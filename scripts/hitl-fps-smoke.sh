#!/usr/bin/env bash
# hitl-fps-smoke.sh — objective fps + delivery-stability smoke for the camera
# pipeline (the automatable slice of the Task-8 HITL).
#
# Launches the app on the physical iPad, lets it run, pulls camerakit.log, and
# from the most-recent session computes sustained fps (from the per-frame yield
# counters) and checks the per-window delivery metrics for dropped/overwritten
# frames. This is the repeatable form of the manual fps check recorded in
# measurements/phase-3-prep/8bit-bgra-delivery.md.
#
# It does NOT verify visual correctness (green frames, colour, tracker overlay)
# — there is no device screen-capture path on iOS 26.4 (XcodeBuildMCP
# `screenshot` is simulator-only). Those stay manual.
#
# Prereq: the app must already be installed on the device with
# CameraKitLog.enableFileLogging() active — e.g. run
# `mcp__XcodeBuildMCP__build_run_device` once first. Device-only; no simulator.
#
# Usage:
#   scripts/hitl-fps-smoke.sh [run_seconds]    # default 30
#
# Exit 0 iff fps ∈ [MIN_FPS, MAX_FPS] AND 0 drops/overwrites; 1 otherwise.

set -u

UDID="DAD37FD5-685B-50E0-911E-F9BC40BBDBE5"   # devicectl CoreDevice UDID (Shreeyak's iPad)
BUNDLE="com.cambrian.eva-swift-stitch"
RUN_SECONDS="${1:-30}"
MIN_FPS=27          # 30 fps target, allow startup ramp + measurement slack
MAX_FPS=31
_TMP="${TMPDIR:-/tmp}"
PULL="${_TMP%/}/camerakit-fps-smoke.log"

echo "→ launching $BUNDLE on $UDID"
xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE" \
    >/dev/null 2>&1 \
    || { echo "✖ launch failed — is the app installed? run build_run_device first"; exit 1; }

echo "→ running for ${RUN_SECONDS}s…"
sleep "$RUN_SECONDS"

echo "→ pulling camerakit.log"
# The first devicectl copy after a process launch often fails while the device
# warms up ("Enabling developer disk image services"); retry a few times.
pulled=0
for attempt in 1 2 3 4; do
    if xcrun devicectl device copy from \
        --device "$UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" \
        --source /Documents/camerakit.log \
        --destination "$PULL" >/dev/null 2>&1; then
        pulled=1
        break
    fi
    echo "  pull attempt ${attempt} failed; retrying in 3s…"
    sleep 3
done
(( pulled == 1 )) || { echo "✖ log pull failed after retries — check 'xcrun devicectl list devices'"; exit 1; }

# Slice to the most-recent session (the run we just launched).
LN=$(grep -n 'session started' "$PULL" | tail -1 | cut -d: -f1)
[[ -z "${LN:-}" ]] && { echo "✖ no session marker in log"; exit 1; }
SESSION=$(tail -n "+$LN" "$PULL")

# fps from the first/last 'yield: frame=N stream=0' lines (timestamp HH:MM:SS.mmm).
FPS=$(printf '%s\n' "$SESSION" | awk '
    /yield: frame=[0-9]+ stream=0/ {
        split($1, t, ":")
        sec = t[1]*3600 + t[2]*60 + t[3]
        match($0, /frame=[0-9]+/)
        f = substr($0, RSTART+6, RLENGTH-6) + 0
        if (n == 0) { f0=f; s0=sec }
        f1=f; s1=sec; n++
    }
    END {
        if (n < 2 || s1 <= s0) { print "0"; exit }
        printf "%.2f", (f1 - f0) / (s1 - s0)
    }')

# Count metrics windows reporting any non-zero drop or overwrite
# (format: "natural=0/0 processed=0/0 tracker=0/0").
DROPS=$(printf '%s\n' "$SESSION" | grep 'window emit' \
    | grep -Ec '=[1-9][0-9]*/|/[1-9][0-9]*' || true)

echo ""
echo "session start line: $LN"
echo "sustained fps:      ${FPS}  (band ${MIN_FPS}–${MAX_FPS})"
echo "metrics windows with drops/overwrites: ${DROPS}"
echo ""

FAIL=0
awk -v f="$FPS" -v lo="$MIN_FPS" -v hi="$MAX_FPS" 'BEGIN{exit !(f>=lo && f<=hi)}' \
    || { echo "✖ fps ${FPS} outside [${MIN_FPS}, ${MAX_FPS}]"; FAIL=1; }
(( DROPS == 0 )) || { echo "✖ ${DROPS} metrics window(s) reported drops/overwrites"; FAIL=1; }

if (( FAIL == 0 )); then
    echo "✓ PASS — ~${FPS} fps sustained, 0 drops/overwrites"
else
    echo "✖ FAIL"
fi
exit "$FAIL"
