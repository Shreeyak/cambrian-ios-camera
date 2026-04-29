# Pre-existing bugs surfaced during Stage 11 regression

Three bugs surfaced when Stage 11's full regression run exercised the test
matrix end-to-end on iPad iOS 26.4.1. None of them were introduced by Stage 11
(Phase D); two were latent for several stages and were masked by an upstream
crash; the third is a runtime pipeline issue observed during the long-running
test suite. **All three must be fixed before Stage 12 begins.**

This file is a punch-list. Each bug has: severity, where it surfaced, root
cause from the relevant source, and a recommended fix (with caveats).

---

## Bug 1 — Recursive `os_unfair_lock` in `PixelSink.release()` / `unregister()`

**Severity:** BLOCKER (was crashing the whole test process; blocks regression).

**Status:** **FIXED in Stage 11 Phase D-cleanup.** Documented here for traceability.

**Where it surfaced:** Stage 01 `consumerRegistrySubscribeUnregister` aborted with
`libsystem_platform.dylib: BUG IN CLIENT OF LIBPLATFORM: Trying to recursively
lock an os_unfair_lock, Abort Cause 20739`. Because Swift Testing runs in
parallel inside one process, the abort cascaded as 58 false "Crash" entries in
the run summary.

**Root cause:** `PixelSink.release()` (and the same pattern in `unregister()`)
called `continuation.finish()` while holding `state.withLock`. The
`onTermination` closure registered in `subscribe(stream:)` re-acquires
`state.withLock` to remove the subscriber from the lane map. On iOS 26.4.1 the
`finish()` synchronously fires `onTermination`, which recurses into the
`Mutex<InnerState>`'s underlying `os_unfair_lock` and aborts.

**File / location:** `CameraKit/Sources/CameraKit/PixelSink.swift`
- old `release()` lines (pre-fix): drained inside the lock.
- old `unregister()` lines (pre-fix): finish-while-holding pattern.

**Fix shape:** Drain the continuations into a local array under the lock, then
call `finish()` *after* the `state.withLock` returns. `onTermination` then
acquires the lock against zero contention. Symmetric fix in `unregister()`.

**Why it was latent:** Earlier iOS versions or earlier test orderings did not
synchronously fire `onTermination` from `finish()`. Stage 06 (commit `5d51be0`
introduced the actor-based `ConsumerRegistry`) exposed the recursive shape; the
2026-04 iOS 26.4.1 update tightened the synchronization timing.

---

## Bug 2 — Stage 06 `frameNumber == 1` test/source drift

**Severity:** HIGH (4 failing test issues; pre-existing; blocks regression).

**Status:** **FIXED 2026-04-30.** Test assertions updated to match the
assign-then-increment ordering. All 7 `Stage06Tests` pass on iPad iOS 26.4.1.

**Where it surfaced:** `Stage06Tests.swift`
- `frameSetPublication()` lines 54–56 (3 assertions: natural / processed / tracker)
- `naturalStreamIsSubscribable()` line 196 (1 assertion)

All four sites assert `?.frameNumber == 1` for the *first* `FrameSet` produced
by `MetalPipeline.encode(...)`. Actual value is `0`.

**Root cause:** `MetalPipeline.swift:472`:
```swift
let fn = frameNumber          // assign current value (starts at 0)
```
And `MetalPipeline.swift:552`:
```swift
frameNumber &+= 1             // increment AFTER use
```

So the first `FrameSet` constructed by `encode()` has `frameNumber = 0`;
incrementing happens after. The next frame is `1`, then `2`, etc.

