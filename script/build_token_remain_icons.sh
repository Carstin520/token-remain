#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/design/source/token-remain-robot-states"
DUAL_ICON_DIR="$ROOT_DIR/design/source/token-remain-logo-redesign/selected-10-head-logo-states"
STATE_DIR="$ROOT_DIR/Sources/UsageDock/Resources/TokenRemainStates"
APP_ICON="$ROOT_DIR/Sources/UsageDock/Resources/TokenRemain.icns"
IOS_APP_ICON="$ROOT_DIR/apple/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
WATCH_APP_ICON_DIR="$ROOT_DIR/apple/WatchApp/Assets.xcassets/AppIcon.appiconset"
WATCH_APP_ICON="$WATCH_APP_ICON_DIR/AppIcon.png"
IOS_MASTER_ICON="$DUAL_ICON_DIR/app-icon-dual-calm.png"
MASTER_ICON="$DUAL_ICON_DIR/app-icon-dual-calm-macos.png"
ICONSET="$(mktemp -d)/TokenRemain.iconset"

cleanup() {
  rm -rf "$(dirname "$ICONSET")"
}
trap cleanup EXIT

xcrun swift "$ROOT_DIR/script/refine_token_remain_icons.swift" \
  "$SOURCE_DIR" "$STATE_DIR" "$IOS_APP_ICON"

# The app icon is the selected head-only pet with both provider meters. The
# state generator above still refreshes legacy mood assets, so re-apply the
# canonical dual-meter master before assembling platform icons.
sips -z 1024 1024 "$IOS_MASTER_ICON" --out "$IOS_APP_ICON" >/dev/null

mkdir -p "$WATCH_APP_ICON_DIR"
cp "$IOS_APP_ICON" "$WATCH_APP_ICON"

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
echo "Built mood states and dual-meter macOS, iOS, and watchOS app icons"
