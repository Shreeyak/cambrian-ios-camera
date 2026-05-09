# Handoff — Bugs 10 + 14 (Stage-12 entry blockers)

You are picking up post-Stage-11 bug-sweep work on branch `stage-01`. As of
2026-05-09 the remaining Stage-12 entry blockers are:

- **Bug 10** — REC button crash. Fix already applied (`39b9ffe`); needs HITL re-verify.
- **Bug 14** — Second REC press silently fails. Open, unverified.
- **Bug 11** — Resolution control is a static label, not a button. Open. *Out of scope for this handoff* unless 10 and 14 turn out cheap.

Bugs 1–9, 12, 13, 15, 16 are fixed and verified. The three deferred §11
UI/VoiceOver evidence captures into `measurements/stage-11/ui.md` are docs,
not code — separate workstream.

**Read first:**
1. `CLAUDE.md` (especially §6 device-only build rules and §8 invariants)
2. `docs/stage-11-pre-existing-bugs.md` Bug 10 + Bug 14 sections
3. `docs/pre-stage-12-handoff.md` for broader context (somewhat stale on bug
   status — counts of fixed/open changed since it was written)
4. `CameraKit/state.md` "Blocking Stage 12" section for the current cut

---

## Bug 10 — REC button crash (HITL re-verify)

### Status
**Fix applied 2026-04-30** in commit `39b9ffe`. Awaiting HITL on device.

### Root cause (already understood)
`AVCaptureFigVideoDevice setActiveVideoMaxFrameDuration:` threw
`NSInvalidArgumentException` because `CameraSession.setRecordingFrameRateRange()`
called the AVF setters **without** wrapping them in
`lockForConfiguration` / `unlockForConfiguration`. Crash log:
`eva-swift-stitch-2026-04-30-030858.ips`.

### Fix shape (already in place)
Both `setPreviewFrameRateRange` and `setRecordingFrameRateRange` in
`CameraKit/Sources/CameraKit/CameraSession.swift` now acquire the device
lock around the `setVideoFrameDurationRange` call, matching the pattern in
`applySettings`. Verify with:
```bash
grep -n "lockForConfiguration\|setVideoFrameDurationRange\|setRecordingFrameRateRange\|setPreviewFrameRateRange" \
  CameraKit/Sources/CameraKit/CameraSession.swift
```
You should see the lock/unlock pair around each setter.

### What HITL needs to confirm
1. App on device, idle. Tap **REC** in the bottom bar.
2. **No crash.** Recording starts (timer runs in the bottom bar).
3. Tap **REC** again to stop. File saves; banner appears (per Stage 10
   testable `10:saved-banner-appears-three-seconds`, currently DEFERRED).
4. Pull `<Documents>/camerakit.log` and confirm `[recording]` start/stop
   markers. No `NSException` or `lockForConfiguration` errors.

If a crash occurs, pull the latest `.ips`:
```bash
xcrun devicectl device copy from \
  --device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 \
  --domain-type systemCrashLogs --source "/" \
  --destination /tmp/crash/
ls -lt /tmp/crash/Library/Logs/CrashReporter/ | head
```
Parse `.ips` with Python (vanilla `jq` rejects it):
```python
import json
with open("/tmp/crash/Library/Logs/CrashReporter/eva-swift-stitch-...ips") as f:
    raw = f.read()
header_end = raw.index("}\n") + 1
header = json.loads(raw[:header_end])
body, _ = json.JSONDecoder(strict=False).raw_decode(raw[header_end:])
print(body["exception"], body["lastExceptionBacktrace"][:5])
```

### Closing the bug
On clean HITL pass, update:
- `docs/stage-11-pre-existing-bugs.md` Bug 10 status → `**FIXED** (2026-04-30 lock around fps setters; verified <date> HITL)`
- `docs/stage-11-pre-existing-bugs.md` summary table row 10
- `CameraKit/state.md` blocker section — drop Bug 10 row

