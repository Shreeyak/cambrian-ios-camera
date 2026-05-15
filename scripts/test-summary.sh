#!/usr/bin/env bash
# test-summary.sh — wrap `xcodebuild test`; structured output via xcsift.
#
# Usage: scripts/test-summary.sh [--scheme NAME] [--filter SUITE] [--destination DEST] [--verbose]
#   --scheme      default: eva-swift-stitch (app scheme, hosts CameraKitTests
#                 via the dual-membership pattern documented in CLAUDE.md §8)
#                 — switch to `CameraKit` only when running the package's
#                 SwiftPM testTarget directly (rare; not runnable on device).
#   --filter      passed as `-only-testing:<value>`
#                 (e.g. eva-swift-stitchTests/PhotosLibraryClientResolveTests)
#   --destination override device destination
#   --verbose     dump full xcodebuild log at the end
#
# Destination: physical iPad preferred, Mac "Designed for iPad" fallback.
# Simulators are NEVER used (memory constraint on this machine — see CLAUDE.md §6).
# Raw log persists at .build-logs/<ts>-test-<scheme>.log; structured xcsift JSON
# at .build-logs/<ts>-test-<scheme>.json. Read either at any time.
set -uo pipefail

SCHEME="eva-swift-stitch"
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
  # eva-swift-stitchTests is app-hosted (TEST_HOST=eva-swift-stitch.app) and
  # compiles the package's test sources directly via the dual-membership
  # pattern (CLAUDE.md §8). Physical iPad is the canonical run target.
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
LOG=".build-logs/${TS}-test-${SCHEME}.log"
JSON=".build-logs/${TS}-test-${SCHEME}.json"

CMD=(xcodebuild -project eva-swift-stitch.xcodeproj -scheme "$SCHEME" \
     -destination "$DESTINATION" test)
if [[ -n "$FILTER" ]]; then
  CMD+=(-only-testing:"$FILTER")
fi

echo "LOG: $LOG"
echo "JSON: $JSON"
echo "CMD: ${CMD[*]}"

"${CMD[@]}" 2>&1 \
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
