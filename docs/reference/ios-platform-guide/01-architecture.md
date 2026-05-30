# 01 — Core Architecture

The minimal correct architecture for an iOS app with the shape: camera → Metal processing
→ SwiftUI preview, optionally with C++ image analysis.

**Starting point: two files. Extend only when a domain requirement demands it.**

---

## ADR-01: Two-file baseline

The whole thing fits in two files. Every additional file you introduce should map to a
genuine boundary in the domain, not to a textbook layer name.

```
Sources/
├── CameraView.swift                     ~150 lines
│   ├── struct CameraView: View              // SwiftUI root
│   ├── struct MetalCameraView:              // inline UIViewRepresentable
│   │     UIViewRepresentable
│   └── @Observable final class ViewModel    // receives Sendable results
│
└── CameraEngine.swift                   ~250 lines
    ├── actor CameraEngine                   // all state
    ├── final class CaptureDelegate:         // NSObject, runs on
    │     NSObject, AVCaptureVideo...        //   serial session queue
    └── struct DetectionResult: Sendable     // Sendable boundary type
```

### The four moving parts

1. **SwiftUI View** — overlays, buttons, labels. Owns an `@Observable` view model.
   Never sees a pixel buffer.
2. **`UIViewRepresentable` wrapping `MTKView`** — the bridge. Creates the `MTKView`,
   hands it to `CameraEngine` so the engine can draw into it. Lives in the same file
   as the SwiftUI view — it's an implementation detail, not a layer.
3. **`actor CameraEngine`** — owns everything stateful and dangerous:
   `AVCaptureSession`, `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`, the
   capture delegate. All threading rules live inside one type.
4. **`AsyncStream<T: Sendable>`** — the one-way pipe out. Engine yields Sendable
   structs. View model `for await`s them on `@MainActor`. No buffers, no Metal
   objects, no C++ types ever cross this boundary.

### What the original three-layer "sandwich" pattern gets wrong

A separate `UIKit middle layer`, a separate `@MLProcessor global actor`, and
retain/release handshakes for async C++ are pattern-theater for a problem that
collapses:

- The `UIViewRepresentable` is ~30 lines and belongs next to the view that uses it.
- There's only one isolation domain that needs to own state, so there's no reason to
  split it into two actors.
- Retain/release dances around `CVPixelBuffer` disappear when pixel buffers are
  confined to the engine.

Use the three-layer shape only if you find yourself *actually* needing the boundary
it encodes. Don't introduce it speculatively.

---

## ADR-02: Single heavy isolation domain

```
┌─────────────────────────┐         ┌────────────────────────────┐
│  @MainActor             │         │  actor CameraEngine        │
│                         │         │                            │
│  • ViewModel            │         │  • AVCaptureSession        │
│  • SwiftUI Views        │         │  • Metal objects           │
│  • Overlay state        │         │  • Texture cache           │
│                         │         │  • Capture delegate        │
│  receives:              │◄────────│    (serial session queue)  │
│  Sendable results       │  only   │                            │
│                         │  Sendable                            │
└─────────────────────────┘         └────────────────────────────┘

        UI thread                        everything heavy
    (nothing hot here)                   (one isolation domain)
```

The Sendable problem disappears because nothing non-Sendable ever tries to cross.
Full Sendable rules in `02-concurrency.md` ADR-10.

Note: the `AVCaptureSession` itself must be driven from a dedicated serial `DispatchQueue`,
not from inside the actor directly — see `ADR-07`. The engine actor *coordinates* with
that queue; it does not *replace* it.

### Principle: one actor per lifecycle

`CameraEngine` has one lifecycle — start camera → run → stop. Anything with a
*different* lifecycle (stitching state, file I/O for captures, ML model loading and
warmup) belongs in its own actor consuming from a Sendable `AsyncStream`. Cite this
principle when deciding whether a new responsibility collapses into the engine or
splits out. The failure mode is the god-object engine that owns three lifecycles
and races on teardown.

