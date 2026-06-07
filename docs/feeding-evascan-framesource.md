# Co-designing CameraKit ↔ EvaScan frame handoff

CameraKit (this repo) is the live frame producer; the EvaScan stitcher
(`~/work/cambrian/mac-stitch-video`) is the **sole consumer** of its `processed`
and `tracker` lanes. Both repos and the Flutter app are editable — this is a
co-design. Written 2026-06-07.

## Working resolution

The stitcher runs at **1440×1440** (square). CameraKit's crop defaults are now
1440×1440 (`Constants.cropDefaultWidthPx/HeightPx`); the dev-harness center-crop
matches. Consequences of the 4:3 → 1:1 change:
- The tracker lane (derived `trackerHeightPx = 480`, output-aspect-preserving)
  becomes **480×480** — which conveniently equals the 480p coarse-motion size
  the stitcher wants.
- Perf aside (EvaScan ADR-002): a **1536²** source factors by 3 to exactly 512
  (the vDSP radix-2 ECC/PC optimum); **1440 → 480** is vDSP-legal but
  mixed-radix. 1440² is the chosen target; note 1536² if the vDSP backend
  graduates.

## What "align the shapes" means

Match **conventions across two modules + a thin mechanical adapter** — NOT a
shared type package. CameraKit must not depend on `StitchProtocols` (it's also a
Flutter plugin). Design CameraKit's stitcher-facing structs and EvaScan's
`FrameSource` types to be field-for-field congruent so the push→pull adapter is a
mechanical copy.

## Decision 1 (drives the whole shape): two independent rate-decoupled streams

The stitcher will consume the two lanes at **different rates**:
- **tracker** — every frame (~30 fps), cheap coarse motion.
- **processed** — gated on ECC completion, possibly only every ~9th frame
  (up to ~300 ms apart).

Therefore the lanes **cannot** be bundled into one `NextFrame`/`CapturedFrame` —
that forces a shared cadence. They must be **two independent streams, each pulled
at its own rate**. This is exactly what CameraKit's existing per-lane
`subscribe(stream:)` provides: each lane is its own `AsyncStream` with
`.bufferingNewest(1)` latest-wins. The slow processed consumer naturally drops
stale frames and, when ECC frees up, pulls the newest processed frame — correct
behavior, zero extra CameraKit machinery. (Both lanes are already rendered every
camera frame on the GPU regardless — processed also backs the Flutter preview —
so rate-decoupling is free on the producer side.)

**Model:** two `FrameSource` instances in the stitcher — `trackerSource` and
`processedSource` — each driven by its own prefetch queue/worker cadence, each
backed by one CameraKit per-lane subscription.

## Decision 2 (resolved): correlating a tracker frame to a processed frame

Needed to seed ECC (run on a processed frame) from MotionEstimator (run on
tracker frames). **Match by exact `frameNumber`** — both lanes carry the same
`frameNumber` and `captureTime` because they're the same capture. No timestamp
fuzzy-matching.

Seed flow:
1. MotionEstimator consumes the tracker stream every frame, storing its
   integrated pose **keyed by `frameNumber`** (a small map/ring).
2. When processed frame N completes and ECC needs a seed, look up the stored pose
   at `frameNumber == N`.
3. Prune stored poses older than the last committed processed frame.

Hazards:
- Requires the **tracker lane to not drop frames** (so MotionEstimator sees every
  N). It's the fast lane — keep its consumer at full rate; have MotionEstimator
  integrate-across-gap if a drop ever happens.
- `frameNumber` resets per `open()`/session — correlation keys are
  session-scoped (fine).

So both per-lane frames must carry `frameNumber` + `captureTime`. EvaScan's
`NextFrame` already has `frameIndex` + `timestamp`; map `frameIndex = frameNumber`,
`timestamp = captureTime` (ns) on **both** sources.

## Push vs pull — and what it actually costs

