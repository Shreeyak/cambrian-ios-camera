#!/usr/bin/env bash
# release-gate.sh — Phase B v1.0.0 release gate (7 checks, per spec §8).
# All must pass before tagging. Fail-fast.
#
# Checks 2, 3, 5, 6 need a connected iPad (export IPAD_UDID to pin one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Detect the iPad once and export it so every device check (2,3,5,6) pins the
# SAME device. This project rotates between two iPads; independent per-check
# detection could otherwise split checks across them. `|| true` stops a no-match
# grep from aborting under `set -e` before the friendly error below runs.
if [[ -z "${IPAD_UDID:-}" ]]; then
  IPAD_UDID=$(xcrun xctrace list devices 2>&1 \
    | grep -iE 'iPad' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' \
    | head -1) || true
fi
if [[ -z "$IPAD_UDID" ]]; then
  echo "No connected iPad found; export IPAD_UDID=<xctrace UDID> and retry." >&2
  echo "Simulators are disallowed on this machine (CLAUDE.md §6)." >&2
  exit 1
fi
export IPAD_UDID

step () { echo; echo "==> $1"; }

step "[1/7] Dart unit + example smoke"
(cd flutter && flutter test)
(cd flutter/example && flutter test)

step "[2/7] Swift adapter XCTest (iPad)"
flutter/example/scripts/test-swift-adapter.sh

step "[3/7] Integration tests (iPad; Test 2 skipped in v1.0)"
flutter/example/scripts/test-integration.sh

step "[4/7] CameraKit suite (iPad)"
# Existing wrapper; defaults to scheme ios_example_app (app-hosted CameraKitTests).
scripts/test-summary.sh

step "[5/7] ios_example_app smoke build (iPad)"
scripts/build-summary.sh

step "[6/7] flutter example release build (iPad)"
# Build only — don't keep the app running headless. IPAD_UDID was detected and
# exported once at the top, so this check uses the same device as the rest.
(cd flutter/example && flutter build ios --device-id="$IPAD_UDID" --release)

step "[7/7] swift-format lint --strict on CameraKit sources"
swift-format lint --strict CameraKit/Sources/CameraKit/*.swift

echo
echo "==> Release gate: all 7 checks passed."