### Forbidden: the `Task { await engine.process(...) }` frame hop

The naive Swift 6 shape for a sync delegate calling into an actor is:

```swift
// ❌ DO NOT DO THIS
func captureOutput(_ output: AVCaptureOutput,
                   didOutput sampleBuffer: CMSampleBuffer,
                   from connection: AVCaptureConnection) {
    Task { [engine] in
        await engine?.process(sampleBuffer)   // one Task allocated per frame
    }
}
```

Three concrete failures:

1. **Lost capture-order ordering.** Detaching to a `Task` means two frames can be
   in flight into the actor simultaneously; the actor serializes them but the
   order is no longer guaranteed to match capture order under contention. Drift
   correction and any temporal algorithm silently misbehaves.
2. **Per-frame Task allocation** at 30–60fps is measurable overhead with no benefit.
3. **`CMSampleBuffer` / `CVPixelBuffer` retention across the hop drains AVFoundation's
   finite buffer pool.** If Tasks back up (main-thread stalls, thermal throttling),
   capture stalls hard.

The correct shape: the delegate runs on the delivery `DispatchQueue`, is
`nonisolated`, and does *all* per-frame work inline — lock base address, wrap in
`cv::Mat`, invoke C++, encode Metal passes, commit. The actor is touched only for
state changes that are not per-frame (open / close / setResolution). See the
per-frame command graph below and `02-concurrency.md §The frame clock never hops a
Swift actor boundary`.

---

## ADR-03: Direct GPU outputs vs async consumers

Not everything downstream of Metal is a "consumer." Two distinct categories with very
different timing contracts.

### Direct GPU outputs (sinks)

Metal writes to these on the frame clock. They **never** block or drop — preview
smoothness depends on them keeping up. Implemented as passes or blits inside the
per-frame command buffer.

| Sink | Mechanism |
|---|---|
| Natural preview | `MTKView` blit from `naturalTex` (on the frame clock) |
| Video encoder | `AVAssetWriterInputPixelBufferAdaptor` + IOSurface pool (compute; RGBA16F → NV12 conversion; gated on `isRecording`) — see ADR-06 |
| Still capture readback | CPU-readable `CVPixelBuffer` blit from `processedTex`; gated on `stillRequested` — **not** `AVCapturePhotoOutput`, which bypasses Metal |

The natural MTKView blit draws from the same IOSurface as `FrameSet.natural` — written
in the same command buffer pass — so display and async consumers are always bit-identical.
Still capture uses `processedTex` so it captures crop + color ops, matching the processed
consumer path. `processedTex` has no display MTKView — it feeds recording, still capture,
and the async consumer subscription system only.

**Canny preview MTKView is NOT a direct GPU output.** It is driven by the async C++
edge detection consumer:

1. C++ receives `FrameSet.tracker` (480p, downsampled from processedTex).
2. C++ runs `cv::Canny` on a zero-copy `cv::Mat` → edge mask at tracker resolution.
3. C++ composites: reads full-res image pixels (from `FrameSet.natural` or `.processed` —
   Agent 3 decides) and overlays the scaled edge mask on top, producing a composited RGBA
   image at full resolution.
4. C++ writes the composited result into a **pre-allocated shared `MTLTexture`**
   (IOSurface-backed, full-res, mip-levels configured, allocated once at engine setup and
   reused every frame — no per-frame allocation). Writing is via `IOSurfaceLock` /
   `memcpy` / `IOSurfaceUnlock` on the backing surface.
5. Swift side receives a C-ABI callback from C++ signalling write-complete, then runs a
   Metal blit pass to generate mipmaps on the shared texture.
6. The canny `MTKView` renders the mipmapped shared texture with pan/zoom uniforms (origin
   + scale) for quality at any zoom level.

