---
name: ipad-logs
description: Use this skill whenever the user asks to read, tail, grep, stream, or check logs from the physical iPad — phrases like "get iPad logs", "show device logs", "what does the iPad say", "tail device logs", "log X on device", "iPad log shows", "stream logs", "check the iPad logs". This is the canonical and ONLY supported path for iPad log retrieval on this project — do not use `log collect`, `pymobiledevice3`, `idevicesyslog`, `start_device_log_cap`, or any other tool.
---

# iPad Logs Skill

The physical iPad (`DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`, iOS 26) writes app logs
to `<Documents>/camerakit.log` via `CameraKitLog.enableFileLogging()`. The
`scripts/device-log-live.sh` script is the only supported way to retrieve them.

## Why this is the only path

iOS 26.4 broke local WiFi device connectivity. Every other route is dead:

- `log collect --device-udid` — fails with "Device not configured (6)" (iOS 17+ removed the legacy lockdown pairing record it depends on)
- `log stream --device` — the flag does not exist in `/usr/bin/log`
- `start_device_log_cap` / `xcrun devicectl process launch --console` — USB-only, kills app over WiFi, and only captures stdout/stderr (not `Logger`)
- `pymobiledevice3` — broken on iOS 26 (hardcoded RSD port; protocol incompatibility)
- `idevicesyslog` / libimobiledevice — dead on iOS 17+

The file sink + `xcrun devicectl device copy from` is the documented workaround
across the iOS forensics, MDM, and dev-tooling ecosystems for iOS 26.4.

## Prerequisites

The app must call `CameraKitLog.enableFileLogging()` at startup
(in `eva_swift_stitchApp.init()`). Verify with `grep enableFileLogging
eva-swift-stitch/eva_swift_stitchApp.swift` if logs look empty.

## Usage

The script lives at `scripts/device-log-live.sh` and supports four modes:

```bash
scripts/device-log-live.sh            # start background polling (4s interval)
scripts/device-log-live.sh tail       # tail -f the local mirror
scripts/device-log-live.sh grep EXPR  # grep the local mirror
scripts/device-log-live.sh stop       # stop polling
```

Mirror file: `${TMPDIR}/camerakit-live.log` (typically `/var/folders/.../T/camerakit-live.log`).

## Decision tree

When the user asks for device logs, decide based on what they want:

### One-shot snapshot ("show me the last few minutes of logs")

Either start the polling and read the mirror, or pull once directly:

```bash
xcrun devicectl device copy from \
  --device "DAD37FD5-685B-50E0-911E-F9BC40BBDBE5" \
  --domain-type appDataContainer \
  --domain-identifier com.cambrian.eva-swift-stitch \
  --source /Documents/camerakit.log \
  --destination /tmp/camerakit-snapshot.log
# Then Read or grep /tmp/camerakit-snapshot.log
```

For a quick one-shot, a direct `devicectl copy` is faster than starting the polling loop.

### Live monitoring ("watch logs while I reproduce a bug")

```bash
scripts/device-log-live.sh        # start if not already running
scripts/device-log-live.sh tail   # follow the mirror (or use Read tool on the file)
```

Don't use `tail -f` directly via Bash — it blocks. Instead, use `run_in_background` with the tail
command, or read the file content with the Read tool after the user has reproduced the issue.

### Filtered search ("did the engine open?", "any errors today?")

```bash
scripts/device-log-live.sh grep "open\|error"
```

Or for cleaner output, use the `Grep` tool on `${TMPDIR}/camerakit-live.log` directly.

## Important rules

- **Never** suggest `log collect`, `pymobiledevice3`, `idevicesyslog`, `start_device_log_cap`,
  or any other log retrieval tool. They are all broken on iOS 26.4.
- **Never** edit the script's UDID/bundle constants — they're tied to the project's specific iPad.
- **The 4-second polling interval is intentional.** Don't reduce it; `xcrun devicectl` rate-limits.
- **`Logger` calls must use `.notice` or higher** for Console.app visibility.
  Add `privacy: .public` to interpolated strings or they show as `<private>`.
- **If the mirror file doesn't exist or is empty**, the polling isn't running — start it first.
- **If polling fails repeatedly**, the device may not be reachable over WiFi. Check
  `xcrun devicectl list devices` first.

## Configuration constants

Hardcoded in `scripts/device-log-live.sh`:

- UDID: `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5` (Shreeyak's iPad)
- Bundle: `com.cambrian.eva-swift-stitch`
- Source path: `/Documents/camerakit.log`
- Mirror: `${TMPDIR}/camerakit-live.log`
- PID file: `${TMPDIR}/camerakit-live.pid`
- Poll interval: 4 seconds
