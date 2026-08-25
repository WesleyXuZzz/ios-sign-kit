#!/bin/zsh

if [ -z "${ZSH_VERSION:-}" ]; then
  exec /bin/zsh "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_METADATA_PATH="$PROJECT_ROOT/config/release-metadata.json"
OUTPUT_ROOT="$PROJECT_ROOT/dist"
APPLICATIONS_DIRECTORY="${IOS_SIGN_KIT_APPLICATIONS_DIRECTORY:-/Applications}"
TRASH_DIRECTORY="${IOS_SIGN_KIT_TRASH_DIRECTORY:-$HOME/.Trash}"
DRY_RUN="false"

usage() {
  echo "Usage: scripts/install-app.sh [--dry-run]" >&2
}

for ARG in "$@"; do
  case "$ARG" in
    --dry-run)
      if [[ "$DRY_RUN" == "true" ]]; then
        usage
        exit 1
      fi
      DRY_RUN="true"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

"$SCRIPT_DIR/validate-release-metadata.sh" "$RELEASE_METADATA_PATH"
APP_DISPLAY_NAME="$(plutil -extract appDisplayName raw "$RELEASE_METADATA_PATH")"
EXECUTABLE_NAME="$(plutil -extract executableName raw "$RELEASE_METADATA_PATH")"
BUNDLE_IDENTIFIER="$(plutil -extract bundleIdentifier raw "$RELEASE_METADATA_PATH")"

SOURCE_APP_PATH="$OUTPUT_ROOT/$APP_DISPLAY_NAME.app"
TARGET_APP_PATH="$APPLICATIONS_DIRECTORY/$APP_DISPLAY_NAME.app"
STAGED_APP_PATH="$APPLICATIONS_DIRECTORY/.$APP_DISPLAY_NAME.installing.$$.$RANDOM.app"
INSTALL_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PREVIOUS_APP_PATH="$TRASH_DIRECTORY/$APP_DISPLAY_NAME-previous-$INSTALL_TIMESTAMP-$$.app"
BUILD_LOCK_PATH="$OUTPUT_ROOT/.build-app.lock"
BUILD_LOCK_HELD="false"
NEW_APP_LOCATION="source"
PREVIOUS_APP_MOVED="false"
INSTALL_COMMITTED="false"

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

