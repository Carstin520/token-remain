#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="UsageDock"
BUNDLE_ID="com.jamesli.usagedock"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_DIR="${USAGEDOCK_INSTALL_DIR:-/Users/jamesli/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LOCAL_FEED_CONFIG="$ROOT_DIR/Config/UsageDockFeed.local.plist"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
# A stable signature lets macOS retain the user's "Always Allow" choice for
# the Claude Code keychain item across UsageDock rebuilds.
SIGNING_IDENTITY="${USAGEDOCK_SIGNING_IDENTITY:-}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/Sources/UsageDock/Resources/claude.png" "$APP_RESOURCES/claude.png"
cp "$ROOT_DIR/Sources/UsageDock/Resources/openai.png" "$APP_RESOURCES/openai.png"
chmod +x "$APP_BINARY"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
    | head -n 1)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "UsageDock needs an Apple Development signing identity to preserve Keychain approval." >&2
  exit 1
fi
# Finder/File Provider metadata can be copied onto a local bundle and invalidate
# its resource seal. These are metadata only; the signed app never relies on them.
for attribute in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.macl com.apple.provenance; do
  /usr/bin/xattr -dr "$attribute" "$APP_BUNDLE" 2>/dev/null || true
done
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"
# On File Provider-backed workspaces, codesign itself can cause provenance
# metadata to be re-applied to newly written signature files. Removing it after
# signing does not change the code signature and prevents dyld launch stalls.
/usr/bin/xattr -dr com.apple.provenance "$APP_BUNDLE" 2>/dev/null || true

# Run from the stable installed location. LaunchServices can refuse or stall on
# app bundles inside File Provider-backed development folders, while the
# installed path also gives Keychain and notification permissions a stable home.
mkdir -p "$INSTALL_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
for attribute in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.macl com.apple.provenance; do
  /usr/bin/xattr -dr "$attribute" "$INSTALLED_APP" 2>/dev/null || true
done
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"

open_app() {
  local open_arguments=()
  if [[ -f "$LOCAL_FEED_CONFIG" ]]; then
    chmod 600 "$LOCAL_FEED_CONFIG"
    open_arguments=(--args --import-feed-config "$LOCAL_FEED_CONFIG")
  fi
  /usr/bin/open -n "$INSTALLED_APP" "${open_arguments[@]}"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == '$APP_NAME'"
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == '$BUNDLE_ID'"
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