**git-blame:** Both lines come from commit `9f467ecb` (2026-04-22, Stage 04-08
era). `git log -L 552,552:.../MetalPipeline.swift` shows no earlier version,
so the assign-then-increment ordering has been the source behavior since this
file was written. The test assertion was wrong from the start (or written for
a prototype shape that didn't ship).

**Fix shape:** Update three test sites in `Stage06Tests.swift` from `== 1` to
`== 0`. Add a comment cross-referencing this doc, the way the orientation
constant fix references commit `e09c1f3`.

**Why it was latent:** Bug 1 (recursive lock crash) was aborting the test
process before the Stage 06 frame-number tests ran in any full regression
sweep. Filtering to Stage 09/10 in earlier stages bypassed Stage 06 entirely.

---

## Bug 3 — Stage 09 `errorStreamDeliversEveryTransition` race / hang

**Severity:** HIGH (test hangs forever; blocks any full regression).

**Status:** **FIXED 2026-04-30.** All four cached-stream patterns in
`CameraEngine.swift` (`stateStream`, `errorStream`, `frameResultStream`,
`recordingStateStream`) converted from actor-isolated `Task { await
self?.setXContinuation(c) }` to synchronous `nonisolated let
xContinuationBox = Mutex<Continuation?>(nil)` + `box.withLock { $0 = c }`
inside the AsyncStream init closure. The `_emitErrorForTest` race window is
gone; `errorStreamDeliversEveryTransition()` passes deterministically.

**Where it surfaced:** `Stage09Tests.swift:222–240`. Test was the lone
"started-but-never-completed" entry in the Stage 11 regression's parallel
test-execution log; ran for 3+ minutes producing no progress while the camera
fed CannyStub frames in another concurrent test.

**Root cause:** Race in `CameraEngine.swift:345-355`:
```swift
public func errorStream() -> AsyncStream<CameraError> {
    if let cached = cachedErrorStream { return cached }
    let stream = AsyncStream<CameraError>(
        CameraError.self,
        bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
    ) { [weak self] continuation in
        Task { await self?.setErrorContinuation(continuation) }   // ← async!
    }
    cachedErrorStream = stream
    return stream
}
```

The continuation is set via an unordered `Task { await self?.setErrorContinuation(continuation) }`,
not synchronously inside the closure. `errorStream()` returns to the caller
*before* `errorContinuation` is non-nil. If the test then dispatches
`_emitErrorForTest` calls onto the actor mailbox before that inner Task runs,
`publishError`'s `errorContinuation?.yield(err)` is a no-op (`errorContinuation`
is still nil). The 5 emitted errors are silently dropped. The for-await never
sees any of them; loop never reaches `count == 5 { break }`; test hangs.

Pre-existing bug since Stage 09 (commit `e6232be`). Probably racing-passing on
prior iOS / hardware due to faster Task scheduling.

**File / location:** `CameraKit/Sources/CameraKit/CameraEngine.swift:345-355`.

**Fix shape:** Set the continuation **synchronously** inside the AsyncStream
init closure rather than via a Task hop. Two viable variants:

```swift
// Option A: hold continuation via nonisolated mutex (no actor hop).
let stream = AsyncStream<CameraError>(...) { [weak self] continuation in
    self?.errorContinuationLock.withLock { $0 = continuation }
}
```

```swift
// Option B: synchronous nonisolated property (Mutex<Continuation?> field).
private nonisolated let errorContinuationBox = Mutex<AsyncStream<CameraError>.Continuation?>(nil)
...
let stream = AsyncStream<CameraError>(...) { [weak self] continuation in
    self?.errorContinuationBox.withLock { $0 = continuation }
}
```

Either way, kill the `Task { await ... }` so the continuation is live by the
time `errorStream()` returns to the caller. The `setErrorContinuation` private
method goes away. Same fix likely needed in `stateStream()` and any other
cached-stream-with-Task-set pattern in `CameraEngine.swift`. Audit all call
sites before landing.

**Caveats:** `bufferingOldest` will still deliver every error if the
continuation is set by the time the first emit lands. The test will pass after
this fix.

---

## Bug 4 — `processedTex` stuck during long-running test (right-side preview frozen)

**Severity:** MEDIUM-to-HIGH (pre-existing pipeline issue; user-visible during
Stage 11 regression on iPad).

**Status:** **NOT YET FIXED.** Observed empirically; not yet root-caused.
Punch-list item for Stage 12.

**Where it surfaced:** During the Stage 11 regression run, with the test host
app launched on the iPad, the right-side preview (`processedTex` lane) froze
showing the same frame for 2-3 minutes while the left-side preview
(`naturalTex` lane) continued updating normally. Tracker stream (`stream=2`)
also kept flowing — CannyStub frame counter climbed to 6390+ in the log. So:
*natural and tracker keep producing; processed is stuck.*

**Root-cause hypotheses (UNVERIFIED):**
1. `MetalPipeline` Pass 2 (RGBA16F → tone-mapped processed) errored silently and
   stopped writing the processed `CVPixelBuffer`. Texture handle stays alive,
   pixel data freezes.
2. The processed `CVPixelBufferPool` exhausted; `dequeue` started returning
   nil; Pass 2 silently no-ops. Same visible symptom.
