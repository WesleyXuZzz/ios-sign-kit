#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
  exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_METADATA_PATH="$PROJECT_ROOT/config/release-metadata.json"
"$SCRIPT_DIR/validate-release-metadata.sh" "$RELEASE_METADATA_PATH"
APP_DISPLAY_NAME="$(plutil -extract appDisplayName raw "$RELEASE_METADATA_PATH")"
EXECUTABLE_NAME="$(plutil -extract executableName raw "$RELEASE_METADATA_PATH")"
BUNDLE_IDENTIFIER="$(plutil -extract bundleIdentifier raw "$RELEASE_METADATA_PATH")"
MARKETING_VERSION="$(plutil -extract marketingVersion raw "$RELEASE_METADATA_PATH")"
BUNDLE_VERSION="$(plutil -extract buildVersion raw "$RELEASE_METADATA_PATH")"
MACOS_DEPLOYMENT_TARGET="$(plutil -extract minimumMacOSVersion raw "$RELEASE_METADATA_PATH")"
OUTPUT_ROOT="$PROJECT_ROOT/dist"
APP_BUNDLE_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.app"
DMG_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.dmg"
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
BINARY_PATH="$CONTENTS_PATH/MacOS/$EXECUTABLE_NAME"
PLIST_PATH="$CONTENTS_PATH/Info.plist"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
ASSETS_CAR_PATH="$RESOURCES_PATH/Assets.car"
RESOURCE_BUNDLE_PATH="$RESOURCES_PATH/ios-sign-kit_IOSSignKit.bundle"
RUNTIME_RESOURCE_MANIFEST_PATH="$PROJECT_ROOT/config/runtime-resources.tsv"

MAX_BINARY_SIZE_BYTES=$(( 3 * 1024 * 1024 ))
MAX_RESOURCE_BUNDLE_SIZE_KIB=$(( 2 * 1024 ))
MAX_APP_SIZE_KIB=$(( 9 * 1024 ))
MAX_DMG_SIZE_BYTES=$(( 7 * 1024 * 1024 ))

BUILD_LOCK_PATH="$OUTPUT_ROOT/.build-app.lock"
BUILD_LOCK_HELD="false"
TEMPORARY_ROOT=""
VALIDATION_DMG_PATH=""
MOUNT_POINT=""
ASSET_INFO_PLIST_PATH=""
ATTACH_INFO_PLIST_PATH=""
DMG_ATTACHMENT_ATTEMPTED="false"
ATTACHMENT_OWNERSHIP_CONFIRMED="false"
ATTACHED_DEVICE=""
ATTACHED_MOUNT_POINT=""
ATTACHED_VOLUME_KIND=""
PRESERVE_TEMPORARY_SCENE="false"
SIZE_BUDGET_WARNING_COUNT=0

fail() {
  echo "Release artifact verification failed: $1" >&2
  exit 1
}

release_build_lock() {
  local LOCK_OWNER=""

  if [[ "$BUILD_LOCK_HELD" != "true" ]]; then
    return
  fi

  if [[ -f "$BUILD_LOCK_PATH" && ! -L "$BUILD_LOCK_PATH" ]]; then
    LOCK_OWNER="$(< "$BUILD_LOCK_PATH")"
    if [[ "$LOCK_OWNER" == "$$" ]]; then
      if ! unlink "$BUILD_LOCK_PATH"; then
        echo "Warning: failed to release build lock: $BUILD_LOCK_PATH" >&2
      fi
    else
      echo "Warning: build lock ownership changed; leaving it untouched: $BUILD_LOCK_PATH" >&2
    fi
  fi

  BUILD_LOCK_HELD="false"
}

warn_size_budget() {
  local LABEL="$1"
  local ACTUAL="$2"
  local LIMIT="$3"
  local UNIT="$4"

  if (( ACTUAL > LIMIT )); then
    echo "Warning: $LABEL exceeds its $LIMIT $UNIT budget: $ACTUAL $UNIT" >&2
    SIZE_BUDGET_WARNING_COUNT=$(( SIZE_BUDGET_WARNING_COUNT + 1 ))
  fi
}

