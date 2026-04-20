#!/usr/bin/env bash
# regen-contracts-partial.sh — refresh CONTRACTS.md when a source file
# under CameraKit/Sources/ changes. Called by the fswatch loop on save.
#
# Usage: scripts/regen-contracts-partial.sh <path>
#
# v1 just defers to full regen — repomix is fast. If this becomes a
# bottleneck, splice only the affected file's section.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <path>" >&2
  exit 2
fi

CHANGED="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$CHANGED" in
  *"/CameraKit/Sources/"*|"CameraKit/Sources/"*) ;;
  *) exit 0 ;;
esac

exec "$REPO_ROOT/scripts/regen-contracts.sh"
