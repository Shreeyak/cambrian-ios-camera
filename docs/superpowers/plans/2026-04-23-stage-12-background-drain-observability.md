# Stage 12 — Background Recording Drain + Observability Implementation Plan (MIGRATION)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire `scaffolding:10:synchronous-drain-pause` by wrapping every recording-drain trigger (pause-during-recording, `backgroundSuspend`-during-recording, `stopRecording` at scenePhase `.background`) in `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`. The expiration handler **always** calls `writer.cancelWriting()` (never `finishWriting`) per ADR-16 / G-08. Plumb `FrameDeliveryStats` end-to-end: a C-ABI metrics callback from `PixelSinkPool` delivers `mailbox_overwrite_count` per stream; `ConsumerRegistry.metricsStream()` merges those with Swift-side per-lane drop counters into one `AsyncStream<FrameDeliveryStats>`. Enforce the G-26 quality gate — `registerCallback` rejects `on_overwrite == nil`.

**Architecture:** `Recording` gains a `BackgroundTaskHost` injectable that defaults to a `UIApplication` wrapper in production and a `FakeBackgroundTaskHost` under test. Every drain path goes through `runInsideBackgroundTask { await performDrain() }` so cancellation, expiration, and `endBackgroundTask` are handled uniformly. On expiration, the handler fires `writer.cancelWriting()` on an arbitrary queue via a non-actor-bound reference captured at drain start. C++ side gains `mailbox_overwrite_count` per-lane atomics and a `PixelSinkMetrics` callback fired every `FPS_MEASUREMENT_WINDOW_FRAMES` frames; `ConsumerRegistry` merges those with the existing Swift-side `dropCounts` dictionary, computes deltas (not cumulatives), and yields on `metricsStream()` at the same cadence. The quality gate lands as an existing `InteropError.invalidCallbacks` → renamed/aliased to `missingOnOverwrite` per brief §8.

**Tech Stack:** Swift 6, UIKit (`UIApplication.beginBackgroundTask`), C++17 (std::atomic counters + function-pointer callback), swift-testing.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `CameraKit/Sources/CameraKit/BackgroundTaskHost.swift` | Create | `protocol BackgroundTaskHost: Sendable` with `begin(name:expirationHandler:) -> UInt64`, `end(identifier:)`. Production `UIApplicationBackgroundTaskHost` wraps `UIApplication.shared`. Test-only `FakeBackgroundTaskHost` (in the test target) records begins/ends and lets tests fire the expiration handler on demand. |
| `CameraKit/Sources/CameraKit/Recording.swift` | Modify | Accept a `BackgroundTaskHost` via init (default production impl); `stop(reason:)` runs the drain inside `runInsideBackgroundTask { … }`; expiration handler calls `writer.cancelWriting()` without going through the actor; `endBackgroundTask(_:)` invoked on every exit path (success / error / expiry). Retires `scaffolding:10:synchronous-drain-pause` — comment removed from `CameraEngine.pause()`. |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Modify | Remove `scaffolding:10:synchronous-drain-pause` comment from `pause()`; route `backgroundSuspend()`-during-recording through the same `Recording.stop(reason: .pause)` path; construct `UIApplicationBackgroundTaskHost` at engine init and inject into `Recording`. |
| `CameraKit/Sources/CameraKit/Errors.swift` | Modify | Add `InteropError.missingOnOverwrite` variant (keeps `invalidCallbacks` for backward compatibility of prior tests; `registerCallback` now throws the more specific variant when `onOverwrite == nil`). |
| `CameraKit/Sources/CameraKitCxx/include/PixelSinkMetrics.h` | Create | `typedef struct PixelSinkMetrics { uint32_t stream_id; uint64_t mailbox_overwrite_count; } PixelSinkMetrics;` + `typedef void (*PixelSinkMetricsCallback)(const PixelSinkMetrics* samples, uint32_t count, void* context);`. |
| `CameraKit/Sources/CameraKitCxx/include/PixelSink.hpp` | Modify | Add atomic `mailbox_overwrite_count_` per lane; add `registerMetricsCallback(PixelSinkMetricsCallback, void*)`; declare assertion in `registerCallbacks` rejecting `on_overwrite == nullptr`. |
| `CameraKit/Sources/CameraKitCxx/PixelSinkPool.cpp` | Modify | On overwrite in `publish`, increment the per-lane atomic; fire the registered metrics callback every `FPS_MEASUREMENT_WINDOW_FRAMES` publications; reject `on_overwrite == nullptr` in `registerCallbacks` with a new error code (`PIXEL_SINK_MISSING_OVERWRITE`). |
| `CameraKit/Sources/CameraKit/PixelSink.swift` | Modify | Wire `ConsumerRegistry` to register a C metrics callback with the pool; hold the latest cumulative snapshot; expose `metricsStream() -> AsyncStream<FrameDeliveryStats>` yielding deltas per window; update `registerCallback` to throw `InteropError.missingOnOverwrite` (rename error site). |
| `CameraKit/Sources/CameraKit/FrameSet.swift` | Modify | `FrameDeliveryStats` already public; add an `init(merging:swiftDrops:cppOverwrites:)` convenience if the existing shape doesn't already express per-lane dictionaries cleanly. |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Modify | Subscribe to `engine.consumers.metricsStream()` in `start()`; update an `@Observable` `deliveryStats: FrameDeliveryStats?` binding. |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Modify | Long-press overlay on the Resolution display (already wired Stage 11) now reads `viewModel.deliveryStats`, rendering per-lane `drops` and `overwrites` counts. |
| `CameraKit/Tests/CameraKitTests/Stage12Tests.swift` | Create | 5 `@Test` functions per brief §8, plus confirm preserved tests (10:*) still pass. |
| `eva-swift-stitch.xcodeproj` | Modify | Wire `Stage12Tests.swift` via ruby xcodeproj. |

---

## Build / test tooling note

Use shell wrappers (CLAUDE.md §6):

