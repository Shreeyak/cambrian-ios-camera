# 02 — Concurrency

Covers isolation topology, Sendable strategy, scenePhase lifecycle, and the Metal
background submission rule. Many of these are gotchas that are not obvious from Apple's
docs but will crash or hang an app.

---

## ADR-07: Dedicated serial queue for AVCaptureSession

`AVCaptureSession` and `AVCaptureDevice.lockForConfiguration()` must be called from a
dedicated serial `DispatchQueue`, not from `@MainActor` and not from inside the
`CameraEngine` actor directly. Apple's explicit requirement.

```swift
let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
```

- `startRunning()` is **synchronous** and blocks 100–500ms waiting for hardware
  readiness. Calling it from `@MainActor` produces the purple runtime warning for UI
  unresponsiveness.
- The sample buffer delegate (`AVCaptureVideoDataOutputSampleBufferDelegate`) also
  uses a serial queue — may be the same queue or a dedicated `delivery` queue.
- The engine actor coordinates *with* these queues but doesn't *replace* them. Model:
  engine actor methods hop onto `sessionQueue` via `sessionQueue.async { }` for session
  work, and the capture delegate runs on the delivery queue and talks back via
  `AsyncStream` continuations or actor-isolated methods.

**Session object is created once per `open()`, reused across pause/resume.** Do not
recreate `AVCaptureSession()` on every `viewWillAppear` / scene transition — it incurs
full hardware re-init latency. See G-07.

### Swift 6 delegate class declaration (ADR-02 / ADR-07)

Under Swift 6 strict concurrency, the `AVCaptureVideoDataOutputSampleBufferDelegate`
conforming class requires four specific attributes — each is load-bearing and omitting
any one produces a compile error or a latent data race. `final`: no subclass can
inadvertently inherit actor isolation from a parent, keeping the conformance isolation
unambiguous. `NSObject`: AVFoundation's delegate protocol is Objective-C; without it
the method is not visible to the runtime dispatcher. `@unchecked Sendable`: the
`CMSampleBuffer` and `AVCaptureOutput` arguments are not compiler-verified `Sendable`,
but the delivery-queue discipline — one dedicated serial queue, no concurrent access —
makes it safe; this is the one legitimate use of `@unchecked Sendable` described in
G-27 ("`@unchecked Sendable` silences the diagnostic but not the data race") because
the queue contract is real and documented. `nonisolated`: the method is invoked on
AVFoundation's `sampleBufferCallbackQueue`, not on `@MainActor` or the engine actor;
marking it `nonisolated` states that explicitly rather than letting the compiler
infer a wrong isolation domain.

```swift
final class SampleBufferDelegate: NSObject, @unchecked Sendable,
                                   AVCaptureVideoDataOutputSampleBufferDelegate {
    // Called on AVCaptureSession.sampleBufferCallbackQueue, NOT MainActor.
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // hand off via AsyncStream continuation; no direct actor calls here.
    }
}
```

---

## ADR-08: scenePhase semantics

SwiftUI `scenePhase` has three values with distinct meanings. Binding the wrong one
to the wrong action causes intermittent bugs:

| scenePhase | Meaning | Action |
|---|---|---|
| `.active` | Foreground, receiving events | Normal submission; resume GPU if gated |
| `.inactive` | Foreground but not receiving events (app switcher, notification banner, incoming call UI, Control Center) | **Gate GPU submission** (ADR-09). Do NOT stop the session. |
| `.background` | Fully off-screen | `sessionQueue.async { session.stopRunning() }`. |

**Do not use `scenePhase == .background` as the GPU gate** — by that point, the GPU
resource may already be revoked and your process terminated. Gate on `.inactive`.

- Session lifecycle calls (`startRunning`/`stopRunning`) are dispatched on `sessionQueue`
  with async+timeout from `@MainActor`; never `sessionQueue.sync` from MainActor. See ADR-30.

**Do not use `scenePhase == .inactive` as the session stop** — it fires on notification
banners, and stopping the camera for a notification banner is unacceptable UX.

UIKit equivalents:
- `applicationWillResignActive` ≈ `scenePhase == .inactive`
- `applicationDidEnterBackground` ≈ `scenePhase == .background`

**App Store policy note.** `session.stopRunning()` on backgrounding is not a
performance optimization — it's a policy requirement. The status-bar camera
indicator must disappear within ~1 second of the app going fully invisible,
otherwise the app is rejectable. The `stopRunning()` call must complete before
the view-layer task returns on the `.background` transition; don't defer it.
See G-19.

