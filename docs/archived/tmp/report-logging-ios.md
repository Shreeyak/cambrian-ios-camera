# iOS device logs and testing for Claude Code in 2026

**Use XcodeBuildMCP as the primary MCP server, pair it with `pymobiledevice3` and `xcrun devicectl` for the log work it doesn't cover, and adopt the "background capture → file → grep" pattern to work around Claude Code's 2-minute Bash timeout.** The old `ios-deploy`/`idevicesyslog`/`symbolicatecrash` stack is effectively broken for iOS 17+ developer services; Apple's CoreDevice (`devicectl`) plus the open-source `pymobiledevice3` tunnel is now the supported path for an iPad running iOS 26. This changes what "working" means: live log streaming is no longer a one-liner, crash logs come from a `systemCrashLogs` domain on `devicectl`, and the new `xcresulttool` API demands `--legacy` or migration. The payoff is that once you lay the right Swift `Logger` subsystems into your code and wire one wrapper script around `xcodebuild + devicectl + idevicesyslog`, Claude Code can deploy, launch, exercise, and triage your app over WiFi without ever touching the Xcode GUI.

The rest of this report is a practical reference. Code blocks are copy-pasteable against an iPad paired over WiFi via USB first, Xcode's "Connect via network" checked, and Developer Mode enabled on-device.

## The iOS 17+ transport shift you cannot ignore

Starting with iOS 17, Apple moved all developer services (DVT, oslog relay, instruments, process launch) off the classic lockdown-over-TCP channel and onto a **RemoteXPC trusted tunnel** over QUIC (or TCP in iOS 17.4+) exposed via RemoteServiceDiscovery. Apple's `xcrun devicectl` sets this tunnel up transparently. Everything else — `ios-deploy`, many libimobiledevice services, older third-party automation — requires that you bring your own tunnel. **`pymobiledevice3` is the only open-source tool that implements it correctly**, and it is now the de-facto replacement for libimobiledevice on modern iOS.

Practically, this means your toolchain is three layers: **`devicectl` for install/launch/files/crash logs**, **`pymobiledevice3 syslog live` for rich unified-log streaming with subsystem metadata**, and **`idevicesyslog --network` as a cross-platform fallback that still works via the unredacted syslog_relay service**. `log stream` and `log collect` on the Mac remain essential for simulators and for device log archives, but they cannot live-stream a physical iOS device's unified log from the CLI — only Console.app can, or `log stream --device <UDID>` on recent macOS.

Apple DTS engineer "Quinn the Eskimo" has warned on the Developer Forums that `idevicesyslog` "runs on very shaky foundations; there are no supported APIs to do what it's doing." Design your agent workflow to prefer `devicectl` and `pymobiledevice3`, with `idevicesyslog` as a backup.

## The live-log toolbox, ranked for iOS 26 over WiFi

The tool you reach for depends on what metadata you need and how deep you want to go. **`xcrun devicectl device process launch --console` (Xcode 16+)** is the cleanest path when you only need your app's stdout/stderr: it routes the process's fd 1/2 back to your terminal until the app exits, which makes it ideal for capturing `print()` output and crash messages. It does **not** stream the full unified log, and no `devicectl device console` or generic log-stream subcommand exists — the Flutter team's November 2025 migration PR confirms this is still absent in Xcode 26.1.

**`pymobiledevice3 syslog live`** is the richest live stream. Install with `pip install -U pymobiledevice3`, optionally run a one-shot tunnel as root, then filter by process name:

```bash
pymobiledevice3 usbmux list                  # list USB + network devices
pymobiledevice3 syslog live --udid $UDID -p MyApp
pymobiledevice3 syslog live --tunnel ''      # auto-use tunneld daemon
pymobiledevice3 developer dvt oslog --tunnel ''   # richest — full oslog
sudo pymobiledevice3 remote tunneld &        # persistent tunnel daemon
pymobiledevice3 lockdown wifi-connections on # iOS 17.4+ WiFi developer tunnel
```