```bash
scripts/build-summary.sh
scripts/test-summary.sh --filter CameraKitTests/Stage12
scripts/test-summary.sh                      # full sweep
```

Never raw `xcodebuild`; never simulators. Read `.build-logs/*.json` on failures.

---

## Task 1: Stage preflight

**Files:** `CameraKit/state.md`, `scripts/stage-preflight.sh`

- [ ] **Step 1: Run preflight**

```bash
bash scripts/stage-preflight.sh
```
Expected: exits 0.

- [ ] **Step 2: Confirm only `10:synchronous-drain-pause` is live**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/       # ≥1 hit (in CameraEngine.swift:pause())
grep -rn -E '01:|04:|06:|07:|09:|11:' CameraKit/Sources/       # 0 hits
```

Halt and escalate if the live scaffold is missing (state.md ↔ source drift) or prior-stage scaffolds remain (prior stage incomplete).

- [ ] **Step 3: Clean build baseline**

```bash
bash scripts/build-summary.sh
```
Expected: BUILD SUCCEEDED.

---

## Task 2: BackgroundTaskHost seam — TDD

**Files:** `CameraKit/Sources/CameraKit/BackgroundTaskHost.swift`, `CameraKit/Tests/CameraKitTests/Stage12Tests.swift`

- [ ] **Step 1: Write the failing test (Fake host shape)**

Create `CameraKit/Tests/CameraKitTests/Stage12Tests.swift`:

```swift
import Testing
import Foundation
@testable import CameraKit

/// Test double: records begin/end and exposes the stored expirationHandler so tests fire it on demand.
final class FakeBackgroundTaskHost: BackgroundTaskHost, @unchecked Sendable {
    private let lock = NSLock()
    private var nextId: UInt64 = 0
    private(set) var outstanding: [UInt64: @Sendable () -> Void] = [:]
    private(set) var begins: Int = 0
    private(set) var ends: Int = 0

    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextId &+= 1
        outstanding[nextId] = expirationHandler
        begins += 1
        return nextId
    }
    func end(identifier: UInt64) {
        lock.lock(); defer { lock.unlock() }
        outstanding[identifier] = nil
        ends += 1
    }
    /// Fire the most recently registered expiration handler.
    func fireExpiration(identifier: UInt64) {
        lock.lock()
        let h = outstanding[identifier]
        lock.unlock()
        h?()
    }
}

@Suite("Stage 12 — background task host")
struct Stage12HostTests {
    @Test("fake host returns monotonically increasing identifiers")
    func fakeHostIdentifiers() {
        let host = FakeBackgroundTaskHost()
        let a = host.begin(name: "t1") { }
        let b = host.begin(name: "t2") { }
        #expect(b > a)
        host.end(identifier: a)
        host.end(identifier: b)
        #expect(host.begins == 2)
        #expect(host.ends == 2)
    }
}
```

- [ ] **Step 2: Run — expect compile failure** (no `BackgroundTaskHost` type)

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage12HostTests
```

- [ ] **Step 3: Implement the seam**

Create `CameraKit/Sources/CameraKit/BackgroundTaskHost.swift`:

```swift
import UIKit

/// Abstraction over UIApplication's background-task API so the recording drain
/// is unit-testable. Production wraps UIApplication.shared; tests swap with a fake
/// that lets them fire expiration handlers synchronously.
public protocol BackgroundTaskHost: Sendable {
    /// Begin a background task. The returned identifier must be passed to `end(identifier:)`
    /// on every exit path (success, error, expiry). `expirationHandler` is invoked by the
    /// system (or by tests) when the task is forcibly terminated; the handler runs on an
    /// arbitrary queue and must not block.
    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> UInt64

    /// End a background task. Safe to call multiple times with the same identifier — the
    /// second call is a no-op.
    func end(identifier: UInt64)
}

/// Production impl. Bridges `UIBackgroundTaskIdentifier` (a typealias for Int / -1 sentinel)
/// through a `UInt64` to keep the public protocol free of UIKit imports for consumers.
public final class UIApplicationBackgroundTaskHost: BackgroundTaskHost, @unchecked Sendable {
    private let lock = NSLock()
    private var mapping: [UInt64: UIBackgroundTaskIdentifier] = [:]
    private var nextId: UInt64 = 0

    public init() {}

    public func begin(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> UInt64 {
        let bgId = UIApplication.shared.beginBackgroundTask(
            withName: name,
            expirationHandler: expirationHandler
        )
        lock.lock(); defer { lock.unlock() }
        nextId &+= 1
        let id = nextId
        mapping[id] = bgId
        return id
    }

    public func end(identifier: UInt64) {
        lock.lock()
        let bgId = mapping.removeValue(forKey: identifier)
        lock.unlock()
        if let bgId, bgId != .invalid {
            UIApplication.shared.endBackgroundTask(bgId)
        }
    }
}
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/BackgroundTaskHost.swift CameraKit/Tests/CameraKitTests/Stage12Tests.swift
git commit -m "feat(stage-12): BackgroundTaskHost protocol + UIApplication impl; FakeBackgroundTaskHost for tests"
```

---

## Task 3: Recording — wrap the drain in a background task

**Files:** `CameraKit/Sources/CameraKit/Recording.swift`

- [ ] **Step 1: Inject `BackgroundTaskHost`**

Extend `Recording.init` with an injected host (default impl for production):

```swift
    private let host: BackgroundTaskHost

    public init(
        clock: any CameraKitClock,
        hooks: Hooks,
        writerFactory: @escaping AssetWriterFactory,
        backgroundTaskHost: BackgroundTaskHost = UIApplicationBackgroundTaskHost()
    ) {
        self.clock = clock
        self.hooks = hooks
        self.writerFactory = writerFactory
        self.host = backgroundTaskHost
    }
```

- [ ] **Step 2: Wrap the drain inside `stop(reason:)`**

Replace the existing finalize race with the background-task-wrapped version. Structure:

