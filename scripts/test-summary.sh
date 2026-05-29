#!/usr/bin/env bash
# test-summary.sh — wrap `xcodebuild test`; structured output via xcsift.
#
# Usage: scripts/test-summary.sh [--scheme NAME] [--filter SUITE] [--destination DEST] [--verbose]
#   --scheme      default: ios_example_app (app scheme, hosts CameraKitTests
#                 via dual-membership — app-hosted tests that run on device)
#                 — switch to `CameraKit` only when running the package's
#                 SwiftPM testTarget directly (rare; not runnable on device).
#   --filter      passed as `-only-testing:<value>`
#                 (e.g. ios_example_appTests/PhotosLibraryClientResolveTests)
#   --destination override device destination
#   --verbose     dump full xcodebuild log at the end
#
# Destination: physical iPad preferred, Mac "Designed for iPad" fallback.
# Simulators are NEVER used (memory constraint on this machine).
# Raw log persists at .build-logs/<ts>-test-<scheme>.log; structured xcsift JSON
# at .build-logs/<ts>-test-<scheme>.json. Read either at any time.
set -uo pipefail

SCHEME="ios_example_app"
FILTER=""
DESTINATION=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheme) SCHEME="$2"; shift 2 ;;
    --filter) FILTER="$2"; shift 2 ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DESTINATION" ]]; then
  # Hard rule: NEVER use iOS simulators on this machine (memory constraint).
  # Prefer physical iPad; fall back to Mac "Designed for iPad". If neither,
  # ERROR — never silently use a simulator.
  #
  # ios_example_appTests is app-hosted (TEST_HOST=ios_example_app.app) and
  # compiles the package's test sources directly via the dual-membership
  # pattern. Physical iPad is the canonical run target.
  DESTS=$(xcodebuild -project ios_example_app/ios_example_app.xcodeproj -scheme "$SCHEME" -showdestinations 2>&1)
  # Readiness gate: pick the canonical iPad (first listed) and check THAT
  # device — never switch to a different iPad. A locked / preparation-errored
  # iPad shows up in -showdestinations with an `error:` annotation (e.g. "may
  # need to be unlocked"); catch it now and fail fast, otherwise `xcodebuild
  # test` blocks waiting for the destination before timing out.
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
LOG=".build-logs/${TS}-test-${SCHEME}.log"
JSON=".build-logs/${TS}-test-${SCHEME}.json"

# -allowProvisioningUpdates: this project signs with a free Apple Developer
# profile (CLAUDE.md §5), which expires ~weekly. Xcode's GUI silently
# regenerates it; xcodebuild on the CLI will NOT unless this flag is passed,
# failing with "unable to generate a profile". Safe for a local dev machine.
# -destination-timeout 15: bound the wait for the device to become available.
# A healthy connected iPad resolves in ~1-3s, so 15s is several× margin (absorbs
# a transient reconnect) yet fails fast if the device is locked/disconnected —
# vs the long default. The readiness gate above already catches an already-locked
# iPad in seconds; this only backstops a drop between that check and the run.
CMD=(xcodebuild -project ios_example_app/ios_example_app.xcodeproj -scheme "$SCHEME" \
     -destination "$DESTINATION" -destination-timeout 15 -allowProvisioningUpdates test)
if [[ -n "$FILTER" ]]; then
  CMD+=(-only-testing:"$FILTER")
fi

echo "LOG: $LOG"
echo "JSON: $JSON"
echo "CMD: ${CMD[*]}"

"${CMD[@]}" 2>&1 \
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
FAIL_CASES=0
if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
  ERRORS=$(jq -r '(.errors // []) | length' "$JSON" 2>/dev/null || echo 0)
  WARNINGS=$(jq -r '(.warnings // []) | length' "$JSON" 2>/dev/null || echo 0)
  FAIL_CASES=$(jq -r '(.failed_tests // []) | length' "$JSON" 2>/dev/null || echo 0)
fi

printf "TESTS: %s\nBuild errors: %d  Warnings: %d  Failed cases: %d\nLog: %s\nJSON: %s\n" \
  "$STATUS" "$ERRORS" "$WARNINGS" "$FAIL_CASES" "$LOG" "$JSON"

if [[ "$STATUS" == fail ]]; then
  echo "---"
  if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
    jq -r '(.errors // []) | .[0:10] | .[] | "\(.file // "?"):\(.line // "?"): \(.message // .)"' "$JSON" 2>/dev/null \
      || grep -E 'error: ' "$LOG" | head -5
    jq -r '(.failed_tests // []) | .[0:10] | .[] | "FAIL \(.test // "?") @ \(.file // "?"):\(.line // "?") — \(.message // "")"' "$JSON" 2>/dev/null || true
  else
    grep -E 'error: ' "$LOG" | head -5
    grep -E '(Test Case .* failed|✘ Test .+ (failed|recorded an issue))' "$LOG" | head -5 || true
  fi
  exit 1
fi
