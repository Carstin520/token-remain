#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TokenRemain"
EXECUTABLE_NAME="UsageDock"
BUNDLE_ID="com.jamesli.usagedock"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_DIR="${USAGEDOCK_INSTALL_DIR:-/Users/jamesli/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LEGACY_INSTALLED_APPS=(
  "$INSTALL_DIR/UsageDock.app"
  "$INSTALL_DIR/Token Remain.app"
)
LOCAL_FEED_CONFIG="$ROOT_DIR/Config/UsageDockFeed.local.plist"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
# A stable signature lets macOS retain the user's "Always Allow" choice for
# the Claude Code keychain item across UsageDock rebuilds.
SIGNING_IDENTITY="${USAGEDOCK_SIGNING_IDENTITY:-}"

# Future CloudKit distribution is deliberately opt-in. Normal local builds keep
# their Apple Development signing behavior and receive no CloudKit entitlement.
# To produce a profile-backed sync build, set all of:
#   USAGEDOCK_SYNC_RELEASE=1
#   USAGEDOCK_SYNC_PROVISIONING_PROFILE=/absolute/path/to/profile.provisionprofile
#   USAGEDOCK_SYNC_SIGNING_IDENTITY='Developer ID Application: …'
#   USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT=Production   # optional when profile type is unambiguous
# An Apple Development identity is also accepted for a profile-backed development
# build, but only a Developer ID identity receives a signing timestamp.
SYNC_RELEASE_MODE="${USAGEDOCK_SYNC_RELEASE:-0}"
SYNC_PROVISIONING_PROFILE="${USAGEDOCK_SYNC_PROVISIONING_PROFILE:-}"
SYNC_SIGNING_IDENTITY="${USAGEDOCK_SYNC_SIGNING_IDENTITY:-}"
SYNC_REQUESTED_ICLOUD_ENVIRONMENT="${USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT:-}"
SYNC_ENTITLEMENTS_TEMPLATE="$ROOT_DIR/Resources/UsageDockSync.entitlements"
SYNC_WORK_DIR=""
SYNC_RESOLVED_ENTITLEMENTS=""
SYNC_EXPECTED_KEYCHAIN_GROUP=""
SYNC_EXPECTED_APPLICATION_IDENTIFIER=""
SYNC_EXPECTED_TEAM_IDENTIFIER=""
SYNC_EXPECTED_ICLOUD_ENVIRONMENT=""
SYNC_EXPECTED_GET_TASK_ALLOW="false"