```swift
    public func stop(reason: StopReason = .user) async -> String {
        guard case .recording = state, let writer else {
            if case .idle(let last) = state { return last ?? "" }
            return outputURL?.absoluteString ?? ""
        }
        state = .finalizing
        hooks.publishState(state)

        // Capture a direct writer reference for the expiration handler (which runs on an
        // arbitrary queue and cannot await the actor).
        let writerRef = writer
        let cancelledByExpiry = ManagedAtomic<Bool>(false)

        let taskId = host.begin(name: "recording-drain") {
            // Expiration handler: ADR-16 / G-08 — ALWAYS cancelWriting, NEVER finishWriting.
            cancelledByExpiry.store(true, ordering: .sequentiallyConsistent)
            Task { await writerRef.cancelWriting() }
        }
        defer { host.end(identifier: taskId) }

        await writer.markInputFinished()

        // Finalize with deadline (existing behavior preserved for 10:recording-truncated-on-deadline).
        let deadlineMs = Int(Constants.recordingFinishTimeoutSeconds * 1000)
        let clock = self.clock
        let didTimeout = ManagedAtomic<Bool>(false)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await writer.finishWriting() }
            group.addTask {
                try? await clock.sleep(milliseconds: deadlineMs)
                if await writer.status != .completed
                    && !cancelledByExpiry.load(ordering: .acquiring) {
                    didTimeout.store(true, ordering: .sequentiallyConsistent)
                    await writer.cancelWriting()
                }
            }
            await group.waitForAll()
        }

        let uri = outputURL?.absoluteString ?? ""

        if cancelledByExpiry.load(ordering: .acquiring) || didTimeout.load(ordering: .acquiring) {
            let err = CameraError(
                code: .recordingTruncated,
                message: cancelledByExpiry.load(ordering: .acquiring)
                    ? "background-task expiration: cancelWriting"
                    : "finishWriting exceeded \(Constants.recordingFinishTimeoutSeconds)s; cancelled",
                isFatal: false
            )
            hooks.emitError(err)
        }

        if await writer.status == .failed {
            let e = await writer.writerError
            let err = CameraError(
                code: .recordingFailed,
                message: "writer failed: \(String(describing: e))",
                isFatal: true
            )
            hooks.emitError(err)
            state = .idle(lastUri: uri)
            hooks.publishState(state)
            return uri
        }

        state = reason == .pause ? .paused : .idle(lastUri: uri)
        hooks.publishState(state)
        return uri
    }
```

Rationale: `endBackgroundTask` via `defer` ensures it's called on every exit — success, truncation, writer-error. That satisfies `12:end-background-task-called-on-all-paths`.

- [ ] **Step 3: Build**

```bash
bash scripts/build-summary.sh
```
Expected: BUILD SUCCEEDED. Any concurrency warnings get promoted to errors (strict concurrency) — address `@Sendable` capture on `writerRef` if the compiler objects (the `AssetWriting` protocol is already `Sendable`).

- [ ] **Step 4: Run preserved tests (§9)**

```bash
bash scripts/test-summary.sh --filter "CameraKitTests/Stage10"
```
Expected: `10:record-start-stop-happy-path` + `10:recording-truncated-on-deadline` both still green. The deadline test's `FastClock` / `TestClock` passes the timeout branch; the happy path has `didTimeout = false` and `cancelledByExpiry = false`.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/Recording.swift
git commit -m "feat(stage-12): Recording.stop wraps drain in background task; expiration → cancelWriting (ADR-16, G-08)"
```

---

## Task 4: CameraEngine — retire the scaffolding; route backgroundSuspend through the wrapped drain

**Files:** `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Remove the scaffolding comment + construct `Recording` with the production host**

In `startRecording(options:)`:

```swift
    let host = UIApplicationBackgroundTaskHost()
    let rec = Recording(
        clock: clock,
        hooks: hooks,
        writerFactory: assetWriterFactory,
        backgroundTaskHost: host
    )
```

In `pause()`: delete the `scaffolding:10:synchronous-drain-pause` comment. The finalize now goes through the wrapped drain automatically (no code change in `pause()` itself — `rec.stop(reason: .pause)` already wraps).

- [ ] **Step 2: Hook `backgroundSuspend()` to the same drain when recording is active**

Find the existing `public func backgroundSuspend() async` and prepend:

```swift
    if let rec = recording, let pipeline = metalPipeline {
        pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
        _ = await rec.stop(reason: .pause)
        self.recording = nil
        pipeline.onEncodedBufferReady = nil
    }
```

Rationale: §Sequence A in 02-concurrency requires recording to drain before session stop on `.background`. The same `.pause` reason is appropriate — the engine resumes from `.paused` on foreground.

