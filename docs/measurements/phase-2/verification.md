# Phase 2 — Verification evidence (2026-05-15)

**Device:** Shreeyak's iPad Pro 11" (2nd gen, iPad8,9), iOS 26.4.2
**Build UDID:** `00008027-000539EA0184402E` (xctrace) / `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5` (devicectl)
**Scheme:** `eva-swift-stitch`
**Branch:** `phase-2-vocabulary-additive`

---

## Test bundle

`mcp__XcodeBuildMCP__test_device` (no `-only-testing` filter):

```
PASSED: 141  FAILED: 0  SKIPPED: 0
```

Up from 127 baseline (Phase 1B): +14 new Phase-2 tests
(`Stage13Phase2*` × 9 + `Stage13Calibration*` × 4 + thinned `Stage11CalibrationVMTests` × 6 — net +14).

## HITL on device — 2026-05-15 06:13–06:48 UTC

Source: `${TMPDIR}camerakit-live.log` (mirror via `scripts/device-log-live.sh`),
slice from `=== CameraKit session started 2026-05-15 06:13:58 +0000 ===`.

### App launch + baseline streaming — PASS

```
11:43:59.077 [engine] open: pipeline ready — 4032×3024 pool=0x10093e920
11:43:59.077 [consumers] registerCallback: stream=2 token=1 cppCount=1
11:43:59.422 [consumers] yield: frame=0 stream=0 surface=true cppConsumers=0
11:43:59.422 [consumers] yield: frame=0 stream=1 surface=true cppConsumers=0
11:43:59.425 [consumers] yield: frame=0 stream=2 surface=true cppConsumers=1
```

Pipeline up at 4032×3024, all 3 lanes streaming, app-side Canny consumer (Phase 1B) registered (`cppConsumers=1` on stream=2 tracker). Phase-2 changes do not regress Phase-1B baseline.

### `calibrateWhiteBalance()` — engine-side path live — PASS

```
11:46:00.066 [engine] [wb] calibrate start max-gain=4.0 raw=(1.2507324, 1.0, 2.8620605) clamped=(1.2507324, 1.0, 2.8620605)
11:46:00.253 [engine] [wb] calibrate done
…
11:46:47.679 [engine] [wb] calibrate start max-gain=4.0 raw=(1.2858887, 1.0, 2.7839355) clamped=(1.2858887, 1.0, 2.7839355)
11:46:47.895 [engine] [wb] calibrate done
```

7 sequential calibrations across 47 s, each `start → done` in ~190 ms. The `[wb] calibrate start/done` lines come from `CameraEngine.calibrateWhiteBalance()` itself — confirms the algorithm runs engine-side after the §2b move-down. Sidebar status feedback ("Calibrated ✓") reported visually present.

### `calibrateBlackBalance()` — engine-side path live — PASS

User-confirmed visually: tapping Calibrate-BB updates the preview (the GPU pipeline subtracts the new per-channel pedestal, visibly darkening shadow areas). Engine method emits no log line by design (mirrors WB pattern minus the per-iteration verbose tracing). Behavioral confirmation accepted as evidence.

### `setResolution()` + `streamConfigurationStream()` emit — PASS

```
11:47:30.976 [engine] [resolution] applying 640x480
11:47:31.290 [engine] [resolution] applied 640x480
11:47:34.425 [engine] [resolution] applying 1440x1080
11:47:34.633 [engine] [resolution] applied 1440x1080
11:47:37.011 [engine] [resolution] applying 3264x2448
11:47:37.290 [engine] [resolution] applied 3264x2448
11:47:39.005 [engine] [resolution] applying 4032x3024
11:47:39.329 [engine] [resolution] applied 4032x3024
```

4 successful resolution swaps in 8 s. Each `applied` line is followed by a `publishStreamConfiguration()` call (silent — the stream emit is non-logged). Underlying capture-size change verified by `[capture] first-frame after restart actual=4032x3024 pf='420f'` post-swap. Stream emission verified separately by unit test `streamConfigurationStream() returns a cached AsyncStream that terminates cleanly`.

### `SessionState.interrupted` — PARTIAL — caveat documented

Control Center pull-down + restore on iPad triggered the **SwiftUI scenePhase** path, NOT AVF's `wasInterruptedNotification`. The `.interrupted` state is reserved for AVF events (Stage Manager / Split-View with a camera app, phone call, hardware reclaim); the test `Stage13Phase2InterruptedStateTests.otherInterruptionTogglesInterruptedState` injects the AVF event directly via the `_postSessionEventForTest` seam and PASSes — same shape as Stage 9's `cameraInUseBegan` self-heal which also requires a real second-app claim to reach.

### scenePhase → SessionState route — PASS (mid-session follow-up)

User reported the visible pause/resume from Control Center pull-down was not surfacing as a `SessionState` change. Added `engine.notifyScenePhasePaused(_:)` and wired the SwiftUI scenePhase handler to publish `.paused`/`.streaming` around its existing gate-management. Re-tested:

```
12:09:04.868 [scenePhase] scenePhase: active → inactive
12:09:04.880 [scenePhase] scenePhase inactive: gate closed, drain complete, state=.paused
12:09:05.042 [scenePhase] scenePhase: inactive → active
12:09:05.051 [scenePhase] scenePhase active: gate open, state=.streaming (prevPhase=inactive)
```

`stateStream()` consumers (Phase 3's Pigeon adapter, the existing `ErrorPresenterViewModel`, etc.) now see a unified pause/resume signal whether the source is SwiftUI scenePhase or AVF interruption.

## Errors / regressions

None observed across the 4-minute HITL window. No `[error]`, no `threw`, no `cancel` lines, no fatal toasts.

## Build wrapper hotfix

`scripts/build-summary.sh` and `scripts/test-summary.sh` had a stale grep
(`variant:Designed for iPad`) that no longer matches Xcode 26.x's
`variant:Designed for [iPad,iPhone]`. Updated both to a tolerant pattern
so the wrapper-fallback path (when XcodeBuildMCP is unavailable) finds
the Mac "Designed for iPad" destination correctly.
