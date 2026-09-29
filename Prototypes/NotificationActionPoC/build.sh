#!/bin/bash
set -euo pipefail
SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SOURCE_DIR/../.." && pwd)
APP_DIR="$ROOT_DIR/dist/Notification Action PoC.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.tinymins.WinTaskbar.NotificationActionPoC</string>
<key>CFBundleName</key><string>Notification Action PoC</string>
<key>CFBundleExecutable</key><string>NotificationActionPoC</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework UserNotifications \
    "$SOURCE_DIR/main.swift" \
    "$ROOT_DIR/Sources/WinTaskbar/NotificationContentParser.swift" \
    "$ROOT_DIR/Sources/WinTaskbar/NotificationOriginalAction.swift" \
    -o "$APP_DIR/Contents/MacOS/NotificationActionPoC"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
echo "$APP_DIR"
