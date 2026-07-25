#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/design/source/token-remain-robot-states"
DUAL_ICON_DIR="$ROOT_DIR/design/source/token-remain-logo-redesign/selected-10-head-logo-states"
STATE_DIR="$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainStates"
APP_ICON="$ROOT_DIR/Sources/UsageDock/Resources/TokenRemain.icns"
MASTER_ICON="$DUAL_ICON_DIR/app-icon-dual-calm-macos.png"
ICONSET="$(mktemp -d)/TokenRemain.iconset"

cleanup() {
  rm -rf "$(dirname "$ICONSET")"
}
trap cleanup EXIT

xcrun swift "$ROOT_DIR/script/refine_token_remain_icons.swift" \
  "$SOURCE_DIR" "$STATE_DIR"

mkdir -p "$ICONSET"
sips -z 16 16 "$MASTER_ICON" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$MASTER_ICON" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$MASTER_ICON" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$MASTER_ICON" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$MASTER_ICON" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$MASTER_ICON" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$MASTER_ICON" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$MASTER_ICON" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$MASTER_ICON" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$MASTER_ICON" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$APP_ICON"
echo "Built mood states and the dual-meter macOS app icon"
