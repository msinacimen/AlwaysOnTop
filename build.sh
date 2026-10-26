#!/bin/bash
# Builds build/AlwaysOnTop.app (universal: Apple silicon + Intel).
# Signs with the "AlwaysOnTop Local Signing" certificate from your login keychain
# when it exists, so macOS keeps the app's permissions across rebuilds. Without
# it the app is signed ad hoc and permissions must be re-granted after each build.
# Override with SIGN_IDENTITY="…" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AlwaysOnTop.app"
BIN="$APP/Contents/MacOS/AlwaysOnTop"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift \
    -o "build/obj/AlwaysOnTop-$arch"
done
lipo -create build/obj/AlwaysOnTop-arm64 build/obj/AlwaysOnTop-x86_64 -output "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.local.AlwaysOnTop</string>
  <key>CFBundleName</key><string>AlwaysOnTop</string>
  <key>CFBundleDisplayName</key><string>Always On Top</string>
  <key>CFBundleExecutable</key><string>AlwaysOnTop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Always On Top shows a live view of the windows you pin.</string>
</dict>
</plist>
PLIST

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"AlwaysOnTop Local Signing"/ { print $2; exit }')
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier dev.local.AlwaysOnTop "$APP"
echo "Built $APP"

# ./build.sh install — replace /Applications/AlwaysOnTop.app and relaunch it.
if [[ "${1:-}" == "install" ]]; then
  osascript -e 'quit app id "dev.local.AlwaysOnTop"' 2>/dev/null || true
  pkill -x AlwaysOnTop 2>/dev/null || true
  rm -rf /Applications/AlwaysOnTop.app
  ditto "$APP" /Applications/AlwaysOnTop.app
  open /Applications/AlwaysOnTop.app
  echo "Installed /Applications/AlwaysOnTop.app"
fi
