#!/usr/bin/env bash
# watch-contracts.sh — run in a tmux/terminal pane while editing; on every
# save under CameraKit/Sources/, refresh CameraKit/CONTRACTS.md.
#
# Usage: scripts/watch-contracts.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH_DIR="$REPO_ROOT/CameraKit/Sources"

if ! command -v fswatch >/dev/null 2>&1; then
  echo "fswatch not found; install with: brew install fswatch" >&2
  exit 2
fi

echo "watching $WATCH_DIR — CONTRACTS.md will refresh on save"
fswatch -0 -e '\.build/' -e '\.swiftpm/' "$WATCH_DIR" | while IFS= read -r -d '' PATH_CHANGED; do
  "$REPO_ROOT/scripts/regen-contracts-partial.sh" "$PATH_CHANGED"
done
