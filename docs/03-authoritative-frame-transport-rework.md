# Authoritative Plan — FrameTransport Rework (CameraKit ↔ EvaScan)

**This is the decision-of-record.** It supersedes the recommendations in
`02-refined-implementation-frame-interface-recommendations.md` wherever they
differ, and draws its rationale from `01-insights-feeding-evascan-framesource.md`
and `firstprinciples-camera-stitcher-interface.md`. Written 2026-06-07 after a
decision pass with the repo owner.

Scope: a **full rework of the frame-delivery interface on both sides, done now,
before CameraKit has external consumers.** The earlier docs optimised for "ship
with zero CameraKit change + an adapter." That premise is explicitly **rejected**
here: we are changing the shape of CameraKit's lanes, so "no changes required" is
false. We take the clean shape while it is still free to take.

Two repos, two sections:
- **§3 — `cambrian-ios-camera`** (CameraKit, the producer; also a Flutter plugin).
- **§4 — `mac-stitch-video`** (EvaScan, the sole consumer of the camera lanes).

Plus shared vocabulary (§2), cross-cutting contracts (§5), OpenSpec
reconciliation (§6), an implementation sequence (§7), and diagrams (§8).

---

## 1. The whole rework in one paragraph

There is **one shared element vocabulary** — `Frame` / `PixelHandle` /
`FrameMetadata` — defined in a new **platform-neutral `FrameTransport` package
inside the `cambrian-ios-camera` repo** (builds on iOS *and* macOS; no
AVFoundation). CameraKit produces `Frame`s on **two lanes** (`.primary` full-res,
`.tracker` downscaled), each as its own `AsyncThrowingStream<Frame>` with an
explicit **`BufferingPolicy`**, terminating with an error only when CameraKit
itself judges the error terminal. EvaScan consumes `Frame`s through a thin,
consumer-side **`FrameSource`** protocol whose element *is* `Frame`, so the camera
adapter does no type translation. The lanes run at **two rates**, correlated by a
bare **`index`**. EvaScan's pipeline **splits in two** — a motion-estimator stage
(eats `.tracker` every frame) and an align/ECC stage (eats `.primary` latest-wins)
— handed off through an index-keyed `poseStore`.

---

## 2. Shared vocabulary — the `FrameTransport` package

### 2.1 Why a separate neutral package (the binding constraint)

CameraKit imports AVFoundation capture APIs → it **only compiles for iOS** (a
macOS host build fails; CLAUDE.md §6). EvaScan is **multi-platform** — a Mac app
*and* an iOS app — and its core (`StitchProtocols`, the engine) builds for both.
If `Frame` lived *inside* CameraKit, EvaScan's macOS build would transitively pull
AVFoundation and fail. `Frame` also cannot live in EvaScan (CLAUDE.md forbids
CameraKit depending on `StitchProtocols`, and a camera repo depending on a
stitcher repo is backwards layering).

So the shared types need a **third home that builds on both platforms**.
`Frame`/`PixelHandle`/`FrameMetadata` need only CoreVideo, IOSurface, and
Foundation — all cross-platform. Decision: a new SPM product **`FrameTransport`**
in the `cambrian-ios-camera` repo, importable standalone without pulling the rest
of CameraKit.

```
cambrian-ios-camera/  (repo)
  Package.swift
   ├── product: FrameTransport      ← NEW, neutral (iOS + macOS), no AVFoundation
   │     Frame, PixelHandle, FrameMetadata, BufferingPolicy, Lane, PixelFormat
   └── product: CameraKit (iOS)  ──depends──▶ FrameTransport
         produces Frame per lane

mac-stitch-video/  (repo, Mac + iOS)
   StitchProtocols  ──depends──▶ .product("FrameTransport", package: "cambrian-ios-camera")
         FrameSource protocol, element = Frame
   Apps/IOSApp (iOS only)  ──depends──▶ CameraKit + FrameTransport
         CameraKitLiveFrameSource: FrameSource
```

Naming: it is **not** camera-named, because non-camera sources
(`SyntheticFrameSource`, `VideoFileFrameSource`) import it too and have nothing to
do with cameras. It lives *in* the camera repo but is a neutral transport
vocabulary.

### 2.2 The types

```swift
// ===== FrameTransport (neutral; iOS + macOS) =====

public enum Lane: Sendable {
    case primary     // full-resolution alignment frame (camera: the processed output)
    case tracker     // downscaled coarse-motion frame (camera: GPU tracker; files: derived)
}

public enum PixelFormat: Sendable {
    case bgra8       // (gray8 reserved for a future single-channel tracker — see §3.12)
}

public enum BufferingPolicy: Sendable {
    case blocking               // back-pressure the producer — offline/deterministic sources
    case latestWins             // keep newest 1, drop the rest — the .primary real-time lane
    case keepBuffered(depth: Int) // keep up to N, drop OLDEST on overflow — the .tracker lane
}

/// The single pixel currency on both sides. A class, not a struct, because it
/// must release its underlying lock on `deinit` — structs have no deinit.
/// `@unchecked Sendable` is the sanctioned raw-pointer case: `baseAddress` is
/// immutable after init; the GPU/decoder finished writing before delivery
/// (single-writer); concurrent read-only consumers of the immutable buffer are
/// safe. A bounded hold is permitted (see §3.9, §4 ECC hold).
public final class PixelHandle: @unchecked Sendable {
    public let baseAddress: UnsafeRawPointer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int        // the REAL IOSurface stride; kills every `width*4`
    public let format: PixelFormat
    // internally retains the CVPixelBuffer/IOSurface + holds the read lock;
    // deinit unlocks + releases (returns the pool slot).
}

/// Marker protocol. Each producer defines its own concrete metadata type; the
/// universal `Frame` envelope stays producer-agnostic. Decision-relevant data
/// is a TYPED member of the concrete type (never a JSON blob); heavyweight,
/// debug-only data goes off the hot path (§3.6).
public protocol FrameMetadata: Sendable {}

public struct Frame: Sendable {
    public let lane: Lane
    public let index: UInt64           // capture index — shared across lanes, gaps allowed,
                                       // session-scoped; THE correlation key
    public let timestampNs: Int64      // one unit end-to-end; no CMTime/Duration split
    public let pixels: PixelHandle
    public let metadata: any FrameMetadata
}
```

