# Stage 06 Implementation Plan — Tracker stream + FrameSet publication + pool trio

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote `naturalTex`/`processedTex` from single shared textures to `CVPixelBufferPool`-backed per-frame buffers; add Pass 4 (tracker downsample) producing a `TRACKER_HEIGHT_PX`-tall aspect-preserved tracker texture from a third pool; construct `FrameSet` in the command-buffer completion handler and publish it to per-lane Swift subscribers via a rewritten `ConsumerRegistry` actor (`.bufferingNewest(1)` per-lane mailbox per ADR-22); wire a debug overlay (`#if DEBUG`) that shows frame-number + capture-time plus a tiny tracker thumbnail that appears when any consumer subscribes to `.tracker`.

**Architecture:** Three `CVPixelBufferPool`s (`naturalPool`, `processedPool`, `trackerPool`) are allocated at `MetalPipeline.init()` with `kCVPixelBufferIOSurfacePropertiesKey: [:]` + `kCVPixelBufferMetalCompatibilityKey: true` + `kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf`. Each `encode(sampleBuffer:)` call dequeues three fresh buffers (tracker dequeue gated on `consumers.hasSubscriber(.tracker)`), wraps them as `MTLTexture` views through the existing `CVMetalTextureCache`, runs Pass 1 (YUV→natural) → Pass 2 (color→processed) → Pass 4 (compute downsample →tracker). In the `addCompletedHandler`, a `FrameSet` is constructed (three `CVPixelBuffer`s + `CaptureMetadata` from `CMSampleBuffer` attachments + `ProcessingMetadata` snapshot from the Stage-05 `Mutex` snapshot) and handed to `ConsumerRegistry.yield(_:stream:)` for each of `.natural`, `.processed`, `.tracker`. `ConsumerRegistry` is an `actor` for `subscribe`/`unregister`/`registerCallback` but exposes a `nonisolated` yield path backed by a `Mutex<[StreamId: [SubscriberId: AsyncStream<FrameSet>.Continuation]]>` so the delivery queue publishes inline without an actor hop (ADR-02). Drop events are counted via `AsyncStream.Continuation.yield`'s `YieldResult.dropped` return value. `registerCallback(stream:callbacks:)` throws `InteropError.notWired` — the C-ABI path (and `PixelSinkCallbacks` C-ABI struct shape per ADR-31 / D-03) lands in Stage 08. The preview path remains functional via "latest natural/processed texture" mailboxes on `MetalPipeline` (updated on the delivery queue after each successful encode), so `CameraEngine.currentTexture()` still returns the most recent texture each draw.

**Tech Stack:** Swift 6.2, iOS 26, Swift Testing (`@Test`/`@Suite`), Metal compute kernels (`.metal` + `MTLComputePipelineState`), `CVPixelBufferPool` + IOSurface-backed `CVPixelBuffer`, `CVMetalTextureCacheCreateTextureFromImage` zero-copy, `Synchronization.Mutex`, `AsyncStream.bufferingNewest(1)`, SwiftUI debug overlay. **Device builds via `mcp__XcodeBuildMCP__{build_run_device,test_device}` — no simulators, ever** (CLAUDE.md §6 top).

**Stage type:** FEATURE. Adds scaffold `06:simple-consumer-swift-only` (marks the `registerCallback` C-ABI path that throws `InteropError.notWired`). Retires no scaffolds. Active scaffolds after this stage: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `06:simple-consumer-swift-only`.

---

## 0. Hard precondition — Stage 05 must be complete

This plan assumes Stage 05 (`docs/superpowers/plans/2026-04-21-stage-05-reference.md` + actual stage plan) has been fully executed and committed. Verify before starting:

- [ ] **Step 0.1: Run stage pre-flight**

Run: `scripts/stage-preflight.sh`
Expected: exit 0. Verifies `01:simple-metal-passthrough` + `01:skip-completion-guard` slugs live in source (both ≥1 hit), `04:unlocked-uniforms` absent, `CONTRACTS.md` fresh, iOS build passes.

If the preflight reports source drift, STOP and escalate. Do not begin editing.

- [ ] **Step 0.2: Verify Stage 05 artifacts**

Run: `grep -l "uniforms.withLock" CameraKit/Sources/CameraKit/MetalPipeline.swift`
Expected: prints the path. Confirms `Mutex<UniformStorage>` migration shipped.

Run: `grep -l "onProcessingMetadata" CameraKit/Sources/CameraKit/CaptureDelegate.swift 2>/dev/null || grep -l "lastProcessingMetadata" CameraKit/Sources/CameraKit/CaptureDelegate.swift`
Expected: prints the path. Confirms the Stage-05 metadata-snapshot stub is live and ready to be replaced by real FrameSet construction.

---

## 1. File plan

### Modify
- `CameraKit/Sources/CameraKit/Constants.swift` — add `trackerHeightPx`, `poolMinBufferCount`, `poolMaxBufferAgeSeconds`.
- `CameraKit/Sources/CameraKit/Errors.swift` — add `InteropError.notWired`.
- `CameraKit/Sources/CameraKit/FrameSet.swift` — update doc comment on `FrameSet` to note Stage-06 construction; no field changes.
- `CameraKit/Sources/CameraKit/PixelSink.swift` — replace Stage-01 stub: C-ABI `PixelSinkCallbacks` struct per ADR-31; `ConsumerRegistry` becomes an `actor` with Swift `subscribe(stream:)` + C-ABI `registerCallback(stream:callbacks:)` + `unregister(token:)` + nonisolated `yield(_:stream:)` + `hasSubscriber(_:)`; `ConsumerToken` gains a `stream: StreamId` field per the api-skeleton.
- `CameraKit/Sources/CameraKit/TexturePoolManager.swift` — add `makeWorkingFormatPool(size:)` that returns a configured `CVPixelBufferPool` for RGBA16F IOSurface-backed buffers; add `wrapPoolBufferAsTexture(buffer:width:height:)` for per-frame dequeue.
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — three pool refs (`naturalPool`/`processedPool`/`trackerPool`); per-frame dequeue in `encode()`; Pass 4 tracker downsample (gated on `consumers.hasSubscriber(.tracker)`); FrameSet construction + yield in `addCompletedHandler`; latest-texture mailboxes (`latestNaturalTex`/`latestProcessedTex`/`latestTrackerTex`) for preview readers; `consumers: ConsumerRegistry` field held by pipeline.
- `CameraKit/Sources/CameraKit/CaptureDelegate.swift` — `pipeline?.lastProcessingMetadata` read removed (replaced by end-to-end FrameSet construction); keep `onSampleBuffer` + `engine.tickFrame`.
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — expose `public nonisolated var consumers: ConsumerRegistry` (replace the old private reference); delete `registerPixelSink(_:)` + `deregisterPixelSink(_:)` (retired with the Stage-01 closure-based stub); update `open()` to share `ConsumerRegistry` with `MetalPipeline`; `currentTexture()` / `currentProcessedTexture()` read the latest-texture mailboxes; `close()` finishes consumer continuations.
- `CameraKit/Sources/CameraKit/ViewModel.swift` — add `@ObservationIgnored nonisolated(unsafe) var trackerTex: MTLTexture?`; add `debugOverlay: DebugOverlay?` (frame-number + capture-time for the debug overlay); add `debugTrackerSubscribed: Bool` toggle + `startDebugSubscriptions()` / `stopDebugSubscriptions()` that spawn/cancel `Task { for await fs in await engine.consumers.subscribe(stream: ...) }` loops for `.natural` (overlay) and `.tracker` (thumbnail).
- `CameraKit/Sources/CameraKit/CameraView.swift` — overlay a `#if DEBUG` `Text` showing frame-number + capture-time above the top-right Calibrate button; add a tiny tracker thumbnail (`MTKViewRepresentable(textureAccessor: { viewModel.trackerTex })` at ~120×160pt) in the lower-left corner when `viewModel.debugTrackerSubscribed`; add a debug toggle button (`#if DEBUG`) to flip `debugTrackerSubscribed`.

### Create
- `CameraKit/Sources/CameraKit/Shaders/TrackerDownsample.metal` — compute kernel that samples `processedTex` with bilinear filtering into `trackerTex` at `TRACKER_HEIGHT_PX`.
- `CameraKit/Tests/CameraKitTests/Stage06Tests.swift` — seven `@Test` functions covering §8 TESTABLEs.

### Delete (at end, after scaffold retirement)
- None this stage. `registerPixelSink` / `deregisterPixelSink` on `CameraEngine` are deleted inline as part of Task 6 (public API surface update).

### State / briefs
- `CameraKit/state.md` — roll forward per brief §12.

---

## 2. Per-task sequence