3. A `Mutex<UniformStorage>` write contention path stalls Pass 2 specifically.
   Less likely — would affect both natural and processed.
4. `DisplayViewModel.processedTex` lost its strong reference via some
   `@ObservationIgnored nonisolated(unsafe)` race. Less likely — would also
   affect natural in the same way.

**Why it matters:** This is a real user-facing freeze on a long-running session.
It's not a test-only bug. If it reproduces in production it would manifest as a
preview that goes stale after several minutes.

**Investigation steps for Stage 12:**
1. Reproduce: leave the app running on iPad with `processedTex` visible for
   5+ minutes. Confirm the freeze happens without the test runner.
2. Add temporary logging to `MetalPipeline` Pass 2: log every Nth frame's
   command-buffer status and pool-dequeue success. Look for a transition from
   `success` to `silent fail`.
3. Inspect `CVPixelBufferPool` for the processed lane — is `kCVPixelBufferPool
   FreeBufferCount` dropping to 0 over time? Pool age / minimum buffer count
   tuning may need revisiting.
4. Check the `MetalPipeline.uniforms.withLock` contention — see ADR-34 / D-17 /
   Inv-6. If host writes flood the lock during slider drags concurrent with the
   Pass 2 critical section, that could starve Pass 2.

**Caveats:** Engine code (`MetalPipeline.swift`, `PixelSink.swift` per-frame
`yield()` path) was *not* modified by Stage 11 Phase D. So the bug pre-exists
Phase D. Confirmed via `git diff HEAD --stat` on those files.

---

## Bug 5 — Bottom bar permanently greyed on launch (Settings/Calibrate/Capture/REC unusable)

**Severity:** HIGH (entire bottom-bar control surface is unreachable; blocks any
HITL run that touches sliders/record/capture).

**Status:** **FIXED 2026-04-30** in commit `a4f2607` — `CameraEngine.init`
now eagerly constructs all four cached streams (state/error/frameResult/
recording) so each box continuation is installed before any `publishX(...)`
call. Cached vars marked `nonisolated(unsafe)` (single-writer-per-phase: init
then optional clear in `close()`). Confirmed via HITL on iPad — bottom bar
lights up at launch.

Surfaced 2026-04-30 during Bug 4 HITL run on Shreeyak's iPad (HEAD
`9719ecf`).

**Where it surfaced:** App launches, both previews stream correctly (frame
counter `#20,060 t=128,700,515ms` visible in tracker overlay), but the bottom
bar (Settings, Calibrate, Capture, REC, resolution label) is rendered dim and
non-tappable. DEBUG sidebar buttons (Hide Tracker, Halt Pass 2, Resume Pass 2)
are tappable — those are not enablement-gated.

**Root-cause hypothesis (UNVERIFIED):**
`ControlEnablement` (`ControlEnablement.swift:32-37`) gates every bottom-bar
control on `sessionState == .streaming`. The viewmodel's `sessionState` mirror
is updated only inside `for await state in await engine.stateStream()` in
`ViewModel.swift:109-111`, which runs *after* `try await engine.open()` returns.
If the engine emits `.streaming` during/before `open()` returns and the
cached `stateStream()` continuation isn't yet installed (Bug 3 sibling: cached
stream + lazy install pattern), the `.streaming` emit is dropped — the
`sessionState` mirror stays at its initial `.closed`, and every gated
enablement boolean stays `false`.

Bug 3 closed the *async-Task install* race for the four cached streams, but
did **not** address the *cached + lazy first-construction* race where the
publisher emits before the subscriber ever calls `xStream()`. With
`bufferingOldest(N)` the lazily-constructed stream cannot replay events that
predate its construction.

Verification needed: dump `sessionState` value at HITL and grep for `[CameraEngine]`
state-publish lines in `camerakit.log`. If `publishState(.streaming)` runs
*before* `ViewModel.start()` reaches `engine.stateStream()`, hypothesis is
confirmed.

**Fix shape (likely):** Construct the cached `stateStream()` eagerly during
`CameraEngine.init()` so the box continuation is live before any state-publish
can happen. Same eager-construction may be needed for the other three cached
streams (errorStream / frameResultStream / recordingStateStream) — audit each
publish-before-subscribe risk window.

**Caveats:** Race may also be hidden in the bridge between `engine.open()`'s
internal state machine and the public `publishState(...)` helper. Walk both
paths before committing to a fix.