### 2.3 Why these shapes (rationale)

- **One element type end-to-end.** Today CameraKit emits `FrameSet` (all lanes
  bundled) and EvaScan wraps it in `NextFrame`/`FrameBuffer`; an adapter
  translates and — in the process — recomputes stride as `width*4` (the latent
  corruption bug). With one shared `Frame`, the adapter translates *nothing*; the
  stride bug cannot exist because `PixelHandle.bytesPerRow` is the authoritative
  stride carried from the source IOSurface.
- **`PixelHandle` is self-describing.** dims/stride/format travel *with the
  pixels*, not on the source. This is why `FrameSource` can drop `width`/`height`
  (§4.2): a source-level resolution is redundant at best and a lie at worst (the
  camera's runtime-reconfigurable crop can change it; a video track's dimensions
  can change mid-stream).
- **`FrameMetadata` is a marker + producer-specific concretes.** `settled` is a
  camera concept; `groundTruthPose` is a synthetic/replay concept;
  `presentationTimestamp`/`trackIndex` are video-file concepts. Forcing them all
  onto one universal struct produces the "every conformer invents a value" smell
  (today `NextFrame.groundTruthPose` is hardcoded `nil` by two of four sources).
  Each lives where it belongs; consumers that branch on it downcast at a
  source-specific boundary (the camera adapter already *is* camera-specific).
- **`index` is the only correlation key.** No `CaptureID` wrapper — both lanes of
  one `open()` share a session, so a bare `UInt64` match is unambiguous within the
  session, and `poseStore` is built around it directly.
- **`BufferingPolicy` replaces a Bool.** The old `prefersLatestWins: Bool` cannot
  express "keep a bounded buffer of N for the motion lane." The enum can, and
  folds the file source's old "Block" mode into the same knob.

### 2.4 The consumer-side protocol (lives in EvaScan, element = `Frame`)

`FrameSource` is the *pull* abstraction; it stays in EvaScan's `StitchProtocols`
(it also serves file/replay/synthetic). CameraKit does **not** conform to it.

```swift
public protocol FrameSource: Sendable {
    var bufferingPolicy: BufferingPolicy { get }       // replaces prefersLatestWins: Bool
    func frames() -> any AsyncSequence<Frame, any Error> // finish = EOF, throw = error
}
```

See §4.2 for the full rationale on what was dropped (`width`, `height`,
`nominalFps`) and why `next() -> Frame?` became an `AsyncSequence`.

---

## 3. `cambrian-ios-camera` (CameraKit) changes

Ordering note: §3.8 (crop) is **independent** of the frame-delivery rework and can
land first; everything else is the frame-shape change.

### 3.1 New `FrameTransport` package (additive)

Add the neutral SPM product (§2). CameraKit gains a dependency on it and produces
`Frame`/`PixelHandle`/`CameraFrameMetadata`. The Flutter plugin (which depends on
CameraKit) inherits the transitive dependency — acceptable, it is a tiny neutral
module.

### 3.2 Per-lane delivery: `subscribe(stream:buffering:) -> AsyncThrowingStream<Frame>`

Today: `subscribe(stream: StreamId) -> AsyncStream<FrameSet>`, hardwired to
`.bufferingNewest(1)` for every lane (`PixelSink.swift:104`), delivering the
*whole* `FrameSet` (all lanes) per subscription.

Change to:
- **Yield a single-lane `Frame`, not the all-lanes `FrameSet`.** A `.tracker`
  subscriber must not transiently pin the `.primary` pool buffer it never reads.
  This is a prerequisite for reasoning about per-lane pool depth.
- **Take a `BufferingPolicy` per subscription.** `.primary` → `.latestWins`;
  `.tracker` → `.keepBuffered(depth:)`. This is the producer-side mirror of the
  policy enum. The fixed global `.bufferingNewest(1)` is gone — it could not
  express a buffered tracker lane, which the every-frame motion estimator needs.
- **`AsyncThrowingStream`** (see §3.4).

`FrameSet` as a public type is **removed** (its lanes are now separate streams;
its `Hashable` conformance is dropped per §3.10). The Swift `subscribe()` API
itself is kept and reworked — note it currently lives in `PixelSink.swift`
alongside the unrelated C-ABI sink that §3.10 removes; the file should be split so
the Swift consumer-registry survives the C-ABI deletion.

### 3.3 Lane rename `processed → primary` (single vocabulary)

`StreamId.processed` becomes `StreamId.primary` across CameraKit
(`SessionState.swift:34`, `MetalPipeline`, `CameraEngine`, docs). One vocabulary
everywhere — the camera's full-res output *is* the neutral `.primary` lane.

