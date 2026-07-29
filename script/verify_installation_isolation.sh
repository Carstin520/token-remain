#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"

fail() {
  echo "installation isolation verification failed: $1" >&2
  exit 1
}

require_contract_value() {
  local output="$1"
  local expected="$2"
  /usr/bin/grep -Fqx -- "$expected" <<<"$output" \
    || fail "missing contract value '$expected'"
}

dev_contract="$("$BUILD_SCRIPT" --print-install-contract)"
sync_contract="$(USAGEDOCK_SYNC_RELEASE=1 "$BUILD_SCRIPT" --print-install-contract)"

require_contract_value "$dev_contract" "sync_release=0"
require_contract_value "$dev_contract" "app_name=TokenRemain Dev"
require_contract_value "$dev_contract" "executable=UsageDockDev"
require_contract_value "$dev_contract" "bundle_id=com.jamesli.usagedock.dev"
require_contract_value "$dev_contract" \
  "installed_app=/Users/jamesli/Applications/TokenRemain Dev.app"
require_contract_value "$dev_contract" \
  "stable_sync_app=/Users/jamesli/Applications/TokenRemain.app"

require_contract_value "$sync_contract" "sync_release=1"
require_contract_value "$sync_contract" "app_name=TokenRemain"
require_contract_value "$sync_contract" "executable=UsageDock"
require_contract_value "$sync_contract" "bundle_id=com.jamesli.usagedock"
require_contract_value "$sync_contract" \
  "installed_app=/Users/jamesli/Applications/TokenRemain.app"

if [[ "$dev_contract" == *"installed_app=/Users/jamesli/Applications/TokenRemain.app"* ]]; then
  fail "development mode can still overwrite the stable sync app"
fi

/usr/bin/grep -Fq 'verify_bundle_for_mode "$APP_BUNDLE"' "$BUILD_SCRIPT" \
  || fail "staged bundles are not verified before installation"
/usr/bin/grep -Fq 'verify_bundle_for_mode "$INCOMING_APP"' "$BUILD_SCRIPT" \
  || fail "incoming bundles are not verified before replacement"
/usr/bin/grep -Fq 'Private sync source upload succeeded' "$BUILD_SCRIPT" \
  || fail "sync binary marker verification is missing"

echo "installation isolation verified: development and sync builds use protected paths"
