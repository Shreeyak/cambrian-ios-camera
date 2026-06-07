# Camera ↔ Stitcher Frame Handoff — Consolidated Recommendations

**Canonical, action-oriented spec** for feeding CameraKit's live frames into the
EvaScan stitcher (`~/work/cambrian/mac-stitch-video`). Written 2026-06-07.
The two working docs remain as rationale archives:
- `feeding-evascan-framesource.md` — code-grounded analysis (file:line citations).
- `firstprinciples-camera-stitcher-interface.md` — from-scratch design exploration.

---

## 0. Context & settled decisions

- CameraKit is the live producer; **the stitcher is the sole consumer of the
  `processed` and `tracker` lanes.** Flutter consumes `processed` for preview only.
- **Working resolution 1440×1440 (square).** The stitcher sets it via
  `OpenConfiguration.cropRegion`; the tracker derives to 480×480.
- **Two lanes, two rates:** tracker every frame (~30 fps, fast motion); processed
  latest-wins, **ECC aligns the newest processed frame at pickup** (~300 ms apart).
  → two independent streams, never one bundled frame.
- **Correlate lanes by capture index** (`frameNumber`; same capture → same index).
- **Multi-stage C++ pipeline** (owner's direction): motion estimation (PC) and
  ECC-align+blend run as separate C++-owned threads, each internally
  multi-threaded and thread-pinned. C++ owns its execution.
- **Layering:** CameraKit must not depend on the stitcher's `StitchProtocols`. The
  `FrameSource` abstraction lives consumer-side (it also serves file/replay).

## 1. The integration model (how the pieces fit)

The camera is **push**; the stitcher pulls via a `FrameSource.next()` seam. The
bridge is the standard one — a per-lane `AsyncStream` (push-fed, pull-consumed),
backed where each source's nature fits: **camera lanes by CameraKit's existing
`AsyncStream(.bufferingNewest(1))`, file/replay by on-demand decode.** Frames
cross to the C++ engine as **self-describing, refcount-pinned, zero-copy leases**;
the two lanes feed two C++ input queues and correlate through a C++ pose store.

```
CameraKit — one capture N → two lanes (same index N, same timestamp)
│
├ tracker 480²  ─AsyncStream(bounded)── trackerSource ─Task─> [C++ motion queue]
│                                                              ─> MOTION thread (PC, every frame)
│                                                                 └─> poseStore[N] = pose ──┐
├ processed 1440² ─AsyncStream(newest-1)─ processedSource ─Task─> [C++ ECC queue (latest-wins)]
│                                                              ─> ECC+BLEND thread (~300 ms)
│                                                                 read poseStore[N] (seed) ◄─┘
│                                                                 align→blend→MosaicSink
│                                                                 committedPose ─► admission gate
```

Tracker frames are **copied** (small, lossless, no pool pinning); processed frames
are **held zero-copy** across ECC (large; copying at 30 fps ≈ 240 MB/s of mostly-
dropped data). Holding is safe because a held `CVPixelBuffer` reference pins its
pool slot (verified in CameraKit's `TexturePoolManager` — fresh buffer per frame +
refcount excludes held buffers from reuse).

---

## A. CameraKit (producer) — recommendations

**Headline: NO changes are required to integrate. CameraKit's current state is
consumable as-is**, and `.bufferingNewest(1)` is an exact fit for newest-at-pickup.
Everything below is *already done*, *optional*, or a *usage note*.

### A.0 Already done
| Item | Note |
|------|------|
| `OpenConfiguration.trackerHeight` (configurable, aspect-preserving, clamped, even) | Built green. |
| Crop defaults → 1440×1440 (`Constants.cropDefault*`) + dev-harness center-crop | Done. `cropDefault*` is **vestigial** (real crop is consumer-driven via `OpenConfiguration.cropRegion`). |

### A.1 Required for the handoff
**None.** The current per-lane `subscribe(stream:) → AsyncStream<FrameSet>` with
IOSurface-backed BGRA8 `CVPixelBuffer`s, subscription-gated tracker, and
consumer-set crop is sufficient. The stitcher's adapter does the rest (§B.1).

### A.2 Optional (perf / hygiene / future), each with why
| Change | Why | Priority |
|--------|-----|----------|
| **Cut the natural lane** (Pass-7n, `FrameSet.natural`, `latestNaturalBuffer`, `StreamId.natural`; update Flutter `StreamId`/`TextureBridge`) | Saves a GPU convert pass + one pooled buffer/frame; the sole consumers (stitcher, Flutter) use `processed`. | High value, low risk |
| **Per-lane delivery payload** (deliver one lane's buffer + stamp, not the whole `FrameSet`) | A per-lane subscription currently ships all lanes, transiently pinning buffers the subscriber ignores. | Medium |
| **Terminate the frame stream *with* the error** (vs the separate `errorStream()`) | Today camera failure finishes the stream silently → looks like clean EOF. Throwing-stream unifies it; otherwise the adapter must merge `errorStream` (§B.1). | Medium |
| **Fix the tracker→processed fallback landmine** (`trackerForSet = trackerBuf ?? processedForSet`) — make tracker genuinely absent when unsubscribed | Latent correctness bug (full-res buffer under the `.tracker` label). **Does not bite the stitcher** (it subscribes to `.tracker`), but it's a trap for any other usage. | Medium |
| **`settled` flag** (AE && WB && **focus** converged) — plumb real `DeviceStateSnapshot` (`device.lastSnapshot`) into `FrameSet` construction | Lets the stitcher gate the mosaic seed (first-writer-wins, ADR-006) on CameraKit's attestation. **Optional** — the stitcher can self-gate via its `QualityGate` (§B.3). Note: `CaptureMetadata` is entirely stubbed today, so this is real plumbing, not a 1-line field. | Optional feature |
| **`lockedPixels() → (ptr, bytesPerRow, lease)`** — a lease-returning borrow helper on the lane buffer, *not* a scoped `withLockedBytes {}` closure | Every IOSurface consumer currently reimplements `CVPixelBufferGetIOSurface → IOSurfaceLock(.readOnly) → baseAddress → unlock+release` by hand — both landmines live there. A lease-returning API is required here because the scoped-closure form unlocks too early for the ECC hold (~300 ms); the lease must remain alive for the full pipeline duration. | Optional feature |
| **Remove `blurScore` / `trackerQuality`** (or implement them) | Currently hardcoded `0.0` / `.good` (`MetalPipeline.swift:690–691`) — the contract advertises signals it doesn't deliver. *Intended source:* a GPU gradient/Laplacian reduction in **Pass 4** (the tracker downsample), classified into `TrackerQuality`. The stitcher's `QualityGate` already computes the equivalent CPU-side, so **lean remove** until a consumer needs them. | Hygiene |
| **Drop `FrameSet: Hashable`** | A transient pool-backed GPU envelope shouldn't be value-equatable by `(frameNumber, captureTime)`; nothing consumes the hash. | Hygiene |
| **Grayscale tracker lane** (single-channel instead of BGRA8) | `MotionEstimator`/`QualityGate` work in grayscale anyway — would save the CPU `cvtColor`. Changes the tracker pixel format (a deliberate contract term). | Future micro-opt |

### A.3 Usage notes (not changes — how the stitcher must use CameraKit as-is)
- **Subscribe to `.tracker`** to force its render (subscription-gated). Each per-
  lane subscription delivers the whole `FrameSet` — read only your lane.
- **Set resolution** via `OpenConfiguration.cropRegion` (1440²) and tracker size
  via `OpenConfiguration.trackerHeight`.
- **Pool depth:** pools grow on demand (only `MinimumBufferCount=3` +
  `MaximumBufferAge=1 s`, no hard cap), so a held buffer is never corrupted; the
  risk of a long/large hold is memory growth, not allocation failure. Treat
  "`pool=5`" as a `MinimumBufferCount` target, not a ceiling; watch
  `holdOverBudgetByLane`.

### A.4 Do NOT
- Make CameraKit depend on `StitchProtocols` or conform to `FrameSource` (wrong
  layering; CameraKit is also a Flutter plugin).
- Route the stitcher through the C-ABI `PixelSink`/`PixelSinkPool` path. Its
  `onFrame` IOSurface is **"valid for call only"** (`PixelSink.hpp:11`) — it
  cannot support the stitcher's ~300 ms hold without a copy. The stitcher uses the
  Swift `FrameSource` path. (Whether to fully retire the C-ABI path — its only
  remaining user is the dev Canny demo — is a separate call, §D.4.)
- Force Flutter preview to copy. The `@unchecked Sendable` lease is sound on
  **single-writer** (GPU finishes before delivery), not single-reader —
  concurrent readers of the immutable buffer are safe; pool sizing absorbs the
  extra display-hold.

---

## B. EvaScan stitcher (consumer) — recommendations

This is where the work lives. The shared contract types and the camera adapter
are stitcher-side; CameraKit is consumed as-is.

### B.1 The camera adapter + shared contract types (Required)
- **`CameraKitLiveFrameSource: FrameSource`** (new iOS-only package, depends on
  CameraKit SPM at a pinned tag). Per lane: `subscribe(stream:)`, read that lane's
  `CVPixelBuffer` off the `FrameSet`, `IOSurfaceLock(.readOnly)`, wrap as a
  `FrameLease`; `prefersLatestWins = true`. Mirror `NarwhalFrameSource` (the proven
  push→pull live bridge). *Why:* keeps the camera as just another `FrameSource`.
- **Merge `errorStream()` into `next()`** (race the lane stream vs the error
  stream; throw on error, `nil` on finish). *Why:* otherwise camera death looks
  like clean EOF. (Removable if CameraKit adopts A.2 throwing-stream.)
- **`FrameBuffer` carries `width`/`height`/`bytesPerRow`/`format`** (self-
  describing), read off the `CVPixelBuffer`. `@unchecked Sendable` with an
  `// Ownership:` note (raw pointer; immutable after init; lifetime held by the
  lease). *Why:* kills the `width*4` assumption and supports a future grayscale
  tracker.
- **Stride fix:** `slot.stride_bytes = bytesPerRow`, not `width*4`
  (`FramePrefetchQueue.swift:80`). *Why:* IOSurface stride is padded; the
  assumption silently corrupts rows whenever width isn't 64-aligned.
- **`FrameLease` lifetime:** `final class`, `deinit` returns the pool slot;
  bounded hold (~300 ms) permitted. *Why:* the held `CVPixelBuffer` ref pins the
  pool slot (verified), so the zero-copy ECC hold is safe.

### B.2 Two sources + the multi-stage feed (Required for the dual-rate design)
- **Two `FrameSource`s:** `trackerSource` (every frame) and `processedSource`
  (latest-wins). *Why:* the lanes are consumed at independent rates.
- **Two C++ input queues, C++ keeps ownership of execution.** `trackerSource →`
  motion input queue (bounded-lossless; drop+gap on overflow); `processedSource →`
  ECC input queue (latest-wins, cap 1). A trivial Swift feeder Task per source
  (`for await { enqueue }`). *Why:* C++ owns its multi-threaded, pinned, multi-
  stage execution — **keep the C++ queue**; do **not** collapse to a Swift-driven
  synchronous `processFrame` (it would undo thread pinning and re-serialize motion
  behind ECC).
- **`poseStore` is the motion→ECC handoff, C++-internal.** Motion thread writes
  `poseStore[index]`; ECC thread reads it as the seed; ECC writes `committedPose`
  back to the admission gate. Mutex-guarded index→pose map, gap-tolerant lookup,
  capacity ≥ the ECC lag (~256 ≈ 8 s). *Why:* both writer and reader are C++
  threads — a Swift actor would add a hop per frame.
- **ECC aligns the newest processed frame at pickup.** The processed queue is
  plain latest-wins; the displacement gate only decides whether to run ECC this
  cycle. *Why:* loosest coupling — the two lanes stay independent and correlate
  only through `poseStore`.
- **C++ `StitchFrameSlot` gains tracker fields + `settled`** (if A.2 settled is
  taken; else omit). Feed `stride_bytes` from `bytesPerRow`. Cross into C++
  **synchronously** in a `nonisolated` shim; the raw pointer must not cross an
  `await`.
- **Demand-decode `next()` for file/replay** sources — no `AsyncStream`, no
  buffer; inherently lossless + back-pressured.

### B.3 Tuning
- **Per-lane pool sizing:** target `MinimumBufferCount=5` on the processed and
  tracker pools; natural pool gone (if A.2 cut). Watch `holdOverBudgetByLane` /
  `poolExhaustion`.
- **MotionEstimator consumes the supplied 480² tracker** directly instead of
  `cv::resize`-ing the full frame. *Why:* the tracker already lands at the coarse-
  motion size on CameraKit's GPU — the resize is redundant CPU work.
- **Seed gate:** use the existing `QualityGate` (LV/TG floors) to reject soft seed
  frames. *Why:* covers the "don't seed a bad frame" need without CameraKit's
  `settled` — adopt `settled` only if you want convergence attestation too.

### B.4 Resolution housekeeping (1600→1440)
Entangled, **not** a single constant: a bundled 1600×1200 PNG test asset
(`StaticDemoFrameTests`), `MockStitchCoordinatorTests`, and **calibrated** values
(ADR-043, `algorithms.md` §10/§12 LV/TG floors, `Tuning.hpp`, `QualityGate.hpp`)
keyed to 1600×1200's pixel count and 4:3 aspect. *Recommended:* update synthetic/
debug **defaults** to 1440²; regenerate the demo PNG + its test; amend ADR-043 to
state 1440² with a "floors need recalibration at 1:1 / 2.07 MP" note — do **not**
silently change floor values. (Open decision §D.1.)

### B.5 Do NOT
- Wire CameraKit's C++ `PixelSink` directly into the stitcher's C++. Verified: its
  IOSurface is call-scoped, forcing an 8 MB copy inside the callback; it keeps the
  cross-thread handoff anyway; it fragments ingestion and couples the two repos'
  C++ builds. The Swift `FrameSource` path (refcounted `CVPixelBuffer`, holdable)
  is strictly better.

---

## C. Shared / cross-cutting
- **Correlate by `frameNumber`** — session-scoped (resets per `open()`), gaps
  expected (latest-wins drops). Both lanes carry the same index + timestamp.
- **Errors/EOF:** a single camera failure surfaces on **both** lanes — **dedupe**
  at the coordinator (report once; tear down `poseStore` after both stages join).
- **Timestamp unit:** carry nanoseconds end-to-end (convert `CMTime → ns` once at
  CameraKit's construction site) to avoid a per-frame `CMTimeConvertScale`.

## D. Open decisions (need the user)
1. **EvaScan 1600→1440 calibration/asset/ADR** (§B.4) — confirm the recommended
   path (defaults + regen PNG + ADR note; recalibrate floors separately).
2. **`cropDefault*`: wire into `open()` or delete?** Vestigial today. Lean: delete
   (one source of truth — crop is consumer-driven).
3. **`settled`: plumb in CameraKit or self-gate in the stitcher?** Lean: self-gate
   via `QualityGate` first; plumb `settled` later if needed.
4. **C-ABI `PixelSink` path: retire or keep?** Lean: retire (only the dev Canny
   demo uses it; the stitcher uses the Swift path).
5. **`blurScore`/`trackerQuality`: remove or implement?** Lean: remove until a
   consumer needs them.

## E. Implementation sequence (dependency-ordered; CameraKit needs no change to start)
1. **Stitcher — shared contract types** (`FrameBuffer` self-describing +
   `bytesPerRow`/format, `FrameLease`, `NextFrame` (+`settled` optional),
   `FrameSource`); the stride fix. Builds/tests on Mac against existing sources.
2. **Stitcher — `CameraKitLiveFrameSource` adapter** (+ CameraKit SPM dep, pinned
   tag); two `FrameSource`s; `errorStream` merge. **Validate against current
   CameraKit on device.** No CameraKit change needed here.
3. **Stitcher — multi-stage split:** motion + ECC threads, two input queues,
   `poseStore` + `committedPose`; newest-at-pickup; MotionEstimator consumes the
   supplied tracker; C++ slot gains tracker fields.
4. **Stitcher — tuning + housekeeping:** per-lane pool=5; resolution 1600→1440
   (§D.1).
5. **CameraKit — optional, later (after integration is proven):** cut natural lane
   (+ Flutter); plumb `settled` (if §D.3 yes); fix tracker landmine; remove
   `blurScore`/`trackerQuality` + `FrameSet: Hashable`; retire the C-ABI path.
