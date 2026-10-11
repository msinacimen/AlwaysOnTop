# Always On Top

A macOS menu bar app that keeps any window above all others — and still lets you use it like a normal window.

macOS doesn't let one app change the stacking level of another app's windows, so Always On Top places a borderless floating panel exactly over the window you pin and streams a live copy of it (ScreenCaptureKit). While the real window is in front, the copy is click-through and you're using the actual app. When another app comes forward, the copy is already in place on top, so there's no flicker. Clicking the copy raises the real window and replays the click on it.

## Usage

| Action | How |
| --- | --- |
| Pin / unpin the window you're looking at | **⌃⌥P** (the pinned window under the pointer wins) |
| Unpin everything | **⌃⌥⇧P** |
| Pin any open window | Menu bar 📌 › Pin Window |
| Opacity, bring to front, unpin | Menu bar 📌 › the pinned window's submenu |

- Scrolling over a covered pinned window scrolls the real one without switching to it.
- Sheets, popovers and dialogs of the pinned window show normally.
- Pinned windows follow you across desktops and over full-screen apps.
- "Open at Login" is in the menu.

## Permissions

- **Screen & System Audio Recording** — to show the live copy.
- **Accessibility** — to bring the real window forward and pass clicks to it.

Grant both in System Settings › Privacy & Security, then quit and reopen the app.

## Build

Requires macOS 14+ and the Xcode command line tools.

```bash
./build.sh            # builds build/AlwaysOnTop.app (universal)
./build.sh install    # also replaces /Applications/AlwaysOnTop.app and relaunches it
```

If a code-signing identity named **AlwaysOnTop Local Signing** exists in your keychain, the build is signed with it, so macOS keeps the app's permissions across rebuilds. Otherwise it's signed ad hoc and permissions must be granted again after each build. Set `SIGN_IDENTITY` to use a different identity.

## Code

- `Sources/AppDelegate.swift` — menu bar UI, window discovery, shortcuts, login item
- `Sources/PinnedWindow.swift` — capture stream, floating panel, cover detection, click hand-off
- `Sources/HotKey.swift` — global shortcuts via Carbon (no Accessibility needed)