**Flutter ripple (in scope):** the Pigeon `StreamId` enum
(`…/Pigeon/cambrian_ios_camera_api.g.swift`, the `.dart` and `.kt` generated
mirrors, and the `pigeons/*.dart` DSL) and `TextureBridge.swift` rename
`processed → primary`. The Pigeon files regenerate; `TextureBridge` already moves
because §3.7 removes `.natural` from the same enum. (Flutter preview already uses
the processed lane, so behavior is unchanged — only the name.)

### 3.4 Terminate the stream WITH the error — CameraKit owns terminal-vs-transient

Today a camera failure *finishes* the frame `AsyncStream` silently while the error
goes to a separate `errorStream()` (`CameraEngine.swift:605`). To a puller that
looks like a clean EOF — the mosaic stops with nothing surfaced.

Change: the per-lane stream is an **`AsyncThrowingStream<Frame, Error>`** that
**finishes-with-error**. Crucially — and this is the owner's design point —
**CameraKit decides which errors are terminal.** CameraKit is built to recover
from transient faults (it retries, re-arms). A transient error does **not**
terminate the lane; the lane keeps yielding after recovery. Only an error
CameraKit judges **terminal** (`CameraError.isFatal == true`, e.g.
`maxRetriesExceeded`) ends the stream by throwing. `errorStream()` remains for
observability/non-fatal signals, but the *frame lane* now carries the terminal
verdict itself, so the consumer's single `for try await` loop sees EOF (finish)
vs failure (throw) without racing a second channel.

### 3.5 `CameraFrameMetadata` — real typed sensor decision fields

Define the camera's concrete metadata:

```swift
public struct CameraFrameMetadata: FrameMetadata {
    public let settled: Bool            // AE && WB && focus all converged
    public let focusState: FocusState   // .converged | .adjusting | .unknown
    public let wbState: WhiteBalanceState
    public let exposureState: ExposureState
}
```

