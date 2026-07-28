#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
VENDOR_DIR="$ROOT_DIR/Vendor/ccusage"
CHECKSUM_FILE="$VENDOR_DIR/SHA256"
README_FILE="$VENDOR_DIR/README.md"
ARM_PACKAGE="@ccusage/ccusage-darwin-arm64"
X64_PACKAGE="@ccusage/ccusage-darwin-x64"
ARM_REGISTRY_URL="https://registry.npmjs.org/%40ccusage%2Fccusage-darwin-arm64/latest"
X64_REGISTRY_URL="https://registry.npmjs.org/%40ccusage%2Fccusage-darwin-x64/latest"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$INFO_PLIST")"
INSTALLED_ARM_BINARY="$VENDOR_DIR/$INSTALLED_VERSION/darwin-arm64/ccusage"
INSTALLED_X64_BINARY="$VENDOR_DIR/$INSTALLED_VERSION/darwin-x64/ccusage"
INSTALLED_UNIVERSAL_BINARY="$VENDOR_DIR/$INSTALLED_VERSION/darwin-universal/ccusage"
WORK_DIR=""

fail() {
  echo "ccusage freshness verification failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    /bin/rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

is_newer_stable_version() {
  local candidate="$1" installed="$2"
  local candidate_major candidate_minor candidate_patch
  local installed_major installed_minor installed_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
  IFS=. read -r installed_major installed_minor installed_patch <<< "$installed"
  if (( candidate_major != installed_major )); then
    (( candidate_major > installed_major ))
  elif (( candidate_minor != installed_minor )); then
    (( candidate_minor > installed_minor ))
  else
    (( candidate_patch > installed_patch ))
  fi
}

verify_local_contract() {
  local actual_paths expected_paths native_binary
  [[ -x "$INSTALLED_ARM_BINARY" ]] || fail "missing vendored $INSTALLED_VERSION arm64 binary"
  [[ -x "$INSTALLED_X64_BINARY" ]] || fail "missing vendored $INSTALLED_VERSION x86_64 binary"
  [[ -x "$INSTALLED_UNIVERSAL_BINARY" ]] || fail "missing vendored $INSTALLED_VERSION universal binary"
  [[ -r "$VENDOR_DIR/LICENSE" ]] || fail "missing vendored MIT license"
  [[ -r "$CHECKSUM_FILE" ]] || fail "missing vendored checksum manifest"
  [[ "$(/usr/bin/wc -l < "$CHECKSUM_FILE" | /usr/bin/tr -d '[:space:]')" == "3" ]] \
    || fail "checksum manifest must contain exactly three entries"
  /usr/bin/awk 'length($1) != 64 || $1 !~ /^[0-9a-f]+$/ || NF != 2 { exit 1 }' "$CHECKSUM_FILE" \
    || fail "checksum manifest contains an invalid entry"
  actual_paths="$(/usr/bin/awk '{ print $2 }' "$CHECKSUM_FILE" | /usr/bin/sort)"
  expected_paths="$(printf '%s\n' \
    "$INSTALLED_VERSION/darwin-arm64/ccusage" \
    "$INSTALLED_VERSION/darwin-universal/ccusage" \
    "$INSTALLED_VERSION/darwin-x64/ccusage" | /usr/bin/sort)"
  [[ "$actual_paths" == "$expected_paths" ]] || fail "checksum manifest contains unexpected paths"
  (cd "$VENDOR_DIR" && /usr/bin/shasum -a 256 -c SHA256 >/dev/null) \
    || fail "vendored binary checksum mismatch"
  [[ "$(/usr/bin/lipo "$INSTALLED_ARM_BINARY" -archs)" == "arm64" ]] \
    || fail "vendored arm64 binary has an unexpected architecture"
  [[ "$(/usr/bin/lipo "$INSTALLED_X64_BINARY" -archs)" == "x86_64" ]] \
    || fail "vendored x86_64 binary has an unexpected architecture"
  /usr/bin/lipo "$INSTALLED_UNIVERSAL_BINARY" -verify_arch arm64 x86_64 \
    || fail "vendored universal binary is missing arm64 or x86_64"
  case "$(/usr/bin/uname -m)" in
    arm64) native_binary="$INSTALLED_ARM_BINARY" ;;
    x86_64) native_binary="$INSTALLED_X64_BINARY" ;;
    *) fail "unsupported build host architecture: $(/usr/bin/uname -m)" ;;
  esac
  [[ "$("$native_binary" --version)" == "ccusage $INSTALLED_VERSION" ]] \
    || fail "native helper and Info.plist versions differ"
  [[ "$("$INSTALLED_UNIVERSAL_BINARY" --version)" == "ccusage $INSTALLED_VERSION" ]] \
    || fail "universal helper and Info.plist versions differ"
}

