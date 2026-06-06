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
