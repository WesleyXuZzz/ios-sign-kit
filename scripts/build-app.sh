#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
  exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

zmodload zsh/datetime

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_METADATA_PATH="$PROJECT_ROOT/config/release-metadata.json"
REQUESTED_BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER-}"
REQUESTED_BUNDLE_VERSION="${BUNDLE_VERSION-}"
"$SCRIPT_DIR/validate-release-metadata.sh" "$RELEASE_METADATA_PATH"
APP_DISPLAY_NAME="$(plutil -extract appDisplayName raw "$RELEASE_METADATA_PATH")"
EXECUTABLE_NAME="$(plutil -extract executableName raw "$RELEASE_METADATA_PATH")"
BUNDLE_IDENTIFIER="$(plutil -extract bundleIdentifier raw "$RELEASE_METADATA_PATH")"
MARKETING_VERSION="$(plutil -extract marketingVersion raw "$RELEASE_METADATA_PATH")"
BUNDLE_VERSION="$(plutil -extract buildVersion raw "$RELEASE_METADATA_PATH")"
MACOS_DEPLOYMENT_TARGET="$(plutil -extract minimumMacOSVersion raw "$RELEASE_METADATA_PATH")"
BUILD_CACHE_PATH="$PROJECT_ROOT/.build"
BUILD_STARTED_AT="$EPOCHREALTIME"
OUTPUT_FORMAT="app"
FORMAT_SET="false"
CLEAN_BUILD="false"
SWIFT_CONFIGURATION="release"
RELEASE_DEBUG_INFO_FORMAT="${RELEASE_DEBUG_INFO_FORMAT:-none}"
IOS_SIGN_KIT_CODE_SIGN_IDENTITY="${IOS_SIGN_KIT_CODE_SIGN_IDENTITY:--}"
DMG_FILESYSTEM="APFS"
DMG_FORMAT="ULFO"
RUNTIME_RESOURCE_MANIFEST_PATH="$PROJECT_ROOT/config/runtime-resources.tsv"
RUNTIME_RESOURCE_FILE_NAMES=()
if [[ ! -f "$RUNTIME_RESOURCE_MANIFEST_PATH" || -L "$RUNTIME_RESOURCE_MANIFEST_PATH" ]]; then
  echo "Runtime resource manifest is missing or linked: $RUNTIME_RESOURCE_MANIFEST_PATH" >&2
  exit 1
