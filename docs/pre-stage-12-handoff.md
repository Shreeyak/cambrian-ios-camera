# Pre-Stage-12 handoff

State of the Stage-11-aftermath bug sweep on branch `stage-01`. Read this
first if you're picking up the work in a new session; cross-reference
`docs/stage-11-pre-existing-bugs.md` for per-bug detail (root cause, fix
shape, citations).

---

## TL;DR

- 16 bugs surfaced during Stage 11 regression + post-Stage-11 HITL.
- 11 fixed and verified on iPad (1, 2, 3, 4, 5, 6, 7, 9, 10, 15, 16).
- 5 open (8, 11, 12, 13, 14) — none of them crashes; all
  triaged into 5 work-streams (families A–E below).
- HITL fed by **Shreeyak's iPad Pro 11" 2nd-gen (iPad8,9)**
  (xctrace UDID `00008027-000539EA0184402E`,
  devicectl UDID `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`). Wi-Fi pairing
  occasionally wedges; USB plug + Mac/iPad reboot is the reliable
  recovery (CLAUDE.md §6 has the dual-UDID note).
- Pre-existing instrumentation still in source: `Bug4Probe` +
  DEBUG-only "Halt Pass 2 (bug4)" button in `CameraView`. **Revert
  these** once the team is satisfied Bug 4 stays fixed (see *Cleanup
  pending* below).

---

## Recent commits on `stage-01` (most recent first)

```
87e6a7b fix(fps-alert): scale degraded threshold with manual exposure duration
5d0bf90 refactor(logging): retire pre-stage-12 probe files; add recovery/watchdog/still-capture logs
975ad4e merge(worktree-logging): unified logging + iPad log tooling
03b09a9 refactor(logging): unified CameraKitLog wrapper closes scenePhase file-sink gap
5f82695 docs+tools: ipad-logs skill + device-log-live.sh for iOS 26.4 WiFi logging
9c03fd5 fix(pre-stage-12): camera fails to resume after app backgrounding  ← Bug 15
1303fbb fix(pre-stage-12): bug 6 — disable stabilization + low-light boost; document photo-output rewire
027b688 fix(pre-stage-12): bug 6 + bug 9 — sessionPreset = .inputPriority
2681116 instrument(bug6): pixel-buffer + drawable + format-dump probe
7c53ba8 fix(pre-stage-12): bug 4 — live mailbox forwarding for processedTex / naturalTex
39b9ffe fix(pre-stage-12): bug 7 + bug 10 — AVFoundation NSException crashes on WB Calibrate and REC
a4f2607 fix(pre-stage-12): bug 5 — eager cached-stream construction (bottom bar greyed)
9719ecf instrument(bug4): MetalPipeline Pass 2 probe + DEBUG halt button
486d6e8 docs: note two-iPad rotation + dual UDID schemes (xctrace vs devicectl)
87bd269 fix(pre-stage-12): clear bugs 2 and 3 from stage-11 punch-list
0949a19 docs(stage-11): promote 3 HITL passes to Stage 12 blocker list
```

Working tree should be clean. If not, check `git status` first — the
HITL session is over.

---

## Triage — open bugs grouped by likely shared root cause

5 work-streams cover all 9 open bugs.

### Family A — Green-buffer / Metal viewport (Bugs 6, 9) ✓ FIXED

- **6** ~~Green band below previews on the live screen.~~ Fixed: `sessionPreset = .inputPriority` + disabled stabilization/low-light boost; photo-output rewire documented. (`027b688`, `1303fbb`)
- **9** ~~Still-capture saved as 4032×3024 with the actual photo content in the top-left fraction; rest is uniform green.~~ Fixed: same `sessionPreset = .inputPriority` change cleared the sub-region write issue. (`027b688`)

### Family B — Calibrate UX dead-end + persistence (Bugs 8, 12, 13)

- **8** Black-Balance has no on-screen sample-point indicator.
- **12** Black preview on cold launch when persisted manual WB exists.
  *Confirmed persistence-driven during HITL — uninstall+reinstall
  clears it.*
- **13** WB Calibrate is one-shot: no revert, no re-sample on second
  tap, no auto-WB exit. Pink tint on a mostly-grey reference patch
  suggests the gain math (or sample units) is also off; needs a
  ground-truth check.

All three are facets of the calibrate flow being incomplete: it's a
one-way pipe (sample → compute → write → persist) with no exit.
`SettingsPersistence` makes it survive reboots.

**Investigation start:** redesign the calibrate UX so each tap
re-samples; add an explicit Auto-WB / Reset path that writes
`wbMode = .auto` and clears the persisted manual gains. While there,
audit `CalibrationCompute.grayWorldGains` against a known grey patch.

