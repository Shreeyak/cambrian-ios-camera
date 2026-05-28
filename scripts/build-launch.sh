#!/usr/bin/env bash
# build-launch.sh — build the app and launch it on a connected physical iPad.
#
# Usage:
#   scripts/build-launch.sh            # build in Debug   (default)
#   scripts/build-launch.sh --release  # build in Release
#
# Builds with xcodebuild (generic iOS destination), then installs and launches
# on a paired physical iPad via `devicectl`. The device is auto-discovered: the
# project's two iPads rotate one at a time, so the first reachable paired iPad
# wins — no UDID to hardcode.
#
# Physical iPad ONLY. Simulators are disallowed on this machine;
# the Mac "Designed for iPad" fallback is intentionally NOT handled here — if no
# paired iPad is reachable, the script errors rather than running anything else.
# Build output is redirected to .build-logs/<ts>-build-launch-<config>.log.
set -uo pipefail

PROJECT="eva-swift-stitch.xcodeproj"
SCHEME="eva-swift-stitch"
CONFIG="Debug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG="Release"; shift ;;
    -h|--help)
      echo "usage: scripts/build-launch.sh [--release]"
      echo "  (no flag)  build & launch in Debug   (default)"
      echo "  --release  build & launch in Release"
      exit 0 ;;
    *) echo "unknown arg: $1  (use --release or -h)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }

# --- discover a reachable, paired physical iPad ------------------------------
echo "→ discovering device…"
DEV_JSON="$(mktemp)"
trap 'rm -f "$DEV_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEV_JSON" >/dev/null 2>&1

# Rank "connected" ahead of the rest; drop devices devicectl marks "unavailable".
# (tunnelState is the passive list-time state; "disconnected" devices that are
# awake still install fine — devicectl brings the tunnel up on demand.)
SEL=$(jq -r '
  .result.devices[]
  | select(.hardwareProperties.deviceType == "iPad")
  | select(.connectionProperties.pairingState == "paired")
  | select(.connectionProperties.tunnelState != "unavailable")
  | [ (if .connectionProperties.tunnelState == "connected" then 0 else 1 end),
      .identifier, .deviceProperties.name ] | @tsv
' "$DEV_JSON" | sort -n | head -1)

if [[ -z "$SEL" ]]; then
  echo "✖ no reachable paired iPad found." >&2
  echo "  Connect/unlock an iPad, then: xcrun devicectl list devices" >&2
  echo "  (simulators are disallowed on this machine)" >&2
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
