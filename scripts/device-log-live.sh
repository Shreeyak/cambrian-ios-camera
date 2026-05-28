#!/usr/bin/env bash
# device-log-live.sh — poll camerakit.log from the physical iPad over WiFi.
#
# Uses xcrun devicectl device copy from to pull <Documents>/camerakit.log
# every POLL_INTERVAL seconds and append new lines to a local mirror.
# The device must have the app installed with CameraKitLog.enableFileLogging()
# called at startup (set in eva_swift_stitchApp.init).
#
# Usage:
#   scripts/device-log-live.sh            # start background polling
#   scripts/device-log-live.sh stop       # stop polling
#   scripts/device-log-live.sh tail       # follow local mirror
#   scripts/device-log-live.sh grep EXPR  # search local mirror

set -u

BUNDLE="com.cambrian.eva-swift-stitch"
_TMP="${TMPDIR:-/tmp}"
LOG="${_TMP%/}/camerakit-live.log"
PULL="${_TMP%/}/camerakit-pull.log"
PID_FILE="${_TMP%/}/camerakit-live.pid"
POLL_INTERVAL=4  # seconds between pulls

# Auto-detect a reachable, paired physical iPad and print its devicectl
# identifier on stdout (info goes to stderr). The project's two iPads rotate
# one at a time, so the first reachable paired iPad wins — no UDID to hardcode.
# Mirrors the discovery in build-launch.sh. Returns non-zero if none found.
detect_ipad() {
    command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; return 1; }
    local json sel id name
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
    # Rank "connected" first; drop devices devicectl marks "unavailable".
    sel=$(jq -r '
      .result.devices[]
      | select(.hardwareProperties.deviceType == "iPad")
      | select(.connectionProperties.pairingState == "paired")
      | select(.connectionProperties.tunnelState != "unavailable")
      | [ (if .connectionProperties.tunnelState == "connected" then 0 else 1 end),
          .identifier, .deviceProperties.name ] | @tsv
    ' "$json" | sort -n | head -1)
    rm -f "$json"
    if [[ -z "$sel" ]]; then
        echo "✖ no reachable paired iPad found — connect/unlock one, then: xcrun devicectl list devices" >&2
        return 1
    fi
    id=$(printf '%s' "$sel" | cut -f2)
    name=$(printf '%s' "$sel" | cut -f3)
    echo "→ device: ${name} (${id})" >&2
    printf '%s' "$id"
}

stop_capture() {
    if [[ -f "$PID_FILE" ]]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo "Stopped polling (pid $PID)"
        else
            echo "Polling already stopped"
        fi
        rm -f "$PID_FILE"
    else
        echo "No polling running"
    fi
}

case "${1:-start}" in
    stop)
        stop_capture
        exit 0
        ;;
    tail)
        if [[ ! -f "$LOG" ]]; then
            echo "No log mirror at $LOG — run 'start' first"
            exit 1
        fi
        tail -n 100 -f "$LOG"
        exit 0
        ;;
    grep)
        EXPR="${2:?'Usage: device-log-live.sh grep EXPR'}"
        grep -i "$EXPR" "$LOG"
        exit 0
        ;;
    start)
        ;;
    *)
        echo "Usage: $0 [start|stop|tail|grep EXPR]"
        exit 1
        ;;
esac

# --- start ---

UDID="$(detect_ipad)" || exit 1

# Stop any existing polling loop before starting a new one.
stop_capture 2>/dev/null

: > "$LOG"
echo "=== camerakit log mirror started $(date) ===" >> "$LOG"
echo "=== polling device $UDID every ${POLL_INTERVAL}s ===" >> "$LOG"

# Background polling loop: pull the log file, append new lines to mirror.
(
    LAST_LINE=0
    while true; do
        if xcrun devicectl device copy from \
            --device "$UDID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" \
            --source /Documents/camerakit.log \
            --destination "$PULL" \
            > /dev/null 2>&1; then

            CURRENT=$(wc -l < "$PULL" 2>/dev/null || echo 0)
            if (( CURRENT > LAST_LINE )); then
                tail -n +"$((LAST_LINE + 1))" "$PULL" >> "$LOG"
                LAST_LINE=$CURRENT
            fi
        fi
        sleep "$POLL_INTERVAL"
    done
) < /dev/null > /dev/null 2>&1 &

echo $! > "$PID_FILE"
disown

echo "Log polling started → $LOG  (pid $(cat "$PID_FILE"), every ${POLL_INTERVAL}s)"
echo ""
echo "Commands:"
echo "  tail -f $LOG                                 # follow"
echo "  grep -i 'error\\|fault' $LOG                 # filter errors"
echo "  scripts/device-log-live.sh stop              # stop"