cleanup() {
  local EXIT_STATUS=$?
  if (( $# == 1 )); then
    EXIT_STATUS="$1"
  fi
  local CLEANUP_STATUS=0

  trap - EXIT HUP INT TERM
  set +e

  if [[ "$DMG_ATTACHMENT_ATTEMPTED" == "true" \
    && "$ATTACHMENT_OWNERSHIP_CONFIRMED" != "true" ]]; then
    PRESERVE_TEMPORARY_SCENE="true"
    echo "DMG attachment ownership was not confirmed; preserving validation data." >&2
  fi

  if [[ "$ATTACHMENT_OWNERSHIP_CONFIRMED" == "true" ]]; then
    if ! hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null 2>&1; then
      echo "Failed to detach captured validation device: $ATTACHED_DEVICE" >&2
      CLEANUP_STATUS=1
      PRESERVE_TEMPORARY_SCENE="true"
    fi
  fi

  if [[ "$PRESERVE_TEMPORARY_SCENE" != "true" ]]; then
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" && ! -L "$MOUNT_POINT" ]]; then
      if ! rmdir "$MOUNT_POINT"; then
        echo "Failed to remove empty validation mount point: $MOUNT_POINT" >&2
        CLEANUP_STATUS=1
      fi
    fi

    for TEMPORARY_FILE in \
      "$ASSET_INFO_PLIST_PATH" \
      "$ATTACH_INFO_PLIST_PATH" \
      "$VALIDATION_DMG_PATH"; do
      if [[ -n "$TEMPORARY_FILE" \
        && -f "$TEMPORARY_FILE" \
        && ! -L "$TEMPORARY_FILE" ]]; then
        if ! unlink "$TEMPORARY_FILE"; then
          echo "Failed to remove validation file: $TEMPORARY_FILE" >&2
          CLEANUP_STATUS=1
        fi
      fi
    done

    if [[ -n "$TEMPORARY_ROOT" \
      && -d "$TEMPORARY_ROOT" \
      && ! -L "$TEMPORARY_ROOT" ]]; then
      if ! rmdir "$TEMPORARY_ROOT"; then
        echo "Failed to remove empty validation directory: $TEMPORARY_ROOT" >&2
        CLEANUP_STATUS=1
      fi
    fi
  elif [[ -n "$TEMPORARY_ROOT" ]]; then
    echo "Preserved validation directory: $TEMPORARY_ROOT" >&2
    if [[ -n "$VALIDATION_DMG_PATH" ]]; then
      echo "Preserved validation DMG copy: $VALIDATION_DMG_PATH" >&2
    fi
  fi

  release_build_lock

  if (( EXIT_STATUS == 0 && CLEANUP_STATUS != 0 )); then
    EXIT_STATUS=1
  fi
  exit "$EXIT_STATUS"
}

trap cleanup EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

if (( $# != 0 )); then
  fail "this script verifies the default dist release artifacts and accepts no arguments"
fi

[[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] \
  || fail "release output directory is missing or linked: $OUTPUT_ROOT"
if ! /usr/bin/shlock -f "$BUILD_LOCK_PATH" -p "$$"; then
  if [[ -f "$BUILD_LOCK_PATH" && ! -L "$BUILD_LOCK_PATH" ]]; then
    fail "another app build or release verification is running with PID $(< "$BUILD_LOCK_PATH")"
  fi
  fail "another app build or release verification is running"
fi
BUILD_LOCK_HELD="true"

[[ -d "$APP_BUNDLE_PATH" && ! -L "$APP_BUNDLE_PATH" ]] \
  || fail "release app bundle is missing or is not a regular directory: $APP_BUNDLE_PATH"
[[ -f "$DMG_PATH" && ! -L "$DMG_PATH" ]] \
  || fail "release DMG is missing or is not a regular file: $DMG_PATH"
[[ -f "$BINARY_PATH" && ! -L "$BINARY_PATH" && -x "$BINARY_PATH" ]] \
  || fail "release executable is missing, linked, or not executable: $BINARY_PATH"
[[ -f "$PLIST_PATH" && ! -L "$PLIST_PATH" ]] \
  || fail "Info.plist is missing or linked: $PLIST_PATH"
[[ -f "$ASSETS_CAR_PATH" && ! -L "$ASSETS_CAR_PATH" && -s "$ASSETS_CAR_PATH" ]] \
  || fail "Assets.car is missing, linked, or empty: $ASSETS_CAR_PATH"
[[ -d "$RESOURCE_BUNDLE_PATH" && ! -L "$RESOURCE_BUNDLE_PATH" ]] \
  || fail "SwiftPM resource bundle is missing or linked: $RESOURCE_BUNDLE_PATH"

TEMPORARY_ROOT="$(mktemp -d "/private/tmp/iOSSignKit-release-verification.XXXXXX")"
TEMPORARY_ROOT="$(cd "$TEMPORARY_ROOT" && pwd -P)"
MOUNT_POINT="$TEMPORARY_ROOT/mount"
VALIDATION_DMG_PATH="$TEMPORARY_ROOT/$APP_DISPLAY_NAME.dmg"
ASSET_INFO_PLIST_PATH="$TEMPORARY_ROOT/asset-info.plist"
ATTACH_INFO_PLIST_PATH="$TEMPORARY_ROOT/attach-info.plist"
mkdir "$MOUNT_POINT"

echo "==> Verifying release app signature"
codesign --verify --strict --verbose=4 "$APP_BUNDLE_PATH"
APP_SIGNATURE_INFO="$(codesign -dvvv "$APP_BUNDLE_PATH" 2>&1)"
if [[ "$APP_SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "==> Release app uses an ad-hoc signature"
else
  APP_TEAM_IDENTIFIER="$(
    printf '%s\n' "$APP_SIGNATURE_INFO" \
      | awk -F= '/^TeamIdentifier=/ { print $2; exit }'
  )"
  APP_SIGNING_AUTHORITY="$(
    printf '%s\n' "$APP_SIGNATURE_INFO" \
      | awk -F= '/^Authority=/ { print $2; exit }'
  )"
  [[ -n "$APP_TEAM_IDENTIFIER" \
    && "$APP_TEAM_IDENTIFIER" != "not set" ]] \
    || fail "identity-signed release app has no team identifier"
  [[ -n "$APP_SIGNING_AUTHORITY" ]] \
    || fail "identity-signed release app has no signing authority"
  echo "==> Release app uses an identity-backed signature"
fi

echo "==> Verifying Info.plist"
plutil -lint "$PLIST_PATH" >/dev/null
[[ "$(plutil -extract CFBundleIconName raw "$PLIST_PATH")" == "AppIcon" ]] \
  || fail "CFBundleIconName must be AppIcon"
if plutil -extract CFBundleIconFile raw "$PLIST_PATH" >/dev/null 2>&1; then
  fail "CFBundleIconFile must be absent when the app uses Assets.car"
fi
[[ "$(plutil -extract CFBundleDisplayName raw "$PLIST_PATH")" == "$APP_DISPLAY_NAME" ]] \
  || fail "CFBundleDisplayName does not match release metadata"
[[ "$(plutil -extract CFBundleExecutable raw "$PLIST_PATH")" == "$EXECUTABLE_NAME" ]] \
  || fail "CFBundleExecutable does not match release metadata"
[[ "$(plutil -extract CFBundleIdentifier raw "$PLIST_PATH")" == "$BUNDLE_IDENTIFIER" ]] \
  || fail "CFBundleIdentifier does not match release metadata"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST_PATH")" == "$MARKETING_VERSION" ]] \
  || fail "CFBundleShortVersionString does not match release metadata"
[[ "$(plutil -extract CFBundleVersion raw "$PLIST_PATH")" == "$BUNDLE_VERSION" ]] \
  || fail "CFBundleVersion does not match release metadata"
[[ "$(plutil -extract LSMinimumSystemVersion raw "$PLIST_PATH")" == "$MACOS_DEPLOYMENT_TARGET" ]] \
  || fail "LSMinimumSystemVersion does not match release metadata"
[[ "$(plutil -extract CFBundlePackageType raw "$PLIST_PATH")" == "APPL" ]] \
  || fail "CFBundlePackageType must be APPL"
[[ "$(plutil -extract LSUIElement raw "$PLIST_PATH")" == "true" ]] \
  || fail "LSUIElement must be true"
[[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw "$PLIST_PATH")" ]] \
  || fail "NSLocalNetworkUsageDescription must explain LAN control access"

echo "==> Verifying packaged resources"
if ! xcrun assetutil --info "$ASSETS_CAR_PATH" \
  | plutil -convert xml1 -o "$ASSET_INFO_PLIST_PATH" -- -; then
  fail "assetutil output could not be converted from JSON to a property list"
fi

ASSET_INDEX=0
FOUND_LARGE_APP_ICON_RENDITION="false"
while plutil \
  -extract "$ASSET_INDEX" xml1 \
  -o /dev/null \
  "$ASSET_INFO_PLIST_PATH" \
  >/dev/null 2>&1; do
  ASSET_NAME="$(
    plutil -extract "$ASSET_INDEX.Name" raw "$ASSET_INFO_PLIST_PATH" 2>/dev/null \
      || true
  )"
  ASSET_TYPE="$(
    plutil -extract "$ASSET_INDEX.AssetType" raw "$ASSET_INFO_PLIST_PATH" 2>/dev/null \
      || true
  )"
  ASSET_PIXEL_WIDTH="$(
    plutil -extract "$ASSET_INDEX.PixelWidth" raw "$ASSET_INFO_PLIST_PATH" 2>/dev/null \
      || true
  )"
  ASSET_PIXEL_HEIGHT="$(
    plutil -extract "$ASSET_INDEX.PixelHeight" raw "$ASSET_INFO_PLIST_PATH" 2>/dev/null \
      || true
  )"

  if [[ "$ASSET_NAME" == "AppIcon" \
    && "$ASSET_TYPE" == "Icon Image" \
    && "$ASSET_PIXEL_WIDTH" == <-> \
    && "$ASSET_PIXEL_HEIGHT" == <-> ]] \
    && (( ASSET_PIXEL_WIDTH >= 512 && ASSET_PIXEL_HEIGHT >= 512 )); then
    FOUND_LARGE_APP_ICON_RENDITION="true"
  fi

  ASSET_INDEX=$(( ASSET_INDEX + 1 ))
