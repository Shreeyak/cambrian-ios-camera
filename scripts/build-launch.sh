#!/usr/bin/env bash
# build-launch.sh — build the app and launch it on a connected physical iPad.
#
# Usage:
#   scripts/build-launch.sh                      # build in Debug   (default)
#   scripts/build-launch.sh --release            # build in Release
#   scripts/build-launch.sh --device Shreeyak    # target a specific iPad
#   scripts/build-launch.sh --list               # list paired iPads, then exit
#
# Builds with xcodebuild (generic iOS destination), then installs and launches
# on a paired physical iPad via `devicectl`. By default the device is
# auto-discovered (first reachable paired iPad wins). When both project iPads are
# awake, pass `--device <name-or-udid>` to pick one explicitly — match is a
# case-insensitive substring of the device name, or its exact devicectl UDID.
# Use `--list` to see the names/UDIDs to choose from.
#
# Physical iPad ONLY. Simulators are disallowed on this machine;
# the Mac "Designed for iPad" fallback is intentionally NOT handled here — if no
# paired iPad is reachable, the script errors rather than running anything else.
# Build output is redirected to .build-logs/<ts>-build-launch-<config>.log.
set -uo pipefail

PROJECT="ios_example_app/ios_example_app.xcodeproj"
SCHEME="ios_example_app"
CONFIG="Debug"
DEVICE_FILTER=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG="Release"; shift ;;
    --device|-d)
      [[ $# -ge 2 ]] || { echo "--device needs a name or UDID" >&2; exit 2; }
      DEVICE_FILTER="$2"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help)
      echo "usage: scripts/build-launch.sh [--release] [--device <name-or-udid>] [--list]"
      echo "  (no flag)            build & launch in Debug   (default)"
      echo "  --release            build & launch in Release"
      echo "  --device, -d <id>    target a specific iPad (name substring or devicectl UDID)"
      echo "  --list               list paired iPads, then exit"
      exit 0 ;;
    *) echo "unknown arg: $1  (use --release, --device <id>, --list, or -h)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }

# --- discover a reachable, paired physical iPad ------------------------------
echo "→ discovering device…"
DEV_JSON="$(mktemp)"
trap 'rm -f "$DEV_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEV_JSON" >/dev/null 2>&1

# --list: enumerate paired iPads (name, devicectl UDID, tunnelState) and exit.
if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "paired iPads:"
  jq -r '
    .result.devices[]
    | select(.hardwareProperties.deviceType == "iPad")
    | select(.connectionProperties.pairingState == "paired")
    | "  \(.deviceProperties.name)\t\(.identifier)\t[\(.connectionProperties.tunnelState)]"
  ' "$DEV_JSON" | column -t -s $'\t'
  exit 0
fi

# Rank "connected" ahead of the rest; drop devices devicectl marks "unavailable".
# (tunnelState is the passive list-time state; "disconnected" devices that are
# awake still install fine — devicectl brings the tunnel up on demand.)
# When --device is given, keep only devices whose name contains the filter
# (case-insensitive) or whose devicectl UDID matches it exactly.
SEL=$(jq -r --arg flt "$DEVICE_FILTER" '
  .result.devices[]
  | select(.hardwareProperties.deviceType == "iPad")
  | select(.connectionProperties.pairingState == "paired")
  | select(.connectionProperties.tunnelState != "unavailable")
  | select($flt == ""
        or (.identifier | ascii_downcase) == ($flt | ascii_downcase)
        or (.deviceProperties.name | ascii_downcase | contains($flt | ascii_downcase)))
  | [ (if .connectionProperties.tunnelState == "connected" then 0 else 1 end),
      .identifier, .deviceProperties.name ] | @tsv
' "$DEV_JSON" | sort -n | head -1)

if [[ -z "$SEL" ]]; then
  if [[ -n "$DEVICE_FILTER" ]]; then
    echo "✖ no reachable paired iPad matched --device '${DEVICE_FILTER}'." >&2
    echo "  See available devices: scripts/build-launch.sh --list" >&2
  else
    echo "✖ no reachable paired iPad found." >&2
    echo "  Connect/unlock an iPad, then: xcrun devicectl list devices" >&2
    echo "  (simulators are disallowed on this machine)" >&2
  fi
  exit 1
fi
DEVICE_ID=$(printf '%s' "$SEL" | cut -f2)
DEVICE_NAME=$(printf '%s' "$SEL" | cut -f3)
echo "  device: ${DEVICE_NAME} (${DEVICE_ID})"

# --- build -------------------------------------------------------------------
mkdir -p .build-logs
TS=$(date +%Y%m%d-%H%M%S)
LOG=".build-logs/${TS}-build-launch-$(printf '%s' "$CONFIG" | tr '[:upper:]' '[:lower:]').log"
echo "→ building ${SCHEME} (${CONFIG})…  log: ${LOG}"
echo "  watch with: tail -f ${LOG}"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' build > "$LOG" 2>&1
BUILD_RC=$?
if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "✖ BUILD FAILED — first errors:" >&2
  grep -E 'error: ' "$LOG" | head -5 >&2
  echo "  full log: ${LOG}" >&2
  exit 1
fi
echo "  build OK"

# --- locate the built .app + bundle id ---------------------------------------
IFS=$'\t' read -r APP_DIR APP_NAME BUNDLE_ID < <(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' -showBuildSettings -json 2>/dev/null \
  | jq -r '.[0].buildSettings
           | [.TARGET_BUILD_DIR, .FULL_PRODUCT_NAME, .PRODUCT_BUNDLE_IDENTIFIER] | @tsv'
)
APP_PATH="${APP_DIR}/${APP_NAME}"
if [[ ! -d "$APP_PATH" ]]; then
  echo "✖ built app not found at: ${APP_PATH}" >&2
  exit 1
fi

# --- install -----------------------------------------------------------------
echo "→ installing onto ${DEVICE_NAME}…"
installed=0
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >/dev/null 2>&1; then
    installed=1; break
  fi
  echo "  install attempt ${attempt} failed; retrying in 3s…"
  sleep 3
done
(( installed == 1 )) || { echo "✖ install failed — is the iPad unlocked & trusted?" >&2; exit 1; }

# --- launch ------------------------------------------------------------------
echo "→ launching ${BUNDLE_ID}…"
xcrun devicectl device process launch --terminate-existing \
  --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 \
  || { echo "✖ launch failed" >&2; exit 1; }

echo "✓ ${SCHEME} (${CONFIG}) launched on ${DEVICE_NAME}"