cleanup_build_artifacts() {
  if [[ -n "$SYNC_WORK_DIR" && -d "$SYNC_WORK_DIR" ]]; then
    rm -rf "$SYNC_WORK_DIR"
  fi
  # The staged bundle is only an intermediate. Keeping it under `dist/`
  # registers a second TokenRemain with LaunchServices and Developer Tools.
  # The signed installed copy under ~/Applications is the sole runnable app.
  if [[ -d "$APP_BUNDLE" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$APP_BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$APP_BUNDLE"
  fi
}
trap cleanup_build_artifacts EXIT

if [[ "$SYNC_RELEASE_MODE" != "0" && "$SYNC_RELEASE_MODE" != "1" ]]; then
  echo "USAGEDOCK_SYNC_RELEASE must be 0 or 1." >&2
  exit 2
fi
if [[ "$SYNC_RELEASE_MODE" == "0" \
  && ( -n "$SYNC_PROVISIONING_PROFILE" \
    || -n "$SYNC_SIGNING_IDENTITY" \
    || -n "$SYNC_REQUESTED_ICLOUD_ENVIRONMENT" ) ]]; then
  echo "Set USAGEDOCK_SYNC_RELEASE=1 to use sync signing or CloudKit environment options." >&2
  exit 2
fi
if [[ -n "$SYNC_REQUESTED_ICLOUD_ENVIRONMENT" \
  && "$SYNC_REQUESTED_ICLOUD_ENVIRONMENT" != "Development" \
  && "$SYNC_REQUESTED_ICLOUD_ENVIRONMENT" != "Production" ]]; then
  echo "USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT must be Development or Production." >&2
  exit 2
fi

prepare_sync_signing() {
  if [[ ! -r "$SYNC_PROVISIONING_PROFILE" ]]; then
    echo "USAGEDOCK_SYNC_PROVISIONING_PROFILE must name a readable macOS provisioning profile." >&2
    exit 1
  fi
  if [[ -z "$SYNC_SIGNING_IDENTITY" ]]; then
    echo "USAGEDOCK_SYNC_SIGNING_IDENTITY is required when USAGEDOCK_SYNC_RELEASE=1." >&2
    exit 1
  fi
  if [[ ! -r "$SYNC_ENTITLEMENTS_TEMPLATE" ]]; then
    echo "Missing sync entitlement template: $SYNC_ENTITLEMENTS_TEMPLATE" >&2
    exit 1
  fi

  SYNC_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usagedock-sync.XXXXXX")"
  local profile_plist="$SYNC_WORK_DIR/profile.plist"
  if ! /usr/bin/security cms -D -i "$SYNC_PROVISIONING_PROFILE" > "$profile_plist"; then
    echo "Could not decode the sync provisioning profile." >&2
    exit 1
  fi

  local app_identifier_prefix
  app_identifier_prefix="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' "$profile_plist" 2>/dev/null || true)"
  if [[ -z "$app_identifier_prefix" ]]; then
    echo "The sync provisioning profile has no ApplicationIdentifierPrefix." >&2
    exit 1
  fi
  if [[ "$app_identifier_prefix" != *. ]]; then
    app_identifier_prefix="${app_identifier_prefix}."
  fi

  local profile_container
  profile_container="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:0' "$profile_plist" 2>/dev/null || true)"
  if [[ "$profile_container" != "iCloud.com.jamesli.tokenremain" ]]; then
    echo "The sync provisioning profile does not authorize iCloud.com.jamesli.tokenremain." >&2
    exit 1
  fi

  local profile_cloudkit_service
  profile_cloudkit_service="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services:0' "$profile_plist" 2>/dev/null || true)"
  if [[ -z "$profile_cloudkit_service" ]]; then
    profile_cloudkit_service="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services' "$profile_plist" 2>/dev/null || true)"
  fi
  # Apple may encode this permission as the concrete service or as a wildcard
  # string in a development profile. The signed app still requests only CloudKit.
  if [[ "$profile_cloudkit_service" != "CloudKit" && "$profile_cloudkit_service" != "*" ]]; then
    echo "The sync provisioning profile does not authorize the CloudKit service." >&2
    exit 1
  fi

  local has_development_environment=false
  local has_production_environment=false
  local environment_index=0
  while true; do
    local profile_environment
    profile_environment="$(/usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.developer.icloud-container-environment:$environment_index" \
      "$profile_plist" 2>/dev/null || true)"
    [[ -n "$profile_environment" ]] || break
    [[ "$profile_environment" == "Development" ]] && has_development_environment=true
    [[ "$profile_environment" == "Production" ]] && has_production_environment=true
    environment_index=$((environment_index + 1))
  done

  SYNC_EXPECTED_ICLOUD_ENVIRONMENT="$SYNC_REQUESTED_ICLOUD_ENVIRONMENT"
  if [[ -z "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" ]]; then
    local first_provisioned_device provisions_all_devices
    first_provisioned_device="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices:0' "$profile_plist" 2>/dev/null || true)"
    provisions_all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist" 2>/dev/null || true)"
    if [[ -n "$first_provisioned_device" ]]; then
      SYNC_EXPECTED_ICLOUD_ENVIRONMENT="Development"
    elif [[ "$provisions_all_devices" == "true" ]]; then
      SYNC_EXPECTED_ICLOUD_ENVIRONMENT="Production"
    else
      echo "Could not infer the CloudKit environment; set USAGEDOCK_SYNC_ICLOUD_ENVIRONMENT explicitly." >&2
      exit 1
    fi
  fi
  if [[ "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" == "Development" \
    && "$has_development_environment" != "true" ]]; then
    echo "The sync provisioning profile does not authorize CloudKit Development." >&2
    exit 1
  fi
  if [[ "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" == "Production" \
    && "$has_production_environment" != "true" ]]; then
    echo "The sync provisioning profile does not authorize CloudKit Production." >&2
    exit 1
  fi

  SYNC_EXPECTED_GET_TASK_ALLOW="false"
  if [[ "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" == "Development" ]]; then
    SYNC_EXPECTED_GET_TASK_ALLOW="true"
    if [[ "$SYNC_SIGNING_IDENTITY" != "Apple Development:"* ]]; then
      echo "CloudKit Development builds require an Apple Development identity." >&2
      exit 1
    fi
  fi
  if [[ "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" == "Production" \
    && "$SYNC_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Production website distribution requires a Developer ID Application identity." >&2
    exit 1
  fi

  SYNC_RESOLVED_ENTITLEMENTS="$SYNC_WORK_DIR/UsageDockSync.resolved.entitlements"
  SYNC_EXPECTED_KEYCHAIN_GROUP="${app_identifier_prefix}com.jamesli.tokenremain.sync"
  SYNC_EXPECTED_APPLICATION_IDENTIFIER="${app_identifier_prefix}${BUNDLE_ID}"
  SYNC_EXPECTED_TEAM_IDENTIFIER="${app_identifier_prefix%.}"
  cp "$SYNC_ENTITLEMENTS_TEMPLATE" "$SYNC_RESOLVED_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $SYNC_EXPECTED_KEYCHAIN_GROUP" "$SYNC_RESOLVED_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier $SYNC_EXPECTED_APPLICATION_IDENTIFIER" "$SYNC_RESOLVED_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $SYNC_EXPECTED_TEAM_IDENTIFIER" "$SYNC_RESOLVED_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.icloud-container-environment $SYNC_EXPECTED_ICLOUD_ENVIRONMENT" "$SYNC_RESOLVED_ENTITLEMENTS"
  if [[ "$SYNC_EXPECTED_GET_TASK_ALLOW" == "true" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.get-task-allow true' "$SYNC_RESOLVED_ENTITLEMENTS"
  else
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$SYNC_RESOLVED_ENTITLEMENTS" 2>/dev/null || true
  fi
}

verify_sync_signature() {
  local signed_app="$1"
  local final_entitlements="$SYNC_WORK_DIR/final-entitlements.plist"
  /usr/bin/codesign --verify --deep --strict "$signed_app"
  /usr/bin/codesign -d --entitlements :- "$signed_app/Contents/MacOS/$EXECUTABLE_NAME" > "$final_entitlements" 2>/dev/null

  local container environment service keychain_group application_identifier team_identifier get_task_allow
  container="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$final_entitlements" 2>/dev/null || true)"
  environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$final_entitlements" 2>/dev/null || true)"
  service="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services:0' "$final_entitlements" 2>/dev/null || true)"
  keychain_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$final_entitlements" 2>/dev/null || true)"
  application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$final_entitlements" 2>/dev/null || true)"
  team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$final_entitlements" 2>/dev/null || true)"
  get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$final_entitlements" 2>/dev/null || true)"
  if [[ "$container" != "iCloud.com.jamesli.tokenremain" \
    || "$environment" != "$SYNC_EXPECTED_ICLOUD_ENVIRONMENT" \
    || "$service" != "CloudKit" \
    || "$keychain_group" != "$SYNC_EXPECTED_KEYCHAIN_GROUP" \
    || "$application_identifier" != "$SYNC_EXPECTED_APPLICATION_IDENTIFIER" \
    || "$team_identifier" != "$SYNC_EXPECTED_TEAM_IDENTIFIER" ]]; then
    echo "Final sync signature is missing a required CloudKit or shared-keychain entitlement." >&2
    exit 1
  fi
  if [[ "$SYNC_EXPECTED_GET_TASK_ALLOW" == "true" && "$get_task_allow" != "true" ]]; then
    echo "Development sync signature is missing get-task-allow from its profile." >&2
    exit 1
  fi
  if [[ "$SYNC_EXPECTED_GET_TASK_ALLOW" == "false" && "$get_task_allow" == "true" ]]; then
    echo "Production sync signature unexpectedly grants get-task-allow." >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$final_entitlements" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$final_entitlements" >/dev/null 2>&1; then
    echo "Final sync signature unexpectedly grants App Sandbox or an App Group." >&2
    exit 1
  fi
}

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
cd "$ROOT_DIR"
SWIFT_BUILD_ARGS=(--product "$EXECUTABLE_NAME")
if [[ "$SYNC_RELEASE_MODE" == "1" ]]; then
  SWIFT_BUILD_ARGS+=(-Xswiftc -DTOKENREMAIN_CLOUD_SYNC)
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/Sources/UsageDock/Resources/claude.png" "$APP_RESOURCES/claude.png"
cp "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemain.icns" "$APP_RESOURCES/TokenRemain.icns"
cp -R "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainHeadStates" "$APP_RESOURCES/"
cp -R "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainFullBodyStates" "$APP_RESOURCES/"
# Localized strings live in the app bundle so SwiftUI and NSLocalizedString
# automatically follow the system language or the per-app macOS language.
for localization in "$ROOT_DIR/Sources/UsageDock/Localization/"*.lproj; do
  cp -R "$localization" "$APP_RESOURCES/"
done
chmod +x "$APP_BINARY"

if [[ "$SYNC_RELEASE_MODE" == "1" ]]; then
  prepare_sync_signing
  SIGNING_IDENTITY="$SYNC_SIGNING_IDENTITY"
else
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
      | head -n 1)"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "TokenRemain needs an Apple Development signing identity to preserve Keychain approval." >&2
    exit 1
  fi
fi
# Finder/File Provider metadata can be copied onto a local bundle and invalidate
# its resource seal. These are metadata only; the signed app never relies on them.
for attribute in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.macl com.apple.provenance com.apple.quarantine; do
  /usr/bin/xattr -dr "$attribute" "$APP_BUNDLE" 2>/dev/null || true
done
if [[ "$SYNC_RELEASE_MODE" == "1" ]]; then
  cp "$SYNC_PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
  # Browser-downloaded profiles carry quarantine metadata. If it is copied into
  # the locally built bundle, Gatekeeper treats this development app as an
  # internet-distributed, unnotarized app and kills it before main() runs.
  /usr/bin/xattr -c "$APP_CONTENTS/embedded.provisionprofile" 2>/dev/null || true
  if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
      --entitlements "$SYNC_RESOLVED_ENTITLEMENTS" "$APP_BUNDLE"
  else
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
      --entitlements "$SYNC_RESOLVED_ENTITLEMENTS" "$APP_BUNDLE"
  fi
else
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"
fi
# On File Provider-backed workspaces, codesign itself can cause provenance
# metadata to be re-applied to newly written signature files. Removing it after
# signing does not change the code signature and prevents dyld launch stalls.
/usr/bin/xattr -dr com.apple.provenance "$APP_BUNDLE" 2>/dev/null || true

# Run from the stable installed location. LaunchServices can refuse or stall on
# app bundles inside File Provider-backed development folders, while the
# installed path also gives Keychain and notification permissions a stable home.
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
for attribute in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.macl com.apple.provenance com.apple.quarantine; do
  /usr/bin/xattr -dr "$attribute" "$INSTALLED_APP" 2>/dev/null || true
done
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"
if [[ "$SYNC_RELEASE_MODE" == "1" ]]; then
  verify_sync_signature "$INSTALLED_APP"
fi
for legacy_app in "${LEGACY_INSTALLED_APPS[@]}"; do
  rm -rf "$legacy_app"
done

open_app() {
  local open_arguments=()
  if [[ -f "$LOCAL_FEED_CONFIG" ]]; then
    chmod 600 "$LOCAL_FEED_CONFIG"
    open_arguments=(--args --import-feed-config "$LOCAL_FEED_CONFIG")
  fi
  /usr/bin/open -n "$INSTALLED_APP" "${open_arguments[@]}"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$EXECUTABLE_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == '$EXECUTABLE_NAME'"
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == '$BUNDLE_ID'"
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      # Match the executable name exactly. A full-command-line search can match
      # the build shell itself because its arguments contain the app path,
      # producing a false-positive launch verification.
      if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.5
    done
    echo "$APP_NAME did not remain running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
