import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

/// Maps an Accessibility window element to its window server ID. Private but
/// stable; window managers such as Rectangle and Amethyst rely on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Shows captured frames. It only receives mouse events while the real window
/// is covered: a click raises the real window and is then replayed on it, and
/// scrolling is forwarded so the copy can be scrolled without focusing it.
final class MirrorView: NSView {
    weak var pin: PinnedWindow?
    let displayLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayLayer.contentsGravity = .resizeAspect
        layer = displayLayer // layer-hosting: we own the layer's contents
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pin?.clickBegan(event) }
    override func mouseUp(with event: NSEvent) { pin?.clickEnded(event, button: .left) }
    override func rightMouseDown(with event: NSEvent) { pin?.clickBegan(event) }
    override func rightMouseUp(with event: NSEvent) { pin?.clickEnded(event, button: .right) }
    override func otherMouseDown(with event: NSEvent) { pin?.focusSource() }
    override func scrollWheel(with event: NSEvent) { pin?.forwardScroll(event) }
}

/// Keeps a window visually on top. A borderless floating panel sits exactly
/// over the real window and shows a live copy of it, so it's already in place
/// the instant something else would cover the window — no flicker. While the
/// real window is in front the copy is click-through, so the user is always
/// interacting with the actual app.
final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Placement {
        case front              // nothing above the real window
        case frontWithChildren  // only its own sheets/popovers are above it
        case covered            // another window overlaps it
        case offscreen          // minimized, or on another desktop
    }

    let source: SCWindow
    let pid: pid_t
    let panel: NSPanel
    var onClose: ((PinnedWindow) -> Void)?

    private let mirror = MirrorView()
    private let appElement: AXUIElement
    private var stream: SCStream?
    private let config = SCStreamConfiguration()
    private var pixelScale: CGFloat = 2
    private var capturedSize: CGSize
    private var lastBounds: CGRect?
    private var settledAt = Date.distantPast // when the real window last moved or resized
    private var clickDownLocation: CGPoint?
    private let frameQueue = DispatchQueue(label: "AlwaysOnTop.frames", qos: .userInteractive)
    private var closed = false

    var windowID: CGWindowID { source.windowID }

    var displayName: String {
        let app = source.owningApplication?.applicationName ?? "Window"
        guard let title = source.title, !title.isEmpty else { return app }
        return "\(app) — \(title)"
    }

    var opacity: CGFloat {
        get { panel.alphaValue }
        set { panel.alphaValue = min(1, max(0.15, newValue)) }
    }

    init(window: SCWindow) {
        source = window
        pid = window.owningApplication?.processID ?? 0
        capturedSize = window.frame.size
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25) // never let a hung app freeze us

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: window.frame.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false // our app is never active, so this must be off
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        mirror.pin = self
        panel.contentView = mirror
    }

    // MARK: Capture

    func start() async throws {
        let filter = SCContentFilter(desktopIndependentWindow: source)
        pixelScale = CGFloat(filter.pointPixelScale)
        capturedSize = filter.contentRect.size
        config.width = max(1, Int(capturedSize.width * pixelScale))
        config.height = max(1, Int(capturedSize.height * pixelScale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func resizeCapture(to size: CGSize) {
        capturedSize = size
        config.width = max(1, Int(size.width * pixelScale))
        config.height = max(1, Int(size.height * pixelScale))
        if let stream { Task { [config] in try? await stream.updateConfiguration(config) } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        DispatchQueue.main.async { [weak self] in
            self?.mirror.displayLayer.contents = surface
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Usually means the source window was closed.
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    // MARK: Tracking

    /// Called many times a second with the on-screen window list (front to back).
    /// Shows the floating copy only when the real window is covered.
    func sync(windowList: [[String: Any]]) {
        guard !closed else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              let bounds = Self.bounds(of: info)
        else { return close() }

        if bounds.size != capturedSize { resizeCapture(to: bounds.size) }
        if let lastBounds, lastBounds != bounds { settledAt = Date() }
        lastBounds = bounds

        // Step aside briefly while the real window is being moved or resized,
        // so a lagging copy isn't drawn over it.
        let settling = Date().timeIntervalSince(settledAt) < 0.25

        let visible: Bool
        let interactive: Bool
        if app.isHidden {
            (visible, interactive) = (false, false)
        } else {
            switch placement(of: bounds, in: windowList) {
            case .front:
                (visible, interactive) = (!settling, false)
            case .frontWithChildren:
                (visible, interactive) = (false, false)
            case .covered:
                (visible, interactive) = (true, true)
            case .offscreen:
                // On another desktop: keep it visible here, unless it's minimized
                // or full screen (a full-screen copy would blanket every desktop).
                (visible, interactive) = (!isMinimized() && !NSScreen.screens.contains { $0.frame.size == bounds.size }, true)
            }
        }

        // While a click is being handed over, leave the mouse routing alone.
        if clickDownLocation == nil, panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
        guard visible else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let frame = Self.cocoaFrame(for: bounds)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func placement(of bounds: CGRect, in windowList: [[String: Any]]) -> Placement {
        var hasChildrenAbove = false
        for info in windowList {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if (info[kCGWindowNumber as String] as? CGWindowID) == windowID {
                return hasChildrenAbove ? .frontWithChildren : .front
            }
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let other = Self.bounds(of: info), other.width > 1, other.height > 1,
                  other.intersects(bounds) else { continue }

            // A sheet, popover or dialog from the same app that sits mostly on
            // top of the pinned window belongs to it; the copy must not hide it.
            let overlap = other.intersection(bounds)
            if (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
               overlap.width * overlap.height >= 0.5 * other.width * other.height {
                hasChildrenAbove = true
                continue
            }
            return .covered
        }
        return .offscreen
    }

    private func currentPlacement() -> Placement? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              let bounds = Self.bounds(of: info) else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return placement(of: bounds, in: list)
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
    }

    /// Window server coordinates are top-left based; AppKit's are bottom-left.
    private static func cocoaFrame(for bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    // MARK: Interaction

    private func axWindow() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == windowID
        }
    }

    private func isMinimized() -> Bool {
        guard let window = axWindow() else { return false }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    /// Brings the real window to the front, focused. The copy stays put: it
    /// shows the same pixels, so the switch is invisible.
    @objc func focusSource() {
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.isHidden == true { app?.unhide() }
        if let window = axWindow() {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app?.activate()
    }

    /// A click on the copy (the real window was covered): raise the real window
    /// straight away so it's ready by the time the button comes up.
    func clickBegan(_ event: NSEvent) {
        clickDownLocation = event.cgEvent?.location
        focusSource()
    }

    /// Replays the click on the real window once it's in front, so the button
    /// or field under the pointer responds to that first click. Drags only focus.
    func clickEnded(_ event: NSEvent, button: CGMouseButton) {
        guard let down = clickDownLocation else { return }
        let up = event.cgEvent?.location ?? down
        guard hypot(up.x - down.x, up.y - down.y) < 5 else {
            clickDownLocation = nil
            return
        }
        replayClick(at: down, button: button, deadline: Date().addingTimeInterval(0.5))
    }

    private func replayClick(at point: CGPoint, button: CGMouseButton, deadline: Date) {
        switch currentPlacement() {
        case .front?, .frontWithChildren?:
            // Let the click fall through the copy to the real window underneath.
            panel.ignoresMouseEvents = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                let (downType, upType): (CGEventType, CGEventType) =
                    button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
                for type in [downType, upType] {
                    let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                    click?.setIntegerValueField(.mouseEventClickState, value: 1)
                    click?.post(tap: .cghidEventTap)
                }
                self?.clickDownLocation = nil
            }
        default:
            guard Date() < deadline else {
                clickDownLocation = nil // the window never came forward; drop the click
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.replayClick(at: point, button: button, deadline: deadline)
            }
        }
    }

    func forwardScroll(_ event: NSEvent) {
        guard let scroll = event.cgEvent?.copy() else { return }
        scroll.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        scroll.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        scroll.postToPid(pid)
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        panel.orderOut(nil)
        onClose?(self)
    }

    // MARK: Menu

    @objc private func setOpacity(_ sender: NSMenuItem) {
        opacity = CGFloat(sender.tag) / 100
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        close()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let front = NSMenuItem(title: "Bring to Front", action: #selector(focusSource), keyEquivalent: "")
        front.target = self
        menu.addItem(front)

        let opacityItem = NSMenuItem(title: "Opacity When Floating", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 85, 70, 50, 30] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = abs(opacity * 100 - CGFloat(percent)) < 2.5 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())

        let unpinItem = NSMenuItem(title: "Unpin", action: #selector(unpin(_:)), keyEquivalent: "")
        unpinItem.target = self
        menu.addItem(unpinItem)

        return menu
    }
}
