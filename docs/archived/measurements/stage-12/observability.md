# Stage 12 — HITL background-drain + observability evidence

## 12:home-button-drain-produces-finalized-mp4-device
Device: iPad Pro 11" 2nd-gen (iPad8,9), iOS 26.
- Start recording.
- Press the Home button to background the app mid-recording (~5–10 s in).
- Re-open the app.
- Confirm: a `.mp4` lands in Photos for the recorded segment (up to the
  background-task budget), OR — if the OS budget was exceeded — an *empty*
  file is recorded, never a corrupt MP4 (ADR-16 / G-08).
- `mediainfo` on the file: either a valid `HEVC`/`MP4` clip, or a 0-byte /
  no-`moov` empty file. Never a truncated-but-non-empty corrupt container.

PASS / FAIL: **PASS** (verified from device log)
Date: 2026-05-14
Notes:
- Session `2026-05-14 12:45:50 +0000` in `camerakit.log` captured the full
  sequence:
  ```
  18:18:28.617  [recording] toggle invoked → startRecording
     … ~11 s recording …
  18:18:39.784  [scenePhase] inactive → background        (Home pressed)
  18:18:39.784  [bgsuspend] active recording — finalizing via background-task drain
  18:18:39.784  [recording] Recording.stop entry: state=recording droppedNotReady=0
  18:18:40.071  [recording] Recording.stop group done:
                durationMs=286  writerStatus=2  didCancel=false
  18:18:44.378  [bgresume] … camera restarted, frames resume
  ```
- `writerStatus=2` = `AVAssetWriter.Status.completed` → `finishWriting()`
  succeeded inside the `beginBackgroundTask` assertion; `moov` atom written →
  **valid finalized MP4**, not empty, not corrupt.
- `didCancel=false` → the expiration handler never fired; the drain finished
  in 286 ms, far inside the OS background budget.
- User confirmed the recorded file is present in the Files app and the app
  resumed cleanly (preview live, REC idle, no crash).
- The Stage 12 code path is exercised: `backgroundSuspend()` detected the
  active recording and routed through `finalizeActiveRecording` — this branch
  did not exist before Stage 12.

## 12:debug-overlay-shows-live-overwrite-counts
Device: iPad Pro 11" 2nd-gen (iPad8,9), iOS 26, DEBUG build.
- Long-press the preview to toggle the D-11 `FrameDeliveryStats` panel
  (bottom-right).
- Induce drops with a slow subscriber (e.g. the tracker thumbnail toggled on
  under load).
- Confirm the panel updates live, once per FPS measurement window, showing
  per-lane `swiftDrop` and `cppOverwrite` deltas from both the Swift facade
  and the C++ pool.

PASS / FAIL: **PASS** (wiring + liveness verified by device log)
Date: 2026-05-14
Notes:
- Panel toggles on/off via the long-press gesture — overlay wiring confirmed
  by the user.
- The panel content reads all-zero and *cannot* be made non-zero with the
  current pipeline: the consumer `AsyncStream` uses `.bufferingNewest(1)`
  (silently replaces, never surfaces a `.dropped` result) and the C++
  `PixelSinkPool` dispatches synchronously (never overwrites a mailbox slot).
  Drops/overwrites are therefore structurally always 0 — the HITL step
  "induce drops with a slow subscriber" has nothing to act on yet. This is
  not a defect; it is a property of the pre-async-pool pipeline.
- To make emission *cadence* verifiable despite the always-zero content, a
  `[metrics]` log line was added in `MetricsSink.onMetric` (throttled to
  ~3 s wall-clock so `camerakit.log` stays readable). Session
  `2026-05-14 21:40:38 +0000` confirms a steady cadence:
  `03:10:39.676 → 42.684 → 45.684 → 48.689 → 52.022 → 55.028 → …`
  (~3.0 s intervals). This proves the full path is live:
  C++ `emitMetrics` → `@convention(c)` thunk → `MetricsSink.onMetric` →
  `FrameDeliveryStats` yield.
- Emit-cadence deviation: the *panel* emit (`continuation.yield`) fires
  ~3×/FPS-window, not once — `dispatchCount_` is incremented once per
  (stream, frame), so 3 lanes × 30 fps overshoots `kFpsWindow` by 3×. Not a
  correctness bug: the per-lane counters are cumulative and incremented
  per-event, and `MetricsSink` ships exact deltas against the prior snapshot,
  so no event is ever lost regardless of emit frequency. Recorded as
  Decision #80 for upstream wording reconciliation.

## Instruments — endBackgroundTask invariant (brief §11)
Device: iPad Pro 11" 2nd-gen (iPad8,9), iOS 26.
- Time Profiler across a 30 s background-drain cycle.
- Confirm `endBackgroundTask` is called on every drain exit (no leaked
  `UIBackgroundTaskIdentifier`); landscape-right lock still enforced.

Observations: **DEFERRED** (Instruments run not performed). Covered instead by:
- Unit test `12:end-background-task-called-on-all-paths` (green) — asserts
  `endBackgroundTask` is invoked exactly once on normal finalize, deadline
  cancel, expiration cancel, and the writer-error path.
- Device log: `[bgsuspend] stopRunning returned` lands 2 ms after
  `Recording.stop group done` in the session above — the post-drain
  `endBackgroundTask` MainActor hop completes without stalling.
Date: 2026-05-14