validate_app_bundle() {
  local APP_PATH="$1"
  local INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"
  local EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
  local ACTUAL_BUNDLE_IDENTIFIER
  local ACTUAL_EXECUTABLE_NAME

  if [[ ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
    echo "App bundle is missing, not a directory, or linked: $APP_PATH" >&2
    return 1
  fi
  if [[ ! -f "$INFO_PLIST_PATH" || -L "$INFO_PLIST_PATH" ]]; then
    echo "App Info.plist is missing or linked: $INFO_PLIST_PATH" >&2
    return 1
  fi

  ACTUAL_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST_PATH" 2>/dev/null)" || {
    echo "App Info.plist does not contain a valid CFBundleIdentifier: $INFO_PLIST_PATH" >&2
    return 1
  }
  ACTUAL_EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$INFO_PLIST_PATH" 2>/dev/null)" || {
    echo "App Info.plist does not contain a valid CFBundleExecutable: $INFO_PLIST_PATH" >&2
    return 1
  }

  if [[ "$ACTUAL_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]]; then
    echo "Unexpected app Bundle ID at $APP_PATH: $ACTUAL_BUNDLE_IDENTIFIER" >&2
    return 1
  fi
  if [[ "$ACTUAL_EXECUTABLE_NAME" != "$EXECUTABLE_NAME" ]]; then
    echo "Unexpected app executable at $APP_PATH: $ACTUAL_EXECUTABLE_NAME" >&2
    return 1
  fi
  if [[ ! -f "$EXECUTABLE_PATH" || -L "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
    echo "App executable is missing, linked, or not executable: $EXECUTABLE_PATH" >&2
    return 1
  fi
  if ! codesign --verify --strict "$APP_PATH"; then
    echo "App code signature verification failed: $APP_PATH" >&2
    return 1
  fi
}

validate_existing_target() {
  local INFO_PLIST_PATH="$TARGET_APP_PATH/Contents/Info.plist"
  local ACTUAL_BUNDLE_IDENTIFIER

  if [[ ! -d "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
    echo "Refusing to replace an unexpected application path: $TARGET_APP_PATH" >&2
    return 1
  fi
  if [[ ! -f "$INFO_PLIST_PATH" || -L "$INFO_PLIST_PATH" ]]; then
    echo "Refusing to replace an application without a regular Info.plist: $TARGET_APP_PATH" >&2
    return 1
  fi

  ACTUAL_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST_PATH" 2>/dev/null)" || {
    echo "Refusing to replace an application with an unreadable Bundle ID: $TARGET_APP_PATH" >&2
    return 1
  }
  if [[ "$ACTUAL_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]]; then
    echo "Refusing to replace an application with Bundle ID $ACTUAL_BUNDLE_IDENTIFIER: $TARGET_APP_PATH" >&2
    return 1
  fi
}

rollback_install() {
  local ROLLBACK_OK="true"

  set +e

  if [[ "$NEW_APP_LOCATION" == "target" ]]; then
    if [[ -e "$SOURCE_APP_PATH" || -L "$SOURCE_APP_PATH" ]]; then
      NEW_APP_LOCATION="source"
    elif [[ -e "$STAGED_APP_PATH" || -L "$STAGED_APP_PATH" ]]; then
      if ! /bin/mv "$STAGED_APP_PATH" "$SOURCE_APP_PATH"; then
        echo "Rollback failed while restoring the staged app to: $SOURCE_APP_PATH" >&2
        ROLLBACK_OK="false"
      else
        NEW_APP_LOCATION="source"
      fi
    elif [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
      if ! /bin/mv "$TARGET_APP_PATH" "$SOURCE_APP_PATH"; then
        echo "Rollback failed while restoring the new app to: $SOURCE_APP_PATH" >&2
        ROLLBACK_OK="false"
      else
        NEW_APP_LOCATION="source"
      fi
    else
      echo "Rollback cannot find the new app in its source, staging, or target path." >&2
      ROLLBACK_OK="false"
    fi
  elif [[ "$NEW_APP_LOCATION" == "staged" ]]; then
    if [[ -e "$SOURCE_APP_PATH" || -L "$SOURCE_APP_PATH" ]]; then
      NEW_APP_LOCATION="source"
    elif [[ -e "$STAGED_APP_PATH" || -L "$STAGED_APP_PATH" ]]; then
      if ! /bin/mv "$STAGED_APP_PATH" "$SOURCE_APP_PATH"; then
        echo "Rollback failed while restoring the staged app to: $SOURCE_APP_PATH" >&2
        ROLLBACK_OK="false"
      else
        NEW_APP_LOCATION="source"
      fi
    else
      echo "Rollback cannot find the staged app at: $STAGED_APP_PATH" >&2
      ROLLBACK_OK="false"
    fi
  fi

  if [[ "$PREVIOUS_APP_MOVED" == "true" ]]; then
    if [[ -e "$PREVIOUS_APP_PATH" || -L "$PREVIOUS_APP_PATH" ]]; then
      if [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
        echo "Rollback cannot restore the previous app because its destination is occupied: $TARGET_APP_PATH" >&2
        ROLLBACK_OK="false"
      elif ! /bin/mv "$PREVIOUS_APP_PATH" "$TARGET_APP_PATH"; then
        echo "Rollback failed while restoring the previous app from: $PREVIOUS_APP_PATH" >&2
        ROLLBACK_OK="false"
      else
        PREVIOUS_APP_MOVED="false"
      fi
    elif [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
      PREVIOUS_APP_MOVED="false"
    else
      echo "Rollback cannot find the previous app at: $PREVIOUS_APP_PATH" >&2
      ROLLBACK_OK="false"
    fi
  fi

  if [[ "$ROLLBACK_OK" != "true" ]]; then
    echo "Installation rollback was incomplete; inspect these paths before retrying:" >&2
    echo "  Source: $SOURCE_APP_PATH" >&2
    echo "  Staging: $STAGED_APP_PATH" >&2
    echo "  Target: $TARGET_APP_PATH" >&2
    echo "  Previous: $PREVIOUS_APP_PATH" >&2
  fi
}

cleanup_install() {
  local EXIT_STATUS=$?

  trap - EXIT HUP INT TERM
  if [[ "$INSTALL_COMMITTED" != "true" ]]; then
    rollback_install
  fi
  release_build_lock
  exit "$EXIT_STATUS"
}

if [[ ! -d "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
  echo "Build output directory is missing or linked: $OUTPUT_ROOT" >&2
  exit 1
fi
if ! /usr/bin/shlock -f "$BUILD_LOCK_PATH" -p "$$"; then
  if [[ -f "$BUILD_LOCK_PATH" && ! -L "$BUILD_LOCK_PATH" ]]; then
    echo "Another app build or installation is already running with PID $(< "$BUILD_LOCK_PATH")" >&2
  else
    echo "Another app build or installation is already running" >&2
  fi
  exit 1
fi
BUILD_LOCK_HELD="true"
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

validate_app_bundle "$SOURCE_APP_PATH"

if [[ ! -d "$APPLICATIONS_DIRECTORY" || -L "$APPLICATIONS_DIRECTORY" ]]; then
  echo "Applications directory is missing, not a directory, or linked: $APPLICATIONS_DIRECTORY" >&2
  exit 1
fi
if [[ ! -w "$APPLICATIONS_DIRECTORY" ]]; then
  echo "Applications directory is not writable: $APPLICATIONS_DIRECTORY" >&2
  echo "Run the script from an account that can write to this directory." >&2
  exit 1
fi
if [[ -e "$STAGED_APP_PATH" || -L "$STAGED_APP_PATH" ]]; then
  echo "Refusing to replace an existing staging path: $STAGED_APP_PATH" >&2
  exit 1
fi

if [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
  validate_existing_target
  if [[ ! -d "$TRASH_DIRECTORY" || -L "$TRASH_DIRECTORY" ]]; then
    echo "Trash directory is missing, not a directory, or linked: $TRASH_DIRECTORY" >&2
    exit 1
  fi
  if [[ ! -w "$TRASH_DIRECTORY" ]]; then
    echo "Trash directory is not writable: $TRASH_DIRECTORY" >&2
    exit 1
  fi
  if [[ -e "$PREVIOUS_APP_PATH" || -L "$PREVIOUS_APP_PATH" ]]; then
    echo "Refusing to replace an existing backup path: $PREVIOUS_APP_PATH" >&2
    exit 1
  fi
fi

RUNNING_PIDS="$(pgrep -x "$EXECUTABLE_NAME" || true)"
if [[ -n "$RUNNING_PIDS" ]]; then
  RUNNING_PID_SUMMARY="${RUNNING_PIDS//$'\n'/, }"
  echo "$APP_DISPLAY_NAME is currently running with PID(s): $RUNNING_PID_SUMMARY" >&2
  echo "Quit the app normally before installing a replacement." >&2
  exit 1
fi

echo "Source: $SOURCE_APP_PATH"
echo "Destination: $TARGET_APP_PATH"
if [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
  echo "Previous installation: $PREVIOUS_APP_PATH"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run completed; no files were moved."
  INSTALL_COMMITTED="true"
  exit 0
fi

echo "==> Staging packaged app in Applications"
NEW_APP_LOCATION="staged"
/bin/mv "$SOURCE_APP_PATH" "$STAGED_APP_PATH"

if [[ -e "$TARGET_APP_PATH" || -L "$TARGET_APP_PATH" ]]; then
  echo "==> Moving previous installation to Trash"
  PREVIOUS_APP_MOVED="true"
  /bin/mv "$TARGET_APP_PATH" "$PREVIOUS_APP_PATH"
fi

echo "==> Installing $APP_DISPLAY_NAME"
NEW_APP_LOCATION="target"
/bin/mv "$STAGED_APP_PATH" "$TARGET_APP_PATH"

validate_app_bundle "$TARGET_APP_PATH"

INSTALL_COMMITTED="true"
echo "Installed app: $TARGET_APP_PATH"
if [[ "$PREVIOUS_APP_MOVED" == "true" ]]; then
  echo "Previous installation moved to: $PREVIOUS_APP_PATH"
fi