---

## Bug 6 — Green rendering band below previews (CAMetalLayer artifact)

**Severity:** MEDIUM (cosmetic but loud; immediate visual regression).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 during the same HITL run.

**Where it surfaced:** Below the two side-by-side previews, the area down to
the (greyed) bottom bar fills with a uniform bright-green band that spans the
full window width and the entire vertical gap. Both natural and processed
preview content above it look correct.

**Root-cause hypothesis (UNVERIFIED):** Classic CAMetalLayer-uninitialized-memory
symptom from CLAUDE.md §8 invariants. Two candidates:
1. An MTKView (or layer-hosting view) under the bottom bar acquires a
   `currentDrawable` but never calls `present(drawable)`. CAMetalLayer then
   shows whatever was last in that GPU memory — often green when it's an
   un-cleared YCbCr scratch. Per CLAUDE.md §8: *"Never return between
   `view.currentDrawable` and `commandBuffer.present(drawable)`."*
2. A blit with non-zero `sourceOrigin` or `destinationOrigin` on the
   IOSurface-backed `naturalTex` / `processedTex`. Per CLAUDE.md §8:
   *"non-zero origins on IOSurface-backed textures … silently break rendering
   (both previews go green, no crash, no error without the Metal validation
   layer enabled)."* Visible only as a band below — implies the affected blit
   targets a layout region that's only the gap between previews and bar.

**Verification needed:** Enable Metal API validation in scheme, relaunch, look
for blit-origin or unpresented-drawable diagnostics. Inspect view tree —
which view's CAMetalLayer covers the green region. Likely a stray/zero-sized
preview MTKView that wasn't culled by the Stage 11 rewire.

**Fix shape (after verification):** Either (a) enforce always-present on every
drawable acquisition path (drop early returns) or (b) zero out blit origins on
all IOSurface targets — the §8 invariants spell out the discipline.

---

## Bug 7 — White-balance Calibrate action crashes the app

**Severity:** BLOCKER (one-tap crash on a top-level user surface).

**Status:** **FIX APPLIED 2026-04-30** (awaiting HITL re-verify). Root cause
identified from crash log `eva-swift-stitch-2026-04-30-030647.ips`:
`AVCaptureFigVideoDevice setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:`
threw `NSInvalidArgumentException` because `grayWorldGains` (in
`CalibrationCompute.swift`) returns gains derived as `mean / channel`, which
for any non-gray sample easily exceeds `[1.0, maxWhiteBalanceGain]` —
AVFoundation rejects the call. Fix: `applySettings` (`CameraSession.swift`)
now clamps each manual WB gain to `[1.0, maxWhiteBalanceGain]` before the
device write — single chokepoint protects every WB write path.

**Where it surfaced:** Calibrate sidebar → tap **White Balance** → app
terminates immediately. Black Balance from the same sidebar does not crash;
other GPU sliders work.

**Root-cause hypothesis (UNVERIFIED):** Crash on the WB-specific code path —
candidate sites: an unwrap of an optional readback (`focus`/`exposure`/`wbGains`
nilable from `AVCaptureDevice` until first KVO emit), an `AVCaptureDevice
.lockForConfiguration` violation off `sessionQueue`, or an attempt to set
`whiteBalanceGains` outside the device-supported gain-range. Need crash log
to discriminate.

**Investigation steps:** Pull device crash log (`xcrun devicectl device copy
from --device <devicectl-udid> --domain-type systemCrashLogs --source "/"
--destination /tmp/crash/`) and `<Documents>/camerakit.log`; grep for `[wb]`
or `[calibrate]` lines and the last engine state before crash. Cross-check
against the Calibrate WB handler.

---

## Bug 8 — Black-balance has no point-of-measurement indicator

**Severity:** LOW (functional but undiscoverable; user can't verify which
pixel is being sampled).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad.

**Where it surfaced:** Calibrate → Black Balance — sliders affect output
(green channel slider visibly drives the green-buffer artifact, see Bug 6)
but no on-screen reticle / target indicates the sample point.

**Fix shape:** Render a small reticle at the sampled pixel coordinate during
black-balance mode; surface the sampled XY in the calibration sidebar.

---

## Bug 9 — Still-capture image has 4032×3024 dimensions but actual frame fills only top-left fraction; remainder is green

**Severity:** HIGH (capture output is unusable; ships green padding).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad.

