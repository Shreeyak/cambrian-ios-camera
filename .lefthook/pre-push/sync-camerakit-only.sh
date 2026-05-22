#!/usr/bin/env bash
# .lefthook/pre-push/sync-camerakit-only.sh
#
# Keep the `camerakit-only` synthetic branch in sync (CLAUDE.md §10).
#
# A lefthook *script* (not a command) so it runs on EVERY push — lefthook
# commands skip with "no matching push files" on a no-op/non-CameraKit push,
# scripts don't. It is git-state-driven (no hook-manager env / stdin), so it
# also works under a different manager or a bare `.git/hooks/pre-push`.
#
# Cost control: `git subtree split` is slow (~40s on this history), so we must
# NOT run it on every push. Cheap O(1) guard first — compare the CameraKit/ tree
# object at HEAD against the last successfully-synced tree (recorded in
# .git/camerakit-only-synced.tree). Unchanged → instant exit. Only when CameraKit/
# actually changed do we pay for the split + push. So the hook fires every push
# but is sub-second unless CameraKit/ changed.
#
# The synthetic branch is consumed by
# camera2_flutter_demo/packages/cambrian_camera via `git subtree pull`.
#
# Skip on a one-off push:  git push --no-verify
set -euo pipefail

# Re-entry guard. This hook fires on EVERY `git push`, including our own push of
# camerakit-only below — without this guard that inner push would re-trigger the
# hook recursively (a fork bomb of subtree splits). The inner push also uses
# --no-verify (belt and suspenders); this env sentinel is the primary defense and
# is inherited by the child `git push` process.
[ -n "${CAMERAKIT_SYNC_RUNNING:-}" ] && exit 0

# Only publish from main — the branch whose CameraKit/ subtree we ship.
branch="$(git symbolic-ref --short -q HEAD || echo '')"
[ "$branch" = "main" ] || exit 0

# Cheap guard: the tree object of CameraKit/ at HEAD is an O(1) content
# fingerprint. If it matches the last synced tree, the published content is
# identical — skip the expensive split entirely.
tree="$(git rev-parse -q --verify HEAD:CameraKit 2>/dev/null || echo '')"
[ -n "$tree" ] || exit 0
marker="$(git rev-parse --git-common-dir)/camerakit-only-synced.tree"
if [ -f "$marker" ] && [ "$(cat "$marker")" = "$tree" ]; then
    exit 0  # CameraKit/ unchanged since the last successful sync — nothing to do
fi

# CameraKit/ changed (or first run / lost marker): regenerate and publish.
echo "→ CameraKit/ changed; updating camerakit-only (git subtree split — ~40s)…"
split_sha="$(git subtree split --prefix=CameraKit -q)"
remote_sha="$(git ls-remote origin refs/heads/camerakit-only 2>/dev/null | awk '{print $1}')"
if [ "$split_sha" != "$remote_sha" ]; then
    # Force because subtree split regenerates history; the split is stable, so
    # this is a fast-forward in practice. --no-verify + the CAMERAKIT_SYNC_RUNNING
    # sentinel both prevent this push from re-triggering this very hook.
    CAMERAKIT_SYNC_RUNNING=1 git push --no-verify --force origin \
        "${split_sha}:refs/heads/camerakit-only"
    echo "✓ camerakit-only updated ($split_sha)"
else
    echo "✓ camerakit-only already current"
fi
# Record the synced tree so subsequent no-op pushes exit cheaply.
printf '%s\n' "$tree" > "$marker"
