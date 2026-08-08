#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_FILE="$ROOT_DIR/BUILD_NUMBER"
RELEASE_TAG_FILE="$ROOT_DIR/RELEASE_TAG"
MAC_INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

fail() {
  echo "version consistency verification failed: $*" >&2
  exit 1
}

[[ -r "$VERSION_FILE" ]] || fail "VERSION is missing"
[[ -r "$BUILD_FILE" ]] || fail "BUILD_NUMBER is missing"

VERSION="$(/usr/bin/tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_NUMBER="$(/usr/bin/tr -d '[:space:]' < "$BUILD_FILE")"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION must use MAJOR.MINOR.PATCH"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || fail "BUILD_NUMBER must be a positive integer"

RELEASE_TAG="v$VERSION"
if [[ -r "$RELEASE_TAG_FILE" ]]; then
  RELEASE_TAG="$(/usr/bin/tr -d '[:space:]' < "$RELEASE_TAG_FILE")"
fi
[[ "$RELEASE_TAG" == "v$VERSION" || "$RELEASE_TAG" == "v$VERSION+build.$BUILD_NUMBER" ]] \
  || fail "RELEASE_TAG $RELEASE_TAG does not match $VERSION ($BUILD_NUMBER)"

MAC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAC_INFO_PLIST")"
MAC_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MAC_INFO_PLIST")"

[[ "$MAC_VERSION" == "$VERSION" ]] \
  || fail "macOS marketing version $MAC_VERSION does not match $VERSION"
[[ "$MAC_BUILD" == "$BUILD_NUMBER" ]] \
  || fail "macOS build $MAC_BUILD does not match $BUILD_NUMBER"
echo "version consistency verified: $VERSION ($BUILD_NUMBER), release tag $RELEASE_TAG"
