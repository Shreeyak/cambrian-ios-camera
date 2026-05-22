#!/usr/bin/env bash
# test-phase-b.sh — run all four Phase B test layers in order, fail-fast.
#
#   1. Dart unit tests          (flutter/test/)
#   2. Example widget smoke      (flutter/example/test/)
#   3. Swift adapter XCTest      (RunnerTests on iPad)
#   4. Integration tests         (iPad; Test 2 skipped in v1.0)
#
# Layers 3 + 4 need a connected iPad (export IPAD_UDID to pin one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "==> [1/4] Dart unit tests (flutter/test/)"
(cd flutter && flutter test)

echo "==> [2/4] Example widget smoke (flutter/example/test/)"
(cd flutter/example && flutter test)

echo "==> [3/4] Swift adapter (flutter/example/ios/RunnerTests, iPad)"
flutter/example/scripts/test-swift-adapter.sh

echo "==> [4/4] Integration tests (iPad; Test 2 skipped in v1.0)"
flutter/example/scripts/test-integration.sh

echo "==> All four Phase B test layers green."
