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

**Status:** **FIXED 2026-04-30 / verified 2026-05-09 on iPad.** Root cause:
the still-capture mailbox stranded the most recently produced processed
buffer when the pool rotated. Fix: live mailbox forwarding in
`CameraEngine` / `DisplayViewModel` (commit on 2026-04-30). HITL: right
preview no longer freezes on long sessions; both natural and processed
lanes update continuously.

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

**Status:** **FIXED.** Root cause: `sessionPreset` was not set to `.inputPriority`; switching it forced AVFoundation to honour the physical sensor resolution, eliminating the un-cleared sub-region. Stabilization and low-light boost also disabled as part of the same fix. Commits `027b688` + `1303fbb`.

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

**Status:** **FIXED 2026-04-30 / verified 2026-05-09 on iPad.** Two-layer
defense in place: (1) `applySettings` (`CameraSession.swift`) clamps each
manual WB gain to `[1.0, maxWhiteBalanceGain]` before the device write —
single chokepoint protects every WB write path. (2) The Bug 13 rework
replaced our own `grayWorldGains` math with Apple's
`grayWorldDeviceWhiteBalanceGains` + a final `min/max` clamp in
`CalibrationViewModel.calibrateWB`, so the original out-of-range source
no longer feeds AVF in the first place. HITL: no crash on Calibrate
across multiple presses and varied scenes. Crash log
`eva-swift-stitch-2026-04-30-030647.ips` was the originating evidence
(`AVCaptureFigVideoDevice setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:`
→ `NSInvalidArgumentException`).

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

**Status:** **FIXED — verified 2026-05-09 on iPad.** Stage 11 Task 11
(reticle overlay) renders the sample reticle on the natural-preview lane;
both WB and BB calibrate use the same center-patch coordinates so a single
reticle covers both. HITL confirms the reticle is visible and aligned with
the actual sample location.

**Where it surfaced:** Calibrate → Black Balance — sliders affect output
(green channel slider visibly drives the green-buffer artifact, see Bug 6)
but no on-screen reticle / target indicates the sample point.

---

## Bug 9 — Still-capture image has 4032×3024 dimensions but actual frame fills only top-left fraction; remainder is green

**Severity:** HIGH (capture output is unusable; ships green padding).

**Status:** **FIXED.** Same root cause as Bug 6 — `sessionPreset = .inputPriority` resolved the sub-region write; still-capture path now encodes the full sensor frame. Commit `027b688`.

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

**Status:** **FIXED** (2026-04-30 lock-around-fps-setters in commit `39b9ffe`;
verified 2026-05-12 HITL on iPad `00008027-000539EA0184402E`). REC tap →
recording starts, stop → file saves, no `NSException` / no
`lockForConfiguration` markers in `camerakit.log`.

**Root cause** (confirmed from crash log
`eva-swift-stitch-2026-04-30-030858.ips`):
`AVCaptureFigVideoDevice setActiveVideoMaxFrameDuration:` threw
`NSInvalidArgumentException` because `CameraSession.setRecordingFrameRateRange()`
called the AVFoundation setters **without** wrapping them in
`lockForConfiguration` / `unlockForConfiguration` — required by AVFoundation
for any device-config mutation.

**Fix:** both `setPreviewFrameRateRange` and `setRecordingFrameRateRange` in
`CameraSession.swift:368-401` now acquire the device lock around the
`setVideoFrameDurationRange` call (matches the pattern in `applySettings`).

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

**Status:** **FIXED — verified 2026-05-09 on iPad.** Cold-launch preview
now comes up live in both lanes without requiring a Capture/REC tap to
unstick the render loop. The fix has accumulated across several commits
between the original 2026-04-30 surfacing and 2026-05-09 (live mailbox
forwarding for Bug 4 reshaped the MTKView feed; the persisted-WB strip-on-
load behavior — `SettingsPersistence.load` — removed the `.manual`
`lockForConfiguration` window during `open()` that was hypothesis 1).
Either of those plausibly resolved the stuck-render-loop symptom; HITL
confirms the user-visible black-on-launch is gone.

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

**Status:** **FIXED — verified 2026-05-09 on iPad.** All three fix-shape
items addressed:

1. **Re-sample on every tap.** `CalibrationViewModel.calibrateWB` now
   switches to `.continuousAutoWhiteBalance`, awaits AWB convergence,
   reads `device.grayWorldDeviceWhiteBalanceGains` for the freshly-settled
   scene, and applies. Each tap is a fresh read against the current scene.
2. **Auto / Lock affordances.** Five-button calibration sidebar (Stage 11
   Task 8): Calibrate, Lock, Auto for WB; Calibrate, Reset for BB. Auto
   writes `wbMode = .auto`, clearing manual gains.
