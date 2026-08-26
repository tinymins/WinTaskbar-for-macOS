#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

SIGNING_DIRECTORY="$ROOT_DIR/.signing"
SIGNING_P12_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.p12"
SIGNING_PASSWORD_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.password"
PINNED_CERTIFICATE_PATH="$ROOT_DIR/.github/WinTaskbar-CI-Code-Signing.pem"
RCODESIGN_PATH="$ROOT_DIR/.tools/rcodesign"
RCODESIGN_VERSION=0.29.0

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
  if [[ ! -x "$RCODESIGN_PATH" ]]; then
    echo "rcodesign is not initialized. Run: bun run init" >&2
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
  pkcs12_args=(
    -in "$SIGNING_P12_PATH"
    -clcerts
    -nokeys
    -passin env:P12_PASSWORD
  )
  if [[ "$(openssl version)" == "OpenSSL 3"* ]]; then
    pkcs12_args+=(-legacy)
  fi
  imported_fingerprint=$(
    P12_PASSWORD="$p12_password" openssl pkcs12 "${pkcs12_args[@]}" 2>/dev/null |
      openssl x509 -noout -fingerprint -sha256
  )
  pinned_fingerprint=$(openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha256)
  if [[ "$imported_fingerprint" != "$pinned_fingerprint" ]]; then
    echo "The local signing certificate does not match the pinned WinTaskbar certificate." >&2
    exit 1
  fi

  rcodesign_signature=$(codesign -dvvv "$RCODESIGN_PATH" 2>&1)
  if [[ "$("$RCODESIGN_PATH" --version)" != "apple-codesign $RCODESIGN_VERSION" ]] || \
    ! codesign --verify --deep --strict "$RCODESIGN_PATH" || \
    ! grep -q '^Authority=Developer ID Application: Gregory Szorc (MK22MZP987)$' <<< "$rcodesign_signature" || \
    ! grep -q '^TeamIdentifier=MK22MZP987$' <<< "$rcodesign_signature"; then
    echo "The local rcodesign binary failed signature verification. Run: bun run init" >&2
    exit 1
  fi

  bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")
  certificate_sha1=$(
    openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha1 |
      cut -d= -f2 |
      tr -d ':' |
      tr '[:upper:]' '[:lower:]'
  )
  requirement_expression="identifier \"$bundle_identifier\" and certificate root = H\"$certificate_sha1\""
  requirement_directory="$ROOT_DIR/.build/local-signing"
  requirement_path="$requirement_directory/WinTaskbar.requirement.bin"
  mkdir -p "$requirement_directory"
  csreq -r="$requirement_expression" -b "$requirement_path"

  "$RCODESIGN_PATH" -C /dev/null sign \
    --p12-file "$SIGNING_P12_PATH" \
    --p12-password-file "$SIGNING_PASSWORD_PATH" \
    --timestamp-url none \
    --code-signature-flags runtime \
    --code-requirements-file "$requirement_path" \
    "$APP_DIR"

  expected_requirement="designated => $requirement_expression"
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
