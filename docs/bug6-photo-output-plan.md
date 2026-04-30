# Path 1 — `AVCapturePhotoOutput` for stills (architecture plan)

Bug 6 introduced this: post-fix, stills land at 4032×3024 with no green
band, but they look soft compared to Camera-app captures at the same
size. Format selection is already optimal (idx 47 — see
`bug6-back-camera-formats.md`). The detail gap comes from
`AVCaptureVideoDataOutput`'s video-grade ISP. The lift requires
`AVCapturePhotoOutput`.

This is a **plan**, not a change list. It is bigger than a punch-list
fix and likely needs upstream brief authorship (`implementation/briefs/`)
before it lands. Probably **Stage 13** material — Stage 12's brief
covers `UIApplication.beginBackgroundTask` and retiring
`scaffolding:10:synchronous-drain-pause`.

## TL;DR

Add a parallel `AVCapturePhotoOutput` to the existing session. Live
preview, processed preview, and recording continue to use
`AVCaptureVideoDataOutput` with no behavioral change. Still capture
re-routes through the photo output, takes one ISP-processed frame
through Metal Pass 2 for color correction, and saves the result. Net
effect: stills get Camera-app-grade detail; everything else stays
identical.

## Architecture diff

### Before (today)

```
AVCaptureSession
└── AVCaptureVideoDataOutput  → delivery queue → MetalPipeline.encode(sampleBuffer:)
                                                  ├── Pass 1 YUV→RGBA           (naturalTex)
                                                  ├── Pass 2 colorTransform     (processedTex)
                                                  ├── Pass 4 trackerDownsample  (trackerTex, conditional)
                                                  ├── Pass 5 RGBA16F→NV12       (encoderBuf, conditional on isRecording)
                                                  └── Pass 6 blit               (stillReadback, conditional on pendingCapture)
                                                                ↓
                                                        StillCapture (vImage→TIFF→Photos)
```

### After

```
AVCaptureSession
├── AVCaptureVideoDataOutput  → delivery queue → MetalPipeline.encode(sampleBuffer:)
│                                                  ├── Pass 1, 2, 4, 5    (unchanged)
│                                                  └── Pass 6 retired      ← see scaffolding note
│
└── AVCapturePhotoOutput      → photoQueue     → StillCapture.handlePhoto(_:)
                                                  ↓
                                                  pipeline.encodePhoto(pixelBuffer:)
                                                    └── Pass 2 only         (one-shot, isolated path)
                                                  ↓
                                                  vImage → CGImage → TIFF → Photos
```

The video output path is byte-for-byte identical to today. Pass 6
(blit-from-`processedTex` to a still readback buffer) is no longer
needed and gets retired.

## Component changes

### `CameraSession.swift`

- Add `private let photoOutput = AVCapturePhotoOutput()`.
- Inside `configure()`, after the video output is added but before
  `commitConfiguration()`:
  - Set `photoOutput.maxPhotoDimensions` to `chosenSize` (4032×3024).
  - `if avSession.canAddOutput(photoOutput) { avSession.addOutput(photoOutput) }`
  - Set the photo connection's `videoRotationAngle` to match
    `Constants.captureOrientationAngleDeg` (ADR-17 — same angle, same
    rule).
  - Capture-readiness configuration (order matters — set before
    `commitConfiguration()`, see Apple "Managing responsive capture"):
    1. `if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }`
       — lets the next capture begin before the previous one fully
       returns. Materially raises sustained throughput when the user
       taps shutter quickly.
    2. `if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }`
       — keeps a rolling buffer of recent frames so the photo "is
       already taken" at shutter-press; makes the shot feel instant.
    3. After `commitConfiguration()` and before exposing capture to the
       user, prime the pipeline with
       `photoOutput.setPreparedPhotoSettingsArray([template], completionHandler:)`
       where `template` is a representative `AVCapturePhotoSettings`
       matching what `StillCapture` will issue (BGRA, max dimensions,
       `.balanced` quality). Without this, the first shot pays a
       buffer-allocation tax of tens of ms.
  - **Deferred for a later stage:** `isAutoDeferredPhotoDeliveryEnabled`
    + the proxy/full-quality two-callback delegate flow. Adds
    background ISP processing that returns a fast proxy first and the
    full-quality result later — useful for burst UX but requires
    StillCapture to handle two delegate callbacks per shot and a
    proxy-replacement flow in Photos. Not in this plan; revisit once
    responsive-capture path is shipping cleanly.
- Extend the return tuple: `(device: …, captureSize: …, photoOutput: AVCapturePhotoOutput)`.
- `photoOutput` itself is class-bound and `@unchecked Sendable` by use;
  callers serialize via `sessionQueue` for `capturePhoto(with:delegate:)`
  per ADR-07.

### `CameraEngine.swift`

