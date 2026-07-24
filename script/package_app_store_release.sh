#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
PROJECT="$APPLE_DIR/TokenRemain.xcodeproj"
VERSION="$(/usr/bin/sed -n 's/^[[:space:]]*MARKETING_VERSION: "\(.*\)"/\1/p' "$APPLE_DIR/project.yml" | /usr/bin/head -n 1)"
BUILD="$(/usr/bin/sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$APPLE_DIR/project.yml" | /usr/bin/head -n 1)"
OUTPUT_ROOT="${TOKENREMAIN_IOS_OUTPUT_DIR:-$ROOT_DIR/dist-release/ios/$VERSION-$BUILD}"
ARCHIVE_PATH="${TOKENREMAIN_IOS_ARCHIVE_PATH:-$OUTPUT_ROOT/TokenRemain.xcarchive}"
EXPORT_DIR="${TOKENREMAIN_IOS_EXPORT_DIR:-$OUTPUT_ROOT/AppStore}"
IPA="${TOKENREMAIN_IOS_IPA:-}"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
IDENTITY_SELECTOR="${TOKENREMAIN_APPLE_DISTRIBUTION_IDENTITY:-Apple Distribution: Dongheng Li (84397AQ22Y)}"
BROADCAST_BASE_URL="${TOKENREMAIN_BROADCAST_BASE_URL:-https://api.tokenremain.com}"

IOS_PROFILE="${TOKENREMAIN_IOS_PROFILE:-}"
WIDGETS_PROFILE="${TOKENREMAIN_WIDGETS_PROFILE:-}"
WATCH_PROFILE="${TOKENREMAIN_WATCH_PROFILE:-}"
WATCH_WIDGETS_PROFILE="${TOKENREMAIN_WATCH_WIDGETS_PROFILE:-}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenremain-app-store-release.XXXXXX")"
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

plist_has_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null \
    | /usr/bin/grep -Fq -- "$3"
}

assert_absent() {
  if /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; then
    fail "$3 must not contain $2"
  fi
}

resolve_distribution_identity() {
  local matches count
  matches="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -F -- "$IDENTITY_SELECTOR" || true)"
  count="$(printf '%s\n' "$matches" | /usr/bin/sed '/^[[:space:]]*$/d' \
    | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  [[ "$count" == "1" ]] \
    || fail "TOKENREMAIN_APPLE_DISTRIBUTION_IDENTITY must match exactly one valid identity."
  [[ "$matches" == *'"Apple Distribution: Dongheng Li (84397AQ22Y)"'* ]] \
    || fail "The selected identity is not the Team 84397AQ22Y Apple Distribution identity."
  printf '%s\n' "$matches" | /usr/bin/awk '{print $2}'
}

require_profile() {
  local path="$1"
  local label="$2"
  [[ -r "$path" ]] || fail "$label must point to a readable App Store provisioning profile."
}

validate_profile() {
  local path="$1"
  local expected_identifier="$2"
  local role="$3"
  local expected_certificate_sha="$4"
  local plist="$TEMP_DIR/$role.plist"
  local certificate_sha

  /usr/bin/security cms -D -i "$path" > "$plist"
  [[ "$(plist_value "$plist" Entitlements:application-identifier)" == \
    "84397AQ22Y.$expected_identifier" ]] \
    || fail "$role profile has the wrong application identifier."
  [[ "$(plist_value "$plist" Entitlements:get-task-allow)" == "false" ]] \
    || fail "$role profile must disable get-task-allow."
  [[ "$(plist_value "$plist" Entitlements:beta-reports-active)" == "true" ]] \
    || fail "$role profile is not an App Store distribution profile."
  [[ "$(plist_value "$plist" Entitlements:com.apple.developer.team-identifier)" == \
    "84397AQ22Y" ]] || fail "$role profile has the wrong Team ID."
  plist_has_value "$plist" Entitlements:com.apple.security.application-groups \
    group.com.jamesli.tokenremain \
    || fail "$role profile does not authorize the TokenRemain App Group."

  if [[ "$role" == "ios" ]]; then
    [[ "$(plist_value "$plist" Entitlements:aps-environment)" == "production" ]] \
      || fail "The iOS profile must authorize production APNs."
    plist_has_value "$plist" \
      Entitlements:com.apple.developer.icloud-container-identifiers \
      iCloud.com.jamesli.tokenremain \
      || fail "The iOS profile does not authorize the TokenRemain CloudKit container."
    plist_has_value "$plist" \
      Entitlements:com.apple.developer.icloud-container-environment Production \
      || fail "The iOS profile does not authorize CloudKit Production."
  else
    assert_absent "$plist" Entitlements:aps-environment "$role profile"
    assert_absent "$plist" \
      Entitlements:com.apple.developer.icloud-container-identifiers "$role profile"
  fi

  certificate_sha="$(/usr/bin/plutil -extract DeveloperCertificates.0 raw -o - "$plist" \
    | /usr/bin/base64 -D \
    | /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 \
    | /usr/bin/sed 's/.*=//; s/://g')"
  [[ "$certificate_sha" == "$expected_certificate_sha" ]] \
    || fail "$role profile does not embed the selected Apple Distribution certificate."
}

