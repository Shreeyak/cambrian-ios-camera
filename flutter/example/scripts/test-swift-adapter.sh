#!/usr/bin/env bash
# test-swift-adapter.sh — run the RunnerTests XCTest suite (the Pigeon-adapter
# unit tests) on the connected iPad, via xcsift for structured output.
#
# The test target lives in the *Runner* scheme (there is no standalone
# `RunnerTests` scheme), so we invoke `-scheme Runner -only-testing:RunnerTests`.
# The scheme's Test action is Debug — required for `@testable import
# cambrian_ios_camera` and for the SceneDelegate XCTest guard that lets the
# Debug host launch under `xcodebuild test` without crashing.
#
# Destination: physical iPad only. These are app-hosted tests (TEST_HOST=
# Runner.app); iOS forbids tool-hosted testing on device, and simulators are
# disallowed on this machine (CLAUDE.md §6). No Mac fallback — connect an iPad
# or export IPAD_UDID.
#
# Raw log persists at .build-logs/<ts>-swift-adapter.log; xcsift JSON at
# .build-logs/<ts>-swift-adapter.json. The script's exit status reflects
# xcodebuild's real result (via PIPESTATUS) — a passing pipe never masks a
# failing test run.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

UDID="${IPAD_UDID:-}"
if [[ -z "$UDID" ]]; then
  # xctrace ECID UDID form: 8 hex - 16 hex (e.g. 00008027-000539EA0184402E).
  UDID=$(xcrun xctrace list devices 2>&1 \
    | grep -iE 'iPad' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' \
    | head -1)
fi
if [[ -z "$UDID" ]]; then
  echo "No connected iPad found; export IPAD_UDID=<xctrace UDID> and retry." >&2
  echo "Simulators are disallowed on this machine (CLAUDE.md §6)." >&2
  exit 1
fi
echo "DEST: physical iPad $UDID"

mkdir -p .build-logs
TS=$(date +%Y%m%d-%H%M%S)
LOG=".build-logs/${TS}-swift-adapter.log"
JSON=".build-logs/${TS}-swift-adapter.json"
echo "LOG: $LOG"
echo "JSON: $JSON"

xcodebuild test \
  -project flutter/example/ios/Runner.xcodeproj \
  -scheme Runner \
  -destination "platform=iOS,id=$UDID" \
  -only-testing:RunnerTests \
  2>&1 | tee "$LOG" | xcsift --format json > "$JSON" || true
XC_STATUS=${PIPESTATUS[0]}
STATUS=$([[ "$XC_STATUS" -eq 0 ]] && echo success || echo fail)

ERRORS=0; FAIL_CASES=0
if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
  ERRORS=$(jq -r '(.errors // []) | length' "$JSON" 2>/dev/null || echo 0)
  FAIL_CASES=$(jq -r '(.failed_tests // []) | length' "$JSON" 2>/dev/null || echo 0)
fi

printf "ADAPTER TESTS: %s\nBuild errors: %d  Failed cases: %d\nLog: %s\nJSON: %s\n" \
  "$STATUS" "$ERRORS" "$FAIL_CASES" "$LOG" "$JSON"

if [[ "$STATUS" == fail ]]; then
  echo "---"
  if command -v jq >/dev/null 2>&1 && [[ -s "$JSON" ]]; then
    jq -r '(.errors // []) | .[0:10] | .[] | "\(.file // "?"):\(.line // "?"): \(.message // .)"' "$JSON" 2>/dev/null || true
    jq -r '(.failed_tests // []) | .[0:10] | .[] | "FAIL \(.test // "?") @ \(.file // "?"):\(.line // "?") — \(.message // "")"' "$JSON" 2>/dev/null || true
  else
    grep -E 'error: ' "$LOG" | head -5
  fi
  exit 1
fi