**Where it surfaced:** Tap Capture — saved still is 4032×3024 but the
actual photographic content occupies less than half the height and width in
the top-left corner; the rest of the frame is uniform green.

**Root-cause hypothesis (UNVERIFIED):** Almost certainly the same green-
buffer family as Bug 6 — Pass 2 (or whatever the still-capture path uses)
writes only a sub-region of a destination texture/CVPixelBuffer, leaving
the remainder showing un-cleared GPU/IOSurface memory. Candidates: viewport
mismatch in still-capture encode, or a destination texture larger than the
captured image with no background clear.

User confirmed the green-channel slider on Black Balance affects the green
band on the live preview — confirming the green region is a real GPU buffer
holding stale output, not a layer transparency artifact. Bug 6 (live
preview) and Bug 9 (still capture) are likely the **same root cause**;
investigate together.

**Investigation steps:** Inspect the still-capture path (`StillCapture` /
`MetalPipeline` capture-encode site) for viewport/region setup; enable the
Metal validation layer; verify texture size vs encoded region.

---

## Bug 10 — REC button crashes the app

**Severity:** BLOCKER (recording is a primary surface; one-tap crash).

**Status:** **FIX APPLIED 2026-04-30** (awaiting HITL re-verify). Root cause
identified from crash log `eva-swift-stitch-2026-04-30-030858.ips`:
`AVCaptureFigVideoDevice setActiveVideoMaxFrameDuration:` threw
`NSInvalidArgumentException` because `CameraSession.setRecordingFrameRateRange()`
called the AVFoundation setters **without** wrapping them in
`lockForConfiguration` / `unlockForConfiguration` — required by AVFoundation
for any device-config mutation. Fix: both `setPreviewFrameRateRange` and
`setRecordingFrameRateRange` now acquire the device lock around the
`setVideoFrameDurationRange` call (matches the pattern in `applySettings`).

**Where it surfaced:** Tap REC — app terminates immediately.

**Root-cause hypothesis (UNVERIFIED):** Stage-10 recording path. Candidates:
an `AVAssetWriter.startWriting()` precondition violation; a Metal/CVPixelBuffer
type mismatch when the recording lane attaches to the encoder; or a
`recordingStateStream()` interaction with the new `nonisolated(unsafe)`
cached-stream pattern from Bug 5 fix (race or aliasing introduced by the
fix? — eager construction shouldn't change recording semantics, but rule it
out). Crash log will discriminate.

**Investigation steps:** Pull crash log + `camerakit.log`; grep for `[rec]`
/ `[recording]` lines and the last state before crash.

---

## Bug 11 — Resolution control is a static label, not a button

**Severity:** LOW-MED (regression vs. domain spec or pre-Stage-11 behavior).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad.

**Where it surfaced:** Bottom bar shows the current capture resolution
(e.g. `4032×3024`) as a label that does not respond to taps. User cannot
change camera resolution from the UI.

**Root-cause hypothesis (UNVERIFIED):** Either a missed wire in the Stage
11 bottom-bar rewire (`CameraView.swift:134` `resolutionLabel(...)`) — the
label was rendered but the tap handler / picker presentation never landed —
or this is intentional Stage 11 scope and the picker is a Stage-12 task.
Cross-check against `briefs/stage-11.md` § resolution control.

---

## Bug 12 — Black preview on launch; freezes/streams in response to capture/REC

**Severity:** HIGH (preview useless on cold launch).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad after Bug
7+10 fix install. Frame counter overlay shows frame numbers climbing —
engine and pipeline are streaming — but both MTKView preview panels show
black. Tapping **Capture** saves the still successfully and unfreezes the
preview to a single frozen frame. Tapping **REC** starts continuous preview
streaming. Stop REC keeps the preview running.

**Root-cause hypothesis (UNVERIFIED):** MTKView's render loop appears
"paused" until a state-change kicks it. Two candidates:
1. Persisted WB-manual settings from the previous run apply during `open()`
   (`CameraEngine.swift:255-266`); this introduces a `lockForConfiguration`
   window that may interact with the MTKView's first-frame drawable
   acquisition. Capture/REC issue subsequent device-config events that
   "unstick" the render loop.
2. SwiftUI `MTKViewRepresentable` is being torn down + recreated on parent
   re-renders; the new MTKView's first `currentDrawable` returns nil before
   layout settles, the `draw(in:)` early-returns, and without
   `enableSetNeedsDisplay` the view never schedules another draw until an
   external trigger (capture/REC) forces a body re-evaluation.