3. **Math.** Replaced our `grayWorldGains` (which produced the pink tint
   on grey patches — `mean/channel` ratios out of `[1, maxGain]`) with
   Apple's hardware `grayWorldDeviceWhiteBalanceGains` (Bayer-domain,
   pre-CCM, pre-gamma, scene-aware) — single-shot apply, no iteration.
4. **Persistence.** `SettingsPersistence.load` strips manual on cold
   launch (Stage 11 Task 5) — each session boots in AWB.
5. **UI feedback.** `WBCalibrationStatus` enum (`.idle` / `.calibrating`
   / `.completed`) drives the Calibrate button: spinner during apply,
   green ✓ "Calibrated" for 1.5 s on success, then revert to idle.

History: earlier iterations of this fix attempted a patch-sampled
gray-world iterative loop with various damping schemes (sqrt-step,
log-cap k=0.5/0.25, dark-patch guard, divergence-restore). All
ping-ponged on iPad HITL because AVF's bounded `[1, maxGain]` gain range
doesn't fit the post-CCM patch-sample gray-world geometry. Apple's pre-
CCM Bayer-stat reading is the authoritative answer; iterating on top of
it added cycling-color UX without improving the result.

---

## Bug 14 — Second REC press silently fails to save video

**Severity:** HIGH (data loss on a primary surface).

**Status:** **FIXED** (2026-05-12 — CAS-race finalize in `Recording.stop`;
verified 2026-05-12 HITL on iPad `00008027-000539EA0184402E`).

**Symptom (original report):** First REC → recording starts, stop → file saved.
Second REC tap → no crash, no save (no banner, no file produced).

**Root cause (decomposed during 2026-05-12 investigation):**

The user-observable "second tap fails" was two issues braided together:

1. **`Recording.stop()` always blocked for the full 5 s finalize deadline.**
   The pre-fix code used `withTaskGroup` with a work child (`writer.finishWriting`)
   and a deadline child (`clock.sleep(deadlineMs)` then conditional `cancelWriting`).
   `withTaskGroup` does **not** auto-cancel siblings when one finishes, and the
   deadline child had no early-out, so `group.waitForAll()` always waited the
   full `Constants.recordingFinishTimeoutSeconds` (5.0 s). Post-fix HITL: stop
   `durationMs` was **39–99 ms** vs **5032–5102 ms** pre-fix.

2. **`RecordingViewModel.toggleRecording` swallowed taps during `.finalizing`.**
   The state-machine `default` branch correctly no-ops in `.finalizing` /
   `.paused`, but that window was 5 s instead of milliseconds, so the user's
   second REC tap (and any rapid follow-ups) silently fell through. Once #1
   was fixed, the `.finalizing` window collapsed to ~50 ms and the tap landed
   normally.

The "no file produced" half of the original symptom was a misdiagnosis: files
were always being written to `<Documents>/<timestamp>.mp4`, but the
container is private (no `UIFileSharingEnabled`, no Photos save) so they were
invisible to the Files app and Photos app. See "Out of scope" below.

**Fix:** `Recording.swift:127-176` rewritten to use the canonical ADR-30
`AsyncWithTimeout.runOnQueue` pattern — `withCheckedContinuation` + a
`ManagedAtomic<Bool>` CAS race between the work branch and the deadline branch.
Whichever wins resumes the continuation; the loser no-ops. This is the same
pattern documented in CLAUDE.md §8 for the `withThrowingTaskGroup` family of
bug, applied to the non-throwing variant.

Additional in-place observability (kept post-fix):
- `RecordingViewModel.toggleRecording` — entry log of state; default-branch
  no-op log; `try?` replaced with `do/catch` + `CameraKitLog.error` so engine
  throws surface.
- `CameraEngine.startRecording`/`stopRecording` — entry/exit logs including
  `pipeline.isRecording`, `recording==nil`, and `durationMs`.
- `Recording.stop` — entry/exit logs with writer status and `didCancel`.

**Regression test:** `CameraKit/Tests/CameraKitTests/Stage10Tests.swift` —
new `Stage10StopPromptnessTests` suite asserts that `stop()` returns within
1 s when `finishWriting` takes ~50 ms (pre-fix: ~5 s). A second test runs
two consecutive `start → submit → stop` cycles and asserts both produce a
`.completed` writer. Compile-verified; execution blocked on this machine by
the pre-existing host-app-wiring gap in CLAUDE.md §8 (CameraKitTests is
tool-hosted and cannot run on iPad device destinations).

**Out of scope for this fix (separate workstream):** the Documents-container
visibility gap — no `UIFileSharingEnabled` and no `PHPhotoLibrary` save path
for recorded video. Plan doc to follow.

---

## Bug 15 — Debug overlay (`#frame t=… edges=…`) freezes after a minute or so

