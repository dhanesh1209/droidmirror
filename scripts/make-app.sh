#!/bin/bash
# Builds build/DroidMirror.app, the menu-bar app, from the Swift package.
#
# The app is ad-hoc signed: fine for running on the Mac that built it, not for giving to others.
# Distribution would need a Developer ID certificate and notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DroidMirrorApp
BIN_DIR="$(swift build -c release --product DroidMirrorApp --show-bin-path)"

APP="build/DroidMirror.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DroidMirrorApp" "$APP/Contents/MacOS/DroidMirror"
cp scripts/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DroidMirror</string>
    <key>CFBundleDisplayName</key><string>DroidMirror</string>
    <key>CFBundleIdentifier</key><string>dev.droidmirror.mac</string>
    <key>CFBundleExecutable</key><string>DroidMirror</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DroidMirror listens on your local network for your paired phone.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
echo "Open it with:  open $APP"