fi
while IFS=$'\t' read -r RESOURCE_SOURCE_PATH RESOURCE_ROLE; do
  [[ -z "$RESOURCE_SOURCE_PATH" || "$RESOURCE_SOURCE_PATH" == \#* ]] && continue
  if [[ "$RESOURCE_ROLE" != "runtime" \
    && "$RESOURCE_ROLE" != "notification-attachment" ]]; then
    echo "Invalid runtime resource manifest entry: $RESOURCE_SOURCE_PATH" >&2
    exit 1
  fi
  SOURCE_TREE_RESOURCE_PATH="$PROJECT_ROOT/Sources/IOSSignKit/$RESOURCE_SOURCE_PATH"
  if [[ ! -f "$SOURCE_TREE_RESOURCE_PATH" || -L "$SOURCE_TREE_RESOURCE_PATH" ]]; then
    echo "Manifest runtime resource is missing or linked: $RESOURCE_SOURCE_PATH" >&2
    exit 1
  fi
  RUNTIME_RESOURCE_FILE_NAMES+=("${RESOURCE_SOURCE_PATH:t}")
done < "$RUNTIME_RESOURCE_MANIFEST_PATH"
(( ${#RUNTIME_RESOURCE_FILE_NAMES[@]} > 0 )) || {
  echo "Runtime resource manifest contains no entries." >&2
  exit 1
}
SWIFT_BUILD_EXTRA_OPTIONS=()
if [[ -n "${SWIFT_BUILD_OPTIONS:-}" ]]; then
  SWIFT_BUILD_EXTRA_OPTIONS=("${(@z)SWIFT_BUILD_OPTIONS}")
fi

usage() {
  echo "Usage: scripts/build-app.sh [app|dmg] [--debug] [--clean]" >&2
}

elapsed_since() {
  local STARTED_AT="$1"
  printf "%.2f" "$(( EPOCHREALTIME - STARTED_AT ))"
}

format_elapsed_clock() {
  local ELAPSED_SECONDS="$1"
  local -i TOTAL_SECONDS="${ELAPSED_SECONDS%%.*}"
  local -i HOURS=$(( TOTAL_SECONDS / 3600 ))
  local -i MINUTES=$(( (TOTAL_SECONDS % 3600) / 60 ))
  local -i SECONDS=$(( TOTAL_SECONDS % 60 ))

  if (( HOURS > 0 )); then
    printf "%02d:%02d:%02d" "$HOURS" "$MINUTES" "$SECONDS"
  else
    printf "%02d:%02d" "$MINUTES" "$SECONDS"
  fi
}

build_elapsed_clock() {
  format_elapsed_clock "$(elapsed_since "$BUILD_STARTED_AT")"
}

log_stage() {
  echo "==> [$(build_elapsed_clock)] $1"
}

log_stage_complete() {
  local MESSAGE="$1"
  local DURATION="$2"
  log_stage "$MESSAGE (${DURATION}s)"
}

format_bytes() {
  local BYTE_COUNT="$1"
  awk -v bytes="$BYTE_COUNT" 'BEGIN {
    if (bytes >= 1024 * 1024) {
      printf "%.1f MiB", bytes / (1024 * 1024)
    } else if (bytes >= 1024) {
      printf "%.1f KiB", bytes / 1024
    } else {
      printf "%d B", bytes
    }
  }'
}

app_tree_size_bytes() {
  local APP_PATH="$1"
  find "$APP_PATH" -type f -exec stat -f "%z" {} + \
    | awk '{ total += $1 } END { print total + 0 }'
}

clear_project_build_cache() {
  if [[ ! -e "$BUILD_CACHE_PATH" && ! -L "$BUILD_CACHE_PATH" ]]; then
    return
  fi

  if [[ ! -d "$BUILD_CACHE_PATH" || -L "$BUILD_CACHE_PATH" ]]; then
    echo "Refusing to clear unexpected build cache path: $BUILD_CACHE_PATH" >&2
    return 1
  fi

  /bin/rm -R -- "$BUILD_CACHE_PATH"
}

for ARG in "$@"; do
  case "$ARG" in
    dmg|app)
      if [[ "$FORMAT_SET" == "true" ]]; then
        usage
        exit 1
      fi
      OUTPUT_FORMAT="$ARG"
      FORMAT_SET="true"
      ;;
    --debug)
      SWIFT_CONFIGURATION="debug"
      APP_DISPLAY_NAME="${APP_DISPLAY_NAME}-Debug"
      ;;
    --clean)
      CLEAN_BUILD="true"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ "$SWIFT_CONFIGURATION" == "release" ]]; then
  if [[ -n "$REQUESTED_BUNDLE_IDENTIFIER" \
    && "$REQUESTED_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]]; then
    echo "Release Bundle ID is fixed by config/release-metadata.json; environment overrides are not allowed." >&2
    exit 1
  fi
  if [[ -n "$REQUESTED_BUNDLE_VERSION" \
    && "$REQUESTED_BUNDLE_VERSION" != "$BUNDLE_VERSION" ]]; then
    echo "Release build version is fixed by config/release-metadata.json; environment overrides are not allowed." >&2
    exit 1
  fi
fi

XCODE_VERSION_OUTPUT="$(xcodebuild -version)"
XCODE_VERSION="$(printf '%s\n' "$XCODE_VERSION_OUTPUT" | awk '/^Xcode / { print $2 }')"
XCODE_BUILD_VERSION="$(printf '%s\n' "$XCODE_VERSION_OUTPUT" | awk '/^Build version / { print $3 }')"
DT_XCODE="$(printf '%s\n' "$XCODE_VERSION" | awk -F. '{ printf "%d%d0", $1, $2 }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD_VERSION="$(xcrun --sdk macosx --show-sdk-build-version)"
BUILD_MACHINE_OS_BUILD="$(sw_vers -buildVersion)"

if [[ "$SWIFT_CONFIGURATION" == "release" ]]; then
  case "$RELEASE_DEBUG_INFO_FORMAT" in
    none|dwarf)
      ;;
    *)
      echo "Invalid RELEASE_DEBUG_INFO_FORMAT: $RELEASE_DEBUG_INFO_FORMAT" >&2
      echo "Expected one of: none, dwarf" >&2
      exit 1
      ;;
  esac

  SWIFT_BUILD_EXTRA_OPTIONS=(
    "-Xswiftc"
    "-Osize"
    "-Xswiftc"
    "-no-whole-module-optimization"
    "-debug-info-format"
    "$RELEASE_DEBUG_INFO_FORMAT"
    "${SWIFT_BUILD_EXTRA_OPTIONS[@]}"
  )
fi