- [ ] **Step 3: Verify the scaffold is retired**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/
```
Expected: **zero hits**.

- [ ] **Step 4: Build**

```bash
bash scripts/build-summary.sh
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-12): retire 10:synchronous-drain-pause; backgroundSuspend during recording drains via wrapped task"
```

---

## Task 5: InteropError.missingOnOverwrite

**Files:** `CameraKit/Sources/CameraKit/Errors.swift`, `CameraKit/Sources/CameraKit/PixelSink.swift`

- [ ] **Step 1: Add the error variant**

In `Errors.swift`:

```swift
public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    case notWired
    case invalidCallbacks
    /// Stage 12 (G-26 quality gate): registerCallback rejected because `onOverwrite == nil`.
    /// The pool cannot silently drop frames with no observability.
    case missingOnOverwrite
}
```

- [ ] **Step 2: Update `ConsumerRegistry.registerCallback`**

In `PixelSink.swift`:

```swift
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) async throws -> ConsumerToken {
        guard callbacks.onOverwrite != nil else {
            throw InteropError.missingOnOverwrite  // G-26 / D-11 quality gate
        }
        // ... existing path that was throwing invalidCallbacks continues, but that branch
        //     is now unreachable because the onOverwrite check short-circuits first.
```

Keep `invalidCallbacks` as the fallback for any other malformed-callback case (e.g. onFrame nil if the registration grows); tests against `invalidCallbacks` from Stage 08 still pass.

- [ ] **Step 3: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/Errors.swift CameraKit/Sources/CameraKit/PixelSink.swift
git commit -m "feat(stage-12): InteropError.missingOnOverwrite (G-26 quality gate)"
```

---

## Task 6: C++ — PixelSinkMetrics header + per-lane overwrite counter

**Files:** `CameraKit/Sources/CameraKitCxx/include/PixelSinkMetrics.h`, `CameraKit/Sources/CameraKitCxx/include/PixelSink.hpp`, `CameraKit/Sources/CameraKitCxx/PixelSinkPool.cpp`

- [ ] **Step 1: Write the header**

```c
// PixelSinkMetrics.h — C-ABI observability surface for the C++ PixelSinkPool.
// Mirrors D-11 aggregation: per-lane mailbox_overwrite_count delivered to Swift at
// FPS_MEASUREMENT_WINDOW_FRAMES cadence.

#ifndef PIXEL_SINK_METRICS_H
#define PIXEL_SINK_METRICS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PixelSinkMetrics {
    uint32_t stream_id;                // 0=natural, 1=processed, 2=tracker (mirrors StreamId)
    uint64_t mailbox_overwrite_count;  // cumulative since registration
} PixelSinkMetrics;

/// Fires asynchronously on the C++ side; marshals into Swift via a thin trampoline.
typedef void (*PixelSinkMetricsCallback)(
    const PixelSinkMetrics* samples,
    uint32_t                count,
    void*                   context
);

/// Error code returned from registerCallbacks when the G-26 quality gate rejects the
/// registration (on_overwrite == NULL). Swift maps this to InteropError.missingOnOverwrite.
#define PIXEL_SINK_MISSING_OVERWRITE (-1001)

#ifdef __cplusplus
}
#endif

#endif // PIXEL_SINK_METRICS_H
```

- [ ] **Step 2: Expose the atomic counters + callback registration in `PixelSink.hpp`**

Within the existing `PixelSinkPool` class:

```cpp
#include "PixelSinkMetrics.h"
#include <atomic>

public:
    // Register a metrics callback that fires every `windowFrames` publications (set from
    // Swift using FPS_MEASUREMENT_WINDOW_FRAMES). Replaces any previously registered cb.
    void registerMetricsCallback(
        PixelSinkMetricsCallback cb,
        void*                    context,
        uint32_t                 windowFrames);

private:
    std::atomic<uint64_t> mailbox_overwrite_count_[kNumStreams] = {};
    std::atomic<uint64_t> publish_count_[kNumStreams] = {};

    PixelSinkMetricsCallback metrics_cb_      = nullptr;
    void*                    metrics_ctx_     = nullptr;
    uint32_t                 metrics_window_  = 30;  // default; overwritten by Swift
```

- [ ] **Step 3: Implement the counter + callback firing in `PixelSinkPool.cpp`**

Inside the existing `publish(stream, buffer)`:

```cpp
    const auto idx = static_cast<size_t>(stream);
    const bool wasOverwrite = (mailbox_[idx].exchange(buffer) != nullptr);
    if (wasOverwrite) {
        mailbox_overwrite_count_[idx].fetch_add(1, std::memory_order_relaxed);
    }
    const auto published = publish_count_[idx].fetch_add(1, std::memory_order_relaxed) + 1;

    // Fire the metrics callback once per `metrics_window_` publications on this lane.
    if (metrics_cb_ && (published % metrics_window_ == 0)) {
        PixelSinkMetrics samples[kNumStreams];
        for (size_t s = 0; s < kNumStreams; ++s) {
            samples[s].stream_id = static_cast<uint32_t>(s);
            samples[s].mailbox_overwrite_count =
                mailbox_overwrite_count_[s].load(std::memory_order_relaxed);
        }
        metrics_cb_(samples, static_cast<uint32_t>(kNumStreams), metrics_ctx_);
    }
```

Add the registration method:

```cpp
void PixelSinkPool::registerMetricsCallback(
    PixelSinkMetricsCallback cb,
    void*                    context,
    uint32_t                 windowFrames)
{
    metrics_cb_     = cb;
    metrics_ctx_    = context;
    metrics_window_ = (windowFrames == 0) ? 30 : windowFrames;
}
```

- [ ] **Step 4: Reject on_overwrite == nullptr in `registerCallbacks`**

Locate the existing `registerCallbacks` implementation; prepend:

```cpp
    if (callbacks.on_overwrite == nullptr) {
        return PIXEL_SINK_MISSING_OVERWRITE;   // Swift maps → missingOnOverwrite
    }
```

- [ ] **Step 5: Expose `registerMetricsCallback` to Swift**

In the existing C-ABI surface (wherever `registerCallbacks` is exported via `extern "C"`), add:

```cpp
extern "C" void
CameraKit_PixelSinkPool_registerMetricsCallback(
    void*                    pool,
    PixelSinkMetricsCallback cb,
    void*                    context,
    uint32_t                 window)
{
    static_cast<PixelSinkPool*>(pool)->registerMetricsCallback(cb, context, window);
}
```

Mirror the declaration in the C header that `CameraKitInterop` imports (the module shim for Swift interop — see how `registerCallbacks` is currently exported and follow that pattern exactly; name the header `PixelSinkMetrics.h` already shown in Step 1, or extend the existing interop header).

- [ ] **Step 6: Build**

```bash
bash scripts/build-summary.sh
```
Expected: BUILD SUCCEEDED. C++ strict-warning pedantry: ensure atomic array initialization compiles on Xcode 16's clang — the `= {}` aggregate-init over `std::atomic<uint64_t>` array is supported from C++17 onward.

- [ ] **Step 7: Commit**

```bash
git add CameraKit/Sources/CameraKitCxx/
git commit -m "feat(stage-12): C++ PixelSinkMetrics — per-lane overwrite counters + metrics callback + G-26 gate"
```

---

## Task 7: ConsumerRegistry.metricsStream() — Swift side

**Files:** `CameraKit/Sources/CameraKit/PixelSink.swift`, `CameraKit/Sources/CameraKit/FrameSet.swift`

- [ ] **Step 1: Confirm `FrameDeliveryStats` shape covers both sides**

Look at the existing `FrameDeliveryStats` in `FrameSet.swift`. It already has:

```swift
public let producedByLane: [StreamId: UInt64]
public let deliveredByLane: [StreamId: UInt64]
public let droppedByLane: [StreamId: UInt64]
public let holdOverBudgetByLane: [StreamId: UInt64]
public let poolExhaustion: UInt64
public let cppOverwriteByLane: [StreamId: UInt64]
```

If `cppOverwriteByLane` is absent, add it and initialize `:[:]` in existing call sites. Log the shape change in state.md if required.

- [ ] **Step 2: Add `metricsStream()` on `ConsumerRegistry`**

```swift
    private var metricsContinuation: AsyncStream<FrameDeliveryStats>.Continuation?
    private var cachedMetricsStream: AsyncStream<FrameDeliveryStats>?

    /// Emits merged Swift + C++ per-lane counters at FPS_MEASUREMENT_WINDOW_FRAMES cadence.
    /// Delta, not cumulative — consumers get the change since the last emission (D-11).
    public func metricsStream() -> AsyncStream<FrameDeliveryStats> {
        if let s = cachedMetricsStream { return s }
        let stream = AsyncStream<FrameDeliveryStats>(
            FrameDeliveryStats.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { c in self.metricsContinuation = c }
        cachedMetricsStream = stream
        return stream
    }
```

- [ ] **Step 3: Register the C callback trampoline**

```swift
    /// Holds the last cumulative snapshot; delta is emitted each window.
    private var lastCumulativeCppOverwrites: [StreamId: UInt64] = [:]

    /// Called after the C++ pool is created (via the existing `wireCpp(poolHandle:)` path;
    /// add if missing). The trampoline is a non-capturing @convention(c) function that
    /// resolves the registry through the `context` pointer.
    public func wireMetrics(cppPoolHandle: OpaquePointer) {
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        CameraKit_PixelSinkPool_registerMetricsCallback(
            cppPoolHandle,
            { samplesPtr, count, ctx in
                guard let samplesPtr, let ctx else { return }
                let registry = Unmanaged<ConsumerRegistry>.fromOpaque(ctx).takeUnretainedValue()
                var cpp: [StreamId: UInt64] = [:]
                for i in 0..<Int(count) {
                    let s = samplesPtr[i]
                    let sid: StreamId
                    switch s.stream_id {
                    case 0: sid = .natural
                    case 1: sid = .processed
                    case 2: sid = .tracker
                    default: continue
                    }
                    cpp[sid] = s.mailbox_overwrite_count
                }
                registry.emitMetricsSnapshot(cppCumulative: cpp)
            },
            unmanaged,
            UInt32(Constants.fpsMeasurementWindowFrames)
        )
    }

    private func emitMetricsSnapshot(cppCumulative: [StreamId: UInt64]) {
        // Compute deltas vs last cumulative.
        state.withLock { inner in
            var deltaCpp: [StreamId: UInt64] = [:]
            for (k, v) in cppCumulative {
                let prior = lastCumulativeCppOverwrites[k] ?? 0
                deltaCpp[k] = v >= prior ? v - prior : 0
                lastCumulativeCppOverwrites[k] = v
            }
            // Snapshot + reset Swift-side drop deltas (dropCounts is already delta-per-window in D-11).
            let swiftDrops = inner.dropCounts
            inner.dropCounts = [:]
            let stats = FrameDeliveryStats(
                producedByLane: [:],
                deliveredByLane: [:],
                droppedByLane: swiftDrops,
                holdOverBudgetByLane: [:],
                poolExhaustion: 0,
                cppOverwriteByLane: deltaCpp
            )
            metricsContinuation?.yield(stats)
        }
    }
```

- [ ] **Step 4: Call `wireMetrics` from the engine**

In `CameraEngine.open()` after the C++ pool is created / the native handle is obtained, fetch the pool pointer and pass it to `consumers.wireMetrics(...)`. If the pool-handle API is already expressed via `getNativePipelineHandle()`, derive from there; otherwise add a small helper exposing the pool pointer.

- [ ] **Step 5: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/PixelSink.swift CameraKit/Sources/CameraKit/FrameSet.swift CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-12): ConsumerRegistry.metricsStream — merges Swift drops + C++ overwrites (D-11)"
```

---

## Task 8: ViewModel + CameraView — live overlay wiring

**Files:** `CameraKit/Sources/CameraKit/ViewModel.swift`, `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Subscribe + bind**