---

## ADR-09: Metal background submission rule

Apple's rule, stated flatly: *a Metal app cannot execute Metal commands in the
background, and one that attempts this is terminated.* The violation appears as
`MTLCommandBufferErrorNotPermitted` (IOAF code 6) and the process is killed.

This is fundamentally unlike desktop OSes or Android, where the GPU is a resource
you can keep talking to as long as you hold a surface. On iOS, the GPU is a gated
system resource that's revoked from backgrounded apps.

### Two mandatory actions before backgrounding

**1. Stop submitting new command buffers.** Any `commit()` that lands after the system
backgrounds you risks termination. Use an atomic gate:

```swift
import Atomics  // swift-atomics

let gpuSubmissionEnabled = ManagedAtomic<Bool>(true)

// In the capture delegate, AFTER C++/CV work and consumer yield,
// immediately before commit:
cvPipeline.process(frame)                  // runs regardless of gate
consumerStream.yield(detectionResult)      // async consumers keep flowing

guard gpuSubmissionEnabled.load(ordering: .acquiring) else {
    return  // skip Metal encode + commit + present; release CVPixelBuffer
}
commandBuffer.commit()
lastCommittedCommandBuffer = commandBuffer
```

The gate check must be **after** CPU-side work and **immediately before** `commit()` —
that is the guarded operation. **The gate does not silence async consumers.**
C++/CV pipelines and `AsyncStream` yields run regardless; only the Metal encode +
commit + present path is skipped. During `.inactive` (notification banner, call UI),
detections keep arriving at the view model — only the preview render pauses.

**2. Ensure in-flight work is scheduled** (not completed — scheduled). Already-committed
command buffers run to completion even if the app backgrounds; uncommitted ones
won't. In your backgrounding handler:

```swift
// On scenePhase → .inactive:
gpuSubmissionEnabled.store(false, ordering: .releasing)
lastCommittedCommandBuffer?.waitUntilScheduled()
```

- `waitUntilCompleted()` blocks until GPU execution finishes — too strong, and
  dangerous on main.
- `waitUntilScheduled()` blocks only until the command has been handed to the GPU
  driver — the correct contract.

### What you can safely retain across backgrounding

| Safe to keep | Not safe to keep |
|---|---|
| `MTLDevice`, `MTLCommandQueue`, `MTLLibrary`, compiled pipeline states | Uncommitted command buffers |
| `CVMetalTextureCache` | |
| Pre-allocated `MTLTexture` / `MTLBuffer` pools | |

Holding GPU resource objects is not submission. Retain them across backgrounding to
avoid expensive re-initialization on foreground.

### `.inactive` policy choice

`.inactive` also fires for Control Center, notification banners, incoming call UI,
and the app switcher — transient system UI where the user is still "in" your app.

| Policy | Gate triggers on | Tradeoff |
|---|---|---|
| **Strict** | `.inactive` always | Safest; brief preview freeze on every notification banner |
| **Loose** | `.inactive` + verify `UIApplication.shared.applicationState != .active` | Keeps rendering through notifications; only gates for true backgrounding |

Pick based on product. A scientific/medical imaging app tolerates brief pauses; a
consumer camera app does not.

---

## ADR-10: Sendable strategy

**Rule: non-Sendable types never cross an actor boundary.** Enforce at compile time.
The Sendable warnings are real; silencing them with `@unchecked Sendable` is a
last resort.

### Not Sendable (keep inside the engine)

- `CVPixelBuffer`, `CVMetalTexture`, `CVMetalTextureCache`
- `MTLTexture`, `MTLCommandBuffer`, any Metal object
- `cv::Mat`, anything from OpenCV
- Raw pointers into IOSurfaces

### Sendable (safe to yield via `AsyncStream` or pass `@MainActor`)

- Plain structs of POD fields
- Enums with POD payloads
- Result types: detection boxes, tracking coords, edge coordinates, sensor-metadata
  snapshots
- `@Observable` classes (Swift 6 infers Sendable when all stored fields are Sendable)

### When a buffer *must* cross an isolation boundary

Use Swift 6's `sending` parameter annotation (SE-0430). It transfers ownership at
compile time without the runtime ambiguity of `@unchecked Sendable`:

```swift
func handoff(frame: sending IncomingFrame) async { ... }
```

