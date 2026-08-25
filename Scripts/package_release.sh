#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
ARCHITECTURE=${2:-}
BUILD_NUMBER=${3:-1}

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
  echo "Version must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-PRERELEASE format." >&2
  exit 1
fi
MARKETING_VERSION=${VERSION%%-*}

case "$ARCHITECTURE" in
  arm64|x86_64|universal) ;;
  *)
    echo "Architecture must be arm64, x86_64, or universal." >&2
    exit 1
    ;;
esac

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 1
fi

BUILD_ROOT="$ROOT_DIR/.build/releases"
OUTPUT_ROOT="$ROOT_DIR/dist/releases"
APP_DIR="$OUTPUT_ROOT/$ARCHITECTURE/WinTaskbar.app"
CONTENTS_DIR="$APP_DIR/Contents"
EXECUTABLE_PATH="$CONTENTS_DIR/MacOS/WinTaskbar"
ARCHIVE_NAME="WinTaskbar-$VERSION-macos-$ARCHITECTURE.zip"
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}

if [[ "${GITHUB_ACTIONS:-false}" == "true" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "GitHub Actions releases require a stable SIGNING_IDENTITY." >&2
  exit 1
fi

build_architecture() {
  local architecture=$1
  local build_path="$BUILD_ROOT/$architecture"
  swift build \
    -c release \
    --arch "$architecture" \
    --build-path "$build_path" >&2
  swift build \
    -c release \
    --arch "$architecture" \
    --build-path "$build_path" \
    --show-bin-path
}

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS_DIR/Info.plist")" == "$MARKETING_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS_DIR/Info.plist")" == "$BUILD_NUMBER" ]]

for localization in "$ROOT_DIR"/Resources/*.lproj; do
  cp -R "$localization" "$CONTENTS_DIR/Resources/"
done

if [[ "$ARCHITECTURE" == "universal" ]]; then
  arm64_bin_dir=$(build_architecture arm64)
  x86_64_bin_dir=$(build_architecture x86_64)
  lipo -create \
    "$arm64_bin_dir/WinTaskbar" \
    "$x86_64_bin_dir/WinTaskbar" \
    -output "$EXECUTABLE_PATH"
else
  bin_dir=$(build_architecture "$ARCHITECTURE")
  cp "$bin_dir/WinTaskbar" "$EXECUTABLE_PATH"
fi

codesign_args=(--force --deep --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign_args+=(--options runtime)
fi
if [[ -n "${SIGNING_KEYCHAIN_PATH:-}" ]]; then
  codesign_args+=(--keychain "$SIGNING_KEYCHAIN_PATH")
fi
codesign "${codesign_args[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

actual_architectures=$(lipo -archs "$EXECUTABLE_PATH")
case "$ARCHITECTURE" in
  arm64)
    [[ "$actual_architectures" == "arm64" ]]
    ;;
  x86_64)
    [[ "$actual_architectures" == "x86_64" ]]
    ;;
  universal)
    [[ " $actual_architectures " == *" arm64 "* ]]
    [[ " $actual_architectures " == *" x86_64 "* ]]
    ;;
esac

(
  cd "$OUTPUT_ROOT"
  ditto -c -k --sequesterRsrc --keepParent "$ARCHITECTURE/WinTaskbar.app" "$ARCHIVE_NAME"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "$OUTPUT_ROOT/$ARCHIVE_NAME"
