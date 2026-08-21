#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
RELEASE_TAG_FILE="$ROOT_DIR/RELEASE_TAG"
RELEASE_TAG="v$VERSION"
if [[ -r "$RELEASE_TAG_FILE" ]]; then
  RELEASE_TAG="$(/usr/bin/tr -d '[:space:]' < "$RELEASE_TAG_FILE")"
fi
CCUSAGE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$INFO_PLIST")"
OUTPUT_DIR="${TOKENREMAIN_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist-release/$VERSION-$BUILD}"
APP="$OUTPUT_DIR/TokenRemain.app"
ZIP="$OUTPUT_DIR/TokenRemain-$VERSION-$BUILD-macOS.zip"
APPCAST="$OUTPUT_DIR/appcast.xml"
DMG="$OUTPUT_DIR/TokenRemain.dmg"
VERSIONED_DMG="$OUTPUT_DIR/TokenRemain-$VERSION-$BUILD.dmg"
PROFILE="${USAGEDOCK_SYNC_PROVISIONING_PROFILE:-}"
IDENTITY="${USAGEDOCK_SYNC_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${TOKENREMAIN_NOTARYTOOL_PROFILE:-}"
BROADCAST_BASE_URL="${TOKENREMAIN_BROADCAST_BASE_URL:-https://api.tokenremain.com}"
IDENTITY_COMMON_NAME=""
VERIFY_WORK_DIR=""
VERIFICATION_APP=""

cleanup_release_artifacts() {
  if [[ -n "$VERIFY_WORK_DIR" && -d "$VERIFY_WORK_DIR" ]]; then
    /bin/rm -rf "$VERIFY_WORK_DIR"
  fi
  # TokenRemain.app is a generated staging bundle. Leaving it expanded inside
  # dist-release makes Spotlight and LaunchServices expose it as another
  # installed version. ZIP/DMG/appcast/checksum artifacts remain canonical.
  if [[ -d "$APP" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$APP" >/dev/null 2>&1 || true
    /bin/rm -rf "$APP"
  fi
}
trap cleanup_release_artifacts EXIT

materialize_verification_app() {
  if [[ -d "$APP" ]]; then
    VERIFICATION_APP="$APP"
    return
  fi
  [[ -s "$ZIP" ]] || {
    echo "Release verification needs either the expanded app or signed ZIP." >&2
    exit 1
  }
  VERIFY_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenremain-release-verify.XXXXXX")"
  /usr/bin/ditto -x -k "$ZIP" "$VERIFY_WORK_DIR"
  VERIFICATION_APP="$VERIFY_WORK_DIR/TokenRemain.app"
  [[ -d "$VERIFICATION_APP" ]] || {
    echo "Signed ZIP did not contain TokenRemain.app." >&2
    exit 1
  }
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

resolve_signing_common_name() {
  local selector="$1"
  local matches match_count
  matches="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -F -- "$selector" || true)"
  match_count="$(printf '%s\n' "$matches" | /usr/bin/sed '/^[[:space:]]*$/d' \
    | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  if [[ "$match_count" != "1" ]]; then
    echo "Signing identity selector must match exactly one valid identity; use its SHA-1 when common names are duplicated." >&2
    return 1
  fi
  printf '%s\n' "$matches" | /usr/bin/sed -n 's/.*"\(.*\)".*/\1/p'
}

require_signing_inputs() {
  if [[ "$BROADCAST_BASE_URL" != https://* ]]; then
    echo "TOKENREMAIN_BROADCAST_BASE_URL must be the deployed HTTPS Worker origin." >&2
    exit 1
  fi
  if [[ ! -r "$PROFILE" ]]; then
    echo "USAGEDOCK_SYNC_PROVISIONING_PROFILE must point to the Apple-issued Developer ID provisioning profile." >&2
    exit 1
  fi
  if [[ -z "$IDENTITY" ]]; then
    echo "USAGEDOCK_SYNC_SIGNING_IDENTITY must be a certificate SHA-1 or unambiguous common name." >&2
    exit 1
  fi
  IDENTITY_COMMON_NAME="$(resolve_signing_common_name "$IDENTITY")"
  if [[ "$IDENTITY_COMMON_NAME" != "Developer ID Application:"*"(84397AQ22Y)" ]]; then
    echo "The requested identity is not a valid Team 84397AQ22Y Developer ID Application identity." >&2
    exit 1
  fi
}

verify_app() {
  local app="$1"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/tokenremain-release-entitlements.XXXXXX")"

  /usr/bin/codesign --verify --deep --strict "$app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBroadcastBaseURL' "$app/Contents/Info.plist")" == "$BROADCAST_BASE_URL" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")" == "https://github.com/Carstin520/token-remain/releases/latest/download/appcast.xml" ]]
  [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$app/Contents/Info.plist")" == "false" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$app/Contents/Info.plist")" == "false" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$app/Contents/Info.plist")" == "false" ]]
  ! /usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$app/Contents/Info.plist" >/dev/null 2>&1
  ! /usr/libexec/PlistBuddy -c 'Print :SUScheduledImpatientCheckInterval' "$app/Contents/Info.plist" >/dev/null 2>&1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$app/Contents/Info.plist")" == "true" ]]
  [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]]
  [[ -x "$app/Contents/Helpers/ccusage" ]]
  /usr/bin/lipo "$app/Contents/MacOS/UsageDock" -verify_arch arm64 x86_64
  /usr/bin/lipo "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" -verify_arch arm64 x86_64
  /usr/bin/lipo "$app/Contents/Helpers/ccusage" -verify_arch arm64 x86_64
  /usr/bin/codesign --verify --strict "$app/Contents/Frameworks/Sparkle.framework"
  /usr/bin/codesign --verify --strict "$app/Contents/Helpers/ccusage"
  [[ "$("$app/Contents/Helpers/ccusage" --version)" == "ccusage $CCUSAGE_VERSION" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$app/Contents/Info.plist")" == "$CCUSAGE_VERSION" ]]
  /usr/bin/codesign -d --entitlements :- "$app/Contents/MacOS/UsageDock" > "$entitlements" 2>/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$entitlements")" == "Production" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$entitlements")" == "iCloud.com.jamesli.tokenremain" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" == "84397AQ22Y.com.jamesli.tokenremain.sync" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.aps-environment' "$entitlements")" == "production" ]]
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

