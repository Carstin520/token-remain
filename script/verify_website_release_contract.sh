#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
INDEX="$ROOT_DIR/site/index.html"
SUPPORT="$ROOT_DIR/site/support.html"
PRIVACY="$ROOT_DIR/site/privacy.html"
DOWNLOAD_URL="https://github.com/Carstin520/token-remain/releases/latest/download/TokenRemain.dmg"
PUBLIC_URL="https://tokenremain.com"

fail() {
  echo "website release contract verification failed: $*" >&2
  exit 1
}

[[ -r "$INDEX" ]] || fail "site/index.html is missing"
[[ -r "$SUPPORT" ]] || fail "site/support.html is missing"
[[ -r "$PRIVACY" ]] || fail "site/privacy.html is missing"

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
/usr/bin/grep -Fq \
  'fixed, bodyless GET request at most once per day' \
  "$PRIVACY" \
  || fail "English privacy policy does not disclose the public pricing refresh"
/usr/bin/grep -Fq \
  '每天最多一次向 GitHub 发出固定且无请求正文的 GET 请求' \
  "$PRIVACY" \
  || fail "Chinese privacy policy does not disclose the public pricing refresh"

echo "website release contract verified: static $VERSION fallback + dynamic latest release + stable DMG download"

if [[ "${1:-}" == "--public" ]]; then
  PUBLIC_INDEX="$(/usr/bin/curl -fsSL "$PUBLIC_URL/?release-check=$VERSION")" \
    || fail "cannot load the public homepage"
  /usr/bin/grep -Fq "data-release-version=\"$VERSION\"" <<< "$PUBLIC_INDEX" \
    || fail "public homepage fallback does not match VERSION $VERSION"
  /usr/bin/grep -Fq "$DOWNLOAD_URL" <<< "$PUBLIC_INDEX" \
    || fail "public homepage download does not use the stable latest-release asset URL"

  LATEST_TAG="$(/usr/bin/curl -fsSL \
    "https://api.github.com/repos/Carstin520/token-remain/releases/latest" \
    | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))')" \
    || fail "cannot resolve the latest GitHub release"
  [[ "$LATEST_TAG" == "v$VERSION" ]] \
    || fail "latest GitHub release is $LATEST_TAG, expected v$VERSION"

  DOWNLOAD_HEADERS="$(/usr/bin/curl -fsSI "$DOWNLOAD_URL" | /usr/bin/tr -d '\r')" \
    || fail "latest Mac download is unavailable"
  /usr/bin/grep -Fqi \
    "location: https://github.com/Carstin520/token-remain/releases/download/v$VERSION/TokenRemain.dmg" \
    <<< "$DOWNLOAD_HEADERS" \
    || fail "latest Mac download does not resolve to v$VERSION"

  echo "public website release verified: homepage + GitHub release + TokenRemain.dmg all match v$VERSION"
fi
