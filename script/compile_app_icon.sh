#!/usr/bin/env bash
set -euo pipefail

# Compiles the Icon Composer app icon (Resources/AppIcon.icon) into the
# bundle's Assets.car. macOS 26 and later read it through CFBundleIconName and
# draw it with the system icon shape; without it they set the legacy icns on a
# generic backing tile. Older systems keep using CFBundleIconFile
# (TokenRemain.icns), whose full-resolution artwork is better than the 256 px
# icns actool would emit as a fallback, so only Assets.car is installed.
#
# usage: compile_app_icon.sh <bundle Resources dir> [--required]
#   --required  fail when actool is unavailable (release builds); otherwise a
#               missing Xcode only warns and the bundle keeps the legacy icon.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:?usage: compile_app_icon.sh <bundle Resources dir> [--required]}"
REQUIRED="${2:-}"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icon"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT_DIR/Resources/Info.plist")"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! /usr/bin/xcrun --find actool >/dev/null 2>&1; then
  if [[ "$REQUIRED" == "--required" ]]; then
    echo "actool (Xcode 26 or later) is required to compile $ICON_SOURCE." >&2
    exit 1
  fi
  echo "warning: actool not found; the bundle keeps only the legacy icns icon." >&2
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

/usr/bin/xcrun actool "$ICON_SOURCE" \
  --compile "$WORK_DIR" \
  --platform macosx \
  --minimum-deployment-target "$MINIMUM_SYSTEM_VERSION" \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK_DIR/partial.plist" \
  --errors --warnings >/dev/null

# The partial plist must still name the icon Info.plist points at.
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$WORK_DIR/partial.plist")" \
  != "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ROOT_DIR/Resources/Info.plist")" ]]; then
  echo "AppIcon.icon compiled under a name Info.plist does not use." >&2
  exit 1
fi
[[ -s "$WORK_DIR/Assets.car" ]] || { echo "actool produced no Assets.car." >&2; exit 1; }
cp "$WORK_DIR/Assets.car" "$DESTINATION/Assets.car"