The `developer dvt oslog` variant exposes `subsystem` and `category` metadata — exactly what your Swift `Logger` statements emit — and is the CLI equivalent of what Console.app shows when you select a connected device. It requires the personalized Developer Disk Image mounted (which Xcode mounts automatically on first pair).

**`idevicesyslog`** from libimobiledevice is still the simplest cross-platform option and works over WiFi with `--network`, but it rides the unredacted `syslog_relay` service and **does not deliver subsystem/category metadata from `os_log`** — you see kernel messages, `NSLog`, and `printf`-style output. Useful flags: `-u UDID -n` (network), `-p MyApp|ReportCrash` (include processes), `-e backboardd|CommCenter` (exclude noise), `-m com.example.app` (match substring), `-t`/`-T` (trigger-start/stop), `-o file.log`. Always `brew install --HEAD libimobiledevice` on newly-released iOS majors; upstream lags Apple by weeks.

**`log collect --device-udid $UDID --last 15m --output dev.logarchive`** pulls a unified-log archive off the device (requires `sudo` and an unlocked, trusted device), which you then read with `log show dev.logarchive --info --debug --predicate 'subsystem == "com.example.app"' --style compact`. A loop running `log collect --last 30s` every 25 seconds gives you a passable quasi-stream when live options fail.

| Need | Best tool over WiFi on iOS 26 |
|---|---|
| App stdout/stderr | `xcrun devicectl device process launch --console` |
| Full unified log with subsystem/category | `pymobiledevice3 developer dvt oslog --tunnel ''` |
| Rich syslog with debug/info | `pymobiledevice3 syslog live --tunnel ''` |
| Cross-platform / Linux host | `idevicesyslog -n -u $UDID -p MyApp` |
| Historical 15-min window with predicates | `sudo log collect --device-udid $UDID --last 15m --output X.logarchive` then `log show X.logarchive --predicate …` |
| App's own runtime logs | `OSLogStore(scope: .currentProcessIdentifier)` from inside Swift |

## Swift 6 logging patterns that unlock CLI filtering

CLI log filtering only works when your code uses **static string literal subsystems and categories**. The canonical pattern, restated with Swift 6 strict-concurrency in mind:

```swift
import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier!
    static let networking  = Logger(subsystem: subsystem, category: "networking")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let auth        = Logger(subsystem: subsystem, category: "auth")
    static let ui          = Logger(subsystem: subsystem, category: "ui")
}

Logger.networking.info("→ \(req.url!.absoluteString, privacy: .public) id=\(id, privacy: .public)")
Logger.networking.error("⨯ \(err, privacy: .public) id=\(id, privacy: .public)")
Logger.persistence.debug("SQL: \(sql, privacy: .public) params=\(p, privacy: .private(mask: .hash))")
Logger.ui.fault("Invariant: navStack empty at settings pop")
```

**`Logger` is now `Sendable`** in current SDKs — Apple engineer Quinn confirmed this on Developer Forums thread 747816, and the compiler warning that plagued early Xcode 15.3 strict-concurrency builds no longer fires. If you still target an older SDK that emits the warning, use `nonisolated(unsafe) static let` as the escape hatch; calling `.info(...)` never requires `await` and never needs a `Task` wrapper, which means logging from actors is genuinely free.

Three privacy subtleties bite everyone:

1. **Interpolated values are `.private` by default** and render as `<private>` in every CLI tool. Mark IDs, URLs without query strings, enum cases, and bundle IDs explicitly `.public`. Use `.private(mask: .hash)` to correlate "same user across events" without leaking identity.
2. **`.debug` and `.info` are not persisted by default** — they live in a memory ring buffer and only materialize when a subscriber (Xcode debugger, `log stream`, `pymobiledevice3`) is actively attached. A release build with nothing attached never writes them. This is what makes `.debug` statements safe to leave in production.
3. **Do not wrap `Logger` in a helper that takes `String`.** The compile-time `OSLogMessage` interpolation is the whole performance model; eager-formatting destroys it.

On-device, you cannot run `log config`; instead, ship an **`OSLogPreferences` key in Info.plist** for debug builds to force `level:debug, persist:debug` for your own subsystem. On the Mac/Simulator host, `sudo log config --subsystem com.example.app --mode "level:debug,persist:debug"` does the same.