**Investigation steps:** Wipe persisted UserDefaults + relaunch — if black
screen disappears, hypothesis 1; if it persists, hypothesis 2. Add probe
logging in `MTKViewCoordinator.draw(in:)` to count drawable-nil returns vs
successful blits over the first 10 seconds.

---

## Bug 13 — Manual WB calibrate is one-shot with no revert / re-sample / auto path

**Severity:** MEDIUM (UX dead-end — once calibrated, user is stuck).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad.

**Where it surfaced:** First WB Calibrate tap applies a tint (pink for a
mostly-grey reference patch — gain math also questionable). Subsequent
Calibrate taps are silent — no re-sample, no recompute. There is no
"revert to auto WB" affordance, no "re-sample at new patch" path, and the
calibrated state persists across app launches via `SettingsPersistence`.

Combined with Bug 12, this means a single bad calibrate locks the user
into a permanently-tinted preview that only resets on app uninstall.

**Fix shape:** (1) Each Calibrate tap should re-sample and recompute; (2)
Add an explicit "Auto WB" / "Reset" affordance that writes
`wbMode = .auto` (clearing manual gains); (3) Cross-check `grayWorldGains`
math against a known grey reference — pink tint suggests channel sample
units / scaling are off. See `CalibrationCompute.swift`.

---

## Bug 14 — Second REC press silently fails to save video

**Severity:** HIGH (data loss on a primary surface).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad.

**Where it surfaced:** First REC → recording starts, stop → file saved.
Second REC tap → no crash, no save (no banner, no file produced).

**Root-cause hypothesis (UNVERIFIED):** Second-call recording state
machine in `Recording.swift` (or the `assetWriter` lifecycle) doesn't
reset after first-stop, leaving a stale writer / completion handler that
the new `start(...)` invocation conflicts with. Could also be `pipeline
.isRecording` atomic stuck true when it shouldn't be, blocking encoded
buffers from reaching the new writer.

**Investigation steps:** Pull `<Documents>/camerakit.log` after a
two-press REC sequence; inspect `[recording]` markers around start/stop
boundaries. Verify `assetWriterFactory` is invoked on the second start.

---

## Bug 15 — Debug overlay (`#frame t=… edges=…`) freezes after a minute or so

**Severity:** LOW (DEBUG-only).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad after Bug 4
mailbox-forwarding fix install (HEAD post-Bug-4).

**Where it surfaced:** `DisplayViewModel.startDebugOverlay()` subscribes via
`engine.consumers.subscribe(.natural)` and writes `self.debugOverlay`
inside `MainActor.run { … }` for every 10th frame. After ~1000 frames
(~33 s), the overlay text stops updating while previews keep streaming.

**Producer is healthy.** `camerakit.log` shows `[consumers] yield: …
stream=0` lines continuing past frame 11100 with no errors / no
`terminate`/`unsubscrib`/`cancel` markers. The publisher keeps yielding;
the subscriber's for-await loop has stalled.

**Root-cause hypotheses (UNVERIFIED):**
1. `MainActor.run { self.debugOverlay = overlay }` is blocking on a
   saturated MainActor queue — every body re-eval (e.g. `lastFrameResult`
   updates at 30 Hz, slider drags) competes for the same actor.
2. The subscribe-side AsyncStream's `bufferingNewest(1)` semantics + a slow
   consumer may be silently dropping every frame, but only the first 100
   `% 10 == 0` frames have content the consumer absorbs before the
   `cannyStub.processedCount` lookup deadlocks against the C++ pool.
3. Same family as Bug 16 — an underlying MainActor stall is masking both.

---

## Bug 16 — ISO / Shutter slider readouts freeze at last value despite the device still applying changes