Rule (owner's): **anything the stitcher branches on must be a typed member of the
concrete metadata** — never a JSON blob. `settled` gates the first-writer-wins
mosaic seed (EvaScan ADR-006): a mid-autofocus frame must not seed the mosaic.

This is **real plumbing, not a one-line field.** Today `CaptureMetadata` is
stubbed — `MetalPipeline` builds a zero-valued placeholder (~:630) and the
completion handler hardcodes its quality fields (~:690–691). The true sensor
state lives in `device.lastSnapshot` (`DeviceStateSnapshot`: AE-adjusting flag,
WB-settled signal, lens position) and was never threaded into `Frame`
construction. This change threads it in. `settled = AE-converged && WB-settled &&
focus-converged`.

### 3.6 3 Hz `frameResultStream` carries a JSON debug payload

Keep the existing ~3 Hz `frameResultStream` (`CameraEngine.swift:548`) as the
**off-hot-path, debug** channel. Heavyweight, occasionally-needed diagnostics —
current AF status, WB settling progress, full AE state — are **already produced by
the camera library**; we just forward them. Carry them as a **JSON payload** on
`FrameResult` (extensible, debug-grade, not parsed for control decisions).

The split is the point: **decision-driving signals are typed, per-frame, on
`CameraFrameMetadata` (§3.5); debug detail is JSON, low-rate, here.** Nothing
branches on the JSON; it exists so a human can answer "why didn't it settle?"
without a rebuild.

**Disposition of `ProcessingMetadata`.** The old `FrameSet` carried *two*
metadata structs: `CaptureMetadata` (sensor state → routed to
`CameraFrameMetadata` typed fields + this JSON, §3.5) and **`ProcessingMetadata`**
(`cropRegion`, `brightness`, `contrast`, `saturation`, `gamma`,
`whiteBalanceGains` — the grade parameters, `ProcessingMetadata.swift:15–37`).
**Nothing branches on the grade parameters**, so they are **not** per-frame typed
metadata — fold them into the 3 Hz JSON debug payload here (they change only when
the consumer reconfigures grading, so per-frame delivery was always redundant).
`cropRegion` specifically is consumer-driven (the consumer set it), so echoing it
per-frame is pure redundancy; the JSON channel is sufficient for confirmation/debug.

### 3.7 Cut the streaming `natural` lane — keep `captureNaturalPicture` (folds `remove-natural-lane`)

**Critical distinction:** remove the *streaming natural lane*; keep the *natural
still-capture API* and the *internal 16F natural texture*.

- **Remove:** `StreamId.natural`, the natural `Frame` lane, Pass-7n (the BGRA8
  convert), the `naturalPool`/`eightBitNaturalPool` allocations, the
  `latestNaturalBuffer` mailbox + its yield (`MetalPipeline.swift:694,707`), and
  `SessionCapabilities.naturalTextureId`. Saves a GPU pass + a pooled buffer every
  frame. The streaming lane was debug-only; the two real consumers (stitcher,
  Flutter preview) use `.primary`.
- **Keep & repoint:** `captureNaturalPicture` (the public still-capture API)
  becomes an **on-demand readback** from the preserved 16F natural working texture
  (`latestNaturalTex16F`, the Pass-1 output), converting to BGRA8 at capture time.
  The signature is unchanged; only the implementation moves off the deleted
  streaming mailbox. (If Pass-7n stayed just to feed the mailbox, no GPU pass would
  be saved — so the readback path is what makes the cut real.)
- **Preserve:** the internal 16F natural texture + its Pass-1 write, because WB/BB
  calibration samples it. Calibration is unaffected.

### 3.8 Crop rework (folds `camera-crop-config`; independent, can ship first)

- **Validate `captureResolution` against `SessionCapabilities.supportedSizes`.**
  Reject an unsupported size with a clear configuration error instead of silently
  accepting it. `nil` keeps device-default behavior. *(The one breaking change in
  this group.)*
- **New `setCenterCrop(width:height:offsetX:offsetY:)`.** Crop = a size plus an
  optional center displacement (ratio of active dimensions). CameraKit computes the
  pixel ROI: even centerpoint, even extents, clamped fully in-bounds. Layers over
  the existing `setCropRegion` rebuild path.
- **Crop as enable/disable with a remembered default.** Disabled (full-frame) by
  default; `setCropEnabled(_:)` + an open-time flag turn it on. Enabling with no
  configured geometry applies the **`Constants.cropDefault*` (1440×1440)** centered
  and clamped. Disabling → full-frame; re-enabling restores the last geometry.
- **Wire `Constants.cropDefault*` into `open()`** so it is the single source of the
  default crop size — no longer vestigial. (Earlier "delete it / wire it" open
  question is resolved: **wire it.**)
- *Reused:* open-time `Rect` via `OpenConfiguration.cropRegion`, `validateCropRegion`
  bounds/even checks, the live `setCropRegion(_:)` rebuild.

### 3.9 `lockedPixels() -> (ptr, bytesPerRow, lease)` — a lease-returning borrow helper

Every IOSurface consumer today re-implements `CVPixelBufferGetIOSurface →
IOSurfaceLock(.readOnly) → baseAddress → matching unlock+release` by hand — both
landmines (wrong unlock, missing release) live there. Provide one helper on the
lane buffer that returns a **lease** (an object whose `deinit` unlocks+releases),
**not** a scoped `withLockedBytes { }` closure. The scoped form unlocks at closure
exit, which is far too short for the ECC hold (~300 ms on the consumer side); the
lease stays alive for the full pipeline hold. `PixelHandle` (§2.2) *is* this lease
on the shared side; `lockedPixels()` is the CameraKit-internal constructor for it.

### 3.10 Removals

- **`blurScore` / `trackerQuality`** — hardcoded `0.0` / `.good`
  (`MetalPipeline.swift:690–691`); the contract advertises GPU signals it never
  computes. **Remove** them (and the `TrackerQuality` enum). If a consumer ever
  needs them, implement honestly (a GPU gradient/Laplacian reduction in the tracker
  downsample); until then the stitcher's own `QualityGate` covers the equivalent.
- **`FrameSet: Hashable`** — gone with `FrameSet` itself; a transient pool-backed
  GPU envelope being value-equatable by `(frameNumber, captureTime)` was
  misleading (frames "equal" across sessions; nothing consumed the hash).
- **C-ABI `PixelSink` / `PixelSinkPool`** — remove the entire C-ABI path: the
  `CameraKitCxx` sink (`PixelSink.hpp`, `PixelSinkPool.cpp`,
  `PixelSinkCallbacks.h`, `PixelSinkMetrics.h`, `CaptureAtomic`), its
  `CameraKitInterop` bridge, and the C-ABI dispatch wiring in `CameraEngine`. Its
  `onFrame` IOSurface is **"valid for call only"** — it structurally cannot support
  the consumer's bounded hold without a copy, and the Swift `subscribe()` path
  (refcounted, holdable) is strictly better. **Keep** the Swift `subscribe()` API
  (it merely shares the `PixelSink.swift` file — split the file).
  **Known, accepted breakage:** the `ios_example_app` AppCxx demos (Canny/Counter
  consumers, `DisplayViewModel`, `Stage08CannyTests`, `CABIParityTests`) and the
  Flutter demo consume the C-ABI path. **They are left broken for now** (owner's
  call) — do not spend effort repairing them in this rework.

### 3.11 Fix the tracker-fallback landmine

`MetalPipeline.swift:655`: `let trackerForSet = trackerBuf ?? processedForSet`
substitutes the full-res primary buffer under the `.tracker` label when no tracker
subscriber exists. With per-lane delivery the tracker lane simply **does not yield
when unsubscribed/unrendered** — it is genuinely absent, never substituted. (Owner:
"if tracker not subscribed, it should not be available at all.")

### 3.12 Rejected for now: grayscale tracker

A single-channel `gray8` tracker would save the consumer's `cvtColor`, but it is
**not a current spec requirement** — keep the tracker BGRA8. `PixelFormat` reserves
`gray8` for when the motion estimator's input contract actually calls for it.

### 3.13 Tracker resolution is consumer-specified (contract)

The motion estimator is tuned to a **fixed input size**, so the consumer must be
able to dictate the tracker resolution. CameraKit already exposes
`OpenConfiguration.trackerHeight` (aspect-preserving, clamped, even). At the 1440²
square working resolution, height-only yields an exact square (480² default, or
512² for a vDSP radix-2 backend). The contract: **one `motionInputSize` in the
consumer drives both** the camera's `trackerHeight` and the file decorator's target
(§4.4); a source that cannot produce exactly that size is a configuration error,
not a silently re-resized frame. *(Height-only suffices while the working res is
1:1 square; a non-square working res would need a full `Size`. Noted, not built.)*

---

## 4. `mac-stitch-video` (EvaScan) changes

### 4.1 Adopt `FrameTransport`; delete the old vocabulary

`NextFrame`, `FrameBuffer`, and every per-source reinvention collapse into the
shared `Frame` / `PixelHandle` / `FrameMetadata`. `StitchProtocols` gains a
dependency on `.product("FrameTransport", package: "cambrian-ios-camera")`.

### 4.2 Revised `FrameSource` protocol

```swift
public protocol FrameSource: Sendable {
    var bufferingPolicy: BufferingPolicy { get }
    func frames() -> any AsyncSequence<Frame, any Error>
}
```

Justified against actual usage (grep over the repo):

- **Drop `width` / `height`.** Their *only* load-bearing reader was the stride bug
  itself — `FramePrefetchQueue.swift:78–80` sets `slot.width/height/stride_bytes`
  from `source.width`, computing stride as `source.width * 4`. Once `PixelHandle`
  carries dims+`bytesPerRow`, those three lines read from `frame.pixels` and the
  protocol fields have **zero remaining consumers**. (Every other `width*4` in the
  repo is a local at a buffer-construction site, not a protocol read.)
- **Drop `nominalFps`.** No engine/core code reads `source.nominalFps`; it is
  load-bearing only *inside* synthetic/recording sources that fabricate timestamps
  (`nanosPerFrame = 1e9 / nominalFps`). It stays a private field of the sources
  that self-pace and a persisted field of `RecordingManifest` — but it is **not** a
  protocol obligation every conformer must invent. (See §4.5 for the override.)
- **`prefersLatestWins: Bool` → `bufferingPolicy: BufferingPolicy`.** One consumer
  (`CoordinatorLifecycle.swift:22 → setOverflowDropOldest`) becomes a `switch`. The
  Bool could not express the tracker's `keepBuffered(depth:)`; the enum can, and
  also expresses the offline `.blocking` mode.
- **`next() -> Frame?` → `frames() -> AsyncSequence`.** The nil-as-EOF + throw pair
  was two termination channels. An `AsyncSequence` has exactly one termination
  model — **finish = EOF, throw = error** — which is *the same* model CameraKit
  adopts in §3.4. The payoff: the camera adapter (§4.3) stops translating
  termination conventions; it forwards CameraKit's stream directly.

### 4.3 `CameraKitLiveFrameSource: FrameSource` (near-zero adapter)

iOS-only target; imports CameraKit + FrameTransport. Because both sides speak
`Frame` and the same termination model, the body collapses to essentially
"return the lane's stream":

```swift
struct CameraKitLiveFrameSource: FrameSource {
    let bufferingPolicy: BufferingPolicy        // .latestWins (primary) | .keepBuffered (tracker)
    func frames() -> any AsyncSequence<Frame, any Error> {
        engine.subscribe(stream: lane.asStreamId, buffering: bufferingPolicy)
    }
}
```

No `FrameSet → NextFrame` repack, no stride recompute, no `errorStream` race. One
instance per lane (lanes stay separate — owner's decision).

### 4.4 `TrackerDerivingSource` — a fan-out for non-camera sources

The two-stage split (§4.6) makes `.tracker` a **universal contract**: every source
must vend a downscaled lane for the motion estimator, not just the camera. Only the
camera gets it free (GPU). Every other source synthesizes it.

Mechanism: a **fan-out** (not a pull-through decorator). It decodes/generates a
frame **once**, then emits the full-res frame on `.primary` *and* a CPU-downsampled
copy on `.tracker`, **both stamped with the same `index`**:

```
file/synthetic decode ──┬─ full-res ───────────────▶ .primary  (latestWins)
   (index N)            └─ cv::resize → motionSize ─▶ .tracker  (keepBuffered(N))
                                          both Frames carry index N
```

It must be a fan-out, not a "pull the primary and derive," because under
`.latestWins` a pull-through deriver and the align stage would be two competing
consumers of one primary stream. The fan-out mirrors the camera's GPU split
exactly. The downsample target is the consumer's `motionInputSize` (§3.13). One
tested downsample path instead of four sources each reinventing `cv::resize`.

### 4.5 `nominalFps` override (playback speed / pressure-testing)

Sources that self-pace (video-file, recording) self-pace at
**`fpsOverride ?? recordedNominalFps`**. The override is an external input so the
owner can replay a recording **faster than real time** — to preview quickly and,
importantly, to **pressure-test the pipeline** (drive frames at the queues faster
than ECC can keep up and watch the drop/`keepBuffered` behavior). The override is a
source construction parameter, *not* a protocol field — consistent with dropping
`nominalFps` from `FrameSource` (§4.2).

### 4.5a Demand-decode is the offline file/replay mechanism (reconciling two approvals)

Two of the owner's approvals look contradictory until separated by **mode**, and
both are correct:

- **Real-time video playback** (§4.5): source-paced at `fpsOverride ?? nominalFps`,
  `.primary` = `latestWins`, `.tracker` = `keepBuffered(N)`. **Drops** frames under
  load — the camera's shape. Used when the owner wants to *watch* a recording or
  *pressure-test* the pipeline.
- **Offline/deterministic** (`.blocking`): **demand-decode** — the
  `AsyncSequence`'s iterator decodes exactly one frame per `next()`, so it is
  **pull-native, consumer-paced, back-pressured, and lossless** (no `AsyncStream`
  buffer, nothing dropped). Used when correctness/completeness matters over
  wall-clock: recording-playback tests, WSI batch, golden-frame comparisons.

The selector is `BufferingPolicy`: `.blocking` ⇒ demand-decode, lossless,
lockstep; `.latestWins`/`.keepBuffered` ⇒ real-time, source-paced, drops under
load. A file source can run in *either* mode — same source, different policy. So
"demand-decode for file/replay" (approved) and "video files play at recorded fps"
(approved) are not in tension: they are the offline and real-time modes of the same
source, chosen by policy.

### 4.6 Split the pipeline in two (bundled into this rework)

EvaScan's pipeline splits into two stages with **decoupled cadences on separate
threads**, handed off by an index-keyed `poseStore`:

- **Motion stage** — consumes `.tracker` **every frame** (`keepBuffered(depth)`),
  cheap coarse motion. Writes `poseStore[index] = pose`.
- **Align/ECC stage** — consumes `.primary` **latest-wins**, aligns the newest
  primary frame at pickup (~300 ms cycles), seeds ECC by reading
  `poseStore[index]`, writes `committedPose` back to the first-writer-wins
  admission gate (ADR-006).

`poseStore`: a mutex-guarded `index → pose` map, gap-tolerant lookup, **capacity
128** — sized for the worst case of 60 fps × 1800 ms ECC ≈ 108 in-flight frames,
plus headroom. Both writer and reader are C++ threads, so the store is C++-internal
(a Swift actor would add a hop per frame).

**This document specifies the seam, not the internal thread/queue topology.** The
contract is fixed (motion eats `.tracker` every frame; ECC eats `.primary`
latest-wins; handoff via index-keyed `poseStore`; ECC aligns newest-at-pickup). The
exact thread/queue boundaries are **left to the implementing agent** to design
within that contract. Constraint from doc 02 that must hold: keep the C++ input
queues and C++-owned, thread-pinned execution — do **not** collapse to a
Swift-driven synchronous `processFrame` (it would undo pinning and re-serialize
motion behind ECC).

### 4.7 Stride fix

`slot.stride_bytes = frame.pixels.bytesPerRow`, never `width * 4`
(`FramePrefetchQueue.swift:80`). IOSurface stride is padded; the assumption
silently corrupts rows whenever width isn't 64-aligned. `slot.width/height` also
read from `frame.pixels`.

### 4.8 `groundTruthPose` → producer metadata

`groundTruthPose` is source-specific (synthetic/WSI/Narwhal attest it; camera and
video-file cannot — they hardcode `nil` today). It moves **off** the universal
envelope into a concrete metadata type, e.g. `SyntheticFrameMetadata.groundTruthPose`,
read via a small `GroundTruthAttesting` protocol:
`slot.has_ground_truth = (frame.metadata as? GroundTruthAttesting) != nil`
(`FramePrefetchQueue.swift:84–86`). `CameraFrameMetadata` simply doesn't have it.
This is the same principle as `settled` — producer-specific decision data is typed,
on the concrete metadata, not a universal field two-thirds of sources fake.

### 4.9 Seed gate

The motion-seed admission can gate on either CameraKit's `settled`
(`CameraFrameMetadata`, §3.5) *or* the stitcher's existing `QualityGate` (LV/TG
floors) — they are complementary. Lean: self-gate via `QualityGate` for the "don't
seed a soft frame" need; additionally honor `settled` when the source attests it
(camera does; file sources don't carry it). The motion estimator consumes the
supplied `.tracker` directly — it no longer `cv::resize`-es the full frame
(redundant; the tracker already lands at `motionInputSize`).

### 4.10 Resolution sweep 1600×1200 → 1440×1440

The owner's mandate: **no more 1600×1200 anywhere; all input defaults are
1440×1440.** This is entangled, not a single constant:

- **Defaults (blind-editable):** `SyntheticFrameSource` (`:27`),
  `SyntheticRecordingBuilder` (`:28/30`), `Apps/{Mac,IOS}App/Debug/DebugSyntheticRecording`
  (`:34`), `SyntheticRecordingSpike/main.swift` (`:26`), WSI harness defaults →
  `1440×1440`.
- **Test-pinned (regenerate, don't blind-edit):** `StaticDemoFrameTests` asserts a
  bundled **1600×1200 PNG** — **regenerate the asset at 1440×1440** and update the
  test; `MockStitchCoordinatorTests` (`:89–90`); the C++ `FrameQueueTests`
  (`:48–50,76–77,241–243`, stride `1600*4`), `QualityGateTests` (`:75,84`),
  `CandidateQueueTests` (`:88–89`), `MotionEstimatorTests` (`:59`). **Rewrite every
  test that relies on a 1600×1200 frame to use 1440×1440.**
- **Calibrated (amend with recalibration note, don't silently swap floors):**
  **ADR-043** (`docs/decisions.md:1388–1414`, "Input 1600×1200") → amend to state
  **1440×1440** and the v0 ceiling, with an explicit *"LV/TG floors need
  recalibration at 1:1 / 2.07 MP"* note; `algorithms.md` §10/§12 LV/TG floor tables
  (`:277,812–813`); `Tuning.hpp:20`; `QualityGate.hpp:36`. The hard-floor *values*
  are calibrated against 1600×1200's pixel count and 4:3 aspect — changing the
  number without recalibration makes the records wrong, so amend the prose + flag
  recalibration as separate work; do not fabricate new floor numbers here.

### 4.11 Per-lane pool sizing

Per-lane `MinimumBufferCount = 5` on the `.primary` and `.tracker` pools (natural
pool gone). `.primary` is **held zero-copy** across ECC (large; copying ~240 MB/s
of mostly-dropped frames is wasteful, and a held `CVPixelBuffer` pins its pool slot
— verified safe). `.tracker` is **copied** on pickup (small, lossless, no pool
pinning). Watch `holdOverBudgetByLane` / `poolExhaustion`.

---

## 5. Cross-cutting contracts

- **Correlate by `index`** — session-scoped (resets per `open()`), gaps expected
  (latest-wins drops on `.primary`). Both lanes carry the same `index` +
  `timestampNs`.
- **Buffering policy by mode, not by source type:**

  | Mode | `.primary` | `.tracker` | Sources |
  |------|-----------|-----------|---------|
  | **Real-time** | `latestWins` | `keepBuffered(N)` | camera, **video-file playback** |
  | **Offline/deterministic** | `blocking` | `blocking` | recording-playback tests, WSI batch |

  Video-file *playback* behaves like the camera (it plays at recorded fps, §4.5),
  so it is real-time, not lockstep. `.blocking` is reserved for genuinely offline
  deterministic processing.
- **One termination model** — finish = EOF, throw = terminal error — on both the
  CameraKit stream and the EvaScan `FrameSource`. CameraKit decides terminal vs
  transient (§3.4).
- **Timestamp in nanoseconds end-to-end** — convert `CMTime → ns` once at
  CameraKit's `Frame` construction; no per-frame `CMTimeConvertScale` downstream.
- **A single camera failure surfaces on both lanes** — the coordinator dedupes
  (report once; tear down `poseStore` after both stages join).

### DO NOT

- Do **not** make CameraKit depend on `StitchProtocols`, or conform to
  `FrameSource`. CameraKit is the producer and a Flutter plugin; `FrameSource` is
  the consumer's pull abstraction. The dependency arrow is EvaScan → FrameTransport
  ← CameraKit, never CameraKit → EvaScan.
- Do **not** put `Frame`/`PixelHandle` inside the CameraKit module — it breaks
  EvaScan's macOS build (AVFoundation). They live in neutral `FrameTransport`.
- Do **not** route the stitcher through the C-ABI `PixelSink` path — its IOSurface
  is call-scoped and cannot support the ECC hold without a copy. (It is being
  removed anyway, §3.10.)
- Do **not** collapse the two-stage pipeline into a Swift-driven synchronous
  `processFrame` — it undoes C++ thread pinning and re-serializes motion behind
  ECC. Keep the C++ input queues.
- Do **not** bundle the two lanes into one element or one cadence — the dual-rate
  requirement (tracker every frame, primary gated) forbids a shared cadence. Two
  streams, correlated by `index`.
- Do **not** vend `.tracker` by re-resizing the full frame in the motion estimator
  — consume the supplied `motionInputSize` tracker (GPU for camera, fan-out for
  files).
- Do **not** make a pull-through `.tracker` deriver — under `.latestWins` it
  competes with the align stage for the primary stream. Fan out at the decode.
- Do **not** force the Flutter preview to copy — the `@unchecked Sendable` lease is
  sound for concurrent readers of the immutable, single-writer buffer; pool sizing
  absorbs the display hold.
- Do **not** silently re-resize a tracker frame that arrives at the wrong size —
  size mismatch vs `motionInputSize` is a configuration error.
- Do **not** substitute the primary buffer under the `.tracker` label when tracker
  is unsubscribed — it must be genuinely absent (§3.11).
- Do **not** silently change EvaScan's calibrated LV/TG floor *values* during the
  1440 sweep — amend the prose + flag recalibration as separate work (§4.10).

---

## 6. OpenSpec reconciliation

Active OpenSpec changes in `openspec/changes/` and how this document relates:

| Change | Disposition |
|--------|-------------|
| **`camera-crop-config`** | **Folded into §3.8.** It is a real CameraKit behavior change (crop-on-open, center-crop ergonomics, enable/disable, `cropDefault*` wired into `open()`, `captureResolution` validation). Independent of frame-delivery; may land first. Keep the change; this doc is its design context. |
| **`remove-natural-lane`** | **Folded into §3.7.** Cuts the streaming natural lane only; keeps `captureNaturalPicture` (repointed to 16F readback) and calibration. Keep the change. |
| `frame-delivery-contract` *(deleted)* | Content absorbed by §2, §3.2–3.4, §4. |
| `frame-metadata-signals` *(deleted)* | Content absorbed by §3.5, §3.6, §4.8. |

**Gaps — work this document mandates that has no OpenSpec change yet:**
1. The **`FrameTransport` package** itself (§2) — new product, the spine of the
   rework. No change covers it.
2. The **EvaScan-side rework** (§4) — lives in the other repo; this repo's OpenSpec
   tracks only the CameraKit half. The EvaScan changes need their own tracking in
   `mac-stitch-video`.
3. The **lane rename + `AsyncThrowingStream` + per-lane `BufferingPolicy` +
   terminal-error semantics** (§3.2–3.4) — the heart of the delivery change, now
   uncovered after the two changes above were deleted.

Recommendation: create OpenSpec changes for (1) `frame-transport-package` and
(3) `frame-delivery-rework` in this repo, and track (2) separately in EvaScan.

---

## 7. Implementation sequence (dependency-ordered)

1. **`FrameTransport` package** (§2) — neutral types, builds on iOS + macOS. The
   spine; everything imports it.
2. **CameraKit crop rework** (§3.8) — independent; can land and ship first.
3. **CameraKit frame-delivery rework** — `FrameTransport` adoption, per-lane
   `subscribe(stream:buffering:) → AsyncThrowingStream<Frame>`, lane rename
   `processed→primary` (+ Flutter Pigeon/TextureBridge), terminal-error stream
   (§3.1–3.4), tracker-fallback fix (§3.11).
4. **CameraKit metadata + cleanup** — `CameraFrameMetadata` real plumbing (§3.5),
   JSON debug on the 3 Hz stream (§3.6), `lockedPixels()` lease (§3.9), remove
   `blurScore`/`trackerQuality`/`FrameSet:Hashable`/C-ABI `PixelSink` (§3.10).
   *(AppCxx + Flutter demos left broken — §3.10.)*
5. **CameraKit cut natural lane** (§3.7) — depends on the `Frame` shape (3) landing.
6. **EvaScan shared-contract adoption** (§4.1–4.2, 4.7) — adopt `FrameTransport`,
   revised `FrameSource`, stride fix; builds on Mac against existing sources.
7. **EvaScan camera adapter** (§4.3) — `CameraKitLiveFrameSource`, two lanes;
   validate against real CameraKit on device.
8. **EvaScan tracker fan-out + two-stage split** (§4.4, 4.6) — `TrackerDerivingSource`,
   motion/ECC threads, `poseStore(128)`, newest-at-pickup, metadata moves (§4.8–4.9),
   `nominalFps` override (§4.5).
9. **EvaScan resolution sweep + tuning** (§4.10–4.11) — 1600→1440 defaults, regen
   PNG, rewrite tests, amend ADR-043/algorithms with recalibration note; per-lane
   pool=5.

---

## 8. Diagrams

### 8.1 End-to-end data flow

```
 cambrian-ios-camera repo                         FrameTransport (neutral)        mac-stitch-video repo
 ───────────────────────────────────             ───────────────────────         ─────────────────────────────────

 ┌───────────────────────────────┐
 │ CameraEngine / MetalPipeline   │   one capture N
 │  GPU fan-out                   │──────────────┐
 └───────────────────────────────┘              │
        │ .primary (1440²)        │ .tracker (motionInputSize, GPU)
        ▼                         ▼
  subscribe(.primary,        subscribe(.tracker,
    .latestWins)               .keepBuffered(N))
        │                         │
        │  AsyncThrowingStream<Frame>   ··· Frame{lane,index,tsNs,pixels:PixelHandle,metadata:CameraFrameMetadata}
        ▼                         ▼
  ┌──────────────┐         ┌──────────────┐      Frame ════════════▶  CameraKitLiveFrameSource: FrameSource
  │ primarySource│         │ trackerSource│                                (iOS-only adapter, near-zero)
  └──────┬───────┘         └──────┬───────┘
         │ latest-wins            │ every frame
         ▼                        ▼
   [C++ ECC queue cap1]    [C++ motion queue keepBuffered]
         │                        │
         │                        ▼
         │                 ┌──────────────────┐  MOTION stage (own thread, every frame)
         │                 │ MotionEstimator  │  poseStore[index] = pose ─────┐
         │                 └──────────────────┘                               │
         ▼                                                                     │
  ┌──────────────────┐  ALIGN/ECC stage (own thread, ~300 ms)                 │
  │ align → ECC → blend│  read poseStore[index]  (seed) ◄──────────────────────┘
  │  newest-at-pickup  │  committedPose ─► first-writer-wins admission (ADR-006)
  └──────────────────┘   │
                         ▼
                    MosaicSink

 Non-camera sources (file/synthetic), real-time playback at fpsOverride ?? nominalFps:
   decode N once ─┬─ full-res ──────────────▶ .primary  (latestWins)   ┐  TrackerDerivingSource
                  └─ cv::resize→motionSize ─▶ .tracker  (keepBuffered) ┘  (fan-out; both index N)
   Offline/test sources use .blocking on both lanes (lockstep, no drift).
```

### 8.2 Type structure

```
FrameTransport (neutral package, iOS + macOS)
│
├── struct Frame : Sendable
│     ├── lane:        Lane            (.primary | .tracker)
│     ├── index:       UInt64          (correlation key; session-scoped; gaps allowed)
│     ├── timestampNs: Int64
│     ├── pixels:      PixelHandle
│     └── metadata:    any FrameMetadata
│
├── final class PixelHandle : @unchecked Sendable   (deinit unlocks + releases)
│     ├── baseAddress: UnsafeRawPointer
│     ├── width, height, bytesPerRow: Int            (bytesPerRow = real IOSurface stride)
│     └── format: PixelFormat                        (.bgra8 ; gray8 reserved)
│
├── protocol FrameMetadata : Sendable                (marker)
│     ├── CameraFrameMetadata    { settled, focusState, wbState, exposureState }   (CameraKit)
│     ├── VideoFileFrameMetadata { presentationTimestamp, trackIndex }             (EvaScan)
│     └── SyntheticFrameMetadata { groundTruthPose }  : GroundTruthAttesting        (EvaScan)
│
├── enum Lane { primary, tracker }
├── enum PixelFormat { bgra8 /* gray8 reserved */ }
└── enum BufferingPolicy { blocking | latestWins | keepBuffered(depth: Int) }

CameraKit (iOS)                          EvaScan / StitchProtocols (Mac + iOS)
└── subscribe(stream:buffering:)         └── protocol FrameSource : Sendable
      -> AsyncThrowingStream<Frame>            ├── var bufferingPolicy: BufferingPolicy
    (lane rename processed→primary)            └── func frames() -> any AsyncSequence<Frame, any Error>
                                             implementors: CameraKitLiveFrameSource (adapter),
                                                           VideoFileFrameSource, SyntheticFrameSource,
                                                           TrackerDerivingSource (fan-out), …
```

### 8.3 Lane / policy / rate matrix

```
                  .primary (full-res → align/ECC)     .tracker (downscaled → motion)
                  ───────────────────────────────     ──────────────────────────────
 camera           latestWins,  GPU, 1440²             keepBuffered(N), GPU, motionInputSize
 video (play)     latestWins,  decode                 keepBuffered(N), fan-out resize
 offline/test     blocking,    decode (lockstep)      blocking,        fan-out resize (lockstep)

 rate             gated on ECC (~300 ms)               every frame (~30/60 fps)
 lifetime         HELD zero-copy across ECC            COPIED on pickup
 correlate        ───────────────  by frame.index  ───────────────
```
