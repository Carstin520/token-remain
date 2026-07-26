#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$ROOT_DIR/Resources/Info.plist")"
BINARY="$ROOT_DIR/Vendor/ccusage/$VERSION/darwin-arm64/ccusage"
LICENSE="$ROOT_DIR/Vendor/ccusage/LICENSE"
SERVICE="$ROOT_DIR/Sources/UsageDock/Services/CCUsageService.swift"
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
if /usr/bin/grep -Eq 'npx|ccusage@latest|/bin/zsh' "$SERVICE"; then
  fail "runtime ccusage collection must not depend on Node, npm, or a login shell"
fi

/usr/bin/grep -Fq 'Contents/Helpers/ccusage' "$BUILD_SCRIPT" \
  || fail "build script does not package the ccusage helper"
/usr/bin/grep -Fq 'sign_embedded_ccusage' "$BUILD_SCRIPT" \
  || fail "build script does not sign the nested ccusage helper"
/usr/bin/grep -Fq 'registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest' "$UPDATE_CHECKER" \
  || fail "runtime ccusage version check no longer uses the official npm package metadata"
/usr/bin/grep -Fq 'unpricedModels' "$SERVICE" \
  || fail "ccusage parser no longer preserves missing-price model identifiers"

echo "bundled ccusage contract verified: native $VERSION arm64 helper + offline single-process collection"