---

## Bug 14 — Second REC press silently fails to save

### Status
**Open, unverified.** Surfaced 2026-04-30 HITL on iPad.

### Symptom
- First REC tap → recording starts, second REC tap stops it, MP4 saves to
  Photos. Works.
- Second REC sequence (tap 3 = start, tap 4 = stop) → no crash, no banner,
  **no file produced**.

### Where to look
Three call sites:

**1. `CameraKit/Sources/CameraKit/RecordingViewModel.swift:58` — `toggleRecording()`**
```swift
func toggleRecording() {
    Task {
        if !isRecording {
            _ = try? await self.engine.startRecording(options: RecordingOptions())  // line 63
        } else {
            _ = try? await self.engine.stopRecording()  // line 65
        }
    }
}
```
The `try?` swallows errors silently — first thing to consider is removing
that and surfacing failures, at least via `CameraKitLog.error`.

**2. `CameraKit/Sources/CameraKit/CameraEngine.swift:890` — `startRecording(options:)`**
Read the body. Look for: does it reset `pipeline.isRecording` somewhere
before starting? Does `assetWriterFactory` get invoked on every call, or
only when state is fresh?

**3. `CameraKit/Sources/CameraKit/Recording.swift`** — `start()` at line 66,
`stop()` at line 127.
- `stop()` line 141 awaits `writer.finishWriting()` inside a TaskGroup with
  `Constants.recordingFinishTimeoutSeconds` deadline (5 s).
- Look at what state survives across a stop → start cycle. Is there a
  `Recording` instance stored on the engine that's mutable, or is a fresh
  one created per start?

### Investigation steps (in order)

**Step 1 — Reproduce + capture log**
```bash
# Make sure the app is running on iPad. Then:
scripts/device-log-live.sh                    # start polling
scripts/device-log-live.sh tail               # watch live in another terminal
# On iPad: tap REC, wait 3 s, tap REC, wait 2 s, tap REC, wait 3 s, tap REC.
scripts/device-log-live.sh stop
xcrun devicectl device copy from \
  --device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 \
  --domain-type appDataContainer \
  --domain-identifier com.cambrian.eva-swift-stitch \
  --source /Documents/camerakit.log \
  --destination /tmp/bug14-camerakit.log
```

**Step 2 — Grep for recording markers**
```bash
grep -n "\[recording\]\|assetWriter\|finishWriting\|isRecording\|startRecording\|stopRecording" \
  /tmp/bug14-camerakit.log | tail -100
```
Compare the markers between the first and second REC sequences. Look for:
- Does `startRecording` log fire on the second start? If not, the
  toggleRecording branch didn't hit start (state stuck `isRecording = true`).
- Does `assetWriter` show up on second start? If not, factory wasn't invoked.
- Does `finishWriting` show on first stop? If timeout fires, state may not
  reset cleanly before second start.

**Step 3 — Hypotheses, ranked by likelihood**

1. **`pipeline.isRecording` atomic stuck true** after first stop.
   - Look in `MetalPipeline.swift` for `isRecording: ManagedAtomic<Bool>` or
     similar. Confirm `stopRecording` flips it back to false.
   - If true: the encoder branch in `encode()` keeps queuing into a stale
     writer that's already been finished → silent drop.

2. **`Recording` instance not reset.** The engine may hold a `var recording: Recording?`
   and second `startRecording` returns early because it's still non-nil after
   `stop()` deferred the cleanup.

3. **`finishWriting` timeout swallowed silently.** `Recording.stop()` line
   141–156 cancels with `Constants.recordingFinishTimeoutSeconds`. If
   first-stop's writer takes too long, the cancel could leave state in an
   undefined position the second start can't recover from.

4. **`RecordingViewModel.isRecording` UI flag desynced from engine.** Less
   likely because UI shows REC button toggling correctly per HITL, but
   worth a sanity print.