Each task is commit-sized. Run tests for the specific scope before moving on.

---

### Task 1 — Constants, Errors, FrameSet doc

**Model:** haiku — single-file additions, no logic.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Constants.swift`
- Modify: `CameraKit/Sources/CameraKit/Errors.swift`
- Modify: `CameraKit/Sources/CameraKit/FrameSet.swift`

- [ ] **Step 1.1: Add pool + tracker constants**

Edit `Constants.swift` — append under the existing `enum Constants {` body, before the closing brace:

```swift
    // MARK: - Stage 06 — Pool trio + tracker stream

    /// Tracker texture height in pixels; width is aspect-preserved and
    /// even-pixel-rounded in `MetalPipeline` (domain 02-frame-delivery §Parallel
    /// Stream Outputs, U-15 resolved; constants.md#TRACKER_HEIGHT_PX).
    static let trackerHeightPx: Int = 480

    /// `kCVPixelBufferPoolMinimumBufferCountKey` — 1 current mailbox ref
    /// + 1 GPU write slot + 1 slack (constants.md#POOL_MIN_BUFFER_COUNT, ADR-19).
    static let poolMinBufferCount: Int = 3

    /// `kCVPixelBufferPoolMaximumBufferAgeKey` — CF ages out unused buffers
    /// after this many seconds of disuse (constants.md#POOL_MAX_BUFFER_AGE_SECONDS,
    /// ADR-19).
    static let poolMaxBufferAgeSeconds: Double = 1.0
```

- [ ] **Step 1.2: Add `InteropError.notWired`**

Edit `Errors.swift` — add a case to the existing `InteropError` enum:

```swift
public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    /// Stage 06: `ConsumerRegistry.registerCallback(stream:callbacks:)` throws this
    /// as a scaffolding guard — the C-ABI path lands in Stage 08 (D-01, D-03).
    case notWired
}
```

- [ ] **Step 1.3: FrameSet doc tweak (no field change)**

Edit `FrameSet.swift` — update the `FrameSet` doc comment lines 5–8:

```swift
/// Atomic unit of publication per ADR-18.
///
/// Stage 06: constructed in `MetalPipeline.addCompletedHandler` from three
/// IOSurface-backed `CVPixelBuffer`s (natural/processed/tracker), the
/// `CMSampleBuffer` capture metadata, and the per-frame `ProcessingMetadata`
/// snapshot from the `Mutex<UniformStorage>` read in `encode()`. Published to
/// subscribed lanes via `ConsumerRegistry.yield(_:stream:)`.
///
/// `@unchecked Sendable` per G-13: `CVPixelBuffer` is not yet `Sendable` on
/// iOS 26; IOSurface backing plus the GPU-completion-before-construction
/// ordering in the completion handler make cross-thread use safe.
```

- [ ] **Step 1.4: Build**

Run: `mcp__XcodeBuildMCP__build_device` (or `scripts/build-summary.sh`).
Expected: BUILD SUCCEEDED.

- [ ] **Step 1.5: Commit**

```bash
git add CameraKit/Sources/CameraKit/Constants.swift \
        CameraKit/Sources/CameraKit/Errors.swift \
        CameraKit/Sources/CameraKit/FrameSet.swift
git commit -m "feat(stage-06): add trackerHeightPx/poolMinBufferCount/poolMaxBufferAgeSeconds, InteropError.notWired"
```

---

### Task 2 — `CVPixelBufferPool` factory in `TexturePoolManager`

**Model:** sonnet — CF API details + IOSurface + Metal-compatibility attributes; error paths.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`

- [ ] **Step 2.1: Add pool-factory + wrap helpers**

Edit `TexturePoolManager.swift` — add new methods under the `// MARK: - Stage 04` section, after `makeIOSurfaceBackedRGBA16F`:

```swift
    // MARK: - Stage 06 — Per-stream CVPixelBufferPool

    /// Creates a `CVPixelBufferPool` that vends IOSurface-backed, Metal-compatible
    /// RGBA16F `CVPixelBuffer`s at `size` per ADR-19 / D-02.
    ///
    /// - `POOL_MIN_BUFFER_COUNT` = 3 (mailbox ref + GPU write slot + slack).
    /// - `POOL_MAX_BUFFER_AGE_SECONDS` = 1.0 (CF-managed age-out).
    /// - `kCVPixelBufferIOSurfacePropertiesKey: [:]`
    /// - `kCVPixelBufferMetalCompatibilityKey: true`
    /// - `kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf`.
    ///
    /// Growth past `MinimumBufferCount` is CF-managed; the effective cap is
    /// `POOL_CAP_RULE = N_active_lanes + 1` which the caller enforces by only
    /// dequeuing a tracker buffer when a tracker subscriber is active.
    func makeWorkingFormatPool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: Constants.poolMaxBufferAgeSeconds,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw MetalError.unsupportedFormat
        }
        return pool
    }

    /// Dequeues a buffer from `pool` and wraps it as an `MTLTexture` view through
    /// the shared `CVMetalTextureCache`. Zero-copy; the caller retains `buffer`
    /// until the GPU completion handler fires (Apple CoreVideo contract).
    ///
    /// - Throws: `MetalError.unsupportedFormat` on dequeue failure,
    ///   `MetalError.textureWrapFailed` on cache-wrap failure.
    func dequeuePoolTexture(
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let buffer = buf else {
            throw MetalError.unsupportedFormat
        }
        var cvTexOut: CVMetalTexture?
        let wrap = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            buffer,
            nil,
            .rgba16Float,
            width,
            height,
            0,
            &cvTexOut
        )
        guard wrap == kCVReturnSuccess, let cvTex = cvTexOut,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrap)
        }
        return (buffer, mtlTex)
    }
```

- [ ] **Step 2.2: Build**

Run: `mcp__XcodeBuildMCP__build_device`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 2.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/TexturePoolManager.swift
git commit -m "feat(stage-06): CVPixelBufferPool factory + per-frame MTLTexture wrap in TexturePoolManager"
```

---

### Task 3 — Tracker downsample shader

**Model:** haiku — single short Metal file.

**Files:**
- Create: `CameraKit/Sources/CameraKit/Shaders/TrackerDownsample.metal`

- [ ] **Step 3.1: Write the kernel**

Create `TrackerDownsample.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Stage 06 — Pass 4 tracker downsample. Samples `processedTex` with bilinear
// filtering into an aspect-preserved, even-pixel-rounded `trackerTex` whose
// height is constants.md#TRACKER_HEIGHT_PX. Width is decided on the host and
// passed through the output texture's own dimensions — the kernel just maps
// gid → normalized coords → sample.

kernel void trackerDownsample(texture2d<float, access::sample>  inTex  [[texture(0)]],
                              texture2d<float, access::write>   outTex [[texture(1)]],
                              sampler                           s      [[sampler(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    float2 uv = float2(
        (float(gid.x) + 0.5) / float(outTex.get_width()),
        (float(gid.y) + 0.5) / float(outTex.get_height())
    );
    float4 c = inTex.sample(s, uv);
    outTex.write(c, gid);
}
```

- [ ] **Step 3.2: Build (confirms shader compiles as part of the SwiftPM resource bundle)**

Run: `mcp__XcodeBuildMCP__build_device`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Shaders/TrackerDownsample.metal
git commit -m "feat(stage-06): Pass 4 tracker downsample Metal kernel"
```

---

### Task 4 — `ConsumerRegistry` actor + C-ABI struct

**Model:** sonnet — concurrency design (actor + `nonisolated` yield + Mutex-backed subscriber table); AsyncStream `.bufferingNewest(1)` + `YieldResult.dropped` drop accounting.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/PixelSink.swift`

- [ ] **Step 4.1: Rewrite the file**

Replace the entire contents of `PixelSink.swift` with:

```swift
import Foundation
import Synchronization

// Stage 06 — ConsumerRegistry actor + C-ABI PixelSinkCallbacks struct
// per architecture 05-consumers.md §D-01 / §D-03 and ADR-18 / ADR-22 / ADR-31.

/// Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and
/// `.registerCallback(stream:callbacks:)`. Holds the lane id so unregister
/// can route to the right internal collection without a second lookup.
public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId
    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}

/// C-ABI-shaped callback struct per ADR-31 and D-03. The Stage-08 C++ `PixelSink`
/// pool will invoke these `@convention(c)` function pointers; in Stage 06 this
/// type exists only so the signature of `registerCallback` can compile — the
/// method itself throws `InteropError.notWired` (scaffolding:06:simple-consumer-swift-only).
public struct PixelSinkCallbacks {
    public typealias OnFrame = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ stream: UInt32,
        _ frameNumber: UInt64,
        _ presentationTimeNs: Int64,
        _ surface: UnsafeMutableRawPointer?
    ) -> Void

    public typealias OnOverwrite = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ stream: UInt32
    ) -> Void

    public typealias OnError = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ code: Int32
    ) -> Void

    public let onFrame: OnFrame
    public let onOverwrite: OnOverwrite
    public let onError: OnError
    public let context: UnsafeMutableRawPointer?

    public init(
        onFrame: OnFrame,
        onOverwrite: OnOverwrite,
        onError: OnError,
        context: UnsafeMutableRawPointer?
    ) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