### Family C — MainActor / @Observable stall (Bugs 15, 16) ✓ FIXED

- **15** ~~DEBUG overlay text (`#frame t=… edges=…`) freezes ~frame 1000 (~33 s) while previews keep streaming.~~ Fixed: camera failed to resume after app backgrounding; `scenePhase` / session-restart fix resolved the overlay freeze. (`9c03fd5`)
- **16** ~~ISO/Shutter slider numeric readouts freeze even though the device is still applying the values.~~ Fixed: same root cause as Bug 15 — session-restart after backgrounding unblocked the `MainActor.run` path. (`9c03fd5`)

### Family D — Recording state machine (Bug 14)

- **14** Second REC press after a clean stop produces no file (no
  crash, no banner).

Stage-10 recording lifecycle. Likely either `assetWriter` isn't reset
between recordings or `pipeline.isRecording` atomic stays `true` after
first stop, blocking encoded buffers from reaching the new writer.
*May* depend on Family C — if `RecordingViewModel` is a stalled
@Observable surface, its second-press handler may never fire.

**Investigation start:** pull `camerakit.log` after a two-press REC
sequence; grep `[recording]` markers around start/stop boundaries;
verify `assetWriterFactory` is invoked twice. Then decide whether to
fix locally or wait for Family C.

### Family E — Resolution control wiring (Bug 11)

- **11** Resolution label in the bottom bar is non-tappable.

Either a Stage-11-rewire miss (`CameraView.swift` `resolutionLabel(...)`
got rendered but the picker presentation never landed) or intentional
Stage-12 scope. *Cross-check `implementation/briefs/stage-11.md` §
resolution* before deciding to fix or defer — if the brief says Stage 11
should land it, this is a regression; if Stage 12, drop the Bug-11 row
from the punch-list.

---

## Recommended fix order for Stage 12 entry

1. **Family A** — visible regression on capture and preview; Metal
   viewport fix is bounded and tractable.
2. **Family C** — affects every observable surface; if it's saturation
   it may be masking D and propagating into B's slider readouts. Worth
   instrumenting *before* deeper UX work.
3. **Family B** — needs UX redesign; larger scope. Best after C is
   stable so you can trust slider/observable surfaces during HITL.
4. **Family D** — confirm C-dependence; fix or defer.
5. **Family E** — scope check vs Stage-11 brief; either fix or move
   the bug entry to Stage 12 backlog.

---

## Cleanup pending

These were intentionally added during the Bug 4 investigation and
should be reverted once Stage 12 confirms Bug 4 doesn't return.

- `CameraKit/Sources/CameraKit/Bug4Probe.swift` — entire file. Header
  comment names every call site to revert.
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — five `Bug4Probe.*`
  calls inside `encode()` + the completion handler.
- `CameraKit/Sources/CameraKit/CameraView.swift` — DEBUG-only
  "Halt Pass 2 (bug4)" + "Resume Pass 2" buttons in the top-right
  cluster (between `#if DEBUG ... #endif`).

---

## Live device + tooling notes

- **Build/install/launch**: `mcp__XcodeBuildMCP__build_device` →
  `install_app_device` → `launch_app_device`. Session defaults
  (project / scheme / deviceId / bundleId) should already be set; if
  `launch_app_device` complains about missing `bundleId`, run
  `session_set_defaults({ bundleId: "com.cambrian.eva-swift-stitch" })`
  once.
- **Pull `<Documents>/camerakit.log`**:
  ```bash
  xcrun devicectl device copy from \
    --device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 \
    --domain-type appDataContainer \
    --domain-identifier com.cambrian.eva-swift-stitch \
    --source /Documents/camerakit.log \
    --destination /tmp/bug-logs/camerakit.log
  ```
  (devicectl UDID, not xctrace UDID — the `appDataContainer` flow uses
  the CoreDevice scheme.)
- **Pull crash logs**: `--domain-type systemCrashLogs --source "/"
  --destination /tmp/bug-logs/crashes/`. Today's eva-swift-stitch
  crashes appear as `eva-swift-stitch-<date>.ips` (unsynced) until
  Apple's analytics rotates them to `*.ips.synced`.
- **Parse `.ips`**: `python3` with `JSONDecoder(strict=False)
  .raw_decode(body)` — the file is a JSON header line then a JSON body
  with stray control chars that vanilla `jq` rejects.
- **Wedged Wi-Fi tunnel**: USB plug, then Mac+iPad reboot. CoreDevice
  daemon kickstarts and other half-measures didn't reliably recover.
