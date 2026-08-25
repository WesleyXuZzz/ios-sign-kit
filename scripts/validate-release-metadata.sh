#!/bin/zsh

set -euo pipefail

METADATA_PATH="${1:-}"

fail() {
  echo "Invalid release metadata: $1" >&2
  exit 1
}

[[ -n "$METADATA_PATH" && -f "$METADATA_PATH" && ! -L "$METADATA_PATH" ]] \
  || fail "file is missing or linked."
plutil -convert xml1 -o /dev/null -- "$METADATA_PATH" >/dev/null 2>&1 \
  || fail "file is not valid JSON or plist data."

APP_DISPLAY_NAME="$(plutil -extract appDisplayName raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "appDisplayName is missing."
EXECUTABLE_NAME="$(plutil -extract executableName raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "executableName is missing."
BUNDLE_IDENTIFIER="$(plutil -extract bundleIdentifier raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "bundleIdentifier is missing."
MARKETING_VERSION="$(plutil -extract marketingVersion raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "marketingVersion is missing."
BUILD_VERSION="$(plutil -extract buildVersion raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "buildVersion is missing."
MINIMUM_MACOS_VERSION="$(plutil -extract minimumMacOSVersion raw "$METADATA_PATH" 2>/dev/null)" \
  || fail "minimumMacOSVersion is missing."

[[ "$APP_DISPLAY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
  || fail "appDisplayName contains unsupported characters."
[[ "$EXECUTABLE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
  || fail "executableName contains unsupported characters."
"${0:A:h}/validate-build-config.sh" "$BUNDLE_IDENTIFIER" "$BUILD_VERSION"
[[ "$MARKETING_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || fail "marketingVersion must contain three numeric components."
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] \
  || fail "buildVersion must be a positive integer."
[[ "$MINIMUM_MACOS_VERSION" =~ ^[0-9]+[.][0-9]+$ ]] \
  || fail "minimumMacOSVersion must contain two numeric components."
