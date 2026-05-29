#!/usr/bin/env bash
# build-summary.sh — wrap `xcodebuild build`; structured output via xcsift.
#
# Usage: scripts/build-summary.sh [--scheme NAME] [--destination DEST] [--verbose]
#
# Destination: physical iPad preferred, Mac "Designed for iPad" fallback.
# Simulators are NEVER used (memory constraint on this machine).
# Raw log always persists at .build-logs/<ts>-build-<scheme>.log;
# structured xcsift JSON at .build-logs/<ts>-build-<scheme>.json.
# Read either at any time — this script never loses output to a pipe.
set -uo pipefail

SCHEME="ios_example_app"
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
  DESTS=$(xcodebuild -project ios_example_app/ios_example_app.xcodeproj -scheme "$SCHEME" -showdestinations 2>&1)
  # Readiness gate: pick the canonical iPad (first listed) and check THAT
  # device — never switch to a different iPad. A locked / preparation-errored
  # iPad shows up in -showdestinations with an `error:` annotation (e.g. "may
  # need to be unlocked"); catch it now and fail fast instead of blocking.
  DEVICE_LINE=$(echo "$DESTS" | grep -E '\{ *platform:iOS, ' | grep -v placeholder | head -1)
  if [[ -n "$DEVICE_LINE" ]]; then
    if echo "$DEVICE_LINE" | grep -q 'error:'; then
      ERRTXT=$(echo "$DEVICE_LINE" | sed -E 's/.*error:[[:space:]]*([^}]*)\}?.*/\1/')
      echo "✖ iPad not ready: ${ERRTXT}" >&2
      echo "  → unlock the iPad (replug if needed), then retry. (Set Auto-Lock=Never on the test iPad to avoid mid-run locks.)" >&2
      exit 1
    fi
    DEVICE_UUID=$(echo "$DEVICE_LINE" | sed -E 's/.*id:([A-Fa-f0-9-]+).*/\1/')
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

# -allowProvisioningUpdates: free Apple Developer profile (CLAUDE.md §5) expires
# ~weekly; the CLI won't regenerate it without this flag (Xcode's GUI does).
# -destination-timeout 15: bound the wait for the device. A healthy connected
# iPad resolves in ~1-3s, so 15s is several× margin yet fails fast on a locked/
# disconnected device — vs the long default. (Readiness gate above already
# catches an already-locked iPad in seconds.)
xcodebuild -project ios_example_app/ios_example_app.xcodeproj -scheme "$SCHEME" -destination "$DESTINATION" -destination-timeout 15 -allowProvisioningUpdates build 2>&1 \
  | tee "$LOG" \
  | xcsift --format json > "$JSON"
# No `|| true`: it runs as a separate command and resets PIPESTATUS to 0,
# masking a failing xcodebuild as success. `set -uo pipefail` (no -e) lets the
# script continue past the failing pipeline while PIPESTATUS[0] keeps xcodebuild's
# real exit code.
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