metadata_value() {
  local metadata="$1" key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$metadata"
}

validate_metadata() {
  local metadata="$1" package="$2" package_suffix="$3"
  local package_name version tarball shasum integrity expected_tarball
  package_name="$(metadata_value "$metadata" name)"
  version="$(metadata_value "$metadata" version)"
  tarball="$(metadata_value "$metadata" dist.tarball)"
  shasum="$(metadata_value "$metadata" dist.shasum)"
  integrity="$(metadata_value "$metadata" dist.integrity)"
  expected_tarball="https://registry.npmjs.org/$package/-/$package_suffix-$version.tgz"
  [[ "$package_name" == "$package" ]] || fail "registry returned unexpected package $package_name"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "registry returned invalid version $version"
  [[ "$tarball" == "$expected_tarball" ]] || fail "registry returned unexpected tarball URL for $package"
  [[ "$shasum" =~ ^[0-9a-f]{40}$ ]] || fail "registry returned invalid tarball SHA-1 for $package"
  [[ "$integrity" == sha512-* ]] || fail "registry returned invalid tarball integrity for $package"
}

download_and_validate() {
  local metadata="$1" package="$2" package_suffix="$3" expected_cpu="$4" expected_macho_arch="$5" destination="$6"
  local version tarball expected_shasum expected_integrity archive actual_shasum actual_integrity
  local archive_entries package_dir package_binary package_json
  version="$(metadata_value "$metadata" version)"
  tarball="$(metadata_value "$metadata" dist.tarball)"
  expected_shasum="$(metadata_value "$metadata" dist.shasum)"
  expected_integrity="$(metadata_value "$metadata" dist.integrity)"
  /bin/mkdir -p "$destination"
  archive="$destination/package.tgz"
  /usr/bin/curl --fail --silent --show-error --max-time 60 "$tarball" -o "$archive" \
    || fail "official $package tarball download failed"
  actual_shasum="$(/usr/bin/shasum -a 1 "$archive" | /usr/bin/awk '{print $1}')"
  [[ "$actual_shasum" == "$expected_shasum" ]] || fail "$package tarball SHA-1 mismatch"
  actual_integrity="sha512-$(/usr/bin/openssl dgst -sha512 -binary "$archive" | /usr/bin/openssl base64 -A)"
  [[ "$actual_integrity" == "$expected_integrity" ]] || fail "$package tarball SHA-512 integrity mismatch"
  archive_entries="$(/usr/bin/tar -tzf "$archive")"
  if printf '%s\n' "$archive_entries" | /usr/bin/grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    fail "$package tarball contains an unsafe path"
  fi
  for required_entry in package/bin/ccusage package/package.json package/LICENSE; do
    printf '%s\n' "$archive_entries" | /usr/bin/grep -Fxq "$required_entry" \
      || fail "$package tarball is missing $required_entry"
  done
  /usr/bin/tar -xzf "$archive" -C "$destination"
  package_dir="$destination/package"
  package_binary="$package_dir/bin/ccusage"
  package_json="$package_dir/package.json"
  [[ "$(/usr/bin/plutil -extract name raw -o - "$package_json")" == "$package" ]] \
    || fail "$package tarball package name mismatch"
  [[ "$(/usr/bin/plutil -extract version raw -o - "$package_json")" == "$version" ]] \
    || fail "$package tarball version mismatch"
  [[ "$(/usr/bin/plutil -extract license raw -o - "$package_json")" == "MIT" ]] \
    || fail "$package tarball license is not MIT"
  [[ "$(/usr/bin/plutil -extract os.0 raw -o - "$package_json")" == "darwin" ]] \
    || fail "$package tarball platform is not macOS"
  [[ "$(/usr/bin/plutil -extract cpu.0 raw -o - "$package_json")" == "$expected_cpu" ]] \
    || fail "$package tarball architecture is not $expected_cpu"
  /bin/chmod +x "$package_binary"
  [[ "$(/usr/bin/lipo "$package_binary" -archs)" == "$expected_macho_arch" ]] \
    || fail "$package binary is not a $expected_macho_arch Mach-O executable"
}

