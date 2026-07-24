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
  SUEnableAutomaticChecks \
  SUAutomaticallyUpdate \
  SUAllowsAutomaticUpdates \
  SUVerifyUpdateBeforeExtraction \
  SURequireSignedFeed; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")" == "true" ]] \
    || fail "$key must be enabled"
done

[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$INFO_PLIST")" == "3600" ]] \
  || fail "automatic checks must use Sparkle's one-hour minimum interval"

/usr/bin/grep -Fq '.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")' \
  "$ROOT_DIR/Package.swift" \
  || fail "Sparkle dependency is not exactly pinned"
/usr/bin/grep -Fq 'private let updaterController = SPUStandardUpdaterController(' \
  "$ROOT_DIR/Sources/UsageDock/App/UsageDockApp.swift" \
  || fail "the production updater controller is missing"
/usr/bin/grep -Fq '#if TOKENREMAIN_CLOUD_SYNC' \
  "$ROOT_DIR/Sources/UsageDock/App/UsageDockApp.swift" \
  || fail "the updater is not isolated to production sync builds"
/usr/bin/grep -Fq 'sign_embedded_sparkle' "$ROOT_DIR/script/build_and_run.sh" \
  || fail "Sparkle nested-code signing is not part of packaging"
/usr/bin/grep -Fq 'generate_update_feed' "$ROOT_DIR/script/package_developer_id_release.sh" \
  || fail "release packaging does not generate a signed appcast"

echo "automatic update contract verified: signed feed + production-only updater + silent defaults"