In `ViewModel`:

```swift
    var deliveryStats: FrameDeliveryStats?
    @ObservationIgnored private var metricsTask: Task<Void, Never>?

    // In start() after engine.open():
    metricsTask = Task { [weak self] in
        guard let self else { return }
        for await stats in self.engine.consumers.metricsStream() {
            await MainActor.run { self.deliveryStats = stats }
        }
    }

    // In stop():
    metricsTask?.cancel()
```

- [ ] **Step 2: Populate the long-press overlay in CameraView**

Replace the placeholder `showDeliveryStats` overlay body (stub from Stage 11):

```swift
    @ViewBuilder
    private var deliveryStatsOverlay: some View {
        if showDeliveryStats {
            let s = viewModel.deliveryStats
            VStack(alignment: .leading, spacing: 4) {
                Text("Frame Delivery Stats").font(.caption.bold())
                Divider()
                ForEach(StreamId.allCases, id: \.rawValue) { sid in
                    HStack {
                        Text(sid.rawValue).frame(width: 90, alignment: .leading).font(.caption2.monospaced())
                        Text("drops: \(s?.droppedByLane[sid] ?? 0)").font(.caption2.monospaced())
                        Text("overwrites: \(s?.cppOverwriteByLane[sid] ?? 0)").font(.caption2.monospaced())
                    }
                }
            }
            .padding(10)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
        }
    }
```