- Store the `photoOutput` returned by `session.configure()`.
- Pass it into `StillCapture` at `init` time alongside the existing
  pipeline ref.
- `public func captureImage(outputPath:)` body simplifies — no longer
  arms a Metal continuation; just calls
  `stillCapture.captureImage(photoOutput:pipeline:…)`.

### `StillCapture.swift` — reshape

Remove the `pipeline.armCapture(continuation:)` arming dance entirely.
Replace with:

1. CAS guard via existing `CppCaptureAtomic` (unchanged).
2. Build `AVCapturePhotoSettings` (HEIC or codec=HEVC + max
   dimensions). Embedded thumbnail off (we generate our own).
3. Dispatch `photoOutput.capturePhoto(with: settings, delegate: self)`
   onto `sessionQueue` (ADR-07).
4. Await the delegate callback via `withCheckedThrowingContinuation`.
5. Implement `AVCapturePhotoCaptureDelegate.photoOutput(_:didFinishProcessingPhoto:error:)`:
   - On error → resume continuation with `StillCaptureError.metalReadbackFailed`
     (or a new case if it warrants distinguishing).
   - On success → extract the photo's `CVPixelBuffer` (BGRA, not YUV —
     photos arrive already de-Bayered through the ISP). Hand to
     `MetalPipeline.encodePhotoForColorTransform(pixelBuffer:)`.
6. The Metal call returns a processed RGBA16F `CVPixelBuffer`. Continue
   with the existing vImage → CGImage → TIFF → Photos flow.

The session-token snapshot pattern (D-10) gets reused: capture the
token at step 3, abort if it advances before step 5 completes.

### `MetalPipeline.swift`

- Add `func encodePhotoForColorTransform(pixelBuffer:) async throws -> CVPixelBuffer`.
  - Wraps the supplied photo buffer (BGRA8) as a `MTLTexture` via
    `CVMetalTextureCacheCreateTextureFromImage` with format
    `.bgra8Unorm` (single plane, no chroma).
  - Allocates a one-shot RGBA16F destination via `texturePool.makeIOSurfaceBackedRGBA16F`
    sized to the photo's actual dimensions.
  - Encodes a single-pass color transform variant. The current
    `colorTransformPSO` reads RGBA16F and writes RGBA16F — its input
    type doesn't match BGRA8 directly. Two options:
    - **(a)** Add a small `bgraToRgba16fColorTransform` kernel that
      combines the format conversion and the existing color-transform
      math in one pass. ~30 lines of Metal.
    - **(b)** Two passes: first a BGRA8→RGBA16F blit/conversion, then
      the existing `colorTransformPSO`. Reuses existing PSO; one
      extra encoder.
    - Recommend (a) — single dispatch, clearer ownership.
  - Awaits completion via `withCheckedThrowingContinuation`. Returns the
    destination buffer.
  - **Does not** touch `latestNaturalBuffer` / `latestProcessedBuffer` /
    `frameNumber` / `consumers` / `onEncodedBufferReady`. This path is
    isolated from the live encode path.

- Pass 6 (the blit branch in `encode()`) is retired. The
  `stillCapturePool`, `pendingCaptureContinuation`,
  `stillCaptureDequeueCount`, and `armCapture(continuation:)` surfaces
  go with it. Test seams that referenced them get updated.

- `ColorShaders.metal` gains the new `bgraToRgba16fColorTransform`
  kernel (or `colorTransformBGRAIn` — name TBD). The existing
  `colorTransform` kernel stays — it's still used by the live Pass 2.

### `Shaders/ColorShaders.metal`

- New kernel: read `texture2d<float, access::sample>` BGRA, apply the
  same `ColorUniform` math, write `texture2d<float, access::write>`
  RGBA16F. Identical math to the live `colorTransform`; only the
  texture types differ. Channel-order swizzle BGRA→RGBA happens inline.

### Concurrency / queue discipline

- `photoOutput.capturePhoto(with:delegate:)` is called on `sessionQueue`
  (ADR-07).
- The `AVCapturePhotoCaptureDelegate` callback queue is set via
  `connection.videoOrientation` is *not* the right hook — instead, the
  delegate callback queue is implicit; AVF dispatches to a private
  serial queue. We do not need a dedicated `photoQueue`; the delegate
  is short-lived and immediately bridges into Swift concurrency via the
  continuation.
- The Metal photo-encode path runs on `delivery` queue. This preserves
  the single-writer Metal invariant: only the `delivery` queue calls
  into `MetalPipeline`. Implementation: the delegate callback hands the
  pixel buffer to a `delivery.async { try await pipeline.encodePhoto… }`
  shim, which then resumes the outer continuation.
  - Trade-off: video frames may stall briefly while the photo encode
    runs (one-pass dispatch, single command buffer commit, ≤10 ms on
    iPad Pro). Acceptable; current Pass-6 blit also runs on `delivery`
    and has comparable cost.

