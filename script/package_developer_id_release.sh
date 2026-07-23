#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
OUTPUT_DIR="${TOKENREMAIN_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist-release/$VERSION-$BUILD}"
APP="$OUTPUT_DIR/TokenRemain.app"
ZIP="$OUTPUT_DIR/TokenRemain-$VERSION-$BUILD-macOS.zip"
PROFILE="${USAGEDOCK_SYNC_PROVISIONING_PROFILE:-}"
IDENTITY="${USAGEDOCK_SYNC_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${TOKENREMAIN_NOTARYTOOL_PROFILE:-}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

require_signing_inputs() {
  if [[ ! -r "$PROFILE" ]]; then
    echo "USAGEDOCK_SYNC_PROVISIONING_PROFILE must point to the Apple-issued Developer ID provisioning profile." >&2
    exit 1
  fi
  if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "USAGEDOCK_SYNC_SIGNING_IDENTITY must be a Developer ID Application identity." >&2
    exit 1
  fi
  if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$IDENTITY\""; then
    echo "The requested Developer ID Application identity is not installed or is not valid." >&2
    exit 1
  fi
}

verify_app() {
  local app="$1"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/tokenremain-release-entitlements.XXXXXX")"

  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/codesign -d --entitlements :- "$app/Contents/MacOS/UsageDock" > "$entitlements" 2>/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$entitlements")" == "Production" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$entitlements")" == "iCloud.com.jamesli.tokenremain" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" == "84397AQ22Y.com.jamesli.tokenremain.sync" ]]
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
    echo "Release app must not contain get-task-allow." >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" >/dev/null 2>&1; then
    echo "Website release must remain unsandboxed." >&2
    exit 1
  fi
  rm -f "$entitlements"
}

build_app() {
  require_signing_inputs
  mkdir -p "$OUTPUT_DIR"
  USAGEDOCK_SYNC_RELEASE=1 \
  USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT=Production \
  USAGEDOCK_SYNC_PROVISIONING_PROFILE="$PROFILE" \
  USAGEDOCK_SYNC_SIGNING_IDENTITY="$IDENTITY" \
  USAGEDOCK_ARCHIVE_DIR="$OUTPUT_DIR" \
    "$ROOT_DIR/script/build_and_run.sh" --archive
  verify_app "$APP"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
}

case "$MODE" in
  build)
    build_app
    echo "Developer ID package created but not notarized: $ZIP"
    ;;
  notarize)
    build_app
    if [[ -z "$NOTARY_PROFILE" ]]; then
      echo "TOKENREMAIN_NOTARYTOOL_PROFILE is required for notarize mode." >&2
      exit 1
    fi
    /usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$APP"
    /usr/bin/xcrun stapler validate "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Notarized and stapled package created: $ZIP"
    ;;
  verify)
    verify_app "$APP"
    /usr/bin/xcrun stapler validate "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
    echo "Developer ID release verification passed: $APP"
    ;;
  *)
    echo "usage: $0 [build|notarize|verify]" >&2
    exit 2
    ;;
esac
