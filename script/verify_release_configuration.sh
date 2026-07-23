#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/verify_distribution_model.sh

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" == "com.jamesli.usagedock" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' Resources/UsageDockSync.entitlements)" == "iCloud.com.jamesli.tokenremain" ]]

/usr/bin/grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER: com.jamesli.tokenremain' apple/project.yml
/usr/bin/grep -Fq 'APS_ENVIRONMENT: production' apple/project.yml
/usr/bin/grep -Fq 'ICLOUD_CONTAINER_ENVIRONMENT: Production' apple/project.yml
[[ "$(/usr/bin/grep -Fc 'TARGETED_DEVICE_FAMILY: "1"' apple/project.yml)" == "2" ]]

for manifest in \
  apple/App/PrivacyInfo.xcprivacy \
  apple/Widgets/PrivacyInfo.xcprivacy \
  apple/WatchApp/PrivacyInfo.xcprivacy \
  apple/WatchWidgets/PrivacyInfo.xcprivacy; do
  /usr/bin/plutil -lint "$manifest" >/dev/null
  /usr/bin/grep -Fq 'NSPrivacyAccessedAPICategoryUserDefaults' "$manifest"
  /usr/bin/grep -Fq '1C8F.1' "$manifest"
done
/usr/bin/grep -Fq 'CA92.1' apple/App/PrivacyInfo.xcprivacy

/bin/bash -n script/build_and_run.sh
/bin/bash -n script/package_developer_id_release.sh
/bin/bash -n script/package_app_store_release.sh

echo "release configuration verified: paid iOS + production Apple capabilities + Developer ID packaging guardrails"