generate_update_feed() {
  local tool="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
  if [[ ! -x "$tool" ]]; then
    (cd "$ROOT_DIR" && /usr/bin/swift package resolve)
  fi
  [[ -x "$tool" ]] || {
    echo "Sparkle generate_appcast tool is unavailable." >&2
    exit 1
  }
  # A rerun may inherit the stable and versioned DMGs from an older candidate.
  # Sparkle treats those byte-identical archives as duplicate updates and
  # refuses to generate the feed. They cannot describe the newly built ZIP, so
  # remove them before scanning and recreate both from the current app below.
  rm -f "$APPCAST" "$DMG" "$VERSIONED_DMG"
  "$tool" \
    --download-url-prefix "https://github.com/Carstin520/token-remain/releases/download/$RELEASE_TAG/" \
    --link "https://tokenremain.com" \
    --maximum-deltas 0 \
    "$OUTPUT_DIR"
  [[ -s "$APPCAST" ]] || {
    echo "Sparkle did not generate appcast.xml." >&2
    exit 1
  }
  /usr/bin/xmllint --noout "$APPCAST"
  /usr/bin/grep -Fq "TokenRemain-$VERSION-$BUILD-macOS.zip" "$APPCAST"
  /usr/bin/grep -Fq 'sparkle:edSignature=' "$APPCAST"
}

