#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/.build-app-store-candidate"
DIST_ROOT="$ROOT_DIR/dist-app-store-candidate"
BASELINE_APP="$DIST_ROOT/TokenRemain Provider Audit Baseline.app"
CANDIDATE_APP="$DIST_ROOT/TokenRemain App Store Candidate.app"
PRODUCT_NAME="UsageDock"
BASELINE_EXECUTABLE="UsageDockProviderAuditBaseline"
CANDIDATE_EXECUTABLE="UsageDockAppStoreCandidate"
ENTITLEMENTS="$ROOT_DIR/Resources/UsageDockAppStoreCandidate.entitlements"
SIGNING_IDENTITY="${TOKENREMAIN_APP_STORE_SIGNING_IDENTITY:-}"
BROADCAST_BASE_URL="${TOKENREMAIN_BROADCAST_BASE_URL:-https://tokenremain-broadcast.jamescarstin520.workers.dev}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -r "$ENTITLEMENTS" ]]; then
  echo "Missing App Store candidate entitlements: $ENTITLEMENTS" >&2
  exit 1
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -n 1)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "An Apple Development signing identity is required for the local Sandbox audit." >&2
  exit 1
fi

stage_bundle() {
  local app_bundle="$1"
  local executable_name="$2"
  local build_binary="$3"
  local app_contents="$app_bundle/Contents"
  local app_macos="$app_contents/MacOS"
  local app_resources="$app_contents/Resources"

  rm -rf "$app_bundle"
  mkdir -p "$app_macos" "$app_resources"
  cp "$build_binary" "$app_macos/$executable_name"
  cp "$ROOT_DIR/Resources/Info.plist" "$app_contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" "$app_contents/Info.plist"
  if [[ -n "$BROADCAST_BASE_URL" ]]; then
    if [[ "$BROADCAST_BASE_URL" != https://* ]]; then
      echo "TOKENREMAIN_BROADCAST_BASE_URL must use HTTPS." >&2
      exit 2
    fi
    /usr/libexec/PlistBuddy \
      -c "Add :TokenRemainBroadcastBaseURL string $BROADCAST_BASE_URL" \
      "$app_contents/Info.plist"
  fi
  cp "$ROOT_DIR/Sources/UsageDock/Resources/claude.png" "$app_resources/claude.png"
  cp "$ROOT_DIR/Sources/UsageDock/Resources/openai.png" "$app_resources/openai.png"
  cp "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemain.icns" "$app_resources/TokenRemain.icns"
  cp -R "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainHeadStates" "$app_resources/"
  cp -R "$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainFullBodyStates" "$app_resources/"
  for localization in "$ROOT_DIR/Sources/UsageDock/Localization/"*.lproj; do
    cp -R "$localization" "$app_resources/"
  done
  chmod +x "$app_macos/$executable_name"
  for attribute in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.macl com.apple.provenance com.apple.quarantine; do
    /usr/bin/xattr -dr "$attribute" "$app_bundle" 2>/dev/null || true
  done
}

verify_candidate_entitlements() {
  local app_bundle="$1"
  local extracted
  extracted="$(mktemp "${TMPDIR:-/tmp}/tokenremain-app-store-entitlements.XXXXXX")"
  /usr/bin/codesign -d --entitlements :- "$app_bundle" > "$extracted" 2>/dev/null
  for key in \
    com.apple.security.app-sandbox \
    com.apple.security.network.client \
    com.apple.security.files.user-selected.read-only \
    com.apple.security.files.bookmarks.app-scope; do
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$extracted" 2>/dev/null || true)" != "true" ]]; then
      echo "Candidate signature is missing required entitlement: $key" >&2
      rm -f "$extracted"
      exit 1
    fi
  done
  if [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.aps-environment' \
    "$extracted" 2>/dev/null || true)" != "development" ]]; then
    echo "Candidate signature is missing the development APNs entitlement." >&2
    rm -f "$extracted"
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.home-relative-path.read-only' "$extracted" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.absolute-path.read-only' "$extracted" >/dev/null 2>&1; then
    echo "Candidate must not use temporary-path exception entitlements." >&2
    rm -f "$extracted"
    exit 1
  fi
  rm -f "$extracted"
}

mkdir -p "$DIST_ROOT"
swift build \
  --scratch-path "$BUILD_ROOT" \
  --product "$PRODUCT_NAME" \
  -Xswiftc -DTOKENREMAIN_APP_STORE_CANDIDATE
BUILD_BINARY="$(swift build --scratch-path "$BUILD_ROOT" --show-bin-path)/$PRODUCT_NAME"

stage_bundle "$BASELINE_APP" "$BASELINE_EXECUTABLE" "$BUILD_BINARY"
stage_bundle "$CANDIDATE_APP" "$CANDIDATE_EXECUTABLE" "$BUILD_BINARY"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$BASELINE_APP"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$CANDIDATE_APP"
/usr/bin/codesign --verify --deep --strict "$BASELINE_APP"
/usr/bin/codesign --verify --deep --strict "$CANDIDATE_APP"
verify_candidate_entitlements "$CANDIDATE_APP"

case "$MODE" in
  build)
    printf '%s\n' "$CANDIDATE_APP"
    ;;
  audit)
    "$BASELINE_APP/Contents/MacOS/$BASELINE_EXECUTABLE" \
      --provider-compatibility-audit --audit-environment unsandboxed-baseline
    "$CANDIDATE_APP/Contents/MacOS/$CANDIDATE_EXECUTABLE" \
      --provider-compatibility-audit --audit-environment app-sandbox-candidate
    ;;
  *)
    echo "usage: $0 [build|audit]" >&2
    exit 2
    ;;
esac
