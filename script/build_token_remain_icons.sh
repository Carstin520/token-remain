#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ICON="$ROOT_DIR/Sources/UsageDock/Resources/TokenRemain.icns"
WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/TokenRemain.iconset"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Expressions and full-body robots have a separate, explicit generation entry.
# This icon-only command must never rewrite TokenRemainStates or HeadStates.
xcrun swiftc "$ROOT_DIR/Sources/UsageDock/Views/DotRingIconArtwork.swift" \
  "$ROOT_DIR/script/render_dot_ring_icons.swift" -o "$WORK_DIR/render-icons"
"$WORK_DIR/render-icons" "$WORK_DIR/images" \
  "$ROOT_DIR/design/source/token-remain-dot-ring-head/native-lighting"

mkdir -p "$ICONSET"
cp "$WORK_DIR/images/small-dock-16.png" "$ICONSET/icon_16x16.png"
cp "$WORK_DIR/images/medium-dock-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$WORK_DIR/images/medium-dock-32.png" "$ICONSET/icon_32x32.png"
for entry in '32x32@2x:64' '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' '512x512:512' '512x512@2x:1024'; do
  cp "$WORK_DIR/images/full-dock-${entry##*:}.png" "$ICONSET/icon_${entry%:*}.png"
done
iconutil -c icns "$ICONSET" -o "$APP_ICON"

# Full-bleed website/window master plus dedicated ICO/tray sources.
cp "$WORK_DIR/images/full-tile-512.png" "$ROOT_DIR/site/assets/brand/appicon-mac.png"
cp "$WORK_DIR/images/medium-tile-256.png" "$ROOT_DIR/site/assets/brand/appicon-medium.png"
cp "$WORK_DIR/images/small-tile-256.png" "$ROOT_DIR/site/assets/brand/appicon-small.png"
echo "Built O4-C size-adapted icns and website/Windows sources; expression assets untouched"
