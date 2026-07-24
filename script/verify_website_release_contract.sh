#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
INDEX="$ROOT_DIR/site/index.html"
SUPPORT="$ROOT_DIR/site/support.html"
DOWNLOAD_URL="https://github.com/Carstin520/token-remain/releases/latest/download/TokenRemain.dmg"

fail() {
  echo "website release contract verification failed: $*" >&2
  exit 1
}

[[ -r "$INDEX" ]] || fail "site/index.html is missing"
[[ -r "$SUPPORT" ]] || fail "site/support.html is missing"

/usr/bin/grep -Fq "data-release-version=\"$VERSION\"" "$INDEX" \
  || fail "static website fallback does not match VERSION $VERSION"
/usr/bin/grep -Fq \
  "https://api.github.com/repos/Carstin520/token-remain/releases/latest" \
  "$INDEX" \
  || fail "website no longer resolves the latest GitHub release dynamically"
/usr/bin/grep -Fq 'id="macDownloadButton"' "$INDEX" \
  || fail "official Mac download button is missing"
/usr/bin/grep -Fq "$DOWNLOAD_URL" "$INDEX" \
  || fail "Mac download button must use GitHub's stable latest-release asset URL"
/usr/bin/grep -Fq "$DOWNLOAD_URL" "$SUPPORT" \
  || fail "support page Mac download must use GitHub's stable latest-release asset URL"

echo "website release contract verified: static $VERSION fallback + dynamic latest release + stable DMG download"
