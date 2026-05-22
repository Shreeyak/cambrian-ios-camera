#!/usr/bin/env bash
# test-integration.sh — run the integration_test suite on the connected iPad.
#
# Three tests live in integration_test/plugin_test.dart:
#   Test 1 — Smoke (open → frame → capture → close)   [unattended]
#   Test 2 — Lifecycle (foreground/background)         [SKIPPED in v1.0 —
#            needs XCUIDevice automation; backgrounding a flutter-driven test
#            drops the driver connection. See plugin_test.dart + README.md.]
#   Test 3 — Recording cycle (2s @ 30fps)              [unattended]
#
# Prerequisite: camera + Photos-add permission pre-granted, auto-lock off.
# See integration_test/README.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/flutter/example"

UDID="${IPAD_UDID:-}"
if [[ -z "$UDID" ]]; then
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

echo "===> Running integration tests on iPad $UDID"
echo "===> Test 2 (Lifecycle) is skipped in v1.0; Tests 1 + 3 run unattended."
echo "===> See integration_test/README.md for prerequisites."

flutter test integration_test --device-id="$UDID"