A live camera is **inherently push**: frames arrive at 30 fps on the delivery
queue whether or not anyone wants them, and the hardware **cannot be
back-pressured** (it's real-time). The stitcher's `FrameSource.next()` is
**pull**. These do not actually clash — `AsyncStream(bufferingNewest(1))` *is* the
canonical push→pull bridge: a push producer (`continuation.yield`) feeding a
pull consumer (`iterator.next()`), with intermediate frames dropped. So `next()`
is literally "sample the newest of an always-running push stream." That's the
right model for a live source, not a hack.

What the push/pull bridge *does* cost, and where the current types fall short:

1. **Drops are invisible to the puller.** The consumer that pulls frame N+9 (8
   dropped) sees only a `frameNumber` jump, no drop signal. Fine for the
   processed lane (latest-wins is desired); **wrong for the tracker lane**, where
   MotionEstimator integrates motion and needs *every* frame (Decision 2). So the
   two lanes want **different buffering policies** — processed: `latestWins(1)`;
   tracker: bounded-lossless (drop only on overflow, with a surfaced drop count).
   CameraKit's `subscribe` is hardwired to `bufferingNewest(1)` for *all* lanes —
   it cannot express a lossless tracker lane. This is a real gap.
2. **No back-pressure means the only knob is the drop policy.** You can't block
   the camera, so per-lane policy (sample-newest vs bounded-lossless-then-drop)
   is the *entire* design space. It deserves to be explicit, per lane, not a
   fixed global.

## FrameSet ↔ FrameSource: the concrete code-level frictions

Grounded in the real source. Tier 1 changes behavior; Tier 2 makes the adapter
mechanical; Tier 3 is a smell.

**Tier 1 (behavior):**
- **A. Lifetime model conflict.** `FrameSet.swift:22-33` forbids holding a buffer
  "across an await or beyond the next stream yield" (pool-backed; holding →
  starvation → `frameStall` three hops away). But the stitcher *holds* the
  processed buffer across ECC (~300 ms) via `FramePrefetchQueue`'s
  `Unmanaged.passRetained`, and `NarwhalFrameSource` (the proven live source)
  deliberately holds the IOSurface "for the whole pipeline hold." This is a
  **fork, not a fix**:
  - *Hold* (consistent with the whole `FrameSource` arch; zero-copy): size the
    processed pool for the bound (pool 5 absorbs the ~300 ms hold under
    latest-wins → ~3 live) and **relax CameraKit's contract** for this
    co-designed sole consumer (the contract is a defensive default).
  - *Copy-out* (one ~8 MB memcpy per ECC cycle, ~3/s — negligible): the stitcher
    copies on pickup; CameraKit's pool churns freely. Sole merit — **decouples
    CameraKit's pool from ECC-latency variance**: a hold that ever exceeds pool
    headroom stalls delivery (the exact failure the contract warns of); copy-out
    can't. Discriminator: trust the 300 ms bound → hold; don't → copy. Tracker
    stays zero-copy either way (held briefly).
- **B. Per-lane subscription ships the whole `FrameSet`.** `subscribe(.tracker)`
  delivers a `FrameSet` carrying all lanes, so the tracker subscriber pins the
  *processed* pool buffer it never reads while buffered. **B is a prerequisite
  for A's pool math** — you can't reason about per-lane depth if every lane pins
  every pool. Fix: a per-lane payload (one buffer + shared fields), not the
  all-lanes struct.
- **D. Error channel is split → camera death looks like clean EOF.** `next()`
  unifies frames+errors (throws / nil-EOF); CameraKit's frame `AsyncStream` just
  *finishes* on failure while the error goes to a separate `errorStream()`. A
  camera failure currently reaches the stitcher as a clean `nil` and the mosaic
  stops with **no error surfaced**. Fix: terminate the frame stream *with* the
  error (throwing stream), or the adapter must race `errorStream` and map
  `CameraError → FrameSourceError`.

**Tier 2 (congruence):**
- **C. No format/stride/dims in the consumer contract.** `FrameSet` lanes are
  self-describing `CVPixelBuffer`s; EvaScan's `FrameBuffer` drops that and assumes
  BGRA8 + `width*4` (`FramePrefetchQueue.swift:80`). Carry
  width/height/bytesPerRow/pixelFormat — mandatory if the tracker ever goes
  single-channel grayscale.
- **E. Timestamp units.** `FrameSet.captureTime: CMTime` vs
  `NextFrame.timestamp: Duration` → a `CMTimeConvertScale` per frame. Pick one
  unit (ns) on both.
- **F. `frameNumber` semantics.** `NextFrame.frameIndex` says "monotonic, starts
  at 0"; CameraKit's resets per session and the consumer sees **gaps**
  (latest-wins). Align: capture index, gaps expected, session-scoped, *and* the
  correlation key (Decision 2).
- **H. A lease-returning borrow helper.** Every consumer reinvents
  `CVPixelBufferGetIOSurface → IOSurfaceLock(.readOnly) → IOSurfaceGetBaseAddress
  → matching unlock+release` (where both landmines lived). CameraKit should offer
  `lockedPixels() -> (ptr, bytesPerRow, lease)` on the lane buffer — **lease-
  returning, not scoped `withLockedBytes {}`** (Narwhal documents the scoped
  unlock is far too short for a pipeline hold).

**Tier 3 (smell):**
- **G. `FrameSet: Hashable`.** A transient, pool-backed GPU delivery envelope
  being `Equatable`/`Hashable` by `(frameNumber, captureTime)` is misleading
  (frames "equal" across sessions; nothing consumes the hash). Drop it.

**Reality behind `settled` and `blurScore`:** `CaptureMetadata` is *entirely
stubbed* — `MetalPipeline.swift:618` builds `.placeholder()` (all zeros), and
`:678-679` hardcode `blurScore: 0.0` / `trackerQuality: .good`. The real sensor
state lives in `device.lastSnapshot` but was never plumbed into the completion
handler. So `settled` (AE+WB+focus) is not a 1-line Bool — it's "thread
`DeviceStateSnapshot` into `FrameSet` construction," and the seed gate cannot
lean on any existing `FrameSet` metadata today.

## If redesigning both interfaces from scratch

Collapse `FrameSet` + `FrameSource` + `NextFrame` + `FrameBuffer` into **one
shared vocabulary**: a per-lane `AsyncSequence` of self-describing, leased frame
handles. The push/pull "mismatch" dissolves — `AsyncSequence` is push-fed,
pull-consumed by construction; with the right shape there is almost no adapter.

```swift
struct Frame {                 // one lane, one capture
    let lane: Lane             // .processed | .tracker
    let index: UInt64          // capture index — shared across lanes, gaps allowed; the correlation key
    let timestampNs: Int64     // one unit, no CMTime/Duration split
    let settled: Bool          // AE+WB+focus converged
    let pixels: PixelHandle    // self-describing + lifetime
}

struct PixelHandle {           // the single currency on BOTH sides
    let baseAddress: UnsafeRawPointer
    let width, height, bytesPerRow: Int
    let format: PixelFormat
    // holds the IOSurface locked; releases on deinit. A bounded hold is allowed.
}
```

- **One element type end to end.** CameraKit builds `Frame`; the stitcher's C++
  slot reads `frame.pixels` directly (ptr/stride/dims/format all present). No
  `FrameSet → FrameBuffer` translation, no `width*4`, no reinvented lock dance.
- **Per-lane `AsyncSequence` with an explicit buffering policy** chosen at
  subscribe: `.latestWins(1)` (processed) vs `.lossless(bounded: N)` (tracker).
  This is the thing the current fixed `bufferingNewest(1)` cannot do, and it's
  what the different-rate + every-frame-motion requirement demands.
- **Throwing termination** (`AsyncThrowingStream` / yields `Result`): camera
  failure ends the lane sequence with an error → unifies with the consumer's
  `next() throws`; no separate error channel to race (fixes D).
- **Bounded hold permitted** via the lease, so no copy is forced (resolves A
  toward hold — the stitcher's natural model — without violating a "don't hold"
  rule, because the rule is replaced by an explicit lease contract).
- **Heavyweight sensor metadata stays off the hot path** — a separate low-rate
  stream (the existing 3 Hz `frameResultStream`), not bundled into every frame.
- **Layering:** the `Frame`/`PixelHandle` type lives in **CameraKit** (the
  producer's natural output; Flutter consumes it too). EvaScan keeps a thin
  `FrameSource` *protocol* (so video-file and replay sources still plug in) whose
  element is `Frame`; the camera lane conforms near-identically. CameraKit still
  must not depend on `StitchProtocols`.
- **Dual rate = two sequences from one camera** (`camera.lane(.tracker)`,
  `camera.lane(.processed)`), correlated by `index`.

Net: the from-scratch interface is *"a live camera exposes one
`AsyncSequence<Frame>` per lane, each with a chosen drop policy, over a shared
self-describing leased pixel handle, terminating with a throwing error."* The
adapter shrinks to nearly nothing because both sides already speak it.

## The per-lane frame shape

### CameraKit side

The per-lane `subscribe(stream:)` is the right primitive — but fix it so a lane
subscription delivers **only that lane's buffer** (today it hands the whole
`FrameSet`, all lanes), with `frameNumber`, `captureTime`, and `settled`. A
lighter per-lane struct (not the all-lanes `FrameSet`) avoids pinning the other
lane's pool buffer while one lane is buffered.

### EvaScan side — `FrameBuffer`/`NextFrame` carry self-describing dims

Each lane has different dims (1440×1440 vs 480×480), so dims+stride must live on
the buffer, not on `FrameSource.width/height`:

```swift
// Ownership (rule A.4): ptr immutable after init; pixel lifetime held by the
// release closure. Raw pointer ⇒ @unchecked Sendable (the sanctioned case).
public final class FrameBuffer: @unchecked Sendable {
    public let ptr: UnsafeMutableRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int                    // ← real IOSurface stride; fixes width*4 bug
    private let _release: @Sendable () -> Void
    deinit { _release() }
}
```

`NextFrame` stays single-lane (`buffer`, `timestamp`, `frameIndex`, +`settled`);
the stitcher instantiates **two** sources. `FrameSource.width/height` describe
that source's lane. The C++ `StitchFrameSlot` already has `stride_bytes` — feed
it `bytesPerRow` instead of `width*4`; add a `settled` flag.

## CameraKit changes (tiered)

**Correctness — do regardless:**
- **Tracker dims landmine.** `trackerForSet = trackerBuf ?? processedForSet`
  (`MetalPipeline.swift:643`) substitutes the full-res processed buffer under the
  `.tracker` label when no tracker subscriber exists. Make the tracker buffer
  genuinely **absent** when the lane is off (user: confirmed bug — "if tracker
  not subscribed, it should not be available at all"). Make the per-lane
  tracker delivery `Optional`; never substitute.
- **`blurScore=0.0` / `trackerQuality=.good` are hardcoded lies** — populate
  truthfully or remove.

**User-requested:**
- **Cut the natural lane entirely** (Pass-7n, `FrameSet.natural`,
  `latestNaturalBuffer`, `StreamId.natural`). Update the Flutter plugin
  (`StreamId` Pigeon enum + `TextureBridge`) — preview already uses `.processed`.
  Saves a GPU pass + a pooled buffer/frame. (User: natural was debug-only.)
- **Add `settled: Bool`** = AE **and** WB **and** focus converged (CameraKit has
  all three: AE monitor / `isAdjustingExposure`, `awaitWBSettled`, lens position
  in `DeviceStateSnapshot`). A mid-autofocus frame must not seed a
  first-writer-wins mosaic (ADR-006).

**Co-design:**
- **Tracker size is currently a compile-time `Constant` (`trackerHeightPx`), NOT
  settable via `OpenConfiguration`.** To make it 480p/512p-configurable, add an
  `OpenConfiguration` field. (At 1440² square it already lands on 480×480.)
- Optionally tighten per-lane delivery to a lane-specific struct (above).

## EvaScan changes (tiered)

- **Stride.** Copy `FrameBuffer.bytesPerRow` into `slot.stride_bytes`; stop
  computing `width*4` (`FramePrefetchQueue.swift:80`).
- **`FrameBuffer` carries width/height/bytesPerRow**; add `settled` to
  `NextFrame`; C++ `StitchFrameSlot` += `settled`. (Other conformers
  `VideoFileFrameSource`/`NarwhalFrameSource` are editable — set `settled=true`.)
- **Two sources** (`trackerSource` + `processedSource`), each its own prefetch
  queue cadence.
- **MotionEstimator stores per-`frameNumber` poses**; ECC seeds from the matching
  processed frame's stored pose (Decision 2). MotionEstimator consumes the
  supplied 480×480 tracker directly instead of `cv::resize`-ing the full frame.
- **Seed gate** keys on `NextFrame.settled`.
- **Pool depth is per-lane**: processed pool and tracker pool each floor 5
  (user-approved); natural pool gone. Watch `holdOverBudgetByLane` /
  `poolExhaustion`.

## Crop-default change status (1440×1440)

**CameraKit — DONE:** `Constants.cropDefaultWidthPx/HeightPx = 1440`;
`ViewModel.toggleCenterCrop` center-crop + comments updated to 1440×1440.

**EvaScan — NOT a single constant; entangled, needs decisions.** The `1600×1200`
there is two different kinds of thing:
- *Safe-ish defaults:* `SyntheticFrameSource` / `SyntheticRecordingBuilder`
  default `(1600,1200)`; `Apps/{Mac,IOS}App/Debug/DebugSyntheticRecording`
  default `1600×1200`; `SyntheticRecordingSpike`.
- *Calibration / asset / test-pinned (do NOT blind-edit):*
  - `StaticDemoFrameTests` asserts a bundled **1600×1200 PNG asset** — changing
    the number without regenerating the PNG breaks the test.
  - `MockStitchCoordinatorTests` pins `1600/1200`.
  - `algorithms.md` §10/§12 LV/TG floor tables, `Tuning.hpp`, `QualityGate.hpp`,
    `ADR-043 "Input 1600×1200"` — calibrated against 1600×1200's pixel count and
    4:3 aspect; floors scale with pixel count. Swapping the number without
    recalibration makes the records wrong.

Recommended EvaScan path (pending confirmation): update the synthetic/debug
*defaults* to 1440×1440; regenerate the demo PNG asset + its test; amend ADR-043
to state 1440×1440 with a "floors need recalibration at 1:1 / 2.07 MP" note
rather than silently changing the floor values.
