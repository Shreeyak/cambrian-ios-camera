#!/usr/bin/env bash
# stage-preflight.sh — validate the repo is in a coherent state before a
# new stage kicks off.
#
# Checks:
#   1. Every scaffold slug listed in CameraKit/state.md under "Scaffolding
#      still live" returns ≥1 hit in CameraKit/Sources/.
#   2. No scaffold slug in source is missing from state.md.
#   3. CameraKit/CONTRACTS.md exists and is fresh (< 24h old).
#   4. Build succeeds (scripts/build-summary.sh).
#
# Exit 0 on success, 1 on any failure. Prints a summary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

STATE=CameraKit/state.md
CONTRACTS=CameraKit/CONTRACTS.md

FAIL=0
note() { printf "  %s\n" "$*"; }
warn() { printf "⚠  %s\n" "$*"; FAIL=1; }
ok()   { printf "✔  %s\n" "$*"; }

echo "=== Stage preflight ==="

echo "Checking state.md ↔ source coherence..."
LIVE_SLUGS=$(awk '/Scaffolding still live/,/^## /' "$STATE" | grep -oE '[0-9]{2}:[a-z0-9-]+' | sort -u || true)
for slug in $LIVE_SLUGS; do
  if rg -q "// scaffolding:$slug" CameraKit/Sources/; then
    ok "state.md slug $slug found in source"
  else
    warn "state.md slug $slug has ZERO hits in source"
  fi
done

SOURCE_SLUGS=$(rg -oN --no-filename '// scaffolding:([0-9]{2}:[a-z0-9-]+)' -r '$1' CameraKit/Sources/ | sort -u || true)
for slug in $SOURCE_SLUGS; do
  if grep -q "$slug" "$STATE"; then
    ok "source slug $slug documented in state.md"
  else
    warn "source slug $slug NOT documented in state.md"
  fi
done

if [[ ! -f "$CONTRACTS" ]]; then
  warn "CONTRACTS.md missing; regenerating"
  "$REPO_ROOT/scripts/regen-contracts.sh"
else
  AGE_S=$(( $(date +%s) - $(stat -f %m "$CONTRACTS") ))
  if (( AGE_S > 86400 )); then
    note "CONTRACTS.md is $((AGE_S/3600))h old; regenerating"
    "$REPO_ROOT/scripts/regen-contracts.sh"
  else
    ok "CONTRACTS.md fresh ($((AGE_S/60))m old)"
  fi
fi

echo "Running build..."
if "$REPO_ROOT/scripts/build-summary.sh" >/tmp/preflight-build.log 2>&1; then
  ok "$(head -1 /tmp/preflight-build.log)"
else
  warn "build FAILED — see /tmp/preflight-build.log"
fi

echo "=== $(if (( FAIL )); then echo "FAIL"; else echo "PASS"; fi) ==="
exit $FAIL