**Severity:** MEDIUM (HITL-blocking; user can't trust UI state).

**Status:** **NOT YET FIXED.** Surfaced 2026-04-30 HITL on iPad after Bug
4 fix install. `HardwareControlsViewModel.currentSettings` is the source
of truth for the slider readouts; it's updated optimistically after
`engine.updateSettings(delta)` succeeds (`HardwareControlsViewModel
.swift:43-47`):

```swift
try await engine.updateSettings(delta)
await MainActor.run { [weak self] in
    self?.currentSettings = delta.merging(onto: self?.currentSettings ?? .init())
}
```

User confirms the **device** is receiving the values (image brightness
responds to shutter changes), but the slider visual freezes at ISO=1731,
shutter=25 ms. So the engine commit is succeeding; the optimistic
post-commit `currentSettings = …` write is either not running or not
re-rendering the view.

**Root-cause hypotheses (UNVERIFIED):**
1. Same MainActor saturation as Bug 15 — `MainActor.run` queues but never
   executes after the actor falls behind.
2. `delta.merging(onto:)` is producing a value `==` to the previous
   `currentSettings`, so SwiftUI's @Observable diff is a no-op — but
   user-visible image change argues against this.
3. SwiftUI's @Observable tracking lost the binding for `currentSettings`
   after some view-tree shuffle — possibly tied to the MTKView refactor
   in the Bug 4 fix.

**Investigation steps:** Add a print/log inside `applyDelta` after the
`MainActor.run` block to confirm currentSettings is actually written
post-stall. If yes → SwiftUI re-render path. If no → MainActor stall.

---

## Summary — punch-list before Stage 12

| # | Bug | Severity | Status | File |
|---|-----|----------|--------|------|
| 1 | Recursive `os_unfair_lock` in `PixelSink.release/unregister` | BLOCKER | **FIXED** (Stage 11 Phase D-cleanup) | `PixelSink.swift` |
| 2 | Stage 06 `frameNumber == 1` test asserts wrong value | HIGH | **FIXED** (2026-04-30; 4 sites updated to `== 0`) | `Stage06Tests.swift` |
| 3 | Stage 09 `errorStream()` race — continuation set via `Task` | HIGH | **FIXED** (2026-04-30; nonisolated Mutex box; all 4 cached streams) | `CameraEngine.swift` |
| 4 | `processedTex` freezes on long sessions — capture-once mailbox stranded by pool rotation | MED-HIGH | **FIX APPLIED** (2026-04-30; live mailbox forwarding in `CameraEngine`/`DisplayViewModel`); HITL: right preview no longer freezes | `CameraEngine.swift` / `DisplayViewModel.swift` |
| 5 | Bottom bar permanently greyed (cached-stream lazy-install race) | HIGH | **FIXED** (2026-04-30 commit `a4f2607`; eager cached-stream construction in `CameraEngine.init`) | `CameraEngine.swift` |
| 6 | Green rendering band below previews | MED | open (unverified; same family as Bug 9) | likely Metal preview layer / blit origin |
| 7 | White-balance Calibrate crashes app — gains out of `[1.0, maxWB]` | BLOCKER | **FIX APPLIED** (2026-04-30; clamp in `applySettings`); awaiting HITL | `CameraSession.swift` |
| 8 | Black-balance has no sample-point indicator | LOW | open | Calibrate sidebar / overlay |
| 9 | Still-capture image content occupies only top-left fraction; rest green | HIGH | open (unverified; same family as Bug 6) | likely still-capture encode path |
| 10 | REC button crashes app — fps-range setters missing `lockForConfiguration` | BLOCKER | **FIX APPLIED** (2026-04-30; lock around setters); awaiting HITL | `CameraSession.swift` |
| 11 | Resolution control is a static label, not a button | LOW-MED | open | `CameraView.swift` resolutionLabel |
| 12 | Black preview on cold launch; capture/REC unfreezes it | HIGH | open (unverified) | `MTKViewRepresentable` / persisted-settings replay path |
| 13 | WB Calibrate is one-shot with no revert / re-sample / auto path | MED | open | `CalibrationViewModel` / `CalibrationCompute` |
| 14 | Second REC press silently fails to save video | HIGH | open (unverified) | `Recording.swift` lifecycle |
| 15 | Debug overlay freezes ~frame 1000 (DEBUG-only) | LOW | open (unverified; possibly MainActor stall) | `DisplayViewModel.startDebugOverlay` |
| 16 | ISO/Shutter slider readouts freeze despite device receiving values | MED | open (unverified; possibly MainActor stall — likely same as Bug 15) | `HardwareControlsViewModel` |

**Stage 12 must clear bugs 6, 9, 11, 12, 13, 14, 15, and 16** (plus optionally 8) before retiring
`scaffolding:10:synchronous-drain-pause` and beginning `UIApplication.beginBackgroundTask`
work. Otherwise the regression sweep won't be trustworthy and the next stage's
pause/resume work will be tested against a partially-broken baseline.
