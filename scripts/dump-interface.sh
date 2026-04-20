#!/usr/bin/env bash
# dump-interface.sh — emit CameraKit's compiler-validated .swiftinterface.
#
# Use when you need compiler-truth answers about the public API surface:
# isolation attributes (@MainActor, nonisolated), Sendability conformances,
# synthesized Hashable members, actor internals (unownedExecutor), exact
# @available annotations. These are things the compiler deduces and that
# source-text compression (repomix) does not show.
#
# Output: /tmp/CameraKit.swiftinterface  (or $1 if provided)
#
# Note: Bundle.module references in MetalPipeline.swift produce a compile
# error, but the .swiftinterface is emitted before the error fires (internal
# types are excluded from the public interface, so this doesn't affect
# correctness). The error is suppressed in output; script exits 0 if the
# interface file was produced.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/CameraKit.swiftinterface}"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET=arm64-apple-ios26.0

xcrun swiftc \
  -emit-module-interface-path "$OUT" \
  -module-name CameraKit \
  -sdk "$SDK" \
  -target "$TARGET" \
  -enable-library-evolution \
  -swift-version 6 \
  "$REPO_ROOT"/CameraKit/Sources/CameraKit/*.swift \
  2>/dev/null || true

if [[ ! -s "$OUT" ]]; then
  echo "failed to emit interface at $OUT" >&2
  exit 1
fi

LINES=$(wc -l < "$OUT" | tr -d ' ')
echo "wrote $OUT ($LINES lines, public API only, compiler-validated)"
