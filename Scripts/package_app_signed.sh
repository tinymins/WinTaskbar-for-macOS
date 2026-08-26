#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PINNED_CERTIFICATE_PATH="$ROOT_DIR/.github/WinTaskbar-CI-Code-Signing.pem"
USER_CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}
P12_PATH=${WINTASKBAR_SIGNING_P12_PATH:-"$USER_CONFIG_ROOT/wintaskbar/signing/WinTaskbar-CI-Code-Signing.p12"}
PASSWORD_SERVICE=${WINTASKBAR_SIGNING_PASSWORD_SERVICE:-io.github.tinymins.WinTaskbar.ci-signing-p12}
PASSWORD_ACCOUNT=${WINTASKBAR_SIGNING_PASSWORD_ACCOUNT:-$(id -un)}
LOGIN_KEYCHAIN=$(security default-keychain -d user | tr -d ' "\n')

if [[ ! -f "$P12_PATH" ]]; then
  echo "Stable signing certificate not found at $P12_PATH." >&2
  exit 1
fi

if [[ ! -f "$PINNED_CERTIFICATE_PATH" ]]; then
  echo "Pinned public certificate not found at $PINNED_CERTIFICATE_PATH." >&2
  exit 1
fi

p12_password=$(
  security find-generic-password \
    -w \
    -a "$PASSWORD_ACCOUNT" \
    -s "$PASSWORD_SERVICE" \
    "$LOGIN_KEYCHAIN"
)

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/wintaskbar-local-signing.XXXXXX")
keychain_path="$temporary_root/local-signing.keychain-db"
keychain_password=$(uuidgen)
original_keychains=()
while IFS= read -r keychain; do
  keychain=${keychain#*\"}
  keychain=${keychain%\"}
  original_keychains+=("$keychain")
done < <(security list-keychains -d user)

cleanup() {
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychain -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rmdir "$temporary_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$P12_PATH" \
  -P "$p12_password" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "$keychain_path" >/dev/null

imported_fingerprint=$(
  security find-certificate -p -c "WinTaskbar CI Code Signing" "$keychain_path" |
    openssl x509 -noout -fingerprint -sha256
)
pinned_fingerprint=$(openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha256)
if [[ "$imported_fingerprint" != "$pinned_fingerprint" ]]; then
  echo "The local signing certificate does not match the pinned WinTaskbar certificate." >&2
  exit 1
fi

security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$keychain_path" \
  "$PINNED_CERTIFICATE_PATH"
security set-key-partition-list \
  -S apple-tool:,apple: \
  -k "$keychain_password" \
  "$keychain_path" >/dev/null
security list-keychain -d user -s "$keychain_path" "${original_keychains[@]}"

identities=$(security find-identity -v -p codesigning "$keychain_path")
identity_count=$(grep -cE '^[[:space:]]*[0-9]+\)' <<< "$identities" || true)
if [[ "$identity_count" -ne 1 ]]; then
  echo "Expected exactly one stable code-signing identity, found $identity_count." >&2
  exit 1
fi
signing_identity=$(awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }' <<< "$identities")

cd "$ROOT_DIR"
bash Scripts/package_app.sh >/dev/null
app_path="$ROOT_DIR/dist/WinTaskbar.app"
codesign \
  --force \
  --deep \
  --options runtime \
  --sign "$signing_identity" \
  --keychain "$keychain_path" \
  "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
certificate_sha1=$(
  openssl x509 -in "$PINNED_CERTIFICATE_PATH" -noout -fingerprint -sha1 |
    cut -d= -f2 |
    tr -d ':' |
    tr '[:upper:]' '[:lower:]'
)
expected_requirement="designated => identifier \"$bundle_identifier\" and certificate root = H\"$certificate_sha1\""
actual_requirement=$(codesign -d -r- "$app_path" 2>&1 | tail -n 1)
if [[ "$actual_requirement" != "$expected_requirement" ]]; then
  echo "The local app does not have the stable WinTaskbar designated requirement." >&2
  echo "Expected: $expected_requirement" >&2
  echo "Actual:   $actual_requirement" >&2
  exit 1
fi

echo "$app_path"