`sending` is strictly stronger than `@unchecked Sendable`. Only fall back to
`@unchecked Sendable` when importing an Apple type that Apple has not yet marked
Sendable (e.g. `CVPixelBuffer` as of iOS 26) — and document the specific instance
and its thread-safety contract.

### Corollary: the frame clock never hops a Swift actor boundary

The 30Hz capture-delegate → Metal → completion-handler → consumer-publish path runs
entirely on the delivery `DispatchQueue`. No `await`, no cross-actor call. UI
updates from a frame are coalesced into a single `Task { @MainActor in ... }`
scheduled at the end of the delegate method, not one per state change.

If you find yourself needing an `await` on the frame path, you're about to introduce
hidden latency from suspension points. Prefer a nonisolated helper, or a C-ABI
callback that publishes to an `AsyncStream` without hopping actors.

---

## Three state machines that must agree

On backgrounding, three state machines interact. They must not conflict.

```
scenePhase → .inactive
  ├─ gpuSubmissionEnabled = false           (atomic; ADR-09)
  └─ lastCommittedCommandBuffer.waitUntilScheduled()

scenePhase → .background
  ├─ sessionQueue.async { session.stopRunning() }
  └─ do NOT release CVMetalTextureCache / MTLDevice — retain them

AVCaptureSession.wasInterrupted  (fires independently, around same time)
  └─ videoDeviceNotAvailableInBackground → no-op; system already handled it
```

**Do not call `stopRunning()` in response to a system-initiated interruption.** The
session is already in the interrupted state (`isInterrupted == true`); calling
`stopRunning()` yourself races the system and produces undefined
`isRunning`/`isInterrupted` state. See `04-avfoundation.md` for interruption
handling.

### Completion-handler re-entrancy guard

Between `commandBuffer.commit()` and `addCompletedHandler` firing, the engine actor
may have serviced other messages — `close()`, `backgroundSuspend()`,
`setResolution()` — any of which may have released GPU resources the handler is
about to touch.

**Required pattern:** capture `sessionState` at commit time. In the handler,
verify it hasn't changed before acting:

```swift
let frameSessionState = sessionState
commandBuffer.addCompletedHandler { [weak self] cb in
    if cb.status == .error, let err = cb.error {
        Task { await self?.handleMetalError(err) }
        return
    }
    Task { await self?.onFrameComplete(
        readIndex: readIndex,
        expectedState: frameSessionState
    )}
}

// Inside the actor:
func onFrameComplete(readIndex: Int, expectedState: SessionState) {
    guard sessionState == expectedState, sessionState == .streaming else {
        return  // drop silently; teardown ran between commit and completion
    }
    // ... safe to touch readback buffers, publish consumers, etc.
}
```

Without this guard, a `close()` racing with a completion handler produces
use-after-free crashes on readback buffers.

On foreground:

```
scenePhase → .active
  └─ gpuSubmissionEnabled = true

AVCaptureSession resumes
  (system via interruptionEnded, or manual via viewWillAppear)
  └─ first frame arrives; encode-and-commit resumes normally
```

---

## ADR-21: Approachable Concurrency — default MainActor isolation

Enable Xcode 26's **Approachable Concurrency** build setting (compiler flag
`-default-isolation MainActor`, SE-0466). With it on, every type in the module is
implicitly `@MainActor` unless explicitly opted out. This *reduces* annotation
noise and makes isolation intent legible at module scope — you no longer sprinkle
`@MainActor` across every view model, observable, and SwiftUI view.

### Concrete isolation topology for this app

| Type | Isolation | How |
|---|---|---|
| `CameraView`, `ViewModel`, any `@Observable` state type | `@MainActor` | Implicit (default) |
| `CameraEngine` | custom `actor` | Explicit `actor CameraEngine` — opts out of default |
| `CaptureDelegate` (sample-buffer callback) | `nonisolated` | Explicit `final class … : NSObject, @unchecked Sendable` + `nonisolated` methods; runs on the `delivery` `DispatchQueue` |
| Pure value types (`FrameSet`, `CaptureMetadata`, detection results) | `nonisolated` / `Sendable` | Value types with all `Sendable` fields |

Compiler-verified isolation replaces comment discipline. If a type lacks isolation
annotations, it is `@MainActor` — no ambiguity.

### Interaction with existing ADRs

- Does **not** relax ADR-07 (session queue). `AVCaptureSession` work still dispatches
  onto the dedicated serial queue. Default isolation concerns Swift actor boundaries,
  not `DispatchQueue` boundaries.