### Recovery / D-10 / Watchdogs (ADR-15, Stage 09)

- Capture `engineSessionToken` at `capturePhoto` call. Bail if the
  token advances before the Metal photo-encode resumes.
- The capture-watchdog (kind: `.capture`) currently ticks on video
  frames; photo capture should not tickle it (it's a separate code
  path). No change needed.
- The GPU watchdog ticks on Metal completion. The photo-encode command
  buffer's completion handler should call the same `feed()` path so a
  successful photo encode counts as GPU liveness.

### Photo-library + file format

- Existing `saveToPhotoLibrary(url:)` flow stays. Same TIFF write path.
- Optionally switch the on-disk format to HEIC for size — independent
  of this plan; can land separately.
- `NSPhotoLibraryAddUsageDescription` already wired (CLAUDE.md §5,
  Stage 07).

### Test strategy (CLAUDE.md §6 + Stage testing discipline)

- Mock `AVCapturePhotoOutput` via a new protocol
  `PhotoCapturing` (analogous to `CaptureDeviceProviding`):
  - `func capturePhoto(with:settings:delegate:) -> Void` etc.
  - Live impl wraps `AVCapturePhotoOutput`; test impl synthesizes a
    `CVPixelBuffer` and invokes the delegate callback synchronously.
- Unit tests (under `CameraKitTests/Stage13Tests/` or wherever the
  brief lands):
  - **Color-transform parity**: feed a known BGRA8 buffer through the
    new kernel; expected RGBA16F output matches the live
    `colorTransform` applied to the same data. Catches kernel
    divergence.
  - **Lifecycle**: success, AVF error, session-token bump mid-flight,
    timeout (`AsyncWithTimeout` wrap; reasonable: 2 s).
  - **CAS guard**: two concurrent `captureImage` calls — second throws
    `alreadyInFlight` (existing test seam).
  - **Pass-6 retirement**: `pendingCaptureContinuation` and friends are
    no longer reachable; existing Stage-07 tests get migrated to the
    new path.

### Scaffolding / staging

- The new path lands tagged `scaffolding:NN:photo-output-still-capture`
  (NN = whatever stage authors this — likely 13).
- The retired Pass-6 surfaces drop their `scaffolding:07:…` markers per
  the brief's `Retires scaffolding from:` line.
- `CameraKit/state.md` gets a new entry under "Scaffolding still live"
  during bring-up; moves to "Permanent" once HITL confirms detail
  parity with Camera-app stills.

## Risks and open items

- **HEIC vs TIFF**: TIFF preserves bit depth but balloons file size at
  4032×3024. HEIC is half the size with negligible perceptual loss.
  Decision deferred — landing TIFF first preserves current behavior.
- **Frame-drop spike at shutter**: capturing a 12 MP photo while video
  is running at 30 fps will likely drop 1–3 video frames. Acceptable
  for shutter UX; verify that Stage 09 watchdogs don't fire on the
  drop. May need a short watchdog grace window keyed to in-flight
  capture state.
- **AVCapturePhoto.pixelBuffer availability**: `AVCapturePhoto` returns
  `pixelBuffer` only when the photo output is configured for
  uncompressed delivery. We need
  `AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey: …])`
  with `kCVPixelFormatType_32BGRA` requested. Confirm on device that
  the chosen format honors this — some formats only deliver compressed
  HEIF.
- **Color space**: photo buffers may arrive in P3, sRGB, or device RGB
  depending on the photo settings. The Metal kernel must agree on the
  color space. Easiest: set
  `photoSettings.processedFormat = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]`
  and force sRGB via `CGColorSpace(name: CGColorSpace.sRGB)` on the
  destination MTLTexture.
- **Live Photos / RAW**: deliberately not addressed by this plan.
- **Existing `pendingCaptureContinuation` test seam**: a few Stage 07
  tests assert non-nil after `armCapture`. They get rewritten or
  deleted with the surface.

## Effort estimate

- ~250 LOC new (StillCapture rewrite, MetalPipeline.encodePhoto,
  one new shader kernel, photoOutput wiring in CameraSession).
- ~80 LOC removed (Pass 6 blit branch, stillCapturePool plumbing,
  armCapture machinery).
- 2–3 days focused implementation, 1 day HITL bring-up + Stage-N tests.

## Recommended next step

1. Surface this plan to upstream brief authoring as a Stage 13 (or
   later) candidate brief.
2. Until that brief lands, the post-fix Bug 6 / Bug 9 state is:
   green-band gone, detail at video-grade. That's a meaningful
   improvement and shippable as-is.
3. Keep `Bug6Probe` in place until the brief lands, in case format
   enumeration is needed to author it.