install_profile() {
  local path="$1"
  local plist="$TEMP_DIR/install.plist"
  local uuid
  /usr/bin/security cms -D -i "$path" > "$plist"
  uuid="$(plist_value "$plist" UUID)"
  /bin/mkdir -p "$PROFILE_DIR"
  /usr/bin/install -m 600 "$path" "$PROFILE_DIR/$uuid.mobileprovision"
}

preflight_profiles() {
  local identity_sha
  require_profile "$IOS_PROFILE" TOKENREMAIN_IOS_PROFILE
  require_profile "$WIDGETS_PROFILE" TOKENREMAIN_WIDGETS_PROFILE
  require_profile "$WATCH_PROFILE" TOKENREMAIN_WATCH_PROFILE
  require_profile "$WATCH_WIDGETS_PROFILE" TOKENREMAIN_WATCH_WIDGETS_PROFILE

  identity_sha="$(resolve_distribution_identity)"
  validate_profile "$IOS_PROFILE" com.jamesli.tokenremain ios "$identity_sha"
  validate_profile "$WIDGETS_PROFILE" com.jamesli.tokenremain.widgets widgets "$identity_sha"
  validate_profile "$WATCH_PROFILE" com.jamesli.tokenremain.watchkitapp watch "$identity_sha"
  validate_profile "$WATCH_WIDGETS_PROFILE" \
    com.jamesli.tokenremain.watchkitapp.widgets watch-widgets "$identity_sha"

  install_profile "$IOS_PROFILE"
  install_profile "$WIDGETS_PROFILE"
  install_profile "$WATCH_PROFILE"
  install_profile "$WATCH_WIDGETS_PROFILE"
  echo "App Store provisioning profile preflight passed."
}

