# First-Principles Design: Camera → Stitcher Frame Interface

**Status:** design exploration. No existing code consulted; derived purely from the brief
and current Swift 6.2+ practice (strict concurrency, `Sendable`, `AsyncStream`/`AsyncSequence`,
actors, C++ interop).

**Scope:** the *output* API of a live camera package (the **producer**) and the *input* API of
a C++-backed mosaic/stitching app (the **consumer**), such that two derived image lanes flow
across the thread boundary seamlessly under Swift 6 data-race safety.

---

## 1. The core tensions

Four forces collide here. Every candidate design is really a different way of resolving them.

1. **Push vs pull.** The camera is a *live push source*: frames arrive at ~30 fps whether or
   not anyone reads them, and the hardware **cannot be back-pressured**. The consumer is a
   *pull* system on the expensive lane: the C++ aligner asks for the next processed frame only
   when its single worker thread frees up (every ~300 ms, variably). A push producer feeding a
   pull consumer needs an explicit *impedance buffer* whose overflow policy is a first-class
   design choice, not an accident.

2. **Dual-rate, opposite drop policies.** The two lanes derived from the same instant want
   contradictory things:
   - **Tracker lane** (~480×480 BGRA ≈ 0.9 MB): feeds a cheap motion estimator that must see
     **every frame** (lossless, ~30 fps). Missing frames degrade motion integration.
   - **Processed lane** (~1440×1440 BGRA ≈ 8 MB): feeds the expensive ECC aligner. Consumed at
     a **low, variable** rate; when the engine frees up it wants the **newest** frame
     (latest-wins), never a stale queued one.

   A single uniform transport/policy *cannot* serve both well — see the asymmetry argument in §2.

3. **Lifetime / ownership of pooled GPU buffers.** Output pixels live in a small, fixed pool of
   reference-counted, IOSurface-style buffers. Pixels are valid only while a buffer is alive and
   only *after* GPU rendering completes. Holding a buffer too long **starves the pool and stalls
   capture** — the producer's only relief valve is to drop. The consumer holds a processed frame
   for ~300 ms of C++ work. So buffer return must be **deterministic**, and "hold zero-copy" vs
   "copy out" is a genuine tradeoff that *differs per lane*.

4. **Cross-lane correlation.** The motion estimate computed on tracker frame *N* must later seed
   the aligner when processed frame *N* is finally processed — which may be many frames later.
   The consumer needs to look up "the motion state at capture index *N*." This is a *temporal
   join* keyed by a stable capture identity, living entirely on the consumer side.

### The asymmetry that drives the recommendation

The two lanes pull copy-vs-hold in **opposite** directions, and this is the load-bearing
observation of the whole document:

- **Lossless + zero-copy-hold + small fixed pool is mutually impossible.** A lossless queue of
  *pooled* buffers pins one pool slot per queued frame; at 30 fps with any consumer jitter the
  queue grows and pins every slot, and capture stalls. For the tracker lane the frame is *small*
  (0.9 MB), so **copying the bytes out** dissolves the contradiction entirely: the pool slot is
  released immediately, the copy is trivially `Sendable`, and the lossless queue holds plain
  value data the pool never misses.

- **Latest-wins + large frame ⇒ zero-copy hold pays off.** The processed frame is *large* (8 MB);
  copying it every frame at 30 fps is ~240 MB/s of pure memcpy for frames that are mostly
  dropped. Latest-wins bounds the number of simultaneously-pinned processed buffers to ~1–2
  (the one being processed + the newest waiting), which a pool can be explicitly sized for. So
  **hold the processed buffer zero-copy** and return it deterministically when C++ finishes.

A uniform "copy everything" design wastes 8 MB/frame on the lane that mostly drops its frames.
A uniform "hold everything" design starves the pool on the lossless lane. **The right answer is
asymmetric**, and it falls out of arithmetic, not taste. The three candidates below are built so
that exactly one embraces this asymmetry; the other two are coherent alternatives that each fail
on one side of it, which makes the rejection rationale concrete.

### Invariants every candidate must honor (from first principles)

- **No reverse dependency (point 7).** The producer publishes a concrete `Sendable` frame type
  and knows nothing of the stitcher. The `FrameSource` abstraction — which must also serve file
  and on-disk-replay inputs — lives **consumer-side**. A thin `CameraFrameSource` adapter bridges
  producer → `FrameSource`. The producer never conforms to a consumer protocol.
- **Producer can always drop, never block.** Because the camera can't be back-pressured, every
  hold path needs an explicit *pool-exhausted → drop newest-into-pool / drop-incoming* branch.
  The producer's public surface must make "this frame was dropped" observable (gap in capture
  index) rather than silently stalling capture.
