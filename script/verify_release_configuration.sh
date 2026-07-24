#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/verify_version_consistency.sh
./script/verify_distribution_model.sh
./script/verify_automatic_sync_contract.sh
./script/verify_automatic_update_contract.sh
./script/verify_installation_isolation.sh

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" == "com.jamesli.usagedock" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' Resources/UsageDockSync.entitlements)" == "iCloud.com.jamesli.tokenremain" ]]

/usr/bin/grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER: com.jamesli.tokenremain' apple/project.yml
/usr/bin/grep -Fq 'APS_ENVIRONMENT: production' apple/project.yml
/usr/bin/grep -Fq 'ICLOUD_CONTAINER_ENVIRONMENT: Production' apple/project.yml
[[ "$(/usr/bin/grep -Fc 'TARGETED_DEVICE_FAMILY: "1"' apple/project.yml)" == "2" ]]

# Export compliance is still an explicit Account Holder gate. Until the
# CryptoKit AES-GCM determination is confirmed in App Store Connect, the source
# configuration must not silently claim either exempt or non-exempt status.
if /usr/bin/grep -Eq \
  'ITSAppUsesNonExemptEncryption|ITSEncryptionExportComplianceCode|INFOPLIST_KEY_ITSAppUsesNonExemptEncryption' \
  apple/project.yml apple/SupportFiles/TokenRemain-Info.plist; then
  echo "error: export-compliance Info.plist state was set before the recorded Account Holder determination" >&2
  exit 1
fi

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
/bin/bash -n script/verify_automatic_update_contract.sh
/bin/bash -n script/verify_installation_isolation.sh
/bin/bash -n script/verify_version_consistency.sh

echo "pre-upload release configuration verified: paid iOS + production Apple capabilities + Developer ID packaging guardrails"
echo "external gate remains: confirm CryptoKit export compliance before setting the release Info.plist key and uploading"