BINARY_PATH=""
APP_ICON_COMPOSER_SOURCE="$PROJECT_ROOT/AppIcon.icon"
APP_ICON_ASSET_BUILD_ROOT="$BUILD_CACHE_PATH/generated-app-icon"
APP_ICON_CACHE_STATUS="not-used"
RESOURCE_BUNDLE_PATH=""
OUTPUT_ROOT="$PROJECT_ROOT/dist"
FINAL_APP_BUNDLE_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.app"
DMG_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.dmg"
APP_BUNDLE_PATH=""
STAGING_ROOT=""
DMG_SOURCE_ROOT=""
PREVIOUS_ROOT=""
PREVIOUS_APP_BUNDLE_PATH=""
PREVIOUS_DMG_PATH=""
STAGED_DMG_PATH=""
APP_WAS_PUBLISHED="false"
DMG_WAS_PUBLISHED="false"
BUILD_LOCK_PATH=""
BUILD_LOCK_HELD="false"
SWIFT_BUILD_DURATION="0.00"
APP_ICON_DURATION="0.00"
APP_ASSEMBLY_DURATION="0.00"
DMG_DURATION="skipped"
CACHE_CLEAN_DURATION="skipped"

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

cleanup_app_build() {
  local EXIT_STATUS=$?
  if (( $# == 1 )); then
    EXIT_STATUS="$1"
  fi
  local ROLLBACK_OK="true"
  local FAILED_DMG_PATH=""
  local FAILED_APP_BUNDLE_PATH=""

  trap - EXIT HUP INT TERM
  set +e

  if [[ -n "$STAGING_ROOT" ]]; then
    FAILED_DMG_PATH="$STAGING_ROOT/.failed-$APP_DISPLAY_NAME.dmg"
    FAILED_APP_BUNDLE_PATH="$STAGING_ROOT/.failed-$APP_DISPLAY_NAME.app"
  fi

  if [[ "$DMG_WAS_PUBLISHED" == "true" ]] \
    && [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
    if ! mv "$DMG_PATH" "$FAILED_DMG_PATH"; then
      echo "Rollback failed while preserving the newly published DMG: $DMG_PATH" >&2
      ROLLBACK_OK="false"
    fi
  fi

  if [[ -n "$PREVIOUS_DMG_PATH" ]] \
    && [[ -f "$PREVIOUS_DMG_PATH" && ! -L "$PREVIOUS_DMG_PATH" ]]; then
    if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
      echo "Rollback cannot restore the previous DMG because its destination is occupied: $DMG_PATH" >&2
      ROLLBACK_OK="false"
    elif ! mv "$PREVIOUS_DMG_PATH" "$DMG_PATH"; then
      echo "Rollback failed while restoring the previous DMG: $PREVIOUS_DMG_PATH" >&2
      ROLLBACK_OK="false"
    fi
  fi

  if [[ -n "$PREVIOUS_APP_BUNDLE_PATH" ]] \
    && [[ -e "$PREVIOUS_APP_BUNDLE_PATH" || -L "$PREVIOUS_APP_BUNDLE_PATH" ]]; then
    if [[ -e "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
      if ! mv "$FINAL_APP_BUNDLE_PATH" "$FAILED_APP_BUNDLE_PATH"; then
        echo "Rollback failed while preserving the newly published app: $FINAL_APP_BUNDLE_PATH" >&2
        ROLLBACK_OK="false"
      fi
    fi
    if [[ -e "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
      echo "Rollback cannot restore the previous app because its destination is occupied: $FINAL_APP_BUNDLE_PATH" >&2
      ROLLBACK_OK="false"
    elif ! mv "$PREVIOUS_APP_BUNDLE_PATH" "$FINAL_APP_BUNDLE_PATH"; then
      echo "Rollback failed while restoring the previous app: $PREVIOUS_APP_BUNDLE_PATH" >&2
      ROLLBACK_OK="false"
    fi
  elif [[ "$APP_WAS_PUBLISHED" == "true" ]] \
    && [[ -e "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
    if ! mv "$FINAL_APP_BUNDLE_PATH" "$FAILED_APP_BUNDLE_PATH"; then
      echo "Rollback failed while preserving the newly published app: $FINAL_APP_BUNDLE_PATH" >&2
      ROLLBACK_OK="false"
    fi
  fi

  if [[ "$ROLLBACK_OK" == "true" ]]; then
    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
      /bin/rm -R -- "$STAGING_ROOT"
    fi
    if [[ -n "$PREVIOUS_ROOT" && -d "$PREVIOUS_ROOT" && ! -L "$PREVIOUS_ROOT" ]]; then
      /bin/rm -R -- "$PREVIOUS_ROOT"
    fi
  else
    echo "Rollback was incomplete; preserving recovery data." >&2
    if [[ -n "$STAGING_ROOT" ]]; then
      echo "Staging path: $STAGING_ROOT" >&2
    fi
    if [[ -n "$PREVIOUS_ROOT" ]]; then
      echo "Previous artifacts path: $PREVIOUS_ROOT" >&2
    fi
  fi

  release_build_lock
  exit "$EXIT_STATUS"
}

publish_app_bundle() {
  if [[ -e "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
    if [[ ! -d "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
      echo "Refusing to replace unexpected app bundle path: $FINAL_APP_BUNDLE_PATH" >&2
      return 1
    fi

    PREVIOUS_ROOT="$(mktemp -d "$OUTPUT_ROOT/.${APP_DISPLAY_NAME}.previous.XXXXXX")"
    PREVIOUS_APP_BUNDLE_PATH="$PREVIOUS_ROOT/$APP_DISPLAY_NAME.app"
    mv "$FINAL_APP_BUNDLE_PATH" "$PREVIOUS_APP_BUNDLE_PATH"
  fi

  APP_WAS_PUBLISHED="true"
  mv "$APP_BUNDLE_PATH" "$FINAL_APP_BUNDLE_PATH"

  APP_BUNDLE_PATH="$FINAL_APP_BUNDLE_PATH"
}

commit_publication() {
  local COMMITTED_PREVIOUS_ROOT="$PREVIOUS_ROOT"
  local COMMITTED_STAGING_ROOT="$STAGING_ROOT"
  local COMMITTED_DMG_SOURCE_ROOT="$DMG_SOURCE_ROOT"

  trap - EXIT HUP INT TERM
  APP_WAS_PUBLISHED="false"
  DMG_WAS_PUBLISHED="false"
  PREVIOUS_ROOT=""
  PREVIOUS_APP_BUNDLE_PATH=""
  PREVIOUS_DMG_PATH=""
  STAGING_ROOT=""
  DMG_SOURCE_ROOT=""

  if [[ -n "$COMMITTED_PREVIOUS_ROOT" ]] \
    && [[ -d "$COMMITTED_PREVIOUS_ROOT" && ! -L "$COMMITTED_PREVIOUS_ROOT" ]]; then
    if ! /bin/rm -R -- "$COMMITTED_PREVIOUS_ROOT"; then
      echo "Warning: committed build, but failed to remove previous artifacts: $COMMITTED_PREVIOUS_ROOT" >&2
    fi
  fi

  if [[ -n "$COMMITTED_DMG_SOURCE_ROOT" ]] \
    && [[ -d "$COMMITTED_DMG_SOURCE_ROOT" && ! -L "$COMMITTED_DMG_SOURCE_ROOT" ]]; then
    if ! rmdir "$COMMITTED_DMG_SOURCE_ROOT"; then
      echo "Warning: committed build, but DMG source directory is not empty: $COMMITTED_DMG_SOURCE_ROOT" >&2
    fi
  fi

  if [[ -n "$COMMITTED_STAGING_ROOT" ]] \
    && [[ -d "$COMMITTED_STAGING_ROOT" && ! -L "$COMMITTED_STAGING_ROOT" ]]; then
    if ! rmdir "$COMMITTED_STAGING_ROOT"; then
      echo "Warning: committed build, but staging is not empty: $COMMITTED_STAGING_ROOT" >&2
    fi
  fi

  release_build_lock
}

validate_publication_targets() {
  if [[ -e "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]] \
    && [[ ! -d "$FINAL_APP_BUNDLE_PATH" || -L "$FINAL_APP_BUNDLE_PATH" ]]; then
    echo "Refusing to replace unexpected app bundle path: $FINAL_APP_BUNDLE_PATH" >&2
    return 1
  fi

  if [[ "$OUTPUT_FORMAT" == "dmg" ]] \
    && [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]] \
    && [[ ! -f "$DMG_PATH" || -L "$DMG_PATH" ]]; then
    echo "Refusing to replace unexpected DMG path: $DMG_PATH" >&2
    return 1
  fi
}

cleanup_app_icon_compile_directory() {
  local COMPILE_DIRECTORY="$1"
  local GENERATED_PATH

  for GENERATED_PATH in \
    "$COMPILE_DIRECTORY/Assets.car" \
    "$COMPILE_DIRECTORY/AppIcon.icns" \
    "$COMPILE_DIRECTORY/asset-info.plist"; do
    if [[ -f "$GENERATED_PATH" && ! -L "$GENERATED_PATH" ]]; then
      unlink "$GENERATED_PATH"
    fi
  done

  if [[ -d "$COMPILE_DIRECTORY" && ! -L "$COMPILE_DIRECTORY" ]] \
    && ! rmdir "$COMPILE_DIRECTORY"; then
    echo "Warning: app icon compile directory is not empty: $COMPILE_DIRECTORY" >&2
  fi
}

copy_runtime_resource_bundle() {
  local RESOURCE_FILE_NAME
  local SOURCE_RESOURCE_PATH
  local DESTINATION_RESOURCE_PATH

  if [[ ! -d "$RESOURCE_BUNDLE_PATH" || -L "$RESOURCE_BUNDLE_PATH" ]]; then
    echo "Required resource bundle was not found at: $RESOURCE_BUNDLE_PATH" >&2
    return 1
  fi

  mkdir -p "$BUNDLED_RESOURCE_PATH"
  for RESOURCE_FILE_NAME in "${RUNTIME_RESOURCE_FILE_NAMES[@]}"; do
    SOURCE_RESOURCE_PATH="$RESOURCE_BUNDLE_PATH/$RESOURCE_FILE_NAME"
    DESTINATION_RESOURCE_PATH="$BUNDLED_RESOURCE_PATH/$RESOURCE_FILE_NAME"
    if [[ ! -f "$SOURCE_RESOURCE_PATH" || -L "$SOURCE_RESOURCE_PATH" ]]; then
      echo "Required runtime resource was not found: $SOURCE_RESOURCE_PATH" >&2
      return 1
    fi
    cp "$SOURCE_RESOURCE_PATH" "$DESTINATION_RESOURCE_PATH"
  done
}

compile_app_icon_assets() {
  local SOURCE_FINGERPRINT
  local CACHE_KEY
  local CACHE_DIRECTORY
  local CACHED_ASSETS_CAR
  local CACHE_SUCCESS_MARKER
  local COMPILE_DIRECTORY
  local COMPILED_ASSETS_CAR
  local COMPILED_PARTIAL_PLIST
  local PENDING_ASSETS_CAR
  local PENDING_SUCCESS_MARKER
  local CACHE_MARKER_VALUE=""

  if [[ ! -d "$APP_ICON_COMPOSER_SOURCE" ]]; then
    echo "App Icon Composer document was not found at: $APP_ICON_COMPOSER_SOURCE" >&2
    return 1
  fi

  mkdir -p "$APP_ICON_ASSET_BUILD_ROOT"

  SOURCE_FINGERPRINT="$(
    find -s "$APP_ICON_COMPOSER_SOURCE" -type f -exec shasum -a 256 {} \; \
      | shasum -a 256 \
      | awk '{ print $1 }'
  )"
  CACHE_KEY="$(
    printf '%s\n' \
      "$SOURCE_FINGERPRINT" \
      "$XCODE_BUILD_VERSION" \
      "$SDK_BUILD_VERSION" \
      "cache-schema=1" \
      "platform=macosx" \
      "$MACOS_DEPLOYMENT_TARGET" \
      "target-device=mac" \
      "app-icon=AppIcon" \
      "standalone-icon-behavior=none" \
      | shasum -a 256 \
      | awk '{ print $1 }'
  )"
  CACHE_DIRECTORY="$APP_ICON_ASSET_BUILD_ROOT/$CACHE_KEY"
  CACHED_ASSETS_CAR="$CACHE_DIRECTORY/Assets.car"
  CACHE_SUCCESS_MARKER="$CACHE_DIRECTORY/.complete"

  if [[ -e "$CACHE_DIRECTORY" || -L "$CACHE_DIRECTORY" ]] \
    && [[ ! -d "$CACHE_DIRECTORY" || -L "$CACHE_DIRECTORY" ]]; then
    echo "Refusing to use unexpected app icon cache path: $CACHE_DIRECTORY" >&2
    return 1
  fi

  if [[ -e "$CACHED_ASSETS_CAR" || -L "$CACHED_ASSETS_CAR" ]] \
    && [[ ! -f "$CACHED_ASSETS_CAR" || -L "$CACHED_ASSETS_CAR" ]]; then
    echo "Refusing to use unexpected cached Assets.car path: $CACHED_ASSETS_CAR" >&2
    return 1
  fi

  if [[ -e "$CACHE_SUCCESS_MARKER" || -L "$CACHE_SUCCESS_MARKER" ]] \
    && [[ ! -f "$CACHE_SUCCESS_MARKER" || -L "$CACHE_SUCCESS_MARKER" ]]; then
    echo "Refusing to use unexpected app icon cache marker: $CACHE_SUCCESS_MARKER" >&2
    return 1
  fi

  if [[ -f "$CACHE_SUCCESS_MARKER" && -s "$CACHE_SUCCESS_MARKER" ]]; then
    CACHE_MARKER_VALUE="$(< "$CACHE_SUCCESS_MARKER")"
  fi

  if [[ -f "$CACHED_ASSETS_CAR" && -s "$CACHED_ASSETS_CAR" ]] \
    && [[ "$CACHE_MARKER_VALUE" == "$CACHE_KEY" ]] \
    && xcrun assetutil --info "$CACHED_ASSETS_CAR" >/dev/null 2>&1; then
    APP_ICON_CACHE_STATUS="hit"
    log_stage "Reusing cached App Icon assets"
  else
    APP_ICON_CACHE_STATUS="miss"
    mkdir -p "$CACHE_DIRECTORY"
    COMPILE_DIRECTORY="$(mktemp -d "$APP_ICON_ASSET_BUILD_ROOT/.compile.XXXXXX")"
    COMPILED_ASSETS_CAR="$COMPILE_DIRECTORY/Assets.car"
    COMPILED_PARTIAL_PLIST="$COMPILE_DIRECTORY/asset-info.plist"
    log_stage "Compiling App Icon Composer document"
    if ! xcrun actool \
      --compile "$COMPILE_DIRECTORY" \
      --platform macosx \
      --minimum-deployment-target "$MACOS_DEPLOYMENT_TARGET" \
      --target-device mac \
      --app-icon AppIcon \
      --standalone-icon-behavior none \
      --output-partial-info-plist "$COMPILED_PARTIAL_PLIST" \
      --output-format human-readable-text \
      --warnings \
      --notices \
      --errors \
      "$APP_ICON_COMPOSER_SOURCE"; then
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi

    if [[ ! -s "$COMPILED_ASSETS_CAR" || -L "$COMPILED_ASSETS_CAR" ]] \
      || ! xcrun assetutil --info "$COMPILED_ASSETS_CAR" >/dev/null 2>&1; then
      echo "App Icon compilation did not produce a valid Assets.car file" >&2
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi

    if ! PENDING_ASSETS_CAR="$(mktemp "$CACHE_DIRECTORY/.Assets.car.XXXXXX")"; then
      echo "Failed to create a pending App Icon cache file" >&2
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi
    if ! cp "$COMPILED_ASSETS_CAR" "$PENDING_ASSETS_CAR" \
      || ! mv "$PENDING_ASSETS_CAR" "$CACHED_ASSETS_CAR"; then
      echo "Failed to publish the compiled App Icon cache" >&2
      if [[ -f "$PENDING_ASSETS_CAR" && ! -L "$PENDING_ASSETS_CAR" ]]; then
        unlink "$PENDING_ASSETS_CAR"
      fi
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi

    if ! PENDING_SUCCESS_MARKER="$(mktemp "$CACHE_DIRECTORY/.complete.XXXXXX")"; then
      echo "Failed to create a pending App Icon cache marker" >&2
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi
    if ! printf '%s\n' "$CACHE_KEY" > "$PENDING_SUCCESS_MARKER" \
      || ! mv "$PENDING_SUCCESS_MARKER" "$CACHE_SUCCESS_MARKER"; then
      echo "Failed to mark the compiled App Icon cache as complete" >&2
      if [[ -f "$PENDING_SUCCESS_MARKER" && ! -L "$PENDING_SUCCESS_MARKER" ]]; then
        unlink "$PENDING_SUCCESS_MARKER"
      fi
      cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
      return 1
    fi

    cleanup_app_icon_compile_directory "$COMPILE_DIRECTORY"
  fi

  if [[ ! -f "$CACHED_ASSETS_CAR" || ! -s "$CACHED_ASSETS_CAR" ]] \
    || [[ -L "$CACHED_ASSETS_CAR" ]]; then
    echo "App Icon compilation did not produce a regular Assets.car file" >&2
    return 1
  fi

  cp "$CACHED_ASSETS_CAR" "$RESOURCES_PATH/Assets.car"
}

create_dmg() (
  local APPLICATIONS_LINK="$DMG_SOURCE_ROOT/Applications"
  local ACTUAL_DMG_FORMAT

  cleanup_dmg() {
    if [[ -L "$APPLICATIONS_LINK" ]]; then
      unlink "$APPLICATIONS_LINK"
    fi
  }

  trap cleanup_dmg EXIT

  if [[ -e "$APPLICATIONS_LINK" || -L "$APPLICATIONS_LINK" ]]; then
    echo "Refusing to replace unexpected Applications link path: $APPLICATIONS_LINK" >&2
    return 1
  fi

  ln -s /Applications "$APPLICATIONS_LINK"

  log_stage "Creating staged DMG"
  hdiutil create \
    -quiet \
    -srcfolder "$DMG_SOURCE_ROOT" \
    -fs "$DMG_FILESYSTEM" \
    -volname "$APP_DISPLAY_NAME" \
    -format "$DMG_FORMAT" \
    "$STAGED_DMG_PATH"
  if [[ ! -f "$STAGED_DMG_PATH" || -L "$STAGED_DMG_PATH" ]]; then
    echo "Staged DMG is not a regular file: $STAGED_DMG_PATH" >&2
    return 1
  fi
  hdiutil verify "$STAGED_DMG_PATH" >/dev/null
  ACTUAL_DMG_FORMAT="$(hdiutil imageinfo -format "$STAGED_DMG_PATH")"
  if [[ "$ACTUAL_DMG_FORMAT" != "$DMG_FORMAT" ]]; then
    echo "Unexpected staged DMG format: $ACTUAL_DMG_FORMAT" >&2
    return 1
  fi

  trap - EXIT
  cleanup_dmg
)

mkdir -p "$OUTPUT_ROOT"

BUILD_LOCK_PATH="$OUTPUT_ROOT/.build-app.lock"
if ! /usr/bin/shlock -f "$BUILD_LOCK_PATH" -p "$$"; then
  if [[ -f "$BUILD_LOCK_PATH" && ! -L "$BUILD_LOCK_PATH" ]]; then
    echo "Another app build is already running with PID $(< "$BUILD_LOCK_PATH")" >&2
  else
    echo "Another app build is already running" >&2
  fi
  exit 1
fi
BUILD_LOCK_HELD="true"
trap cleanup_app_build EXIT
trap 'cleanup_app_build 129' HUP
trap 'cleanup_app_build 130' INT
trap 'cleanup_app_build 143' TERM

if [[ "$CLEAN_BUILD" == "true" ]]; then
  CACHE_CLEAN_STARTED_AT="$EPOCHREALTIME"
  log_stage "Clearing project build cache for cold build"
  clear_project_build_cache
  CACHE_CLEAN_DURATION="$(elapsed_since "$CACHE_CLEAN_STARTED_AT")"
  log_stage_complete "Project build cache cleared" "$CACHE_CLEAN_DURATION"
fi

SWIFT_BUILD_STARTED_AT="$EPOCHREALTIME"
log_stage "Building $SWIFT_CONFIGURATION binary"
swift build -c "$SWIFT_CONFIGURATION" --product "$EXECUTABLE_NAME" "${SWIFT_BUILD_EXTRA_OPTIONS[@]}"
SWIFT_BUILD_DURATION="$(elapsed_since "$SWIFT_BUILD_STARTED_AT")"
log_stage_complete "Swift build complete" "$SWIFT_BUILD_DURATION"
SWIFT_BIN_DIRECTORY="$(swift build -c "$SWIFT_CONFIGURATION" --show-bin-path "${SWIFT_BUILD_EXTRA_OPTIONS[@]}")"
BINARY_PATH="$SWIFT_BIN_DIRECTORY/$EXECUTABLE_NAME"
RESOURCE_BUNDLE_PATH="$SWIFT_BIN_DIRECTORY/ios-sign-kit_IOSSignKit.bundle"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build succeeded but binary was not found at: $BINARY_PATH" >&2
  exit 1
fi

STAGING_ROOT="$(mktemp -d "$OUTPUT_ROOT/.${APP_DISPLAY_NAME}.staging.XXXXXX")"
STAGED_DMG_PATH="$STAGING_ROOT/$APP_DISPLAY_NAME.dmg"
if [[ "$OUTPUT_FORMAT" == "dmg" ]]; then
  DMG_SOURCE_ROOT="$STAGING_ROOT/dmg-source"
  mkdir "$DMG_SOURCE_ROOT"
  APP_BUNDLE_PATH="$DMG_SOURCE_ROOT/$APP_DISPLAY_NAME.app"
else
  APP_BUNDLE_PATH="$STAGING_ROOT/$APP_DISPLAY_NAME.app"
fi
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
PLIST_PATH="$CONTENTS_PATH/Info.plist"
BUNDLED_RESOURCE_PATH="$RESOURCES_PATH/ios-sign-kit_IOSSignKit.bundle"

APP_ASSEMBLY_STARTED_AT="$EPOCHREALTIME"
log_stage "Creating new app bundle for $FINAL_APP_BUNDLE_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

cp "$BINARY_PATH" "$MACOS_PATH/$EXECUTABLE_NAME"
chmod +x "$MACOS_PATH/$EXECUTABLE_NAME"

APP_ICON_STARTED_AT="$EPOCHREALTIME"
compile_app_icon_assets
APP_ICON_DURATION="$(elapsed_since "$APP_ICON_STARTED_AT")"
log_stage "App Icon ready (${APP_ICON_DURATION}s, cache: $APP_ICON_CACHE_STATUS)"

copy_runtime_resource_bundle

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>BuildMachineOSBuild</key>
  <string>$BUILD_MACHINE_OS_BUILD</string>
  <key>DTCompiler</key>
  <string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key>
  <string>$SDK_BUILD_VERSION</string>
  <key>DTPlatformName</key>
  <string>macosx</string>
  <key>DTPlatformVersion</key>
  <string>$SDK_VERSION</string>
  <key>DTSDKBuild</key>
  <string>$SDK_BUILD_VERSION</string>
  <key>DTSDKName</key>
  <string>macosx$SDK_VERSION</string>
  <key>DTXcode</key>
  <string>$DT_XCODE</string>
  <key>DTXcodeBuild</key>
  <string>$XCODE_BUILD_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MACOS_DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>允许附近的 iPhone 通过同一局域网访问 iOSSignKit 控制页。</string>
</dict>
</plist>
PLIST

if [[ "$SWIFT_CONFIGURATION" == "release" ]]; then
  log_stage "Stripping local symbols from release binary"
  xcrun strip -x "$MACOS_PATH/$EXECUTABLE_NAME"
fi

if [[ "$IOS_SIGN_KIT_CODE_SIGN_IDENTITY" == "-" ]]; then
  log_stage "Ad-hoc signing app bundle"
else
  log_stage "Signing app bundle with configured identity"
fi
codesign --force --sign "$IOS_SIGN_KIT_CODE_SIGN_IDENTITY" "$APP_BUNDLE_PATH"

log_stage "Verifying app bundle"
codesign --verify --strict "$APP_BUNDLE_PATH"
APP_ASSEMBLY_DURATION="$(elapsed_since "$APP_ASSEMBLY_STARTED_AT")"
log_stage_complete "App assembly complete" "$APP_ASSEMBLY_DURATION"

if [[ "$OUTPUT_FORMAT" == "dmg" ]]; then
  DMG_STARTED_AT="$EPOCHREALTIME"
  create_dmg
  DMG_DURATION="$(elapsed_since "$DMG_STARTED_AT")"
  log_stage_complete "DMG creation complete" "$DMG_DURATION"
fi

validate_publication_targets

log_stage "Replacing app bundle at $FINAL_APP_BUNDLE_PATH"
publish_app_bundle

if [[ "$OUTPUT_FORMAT" == "dmg" ]]; then
  if [[ ! -f "$STAGED_DMG_PATH" || -L "$STAGED_DMG_PATH" ]]; then
    echo "Refusing to publish an invalid staged DMG: $STAGED_DMG_PATH" >&2
    exit 1
  fi
  if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]] \
    && [[ ! -f "$DMG_PATH" || -L "$DMG_PATH" ]]; then
    echo "Refusing to replace unexpected DMG path: $DMG_PATH" >&2
    exit 1
  fi
  if [[ -f "$DMG_PATH" && ! -L "$DMG_PATH" ]]; then
    if [[ -z "$PREVIOUS_ROOT" ]]; then
      PREVIOUS_ROOT="$(mktemp -d "$OUTPUT_ROOT/.${APP_DISPLAY_NAME}.previous.XXXXXX")"
    fi
    PREVIOUS_DMG_PATH="$PREVIOUS_ROOT/$APP_DISPLAY_NAME.dmg"
    mv "$DMG_PATH" "$PREVIOUS_DMG_PATH"
  fi
  log_stage "Publishing DMG at $DMG_PATH"
  DMG_WAS_PUBLISHED="true"
  mv "$STAGED_DMG_PATH" "$DMG_PATH"
fi

commit_publication

TOTAL_DURATION="$(elapsed_since "$BUILD_STARTED_AT")"
APP_SIZE_BYTES="$(app_tree_size_bytes "$APP_BUNDLE_PATH")"
BINARY_SIZE_BYTES="$(stat -f "%z" "$APP_BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME")"
APP_SIZE="$(format_bytes "$APP_SIZE_BYTES")"
BINARY_SIZE="$(format_bytes "$BINARY_SIZE_BYTES")"

log_stage "Build metrics"
if [[ "$CACHE_CLEAN_DURATION" == "skipped" ]]; then
  echo "Cache cleanup: skipped"
else
  echo "Cache cleanup: ${CACHE_CLEAN_DURATION}s (included in total)"
fi
if [[ "$SWIFT_CONFIGURATION" == "release" ]]; then
  echo "Release debug info: $RELEASE_DEBUG_INFO_FORMAT"
fi
echo "Swift build: ${SWIFT_BUILD_DURATION}s"
echo "App Icon: ${APP_ICON_DURATION}s (cache: $APP_ICON_CACHE_STATUS)"
echo "App assembly: ${APP_ASSEMBLY_DURATION}s"
if [[ "$DMG_DURATION" == "skipped" ]]; then
  echo "DMG creation: skipped"
else
  echo "DMG creation: ${DMG_DURATION}s"
fi
echo "Total: ${TOTAL_DURATION}s"
echo "Binary size: $BINARY_SIZE"
echo "App size: $APP_SIZE"
if [[ "$OUTPUT_FORMAT" == "dmg" ]]; then
  DMG_SIZE_BYTES="$(stat -f "%z" "$DMG_PATH")"
  DMG_SIZE="$(format_bytes "$DMG_SIZE_BYTES")"
  echo "DMG size: $DMG_SIZE"
fi

log_stage "Build complete"
if [[ "$OUTPUT_FORMAT" == "dmg" ]]; then
  echo "$DMG_PATH"
else
  echo "$APP_BUNDLE_PATH"
fi