- **Deterministic buffer return.** A held pooled buffer returns its slot via a `deinit` on a
  `final class` lease *or* an explicit `release()` / `withPixels { }` scope — never vague ARC
  timing while C++ holds it. ARC *triggers* the return, but the lease type makes the moment
  precise and single-owner.
- **Correlation is consumer-side (point 3).** The producer only stamps each frame with a
  `Sendable` metadata value `{captureIndex, timestamp, settled}`. The consumer maintains the
  `captureIndex → MotionState` table in an actor.
- **The "single reader" `@unchecked Sendable` invariant survives the *second* consumer.** The brief
  states the processed lane is *also* consumed by an unrelated Flutter preview app. Two zero-copy
  readers of one pooled buffer would break the single-reader justification *and* double pool
  pressure. Resolution: each lane is vended **per-consumer**, and the **preview consumer always
  gets a copy** (preview tolerates copies and drops freely), while only the **stitcher** keeps the
  zero-copy single-reader hold on the processed lane. So the `@unchecked Sendable` lease is sound
  precisely because the buffer it wraps has exactly one zero-copy reader by construction; any
  additional consumer is served a copy, never the same lease.

---

## 2. Shared vocabulary (used by all three candidates)

These producer-side value types are common to every candidate; the candidates differ in how
frames are *transported* and *owned*, not in what a frame's identity is.

```swift
import CoreMedia
import Synchronization

/// Stable identity + attestation for one captured instant. Trivially Sendable (all value types).
/// Published by the producer; the producer depends on nothing downstream.
public struct CaptureStamp: Sendable, Hashable {
    /// Monotonic per session; resets on session open. Gaps mean frames were dropped.
    public let index: UInt64
    /// Capture-time presentation timestamp (the instant, not the delivery time).
    public let timestamp: CMTime
    /// AE/AWB/AF have converged for this frame.
    public let settled: Bool
}

/// Self-describing pixel layout for the C++ engine (point 5). Pure value type, Sendable.
/// Does NOT own memory — it describes whatever buffer currently backs a frame.
public struct PixelLayout: Sendable, Hashable {
    public enum Format: Sendable { case bgra8 }
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int       // row stride; may exceed width*4 for alignment
    public let format: Format
}

public enum Lane: Sendable { case tracker, processed }
```

For Sendable crossing (point 5) there are exactly three tools, and each candidate picks per lane:

- **(A) Copied bytes** — a value type owning a `[UInt8]` / `UnsafeMutableRawBufferPointer`;
  trivially `Sendable`, no pool coupling. Used for the small tracker lane.
- **(B) `sending` single-owner transfer** — a non-`Sendable` lease moved across isolation via a
  `sending` parameter (SE-0430); the compiler proves the sender relinquishes it. Good when there
  is exactly one consumer of the lane.
- **(C) `@unchecked Sendable` `final class` lease** — an IOSurface-backed handle that is safe to
  read concurrently *because the producer guarantees the GPU finished and there is a single
  reader*; documented, not hand-waved. Used for zero-copy holds shared past `sending`'s reach.

---

# Candidate A — Dual `AsyncSequence` lanes, copy-out everywhere

**Primary stance: push, expressed as two independent `AsyncStream`s; uniform copy-out so frames
are plain `Sendable` values and the pool is never held.**

### Producer-side API

The producer is an `actor` owning the session; it exposes two `AsyncStream`s plus a status
channel. Each emitted frame already owns a heap copy of its pixels — the pool slot is released
the instant the bytes are copied, so no consumer pace can starve capture.

```swift
/// An owned copy of one frame. Trivially Sendable: `[UInt8]` is a value type, no pool coupling.
/// (Storing a raw buffer pointer here would NOT be Sendable without `@unchecked`; the whole point
/// of copy-out is that the copied *representation* is a plain value, so we use `[UInt8]`.)
public struct OwnedPixels: Sendable {
    public let stamp: CaptureStamp
    public let layout: PixelLayout
    public let bytes: [UInt8]                  // owned copy; freed by ARC, no deinit needed
}

public enum SessionStatus: Sendable {
    case running
    case ended                      // graceful close
    case failed(CameraError)        // disconnect / hardware error
}

public actor CameraSession {
    public func open() async throws
    public func close() async

    /// Lossless intent: unbounded-ish buffering policy, but values are cheap copies.
    public func trackerFrames() -> AsyncStream<OwnedPixels>
    /// Latest-wins intent: bufferingPolicy .bufferingNewest(1).
    public func processedFrames() -> AsyncStream<OwnedPixels>

    /// Separate status channel so a lane-side parked consumer still learns of failure (point 6).
    public func status() -> AsyncStream<SessionStatus>
}
```

