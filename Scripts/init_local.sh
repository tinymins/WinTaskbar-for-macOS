#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TOOLS_DIRECTORY="$ROOT_DIR/.tools"
RCODESIGN_PATH="$TOOLS_DIRECTORY/rcodesign"
RCODESIGN_VERSION=0.29.0

case "$(uname -m)" in
  arm64)
    RELEASE_TARGET=aarch64-apple-darwin
    EXPECTED_ARCHIVE_SHA256=d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a
    EXPECTED_BINARY_SHA256=6c4623db45f1d89af439a2ce42fd65798ef56aaaa3e4ced48879be05f750aacb
    ;;
  x86_64)
    RELEASE_TARGET=x86_64-apple-darwin
    EXPECTED_ARCHIVE_SHA256=14ef11bedd51a8d95eafd767939ae96d5900e5a61511bef75bb21db6e7c74140
    EXPECTED_BINARY_SHA256=21588902f0698182c21b14d9623c424eb32595f675ace5b31dc1c3f3b0223ec1
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)." >&2
    exit 1
    ;;
esac

verify_rcodesign() {
  local binary_path=$1
  local actual_binary_sha256
  local signature

  [[ -x "$binary_path" ]] || return 1
  actual_binary_sha256=$(shasum -a 256 "$binary_path" | awk '{ print $1 }')
  [[ "$actual_binary_sha256" == "$EXPECTED_BINARY_SHA256" ]] || return 1
  [[ "$("$binary_path" --version)" == "apple-codesign $RCODESIGN_VERSION" ]] || return 1
  codesign --verify --deep --strict "$binary_path" || return 1
  signature=$(codesign -dvvv "$binary_path" 2>&1)
  grep -q '^Authority=Developer ID Application: Gregory Szorc (MK22MZP987)$' <<< "$signature" || return 1
  grep -q '^TeamIdentifier=MK22MZP987$' <<< "$signature" || return 1
}

mkdir -p "$TOOLS_DIRECTORY"
if verify_rcodesign "$RCODESIGN_PATH"; then
  echo "rcodesign $RCODESIGN_VERSION is already initialized."
else
  download_root=$(mktemp -d "$TOOLS_DIRECTORY/.rcodesign-download.XXXXXX")
  cleanup() {
    case "$download_root" in
      "$TOOLS_DIRECTORY"/.rcodesign-download.*)
        rm -rf "$download_root"
        ;;
    esac
  }
  trap cleanup EXIT

  archive_name="apple-codesign-$RCODESIGN_VERSION-$RELEASE_TARGET.tar.gz"
  archive_path="$download_root/$archive_name"
  release_url="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION/$archive_name"

  curl --fail --location --silent --show-error "$release_url" --output "$archive_path"
  actual_archive_sha256=$(shasum -a 256 "$archive_path" | awk '{ print $1 }')
  if [[ "$actual_archive_sha256" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
    echo "rcodesign archive checksum mismatch." >&2
    exit 1
  fi

  tar -xzf "$archive_path" -C "$download_root"
  downloaded_binary=$(
    find "$download_root" -type f -name rcodesign -perm -111 -print -quit
  )
  if [[ -z "$downloaded_binary" ]] || ! verify_rcodesign "$downloaded_binary"; then
    echo "Downloaded rcodesign binary failed verification." >&2
    exit 1
  fi

  install -m 755 "$downloaded_binary" "$RCODESIGN_PATH"
  verify_rcodesign "$RCODESIGN_PATH"
  echo "Initialized rcodesign $RCODESIGN_VERSION at $RCODESIGN_PATH."
fi

SIGNING_DIRECTORY="$ROOT_DIR/.signing"
SIGNING_P12_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.p12"
SIGNING_PASSWORD_PATH="$SIGNING_DIRECTORY/WinTaskbar-CI-Code-Signing.password"
if [[ -d "$SIGNING_DIRECTORY" ]]; then
  chmod 700 "$SIGNING_DIRECTORY"
  if [[ -f "$SIGNING_P12_PATH" || -f "$SIGNING_PASSWORD_PATH" ]]; then
    if [[ ! -f "$SIGNING_P12_PATH" || ! -f "$SIGNING_PASSWORD_PATH" ]]; then
      echo "Stable local signing requires both files in $SIGNING_DIRECTORY." >&2
      exit 1
    fi
    chmod 600 "$SIGNING_P12_PATH" "$SIGNING_PASSWORD_PATH"
    echo "Stable local signing material is ready."
  fi
fi