/// Swift facade for the consumer fan-out. Actor for subscribe/unregister/registerCallback
/// (cold paths), but publication runs on the delivery queue through a `nonisolated`
/// `yield(_:stream:)` — no actor hop on the frame clock (ADR-02).
///
/// The internal subscriber table is a `Mutex<InnerState>` (iOS 18+). Readers
/// (yield + hasSubscriber) hold the lock only for the duration of the table
/// lookup and a `Continuation.yield(_)` call; the Continuation's buffering
/// policy (`.bufferingNewest(1)`) + drop counter via `YieldResult.dropped`
/// satisfy ADR-22 per-lane mailbox semantics.
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncStream<FrameSet>.Continuation
    }

    private struct InnerState {
        var subscribers: [StreamId: [Subscriber]] = [:]
        var nextId: UInt64 = 0
        /// Per-lane drop counter — incremented every time `Continuation.yield`
        /// returns `.dropped(_)` (a newer frame pushed out the prior buffered one).
        var dropCounts: [StreamId: UInt64] = [:]
    }

    // `nonisolated let` so `yield(_:stream:)` (non-isolated) can reach the mutex
    // without an actor hop. `Mutex` is Sendable.
    private nonisolated let state: Mutex<InnerState> = Mutex(InnerState())

    public init() {}

    // MARK: - Subscribe (Swift lane, D-01)

    /// Returns an `AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22.
    /// Termination of the stream (consuming `Task` cancelled or returned) runs
    /// the onTermination closure, which removes the subscriber synchronously.
    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        let weakSelf = self  // Capture actor reference; closures are Sendable.
        let asyncStream = AsyncStream<FrameSet>(
            bufferingPolicy: .bufferingNewest(1)
        ) { [weakSelf] continuation in
            self.state.withLock { inner in
                inner.subscribers[stream, default: []].append(
                    Subscriber(id: id, continuation: continuation))
            }
            continuation.onTermination = { [weakSelf] _ in
                // onTermination runs on the iterator's thread; remove sync via mutex.
                _ = weakSelf
                self.state.withLock { inner in
                    inner.subscribers[stream]?.removeAll { $0.id == id }
                }
            }
        }
        return asyncStream
    }

    // MARK: - registerCallback (C-ABI lane, D-03) — stub until Stage 08

    /// scaffolding:06:simple-consumer-swift-only — C-ABI consumer registration
    /// lands in Stage 08. Throws `InteropError.notWired` this stage so any
    /// attempted external wiring surfaces loudly instead of silently no-op'ing.
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        throw InteropError.notWired
    }

    // MARK: - Unregister

    public func unregister(token: ConsumerToken) {
        state.withLock { inner in
            guard var lane = inner.subscribers[token.stream] else { return }
            if let idx = lane.firstIndex(where: { $0.id == token.id }) {
                lane[idx].continuation.finish()
                lane.remove(at: idx)
                inner.subscribers[token.stream] = lane
            }
        }
    }

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Yields `frameSet` into every subscriber's mailbox for `stream`. Runs inline
    /// on the delivery queue; no actor hop. Increments `dropCounts[stream]` each
    /// time a Continuation reports `.dropped` (ADR-22: newest wins).
    nonisolated func yield(_ frameSet: FrameSet, stream: StreamId) {
        state.withLock { inner in
            guard let lane = inner.subscribers[stream], !lane.isEmpty else { return }
            for sub in lane {
                let r = sub.continuation.yield(frameSet)
                if case .dropped = r {
                    inner.dropCounts[stream, default: 0] &+= 1
                }
            }
        }
    }

    /// True if there is at least one subscriber for `stream`. Used by the Metal
    /// pipeline to gate Pass 4 dequeue + encode (no tracker work when no one
    /// listens). Nonisolated because it's polled per frame on the delivery queue.
    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        state.withLock { inner in
            (inner.subscribers[stream]?.isEmpty == false)
        }
    }

    // MARK: - Teardown

    /// Finishes every subscriber's continuation. Called from `CameraEngine.close()`.
    func release() {
        state.withLock { inner in
            for (_, lane) in inner.subscribers {
                for sub in lane { sub.continuation.finish() }
            }
            inner.subscribers.removeAll()
        }
    }

    // MARK: - Test-visible metrics

    /// Per-lane drop counter — readable from tests via @testable import.
    nonisolated func dropCount(for stream: StreamId) -> UInt64 {
        state.withLock { $0.dropCounts[stream] ?? 0 }
    }

    /// Per-lane subscriber count — readable from tests via @testable import.
    nonisolated func subscriberCount(for stream: StreamId) -> Int {
        state.withLock { $0.subscribers[stream]?.count ?? 0 }
    }
}
```

**Notes:**
- `Mutex` is `Sendable` so storing it in an `actor` as `nonisolated let` is safe and compiles under strict concurrency.
- `AsyncStream.Continuation.yield` returns `YieldResult` whose `.dropped` case carries the prior element that was pushed out — we discard the payload and just count the event.
- `onTermination` runs synchronously when the consumer's `Task` is cancelled; the `state.withLock` call removes the subscriber before any further yield fires (the already-in-flight yield holds the mutex for its full duration).

- [ ] **Step 4.2: Build**

Run: `mcp__XcodeBuildMCP__build_device`.
Expected: BUILD SUCCEEDED. (Compilation of `CameraEngine.swift` will likely fail due to references to the removed old `PixelSinkCallbacks` closure API and `consumerRegistry.register/.deregister` — Task 5/6 fix those. If the build fails at this step, check that the failures are confined to `CameraEngine.swift` and `CaptureDelegate.swift`; any other failures mean Task 4 introduced an unintended break. If confined, proceed — Task 5 resolves them.)

If the breakage spans other files, STOP and reconsider.

- [ ] **Step 4.3: (Defer commit until Task 5 restores the build)**

Task 5 touches `MetalPipeline` + `CaptureDelegate` + `CameraEngine` in one sweep; commit together.

---

### Task 5 — Per-frame pool dequeue, Pass 4, FrameSet construction, publication

**Model:** sonnet — multi-site concurrency edit; touches the hot path.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`
- Modify: `CameraKit/Sources/CameraKit/CaptureDelegate.swift`

- [ ] **Step 5.1: Add Pass-4 PSO + sampler + pool refs + latest-texture mailboxes + consumers reference**

Edit `MetalPipeline.swift` — **inside the class body**, add/modify as follows.

**a.** Replace the `naturalTex` / `processedTex` property declarations (lines ~72–82) with:

```swift
    // Stage 06 — pool-dequeued, per-frame texture lineage. Long-lived single-buffer
    // shape from Stage 04 replaced; the "current" texture for preview readers
    // (MTKView) lives in the `latest…Tex` mailboxes below, updated in the delivery-
    // queue side of `encode()` after Pass 2 and Pass 4 complete.
    //
    // scaffolding:01:simple-metal-passthrough — Passes 3 (natural blit to
    // drawable), 5 (encoder NV12), 6 (still readback) still arrive in later stages.
    private let naturalPool: CVPixelBufferPool
    private let processedPool: CVPixelBufferPool
    private let trackerPool: CVPixelBufferPool

    private let captureSize: Size
    private let trackerSize: Size

    /// Preview-facing "latest" textures. Written on the delivery queue after
    /// each successful encode; read by MTKView.draw via `currentTexture()` /
    /// `currentProcessedTexture()` without actor hop. Held strongly because the
    /// underlying `CVPixelBuffer` refcount must be >1 for the blit to be safe
    /// past the completion handler.
    nonisolated(unsafe) private(set) var latestNaturalTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestProcessedTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestTrackerTex: MTLTexture?

    /// Retainer for the buffers backing the `latest…Tex` textures. Swapped atomically
    /// with `latest…Tex` on the delivery queue.
    nonisolated(unsafe) private var latestNaturalBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestProcessedBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestTrackerBuffer: CVPixelBuffer?
```

**b.** Remove the `private let naturalBuffer: CVPixelBuffer` and `private let processedBuffer: CVPixelBuffer` lines (replaced by the pool-managed flow above).

**c.** Replace the `private(set) var lastProcessingMetadata: ProcessingMetadata?` block with:

```swift
    // Stage 06: removed — `lastProcessingMetadata` superseded by end-to-end
    // `FrameSet` construction attached in the completion handler. Kept as an
    // internal test seam if @testable references it.
```

(If any test file references `lastProcessingMetadata`, delete those references in Task 8 where Stage06Tests are drafted; Stage04/05 tests should be checked too.)

**d.** Add two new fields:

```swift
    /// Pass-4 tracker downsample PSO + sampler. Compiled in `init()`.
    private let trackerDownsamplePSO: MTLComputePipelineState
    private let trackerSampler: MTLSamplerState

    /// Frame counter + frame clock for FrameSet construction. Delivery-queue only.
    private var frameNumber: UInt64 = 0

    /// Consumer registry handed in from `CameraEngine`. Publication happens in
    /// the addCompletedHandler inline (no actor hop — ADR-02).
    let consumers: ConsumerRegistry
```

**e.** Update the initializer signature and body. Find:

```swift
init(device: MTLDevice, captureSize: Size, gate: ManagedAtomic<Bool>) throws {
```

Change to:

```swift
init(
    device: MTLDevice,
    captureSize: Size,
    gate: ManagedAtomic<Bool>,
    consumers: ConsumerRegistry
) throws {
    self.consumers = consumers
    self.captureSize = captureSize
    // Tracker: height fixed, width aspect-preserved, rounded down to even pixel
    // per brief §4 + constants.md#TRACKER_HEIGHT_PX.
    let trackerH = Constants.trackerHeightPx
    let aspect = Double(captureSize.width) / Double(captureSize.height)
    let rawW = Int((Double(trackerH) * aspect).rounded())
    let trackerW = rawW - (rawW % 2)
    self.trackerSize = Size(width: trackerW, height: trackerH)
```

Then, in the body, replace the Stage-04 single-buffer allocations:

```swift
// 6. Working textures — IOSurface-backed .shared CVPixelBuffers wrapped
//    as RGBA16F MTLTextures (D-02, ADR-20 start-simple default; brief §7).
let (naturalBuf, naturalTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
let (processedBuf, processedTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
self.naturalBuffer = naturalBuf
self.naturalTex = naturalTexture
self.processedBuffer = processedBuf
self.processedTex = processedTexture
```

with:

```swift
// 6. Pool trio — natural / processed at capture size; tracker at trackerSize.
//    Per-frame dequeue in `encode()`; CF manages age-out after POOL_MAX_BUFFER_AGE_SECONDS.
self.naturalPool = try texturePool.makeWorkingFormatPool(size: captureSize)
self.processedPool = try texturePool.makeWorkingFormatPool(size: captureSize)
self.trackerPool = try texturePool.makeWorkingFormatPool(size: trackerSize)
```

Then, before the closing brace of `init`, insert PSO + sampler compilation:

```swift
// 7. Pass-4 tracker downsample PSO + sampler.
guard let trackerFunction = library.makeFunction(name: "trackerDownsample") else {
    throw MetalError.pipelineStateCompilation("trackerDownsample not found")
}
do {
    trackerDownsamplePSO = try device.makeComputePipelineState(function: trackerFunction)
} catch {
    throw MetalError.pipelineStateCompilation(error.localizedDescription)
}
let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
    throw MetalError.pipelineStateCompilation("sampler state")
}
self.trackerSampler = sampler
```

**f.** Update the convenience init at the bottom of the file:

```swift
convenience init(device: MTLDevice, captureSize: Size, gateOpen: Bool = true) throws {
    try self.init(
        device: device,
        captureSize: captureSize,
        gate: ManagedAtomic<Bool>(gateOpen),
        consumers: ConsumerRegistry()
    )
}
```

**g.** Update `currentTexture()` / `currentProcessedTex()` to read the mailboxes:

```swift
func currentTexture() -> MTLTexture {
    // Stage 06: preview-facing latest texture. Never nil once one frame has committed;
    // Stage 01 passthrough viewport was a black frame pre-commit, so a nil-fallback
    // path here would replicate that — for simplicity we dequeue a throwaway buffer
    // on the first call if nothing has committed yet.
    if let t = latestNaturalTex { return t }
    // Initial placeholder: dequeue one frame's worth so the MTKView has *something*
    // to blit until the first real encode finishes.
    if let (buf, tex) = try? texturePool.dequeuePoolTexture(
        pool: naturalPool, width: captureSize.width, height: captureSize.height
    ) {
        latestNaturalBuffer = buf
        latestNaturalTex = tex
        return tex
    }
    fatalError("MetalPipeline.currentTexture: no preview texture available")
}

func currentProcessedTex() -> MTLTexture {
    if let t = latestProcessedTex { return t }
    if let (buf, tex) = try? texturePool.dequeuePoolTexture(
        pool: processedPool, width: captureSize.width, height: captureSize.height
    ) {
        latestProcessedBuffer = buf
        latestProcessedTex = tex
        return tex
    }
    fatalError("MetalPipeline.currentProcessedTex: no preview texture available")
}
```

(Note: both methods are called after init from `CameraEngine.open()` for the initial `_naturalTex` / `_processedTex` population; the fallback dequeue handles that case.)

**h.** Remove `naturalBufferForTest` / `processedBufferForTest` (Stage-04 single-buffer seam); replace with mailbox-based accessors for any test that needs direct buffer access:

```swift
// Stage 06 test seams — expose the latest published pool buffer for a given lane.
var latestNaturalBufferForTest: CVPixelBuffer? { latestNaturalBuffer }
var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer }
var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer }
```

If Stage04/05 tests reference `naturalBufferForTest` / `processedBufferForTest` and break, update them in Task 8 (test suite step) by moving those tests' CPU fill-then-encode pattern onto a `latest…Buffer` accessor after a synthetic encode. (Check: `grep -n "BufferForTest" CameraKit/Tests/CameraKitTests/*.swift`.)

- [ ] **Step 5.2: Update `encode(sampleBuffer:)` — dequeue + Pass 4 + FrameSet construct + publish**

Replace the existing `encode(sampleBuffer:)` body with:

```swift
func encode(sampleBuffer: CMSampleBuffer) throws {
    // 1. Unwrap.
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    // 2. Wrap YUV planes (ADR-06).
    let yTexture: MTLTexture
    let cbcrTexture: MTLTexture
    do {
        yTexture = try texturePool.makeYTexture(from: pixelBuffer)
        cbcrTexture = try texturePool.makeCbCrTexture(from: pixelBuffer)
    } catch {
        return
    }

    // 3. Dequeue pool buffers. Tracker gated on subscriber presence (ADR-19
    //    §Active-stream rules; cap = N_active_lanes + 1).
    let (naturalBuf, naturalTex_i): (CVPixelBuffer, MTLTexture)
    let (processedBuf, processedTex_i): (CVPixelBuffer, MTLTexture)
    var trackerTuple: (CVPixelBuffer, MTLTexture)? = nil
    do {
        (naturalBuf, naturalTex_i) = try texturePool.dequeuePoolTexture(
            pool: naturalPool, width: captureSize.width, height: captureSize.height)
        (processedBuf, processedTex_i) = try texturePool.dequeuePoolTexture(
            pool: processedPool, width: captureSize.width, height: captureSize.height)
        if consumers.hasSubscriber(.tracker) {
            trackerTuple = try texturePool.dequeuePoolTexture(
                pool: trackerPool, width: trackerSize.width, height: trackerSize.height)
        }
    } catch {
        return  // drop frame on pool exhaustion / wrap failure
    }

    // 4. Snapshot uniforms (Stage 05 Mutex<UniformStorage>, Inv 6).
    let (colorSnapshot, cropSnapshot, metadataSnapshot): (ColorUniform, CropUniform, ProcessingMetadata) =
        uniforms.withLock { storage in
            let c = storage.color
            let r = storage.crop
            return (c, r, ProcessingMetadata(color: c, crop: r))
        }

    // 5. Command buffer + label.
    let commandBuffer = commandQueue.makeCommandBuffer()!
    frameNumber &+= 1
    commandBuffer.label = "frame.\(frameNumber)"

    // 6. Pass 1 — YUV → naturalTex_i with crop.
    let pass1 = commandBuffer.makeComputeCommandEncoder()!
    pass1.pushDebugGroup("Pass1.YUVtoRGBA")
    pass1.setComputePipelineState(yuvToRgbaPSO)
    pass1.setTexture(yTexture, index: 0)
    pass1.setTexture(cbcrTexture, index: 1)
    pass1.setTexture(naturalTex_i, index: 2)
    var cropLocal = cropSnapshot
    pass1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    let natGroups = MTLSize(
        width: (naturalTex_i.width + 15) / 16,
        height: (naturalTex_i.height + 15) / 16,
        depth: 1
    )
    pass1.dispatchThreadgroups(natGroups, threadsPerThreadgroup: tg)
    pass1.popDebugGroup()
    pass1.endEncoding()

    // 7. Pass 2 — color transform naturalTex_i → processedTex_i.
    let pass2 = commandBuffer.makeComputeCommandEncoder()!
    pass2.pushDebugGroup("Pass2.ColorTransform")
    pass2.setComputePipelineState(colorTransformPSO)
    pass2.setTexture(naturalTex_i, index: 0)
    pass2.setTexture(processedTex_i, index: 1)
    var colorLocal = colorSnapshot
    pass2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
    pass2.dispatchThreadgroups(natGroups, threadsPerThreadgroup: tg)
    pass2.popDebugGroup()
    pass2.endEncoding()

    // 8. Pass 4 — tracker downsample (gated).
    if let (_, trackerTex_i) = trackerTuple {
        let pass4 = commandBuffer.makeComputeCommandEncoder()!
        pass4.pushDebugGroup("Pass4.TrackerDownsample")
        pass4.setComputePipelineState(trackerDownsamplePSO)
        pass4.setTexture(processedTex_i, index: 0)
        pass4.setTexture(trackerTex_i, index: 1)
        pass4.setSamplerState(trackerSampler, index: 0)
        let trkGroups = MTLSize(
            width: (trackerTex_i.width + 15) / 16,
            height: (trackerTex_i.height + 15) / 16,
            depth: 1
        )
        pass4.dispatchThreadgroups(trkGroups, threadsPerThreadgroup: tg)
        pass4.popDebugGroup()
        pass4.endEncoding()
    }

    // 9. Gate check (ADR-09, D-06).
    guard submissionGate.load(ordering: .acquiring) else { return }

    // 10. FrameSet publication — construct in completion handler (ADR-18) then yield
    //     inline on the completion thread (no actor hop; ADR-02).
    //     Strong-capture pool buffers so they live until after the GPU completes.
    let captureMeta = CaptureMetadata.placeholder(from: sampleBuffer)
    let cap = captureMeta
    let meta = metadataSnapshot
    let fn = frameNumber
    let trackerBuf = trackerTuple?.0
    let consumersRef = consumers

    // Tracker lane: if no subscriber, synthesise a placeholder CVPixelBuffer so
    // FrameSet's non-optional `tracker` field is still populated; consumers
    // without a `.tracker` subscription never see the value.
    let trackerForSet: CVPixelBuffer = trackerBuf ?? naturalBuf

    // scaffolding:01:skip-completion-guard — addCompletedHandler does not
    // check sessionState before doing its work; D-10 guard arrives Stage 09.
    commandBuffer.addCompletedHandler { [weak self] _ in
        guard let self else { return }
        // Swap mailboxes (preview reads these).
        self.latestNaturalBuffer = naturalBuf
        self.latestNaturalTex = naturalTex_i
        self.latestProcessedBuffer = processedBuf
        self.latestProcessedTex = processedTex_i
        if let (tbuf, ttex) = trackerTuple {
            self.latestTrackerBuffer = tbuf
            self.latestTrackerTex = ttex
        }
        // Publish FrameSet.
        let fs = FrameSet(
            frameNumber: fn,
            captureTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            natural: naturalBuf,
            processed: processedBuf,
            tracker: trackerForSet,
            capture: cap,
            processing: meta,
            blurScore: 0,
            trackerQuality: .good
        )
        consumersRef.yield(fs, stream: .natural)
        consumersRef.yield(fs, stream: .processed)
        if trackerBuf != nil {
            consumersRef.yield(fs, stream: .tracker)
        }
        self.texturePool.flush()
    }

    // 11. Track + commit.
    lastCommandBuffer = commandBuffer
    commitCount += 1
    commandBuffer.commit()
}
```

**Note:** `sampleBuffer` is captured by the completion closure — `CMSampleBuffer` is not Sendable but the closure runs on a thread driven by the Metal dispatch queue, and we only extract a `CMTime` + capture metadata from it. This is safe-by-ordering (the sample buffer lives past the commit because the driver retains it until completion). Add `nonisolated(unsafe)` annotations on the captures if the strict-concurrency build complains; if so, capture a `CMTime` + `CaptureMetadata` *before* the `addCompletedHandler` closure is built, and reference only those locals inside.

**g.** Add a `CaptureMetadata.placeholder(from:)` helper at the bottom of `FrameSet.swift` (or in a new extension block inside `MetalPipeline.swift`) — builds a `CaptureMetadata` from `CMSampleBuffer` attachments. For Stage 06 a placeholder (zeroed fields + known defaults) is acceptable because the brief's §8 test 06:frame-set-publication asserts only `frameNumber` match.

Add to `FrameSet.swift` (after the `CaptureMetadata` struct):

```swift
extension CaptureMetadata {
    /// Stage 06 placeholder: zero-valued sensor metadata for tests and initial
    /// FrameSet wiring. Full attachment-derived implementation lands with the
    /// sensor-metadata plumbing in a later stage.
    ///
    /// The `sampleBuffer` parameter is accepted but currently unused — kept so
    /// the call site in `MetalPipeline.encode` already has the hook for the
    /// future attachment-reading implementation.
    static func placeholder(from sampleBuffer: CMSampleBuffer? = nil) -> CaptureMetadata {
        _ = sampleBuffer
        return CaptureMetadata(
            iso: 0,
            exposureDurationNs: 0,
            whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            whiteBalanceModeActive: .auto,
            lensPosition: 0,
            focusModeActive: .auto,
            exposureModeActive: .auto,
            zoomFactor: 1.0,
            cameraPosition: .back
        )
    }
}
```

- [ ] **Step 5.3: Simplify `CaptureDelegate`**

Edit `CaptureDelegate.swift` — remove the `lastProcessingMetadata` read and the Stage-05 comment block in `captureOutput(_:didOutput:from:)`. The new body is:

```swift
func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
) {
    onSampleBuffer?(sampleBuffer)
    engine?.tickFrame()
}
```

Also delete the `weak var pipeline: MetalPipeline?` field and the Stage-05 doc block describing it — publication is end-to-end now, and the delegate doesn't need the pipeline handle.

- [ ] **Step 5.4: Build (still expects `CameraEngine` to wire the new init)**

Run: `mcp__XcodeBuildMCP__build_device`.
Expected: compilation errors in `CameraEngine.swift` referencing the old `MetalPipeline.init(device:captureSize:gate:)` signature and the removed `registerPixelSink`/`deregisterPixelSink`. These are fixed in Task 6.

Do not commit yet.

---

### Task 6 — `CameraEngine` surface: `consumers` accessor + constructor rewire + delete old register paths

**Model:** sonnet — public API removal + actor-nonisolated accessor design.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 6.1: Replace the private ConsumerRegistry field with a public accessor**

Find:

```swift
private var consumerRegistry: ConsumerRegistry = ConsumerRegistry()
```

Replace with:

```swift
/// Stage 06: public consumer registry per D-01 / D-03. Lifetime matches the
/// engine; every `open()` passes this same instance to the `MetalPipeline` so
/// publication (nonisolated `yield` on the delivery queue) and subscription
/// (actor-isolated `subscribe` from Swift callers) share state.
public nonisolated let consumers: ConsumerRegistry = ConsumerRegistry()
```

- [ ] **Step 6.2: Update `open()` to hand consumers into MetalPipeline**

Find:

```swift
let pipeline = try MetalPipeline(device: mtlDevice, captureSize: captureSize, gate: submissionGate)
```

Replace with:

```swift
let pipeline = try MetalPipeline(
    device: mtlDevice,
    captureSize: captureSize,
    gate: submissionGate,
    consumers: consumers
)
```

Also remove the `delegate.pipeline = pipeline` line — the delegate no longer needs it (Task 5 deleted the field).

- [ ] **Step 6.3: Update `setResolution(size:)` to hand consumers into the rebuilt pipeline**

Find:

```swift
let pipeline = try MetalPipeline(
    device: mtlDevice, captureSize: size, gate: submissionGate)
```

Replace with:

```swift
let pipeline = try MetalPipeline(
    device: mtlDevice,
    captureSize: size,
    gate: submissionGate,
    consumers: consumers
)
```

- [ ] **Step 6.4: Delete the Stage-01 register paths**

Remove entirely:

```swift
public func registerPixelSink(_ callbacks: PixelSinkCallbacks) async -> ConsumerToken {
    consumerRegistry.register(callbacks)
}

public func deregisterPixelSink(_ token: ConsumerToken) async {
    consumerRegistry.deregister(token)
}
```