archive_app() {
  [[ "$BROADCAST_BASE_URL" == https://* ]] \
    || fail "TOKENREMAIN_BROADCAST_BASE_URL must be the deployed HTTPS Worker origin."
  command -v xcodegen >/dev/null \
    || fail "xcodegen is required to regenerate the Apple project."
  (
    cd "$APPLE_DIR"
    xcodegen generate
  )
  /bin/mkdir -p "$(dirname "$ARCHIVE_PATH")"
  xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme TokenRemain \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    TOKENREMAIN_BROADCAST_BASE_URL="$BROADCAST_BASE_URL" \
    archive
  echo "Release archive created: $ARCHIVE_PATH"
}

profile_name() {
  /usr/bin/security cms -D -i "$1" \
    | /usr/bin/plutil -extract Name raw -o - -
}

export_app() {
  local export_plist="$TEMP_DIR/ExportOptions.plist"
  local identity_sha

  [[ -d "$ARCHIVE_PATH" ]] || fail "Archive not found: $ARCHIVE_PATH"
  [[ ! -e "$EXPORT_DIR" ]] \
    || fail "Export directory already exists; choose a new TOKENREMAIN_IOS_EXPORT_DIR."
  identity_sha="$(resolve_distribution_identity)"

  /usr/bin/plutil -create xml1 "$export_plist"
  /usr/libexec/PlistBuddy \
    -c "Add :method string app-store-connect" \
    -c "Add :destination string export" \
    -c "Add :signingStyle string manual" \
    -c "Add :signingCertificate string $identity_sha" \
    -c "Add :teamID string 84397AQ22Y" \
    -c "Add :iCloudContainerEnvironment string Production" \
    -c "Add :manageAppVersionAndBuildNumber bool false" \
    -c "Add :uploadSymbols bool true" \
    -c "Add :provisioningProfiles dict" \
    -c "Add :provisioningProfiles:com.jamesli.tokenremain string $(profile_name "$IOS_PROFILE")" \
    -c "Add :provisioningProfiles:com.jamesli.tokenremain.widgets string $(profile_name "$WIDGETS_PROFILE")" \
    -c "Add :provisioningProfiles:com.jamesli.tokenremain.watchkitapp string $(profile_name "$WATCH_PROFILE")" \
    -c "Add :provisioningProfiles:com.jamesli.tokenremain.watchkitapp.widgets string $(profile_name "$WATCH_WIDGETS_PROFILE")" \
    "$export_plist"

  xcodebuild \
    -quiet \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$export_plist"
  echo "App Store package exported: $EXPORT_DIR"
}

verify_bundle() {
  local bundle="$1"
  local expected_identifier="$2"
  local role="$3"
  local entitlements="$TEMP_DIR/$role-entitlements.plist"
  local profile="$TEMP_DIR/$role-profile.plist"
  local signing_details

  [[ -d "$bundle" ]] || fail "$role bundle is missing from the IPA."
  [[ -r "$bundle/PrivacyInfo.xcprivacy" ]] \
    || fail "$role bundle is missing PrivacyInfo.xcprivacy."
  /usr/bin/plutil -lint "$bundle/PrivacyInfo.xcprivacy" >/dev/null
  signing_details="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  [[ "$signing_details" == \
    *"Authority=Apple Distribution: Dongheng Li (84397AQ22Y)"* ]] \
    || fail "$role bundle is not Apple Distribution signed."
  /usr/bin/codesign -d --entitlements :- "$bundle" > "$entitlements" 2>/dev/null
  /usr/bin/security cms -D -i "$bundle/embedded.mobileprovision" > "$profile"

  [[ "$(plist_value "$entitlements" application-identifier)" == \
    "84397AQ22Y.$expected_identifier" ]] \
    || fail "$role signed entitlement has the wrong application identifier."
  [[ "$(plist_value "$entitlements" com.apple.developer.team-identifier)" == \
    "84397AQ22Y" ]] || fail "$role signed entitlement has the wrong Team ID."
  [[ "$(plist_value "$entitlements" get-task-allow)" == "false" ]] \
    || fail "$role signed entitlement must disable get-task-allow."
  [[ "$(plist_value "$entitlements" beta-reports-active)" == "true" ]] \
    || fail "$role signed entitlement is missing beta-reports-active."
  plist_has_value "$entitlements" com.apple.security.application-groups \
    group.com.jamesli.tokenremain \
    || fail "$role signed entitlement is missing the TokenRemain App Group."
  [[ "$(plist_value "$profile" Entitlements:application-identifier)" == \
    "84397AQ22Y.$expected_identifier" ]] \
    || fail "$role embedded profile has the wrong application identifier."

  if [[ "$role" == "ios" ]]; then
    [[ "$(plist_value "$bundle/Info.plist" TokenRemainBroadcastBaseURL)" == "$BROADCAST_BASE_URL" ]] \
      || fail "The exported iOS app has the wrong broadcast service URL."
    [[ "$(plist_value "$entitlements" aps-environment)" == "production" ]] \
      || fail "The exported iOS app must use production APNs."
    [[ "$(plist_value "$entitlements" com.apple.developer.icloud-container-environment)" == \
      "Production" ]] || fail "The exported iOS app must use CloudKit Production."
    [[ "$(plist_value "$entitlements" \
      com.apple.developer.icloud-container-identifiers:0)" == \
      "iCloud.com.jamesli.tokenremain" ]] \
      || fail "The exported iOS app has the wrong CloudKit container."
    [[ "$(plist_value "$entitlements" keychain-access-groups:0)" == \
      "84397AQ22Y.com.jamesli.tokenremain.sync" ]] \
      || fail "The exported iOS app has the wrong sync Keychain group."
  else
    assert_absent "$entitlements" aps-environment "$role signed entitlement"
    assert_absent "$entitlements" \
      com.apple.developer.icloud-container-identifiers "$role signed entitlement"
    assert_absent "$entitlements" keychain-access-groups "$role signed entitlement"
  fi
}

verify_export() {
  local inspect_dir="$TEMP_DIR/ipa"
  local app

  if [[ -z "$IPA" ]]; then
    IPA="$(/usr/bin/find "$EXPORT_DIR" -maxdepth 1 -type f -name "*.ipa" -print -quit)"
  fi
  [[ -r "$IPA" ]] || fail "TOKENREMAIN_IOS_IPA or TOKENREMAIN_IOS_EXPORT_DIR must identify an exported IPA."
  /bin/mkdir -p "$inspect_dir"
  /usr/bin/ditto -x -k "$IPA" "$inspect_dir"
  app="$inspect_dir/Payload/TokenRemain.app"

  /usr/bin/codesign --verify --deep --strict "$app"
  verify_bundle "$app" com.jamesli.tokenremain ios
  verify_bundle "$app/PlugIns/TokenRemainWidgets.appex" \
    com.jamesli.tokenremain.widgets widgets
  verify_bundle "$app/Watch/TokenRemainWatch.app" \
    com.jamesli.tokenremain.watchkitapp watch
  verify_bundle "$app/Watch/TokenRemainWatch.app/PlugIns/TokenRemainWatchWidgets.appex" \
    com.jamesli.tokenremain.watchkitapp.widgets watch-widgets
  /usr/bin/shasum -a 256 "$IPA"
  echo "App Store IPA verification passed: $IPA"
}

case "$MODE" in
  preflight)
    preflight_profiles
    ;;
  archive)
    archive_app
    ;;
  export)
    preflight_profiles
    export_app
    verify_export
    ;;
  verify)
    verify_export
    ;;
  all)
    preflight_profiles
    archive_app
    export_app
    verify_export
    ;;
  *)
    echo "usage: $0 [preflight|archive|export|verify|all]" >&2
    exit 2
    ;;
esac
