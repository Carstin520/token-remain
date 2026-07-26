#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
PACKAGE="@ccusage/ccusage-darwin-arm64"
REGISTRY_URL="https://registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$INFO_PLIST")"
BINARY="$ROOT_DIR/Vendor/ccusage/$INSTALLED_VERSION/darwin-arm64/ccusage"

fail() {
  echo "ccusage freshness verification failed: $*" >&2
  exit 1
}

[[ -x "$BINARY" ]] || fail "missing vendored $INSTALLED_VERSION binary"
[[ "$("$BINARY" --version)" == "ccusage $INSTALLED_VERSION" ]] \
  || fail "Info.plist and vendored binary versions differ"

if [[ "${1:-}" == "--local" ]]; then
  echo "ccusage local version contract verified: $INSTALLED_VERSION"
  exit 0
fi

METADATA="$(/usr/bin/curl --fail --silent --show-error --max-time 15 \
  -H 'Accept: application/json' "$REGISTRY_URL")" \
  || fail "official npm package metadata is unavailable"
LATEST_PACKAGE="$(printf '%s' "$METADATA" | /usr/bin/plutil -extract name raw -o - -)"
LATEST_VERSION="$(printf '%s' "$METADATA" | /usr/bin/plutil -extract version raw -o - -)"
[[ "$LATEST_PACKAGE" == "$PACKAGE" ]] || fail "registry returned $LATEST_PACKAGE"
[[ "$LATEST_VERSION" == "$INSTALLED_VERSION" ]] \
  || fail "bundled $INSTALLED_VERSION is stale; official latest is $LATEST_VERSION"

echo "ccusage freshness verified against npm: $INSTALLED_VERSION is latest"
