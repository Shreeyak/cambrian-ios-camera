#!/usr/bin/env bash
# build-summary.sh — wrap xcodebuild; return a 3-line summary.
#
# Usage: scripts/build-summary.sh [--verbose] [--scheme NAME] [--destination DEST]
#
# Default destination: first iPad simulator installed on the machine.
# --verbose passes through the full xcodebuild output (normal mode filters).
set -euo pipefail

SCHEME="eva-swift-stitch"
DESTINATION=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DESTINATION" ]]; then
  # Ask xcodebuild what it considers valid for this scheme; pick the first iPad Simulator.
  UUID=$(xcodebuild -project eva-swift-stitch.xcodeproj -scheme "$SCHEME" -showdestinations 2>&1 \
    | grep -E 'platform:iOS Simulator.*name:iPad' \
    | head -1 \
    | sed -E 's/.*id:([A-Z0-9-]+).*/\1/')
  if [[ -z "$UUID" ]]; then
    echo "no iPad simulator destination found for scheme $SCHEME" >&2
    exit 1
  fi
  DESTINATION="platform=iOS Simulator,id=$UUID"
fi

LOG=$(mktemp)
trap "rm -f $LOG" EXIT

if xcodebuild -project eva-swift-stitch.xcodeproj -scheme "$SCHEME" -destination "$DESTINATION" build >"$LOG" 2>&1; then
  STATUS=success
else
  STATUS=fail
fi

if (( VERBOSE )); then
  cat "$LOG"
  exit 0
fi

SWIFT_ERRORS=$(grep -c -E '^[^[:space:]].*error: ' "$LOG" || true)
METAL_ERRORS=$(grep -c 'cannot execute tool .metal.' "$LOG" || true)
WARNINGS=$(grep -c -E '^[^[:space:]].*warning: ' "$LOG" || true)

printf "BUILD: %s\nSwift errors: %d\nMetal errors: %d\nWarnings: %d\n" \
  "$STATUS" "$SWIFT_ERRORS" "$METAL_ERRORS" "$WARNINGS"

if [[ "$STATUS" == fail ]]; then
  echo "---"
  grep -E 'error: ' "$LOG" | head -5
  exit 1
fi