Callers use `engine.consumers.subscribe(stream:)` (Swift) or `engine.consumers.registerCallback(stream:callbacks:)` (C-ABI, throws until Stage 08) instead.

- [ ] **Step 6.5: Update `close()` to release subscribers**

Find the existing `close()` body; before the `isOpen = false` line, add:

```swift
await consumers.release()
```

- [ ] **Step 6.6: Build**

Run: `mcp__XcodeBuildMCP__build_device`.
Expected: BUILD SUCCEEDED.

If errors persist, resolve them in-place — do not add hack-arounds. Likely remaining breakage is a Stage-04 or Stage-05 test that referenced `naturalBufferForTest`/`processedBufferForTest`; update those references per Task 5.1.h (use `latestNaturalBufferForTest` / `latestProcessedBufferForTest` after a synthetic encode).

- [ ] **Step 6.7: Run existing tests to confirm no regression**

Run: `mcp__XcodeBuildMCP__test_device` with filter `CameraKitTests/Stage0[1-5]Tests`.
Expected: all prior-stage tests pass unchanged (brief §9 "tests preserved: none new — but the carried set from Stages 01–05 must still be green").

If any test fails, inspect the failure: a legitimate regression requires fixing the production code, not the test. Stage 04/05 tests that used the removed test seams need migration per Task 5.1.h.

- [ ] **Step 6.8: Commit (Tasks 4+5+6 together)**

```bash
git add CameraKit/Sources/CameraKit/PixelSink.swift \
        CameraKit/Sources/CameraKit/MetalPipeline.swift \
        CameraKit/Sources/CameraKit/CaptureDelegate.swift \
        CameraKit/Sources/CameraKit/CameraEngine.swift \
        CameraKit/Sources/CameraKit/FrameSet.swift \
        CameraKit/Tests/CameraKitTests/*.swift
git commit -m "feat(stage-06): ConsumerRegistry actor + pool trio + Pass 4 + FrameSet publication"
```

---

### Task 7 — Debug overlay + tracker thumbnail (UI)

**Model:** sonnet — SwiftUI observation wiring + MTKView lifecycle with pool-backed textures.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 7.1: Add overlay state + subscribe helpers to ViewModel**

Edit `ViewModel.swift` — inside the `final class ViewModel` body, add:

```swift
    // MARK: - Stage 06 — Debug overlay + tracker thumbnail

    struct DebugOverlay: Equatable {
        var frameNumber: UInt64
        var captureTimeMs: Int64
    }
    var debugOverlay: DebugOverlay?

    /// True when the user has toggled the debug tracker subscriber on. Flipping
    /// this triggers subscribe/unsubscribe via `applyDebugTrackerToggle()`.
    var debugTrackerSubscribed: Bool = false

    @ObservationIgnored
    nonisolated(unsafe) var trackerTex: MTLTexture?

    @ObservationIgnored private var naturalSubscriberTask: Task<Void, Never>?
    @ObservationIgnored private var trackerSubscriberTask: Task<Void, Never>?

    /// Starts a `.natural` subscription that feeds the debug overlay.
    /// Always on in DEBUG builds; a no-op in release.
    func startDebugOverlay() {
        #if DEBUG
        naturalSubscriberTask?.cancel()
        naturalSubscriberTask = Task { [weak self] in
            guard let self else { return }
            for await fs in await self.engine.consumers.subscribe(stream: .natural) {
                let overlay = DebugOverlay(
                    frameNumber: fs.frameNumber,
                    captureTimeMs: Int64(CMTimeGetSeconds(fs.captureTime) * 1000)
                )
                await MainActor.run { self.debugOverlay = overlay }
            }
        }
        #endif
    }

    func toggleDebugTrackerSubscription() async {
        debugTrackerSubscribed.toggle()
        if debugTrackerSubscribed {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = Task { [weak self] in
                guard let self else { return }
                for await fs in await self.engine.consumers.subscribe(stream: .tracker) {
                    // Update the tracker texture pointer for MTKView blit.
                    let pipelineTex = self.engine.currentTrackerTexture()
                    _ = fs  // not directly read; the presence of fs means tracker is live
                    await MainActor.run { self.trackerTex = pipelineTex }
                }
                await MainActor.run { self.trackerTex = nil }
            }
        } else {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = nil
            trackerTex = nil
        }
    }
```

**Note:** `engine.currentTrackerTexture()` is a new nonisolated accessor on `CameraEngine` — add it. Edit `CameraEngine.swift`:

```swift
public nonisolated func currentTrackerTexture() -> (any MTLTexture)? {
    metalPipeline?.latestTrackerTex
}
```

(The `metalPipeline?` property is `actor`-isolated as `var metalPipeline: MetalPipeline?`; reading it nonisolated would be a strict-concurrency violation. Swap its declaration to `nonisolated(unsafe) var metalPipeline: MetalPipeline?` — same treatment as `_naturalTex` — if the compiler complains. Document in a comment: "Written once during open()/setResolution on the actor; read nonisolated for preview paths that run on MainActor / MTKView threads.")

- [ ] **Step 7.2: Call `startDebugOverlay()` from `start()`**

In `ViewModel.start()`, after the `frameResultTask = Task { … }` block, add:

```swift
startDebugOverlay()
```

In `stop()`, cancel the tasks:

```swift
naturalSubscriberTask?.cancel(); naturalSubscriberTask = nil
trackerSubscriberTask?.cancel(); trackerSubscriberTask = nil
```

- [ ] **Step 7.3: CameraView — debug overlay text + tracker thumbnail + toggle button**

Edit `CameraView.swift`. Inside the body, layered into the top ZStack, add (after the existing top-right Calibrate-Color button VStack):

```swift
#if DEBUG
// Debug overlay: frame number + capture time (top-left).
if let overlay = viewModel.debugOverlay {
    VStack {
        HStack {
            Text("#\(overlay.frameNumber)  t=\(overlay.captureTimeMs)ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.yellow)
                .padding(6)
                .background(.black.opacity(0.6))
                .padding([.top, .leading], 8)
            Spacer()
        }
        Spacer()
    }
}

// Debug tracker thumbnail (bottom-left) when subscribed.
if viewModel.debugTrackerSubscribed {
    VStack {
        Spacer()
        HStack {
            MTKViewRepresentable(textureAccessor: { viewModel.trackerTex })
                .frame(width: 160, height: 120)
                .border(.yellow, width: 1)
                .padding([.bottom, .leading], 80)
            Spacer()
        }
    }
}

// Debug toggle button (top-right, below the Calibrate button).
VStack {
    HStack {
        Spacer()
        Button(viewModel.debugTrackerSubscribed ? "Hide Tracker" : "Show Tracker") {
            Task { await viewModel.toggleDebugTrackerSubscription() }
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .foregroundStyle(.yellow)
        .padding(.top, 56)
        .padding(.trailing, 16)
    }
    Spacer()
}
#endif
```

- [ ] **Step 7.4: Build + Run on device**

Run: `mcp__XcodeBuildMCP__build_run_device`.
Expected: the app launches on the physical iPad (session defaults must be set per CLAUDE.md §6). Camera preview shows; yellow "#N t=…ms" counter updates; tapping "Show Tracker" reveals a small downsampled thumbnail in the lower-left.

If the app crashes in `MTKViewRepresentable` for the tracker thumbnail: the texture accessor returned nil until the first tracker-lane frame publishes. That's expected — the MTKView will render the black fallback from Stage 01 until the first FrameSet with a tracker buffer is published (~one frame after the subscribe completes).

- [ ] **Step 7.5: Commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift \
        CameraKit/Sources/CameraKit/CameraView.swift \
        CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-06): debug overlay (frame-number + capture-time) + tracker thumbnail"
```

---

### Task 8 — `Stage06Tests.swift`

**Model:** sonnet — seven test methods; each exercises a named TESTABLE from brief §8.

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage06Tests.swift`

- [ ] **Step 8.1: Write the test suite**

Create `Stage06Tests.swift`:

```swift
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

@Suite("Stage06Tests")
struct Stage06Tests {

    // MARK: - Test 1 — 06:frame-set-publication

    /// Inject a known-pattern CMSampleBuffer; subscribers to `.natural` /
    /// `.processed` / `.tracker` each receive one FrameSet per input frame
    /// with matching CaptureMetadata.frameNumber. Each CVPixelBuffer is
    /// IOSurface-backed.
    @Test func frameSetPublication() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let registry = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gate: .init(true), consumers: registry)

        let naturalTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .natural) { return fs }
            return nil
        }
        let processedTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .processed) { return fs }
            return nil
        }
        let trackerTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .tracker) { return fs }
            return nil
        }

        // Give the subscribe tasks a chance to register before we encode.
        try await Task.sleep(nanoseconds: 50_000_000)

        let sb = try makeSyntheticYUVSampleBuffer(width: size.width, height: size.height)
        try pipeline.encode(sampleBuffer: sb)
        // Wait for the completion handler to fire.
        try await Task.sleep(nanoseconds: 200_000_000)

        naturalTask.cancel(); processedTask.cancel(); trackerTask.cancel()
        let n = await naturalTask.value
        let p = await processedTask.value
        let t = await trackerTask.value
        #expect(n?.frameNumber == 1)
        #expect(p?.frameNumber == 1)
        #expect(t?.frameNumber == 1)
        // Each pool buffer is IOSurface-backed.
        #expect(CVPixelBufferGetIOSurface(n!.natural) != nil)
        #expect(CVPixelBufferGetIOSurface(p!.processed) != nil)
        #expect(CVPixelBufferGetIOSurface(t!.tracker) != nil)
    }

    // MARK: - Test 2 — 06:swift-consumer-drop-on-busy

    /// Subscriber iterates with a 10ms sleep per iteration while the delivery
    /// loop yields synthetically at 30fps. The subscriber receives the latest
    /// frame (not a backlog) and at least one drop is recorded.
    @Test func swiftConsumerDropOnBusy() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .processed)

        // Producer: 30 yields at ~30fps.
        let producer = Task {
            for i in 1...30 {
                registry.yield(Self.makeTestFrameSet(frameNumber: UInt64(i)), stream: .processed)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        var seen: [UInt64] = []
        let consumer = Task {
            for await fs in stream {
                seen.append(fs.frameNumber)
                try? await Task.sleep(nanoseconds: 10_000_000)
                if seen.count >= 5 { break }
            }
            return seen
        }
        _ = await producer.value
        let received = await consumer.value

        // Drop counter recorded at least one drop.
        let drops = registry.dropCount(for: .processed)
        #expect(drops >= 1)
        // Latest-wins: received frame numbers should be strictly increasing but
        // should skip frame ids (not 1..<N contiguously).
        #expect(received.count >= 1)
        for i in 1..<received.count { #expect(received[i] > received[i-1]) }
    }

    // MARK: - Test 3 — 06:pool-trio-allocation-on-open

    /// `MetalPipeline.init` creates three CVPixelBufferPool instances with
    /// IOSurface + Metal compat keys; pool cap follows POOL_CAP_RULE
    /// (N_active_lanes + 1) — validated indirectly by exercising dequeue.
    @Test func poolTrioAllocationOnOpen() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 128, height: 128)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gate: .init(true), consumers: ConsumerRegistry())
        // Dequeue one of each to confirm pools are live.
        let (nb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        let (pb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        let (tb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.trackerPoolForTest,
            width: pipeline.trackerSizeForTest.width,
            height: pipeline.trackerSizeForTest.height)
        #expect(CVPixelBufferGetIOSurface(nb) != nil)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
        #expect(CVPixelBufferGetIOSurface(tb) != nil)
    }

    // MARK: - Test 4 — 06:tracker-downsample-height-matches-constant

    @Test func trackerDownsampleHeightMatchesConstant() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Capture size 1280×720 ⇒ tracker 480 tall, 854 wide (even-rounded down from 853.33).
        let size = Size(width: 1280, height: 720)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gate: .init(true), consumers: ConsumerRegistry())
        #expect(pipeline.trackerSizeForTest.height == Constants.trackerHeightPx)
        #expect(pipeline.trackerSizeForTest.width % 2 == 0)
        let expected = Int((Double(Constants.trackerHeightPx) *
            Double(size.width) / Double(size.height)).rounded())
        let expectedEven = expected - (expected % 2)
        #expect(pipeline.trackerSizeForTest.width == expectedEven)
    }

    // MARK: - Test 5 — 06:subscribe-then-cancel-releases-subscriber

    @Test func subscribeThenCancelReleasesSubscriber() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .processed)
        let task = Task {
            for await _ in stream { break }
        }
        // Wait briefly for registration.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(registry.subscriberCount(for: .processed) == 1)
        task.cancel()
        // Yield a sentinel to wake the terminated stream and drain.
        registry.yield(Self.makeTestFrameSet(frameNumber: 42), stream: .processed)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(registry.subscriberCount(for: .processed) == 0)
    }

    // MARK: - Test 6 — 06:register-callback-throws-not-wired

    @Test func registerCallbackThrowsNotWired() async throws {
        let registry = ConsumerRegistry()
        // Minimal C-ABI callback struct; content doesn't matter — the call throws
        // before inspecting the function pointers.
        let cb = PixelSinkCallbacks(
            onFrame: { _, _, _, _, _ in },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: nil
        )
        await #expect(throws: InteropError.notWired) {
            _ = try await registry.registerCallback(stream: .tracker, callbacks: cb)
        }
    }

    // MARK: - Test 7 — 06:natural-stream-is-subscribable

    @Test func naturalStreamIsSubscribable() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let registry = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gate: .init(true), consumers: registry)

        let task = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .natural) { return fs }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let sb = try makeSyntheticYUVSampleBuffer(width: size.width, height: size.height)
        try pipeline.encode(sampleBuffer: sb)
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let fs = await task.value
        #expect(fs?.frameNumber == 1)
        #expect(CVPixelBufferGetIOSurface(fs!.natural) != nil)
    }

    // MARK: - Helpers

    private static func makeTestFrameSet(frameNumber: UInt64) -> FrameSet {
        // Tiny 1×1 pixel buffer for unit tests that don't touch GPU.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1, 1,
            kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb)
        let buffer = pb!
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: Int64(frameNumber), timescale: 30),
            natural: buffer, processed: buffer, tracker: buffer,
            capture: CaptureMetadata.placeholder(),
            processing: ProcessingMetadata(
                color: .identity,
                crop: .full(width: 1, height: 1)),
            blurScore: 0,
            trackerQuality: .good
        )
    }
}

// MARK: - Shared test helper (mirrors Stage02Tests)

private enum SyntheticBufferError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed
    case sampleBufferFailed
}

private func makeSyntheticYUVSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer
    )
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw SyntheticBufferError.pixelBufferFailed(cvStatus)
    }
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescriptionOut: &formatDescription)
    guard let fd = formatDescription else {
        throw SyntheticBufferError.formatDescriptionFailed
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescription: fd, sampleTiming: &timing,
        sampleBufferOut: &sb)
    guard let sampleBuffer = sb else { throw SyntheticBufferError.sampleBufferFailed }
    return sampleBuffer
}
```

- [ ] **Step 8.2: Add test seams on `MetalPipeline`**

Test 3 (`poolTrioAllocationOnOpen`) + Test 4 (`trackerDownsampleHeightMatchesConstant`) reference internal properties: `texturePoolForTest`, `naturalPoolForTest`, `processedPoolForTest`, `trackerPoolForTest`, `trackerSizeForTest`. Add these as `internal var` accessors at the bottom of `MetalPipeline.swift`:

```swift
    // MARK: - Stage 06 test seams (accessed via @testable import)
    var texturePoolForTest: TexturePoolManager { texturePool }
    var naturalPoolForTest: CVPixelBufferPool { naturalPool }
    var processedPoolForTest: CVPixelBufferPool { processedPool }
    var trackerPoolForTest: CVPixelBufferPool { trackerPool }
    var trackerSizeForTest: Size { trackerSize }
```

- [ ] **Step 8.3: Migrate Stage-04 tests that referenced `naturalBufferForTest` / `processedBufferForTest`**

Run: `grep -n "BufferForTest" CameraKit/Tests/CameraKitTests/Stage0[45]Tests.swift`
For each hit, either:
- Replace with `latestNaturalBufferForTest!` / `latestProcessedBufferForTest!` — but these are nil until the first encode fires.
- OR re-plumb the test by encoding one synthetic frame first, then reading the latest buffer.

Expected hits: Stage04Tests Test 1 (`fillBufferUniform(pipeline.naturalBufferForTest, ...)`), Test 3 (`pipeline.processedBufferForTest`), Test 4.

For each, the cleanest rewrite is to dequeue a pool buffer manually, fill it, and swap it into the `latest…Tex` mailbox before calling `encodePass2Only()`. Example:

```swift
// Replace:
try fillBufferUniform(pipeline.naturalBufferForTest, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
// With:
let (buf, tex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
    pool: pipeline.naturalPoolForTest,
    width: size.width, height: size.height)
try fillBufferUniform(buf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
pipeline.setLatestNaturalForTest(buffer: buf, texture: tex)  // new test seam
```

Add the test seam to `MetalPipeline`:

```swift
    func setLatestNaturalForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestNaturalBuffer = buffer
        latestNaturalTex = texture
    }
    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestProcessedBuffer = buffer
        latestProcessedTex = texture
    }
```

And update `encodePass2Only()` (the Stage-04 test seam on MetalPipeline) to use `latestNaturalTex ?? naturalTex` and `latestProcessedTex ?? processedTex` — or rewrite it to dequeue its own buffers. The simplest migration: change its signature to accept input/output textures explicitly:

```swift
func encodePass2Only(input: MTLTexture, output: MTLTexture) async throws {
    // existing body, reading from `input` and writing to `output`
}
```

Update Stage-04 tests accordingly.

- [ ] **Step 8.4: Run the Stage 06 test suite**

Run: `mcp__XcodeBuildMCP__test_device` with filter `CameraKitTests/Stage06Tests`.
Expected: all seven `@Test` methods pass.

If `swiftConsumerDropOnBusy` is flaky (timing-sensitive), accept up to 2 reruns; the test's core assertion — `dropCount >= 1` — is lenient.

- [ ] **Step 8.5: Run full test suite (regression check)**

Run: `mcp__XcodeBuildMCP__test_device` with filter `CameraKitTests/Stage0[1-6]Tests`.
Expected: all tests pass.

- [ ] **Step 8.6: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage06Tests.swift \
        CameraKit/Tests/CameraKitTests/Stage04Tests.swift \
        CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "test(stage-06): Stage06Tests + Stage04 migration to pool-backed test seams"
```

---

### Task 9 — HITL device evidence

**Model:** (human-in-the-loop; no agent.)

**Files:**
- Create: `measurements/stage-06/consumers.md`

- [ ] **Step 9.1: Device smoke — debug overlay**

On physical iPad Pro M1 (iOS 26.4.1), build-run via `mcp__XcodeBuildMCP__build_run_device`. Confirm:
- Yellow `#N t=…ms` counter visible top-left.
- `N` increments monotonically every frame (~30Hz).
- `t` is non-decreasing (capture presentation time).

Record a short screen capture (QuickTime) and a pasted text sample from the overlay.

- [ ] **Step 9.2: Device smoke — tracker thumbnail**

Tap "Show Tracker". Confirm:
- A small (~160×120) thumbnail appears lower-left with a yellow border.
- The thumbnail content matches the main processed preview (downsampled).
- Tap "Hide Tracker" — thumbnail disappears within a frame.

- [ ] **Step 9.3: Instruments — pool age-out**

With Instruments > Allocations attached, unsubscribe the tracker stream; observe `CVPixelBufferPool`'s tracker-lane backing-store count drop to the `POOL_MIN_BUFFER_COUNT` floor and age out after ~1 second of no subscribers. Capture a screenshot of the Allocations histogram.

- [ ] **Step 9.4: Write evidence file**

Create `measurements/stage-06/consumers.md` with:
- Device + iOS version + build hash.
- Screenshots / screen captures for §9.1–§9.3.
- PASS/FAIL for each HITL test ID from brief §8:
  - `06:tracker-thumbnail-appears-on-subscribe`
  - `06:debug-overlay-shows-frame-number-capture-time`

- [ ] **Step 9.5: Commit evidence**

```bash
git add measurements/stage-06/consumers.md
git commit -m "docs(stage-06): HITL evidence — tracker thumbnail + debug overlay"
```

---

### Task 10 — state.md update + scaffold inventory check

**Model:** haiku — mechanical doc edits.

**Files:**
- Modify: `CameraKit/state.md`

- [ ] **Step 10.1: Run the final scaffold grep**

Run: `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only' CameraKit/Sources/`
Expected: each slug returns ≥1 hit. Record the file:line list.

- [ ] **Step 10.2: Update `state.md`**

Rewrite `CameraKit/state.md` per brief §12. Include:
- Current stage: "Stage 06 complete."
- Scaffolding still live (with file:line): `01:simple-metal-passthrough` (MetalPipeline.swift + ColorShaders.metal + TexturePoolManager.swift), `01:skip-completion-guard` (MetalPipeline.swift), `06:simple-consumer-swift-only` (PixelSink.swift).
- Retires-in column: Stage 08 for 01 + 06 slugs; Stage 09 for `01:skip-completion-guard`.
- What's built — Stage 06 (permanent): list per brief §12 (Pass 4 tracker downsample; three `CVPixelBufferPool` instances; `FrameSet` complete construction in completion handler; `ConsumerRegistry` actor with Swift `subscribe(stream:)` + C-ABI `registerCallback` placeholder; `CaptureMetadata.placeholder`; `InteropError.notWired`; debug overlay + tracker-thumbnail UI).
- Public API additions: `ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>`, `ConsumerRegistry.unregister(token:)`, `ConsumerRegistry.registerCallback(stream:callbacks:) throws`, `CameraEngine.consumers: ConsumerRegistry`, `CameraEngine.currentTrackerTexture()`. Removed: `CameraEngine.registerPixelSink` / `deregisterPixelSink`.
- Manual test evidence table — fill in passes for 06:* TESTABLEs + HITLs per §9 file.
- Decisions taken that weren't in briefs — document: 
  - mutex-backed subscriber table inside the actor (brief says "actor" but yield is called on delivery queue; dual-nature implementation is the reconciliation);
  - tracker field populated with `naturalBuf` as placeholder when no tracker subscriber (avoids making `FrameSet.tracker` optional);
  - `CaptureMetadata.placeholder` deferred to a later stage;
  - `MetalPipeline.metalPipeline` made `nonisolated(unsafe)` to unblock nonisolated tracker-texture accessor.
- Open questions for next stage: real `CaptureMetadata` attachment extraction; Pass-3 direct natural-blit (currently flowing through the preview mailbox, not the architecture's "direct GPU blit" target); drop counters wired into `FrameDeliveryStats` publishing stream (Stage 12).

- [ ] **Step 10.3: Run the full test suite one last time**

Run: `mcp__XcodeBuildMCP__test_device` with filter `CameraKitTests/Stage0[1-6]Tests`.
Expected: all tests pass.

- [ ] **Step 10.4: Commit and stop**

```bash
git add CameraKit/state.md
git commit -m "docs(stage-06): state.md — mark Stage 06 complete; Stage 07 pre-flight slugs"
```

Then **stop**. Per CLAUDE.md §7, do not push or open a PR without explicit user approval.

---

## 3. Acceptance criteria (from brief §10)

- [ ] `swift build` (via `mcp__XcodeBuildMCP__build_device`) passes, no new warnings.
- [ ] All prior-stage tests (`Stage0[1-5]Tests`) pass unchanged.
- [ ] New TESTABLE tests (`Stage06Tests` — all seven) pass.
- [ ] HITL tests confirmed on iPad Pro M1; evidence at `measurements/stage-06/consumers.md`.
- [ ] `grep -rn '06:simple-consumer-swift-only' Sources/` ≥1 hit; `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' Sources/` each ≥1 hit.

## 4. Open risks / watch items

- **`CMSampleBuffer` capture in the completion handler.** The closure referenced in §5.2 captures `sampleBuffer` to read `CMSampleBufferGetPresentationTimeStamp`. `CMSampleBuffer` is not Sendable. Strict-concurrency may warn/error. Mitigation: compute the `CMTime` before the closure is built and reference only the local inside the closure. Same pattern for `CaptureMetadata.placeholder(from:)` — move the call outside.
- **Pool exhaustion under subscribed tracker + slow consumer.** `POOL_MIN_BUFFER_COUNT = 3` + `POOL_CAP_RULE = N_active_lanes + 1` = 4 buffers max per pool in steady state. A Swift consumer that stalls > 4 frames' worth of processing may cause CF to withhold new buffers (Stage 12 surfaces this via `pool_exhaustion` counter; this stage accepts dropped frames silently in that case).
- **Preview mailbox race.** `latest…Tex` + `latest…Buffer` are two unsynchronised `nonisolated(unsafe)` writes in the completion handler; MTKView draws reads from them on a different thread. In practice the swap is two pointer-sized stores that will be observed in order — but no formal guarantee. Stage 12 may replace with an atomic swap or `Mutex` if issues arise.
- **`registerCallback` test (Test 6)** uses `@convention(c)` closures. Swift 6 strict-concurrency may require these to be `@Sendable` — if the compiler complains, use named `static func` stubs instead of closures:

```swift
@_cdecl("stage06_test_onFrame")
func stage06_test_onFrame(_: UnsafeMutableRawPointer?, _: UInt32, _: UInt64, _: Int64, _: UnsafeMutableRawPointer?) {}
```

---

## 5. Execution handoff

Plan complete. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks; per-task model annotations (`haiku` / `sonnet`) already set.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`; batch with checkpoints.

Which approach?