The latest-wins behavior is expressed directly in the stream construction:

```swift
// inside the actor, on the delivery path:
processedContinuation.yield(OwnedPixels(copyOut(buffer)))   // continuation built with
                                                            // .bufferingNewest(1)
trackerContinuation.yield(OwnedPixels(copyOut(buffer)))     // built with .unbounded
```

### Consumer-side API

The consumer's `FrameSource` abstraction (point 7) yields the same `OwnedPixels`, so camera,
file, and replay are interchangeable. The C++ engine reads the pixels via
`bytes.withUnsafeBytes { … }` — the bytes are a private value-type copy, valid for the lifetime of
the `OwnedPixels` value the consumer holds.

```swift
public protocol FrameSource: Sendable {            // lives consumer-side
    func trackerFrames() -> AsyncStream<OwnedPixels>
    func processedFrames() -> AsyncStream<OwnedPixels>
    func status() -> AsyncStream<SessionStatus>
}

struct CameraFrameSource: FrameSource {            // thin adapter, no reverse dep
    let session: CameraSession
    func trackerFrames() -> AsyncStream<OwnedPixels> { session.trackerFrames() }
    // …
}

@MainActor final class StitcherCoordinator {
    let motion = MotionTable()                     // actor, see §correlation
    let engine = StitchEngineProxy()               // actor fronting the C++ worker

    func run(_ source: some FrameSource) {
        Task { for await f in source.trackerFrames() {            // every frame
            let m = await engine.estimateMotion(f)                // cheap, ~30 fps
            await motion.record(index: f.stamp.index, m)
        } }
        Task { for await f in source.processedFrames() {          // newest only
            let seed = await motion.lookup(index: f.stamp.index)
            await engine.alignAndBlend(f, seededBy: seed)         // ~300 ms; holds the copy
        } }
        Task { for await s in source.status() { handle(s) } }
    }
}
```

### How A handles the 7 points