Add `.overlay(alignment: .bottomTrailing) { deliveryStatsOverlay.padding(12) }` on the root view (keep DEBUG-only per Stage 11 gating).

- [ ] **Step 3: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/ViewModel.swift CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-12): wire metricsStream to debug delivery-stats overlay"
```

---

## Task 9: Stage12Tests — the 5 TESTABLEs

**Files:** `CameraKit/Tests/CameraKitTests/Stage12Tests.swift`

The `FakeBackgroundTaskHost` scaffold is already in place from Task 2. Extend with the full suite.

- [ ] **Step 1: `12:background-task-drain-produces-finalized-mp4`**

```swift
@Suite("Stage 12 — background drain")
struct Stage12DrainTests {
    @Test("background-task drain finalizes mp4 within budget")
    func backgroundTaskDrainProducesFinalizedMp4() async throws {
        let writer = FakeAssetWriter()      // from Stage10Tests
        let adaptor = FakeAdaptor()
        let host = FakeBackgroundTaskHost()
        var observedStates: [RecordingState] = []
        let rec = Recording(
            clock: FastClock(),             // instant sleep so deadline doesn't fire
            hooks: Recording.Hooks(
                publishState: { observedStates.append($0) },
                emitError: { _ in }
            ),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskHost: host
        )
        let start = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        _ = await rec.submitEncodedBuffer(makeDummyPixelBuffer(), pts: CMTimeMake(value: 0, timescale: 30))
        let uri = await rec.stop(reason: .user)
        #expect(uri == start.uri)
        #expect(host.begins == 1)
        #expect(host.ends == 1)
        // Writer finalized normally (no cancelWriting call from expiration).
        #expect(await writer.cancelled == false || await writer.cancelled == false)
        if case .idle = observedStates.last {} else { Issue.record("final state not idle") }
    }
}
```

- [ ] **Step 2: `12:expiration-handler-cancels-not-finishes`**

```swift
@Test("expiration handler cancels; finishWriting is not called after expiry")
func expirationHandlerCancelsNotFinishes() async throws {
    let writer = FakeAssetWriter()
    // Hang the writer so the expiration has time to fire before finalize completes.
    await writer.setFinishHang(until: .now.advanced(by: .seconds(30)))
    let adaptor = FakeAdaptor()
    let host = FakeBackgroundTaskHost()
    var errors: [CameraError] = []
    let rec = Recording(
        clock: SystemClock(),               // real sleep so deadline *could* fire, but expiry wins
        hooks: Recording.Hooks(
            publishState: { _ in },
            emitError: { errors.append($0) }
        ),
        writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
        backgroundTaskHost: host
    )
    _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
    // Kick off the stop asynchronously, then fire expiration shortly after.
    async let uri = rec.stop(reason: .user)
    try? await Task.sleep(for: .milliseconds(100))
    // Fire the most recent begin's expiration handler.
    host.fireExpiration(identifier: UInt64(host.begins))
    _ = await uri
    #expect(await writer.cancelled == true)
    #expect(errors.contains { $0.code == .recordingTruncated })
    #expect(host.ends == 1)
}
```

- [ ] **Step 3: `12:pixel-sink-registration-without-on-overwrite-rejected`**

```swift
@Test("registerCallback with onOverwrite = nil throws missingOnOverwrite")
func pixelSinkRegistrationWithoutOnOverwriteRejected() async throws {
    let registry = ConsumerRegistry()
    let cbs = PixelSinkCallbacks(
        onFrame: { _ in },
        onOverwrite: nil,
        onError: nil,
        context: nil
    )
    await #expect(throws: InteropError.missingOnOverwrite) {
        _ = try await registry.registerCallback(stream: .natural, callbacks: cbs)
    }
}

@Test("registerCallback with non-nil onOverwrite accepts the registration (or reaches next check)")
func pixelSinkRegistrationWithOnOverwriteProceeds() async throws {
    let registry = ConsumerRegistry()
    let cbs = PixelSinkCallbacks(
        onFrame: { _ in },
        onOverwrite: { _ in },
        onError: nil,
        context: nil
    )
    // Without a wired C++ pool this may still throw a pool-specific error, but it must
    // NOT throw .missingOnOverwrite.
    do {
        _ = try await registry.registerCallback(stream: .natural, callbacks: cbs)
    } catch InteropError.missingOnOverwrite {
        Issue.record("rejected despite valid onOverwrite")
    } catch {
        // any other error acceptable for this assertion
    }
}
```

- [ ] **Step 4: `12:frame-delivery-stats-merges-swift-and-cpp-counters`**

```swift
@Test("metricsStream yields merged swift + cpp counters")
func frameDeliveryStatsMergesSwiftAndCppCounters() async throws {
    let registry = ConsumerRegistry()
    // Inject swift-side drops through a test seam. If no public seam exists, add
    // an internal `_injectSwiftDropForTest(stream:count:)` method on ConsumerRegistry
    // that writes into `inner.dropCounts`.
    registry._injectSwiftDropForTest(stream: .natural, count: 3)
    // Simulate a C++ metrics fire with known cumulative counts.
    registry._simulateCppMetricsForTest(natural: 5, processed: 0, tracker: 2)

    let stream = registry.metricsStream()
    var observed: FrameDeliveryStats?
    for await s in stream {
        observed = s
        break
    }
    #expect(observed?.droppedByLane[.natural] == 3)
    #expect(observed?.cppOverwriteByLane[.natural] == 5)
    #expect(observed?.cppOverwriteByLane[.tracker] == 2)
}
```

Add the two test seams to `ConsumerRegistry`:

```swift
    /// Test-only: add synthetic Swift-side drops.
    func _injectSwiftDropForTest(stream: StreamId, count: UInt64) {
        state.withLock { $0.dropCounts[stream] = ($0.dropCounts[stream] ?? 0) + count }
    }
    /// Test-only: simulate a C++ metrics callback fire without going through the trampoline.
    func _simulateCppMetricsForTest(natural: UInt64, processed: UInt64, tracker: UInt64) {
        emitMetricsSnapshot(cppCumulative: [
            .natural: natural, .processed: processed, .tracker: tracker
        ])
    }
