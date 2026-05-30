# ISP photo-output natural capture — design

> 2026-05-22 · status: approved, ready for implementation plan
> Supersedes `2026-05-15-capture-natural-picture-design.md` and reverses
> decision **D-2P-10** ("`captureNaturalPicture` does NOT use
> `AVCapturePhotoOutput`").

## 1. Summary

`captureNaturalPicture` is re-implemented as a dedicated **`AVCapturePhotoOutput`
one-shot** (ISP hardware-processed — the native-camera photo pipeline) that is
then run through the **same Metal crop + user grade** the live preview uses, and
saved as a **lossless TIFF**, cropped to the **active crop region**. It is
independent of the live video-frame pipeline.

The net effect: the natural capture becomes **identical to the processed capture
(`captureImage`) except for its source** — same shared device settings, same
live grade, same crop. The only difference is _ISP one-shot photo_ vs. _live
video frame_.

`captureImage` (the processed still) is **unchanged**.

## 2. Background — what this corrects

The current `captureNaturalPicture` (per D-2P-10, 2026-05-15) reads the latest
**natural-lane** BGRA8 buffer — the pre-grade YUV→RGB video frame — and
JPEG-encodes it. That implemented "natural" as _"the video frame before Metal
color transforms."_

That reading of "natural" was wrong. The intended meaning: a capture that goes
through the **ISP's hardware-accelerated post-processing** so it looks like a
native-camera photo, then carries the same color transforms as the live grade
before being saved. It is a real one-shot still, not a tap on the video stream.

The video-lane **natural texture is NOT removed** — it still feeds WB/BB
calibration (`dispatchCenterPatchOnNatural`, which requires a pre-grade signal)
and the `.natural` consumer stream. This change only redefines the saved
_natural picture_.

## 3. Requirements (locked during brainstorm)

| # | Requirement |
|---|-------------|
| R1 | `captureNaturalPicture` sources from an `AVCapturePhotoOutput` one-shot, not the video frame pipeline. |
| R2 | The photo is run through the **same Metal crop + Pass-2 grade** as the live preview (current `ColorUniform`). |
| R3 | Output is **TIFF** (lossless), cropped to the **active crop region** at the photo's native resolution for that region. |
| R4 | The capture uses the **same AVF/device settings as `captureImage`** — ISO, exposure, WB, focus (`CameraSettings`) **and** the Metal post-processing (`ProcessingParameters`: brightness/contrast/saturation/gamma/black-balance). It differs from `captureImage` only by source. |
| R5 | `captureImage` (processed still) is unchanged. |
| R6 | During `.paused` (session not running) the call **errors cleanly** — no last-frame fallback. |
| R7 | `photoQualityPrioritization = .balanced` (nicer native-camera look while honoring device exposure/ISO/WB). |

## 4. Architecture

### 4.1 Attach `AVCapturePhotoOutput` at `open()`

In `CameraSession.configure()`, inside the existing
`beginConfiguration`/`commitConfiguration` block (alongside `videoOutput`):

- Create one `AVCapturePhotoOutput`, add it `canAddOutput`-guarded.
- Set its connection's `videoRotationAngle` to `Constants.captureOrientationAngleDeg`
  (ADR-17), matching the video connection, so the photo orientation matches the
  preview.
- Retain it on `CameraSession` (like `videoOutput`).

Coexists with `AVCaptureVideoDataOutput` — we use the data output, not
`AVCaptureMovieFileOutput`, so there is no mutual-exclusion constraint. The
session preset stays `.inputPriority` (honors the chosen full-res 4:3 format),
so the photo's pixel dimensions equal the active format dims (== `captureSize`).

### 4.2 One-shot photo request — `StillPhotoCapture`

New type owning the photo round-trip. `capturePhoto(with:delegate:)` is invoked
on **`sessionQueue`** (ADR-07). The delegate (`AVCapturePhotoCaptureDelegate`,
nonisolated) bridges the resulting `CVPixelBuffer` back through a
`withCheckedContinuation`.

`AVCapturePhotoSettings` — concrete knobs (R4, R7):

- `flashMode = .off`
- `photoQualityPrioritization = .balanced`
- pixel format = **`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`** (`420f`,
  from `availablePhotoPixelFormatTypes`) — matches the video format so the
  existing YUV→RGB Pass-1 consumes it directly. (Fallback / error cleanly if
  `420f` is unavailable.)
- `isHighResolutionPhotoEnabled = false`; **do not** set `maxPhotoDimensions`
  beyond the format's video dims — keeps the 1:1 crop mapping valid.
- No bracketed capture, no RAW, no Smart-HDR override.
- **Device manual locks (exposure/ISO/WB/focus) are honored automatically**
  because the photo output shares the `AVCaptureDevice`. There is **no separate
  "photo settings" surface** — the user controls exposure/ISO/WB via the
  existing `CameraSettings` mechanism exactly as today, and the natural capture
  inherits it. (Restated so a future reader does not add an override or a
  `photoIso`-style field.)

### 4.3 One-shot Metal grade — `MetalPipeline.gradeOneShot(pixelBuffer:)`

New method returning a graded BGRA8 `CVPixelBuffer`:

- Runs **Pass-1** (YUV→RGB, with the current crop uniform — same `cropOrigin`/
  `outputSize` as the live pipeline) + **Pass-2** (current `ColorUniform`),
  into a fresh `outputSize` BGRA8 pool buffer.
- Reuses the live PSOs and the live `uniforms` `Mutex` — so the saved photo
  matches the graded preview, just from the higher-quality ISP source.
- **Grade snapshot timing:** the `ColorUniform` is snapshotted at
  **buffer-arrival time** (when AVF hands us the photo buffer), matching
  `captureImage`'s "whatever the live grade currently is" semantics. A slider
  moved during shutter latency is reflected if it lands before the buffer
  arrives.
- **Dimension guard:** assert the delivered photo buffer dims `== captureSize`
  before applying the 1:1 crop; if a device/iOS quirk delivers different dims,
  **error cleanly** rather than miscrop.
- Awaited to completion via the existing `addCompletedHandler` + continuation
  pattern.

### 4.4 Encode

Hand the graded BGRA8 buffer to the existing `StillCapture.encode(...)` with
`format: .tiff`, `laneTag: "natural"`, current device snapshot in EXIF — the
existing encode path, unchanged.

### 4.5 Concurrency lanes (explicit)

- `sessionQueue` — owns `capturePhoto(with:delegate:)` and all session/output
  mutations (ADR-07).
- Photo delegate callback — nonisolated; bridges to the engine actor via a
  checked continuation.
- `gradeOneShot` — runs **from the engine actor**, using `MetalPipeline`'s own
  command queue (thread-safe). **It does NOT run on `sessionQueue`** —
  sessionQueue is reserved for `AVCaptureSession` mutations.
- Encode/file I/O — as today (`StillCapture`, off the hot queues).

## 5. Behavior contract

- **Pause:** `captureNaturalPicture` during `.paused`/non-running session throws
  cleanly (R6) — an ISP one-shot cannot fire on a stopped session. (This is a
  contract change from today's last-frame-during-pause behavior; documented on
  the method and in DECISIONS.)
- **Latency:** a real photo capture has shutter + ISP latency (tens–hundreds of
  ms) vs. today's instant last-frame grab. Expected and acceptable.
- **Settings inheritance:** identical device + grade settings as `captureImage`
  (R4); the two stills differ only by source.

## 6. Testing

**Unit-testable (device build):**

- `gradeOneShot` applies crop + grade: drive a synthetic YUV buffer + a
  non-identity `ColorUniform` (e.g. full desaturate, like the tracker test) and
  assert the output reflects both the crop and the grade.
- `AVCapturePhotoOutput` is attached after `open()` (inspect `avSession.outputs`).
- Settings builder is a pure function: assert `flashMode == .off`,
  `photoQualityPrioritization == .balanced`, `420f` pixel format,
  `isHighResolutionPhotoEnabled == false`, no `maxPhotoDimensions` override.
- Pause errors cleanly (existing test seams for session state).
- Dimension-guard mismatch errors cleanly (inject a mismatched buffer).

**HITL only (recorded under `measurements/`):**

- That the saved TIFF **visually looks ISP-processed** (native-camera quality)
  and **matches the live grade**. ISP quality cannot be unit-tested.

## 7. Code factoring

`captureNaturalPicture` and `captureImage` stay as **two parallel methods**.
They are "identical except source," but `captureImage` reads the live
`latestProcessedBuffer` mailbox while the natural path is a one-shot async
photo→grade→encode pipeline. Do **not** factor a shared helper yet — the paths
may diverge (natural could later grow RAW/HEIC variants `captureImage` won't).

## 8. Out of scope / deferred (YAGNI)

- Full-sensor `maxPhotoDimensions` beyond the format dims — the chosen format is
  already the largest 4:3 (~12–13MP); negligible gain, and it would break the
  1:1 crop mapping.
- RAW / DNG / HEIC / depth-data / Live Photo (still deferred, as in D-2P-10).
- Sharing a still-capture helper across the two paths (§7).
- Any change to `captureImage`, the video-lane natural texture, the `.natural`
  consumer stream, or recording.

## 9. Files touched (anticipated)

- `CameraSession.swift` — attach + retain `AVCapturePhotoOutput`; rotation.
- `StillPhotoCapture.swift` (new) — one-shot request + delegate + continuation.
- `MetalPipeline.swift` — `gradeOneShot(pixelBuffer:)` + dimension guard.
- `CameraEngine.swift` — rewrite `captureNaturalPicture` to drive the ISP path;
  pause-errors-cleanly contract.
- `Errors.swift` — any new `StillCaptureError` case (e.g. photo-capture failed /
  dimension mismatch) if needed.
- Tests — new suite(s) per §6.
- `DECISIONS.md` — record the D-2P-10 reversal.

## 10. Open questions

None — all design decisions resolved during brainstorm.
