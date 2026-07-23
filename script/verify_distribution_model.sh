#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "distribution model verification failed: $1" >&2
  exit 1
}

require_literal() {
  local literal="$1"
  local file="$2"
  /usr/bin/grep -Fq -- "$literal" "$file" \
    || fail "missing '$literal' in ${file#"$ROOT_DIR/"}"
}

require_absent() {
  local pattern="$1"
  shift
  if /usr/bin/grep -RIEq --exclude-dir=.build --exclude-dir=DerivedData \
    -- "$pattern" "$@"; then
    fail "unexpected commercial entitlement implementation matching '$pattern'"
  fi
}

require_literal "PRODUCT_BUNDLE_IDENTIFIER: com.jamesli.tokenremain" \
  "$ROOT_DIR/apple/project.yml"
require_literal "Release:" "$ROOT_DIR/apple/project.yml"
require_literal "APS_ENVIRONMENT: production" "$ROOT_DIR/apple/project.yml"
require_literal "ICLOUD_CONTAINER_ENVIRONMENT: Production" \
  "$ROOT_DIR/apple/project.yml"
require_literal "<string>com.jamesli.usagedock</string>" \
  "$ROOT_DIR/Resources/Info.plist"
require_literal "com.apple.security.app-sandbox" \
  "$ROOT_DIR/Resources/UsageDockAppStoreCandidate.entitlements"

if /usr/bin/grep -Fq -- "com.apple.security.app-sandbox" \
  "$ROOT_DIR/Resources/UsageDockSync.entitlements"; then
  fail "website Mac sync entitlements unexpectedly enable App Sandbox"
fi

require_absent \
  'tokenremain\.pro\.sync\.lifetime|Transaction\.currentEntitlements|AppStore\.sync\(|Product\.products\(' \
  "$ROOT_DIR/Sources" "$ROOT_DIR/apple/App" "$ROOT_DIR/apple/Widgets" \
  "$ROOT_DIR/apple/WatchApp" "$ROOT_DIR/apple/WatchWidgets"

echo "distribution model verified: paid iOS download + unsandboxed Developer ID Mac"
