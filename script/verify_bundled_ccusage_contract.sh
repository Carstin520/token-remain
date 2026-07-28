#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$ROOT_DIR/Resources/Info.plist")"
ARM_BINARY="$ROOT_DIR/Vendor/ccusage/$VERSION/darwin-arm64/ccusage"
X64_BINARY="$ROOT_DIR/Vendor/ccusage/$VERSION/darwin-x64/ccusage"
UNIVERSAL_BINARY="$ROOT_DIR/Vendor/ccusage/$VERSION/darwin-universal/ccusage"
LICENSE="$ROOT_DIR/Vendor/ccusage/LICENSE"
CHECKSUM_FILE="$ROOT_DIR/Vendor/ccusage/SHA256"
SERVICE="$ROOT_DIR/Sources/UsageDock/Services/CCUsageService.swift"
PRICING_SERVICE="$ROOT_DIR/Sources/UsageDock/Services/CCUsagePricingService.swift"
UPDATE_SCRIPT="$ROOT_DIR/script/verify_ccusage_freshness.sh"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
RELEASE_SCRIPT="$ROOT_DIR/script/package_developer_id_release.sh"
RELEASE_CONFIGURATION="$ROOT_DIR/script/verify_release_configuration.sh"

fail() {
  echo "bundled ccusage contract verification failed: $*" >&2
  exit 1
}

[[ -x "$ARM_BINARY" ]] || fail "vendored arm64 ccusage binary is missing or not executable"
[[ -x "$X64_BINARY" ]] || fail "vendored x86_64 ccusage binary is missing or not executable"
[[ -x "$UNIVERSAL_BINARY" ]] || fail "vendored universal ccusage binary is missing or not executable"
[[ -r "$LICENSE" ]] || fail "vendored ccusage MIT license is missing"
[[ -r "$CHECKSUM_FILE" ]] || fail "vendored checksum manifest is missing"
[[ "$(/usr/bin/wc -l < "$CHECKSUM_FILE" | /usr/bin/tr -d '[:space:]')" == "3" ]] \
  || fail "vendored checksum manifest must contain exactly three entries"
(cd "$ROOT_DIR/Vendor/ccusage" && /usr/bin/shasum -a 256 -c SHA256) \
  || fail "vendored ccusage checksum verification failed"

[[ "$(/usr/bin/lipo "$ARM_BINARY" -archs)" == "arm64" ]] \
  || fail "vendored arm64 helper has an unexpected architecture"
[[ "$(/usr/bin/lipo "$X64_BINARY" -archs)" == "x86_64" ]] \
  || fail "vendored x86_64 helper has an unexpected architecture"
/usr/bin/lipo "$UNIVERSAL_BINARY" -verify_arch arm64 x86_64 \
  || fail "vendored universal helper is missing arm64 or x86_64"
[[ "$("$UNIVERSAL_BINARY" --version)" == "ccusage $VERSION" ]] \
  || fail "vendored universal helper version does not match $VERSION"

/usr/bin/grep -Fq '"--offline"' "$SERVICE" \
  || fail "ccusage must run without pricing-network access"
/usr/bin/grep -Fq 'pricingService.configurationURL' "$SERVICE" \
  || fail "ccusage no longer receives the validated app-owned pricing config"
if /usr/bin/grep -Eq 'npx|ccusage@latest|/bin/zsh' "$SERVICE"; then
  fail "runtime ccusage collection must not depend on Node, npm, or a login shell"
fi
if /usr/bin/grep -Fq '"--no-offline"' "$SERVICE"; then
  fail "runtime ccusage collection must never enable helper networking"
fi

/usr/bin/grep -Fq \
  'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json' \
  "$PRICING_SERVICE" \
  || fail "public pricing refresh no longer uses the fixed LiteLLM table"
/usr/bin/grep -Fq 'request.httpMethod = "GET"' "$PRICING_SERVICE" \
  || fail "public pricing refresh must remain a GET"
/usr/bin/grep -Fq 'request.httpBody = nil' "$PRICING_SERVICE" \
  || fail "public pricing refresh must not upload a request body"
/usr/bin/grep -Fq 'static let refreshInterval: TimeInterval = 24 * 60 * 60' "$PRICING_SERVICE" \
  || fail "public pricing refresh must retain its daily cadence"
/usr/bin/grep -Fq 'pricingOverrides' "$PRICING_SERVICE" \
  || fail "validated public prices are no longer converted to ccusage overrides"

/usr/bin/grep -Fq 'Contents/Helpers/ccusage' "$BUILD_SCRIPT" \
  || fail "build script does not package the ccusage helper"
/usr/bin/grep -Fq 'sign_embedded_ccusage' "$BUILD_SCRIPT" \
  || fail "build script does not sign the nested ccusage helper"
/usr/bin/grep -Fq 'darwin-universal/ccusage' "$BUILD_SCRIPT" \
  || fail "build script does not package the universal ccusage helper"
/usr/bin/grep -Fq -- '--arch arm64 --arch x86_64' "$BUILD_SCRIPT" \
  || fail "build script does not produce a universal application executable"
/usr/bin/grep -Fq 'registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest' "$UPDATE_SCRIPT" \
  || fail "release freshness check no longer uses official npm package metadata"
/usr/bin/grep -Fq 'registry.npmjs.org/%40ccusage%2Fccusage-darwin-x64/latest' "$UPDATE_SCRIPT" \
  || fail "release freshness check no longer verifies the official x86_64 package"
/usr/bin/grep -Fq 'verify_ccusage_freshness.sh" --update' "$RELEASE_SCRIPT" \
  || fail "release packaging no longer updates ccusage before building"
/usr/bin/grep -Fq 'verify_ccusage_freshness.sh --update' "$RELEASE_CONFIGURATION" \
  || fail "release preflight no longer updates ccusage before validation"
/usr/bin/grep -Fq 'Commit and push the verified helper update before packaging' "$RELEASE_SCRIPT" \
  || fail "release packaging may continue with an uncommitted helper update"
if /usr/bin/grep -R -Fq 'ccusage-darwin-arm64/latest' "$ROOT_DIR/Sources"; then
  fail "runtime code must not query ccusage package versions"
fi
/usr/bin/grep -Fq 'unpricedModels' "$SERVICE" \
  || fail "ccusage parser no longer preserves missing-price model identifiers"

echo "bundled ccusage contract verified: universal $VERSION offline collection + daily public price cache"