**Severity:** LOW (DEBUG-only).

**Status:** **FIXED.** Root cause: camera session failed to resume after app was sent to background; the `scenePhase` / session-restart fix unblocked the downstream `MainActor.run` writes that drive the overlay. Commit `9c03fd5`.

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

**Status:** **FIXED.** Same root cause as Bug 15 — session-restart after backgrounding unblocked the `MainActor.run` path in `applyDelta`; slider readouts resume updating correctly. Commit `9c03fd5`.

`HardwareControlsViewModel.currentSettings` is the source
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
| 4 | `processedTex` freezes on long sessions — capture-once mailbox stranded by pool rotation | MED-HIGH | **FIXED** (2026-04-30 fix; verified 2026-05-09 HITL — right preview keeps flowing on long sessions) | `CameraEngine.swift` / `DisplayViewModel.swift` |
| 5 | Bottom bar permanently greyed (cached-stream lazy-install race) | HIGH | **FIXED** (2026-04-30 commit `a4f2607`; eager cached-stream construction in `CameraEngine.init`) | `CameraEngine.swift` |
| 6 | Green rendering band below previews | MED | **FIXED** (`sessionPreset = .inputPriority` + disable stabilization/low-light boost; `027b688`, `1303fbb`) | `CameraSession.swift` |
| 7 | White-balance Calibrate crashes app — gains out of `[1.0, maxWB]` | BLOCKER | **FIXED** (clamp in `applySettings` + Bug 13 rework dropped our own out-of-range gray-world math; verified 2026-05-09 HITL — no crash) | `CameraSession.swift` / `CalibrationViewModel.swift` |
| 8 | Black-balance has no sample-point indicator | LOW | **FIXED** (Stage 11 Task 11 reticle overlay covers both WB + BB sample point; verified 2026-05-09 HITL) | `CameraView.swift` reticle overlay |
| 9 | Still-capture image content occupies only top-left fraction; rest green | HIGH | **FIXED** (same `sessionPreset = .inputPriority` fix as Bug 6; `027b688`) | `CameraSession.swift` |
| 10 | REC button crashes app — fps-range setters missing `lockForConfiguration` | BLOCKER | **FIXED** (2026-04-30 lock around setters in `39b9ffe`; verified 2026-05-12 HITL — no crash, no `lockForConfiguration` markers) | `CameraSession.swift` |
| 11 | Resolution control is a static label, not a button | LOW-MED | **FIXED** (2026-05-13 — `resolutionLabel` rewritten as a `Menu` over `capabilities.supportedSizes`; `ViewModel.setResolution(_:)` wraps `engine.setResolution`; verified 2026-05-14 HITL on iPad) | `CameraView.swift` resolutionLabel |
| 12 | Black preview on cold launch; capture/REC unfreezes it | HIGH | **FIXED** (verified 2026-05-09 HITL — preview live on cold launch) | `MTKViewRepresentable` / persisted-settings replay path |
| 13 | WB Calibrate is one-shot with no revert / re-sample / auto path | MED | **FIXED** (single-shot Apple `grayWorldDeviceWhiteBalanceGains`; Calibrate / Lock / Auto sidebar; UI status; verified 2026-05-09 HITL) | `CalibrationViewModel.swift` / `CameraView.swift` |
| 14 | Second REC press silently fails to save video | HIGH | **FIXED** (2026-05-12 — `Recording.stop` now uses ADR-30 CAS-race finalize; verified 2026-05-12 HITL — stop `durationMs` 39-99 vs 5032-5102 pre-fix, zero silent `.finalizing` no-ops) | `Recording.swift` |
| 15 | Debug overlay freezes ~frame 1000 (DEBUG-only) | LOW | **FIXED** (camera resume after backgrounding; `9c03fd5`) | `CameraEngine.swift` / scenePhase handling |
| 16 | ISO/Shutter slider readouts freeze despite device receiving values | MED | **FIXED** (same root cause as Bug 15; `9c03fd5`) | `HardwareControlsViewModel` |

**All 16 bugs cleared.** Stage 12 can retire
`scaffolding:10:synchronous-drain-pause` and begin `UIApplication.beginBackgroundTask`
work with no open punch-list blockers.

Bugs 4, 7, 8, 12, 13 cleared 2026-05-09 (HITL verified on iPad
`00008027-000539EA0184402E`, iOS 26.4.x, scheme `eva-swift-stitch`).
Bugs 10 and 14 cleared 2026-05-12 (HITL verified on the same iPad — Bug 10
fix in commit `39b9ffe` re-verified, Bug 14 fix in the same session as the
ADR-30 CAS-race finalize change to `Recording.swift`).
Bug 11 cleared 2026-05-14 (HITL verified on the same iPad — resolution
`Menu` picker applies the selected size, captures land at that size).
