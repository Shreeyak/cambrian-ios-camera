#!/usr/bin/env bash
# build-summary.sh — wrap `xcodebuild build`; structured output via xcsift.
#
# Usage: scripts/build-summary.sh [--scheme NAME] [--destination DEST] [--verbose]
#
# Destination: physical iPad preferred, Mac "Designed for iPad" fallback.
# Simulators are NEVER used (memory constraint on this machine — see CLAUDE.md §6).
# Raw log always persists at .build-logs/<ts>-build-<scheme>.log;
# structured xcsift JSON at .build-logs/<ts>-build-<scheme>.json.
# Read either at any time — this script never loses output to a pipe.
set -uo pipefail

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
  # Hard rule: NEVER use iOS simulators on this machine (memory constraint).
  # Prefer physical iPad; fall back to Mac "Designed for iPad" (native, not a sim).
  # If neither is available, ERROR — never silently fall through to a simulator.
  DESTS=$(xcodebuild -project eva-swift-stitch.xcodeproj -scheme "$SCHEME" -showdestinations 2>&1)
  DEVICE_UUID=$(echo "$DESTS" \
    | grep -E '\{ *platform:iOS, ' \
    | grep -v placeholder \
    | head -1 \
    | sed -E 's/.*id:([A-Fa-f0-9-]+).*/\1/')
  if [[ -n "$DEVICE_UUID" ]]; then
    DESTINATION="platform=iOS,id=$DEVICE_UUID"
    echo "DEST: physical iPad $DEVICE_UUID"
  elif echo "$DESTS" | grep -qE 'platform:macOS.*variant:Designed for (iPad|\[iPad'; then
    DESTINATION="platform=macOS,arch=arm64,variant=Designed for iPad"
    echo "DEST: Mac 'Designed for iPad' (no physical device connected)"
  else
    echo "no physical iPad or Mac 'Designed for iPad' destination found" >&2
    echo "simulators are disallowed on this machine — connect an iPad or pass --destination" >&2
    exit 1
  fi
fi

mkdir -p .build-logs
TS=$(date +%Y%m%d-%H%M%S)
LOG=".build-logs/${TS}-build-${SCHEME}.log"
JSON=".build-logs/${TS}-build-${SCHEME}.json"

echo "LOG: $LOG"
echo "JSON: $JSON"

xcodebuild -project eva-swift-stitch.xcodeproj -scheme "$SCHEME" -destination "$DESTINATION" build 2>&1 \
  | tee "$LOG" \
  | xcsift --format json > "$JSON" || true
XC_STATUS=${PIPESTATUS[0]}
STATUS=$([[ "$XC_STATUS" -eq 0 ]] && echo success || echo fail)

if (( VERBOSE )); then
  cat "$LOG"
  [[ "$STATUS" == success ]] && exit 0 || exit 1
fi

ERRORS=0
WARNINGS=0
if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
  ERRORS=$(jq -r '(.errors // []) | length' "$JSON" 2>/dev/null || echo 0)
  WARNINGS=$(jq -r '(.warnings // []) | length' "$JSON" 2>/dev/null || echo 0)
fi

printf "BUILD: %s\nErrors: %d  Warnings: %d\nLog: %s\nJSON: %s\n" \
  "$STATUS" "$ERRORS" "$WARNINGS" "$LOG" "$JSON"

if [[ "$STATUS" == fail ]]; then
  echo "---"
  if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
    jq -r '(.errors // []) | .[0:10] | .[] | "\(.file // "?"):\(.line // "?"): \(.message // .)"' "$JSON" 2>/dev/null \
      || grep -E 'error: ' "$LOG" | head -5
  else
    grep -E 'error: ' "$LOG" | head -5
  fi
  exit 1
fi
