#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$ROOT_DIR/Resources/Info.plist")"
BINARY="$ROOT_DIR/Vendor/ccusage/$VERSION/darwin-arm64/ccusage"
LICENSE="$ROOT_DIR/Vendor/ccusage/LICENSE"
SERVICE="$ROOT_DIR/Sources/UsageDock/Services/CCUsageService.swift"
PRICING_SERVICE="$ROOT_DIR/Sources/UsageDock/Services/CCUsagePricingService.swift"
UPDATE_CHECKER="$ROOT_DIR/Sources/UsageDock/Services/CCUsageUpdateChecker.swift"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
EXPECTED_SHA256="3179f6cabbd4bafe55946f2013c9e2ec3cdfb59fd8c152f3d2f3c7f2adaac6c5"

fail() {
  echo "bundled ccusage contract verification failed: $*" >&2
  exit 1
}

[[ -x "$BINARY" ]] || fail "vendored ccusage binary is missing or not executable"
[[ -r "$LICENSE" ]] || fail "vendored ccusage MIT license is missing"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$BINARY" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || fail "vendored binary checksum changed"

/usr/bin/file "$BINARY" | /usr/bin/grep -Fq 'Mach-O 64-bit executable arm64' \
  || fail "vendored binary is not a macOS arm64 executable"
[[ "$("$BINARY" --version)" == "ccusage $VERSION" ]] \
  || fail "vendored binary version does not match $VERSION"

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
/usr/bin/grep -Fq 'registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest' "$UPDATE_CHECKER" \
  || fail "runtime ccusage version check no longer uses the official npm package metadata"
/usr/bin/grep -Fq 'unpricedModels' "$SERVICE" \
  || fail "ccusage parser no longer preserves missing-price model identifiers"

echo "bundled ccusage contract verified: daily public price cache + native $VERSION offline collection"
