#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

SIGNING_DIRECTORY="$ROOT_DIR/.signing"
SIGNING_P12_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.p12"
SIGNING_PASSWORD_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.password"
PINNED_CERTIFICATE_PATH="$ROOT_DIR/.github/WinTaskbar-CI-Code-Signing.pem"

original_keychains=()
temporary_keychain_path=

cleanup() {
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychain -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$temporary_keychain_path" ]]; then
    temporary_root=$(dirname "$temporary_keychain_path")
    security delete-keychain "$temporary_keychain_path" >/dev/null 2>&1 || true
    rmdir "$temporary_root" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

STABLE_SIGNING=false
if [[ -f "$SIGNING_P12_PATH" || -f "$SIGNING_PASSWORD_PATH" ]]; then
  if [[ ! -f "$SIGNING_P12_PATH" || ! -f "$SIGNING_PASSWORD_PATH" ]]; then
    echo "Stable local signing requires both files in $SIGNING_DIRECTORY." >&2
    exit 1
  fi
  if [[ ! -f "$PINNED_CERTIFICATE_PATH" ]]; then
    echo "Pinned signing certificate not found at $PINNED_CERTIFICATE_PATH." >&2
    exit 1
  fi
  STABLE_SIGNING=true
fi

swift build -c release

APP_DIR="$ROOT_DIR/dist/WinTaskbar.app"
CONTENTS_DIR="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/WinTaskbar" "$CONTENTS_DIR/MacOS/WinTaskbar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
for localization in "$ROOT_DIR"/Resources/*.lproj; do
  cp -R "$localization" "$CONTENTS_DIR/Resources/"
done

if [[ "$STABLE_SIGNING" == "true" ]]; then
  p12_password=$(<"$SIGNING_PASSWORD_PATH")
  temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/wintaskbar-local-signing.XXXXXX")
  temporary_keychain_path="$temporary_root/local-signing.keychain-db"
  keychain_password=$(uuidgen)
  while IFS= read -r keychain; do
    keychain=${keychain#*\"}
    keychain=${keychain%\"}
    original_keychains+=("$keychain")
  done < <(security list-keychains -d user)

  security create-keychain -p "$keychain_password" "$temporary_keychain_path"
  security set-keychain-settings -lut 21600 "$temporary_keychain_path"
  security unlock-keychain -p "$keychain_password" "$temporary_keychain_path"
  security import "$SIGNING_P12_PATH" \
    -P "$p12_password" \
    -A \
    -t cert \
    -f pkcs12 \
    -k "$temporary_keychain_path" >/dev/null

  imported_fingerprint=$(
    security find-certificate -p -c "WinTaskbar CI Code Signing" "$temporary_keychain_path" |
      openssl x509 -noout -fingerprint -sha256
  )
  pinned_fingerprint=$(openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha256)
  if [[ "$imported_fingerprint" != "$pinned_fingerprint" ]]; then
    echo "The local signing certificate does not match the pinned WinTaskbar certificate." >&2
    exit 1
  fi

  security set-key-partition-list \
    -S apple-tool:,apple: \
    -k "$keychain_password" \
    "$temporary_keychain_path" >/dev/null
  security list-keychain -d user -s "$temporary_keychain_path" "${original_keychains[@]}"

  identities=$(security find-identity -v -p codesigning "$temporary_keychain_path")
  identity_count=$(grep -cE '^[[:space:]]*[0-9]+\)' <<< "$identities" || true)
  if [[ "$identity_count" -ne 1 ]]; then
    echo "Expected exactly one stable code-signing identity, found $identity_count." >&2
    exit 1
  fi
  signing_identity=$(awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }' <<< "$identities")
  codesign \
    --force \
    --deep \
    --options runtime \
    --sign "$signing_identity" \
    --keychain "$temporary_keychain_path" \
    "$APP_DIR"

  bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")
  certificate_sha1=$(
    openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha1 |
      cut -d= -f2 |
      tr -d ':' |
      tr '[:upper:]' '[:lower:]'
  )
  expected_requirement="designated => identifier \"$bundle_identifier\" and certificate root = H\"$certificate_sha1\""
  actual_requirement=$(codesign -d -r- "$APP_DIR" 2>&1 | tail -n 1)
  if [[ "$actual_requirement" != "$expected_requirement" ]]; then
    echo "The local app does not have the stable WinTaskbar designated requirement." >&2
    exit 1
  fi
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
