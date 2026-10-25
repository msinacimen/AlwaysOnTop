import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let mainMenu = NSMenu()
    private let windowsMenu = NSMenu()
    private var hotKeys: [HotKey] = []
    private var syncTimer: Timer?

    private var availableWindows: [SCWindow] = []
    private var captureDenied = false
    private var pins: [PinnedWindow] = [] {
        didSet { updateStatusButton() }
    }

    private let myPID = ProcessInfo.processInfo.processIdentifier

    private static let followsDesktopsKey = "followsDesktops"
    /// Whether pins come along to other desktops as a view-only copy, or stay
    /// on their window's own desktop.
    private var followsDesktops: Bool {
        get { UserDefaults.standard.bool(forKey: Self.followsDesktopsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.followsDesktopsKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.followsDesktopsKey: true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Always On Top")
        statusItem.button?.imagePosition = .imageLeading
        mainMenu.delegate = self
        statusItem.menu = mainMenu

        // ⌃⌥P pins or unpins the window you're looking at; ⌃⌥⇧P unpins everything.
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in
                self?.toggleFrontmostWindow()
            },
            HotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
                self?.unpinAll()
            },
        ].compactMap { $0 }

        enableLaunchAtLoginOnFirstRun()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        // Keep each floating copy in step with its real window.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.syncPins() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }

        Task { await refreshWindows() }
    }

    /// App, hide and desktop switches are answered at once, including the
    /// check of which desktop each pinned window is on.
    @objc private func workspaceChanged() {
        syncPins(spaceChanged: true)
    }

    private func syncPins(spaceChanged: Bool = false) {
        guard !pins.isEmpty else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let follows = followsDesktops
        for pin in pins { pin.sync(windowList: list, followsDesktops: follows, spaceChanged: spaceChanged) }
    }

    private func updateStatusButton() {
        statusItem?.button?.title = pins.isEmpty ? "" : " \(pins.count)"
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        Task { await refreshWindows() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        menu.removeAllItems()

        let front = NSMenuItem(title: "Pin / Unpin Frontmost Window", action: #selector(toggleFrontmostFromMenu), keyEquivalent: "p")
        front.keyEquivalentModifierMask = [.control, .option]
        front.target = self
        menu.addItem(front)

        let choose = NSMenuItem(title: "Pin Window", action: nil, keyEquivalent: "")
        choose.submenu = windowsMenu
        menu.addItem(choose)

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Pinned"))
            for pin in pins {
                let item = NSMenuItem(title: truncated(pin.displayName), action: nil, keyEquivalent: "")
                item.submenu = pin.makeMenu()
                menu.addItem(item)
            }
            let all = NSMenuItem(title: "Unpin All", action: #selector(unpinAll), keyEquivalent: "p")
            all.keyEquivalentModifierMask = [.control, .option, .shift]
            all.target = self
            menu.addItem(all)
        }

        menu.addItem(.separator())
        let follow = NSMenuItem(title: "Follow to Other Desktops", action: #selector(toggleFollowsDesktops),
                                keyEquivalent: "")
        follow.target = self
        follow.state = followsDesktops ? .on : .off
        follow.toolTip = "On other desktops a pin shows as a view only and clicks pass through it. "
            + "To use a window on every desktop, right-click its app in the Dock and choose "
            + "Options › Assign To › All Desktops."
        menu.addItem(follow)

        menu.addItem(.separator())
        if captureDenied {
            let item = NSMenuItem(title: "Grant Screen Recording Permission…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !AXIsProcessTrusted() {
            let item = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Always On Top", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func rebuildWindowsMenu() {
        windowsMenu.removeAllItems()

        if captureDenied {
            let item = NSMenuItem(title: "Screen Recording permission needed…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            item.target = self
            windowsMenu.addItem(item)
            return
        }
        if availableWindows.isEmpty {
            windowsMenu.addItem(NSMenuItem(title: "No windows found", action: nil, keyEquivalent: ""))
            return
        }

        let byApp = Dictionary(grouping: availableWindows) { $0.owningApplication?.processID ?? 0 }
        let appOrder = byApp.keys.sorted {
            (byApp[$0]?.first?.owningApplication?.applicationName ?? "")
                .localizedCaseInsensitiveCompare(byApp[$1]?.first?.owningApplication?.applicationName ?? "") == .orderedAscending
        }

        for pid in appOrder {
            guard let windows = byApp[pid], let app = windows.first?.owningApplication else { continue }
            let header = NSMenuItem(title: app.applicationName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                header.image = icon
            }
            windowsMenu.addItem(header)

            for window in windows {
                let title = (window.title?.isEmpty == false) ? window.title! : "Untitled Window"
                let item = NSMenuItem(title: truncated(title), action: #selector(togglePinFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = window
                if pins.contains(where: { $0.windowID == window.windowID }) { item.state = .on }
                windowsMenu.addItem(item)
            }
        }
    }

    private func truncated(_ s: String, limit: Int = 60) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    // MARK: Window discovery

    @MainActor
    private func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            availableWindows = content.windows.filter { window in
                guard let app = window.owningApplication else { return false }
                return window.windowLayer == 0
                    && window.frame.width >= 60 && window.frame.height >= 60
                    && app.processID != myPID
            }
            captureDenied = false
        } catch {
            availableWindows = []
            captureDenied = true
        }
        rebuildWindowsMenu()
    }

    // MARK: Pinning

    @objc private func togglePinFromMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? SCWindow else { return }
        if let existing = pins.first(where: { $0.windowID == window.windowID }) {
            existing.close()
        } else {
            pin(window)
        }
    }

    @objc private func toggleFrontmostFromMenu() {
        toggleFrontmostWindow()
    }

    private func toggleFrontmostWindow() {
        // A pinned copy floating over another app looks like the active window,
        // so the one under the pointer wins.
        let mouse = NSEvent.mouseLocation
        if let hovered = pins.first(where: { $0.contains(screenPoint: mouse) }) {
            hovered.close()
            NSSound(named: "Pop")?.play()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPID else {
            NSSound.beep()
            return
        }
        // The window list is ordered front to back, so the first normal-layer
        // window owned by the frontmost app is the one the user is looking at.
        // Skip tiny ones such as the separate button strip macOS adds to
        // windows being captured.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard let windowID = info.first(where: {
            guard ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  ($0[kCGWindowLayer as String] as? Int) == 0,
                  let dict = $0[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary) else { return false }
            return bounds.width >= 60 && bounds.height >= 60
        })?[kCGWindowNumber as String] as? CGWindowID else {
            NSSound.beep()
            return
        }

        if let existing = pins.first(where: { $0.windowID == windowID }) {
            existing.close()
            NSSound(named: "Pop")?.play()
            return
        }

        Task { @MainActor in
            await refreshWindows()
            if captureDenied {
                showPermissionAlert()
            } else if let window = availableWindows.first(where: { $0.windowID == windowID }) {
                pin(window)
            } else {
                NSSound.beep()
            }
        }
    }

    private func pin(_ window: SCWindow) {
        guard !pins.contains(where: { $0.windowID == window.windowID }) else { return }
        if !AXIsProcessTrusted() { showAccessibilityAlert() }

        let pin = PinnedWindow(window: window, followsDesktops: followsDesktops)
        pin.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
        }
        pins.append(pin)

        Task { @MainActor in
            do {
                try await pin.start()
                NSSound(named: "Tink")?.play()
                syncPins()
            } catch {
                pin.close()
                showError("Couldn't pin “\(pin.displayName)”", detail: error.localizedDescription)
            }
        }
    }

    @objc private func toggleFollowsDesktops() {
        followsDesktops.toggle()
        for pin in pins { pin.setFollowsDesktops(followsDesktops) }
        syncPins(spaceChanged: true)
    }

    @objc private func unpinAll() {
        guard !pins.isEmpty else { return }
        for pin in pins { pin.close() }
        NSSound(named: "Pop")?.play()
    }

    // MARK: Open at login

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Couldn't change Open at Login", detail: error.localizedDescription)
        }
    }

    // MARK: Permissions & alerts

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    @objc private func openAccessibilitySettings() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Always On Top shows a live copy of pinned windows while they're covered, which macOS treats as screen recording.\n\nTurn on Always On Top in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
    }

    private func showAccessibilityAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = "To bring a pinned window forward when you click it, Always On Top needs Accessibility access.\n\nTurn on Always On Top in System Settings › Privacy & Security › Accessibility."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
    }

    private func showError(_ message: String, detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