**Step 4 — Pick the cheapest probe**
- Add `CameraKitLog.notice(.engine, "[recording] start invoked, isRecording before=\(isRecording)")`
  at the top of `Engine.startRecording` and at the top of `Recording.start`.
- Run the two-sequence repro. Inspect the `before=` values.

**Step 5 — Fix shape will fall out of step 3**
Most likely: state reset in `stopRecording`'s success path so the second
`startRecording` sees a clean slate. Less likely: queue ordering / atomic
fence around the `isRecording` flag.

### What success looks like
- Second REC sequence produces a saved file with the post-save banner.
- `[recording]` markers in the log show two clean start/stop cycles.
- A regression test under `Stage10*` exercises two consecutive
  `startRecording → stopRecording` cycles against the test
  `assetWriterFactory` (CameraEngine line 882 names this seam) and
  asserts both produce a finished-writing event.

### Closing the bug
- Update `docs/stage-11-pre-existing-bugs.md` Bug 14 status → `**FIXED**`.
- Update summary table row 14.
- Update `CameraKit/state.md` blocker section.

---

## Live-device tooling pointers

**Build and run.** XcodeBuildMCP first (`session_show_defaults` should
already have project / scheme / deviceId set). Fallback to
`scripts/build-summary.sh` if MCP is unavailable. **Never** simulator
variants — physical iPad only (CLAUDE.md §6).

**Pull app log:** the `ipad-logs` skill or directly:
```bash
xcrun devicectl device copy from \
  --device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 \
  --domain-type appDataContainer \
  --domain-identifier com.cambrian.eva-swift-stitch \
  --source /Documents/camerakit.log \
  --destination /tmp/camerakit.log
```

**Live tail:** `scripts/device-log-live.sh` (4 s poll cadence; do NOT shorten
— `xcrun devicectl` rate-limits). Mirror file at
`${TMPDIR}/camerakit-live.log`.

**Two iPads, two UDID schemes** (CLAUDE.md §8):
- xctrace UDID `00008027-000539EA0184402E` for build/test.
- devicectl UDID `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5` for app-container
  and crash-log pulls.

**Wedged Wi-Fi tunnel:** USB plug + Mac/iPad reboot is the reliable recovery.

---

## Don't do

- Don't `git rebase -i`, `git push --force`, or `git --amend` published
  commits without explicit ask. Stage-01 is a long-running branch with
  shared history.
- Don't widen scope into Bug 11 (resolution control) until 10 and 14 close.
  It's a separate UX pull-in.
- Don't touch the WB calibrate path (Bug 13). It's verified-fixed; touching
  it risks regressions on a hard-won settled state. The Apple-only
  single-shot flow in `CalibrationViewModel.calibrateWB` and the
  `WBCalibrationStatus` UI feedback are load-bearing for the user's
  confidence on iPad.
- Don't pre-emptively delete `Bug4Probe.swift` or the DEBUG-only
  "Halt Pass 2 (bug4)" buttons in `CameraView.swift`. Those land in a
  separate cleanup pass once Stage 12 confirms Bug 4 stays fixed under
  prolonged sessions (`docs/pre-stage-12-handoff.md` "Cleanup pending").
- Don't run with simulator destinations. Memory issues on this machine —
  CLAUDE.md §6 enforces device-only.

---

## Definition of done for this handoff

- Bug 10: HITL pass on device, no crash on REC tap, status updated in both
  `docs/stage-11-pre-existing-bugs.md` and `state.md`.
- Bug 14: root cause identified, fix applied with a test (Stage10 second-
  cycle test), HITL pass on device with two clean REC sequences, status
  updated in both docs.
- A short note appended to `docs/pre-stage-12-handoff.md` recording what
  was found (root cause + fix shape) and the HITL date.

After both close, only Bug 11 + the three §11 UI evidence captures remain
before Stage 12 brief work (`UIApplication.beginBackgroundTask` +
retiring `scaffolding:10:synchronous-drain-pause`) can begin.
