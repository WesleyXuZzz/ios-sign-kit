#!/bin/zsh

set -euo pipefail

BUNDLE_IDENTIFIER_TO_VALIDATE="${1:-}"
BUNDLE_VERSION_TO_VALIDATE="${2:-}"

if [[ -z "$BUNDLE_IDENTIFIER_TO_VALIDATE" ]] \
  || [[ ! "$BUNDLE_IDENTIFIER_TO_VALIDATE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
  || [[ "$BUNDLE_IDENTIFIER_TO_VALIDATE" == *..* ]] \
  || [[ "$BUNDLE_IDENTIFIER_TO_VALIDATE" == *. ]]; then
  echo "Invalid BUNDLE_IDENTIFIER: use non-empty letters, digits, dots, and hyphens without empty segments." >&2
  exit 1
fi

if [[ -z "$BUNDLE_VERSION_TO_VALIDATE" ]] \
  || [[ ! "$BUNDLE_VERSION_TO_VALIDATE" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "Invalid BUNDLE_VERSION: use one to three dot-separated numeric components." >&2
  exit 1
fi
