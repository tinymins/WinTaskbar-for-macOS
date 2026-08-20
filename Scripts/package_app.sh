#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

swift build -c release

APP_DIR="$ROOT_DIR/dist/WinTaskbar.app"
CONTENTS_DIR="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/WinTaskbar" "$CONTENTS_DIR/MacOS/WinTaskbar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
for localization in "$ROOT_DIR"/Resources/*.lproj; do
  cp -R "$localization" "$CONTENTS_DIR/Resources/"
done

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