Predicate syntax for `log stream` and `log show` accepts `subsystem`, `category`, `process`, `processImagePath`, `eventMessage`, `messageType` (`default|info|debug|error|fault`), and standard NSPredicate operators. The essential live-tail command for a Mac app or booted simulator:

```bash
log stream --level debug --style compact \
  --predicate 'subsystem == "com.example.app" AND category IN { "networking", "auth" }'

xcrun simctl spawn booted log stream --level debug --style compact \
  --predicate 'subsystem == "com.example.app"'
```

For agent consumption, append `--style ndjson` and pipe to `jq` — every entry becomes a single JSON line with full metadata. Avoid `--style json`, which buffers a single array until process exit and is useless for live tailing.

## XcodeBuildMCP is the right MCP server; xcode-mcp is not

**The GitHub repo `cameroncooke/XcodeBuildMCP` was transferred to Sentry and now lives at `getsentry/XcodeBuildMCP`.** It is the actively maintained, well-instrumented option with 77 canonical MCP tools across 15 workflow groups, and it is the one you should configure in Claude Code. The separately-named `r-huijts/xcode-mcp-server` has an **unpatched CWE-78 command-injection vulnerability** (issue #13, January 2026) affecting `run_lldb`, `build_project`, `test_project`, and many other tools; avoid it on any machine handling untrusted prompts.

Critical configuration gotcha: **by default only the `simulator` workflow is loaded**. To get device logging, testing, and debugging, you must enable workflows explicitly:

```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest", "mcp"],
      "env": {
        "XCODEBUILDMCP_ENABLED_WORKFLOWS": "simulator,device,logging,project-discovery,ui-testing,debugging,utilities,doctor",
        "XCODEBUILDMCP_SENTRY_DISABLED": "true"
      }
    }
  }
}
```

With the `device` + `logging` workflows enabled you get `start_device_log_capture` and `stop_device_log_capture`, which wrap `xcrun devicectl device launch app --console` in a session-id pattern. Call `start_device_log_capture({ deviceId, bundleId, captureConsole, subsystems })` → get a `logSessionId` → do work → `stop_device_log_capture({ logSessionId })` → get the captured text back. The parallel simulator tools (`start_simulator_log_capture` / `stop_simulator_log_capture`) capture **OSLog structured logs** by default using `log stream --predicate 'subsystem == "<bundle>"'` and optionally the console PTY if `captureConsole: true` (which restarts the app).

Where XcodeBuildMCP falls short: **it has no first-class crash-log tool**, no `get_crash_logs` or equivalent. Crashes surface through the runtime log streams. For `.ips` file retrieval you still shell out to `xcrun devicectl device copy from --domain-type systemCrashLogs`. Build logs are returned as structured parsed diagnostics (filename:line, severity, message) rather than raw xcodebuild output, which is usually better for agents but occasionally truncates heavy test output — issue #177 is the workaround reference. Xcode 26.3's `xcode-ide` bridge workflow proxies Xcode's own `xcrun mcpbridge` server, exposing Issue Navigator entries and SwiftUI preview rendering to the agent.

Testing tools (`test_sim`, `test_device`, `test_macos`, `swift_package_test`) wrap `xcodebuild test` with `-destination` selection and return a **structured summary plus the xcresult path**; with the `coverage` workflow enabled you also get `get_coverage_report` and `get_file_coverage`. UI-test support works for any XCUITest scheme; for agent-driven UI automation without writing XCUITest, XcodeBuildMCP bundles Cameron Cooke's **AXe** framework, giving `tap`, `swipe`, `type_text`, `snapshot_ui`, and accessibility-id-aware gestures — but AXe only runs on simulators, not physical devices.

## A CLI testing workflow that actually works on a WiFi iPad

The full-flow command for running XCTest/XCUITest against a WiFi-paired iPad, as verified against Xcode 26.x, is this:

```bash
UDID=$(xcrun devicectl list devices --json-output - \
       | jq -r '.result.devices[] | select(.connectionProperties.tunnelState=="connected") | .hardwareProperties.udid' | head -1)

rm -rf out && mkdir out
set -o pipefail && NSUnbufferedIO=YES xcodebuild test \
    -workspace MyApp.xcworkspace \
    -scheme MyAppScheme \
    -configuration Debug \
    -destination "platform=iOS,id=$UDID" \
    -testPlan SmokeUITests \
    -resultBundlePath out/Smoke.xcresult \
    -derivedDataPath out/DD \
    -allowProvisioningUpdates \
    2>&1 | xcbeautify --report junit --report-path out/junit.xml
```

Three details matter. First, **`NSUnbufferedIO=YES` is required** for parallel or concurrent test destinations to prevent silent line loss. Second, **`-resultBundlePath` must not already exist** — xcodebuild errors out if the path is present, so `rm -rf` first. Third, **`xcbeautify` (Swift) has replaced `xcpretty` (Ruby)** as the recommended formatter; install with `brew install xcbeautify`, and it can emit JUnit XML with `--report junit` for CI/agent consumption. For test selection, use `-only-testing:MyAppUITests/LoginFlowTests/testValidLogin` or `.xctestplan` files with `-testPlan SmokeUITests`.

**Parsing `.xcresult` bundles changed fundamentally in Xcode 16.** The classic `xcresulttool get --format json --path foo.xcresult` now errors out unless you pass `--legacy`. The new API is subcommand-oriented:

```bash
xcrun xcresulttool get test-results summary --path out/Smoke.xcresult
xcrun xcresulttool get test-results tests --path out/Smoke.xcresult --compact \
  | jq -r '..|objects|select(.result=="Failed")|.identifier'
xcrun xcresulttool get test-results test-details --path out/Smoke.xcresult \
  --test-id "MyAppUITests/LoginTests/testLogin()"
xcrun xcresulttool get build-results --path out/Smoke.xcresult
xcrun xcresulttool export attachments --path out/Smoke.xcresult --output-path ./att
```

Migrate agents off the legacy JSON now — Apple has removed deprecated commands on major Xcode jumps before, and `--legacy` is not guaranteed forever. Third-party wrappers like `xcparse` (`brew install chargepoint/xcparse/xcparse`) and `a7ex/xcresultparser` transparently handle both APIs.

For **UI tests on a physical device over WiFi**, both the app and the `*-Runner.app` must be signed. Pass `-allowProvisioningUpdates` so Xcode mints a development profile for the UITests-Runner bundle ID automatically. Trust-chain prerequisites that are easy to forget: Developer Mode on (`Settings → Privacy & Security → Developer Mode`, reboot), UI Automation enabled (`Settings → Developer`), and the developer profile trusted (`Settings → General → VPN & Device Management`). Auto-Lock set to Never prevents the xctest connection from dropping mid-run. **Physical devices cannot be cloned**, so `-parallel-testing-enabled YES` does nothing useful on a single device — use simulators for fan-out.

## Crash logs and symbolication without the Xcode GUI

Crash logs on modern iOS are `.ips` files (concatenated JSON — a metadata header line followed by the detailed crash report). They live on-device at `/var/mobile/Library/Logs/CrashReporter/`, accessible only through the `systemCrashLogs` `devicectl` domain. The full retrieve-and-symbolicate loop:

```bash
# 1. Pull crash logs off the device
xcrun devicectl device copy from --device $UDID \
    --domain-type systemCrashLogs --source . --destination ./crashes/

# 2. Find a matching dSYM by UUID (Spotlight indexes them)
mdfind "com_apple_xcode_dsym_uuids == 2421317E-79BF-3738-B831-77E365D6BD34"

# 3. Parse the .ips JSON for base address + crashing frame
BASE=$(tail -n +2 MyApp.ips | jq -r '.usedImages[] | select(.name=="MyApp") | .base')

# 4. Symbolicate individual addresses — always pass -i for inlined Swift frames
DSYM="MyApp.app.dSYM/Contents/Resources/DWARF/MyApp"
xcrun atos -o "$DSYM" -arch arm64 -i -l "$BASE" 0x0000000102a3b964
# → -[LoginViewController viewDidLoad] (in MyApp) (LoginViewController.swift:42)
```

The legacy `xcrun symbolicatecrash` script is **deprecated in Xcode 15+** and no longer on the default path; use `atos` per-frame, or drag the `.ips` into Xcode's Organizer for bulk symbolication. `pymobiledevice3 crash pull ./crashes` is the tunnel-aware alternative when `devicectl` misbehaves.

## The background-capture pattern that makes Claude Code work

Claude Code's Bash tool has a **~2-minute default timeout** (maximum 10 minutes via the `timeout` parameter), and several known issues — #11716, #43944, #45717 — mean bare `tail -f` or long-running `xcodebuild test` calls can SIGTERM the agent's parent process. The universally-reliable pattern is **start capture in the background, return immediately, grep the file on follow-up calls**:

```bash
# Canonical launcher, safe for Claude Code
LOG=/tmp/ios.log ; : > "$LOG"
nohup stdbuf -oL -eL idevicesyslog -u "$UDID" --network -p MyApp \
      >"$LOG" 2>&1 </dev/null &
echo $! > /tmp/ios.pid
disown
```

Three details make this reliable. **Redirect stdin from `/dev/null`** so the child doesn't hold the TTY; without it the Bash tool waits for stdin to close and hits its timeout. **`stdbuf -oL`** forces line-buffered output — when you pipe through `grep`/`sed`/`awk`, libc silently switches to 4KB block-buffered mode, and your log file looks empty for minutes. **Write the PID** to a file so a follow-up Claude call can `kill $(cat /tmp/ios.pid)` cleanly. `tmux new -d -s logs 'cmd'` is an even cleaner alternative because tmux creates a new session automatically and is trivially scriptable (`tmux capture-pane -t logs -p -S -2000`).

For consumption, always bound your reads:

```bash
tail -n 500 /tmp/ios.log                                    # last 500 lines
tail -c 200000 /tmp/ios.log                                 # last ~200 KB
grep --line-buffered -iE 'error|fault|exception|crash' /tmp/ios.log | tail -50
timeout 30 tail -f /tmp/ios.log | grep -m1 'DONE'           # bounded live wait
```

A **marker pattern** isolates a single test run from a long-running log file:

```bash
MARK="=== RUN $(date +%s) ==="
echo "$MARK BEGIN" >> /tmp/ios.log
./run-test-scenario.sh
echo "$MARK END"   >> /tmp/ios.log
awk '/=== RUN.*BEGIN/{p=1;next} /=== RUN.*END/{p=0} p' /tmp/ios.log > slice.log
```

Even cleaner: emit the marker from inside your app via `os_log`, and it will appear in `idevicesyslog` output automatically. `idevicesyslog -t "START_MARKER" -T "END_MARKER"` has native trigger-start/stop on matching lines.

A complete wrapper script combining test execution and log capture (abridged from the research):

```bash
#!/usr/bin/env bash
set -u
UDID="${UDID:?}" ; BUNDLE="${BUNDLE:?}" ; SCHEME="${SCHEME:?}"
LOGDIR=$(mktemp -d -t iostest.XXXX)
trap '[[ -f $LOGDIR/syslog.pid ]] && kill $(cat $LOGDIR/syslog.pid) 2>/dev/null' EXIT

# Start filtered device syslog in background
nohup stdbuf -oL idevicesyslog -u "$UDID" --network \
      -p "$(basename $BUNDLE)|ReportCrash" \
      > "$LOGDIR/device.log" 2>&1 </dev/null &
echo $! > "$LOGDIR/syslog.pid" ; disown ; sleep 1

# Run tests
set -o pipefail
NSUnbufferedIO=YES xcodebuild -scheme "$SCHEME" \
    -destination "platform=iOS,id=$UDID" test 2>&1 \
    | tee "$LOGDIR/build.log" | xcbeautify --report junit

# Post-process for Claude
{ echo "### xcodebuild exit: ${PIPESTATUS[0]}"
  echo "### Device errors:" ; grep -iE 'error|fault|crash' "$LOGDIR/device.log" | tail -50
  echo "### Test failures:" ; grep -E 'Testing failed|FAILED' "$LOGDIR/build.log" | tail -30
} > "$LOGDIR/summary.txt"
echo "SUMMARY=$LOGDIR/summary.txt"
```

Claude invokes this with an explicit `timeout: 300000` (5 minutes) and then `Read`s the summary file, which is bounded and fits comfortably in one tool call.

For persistent capture across reboots use a `~/Library/LaunchAgents/com.me.ioslog.plist` and `launchctl bootstrap gui/$(id -u) …`. For long unattended runs, wrap with `caffeinate -dimsu -w $(cat /tmp/ios.pid)` to keep the Mac awake only while the capture PID lives.

## WiFi pairing verification and the failure modes that waste hours

Initial pairing must happen over USB — you cannot wirelessly pair a fresh device. After `Trust This Computer` and Developer Mode enabling, check "Connect via network" in **Xcode → Window → Devices and Simulators**; the device then appears in `xcrun devicectl list devices` with a hostname ending in `.coredevice.local`. The fastest CLI verification:

```bash
xcrun devicectl list devices
xcrun devicectl device info details --device $UDID >/dev/null && echo OK
idevice_id -n            # libimobiledevice: network-only UDID list
pymobiledevice3 bonjour rsd   # iOS 17+ RSD devices on the LAN
```

The failure modes that recur on every project: **VPN on the Mac** (Cisco AnyConnect, Tailscale, Little Snitch) blocks the CoreDevice tunnel and mDNS — disable or split-tunnel. **Guest/enterprise WiFi with client isolation** blocks Bonjour and port 62078 — use your Mac's built-in hotspot or an access point with peer-to-peer enabled. **Device sleep** silently drops the xctest connection — set Auto-Lock to Never and keep it on AC power for long runs. **Different subnets** break Bonjour discovery — same SSID is mandatory without custom mDNS forwarding. **`remoted` stuck on the Mac** — `sudo pkill -9 remoted` forces a reconnect, as documented in `pymobiledevice3/misc/RemoteXPC.md`.

WiFi is noticeably slower than USB: app install can be 2–5× slower and UI tests with many activity frames saturate quickly. Stay on 5 GHz / WiFi 6 and the same subnet. If you care about iteration speed for a heavy test run, initial deploy over USB then switch to WiFi for the test loop, since `xcodebuild` uses whichever transport is reachable without any destination-string change.

## Conclusion: a concrete recommended stack

The stack that survives contact with an iPad running iOS 26 over WiFi, driven by Claude Code, looks like this: **XcodeBuildMCP with the `simulator,device,logging,project-discovery,ui-testing,debugging,utilities,doctor` workflows explicitly enabled**, paired with direct shell access to **`xcrun devicectl`** for file/crash-log operations and **`pymobiledevice3 syslog live --tunnel ''`** for rich live log streaming with subsystem metadata. In the app, a single `Logger` extension with per-feature categories and explicit `.public` privacy markers on safe values is what turns the unified log from noise into a queryable data source. Test runs should go through a wrapper script that starts `idevicesyslog` in the background with `nohup stdbuf -oL … </dev/null &`, runs `NSUnbufferedIO=YES xcodebuild test | xcbeautify`, then post-processes into a bounded summary file that Claude reads with its `Read` tool.

The non-obvious lessons are that **Swift `Logger` is now `Sendable`** and safe from any concurrency context, **`devicectl` has no generic log-stream subcommand** so don't wait for one, **`xcresulttool`'s pre-Xcode-16 JSON is a migration risk** even with `--legacy`, and **Claude Code's Bash timeout forces a file-based workflow** rather than live tailing. Build that pattern once and it becomes invisible; skip it and every run hits the 2-minute wall. XcodeBuildMCP is clearly better than every other MCP server in this space right now — the unpatched CVE on `r-huijts/xcode-mcp-server` alone disqualifies it — but it is a build and log server, not a crash-log server, and the crash-log gap is what `devicectl device copy from --domain-type systemCrashLogs` fills until Sentry extends coverage.