This render is asynchronous — it runs at Canny throughput, not the 30Hz frame clock.
Latest-wins mailbox ensures the canny MTKView always shows the most recent result without
blocking the natural preview.

### Async consumers

Things that **might** be slow and must not block preview. Delivered via a separate
async path with drop-on-busy semantics.

Typical consumers: C++ CV pipelines (edge detection, tracking, classification)
receiving processed full-res frames or a downscaled tracker stream.

**Rule: consumers are always async. Synchronous dispatch inside the capture delegate
is not acceptable** — if a consumer takes longer than the frame budget, AVFoundation
drops frames coarsely and the preview hitches. See ADR-13 in `05-interop.md` for the
dispatch mechanism.

---

## Per-frame command graph

One `MTLCommandBuffer` per camera frame. Passes are gated implicitly: if the feature
driving a pass is off (no recording, no tracker consumer, no still requested), that
pass is skipped. Gating is by conditional append, not by stub shaders.

```
CMSampleBuffer (8-bit biplanar YUV from capture)
   │
   ▼
CVMetalTextureCache → yTex (R8Unorm), cbcrTex (RG8Unorm)  [zero-copy; ADR-04]
   │
   Dequeue 3 pool buffers before passes run (ADR-18):
   naturalPoolBuf ← natural pool, processedPoolBuf ← processed pool,
   trackerPoolBuf ← tracker pool  [gated: consumer subscribed]
   │
   ▼
[commandBuffer begin]

Pass 1  compute   crop + YUV8 → RGBA16F → naturalTex (also → naturalPoolBuf)  per ADR-05
                  (BT.709 YUV-to-RGB; crop origin/size as uniforms)
Pass 2  compute   color transforms → processedTex (also → processedPoolBuf)
Pass 3  blit      naturalTex   → naturalMTKView drawable
                  (processedTex has no display MTKView; it feeds recording, still capture,
                  and consumer lanes only)
Pass 4  compute   processedTex → trackerTex (downsampled, aspect ratio preserved,
                  target height ~480p) → trackerPoolBuf           [gated: consumer subscribed]
Pass 5  compute   rgba16f → yuv8 → encoder pool buffer      [gated: recording]
Pass 6  blit      processedTex → still readback buffer      [gated: still requested]

[commit + present drawables + addCompletedHandler]
   │
   ▼
On GPU completion handler:
   construct FrameSet{frameNumber, captureTime, natural, processed, tracker,
                      capture metadata, processing metadata, blurScore, trackerQuality}
   publish to each subscribed lane's mailbox (see ADR-18, ADR-19)
   │
   ▼  (async, on consumer's own queue — NOT on the frame clock)
C++ edge detection consumer receives FrameSet.tracker:
   cv::Canny on zero-copy cv::Mat (tracker resolution)
   composites edge mask on top of full-res source image (natural or processed — Agent 3 decides)
   writes composited RGBA → pre-allocated shared MTLTexture via IOSurfaceLock/memcpy/Unlock
   C-ABI callback → Swift triggers Metal blit: generateMipmaps(for: sharedTexture)
   Metal render pass: mipmapped sharedTexture → cannyMTKView drawable (pan/zoom uniforms)
```

**Frame clock rule: nothing on the 30Hz frame clock hops a Swift actor boundary.**
The capture-delegate method is `nonisolated`, runs on the delivery queue, and builds
+ commits the command buffer inline. Completion-handler consumer publishing runs on
the delivery queue. UI updates are coalesced to one `Task { @MainActor in ... }` at
the end of the delegate method.

**Channel order is load-bearing.** Every texture in the consumer path
(`naturalTex`, `processedTex`, `trackerTex`) is `RGBA16F` with **R, G, B, A** channel
order. BGRA never appears in any stream a consumer touches — it only appears at the
encoder edge (Pass 5 output format). A consumer applying BT.709 luma weights must
use `(0.2126, 0.7152, 0.0722, 0.0)` in RGBA order; BGRA coefficients produce silently
wrong grayscale with no crash and no error. See G-18.

