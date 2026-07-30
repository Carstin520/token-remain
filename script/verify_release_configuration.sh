#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/verify_version_consistency.sh
./script/verify_automatic_update_contract.sh
./script/verify_installation_isolation.sh
./script/verify_ccusage_freshness.sh --update
./script/verify_bundled_ccusage_contract.sh
./script/verify_ccusage_freshness.sh --local
./script/verify_keychain_read_contract.sh
./script/verify_website_release_contract.sh

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" == "com.jamesli.usagedock" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' Resources/UsageDockSync.entitlements)" == "iCloud.com.jamesli.tokenremain" ]]

/bin/bash -n script/build_and_run.sh
/bin/bash -n script/package_developer_id_release.sh
/usr/bin/grep -Fq 'SWIFT_BUILD_ARGS+=(--configuration release)' script/build_and_run.sh
/usr/bin/grep -Fq 'TokenRemain-$VERSION-$BUILD.dmg' script/package_developer_id_release.sh
/usr/bin/grep -Fq '/usr/bin/cmp -s "$DMG" "$VERSIONED_DMG"' script/package_developer_id_release.sh
SYNC_SUCCESS_MARKER='Private sync source upload succeeded'
/usr/bin/grep -Fq "$SYNC_SUCCESS_MARKER" Sources/UsageDock/Sync/CrossDeviceSyncController.swift
/usr/bin/grep -Fq "$SYNC_SUCCESS_MARKER" script/build_and_run.sh
/bin/bash -n script/verify_automatic_update_contract.sh
/bin/bash -n script/verify_installation_isolation.sh
/bin/bash -n script/verify_bundled_ccusage_contract.sh
/bin/bash -n script/verify_ccusage_freshness.sh
/bin/bash -n script/verify_keychain_read_contract.sh
/bin/bash -n script/verify_version_consistency.sh
/bin/bash -n script/verify_website_release_contract.sh

echo "desktop release configuration verified: version, updater, packaging, privacy, and website contracts"