if [[ "$MODE" != "--check" && "$MODE" != "--local" && "$MODE" != "--update" ]]; then
  echo "usage: $0 [--check|--local|--update]" >&2
  exit 2
fi
[[ "$INSTALLED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "installed version is invalid: $INSTALLED_VERSION"

if [[ "$MODE" == "--local" ]]; then
  verify_local_contract
  echo "ccusage Universal local contract verified: $INSTALLED_VERSION"
  exit 0
fi
if [[ "$MODE" == "--check" ]]; then
  verify_local_contract
fi

WORK_DIR="$(/usr/bin/mktemp -d /tmp/tokenremain-ccusage-update.XXXXXX)"
ARM_METADATA="$WORK_DIR/arm64-metadata.json"
X64_METADATA="$WORK_DIR/x86_64-metadata.json"
/usr/bin/curl --fail --silent --show-error --max-time 15 -H 'Accept: application/json' \
  "$ARM_REGISTRY_URL" -o "$ARM_METADATA" || fail "official arm64 npm metadata is unavailable"
/usr/bin/curl --fail --silent --show-error --max-time 15 -H 'Accept: application/json' \
  "$X64_REGISTRY_URL" -o "$X64_METADATA" || fail "official x86_64 npm metadata is unavailable"
validate_metadata "$ARM_METADATA" "$ARM_PACKAGE" "ccusage-darwin-arm64"
validate_metadata "$X64_METADATA" "$X64_PACKAGE" "ccusage-darwin-x64"
ARM_LATEST_VERSION="$(metadata_value "$ARM_METADATA" version)"
X64_LATEST_VERSION="$(metadata_value "$X64_METADATA" version)"
[[ "$ARM_LATEST_VERSION" == "$X64_LATEST_VERSION" ]] \
  || fail "official arm64 and x86_64 package versions do not match"
LATEST_VERSION="$ARM_LATEST_VERSION"

if [[ "$LATEST_VERSION" == "$INSTALLED_VERSION" && "$MODE" == "--check" ]]; then
  echo "ccusage Universal freshness verified against npm: $INSTALLED_VERSION is latest"
  exit 0
fi
if [[ "$LATEST_VERSION" != "$INSTALLED_VERSION" ]] \
  && ! is_newer_stable_version "$LATEST_VERSION" "$INSTALLED_VERSION"; then
  fail "official latest $LATEST_VERSION is older than bundled $INSTALLED_VERSION"
fi
if [[ "$MODE" != "--update" ]]; then
  fail "bundled $INSTALLED_VERSION is stale; official latest is $LATEST_VERSION"
fi

ARM_DOWNLOAD_DIR="$WORK_DIR/arm64"
X64_DOWNLOAD_DIR="$WORK_DIR/x86_64"
download_and_validate "$ARM_METADATA" "$ARM_PACKAGE" "ccusage-darwin-arm64" arm64 arm64 "$ARM_DOWNLOAD_DIR"
download_and_validate "$X64_METADATA" "$X64_PACKAGE" "ccusage-darwin-x64" x64 x86_64 "$X64_DOWNLOAD_DIR"
ARM_BINARY="$ARM_DOWNLOAD_DIR/package/bin/ccusage"
X64_BINARY="$X64_DOWNLOAD_DIR/package/bin/ccusage"
/usr/bin/cmp -s "$ARM_DOWNLOAD_DIR/package/LICENSE" "$X64_DOWNLOAD_DIR/package/LICENSE" \
  || fail "official arm64 and x86_64 packages contain different licenses"
UNIVERSAL_BINARY="$WORK_DIR/ccusage-universal"
/usr/bin/lipo -create "$ARM_BINARY" "$X64_BINARY" -output "$UNIVERSAL_BINARY"
/bin/chmod +x "$UNIVERSAL_BINARY"
/usr/bin/lipo "$UNIVERSAL_BINARY" -verify_arch arm64 x86_64 \
  || fail "failed to create a Universal ccusage helper"
[[ "$("$UNIVERSAL_BINARY" --version)" == "ccusage $LATEST_VERSION" ]] \
  || fail "Universal helper version mismatch"

NEW_ARM_SHA256="$(/usr/bin/shasum -a 256 "$ARM_BINARY" | /usr/bin/awk '{print $1}')"
NEW_X64_SHA256="$(/usr/bin/shasum -a 256 "$X64_BINARY" | /usr/bin/awk '{print $1}')"
NEW_UNIVERSAL_SHA256="$(/usr/bin/shasum -a 256 "$UNIVERSAL_BINARY" | /usr/bin/awk '{print $1}')"
ARM_TARBALL="$(metadata_value "$ARM_METADATA" dist.tarball)"
X64_TARBALL="$(metadata_value "$X64_METADATA" dist.tarball)"
STAGED_INFO_PLIST="$WORK_DIR/Info.plist"
STAGED_README="$WORK_DIR/README.md"
STAGED_CHECKSUM="$WORK_DIR/SHA256"
[[ "$(/usr/bin/grep -c '<key>TokenRemainBundledCCUsageVersion</key>' "$INFO_PLIST")" == "1" ]] \
  || fail "Info.plist must contain exactly one bundled ccusage version key"
CCUSAGE_NEW_VERSION="$LATEST_VERSION" /usr/bin/perl -0pe '
  s#(<key>TokenRemainBundledCCUsageVersion</key>\s*<string>)[^<]+(</string>)#$1$ENV{CCUSAGE_NEW_VERSION}$2#;
' "$INFO_PLIST" > "$STAGED_INFO_PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TokenRemainBundledCCUsageVersion' "$STAGED_INFO_PLIST")" == "$LATEST_VERSION" ]] \
  || fail "failed to stage the new Info.plist ccusage version"
CCUSAGE_NEW_VERSION="$LATEST_VERSION" \
CCUSAGE_ARM_PACKAGE="$ARM_PACKAGE" \
CCUSAGE_X64_PACKAGE="$X64_PACKAGE" \
CCUSAGE_ARM_TARBALL="$ARM_TARBALL" \
CCUSAGE_X64_TARBALL="$X64_TARBALL" \
CCUSAGE_ARM_SHA256="$NEW_ARM_SHA256" \
CCUSAGE_X64_SHA256="$NEW_X64_SHA256" \
CCUSAGE_UNIVERSAL_SHA256="$NEW_UNIVERSAL_SHA256" \
  /usr/bin/perl -0pe '
    s/^- arm64 package: `[^`]+`/- arm64 package: `$ENV{CCUSAGE_ARM_PACKAGE}`/m;
    s/^- x86_64 package: `[^`]+`/- x86_64 package: `$ENV{CCUSAGE_X64_PACKAGE}`/m;
    s/^- Version: `[^`]+`/- Version: `$ENV{CCUSAGE_NEW_VERSION}`/m;
    s#^- arm64 npm source: `[^`]+`#- arm64 npm source: `$ENV{CCUSAGE_ARM_TARBALL}`#m;
    s#^- x86_64 npm source: `[^`]+`#- x86_64 npm source: `$ENV{CCUSAGE_X64_TARBALL}`#m;
    s/^- arm64 SHA-256: `[^`]+`/- arm64 SHA-256: `$ENV{CCUSAGE_ARM_SHA256}`/m;
    s/^- x86_64 SHA-256: `[^`]+`/- x86_64 SHA-256: `$ENV{CCUSAGE_X64_SHA256}`/m;
    s/^- Universal SHA-256: `[^`]+`/- Universal SHA-256: `$ENV{CCUSAGE_UNIVERSAL_SHA256}`/m;
  ' "$README_FILE" > "$STAGED_README"
printf '%s  %s\n' \
  "$NEW_ARM_SHA256" "$LATEST_VERSION/darwin-arm64/ccusage" \
  "$NEW_X64_SHA256" "$LATEST_VERSION/darwin-x64/ccusage" \
  "$NEW_UNIVERSAL_SHA256" "$LATEST_VERSION/darwin-universal/ccusage" \
  > "$STAGED_CHECKSUM"

NEW_ARM_DIR="$VENDOR_DIR/$LATEST_VERSION/darwin-arm64"
NEW_X64_DIR="$VENDOR_DIR/$LATEST_VERSION/darwin-x64"
NEW_UNIVERSAL_DIR="$VENDOR_DIR/$LATEST_VERSION/darwin-universal"
/bin/mkdir -p "$NEW_ARM_DIR" "$NEW_X64_DIR" "$NEW_UNIVERSAL_DIR"
/usr/bin/ditto "$ARM_BINARY" "$NEW_ARM_DIR/ccusage"
/usr/bin/ditto "$X64_BINARY" "$NEW_X64_DIR/ccusage"
/usr/bin/ditto "$UNIVERSAL_BINARY" "$NEW_UNIVERSAL_DIR/ccusage"
/bin/chmod +x "$NEW_ARM_DIR/ccusage" "$NEW_X64_DIR/ccusage" "$NEW_UNIVERSAL_DIR/ccusage"
/usr/bin/ditto "$ARM_DOWNLOAD_DIR/package/LICENSE" "$VENDOR_DIR/LICENSE"
/usr/bin/ditto "$STAGED_INFO_PLIST" "$INFO_PLIST"
/usr/bin/ditto "$STAGED_README" "$README_FILE"
/usr/bin/ditto "$STAGED_CHECKSUM" "$CHECKSUM_FILE"

if [[ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]]; then
  OLD_VERSION_DIR="$VENDOR_DIR/$INSTALLED_VERSION"
  for old_architecture in darwin-arm64 darwin-x64 darwin-universal; do
    /bin/rm -f "$OLD_VERSION_DIR/$old_architecture/ccusage"
    /bin/rmdir "$OLD_VERSION_DIR/$old_architecture" 2>/dev/null || true
  done
  /bin/rmdir "$OLD_VERSION_DIR" 2>/dev/null || true
fi

INSTALLED_VERSION="$LATEST_VERSION"
INSTALLED_ARM_BINARY="$NEW_ARM_DIR/ccusage"
INSTALLED_X64_BINARY="$NEW_X64_DIR/ccusage"
INSTALLED_UNIVERSAL_BINARY="$NEW_UNIVERSAL_DIR/ccusage"
verify_local_contract
echo "ccusage Universal helper updated for release: $LATEST_VERSION ($NEW_UNIVERSAL_SHA256)"
