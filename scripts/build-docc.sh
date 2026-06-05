#!/usr/bin/env bash
# build-docc.sh — build the human-facing DocC archive for CameraKit.
#
# Uses `xcodebuild docbuild` on the app scheme (which builds CameraKit as a
# dependency, picking up its CameraKit.docc catalog). Destination defaults to
# Mac "Designed for iPad" — a documentation build needs no camera, avoiding
# physical-iPad lock flakiness. Never a simulator.
#
# Usage: scripts/build-docc.sh [--destination "<spec>"]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEST='platform=macOS,arch=arm64,variant=Designed for iPad'
if [[ "${1:-}" == "--destination" && -n "${2:-}" ]]; then DEST="$2"; fi

DD="$(mktemp -d)/DerivedData"
echo "build-docc: docbuild ios_example_app for [$DEST]"

xcodebuild docbuild \
  -project ios_example_app/ios_example_app.xcodeproj \
  -scheme ios_example_app \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -allowProvisioningUpdates \
  > "$DD.log" 2>&1 || { echo "DOCBUILD FAILED — see $DD.log"; tail -40 "$DD.log"; exit 1; }

ARCHIVE="$(find "$DD" -name 'CameraKit.doccarchive' -print -quit)"
if [[ -z "$ARCHIVE" ]]; then
  echo "No CameraKit.doccarchive produced — see $DD.log"
  exit 2
fi
echo "build-docc: produced $ARCHIVE"