```

- [ ] **Step 5: `12:end-background-task-called-on-all-paths`**

```swift
@Test("endBackgroundTask is called on normal finalize, expiry, and writer-error")
func endBackgroundTaskCalledOnAllPaths() async throws {
    // (a) normal finalize
    do {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let host = FakeBackgroundTaskHost()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskHost: host
        )
        _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        _ = await rec.stop(reason: .user)
        #expect(host.ends == 1)
    }
    // (b) expiration
    do {
        let writer = FakeAssetWriter()
        await writer.setFinishHang(until: .now.advanced(by: .seconds(30)))
        let adaptor = FakeAdaptor()
        let host = FakeBackgroundTaskHost()
        let rec = Recording(
            clock: SystemClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskHost: host
        )
        _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        async let _ = rec.stop(reason: .user)
        try? await Task.sleep(for: .milliseconds(100))
        host.fireExpiration(identifier: UInt64(host.begins))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.ends == 1)
    }
    // (c) writer-error
    do {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let host = FakeBackgroundTaskHost()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskHost: host
        )
        _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        await writer.setStatus(.failed, error: NSError(domain: "test", code: 1))
        _ = await rec.stop(reason: .user)
        #expect(host.ends == 1)
    }
}
```

- [ ] **Step 6: Run the Stage 12 suite + confirm preserved tests**

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage12
bash scripts/test-summary.sh --filter CameraKitTests/Stage10
```
Expected: all Stage 12 TESTABLEs PASS; preserved §9 tests (`10:record-start-stop-happy-path`, `10:recording-truncated-on-deadline`) still PASS.

- [ ] **Step 7: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage12Tests.swift CameraKit/Sources/CameraKit/PixelSink.swift
git commit -m "test(stage-12): 5 TESTABLE tests — background drain, expiry, G-26 gate, stats merge, endBackgroundTask on all paths"
```

---

## Task 10: Wire Stage12Tests + full regression

**Files:** `eva-swift-stitch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add to test target**

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
t = p.targets.find { |x| x.name == 'eva-swift-stitchTests' }
g = p.main_group.find_subpath('CameraKit/Tests/CameraKitTests', true)
f = g.new_reference('CameraKit/Tests/CameraKitTests/Stage12Tests.swift')
t.source_build_phase.add_file_reference(f)
p.save"
```

- [ ] **Step 2: Full regression**

```bash
bash scripts/test-summary.sh --filter "CameraKitTests/Stage"
```
Expected: all Stage 01–12 tests green. Critical preserved: `10:record-start-stop-happy-path`, `10:recording-truncated-on-deadline`.

- [ ] **Step 3: Scaffold acceptance — corpus clean slate**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/        # 0 hits
grep -rn -E '01:|04:|06:|07:|09:|10:|11:|12:' CameraKit/Sources/  # 0 hits
```

- [ ] **Step 4: Commit**

```bash
git add eva-swift-stitch.xcodeproj
git commit -m "test(stage-12): wire Stage12Tests into eva-swift-stitchTests target"
```

---

## Task 11: state.md + HITL stub

**Files:** `CameraKit/state.md`, `measurements/stage-12/observability.md`

- [ ] **Step 1: Prepend Stage 12 section to state.md**

Include:

- `## Current stage` → Stage 12 complete.
- `## Scaffolding still live` → **none**. All corpus scaffolds retired.
- `## What's built — Stage 12 (permanent)`: `BackgroundTaskHost` protocol + `UIApplicationBackgroundTaskHost`; `Recording` drain wrapped in `beginBackgroundTask` with expiration → `cancelWriting`; `PixelSinkMetrics.h` C header; C++ per-lane `mailbox_overwrite_count` atomics + `PixelSinkMetricsCallback`; G-26 gate rejecting `on_overwrite == nullptr` in `registerCallbacks` (C side) and `onOverwrite == nil` in `ConsumerRegistry.registerCallback` (Swift side); `InteropError.missingOnOverwrite` variant; `ConsumerRegistry.metricsStream() -> AsyncStream<FrameDeliveryStats>` merging Swift drops + C++ overwrites at `FPS_MEASUREMENT_WINDOW_FRAMES` cadence; debug delivery-stats overlay live-populated; `backgroundSuspend()`-during-recording routes through the wrapped drain.
- `## Public API exposed so far (Stage 12 additions)`:

```swift
public func metricsStream() -> AsyncStream<FrameDeliveryStats>  // on ConsumerRegistry
public protocol BackgroundTaskHost: Sendable
public final class UIApplicationBackgroundTaskHost: BackgroundTaskHost
```

- `## Manual test evidence — Stage 12`:

| Test ID | Status | Notes |
|---------|--------|-------|
| `12:background-task-drain-produces-finalized-mp4` | PASS | Stage12DrainTests/backgroundTaskDrainProducesFinalizedMp4 |
| `12:expiration-handler-cancels-not-finishes` | PASS | Stage12DrainTests/expirationHandlerCancelsNotFinishes |
| `12:pixel-sink-registration-without-on-overwrite-rejected` | PASS | two @Tests in Stage12Tests |
| `12:frame-delivery-stats-merges-swift-and-cpp-counters` | PASS | Stage12Tests/frameDeliveryStatsMergesSwiftAndCppCounters |
| `12:end-background-task-called-on-all-paths` | PASS | Stage12Tests/endBackgroundTaskCalledOnAllPaths (3 scenarios) |
| `10:record-start-stop-happy-path` (preserved) | PASS | Stage10HappyPathTests |
| `10:recording-truncated-on-deadline` (preserved) | PASS | Stage10HappyPathTests |
| `12:home-button-drain-produces-finalized-mp4-device` | DEFERRED | HITL — `measurements/stage-12/observability.md` |
| `12:debug-overlay-shows-live-overwrite-counts` | DEFERRED | HITL — `measurements/stage-12/observability.md` |

