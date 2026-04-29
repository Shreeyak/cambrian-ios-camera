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

## Summary — punch-list before Stage 12

| # | Bug | Severity | Status | File |
|---|-----|----------|--------|------|
| 1 | Recursive `os_unfair_lock` in `PixelSink.release/unregister` | BLOCKER | **FIXED** (Stage 11 Phase D-cleanup) | `PixelSink.swift` |
| 2 | Stage 06 `frameNumber == 1` test asserts wrong value | HIGH | **FIXED** (2026-04-30; 4 sites updated to `== 0`) | `Stage06Tests.swift` |
| 3 | Stage 09 `errorStream()` race — continuation set via `Task` | HIGH | **FIXED** (2026-04-30; nonisolated Mutex box; all 4 cached streams) | `CameraEngine.swift` |
| 4 | `processedTex` freezes on long sessions | MED-HIGH | open (unverified) | likely `MetalPipeline.swift` Pass 2 |

**Stage 12 must clear bug 4** before retiring
`scaffolding:10:synchronous-drain-pause` and beginning `UIApplication.beginBackgroundTask`
work. Otherwise the regression sweep won't be trustworthy and the next stage's
pause/resume work will be tested against a partially-broken baseline.