**Guarantees:**
- The pixels the async processed consumer sees are bit-identical to the pixels
  drawn to the processed preview `MTKView` — both come from the same `processedTex`
  in the same command buffer.
- Every intermediate texture is IOSurface-backed (ADR-06). The only copy in steady
  state is whatever the consumer does with the frame (e.g. `cv::cvtColor` into a
  fresh `cv::Mat`).
- Tracker stream is downsampled for a reason: Canny on full processed resolution
  (~1.9M px) costs 15–25ms per frame on A16-class hardware; at the tracker
  target height (~480p, ~0.3M px) it costs 2–4ms. The downsample is what makes
  per-frame CV fit the frame budget. Don't run CV on the full-resolution processed
  stream. Width is not fixed — it is calculated from processedTex.width × (480 /
  processedTex.height) to preserve aspect ratio.

---

## Extending the baseline

The 2-file model is a starting point. Extensions that are **always** justified for a
real camera product:

- **Split preview:** two `MTKView` instances wrapped by two `UIViewRepresentable`s
  inside `CameraView.swift`. Still one file.
- **Multiple async consumers:** consumer registry lives inside the engine actor OR
  inside a C++ pool the engine owns. Mechanism in ADR-13.
- **Recording:** Metal compute pass (RGBA16F → NV12 conversion) + `AVAssetWriter`
  coordination. Stays inside the engine. See ADR-06, ADR-16.
- **Still capture:** Metal blit pass + CPU readback. Stays inside the engine.

Extensions that need a **domain trigger** before being taken:

- Separate `RecordingActor`: only if recording teardown needs to outlive a scene
  transition and the engine's lifetime doesn't cover it.
- Separate pipeline module: only once the per-frame graph has >4 real
  domain-driven passes and the command-buffer orchestration no longer fits in the
  engine.
- Objective-C++ layer: never. See ADR-11.

---

## ADR-32: `CaptureDeviceProviding` dependency-injection seam for testability

The engine's state machine, error classifier, recovery backoff, settings merge, and
EXIF JSON schema are all pure-logic components that should be unit-testable without a
physical camera. To achieve this, `CameraEngine` must not depend on the concrete
`AVCaptureDevice`; it depends on a protocol (`CaptureDeviceProviding`) whose real
implementation wraps `AVCaptureDevice` and whose fake implementation supplies canned
format enumerations, focus modes, and capability bits for unit tests.

```swift
// Protocol exposes only the surface the engine actually touches.
protocol CaptureDeviceProviding: AnyObject {
    var uniqueID: String { get }
    var activeFormat: CaptureFormat { get set }
    var formats: [CaptureFormat] { get }
    var isFocusModeSupported: (FocusMode) -> Bool { get }

    func lockForConfiguration() throws
    func unlockForConfiguration()
    func setFocusMode(_ mode: FocusMode)
    func setExposureMode(_ mode: ExposureMode)
    // ...grown organically from engine's actual call sites
}

// Engine depends on the protocol.
actor CameraEngine {
    private let device: any CaptureDeviceProviding
    init(device: any CaptureDeviceProviding) { self.device = device }
}

// Unit tests supply a fake.
final class FakeCaptureDevice: CaptureDeviceProviding { /* canned */ }
```

### Discipline

- **Protocol grows organically.** Only methods the engine actually calls appear in it.
  No speculative surface.
- **Real implementation is a thin adapter.** It owns the real `AVCaptureDevice`
  instance and forwards calls; no logic lives in the adapter.
- **v1 requirement, not a v2 aspiration.** Phase 1a's first unit tests must already
  use the fake; the seam is not retrofitted later.

Cross-references: ADR-01 (two-file baseline), ADR-02 (isolation domain), ADR-33
(testing strategy — defined in `07-code-style.md`).
