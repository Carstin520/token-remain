#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "automatic sync contract verification failed: $1" >&2
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
  if /usr/bin/grep -Eq -- "$pattern" "$@"; then
    fail "manual-first sync UI returned (matched '$pattern')"
  fi
}

MAC_CONTROLLER="$ROOT_DIR/Sources/UsageDock/Sync/CrossDeviceSyncController.swift"
MAC_APP="$ROOT_DIR/Sources/UsageDock/App/UsageDockApp.swift"
MAC_SETTINGS="$ROOT_DIR/Sources/UsageDock/Sync/CrossDeviceSyncSettingsCard.swift"
MAC_TEST="$ROOT_DIR/Tests/UsageDockTests/CrossDeviceSyncDefaultsTests.swift"

IOS_SETTINGS_STORE="$ROOT_DIR/apple/Packages/TokenRemainKit/Sources/TokenRemainKit/Snapshot/SnapshotStore.swift"
IOS_APP="$ROOT_DIR/apple/App/TokenRemainApp.swift"
IOS_SETTINGS="$ROOT_DIR/apple/App/Tabs/SettingsTab.swift"
IOS_POLICY="$ROOT_DIR/apple/App/Sync/MobileSyncHealthPolicy.swift"
IOS_TEST="$ROOT_DIR/apple/AppTests/MobileSyncClientTests.swift"

# Fresh installations join the private CloudKit path automatically. A stored
# user choice still wins, so explicitly turning sync off remains durable.
require_literal '?? true' "$MAC_CONTROLLER"
require_literal '?? .macSync' "$IOS_SETTINGS_STORE"
require_literal 'A fresh Mac installation enables private sync automatically' "$MAC_TEST"
require_literal 'A fresh installation enables private Mac sync without setup' "$IOS_TEST"

# Both apps self-check without a settings-screen action. Account changes trigger
# another check, and the visible iPhone loop reconciles missed/coalesced pushes.
require_literal 'func applicationDidBecomeActive' "$MAC_APP"
require_literal 'CrossDeviceSyncController.shared.checkNow()' "$MAC_APP"
require_literal 'NotificationCenter.default.publisher(for: .CKAccountChanged)' "$MAC_CONTROLLER"
require_literal 'NotificationCenter.default.publisher(for: .CKAccountChanged)' "$IOS_APP"
require_literal '.task(id: ForegroundSyncTaskID(' "$IOS_APP"
require_literal 'await model.pullMacSync()' "$IOS_APP"

# Preserve the bounded fast-retry sequence before the 45-second foreground
# reconciliation interval.
require_literal 'private static let initialRetryDelays: [TimeInterval] = [2, 5, 10, 30, 60]' "$IOS_POLICY"
require_literal 'return 45' "$IOS_POLICY"
require_literal 'Automatic health checks use fast retries before steady reconciliation' "$IOS_TEST"

# Retry buttons are allowed as recovery controls, but the primary settings UI
# must not regress to a manual "pull/sync now" workflow.
require_absent \
  'settings\.macsync\.refresh|sync\.action\.sync_now' \
  "$MAC_SETTINGS" "$IOS_SETTINGS"

echo "automatic sync contract verified: fresh-install defaults + self-checks + CloudKit listeners + bounded retries"