build_notarized_dmg() {
  local staging_dir work_dir mount_dir rw_dmg device size_mb
  local dmg_assets="$ROOT_DIR/Resources/dmg"

  for asset in background.png background@2x.png DS_Store; do
    [[ -r "$dmg_assets/$asset" ]] || {
      echo "Missing DMG asset $dmg_assets/$asset; regenerate with script/make_dmg_background.py." >&2
      exit 1
    }
  done

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenremain-dmg.XXXXXX")"
  staging_dir="$work_dir/stage"
  mount_dir="$work_dir/mnt"
  rw_dmg="$work_dir/rw.dmg"
  /bin/mkdir -p "$staging_dir/.background" "$mount_dir"

  /usr/bin/ditto "$APP" "$staging_dir/TokenRemain.app"
  /bin/ln -s /Applications "$staging_dir/Applications"
  # Multi-representation TIFF so the window art stays sharp on Retina.
  /usr/bin/tiffutil -cathidpicheck \
    "$dmg_assets/background.png" "$dmg_assets/background@2x.png" \
    -out "$staging_dir/.background/background.tiff" >/dev/null
  # Prebuilt Finder layout: window size, icon positions and background picture.
  # Shipping it as a file keeps packaging headless — driving Finder over
  # AppleScript would need Automation consent and a GUI session.
  /usr/bin/ditto "$dmg_assets/DS_Store" "$staging_dir/.DS_Store"
  /usr/bin/ditto "$APP/Contents/Resources/TokenRemain.icns" "$staging_dir/.VolumeIcon.icns"

  rm -f "$DMG" "$VERSIONED_DMG"
  size_mb=$(( $(/usr/bin/du -sm "$staging_dir" | /usr/bin/awk '{print $1}') + 60 ))
  /usr/bin/hdiutil create \
    -volname "TokenRemain" \
    -srcfolder "$staging_dir" \
    -format UDRW \
    -fs HFS+ \
    -size "${size_mb}m" \
    -ov \
    "$rw_dmg"

  # The custom-icon flag lives in the volume's catalog, so it can only be set
  # while mounted. A private mountpoint avoids colliding with /Volumes.
  device="$(/usr/bin/hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen \
    -mountpoint "$mount_dir" | /usr/bin/grep -E '^/dev/' | /usr/bin/head -1 \
    | /usr/bin/awk '{print $1}')"
  /usr/bin/xcrun SetFile -a C "$mount_dir"
  /bin/sync
  /usr/bin/hdiutil detach "$device"

  # ULMO (LZMA) compresses the bundle roughly 16% smaller than zlib-level=9.
  # It needs macOS 10.15 to mount, well below the app's own macOS 14 floor.
  # Sparkle installs from the ZIP, so the DMG format only affects first-run
  # downloads from the website.
  /usr/bin/hdiutil convert "$rw_dmg" -format ULMO -o "$DMG"
  rm -rf "$work_dir"

  /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  /usr/bin/codesign --verify --strict "$DMG"
  /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG"
  /usr/bin/xcrun stapler validate "$DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  /bin/cp "$DMG" "$VERSIONED_DMG"
  /usr/bin/cmp -s "$DMG" "$VERSIONED_DMG" || {
    echo "Versioned DMG does not match the stable download artifact." >&2
    exit 1
  }
}

build_app() {
  local previous_ccusage_version="$CCUSAGE_VERSION"
  "$ROOT_DIR/script/verify_ccusage_freshness.sh" --update
  CCUSAGE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$INFO_PLIST")"
  if [[ "$CCUSAGE_VERSION" != "$previous_ccusage_version" ]]; then
    echo "Bundled ccusage was updated from $previous_ccusage_version to $CCUSAGE_VERSION." >&2
    echo "Commit and push the verified helper update before packaging the release, then rerun this command." >&2
    exit 1
  fi
  "$ROOT_DIR/script/verify_bundled_ccusage_contract.sh"
  require_signing_inputs
  mkdir -p "$OUTPUT_DIR"
  USAGEDOCK_SYNC_RELEASE=1 \
  USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT=Production \
  USAGEDOCK_SYNC_PROVISIONING_PROFILE="$PROFILE" \
  USAGEDOCK_SYNC_SIGNING_IDENTITY="$IDENTITY" \
  USAGEDOCK_ARCHIVE_DIR="$OUTPUT_DIR" \
  TOKENREMAIN_BROADCAST_BASE_URL="$BROADCAST_BASE_URL" \
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
    generate_update_feed
    build_notarized_dmg
    echo "Notarized packages and signed update feed created: $OUTPUT_DIR"
    ;;
  verify)
    materialize_verification_app
    verify_app "$VERIFICATION_APP"
    /usr/bin/xcrun stapler validate "$VERIFICATION_APP"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$VERIFICATION_APP"
    [[ -s "$APPCAST" ]]
    /usr/bin/xmllint --noout "$APPCAST"
    /usr/bin/grep -Fq 'sparkle:edSignature=' "$APPCAST"
    /usr/bin/codesign --verify --strict "$DMG"
    /usr/bin/xcrun stapler validate "$DMG"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
    [[ -s "$VERSIONED_DMG" ]]
    /usr/bin/cmp -s "$DMG" "$VERSIONED_DMG"
    /usr/bin/codesign --verify --strict "$VERSIONED_DMG"
    /usr/bin/xcrun stapler validate "$VERSIONED_DMG"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$VERSIONED_DMG"
    echo "Developer ID release verification passed: $VERIFICATION_APP"
    ;;
  *)
    echo "usage: $0 [build|notarize|verify]" >&2
    exit 2
    ;;
esac