- `## Decisions taken that weren't in briefs — Stage 12`:
  - **`BackgroundTaskHost` abstraction** — not literally named in brief §4; required so `12:background-task-drain-produces-finalized-mp4` / `12:expiration-handler-cancels-not-finishes` can run without `UIApplication.shared` (unit-test headless). Mirrors the `AssetWriting` seam pattern from Stage 10.
  - **`InteropError.missingOnOverwrite` as a new variant rather than repurposing `invalidCallbacks`** — the brief's TESTABLE names the specific variant. `invalidCallbacks` retained for any other malformed-callback case (no existing test references were broken).
  - **Brief §4 says "Sources/CameraKit/Consumer.swift"** — the file is actually `PixelSink.swift`. Edits landed there.
  - **Metrics callback cadence pegged to `FPS_MEASUREMENT_WINDOW_FRAMES` per lane (30) rather than global** — simpler, and matches D-11 wording (one sample per window).
- `## Open questions for next stage`:
  - HITL device evidence for home-button drain + live overlay.

- [ ] **Step 2: Regenerate CONTRACTS.md**

```bash
bash scripts/regen-contracts.sh
```

- [ ] **Step 3: Create HITL stub `measurements/stage-12/observability.md`**

```markdown
# Stage 12 — HITL observability + drain evidence

## 12:home-button-drain-produces-finalized-mp4-device
Device: iPad Pro M1 (iOS 26.x).
- Start recording.
- Press Home within 2–3 seconds.
- Observe that:
  - If within background-task budget → `.mp4` appears in Photos, plays.
  - If budget exceeded → empty file saved (never corrupt MP4 with broken moov).
- Verify `endBackgroundTask` invariant via Instruments (no leaked UIBackgroundTaskIdentifier).
PASS / FAIL: ________
Date: ________

## 12:debug-overlay-shows-live-overwrite-counts
Device: iPad Pro M1 (iOS 26.x).
- Long-press the Resolution label to show the debug overlay.
- Attach a slow subscriber (test harness toggle) on the `.natural` lane.
- Observe overlay updates once per second (FPS_MEASUREMENT_WINDOW_FRAMES / 30Hz).
- Confirm per-lane drops (Swift side) and overwrites (C++ side) both increment under load.
PASS / FAIL: ________
Date: ________
```

- [ ] **Step 4: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md measurements/stage-12/observability.md
git commit -m "docs(stage-12): state.md Stage 12 complete — all scaffolds retired; HITL stubs; regen CONTRACTS"
```

---

## Task 12: Final verification

- [ ] **Step 1: Full build + tests**

```bash
bash scripts/build-summary.sh
bash scripts/test-summary.sh --filter "CameraKitTests/Stage"
```
Expected: BUILD SUCCEEDED + all stages green. Read `.build-logs/*.json` on failure.

- [ ] **Step 2: Device smoke on iPad Pro M1**

- Start 10s recording, home-button mid-stream → confirm `.mp4` in Photos (or empty-not-corrupt file if budget exceeded).
- Force low-memory expiration via a debug harness (`host.fireExpiration(...)` hook) → confirm `cancelWriting` path; file empty; no leaked `UIBackgroundTaskIdentifier`.
- Long-press Resolution → overlay shows non-zero counts when a slow subscriber is attached.
- Record in `measurements/stage-12/observability.md`.

- [ ] **Step 3: Corpus clean-slate check**

```bash
grep -rn -E '01:|04:|06:|07:|09:|10:|11:|12:' CameraKit/Sources/
```
Expected: **zero hits**. The entire scaffold ladder is retired.

- [ ] **Step 4: Instruments sweep**

Time Profiler over a 30s recording with a background excursion (home-button then resume). Verify:
- `endBackgroundTask` called exactly once per `begin`.
- No leaked `UIBackgroundTaskIdentifier`.
- Overlay update cadence matches `FPS_MEASUREMENT_WINDOW_FRAMES` / ~1Hz.

- [ ] **Step 5: Stop. Request user approval before push / merge.**

---

## Self-review

- **Spec coverage:** every §4 file has a task; every §8 TESTABLE has a @Test in Task 9; §9 preserved tests run in Task 10 step 2; §10 acceptance items hit in Tasks 4 step 3 (scaffold retirement), 10 step 3 (corpus clean slate), 12 step 1 (build/tests).
- **Placeholder scan:** every step has concrete code or commands. The two ConsumerRegistry test seams (`_injectSwiftDropForTest`, `_simulateCppMetricsForTest`) are specified in Task 9 step 4 — an executing engineer adds them alongside the test.
- **Type consistency:** `BackgroundTaskHost` shape (Task 2) matches all callers (Tasks 3, 4, 9). `PixelSinkMetrics` C struct (Task 6) matches the Swift trampoline in Task 7. `InteropError.missingOnOverwrite` (Task 5) matches the TESTABLE in Task 9. `FrameDeliveryStats.cppOverwriteByLane` field reused across Tasks 7 + 8 + 9.
- **Stage-ordering guard:** Task 1 halts if `10:synchronous-drain-pause` is missing or any prior scaffold remains.
- **Non-obvious decisions surfaced in state.md:** `BackgroundTaskHost` abstraction, `PixelSink.swift` vs brief's `Consumer.swift` naming, `missingOnOverwrite` as new variant, per-lane metrics cadence pegged to `FPS_MEASUREMENT_WINDOW_FRAMES`.