- Does **not** relax ADR-02 (single heavy isolation domain). The engine remains a
  custom actor; "default MainActor" only governs the UI side.
- Does **not** retroactively change ADR-10 (Sendable). `CVPixelBuffer`, `cv::Mat`,
  Metal objects remain non-Sendable and must stay inside the engine.

### `nonisolated(nonsending)` (SE-0461)

Nonisolated `async` functions no longer hop to the global concurrent executor by
default — they run on the caller's actor. Implication: calling a `nonisolated async`
helper from `@MainActor` code does **not** move work off main. To explicitly move
to a background executor, mark the function `@concurrent`.

```swift
@concurrent
nonisolated func compressJPEG(_ frame: sending CVPixelBuffer) async -> Data { ... }
```

This is the sharp edge: pre-Swift 6.2 code that relied on "nonisolated async ⇒
background" now runs on main. Audit any long-running `async` helper when enabling
Approachable Concurrency — add `@concurrent` where background execution was the
intent.

---

## ADR-22: AsyncStream buffering is explicit

Every `AsyncStream` in the pipeline declares its buffering policy at construction.
The default (unbounded) policy is forbidden — it hides backpressure and lets slow
consumers balloon memory until OOM.

### Two policies for two stream shapes

**Frame-rate streams — `.bufferingNewest(1)`.** Detection results, tracker signals,
any stream keyed to the 30 Hz frame clock. Drop-oldest under backpressure. A slow
consumer misses frames; it does not accumulate a backlog.

```swift
let (detections, cont) = AsyncStream.makeStream(
    of: Detection.self,
    bufferingPolicy: .bufferingNewest(1)
)
```

**State-change streams — `.bufferingOldest(64)`.** Device state transitions
(KVO adapter per ADR-14), session interruptions, configuration changes. These
are sparse, every event matters, and the consumer must not miss the transition.
Drop-newest under the (rare) overflow.

```swift
let (deviceState, cont) = AsyncStream.makeStream(
    of: DeviceState.self,
    bufferingPolicy: .bufferingOldest(64)
)
```

### Rule

Creating an `AsyncStream` without a buffering policy is a review-time failure. The
`.unbounded` policy is forbidden outright. If you can't classify your stream as
either frame-rate or state-change, you're designing the stream wrong.

### Interaction with ADRs 13/19

`.bufferingNewest(1)` is the Swift-level mailbox primitive. The C++ `PixelSink`
mailbox (ADR-13) is the analogue on the C++ side, with its own overwrite counters.
Both express the same invariant: **async consumers never block the frame path**.

---

## ADR-23: Task cancellation is enforced, not optional

Every `Task` that loops over an `AsyncStream`, `AsyncSequence`, or any long-running
work calls `try Task.checkCancellation()` per iteration. `Task.isCancelled` without
a corresponding `throw` is explicitly non-conformant — it produces a `Task` that
ignores cancellation.

```swift
// ✅ Correct
for await frame in frameStream {
    try Task.checkCancellation()
    process(frame)
}

// ❌ Silent cancellation leak
for await frame in frameStream {
    guard !Task.isCancelled else { return }  // no-op in practice — the loop
    process(frame)                           // never re-enters if upstream
}                                            // hasn't closed the stream
```

`Task.isCancelled` without `throw` is permitted only when the cancellation
semantics are checked *and* acted on before the next suspension point (rare —
typically only for cleanup in a `withTaskCancellationHandler`).

### Task ownership and cleanup

Every engine-owned `Task` is stored in the engine actor and cancelled in
`close()` / `deinit`. The pattern is non-optional — orphan tasks hold the actor
alive, keep `CVPixelBuffer` pools drained, and fire completion handlers after
teardown.

```swift
actor CameraEngine {
    private var kvoTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?

    func open() async {
        kvoTask = Task { [weak self] in
            for await state in await self?.deviceStateStream() ?? .finished {
                try? Task.checkCancellation()
                await self?.apply(state)
            }
        }
    }

    func close() {
        kvoTask?.cancel();     kvoTask = nil
        metricsTask?.cancel(); metricsTask = nil
        // ... stopRunning, release GPU resources, etc.
    }
}
```

Prefer `.task` over `onAppear { Task { … } }` in SwiftUI — `.task` auto-cancels on
view disappear. See ADR-28 in `08-ios26-and-ui.md`.
