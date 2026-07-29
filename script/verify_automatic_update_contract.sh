#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

fail() {
  echo "automatic update contract verification failed: $*" >&2
  exit 1
}

[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" \
  == "https://github.com/Carstin520/token-remain/releases/latest/download/appcast.xml" ]] \
  || fail "the production appcast URL is not pinned"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")" ]] \
  || fail "the Sparkle public EdDSA key is missing"

for key in \
  SUVerifyUpdateBeforeExtraction \
  SURequireSignedFeed; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")" == "true" ]] \
    || fail "$key must be enabled"
done

for key in \
  SUEnableAutomaticChecks \
  SUAutomaticallyUpdate \
  SUAllowsAutomaticUpdates; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")" == "false" ]] \
    || fail "$key must be disabled so no stale update is downloaded or pinned"
done

if /usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$INFO_PLIST" >/dev/null 2>&1; then
  fail "Sparkle's automatic schedule must not compete with the adaptive probe schedule"
fi
if /usr/libexec/PlistBuddy -c 'Print :SUScheduledImpatientCheckInterval' "$INFO_PLIST" >/dev/null 2>&1; then
  fail "the fixed impatient interval must not pin an already discovered update"
fi

/usr/bin/grep -Fq '.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")' \
  "$ROOT_DIR/Package.swift" \
  || fail "Sparkle dependency is not exactly pinned"
/usr/bin/grep -Fq 'SPUStandardUpdaterController(' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the production updater controller is missing"
/usr/bin/grep -Fq 'updaterDelegate: self' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the adaptive updater delegate is missing"
/usr/bin/grep -Fq 'controller.updater.automaticallyChecksForUpdates = false' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "legacy automatic-check preferences are not disabled"
/usr/bin/grep -Fq 'controller.updater.automaticallyDownloadsUpdates = false' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "legacy automatic-download preferences are not disabled"
/usr/bin/grep -Fq 'updater.checkForUpdateInformation()' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "background checks must be non-downloading information probes"
/usr/bin/grep -Fq 'updaterController.checkForUpdates(nil)' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the user action must perform a fresh latest-version check"
/usr/bin/grep -Fq 'static let noUpdateInterval: TimeInterval = 6 * 60 * 60' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the bounded current-version probe interval is missing"
/usr/bin/grep -Fq 'static let updateAvailableInterval: TimeInterval = 12 * 60 * 60' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the quiet pending-update recheck interval is missing"
/usr/bin/grep -Fq 'supportsGentleScheduledUpdateReminders' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "the gentle scheduled update reminder is missing"
/usr/bin/grep -Fq 'removeOlderStableCopiesAfterRelaunch' \
  "$ROOT_DIR/Sources/UsageDock/Services/AppUpdateController.swift" \
  || fail "post-update stale installation cleanup is missing"
/usr/bin/grep -Fq 'appUpdater.presentAvailableUpdate()' \
  "$ROOT_DIR/Sources/UsageDock/Views/Dashboard/DashboardView.swift" \
  || fail "the Dashboard update action is missing"
/usr/bin/grep -Fq '#if TOKENREMAIN_CLOUD_SYNC' \
  "$ROOT_DIR/Sources/UsageDock/App/UsageDockApp.swift" \
  || fail "the updater is not isolated to production sync builds"
/usr/bin/grep -Fq 'sign_embedded_sparkle' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "Sparkle nested-code signing is not part of packaging"
/usr/bin/grep -Fq 'generate_update_feed' "$ROOT_DIR/script/package_developer_id_release.sh" \
  || fail "release packaging does not generate a signed appcast"
/usr/bin/grep -Fq 'trap cleanup_release_artifacts EXIT' \
  "$ROOT_DIR/script/package_developer_id_release.sh" \
  || fail "release packaging can leave an expanded app registered"

echo "automatic update contract verified: adaptive signed probes + fresh latest install check + gentle reminder"
