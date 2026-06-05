#!/usr/bin/env bash
# emit-symbol-graph.sh — emit CameraKit's compiler symbol graph (the canonical
# machine description of the public API) as JSON.
#
# Confirmed invocation (Task A1 spike): build the package through the app scheme
# with `-emit-symbol-graph` appended to OTHER_SWIFT_FLAGS, into a dedicated
# symbol-graph dir, then lift out `CameraKit.symbols.json`.
#
# Destination: defaults to Mac "Designed for iPad" — symbol-graph emission is a
# pure compile and needs no camera, so the Mac target avoids physical-iPad lock
# flakiness. Override with --destination "<spec>" (e.g. a physical iPad). Never
# a simulator (project rule).
#
# Usage: scripts/emit-symbol-graph.sh [OUT_DIR] [--destination "<spec>"]
#   OUT_DIR defaults to ./Documentation/reference (the consumer reference home).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${1:-$REPO_ROOT/Documentation/reference}"
DEST='platform=macOS,arch=arm64,variant=Designed for iPad'
if [[ "${2:-}" == "--destination" && -n "${3:-}" ]]; then DEST="$3"; fi

PROJECT="ios_example_app/ios_example_app.xcodeproj"
SCHEME="ios_example_app"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SG_DIR="$WORK/symbolgraphs"
DD_DIR="$WORK/DerivedData"
mkdir -p "$SG_DIR" "$OUT_DIR"

echo "emit-symbol-graph: building $SCHEME for [$DEST] → $SG_DIR"

# `$(inherited)` preserves the project's own OTHER_SWIFT_FLAGS; we only append.
# A clean build guarantees compilation actually runs (and thus emits graphs).
xcodebuild clean build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DD_DIR" \
  -allowProvisioningUpdates \
  OTHER_SWIFT_FLAGS='$(inherited) -emit-symbol-graph -emit-symbol-graph-dir '"$SG_DIR" \
  > "$WORK/build.log" 2>&1 || { echo "BUILD FAILED — see $WORK/build.log"; tail -40 "$WORK/build.log"; exit 1; }

# Primary module graph (extensions emit as `CameraKit@Other.symbols.json`; we
# take the base module file).
SRC="$(find "$SG_DIR" -name 'CameraKit.symbols.json' -print -quit)"
if [[ -z "$SRC" ]]; then
  echo "No CameraKit.symbols.json under $SG_DIR — emission path needs adjustment."
  find "$SG_DIR" -name '*.symbols.json' | head
  exit 2
fi

cp "$SRC" "$OUT_DIR/symbol-graph.json"
echo "emit-symbol-graph: wrote $OUT_DIR/symbol-graph.json"