done
(( ASSET_INDEX > 0 )) \
  || fail "Assets.car inspection produced no rendition entries"
[[ "$FOUND_LARGE_APP_ICON_RENDITION" == "true" ]] \
  || fail "Assets.car has no AppIcon Icon Image rendition of at least 512 by 512 pixels"
[[ ! -e "$RESOURCES_PATH/AppIcon.icns" && ! -L "$RESOURCES_PATH/AppIcon.icns" ]] \
  || fail "standalone AppIcon.icns must not be packaged"

[[ -f "$RUNTIME_RESOURCE_MANIFEST_PATH" && ! -L "$RUNTIME_RESOURCE_MANIFEST_PATH" ]] \
  || fail "runtime resource manifest is missing or linked"
EXPECTED_RUNTIME_RESOURCE_NAMES=()
while IFS=$'\t' read -r RESOURCE_SOURCE_PATH RESOURCE_ROLE; do
  [[ -z "$RESOURCE_SOURCE_PATH" || "$RESOURCE_SOURCE_PATH" == \#* ]] && continue
  [[ "$RESOURCE_ROLE" == "runtime" \
    || "$RESOURCE_ROLE" == "notification-attachment" ]] \
    || fail "runtime resource manifest contains an invalid role"
  [[ -f "$PROJECT_ROOT/Sources/IOSSignKit/$RESOURCE_SOURCE_PATH" \
    && ! -L "$PROJECT_ROOT/Sources/IOSSignKit/$RESOURCE_SOURCE_PATH" ]] \
    || fail "manifest runtime resource is missing or linked: $RESOURCE_SOURCE_PATH"
  EXPECTED_RUNTIME_RESOURCE_NAMES+=("${RESOURCE_SOURCE_PATH:t}")
done < "$RUNTIME_RESOURCE_MANIFEST_PATH"
(( ${#EXPECTED_RUNTIME_RESOURCE_NAMES[@]} > 0 )) \
  || fail "runtime resource manifest contains no entries"
PACKAGED_RUNTIME_RESOURCE_PATHS=("$RESOURCE_BUNDLE_PATH"/**/*(DN.))
(( ${#PACKAGED_RUNTIME_RESOURCE_PATHS[@]} == ${#EXPECTED_RUNTIME_RESOURCE_NAMES[@]} )) \
  || fail "runtime resource bundle must contain exactly ${#EXPECTED_RUNTIME_RESOURCE_NAMES[@]} files"
for RESOURCE_NAME in "${EXPECTED_RUNTIME_RESOURCE_NAMES[@]}"; do
  MATCHING_RUNTIME_RESOURCES=("$RESOURCE_BUNDLE_PATH"/**/"$RESOURCE_NAME"(DN.))
  (( ${#MATCHING_RUNTIME_RESOURCES[@]} == 1 )) \
    || fail "runtime resource must be packaged exactly once: $RESOURCE_NAME"
done

FORBIDDEN_RESOURCE_NAMES=(
  "AppIcon.icns"
  "AppIconMaster.png"
  "icon_16x16.png"
  "icon_16x16@2x.png"
  "icon_32x32.png"
  "icon_32x32@2x.png"
  "icon_128x128.png"
  "icon_128x128@2x.png"
  "icon_256x256.png"
  "icon_256x256@2x.png"
  "icon_512x512.png"
  "icon_512x512@2x.png"
)
for RESOURCE_NAME in "${FORBIDDEN_RESOURCE_NAMES[@]}"; do
  FOUND_RESOURCE="$(
    find "$RESOURCE_BUNDLE_PATH" -name "$RESOURCE_NAME" -print -quit
  )"
  [[ -z "$FOUND_RESOURCE" ]] \
    || fail "excluded App Icon source was packaged: $FOUND_RESOURCE"
done
FOUND_ICONSET="$(
  find "$RESOURCE_BUNDLE_PATH" -name "AppIcon.iconset" -print -quit
)"
[[ -z "$FOUND_ICONSET" ]] \
  || fail "excluded AppIcon.iconset directory was packaged: $FOUND_ICONSET"

echo "==> Verifying release size budgets"
BINARY_SIZE_BYTES="$(stat -f "%z" "$BINARY_PATH")"
RESOURCE_BUNDLE_SIZE_KIB="$(du -A -k -s "$RESOURCE_BUNDLE_PATH" | awk '{ print $1 }')"
APP_SIZE_KIB="$(du -A -k -s "$APP_BUNDLE_PATH" | awk '{ print $1 }')"
DMG_SIZE_BYTES="$(stat -f "%z" "$DMG_PATH")"

warn_size_budget \
  "release executable" \
  "$BINARY_SIZE_BYTES" \
  "$MAX_BINARY_SIZE_BYTES" \
  "bytes"
warn_size_budget \
  "runtime resource bundle apparent size" \
  "$RESOURCE_BUNDLE_SIZE_KIB" \
  "$MAX_RESOURCE_BUNDLE_SIZE_KIB" \
  "KiB"
warn_size_budget \
  "release app apparent size" \
  "$APP_SIZE_KIB" \
  "$MAX_APP_SIZE_KIB" \
  "KiB"
warn_size_budget \
  "release DMG" \
  "$DMG_SIZE_BYTES" \
  "$MAX_DMG_SIZE_BYTES" \
  "bytes"

LOCAL_SYMBOL_COUNT="$(
  nm "$BINARY_PATH" 2>/dev/null \
    | awk '$2 ~ /^[a-z]$/ { count++ } END { print count + 0 }'
)"
(( LOCAL_SYMBOL_COUNT == 0 )) \
  || fail "release executable still contains $LOCAL_SYMBOL_COUNT local symbols"

echo "==> Preparing isolated DMG verification copy"
cp "$DMG_PATH" "$VALIDATION_DMG_PATH"
cmp -s "$DMG_PATH" "$VALIDATION_DMG_PATH" \
  || fail "validation DMG copy does not match the release DMG"

echo "==> Verifying DMG integrity and format"
hdiutil verify "$VALIDATION_DMG_PATH" >/dev/null
DMG_FORMAT="$(hdiutil imageinfo -format "$VALIDATION_DMG_PATH")"
[[ "$DMG_FORMAT" == "ULFO" ]] \
  || fail "DMG format must be ULFO, found: $DMG_FORMAT"

echo "==> Mounting isolated DMG copy"
DMG_ATTACHMENT_ATTEMPTED="true"
if ! hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -noverify \
  -mountpoint "$MOUNT_POINT" \
  -plist \
  "$VALIDATION_DMG_PATH" \
  > "$ATTACH_INFO_PLIST_PATH"; then
  PRESERVE_TEMPORARY_SCENE="true"
  fail "hdiutil attach failed before attachment ownership could be confirmed"
fi

if ! plutil -lint "$ATTACH_INFO_PLIST_PATH" >/dev/null; then
  PRESERVE_TEMPORARY_SCENE="true"
  fail "hdiutil attach did not return a valid property list"
fi

ENTITY_INDEX=0
MATCHED_ENTITY_COUNT=0
CANDIDATE_DEVICE=""
CANDIDATE_MOUNT_POINT=""
CANDIDATE_VOLUME_KIND=""
while plutil \
  -extract "system-entities.$ENTITY_INDEX" xml1 \
  -o /dev/null \
  "$ATTACH_INFO_PLIST_PATH" \
  >/dev/null 2>&1; do
  ENTITY_MOUNT_POINT="$(
    plutil \
      -extract "system-entities.$ENTITY_INDEX.mount-point" raw \
      "$ATTACH_INFO_PLIST_PATH" \
      2>/dev/null \
      || true
  )"

  if [[ -n "$ENTITY_MOUNT_POINT" \
    && -d "$ENTITY_MOUNT_POINT" \
    && ! -L "$ENTITY_MOUNT_POINT" ]]; then
    NORMALIZED_ENTITY_MOUNT_POINT="$(
      cd "$ENTITY_MOUNT_POINT" \
        && pwd -P
    )"
    if [[ "$NORMALIZED_ENTITY_MOUNT_POINT" == "$MOUNT_POINT" ]]; then
      MATCHED_ENTITY_COUNT=$(( MATCHED_ENTITY_COUNT + 1 ))
      CANDIDATE_MOUNT_POINT="$NORMALIZED_ENTITY_MOUNT_POINT"
      CANDIDATE_DEVICE="$(
        plutil \
          -extract "system-entities.$ENTITY_INDEX.dev-entry" raw \
          "$ATTACH_INFO_PLIST_PATH" \
          2>/dev/null \
          || true
      )"
      CANDIDATE_VOLUME_KIND="$(
        plutil \
          -extract "system-entities.$ENTITY_INDEX.volume-kind" raw \
          "$ATTACH_INFO_PLIST_PATH" \
          2>/dev/null \
          || true
      )"
    fi
  fi

  ENTITY_INDEX=$(( ENTITY_INDEX + 1 ))
done

if (( MATCHED_ENTITY_COUNT != 1 )); then
  PRESERVE_TEMPORARY_SCENE="true"
  fail "attach plist did not identify exactly one entity for the unique mount point"
fi
if ! [[ "$CANDIDATE_DEVICE" =~ ^/dev/disk[0-9]+(s[0-9]+)?$ ]]; then
  PRESERVE_TEMPORARY_SCENE="true"
  fail "attach plist returned an invalid device entry for the unique mount point"
fi

ATTACHED_DEVICE="$CANDIDATE_DEVICE"
ATTACHED_MOUNT_POINT="$CANDIDATE_MOUNT_POINT"
ATTACHED_VOLUME_KIND="$CANDIDATE_VOLUME_KIND"
ATTACHMENT_OWNERSHIP_CONFIRMED="true"

[[ "${ATTACHED_VOLUME_KIND:l}" == "apfs" ]] \
  || fail "validation DMG volume kind must be APFS, found: $ATTACHED_VOLUME_KIND"

TOP_LEVEL_ENTRIES=("$ATTACHED_MOUNT_POINT"/*(DN))
(( ${#TOP_LEVEL_ENTRIES[@]} == 2 )) \
  || fail "DMG top level must contain exactly the app and Applications link"
[[ -d "$ATTACHED_MOUNT_POINT/$APP_DISPLAY_NAME.app" \
  && ! -L "$ATTACHED_MOUNT_POINT/$APP_DISPLAY_NAME.app" ]] \
  || fail "DMG does not contain the expected app bundle"
[[ -L "$ATTACHED_MOUNT_POINT/Applications" ]] \
  || fail "DMG does not contain the Applications symbolic link"
[[ "$(readlink "$ATTACHED_MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "DMG Applications link must target /Applications"

echo "==> Verifying app signature inside DMG"
MOUNTED_APP_PATH="$ATTACHED_MOUNT_POINT/$APP_DISPLAY_NAME.app"
codesign --verify --strict --verbose=4 "$MOUNTED_APP_PATH"
MOUNTED_SIGNATURE_INFO="$(codesign -dvvv "$MOUNTED_APP_PATH" 2>&1)"
APP_CDHASH="$(
  printf "%s\n" "$APP_SIGNATURE_INFO" \
    | awk -F= '/^CDHash=/ { print $2; exit }'
)"
MOUNTED_CDHASH="$(
  printf "%s\n" "$MOUNTED_SIGNATURE_INFO" \
    | awk -F= '/^CDHash=/ { print $2; exit }'
)"
[[ -n "$APP_CDHASH" && "$MOUNTED_CDHASH" == "$APP_CDHASH" ]] \
  || fail "DMG app does not match the verified release app"

printf '%s\n' \
  "==> Release artifact verification passed" \
  "Binary: $BINARY_SIZE_BYTES bytes" \
  "Runtime resources apparent size: $RESOURCE_BUNDLE_SIZE_KIB KiB" \
  "App apparent size: $APP_SIZE_KIB KiB" \
  "DMG: $DMG_SIZE_BYTES bytes" \
  "Size budget warnings: $SIZE_BUDGET_WARNING_COUNT"