1. **Push/pull:** push streams; the latest-wins `AsyncStream` policy on the processed lane *is*
   the impedance buffer. Pull is implicit (the consumer's `for await` cadence).
2. **Dual-rate:** tracker stream `.unbounded`, processed stream `.bufferingNewest(1)`.
3. **Correlation:** stamps carried per frame; `MotionTable` actor joins by index.
4. **Lifetime:** *moot* — pool slot is freed at copy time; consumer holds a heap copy, no pool
   coupling at all. Cannot starve the pool.
5. **Sendable crossing:** option (A) everywhere; `OwnedPixels` is `Sendable` by construction.
6. **Error/EOS:** dedicated `status()` channel; lane streams also finish on `.ended`/`.failed`.
7. **Layering:** `FrameSource` is consumer-side; producer publishes `OwnedPixels` only.

**Why this is a real alternative:** it bets that correctness-by-construction (everything is a
plain value) is worth a uniform copy cost. It is the simplest to reason about under strict
concurrency — there is no lease, no pool back-pressure, nothing `@unchecked`.

---

# Candidate B — Pull-first `FrameSource` with a latest-wins box + lossless ring; zero-copy holds via leases

**Primary stance: pull. The producer pushes into two consumer-shaped holding structures (a
latest-wins atomic box for processed, a bounded lossless ring for tracker); the consumer *pulls*
`next()` from each. Frames are zero-copy pooled buffers wrapped in deterministic leases.**

This is the inversion of A: instead of the producer driving `yield`, the consumer drives `next()`,
and the holding structures absorb the rate mismatch explicitly.

### Producer-side API

The producer still owns the session and the pool, but instead of streams it owns two *handoff
structures* and hands the consumer a pull handle. A frame is a **lease**: a `final class` whose
`deinit` returns the pooled slot.

```swift
/// Zero-copy view of a live pooled buffer. NOT Sendable on its own — crosses via the lease.
public struct FrameView {
    public let stamp: CaptureStamp
    public let layout: PixelLayout
    public let base: UnsafeRawPointer      // valid only while the owning lease is alive
}

/// Deterministic, single-owner lease over one pooled buffer.
/// @unchecked Sendable: the producer guarantees GPU completion before vending, and the
/// handoff structures guarantee a single consumer reads it (option C, documented).
/// INVARIANT (see "Second consumer" below): exactly one zero-copy reader per pooled buffer.
public final class FrameLease: @unchecked Sendable {
    public let view: FrameView
    private let onRelease: @Sendable () -> Void     // returns the pool slot
    init(_ v: FrameView, onRelease: @escaping @Sendable () -> Void) {
        self.view = v; self.onRelease = onRelease
    }
    deinit { onRelease() }                          // slot returns when C++ + Swift both drop it
}

public protocol FramePull: Sendable {
    /// Suspends until a frame is available or the session ends. Tracker = lossless ring;
    /// processed = latest-wins box (returns the newest, discarding older pinned buffers).
    func next() async throws -> FrameLease?          // nil == graceful end-of-stream
}

public actor CameraSession {
    public func open() async throws
    public func close() async
    public func pull(_ lane: Lane) -> any FramePull
}
```

Internals — the two holding structures, both built so the **producer drops, never blocks**:

- **Processed = latest-wins box.** A `Mutex<FrameLease?>` (iOS 18+ `Synchronization`). On delivery
  the producer swaps in the newest lease; the *displaced* lease is released immediately, returning
  its pool slot. At most ~1–2 processed slots pinned (newest waiting + one being processed) — pool
  sized for exactly that.
- **Tracker = bounded copy ring (lossless under bounded jitter).** Because lossless + pooled-hold
  starves the pool (§1), the tracker ring stores *copies* (0.9 MB each), not leases. The "lease"
  returned for the tracker lane wraps owned `[UInt8]` bytes whose `deinit` frees the copy, so the
  consumer API is uniform even though the backing differs per lane. The ring is sized for expected
  consumer jitter so it is lossless in steady state; under *sustained* overrun the producer drops
  the *oldest* and records the gap (consumer sees an index jump). Dropping the oldest is the wrong
  end for a motion integrator — see the tradeoff note below; ring sizing is the mitigation.

### Consumer-side API

`FramePull` *is* the `FrameSource` abstraction (point 7) — file and replay sources implement the
same `next()` and simply never drop. The consumer pulls at its own pace:

```swift
public protocol FrameSource: Sendable {            // consumer-side
    func pull(_ lane: Lane) -> any FramePull
    func status() -> AsyncStream<SessionStatus>
}

@MainActor final class StitcherCoordinator {
    func run(_ source: some FrameSource) {
        let tracker = source.pull(.tracker)
        let processed = source.pull(.processed)

        Task { while let lease = try await tracker.next() {       // pulls every frame
            let m = await engine.estimateMotion(lease.view)       // synchronous C++ read
            await motion.record(index: lease.view.stamp.index, m)
        } }                                                       // lease deinits -> copy freed

        Task { while let lease = try await processed.next() {     // pulls newest when free
            let seed = await motion.lookup(index: lease.view.stamp.index)
            await engine.alignAndBlend(lease, seededBy: seed)     // holds lease ~300ms
        } }                                                       // lease deinits -> pool slot returns
    }
}
```

Crossing into C++ (point 5): `alignAndBlend` calls a `nonisolated` synchronous shim that passes
`lease.view.base` + `layout` into the engine; the lease is held by the actor for the call's
duration and **must not cross an `await`** while the raw pointer is in use (C++ interop rule:
never hold a raw pointer across suspension). The lease object itself is `Sendable`; the pointer
inside is used only synchronously.

### How B handles the 7 points

1. **Push/pull:** explicitly pull — `next()` is the consumer's pace. The holding structures are
   the impedance buffer, with policy baked into each structure.
2. **Dual-rate:** processed = `Mutex`-backed latest-wins box; tracker = bounded lossless ring.
3. **Correlation:** stamp on each `FrameView`; `MotionTable` actor.
4. **Lifetime:** deterministic via `FrameLease.deinit`. Processed lane holds zero-copy (pool
   sized for ~2); tracker lane backs the lease with copies (no pool pinning). Pool-exhausted →
   producer drops + records gap.
5. **Sendable crossing:** processed = option (C) documented `@unchecked Sendable` lease (single
   reader, GPU-complete); tracker = option (A) copies behind the same lease type.
6. **Error/EOS:** `next()` returns `nil` on graceful end, `throws` on failure — failure reaches
   *whichever* lane is being pulled. A `status()` channel still broadcasts for UI.
7. **Layering:** `FramePull`/`FrameSource` is consumer-side; file/replay implement the same pull
   contract; producer publishes `FrameLease` + `FrameView` only.

**Why this is a real alternative:** it matches the consumer's actual shape — a single C++ worker
that *asks* for the next frame — so there is no producer-driven task fighting the worker's cadence.
The cost is that the producer must own consumer-shaped holding structures, blurring the boundary
slightly, and a stuck/slow puller on the tracker ring quietly drops the oldest rather than the
newest, which is the wrong end for a motion integrator (mitigated by ring sizing).

---

# Candidate C — Single unified push callback delivering a correlated *frame pair*, zero-copy leases both lanes

**Primary stance: push via a `nonisolated` delegate callback that delivers **both lanes of one
capture together** as a single correlated unit; both lanes are zero-copy leases. Correlation is
solved at the source (the pair is born together) instead of re-joined downstream.**

This is architecturally distinct from A and B on two axes: the lanes are **unified** (one
callback, one object) rather than two independent transports, and delivery is a raw
`nonisolated` callback on the delivery queue rather than an `AsyncSequence` or a pull handle.

### Producer-side API

```swift
/// Both lanes of a single capture instant, each a zero-copy lease. The pair shares one stamp.
public final class FramePair: @unchecked Sendable {
    public let stamp: CaptureStamp
    public let tracker: FrameLease           // small lane
    public let processed: FrameLease         // large lane
    // Releasing either lease returns its own pool slot independently.
}

public protocol FrameSink: AnyObject, Sendable {
    /// Called on the delivery queue, GPU render already complete. MUST return fast.
    /// The sink decides per-lane what to retain; unretained leases free immediately.
    func didDeliver(_ pair: sending FramePair)
    func didChangeStatus(_ status: SessionStatus)
}

public actor CameraSession {
    public func open() async throws
    public func close() async
    public func setSink(_ sink: any FrameSink)     // single sink; nonisolated delivery
}
```

The callback is the classic push primitive. The `sending FramePair` (SE-0430) transfers ownership
into the sink so the compiler proves the producer no longer touches it after handoff — the cleanest
possible Sendable story for a single-consumer push. The sink is expected to immediately *route*
each lane to the right downstream structure and drop what it doesn't want.

### Consumer-side API

The consumer implements `FrameSink` and *fans out* the unified callback into its two internal
paces, applying the drop policies itself. This is the key move: the **producer stays policy-free**
(it just delivers pairs); the **consumer owns both drop policies** because only it knows its
engine's state.

```swift
final class StitcherSink: FrameSink {
    let trackerStream: AsyncStream<FrameLease>.Continuation   // .unbounded (lossless intent)
    let latestProcessed = Mutex<FrameLease?>(nil)             // latest-wins box
    let processedSignal: AsyncStream<Void>.Continuation       // wakes the puller

    func didDeliver(_ pair: sending FramePair) {
        // Tracker: copy-out into the lossless stream (small; never pins the pool).
        trackerStream.yield(copyLease(pair.tracker))          // pair.tracker slot frees here
        // Processed: latest-wins; displaced lease released immediately (returns its pool slot).
        latestProcessed.withLock { $0 = pair.processed }      // zero-copy hold
        processedSignal.yield(())
    }
    func didChangeStatus(_ s: SessionStatus) { /* forward */ }
}
```

The engine drives two loops: the tracker loop consumes the lossless stream every frame; the
processed loop, when the C++ worker frees up, *takes* the current latest lease from the box,
processes it (~300 ms holding zero-copy), then releases it. Because the box only ever holds the
newest, the pool pins ~1–2 processed slots regardless of how slow the worker is.

`FrameSource` (point 7) still exists consumer-side as the abstraction the engine consumes; the
camera's `StitcherSink` is one implementation that *adapts a push callback into* the two internal
streams, while a file reader implements `FrameSource` by pushing pairs at its own cadence. The
sink/adapter is the seam where push becomes the consumer's preferred shape.

### How C handles the 7 points

1. **Push/pull:** push at the boundary (callback); the consumer converts to its own pull internally
   in the sink (latest-wins box + lossless stream). The conversion point is explicit and owned by
   the consumer.
2. **Dual-rate:** the sink applies *both* policies in one place — copy-out tracker, latest-wins
   box for processed — using its own knowledge of engine state.
3. **Correlation:** *strongest here* — both lanes arrive in one `FramePair` sharing one `stamp`, so
   the pairing is structural at birth. The `MotionTable` is still needed because the *processed*
   frame for index N is consumed much later than the *tracker* frame for N, but the pair guarantees
   the two lanes of the *same* instant are never mismatched.
4. **Lifetime:** independent per-lane `FrameLease.deinit`; tracker copied-out in the callback
   (pool freed immediately), processed held zero-copy in the box (pool sized ~2). Pool-exhausted →
   producer drops the whole pair, recording the gap.
5. **Sendable crossing:** `sending FramePair` transfers cleanly (option B at the boundary); the
   held processed lease is option (C) `@unchecked Sendable` once parked in the `Mutex`.
6. **Error/EOS:** delivered via the same sink (`didChangeStatus`), so it cannot get stuck behind a
   lane — there is only one delivery channel.
7. **Layering:** the producer defines `FrameSink` (a *producer-side* protocol the consumer
   implements — note: this is the producer publishing a callback contract, not depending on a
   consumer type, so the no-reverse-dependency rule holds). `FrameSource` remains the consumer-side
   abstraction for file/replay.

**Why this is a real alternative:** it is the only candidate that treats the two lanes as one
correlated unit and pushes the *entire* drop-policy decision into the consumer's sink, where engine
state actually lives. The callback is also the lowest-latency delivery primitive (no stream/actor
hop on the hot path). The cost: a `nonisolated` callback that "must return fast" is the easiest
place to accidentally do too much work or hold the delivery queue, and unifying the lanes couples
their delivery (a backlog on one is felt as pressure to drain the callback quickly for both).

---

## 3. Correlation mechanism (shared by all three)

Independent of transport, correlation (point 3) is a consumer-side temporal join keyed by
`CaptureStamp.index`:

```swift
actor MotionTable {
    private var byIndex: [UInt64: MotionState] = [:]
    private var order: [UInt64] = []                  // bounded ring of recent indices
    private let capacity = 256                         // ~8 s at 30 fps; covers worst-case lag

    func record(index: UInt64, _ m: MotionState) {
        if byIndex[index] == nil { order.append(index) }
        byIndex[index] = m
        if order.count > capacity {
            let evicted = order.removeFirst()
            byIndex[evicted] = nil
        }
    }
    /// Newest motion at-or-before `index` if the exact frame was dropped (gaps are expected).
    func lookup(index: UInt64) -> MotionState? {
        byIndex[index] ?? order.last(where: { $0 <= index }).flatMap { byIndex[$0] }
    }
}
```

The bounded ring is essential: the processed lane lags the tracker lane by many frames, so the
table must retain enough history to seed a late processed frame, but not grow unbounded. `lookup`
tolerates index gaps (dropped frames) by falling back to the nearest earlier motion state.

---

## 4. Comparison across the 7 design points

| # | Point | A — Dual `AsyncStream`, copy-out | B — Pull `FramePull` + box/ring, leases | C — Unified push `FramePair`, leases |
|---|-------|----------------------------------|------------------------------------------|--------------------------------------|
| 1 | Push vs pull | Push streams; pull implicit via `for await` cadence | **Explicit pull** (`next()`); impedance in holding structs | Push callback → consumer converts to pull in sink |
| 2 | Dual-rate / drop policy | `.unbounded` vs `.bufferingNewest(1)` on two streams | Bounded copy ring (lossless under bounded jitter; drops oldest + gap on sustained overrun) vs `Mutex` latest-wins box | Sink applies both policies in one place |
| 3 | Correlation | Stamps + `MotionTable` (re-join) | Stamps + `MotionTable` (re-join) | **Structural** — pair born together; `MotionTable` only for lag |
| 4 | Buffer lifetime / pool | No pool coupling (always copies); cannot starve | Processed zero-copy (pool≈2); tracker copied; lease `deinit` | Processed zero-copy; tracker copied; per-lane lease `deinit` |
| 5 | Sendable crossing | (A) copies only — simplest, nothing `@unchecked` | (C) `@unchecked` lease (processed) + (A) copies (tracker) | (B) `sending` pair at boundary + (C) `@unchecked` parked lease |
| 6 | Error / EOS | Separate `status()` + stream finish | `next()` throws/`nil` on the pulled lane + `status()` | Single sink channel (`didChangeStatus`) — never stuck |
| 7 | Layering / `FrameSource` | `FrameSource` consumer-side; adapter wraps streams | `FramePull` *is* the source contract; clean for file/replay | Producer publishes `FrameSink`; `FrameSource` stays consumer-side |
| — | **Copy cost** | ~240 MB/s wasted on mostly-dropped processed lane | Minimal — large lane zero-copy | Minimal — large lane zero-copy |
| — | **Hot-path latency** | Two actor/stream hops | One holding-struct write + pull wake | Lowest — direct `nonisolated` callback |
| — | **Strict-concurrency risk** | Lowest (all values) | Medium (one documented `@unchecked`) | Highest (`nonisolated` callback + unified coupling) |

---

## 5. Recommendation

**Adopt Candidate B — the pull-first `FrameSource` with per-lane asymmetric ownership.** This is a
clean choice of one of the three stances, not a synthesis: B's transport and ownership are taken as
written. The recommendation is opinionated about *why* B's per-lane asymmetry is the right resolution
of §1's tensions:

- **Tracker lane → copy-out into a bounded lossless ring** (Candidate A/B tracker backing). The
  frame is 0.9 MB; copying makes it trivially `Sendable`, frees the pool slot instantly, and lets
  the ring be genuinely lossless without pinning pool buffers. This is the *only* way to satisfy
  "lossless + small fixed pool" simultaneously.
- **Processed lane → zero-copy `FrameLease` held in a latest-wins `Mutex` box**, returned
  deterministically by `deinit` when the C++ worker finishes (~300 ms). Latest-wins bounds pinned
  buffers to ~2, which the pool is explicitly sized for, and avoids ~240 MB/s of pointless memcpy
  on a lane that mostly drops.
- **Pull-first `FrameSource`/`FramePull`** as the consumer abstraction (Candidate B), because the
  C++ engine genuinely *asks* for its next frame; a pull contract also makes file and replay
  sources fall out naturally (they implement `next()` and never drop).

**Why B's stance over A and C:**

- **vs A (uniform copy):** A is the safest under strict concurrency and the simplest to reason
  about, but it pays an 8 MB copy per processed frame for frames the engine mostly discards —
  ~240 MB/s of memcpy bandwidth and cache pollution on the device's hottest path, to copy data
  that is thrown away. A's failure mode is *throughput*: it does not starve the pool, but it burns
  memory bandwidth that the GPU pipeline and ECC aligner need. The asymmetric design keeps A's
  copy *only* where it is cheap and dissolves a real contradiction (the tracker lane).
- **vs C (unified push callback):** C has the best correlation story and the lowest latency. Its
  structural `FramePair` is genuinely attractive, but it is *not* needed here: the processed frame
  for index N is consumed long after tracker frame N, so the consumer must keep a `MotionTable`
  to bridge that lag in *any* design — and once you have the table, a re-join by index gives the
  same correctness without coupling the two lanes' delivery. So B deliberately uses re-join, not
  C's pairing. C's `nonisolated` "must return fast" callback is also the classic place
  to accidentally stall the delivery queue, and unifying the two lanes into one `FramePair`
  couples their delivery — a tracker backlog applies pressure to drain the processed lane and vice
  versa, which is exactly the cross-lane coupling the dual-rate requirement wants to avoid. C's
  failure mode is *operational fragility*: it works beautifully until someone does one frame's
  worth of extra work in `didDeliver` and wedges capture. B keeps the lanes independent and the
  consumer's pull cadence off the delivery queue.

**The recommended design therefore:**

1. Producer (`CameraSession` actor) delivers frames internally; vends per-lane `FramePull`
   handles. Tracker pull is backed by a copy ring; processed pull by a latest-wins lease box.
2. Frames are `FrameLease` (`final class`, `deinit` returns the slot). Processed leases are
   `@unchecked Sendable` with a documented single-reader + GPU-complete invariant; tracker leases
   wrap owned copies.
3. Producer always drops on pool exhaustion and records the gap in `CaptureStamp.index`; never
   blocks capture.
4. Consumer joins lanes via `MotionTable` keyed by `index`, with gap-tolerant `lookup`.
5. Errors/EOS propagate through `next()` (throw / `nil`) *and* a broadcast `status()` channel so a
   consumer parked on one lane still learns of failure.
6. C++ crossing reads `FrameView.base` + `PixelLayout` synchronously inside a `nonisolated` shim;
   the raw pointer never crosses an `await`.

### Failure modes of the rejected options (summary)

- **Candidate A** — *bandwidth waste*: 8 MB × ~30 fps of copies for frames that are mostly
  dropped; correct and simple but throughput-hostile on a device pipeline already contending for
  memory bandwidth.
- **Candidate C** — *delivery-queue fragility + lane coupling*: a `nonisolated` callback that must
  return fast is easy to overload and wedge capture, and bundling both lanes into one delivery
  unit couples their independent rates. Its correlation and policy-ownership ideas are worth
  keeping; its transport is not.
- **A uniform zero-copy-hold design** (not given its own section, but the tempting fourth option)
  — *pool starvation*: a lossless queue of pooled tracker buffers pins one slot per queued frame
  and stalls capture under any consumer jitter. This is precisely the contradiction the asymmetric
  recommendation dissolves by copying the small lane.

---

## 6. Assessment (coordinator review, against the real codebases)

This document was produced blind (no source read). Reviewed against the two actual
codebases (CameraKit's `FrameSet`/`ConsumerRegistry` and the stitcher's
`FrameSource`/`FramePrefetchQueue`), it holds up well. Notes:

**Strongest independent contribution — the size-driven copy/hold asymmetry (§1, §5).**
The hand-written analysis in `feeding-evascan-framesource.md` framed copy-vs-hold as an
undecided *fork* for the processed lane. This document is sharper: the answer is
**asymmetric per lane and falls out of arithmetic** — copy the small tracker lane
(0.9 MB; the only way to get lossless without pinning a fixed pool), hold the large
processed lane zero-copy (8 MB; copying it at 30 fps is ~240 MB/s for mostly-dropped
frames). A uniform policy provably fails on one side. This is the better framing and is
adopted.

**Convergences with the code-grounded analysis** (independently reached): consumer-side
correlation table keyed by capture index with gap-tolerant lookup; `final class` lease
with `deinit` for deterministic pool-slot return; self-describing `PixelLayout`
(width/height/**bytesPerRow**/format — naturally avoiding the real `stride = width*4` bug
in `FramePrefetchQueue`); per-lane differing drop policy; no reverse dependency, with
`FrameSource` staying consumer-side.

**Blind spots (only code-reading surfaces these; the designs avoid them anyway):**
`CaptureMetadata` is currently stubbed, so `settled` is a plumbing task, not a free field;
the error channel is *currently* split (frames finish silently on camera failure) — this
doc correctly *designs* a unified one; `FrameSet` is gratuitously `Hashable`.

**The live divergence — explicit pull (this doc's B) vs a per-lane `AsyncSequence<Frame>`
(the coordinator's lean).** Both are "push-fed, pull-consumed." The real difference is not
whether `next()` exists (it does on both) but: (1) `AsyncStream.yield` never blocks, so it
offers only *drop* policies — a custom `FrameSource.next()` protocol lets each source choose
its discipline, so the **same protocol serves the drop-only live camera *and* the
lossless-blocking file/replay sources** the stitcher also needs (this is exactly what the
existing `FrameSource.prefersLatestWins` flag encodes); (2) a custom holding structure
returns a displaced pooled lease's slot at a **deterministic** instant under your own lock,
where `AsyncStream`'s buffer-release timing is opaque — which matters with a tiny fixed pool.
Given the single C++ worker that genuinely *asks* for its next frame and the multi-source
requirement, **B's explicit-pull stance is the more persuasive of the two** and is the
recommended target. See the concept breakdown appended to the chat thread / the companion
doc for why this is a real distinction and not just `AsyncStream` under another name.

## 7. Refinement — back the protocol with AsyncStream where it fits (do NOT hand-roll the box/ring)

Candidate B as written proposes a hand-rolled `Mutex<FrameLease?>` latest-wins box and a
bounded ring. That is over-engineering and the wrong risk trade: **the `FrameSource.next()`
protocol is the seam; each producer backs it with whatever is simplest/safest, and the
sources have different natures.**

- **Camera processed lane** (push, latest-wins) → back with `AsyncStream(.bufferingNewest(1))`.
  This is the *tested status quo* — CameraKit already delivers lanes this way
  (`ConsumerRegistry.subscribe`), already counting drops. The adapter's `next()` is just
  `await iterator.next()`.
- **Camera tracker lane** (push, lossless, small) → `AsyncStream` storing **copies**
  (`OwnedPixels`), so no pool pinning; pick the buffering policy for jitter tolerance.
- **File / replay** (pull-native, lossless, blocking) → `next()` = *decode one frame on
  demand*. No `AsyncStream`, no buffer, no concurrency primitive at all — inherently lossless
  and back-pressured because work happens only when asked.

This is B's protocol + lifetime model (`next()`, `FrameLease.deinit`, size-driven copy/hold
asymmetry, `MotionTable` correlation) with **A's tested transport** for the camera, unified by
the protocol seam.

Why the custom box was unnecessary:
- The Mutex box reinvents `.bufferingNewest(1)`. `AsyncStream` evicts the displaced element
  **synchronously on `yield`**, so a displaced `FrameLease`'s pool slot returns promptly — the
  "opaque timing" worry in §5 is weaker than stated. Pinned slots ≈ 1 buffered + 1 held by C++
  + ~1 in-flight ≈ 2–3, which `pool=5` covers. Storing a `@unchecked Sendable` lease *in* an
  `AsyncStream` is sound under strict concurrency.
- `AsyncStream`'s only real limitation — `yield` never blocks, so no producer backpressure —
  falls exclusively on the file/replay source, which sidesteps `AsyncStream` entirely via
  on-demand decoding. So we never collide with it.

**Net:** the only hand-written concurrency that remains is the `MotionTable` actor (dictionary
+ bounded ring behind actor isolation) and `FrameLease.deinit`. No custom mailbox, ring, or
backpressure primitive. This *minimizes* bespoke concurrency rather than adding it — the
correct posture when a tested stdlib primitive already solves the push lane.
