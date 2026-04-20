#!/usr/bin/env bash
# scaffold-inventory.sh — emit a markdown table of active scaffold slugs.
#
# Usage: scripts/scaffold-inventory.sh [PATH]
# PATH defaults to CameraKit/Sources/
set -euo pipefail

TARGET="${1:-CameraKit/Sources/}"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) not found; install with: brew install ripgrep" >&2
  exit 2
fi

HITS=$(rg --no-heading --line-number '// scaffolding:[0-9]{2}:[a-z0-9-]+' "$TARGET" || true)

if [[ -z "$HITS" ]]; then
  echo "| Slug | File:line |"
  echo "|------|-----------|"
  echo "| _(no active scaffolds)_ | — |"
  exit 0
fi

echo "| Slug | File:line |"
echo "|------|-----------|"
echo "$HITS" | awk -F: '
{
  # Field 1: path; field 2: line; rest: content containing "// scaffolding:NN:slug ..."
  match($0, /scaffolding:[0-9]{2}:[a-z0-9-]+/)
  slug = substr($0, RSTART, RLENGTH)
  sub(/^scaffolding:/, "", slug)
  printf "| `%s` | `%s:%s` |\n", slug, $1, $2
}' | sort -u