- **Two iPads, two UDID schemes**: see CLAUDE.md §8 — *xctrace UDID*
  for build/test/XcodeBuildMCP, *devicectl UDID* for app-container
  / crash-log pulls. Shreeyak's iPad is currently the connected one;
  the iPad A16 (`iPad15,7`) shows `unavailable` in `devicectl list`.

---

## What this doc is *not*

- Not a replacement for `docs/stage-11-pre-existing-bugs.md` — that
  file has every bug's full root cause, fix shape, and citation.
  Read it for the depth.
- Not a Stage 12 plan — Stage 12's primary work
  (`UIApplication.beginBackgroundTask` + retiring
  `scaffolding:10:synchronous-drain-pause`) is upstream-defined in
  `implementation/briefs/stage-12.md`. The bugs above are pre-flight
  cleanup that block that brief from running on a trustworthy
  baseline.

---

## Update — 2026-05-12: Bugs 10 + 14 closed

Two of the three entry blockers tracked here are now closed; Bug 11
(resolution control) is the only one left.

**Bug 10** — REC tap crash. HITL re-verified 2026-05-12 on iPad
`00008027-000539EA0184402E`. The 2026-04-30 fix in commit `39b9ffe`
(lock around `setVideoFrameDurationRange`) holds: REC tap →
recording starts; stop → file saves; no `NSException`, no
`lockForConfiguration` errors in `camerakit.log`.

**Bug 14** — second REC press "silently fails". Root cause was
**not** what the handoff hypothesized:

- The reported "no file produced" was a misperception. Files **were**
  always being written to `<App>/Documents/<timestamp>.mp4`; the
  container is private (no `UIFileSharingEnabled`, no `PHPhotoLibrary`
  save) so they were invisible to the Files app and Photos app. The
  handoff calling the save path "to Photos" was inaccurate for the
  current code.
- The "silent fail" was a state-machine UX bug rooted in
  `Recording.stop()`. The pre-fix code used `withTaskGroup` with a
  work child (`writer.finishWriting`) and a deadline child
  (`clock.sleep(deadlineMs)` then conditional `cancelWriting`).
  `withTaskGroup` does not auto-cancel siblings when one finishes,
  and the deadline child had no early-out, so `group.waitForAll()`
  always blocked for the full `recordingFinishTimeoutSeconds` (5 s).
  That kept `recordingState` in `.finalizing` for 5 s after every
  stop, and `RecordingViewModel.toggleRecording`'s `default: break`
  branch correctly no-op'd in `.finalizing` — meaning rapid follow-up
  taps fell through silently.
- Same family as CLAUDE.md §8's `withThrowingTaskGroup` invariant
  (deadlock-via-untorndown child). The non-throwing variant has the
  identical pathology.

**Fix shape:** `Recording.stop()` rewritten to mirror the canonical
ADR-30 pattern in `AsyncWithTimeout.runOnQueue` —
`withCheckedContinuation` + `ManagedAtomic<Bool>` CAS race between
work and deadline branches. Whichever resumes first wins; the loser
no-ops idempotently. Post-fix HITL: stop `durationMs` 39-99 ms
(vs 5032-5102 ms pre-fix); zero `toggle no-op (state=finalizing)`
log events under rapid double-tap.

**Probes kept** (load-bearing observability for the recording state
machine — cheap and useful for any future regression):
- `RecordingViewModel.toggleRecording` — entry log of state;
  `default`-branch no-op log; `try?` replaced with `do/catch` +
  `CameraKitLog.error` so engine throws surface.
- `CameraEngine.startRecording`/`stopRecording` — entry/exit logs
  with `pipeline.isRecording`, `recording==nil`, `durationMs`.
- `Recording.stop` — entry/exit logs with writer status and
  `didCancel`.

**Regression test:** new `Stage10StopPromptnessTests` suite in
`CameraKit/Tests/CameraKitTests/Stage10Tests.swift`. Compile-verified;
execution blocked on this machine by the pre-existing host-app-wiring
gap in CLAUDE.md §8.

**Out of scope, captured for follow-up:** Documents-container
visibility. Recording files land in the app's private Documents and
are invisible to Files / Photos. Two-piece fix planned in a separate
workstream: (1) `INFOPLIST_KEY_UIFileSharingEnabled` +
`INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` to surface
Documents in the Files app; (2) `PHPhotoLibrary` save for recorded
video, mirroring `StillCapture.swift`'s pattern (needs
`NSPhotoLibraryAddUsageDescription`). See plan doc forthcoming under
`docs/superpowers/plans/`.
