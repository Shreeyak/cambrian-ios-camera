## Why

`captureNaturalPicture()` always encodes the graded still to a file on disk (PNG/JPEG/TIFF)
and returns a `StillCaptureOutput` with the file path. Downstream apps that need the captured
image **in memory** — to feed a model, a stitcher, or a preview directly — must therefore write
the image to disk and immediately read it back, an unnecessary encode → disk → decode round-trip
that adds latency and I/O for a buffer the pipeline already holds in an IOSurface.

The graded buffer already exists at capture time: `captureNaturalPicture` shoots the ISP one-shot,
crops+grades it through `MetalPipeline.renderStill(...)` into a **BGRA8 IOSurface-backed
`CVPixelBuffer`** (the same format the processed lane delivers), and only *then* encodes it to the
requested file format. We want to let a caller take that buffer directly and skip the file entirely.

## What Changes

- Add a **new sibling method `captureNaturalPictureBuffer()`** that returns the graded
  **IOSurface-backed BGRA8 buffer** directly (same surface/format as the processed lane) and
  **skips** encoding, the disk write, and any Photos publish. The buffer is handed back under an
  explicit **lifetime/ownership contract** (a leased handle the caller holds and releases),
  consistent with how the streaming lanes lease pool buffers — so the IOSurface isn't recycled
  while the caller is still using it.
- **`captureNaturalPicture(outputURL:photosDestination:)` is unchanged** — same signature, same
  `StillCaptureOutput` return, same save-to-file/Photos behavior. No existing caller is affected.
- The shared work — guard the session, shoot the ISP one-shot, crop+grade via `renderStill` — is
  factored into **one private helper** that both public methods call, so the two entry points differ
  only in *delivery* (save-to-file vs. hand-back-buffer), not in capture.

## Capabilities

### Modified Capabilities
- `still-capture`: adds a `captureNaturalPictureBuffer()` entry point that returns the graded
  IOSurface buffer directly and skips the disk write, alongside the unchanged file-based
  `captureNaturalPicture`.

## Impact

- **Swift package (`CameraKit/Sources/CameraKit`)**:
  - `CameraEngine` — new `captureNaturalPictureBuffer() async throws -> PixelHandle`; a private
    `renderNaturalStill()` helper (guard → `capturePhoto` → `renderStill`) shared with the unchanged
    `captureNaturalPicture(...)`.
  - Buffer lifetime: reuse the `PixelHandle` lease contract so the caller controls when the IOSurface
    is released.
- **No signature change** to `captureNaturalPicture` → no call-site churn in the demo, tests, or the
  Flutter Swift adapter.
- **Outputs affected**: none of the streaming lanes; this is a new delivery entry point on the
  one-shot natural still only.
- **Flutter plugin**: native-only initially (a raw IOSurface doesn't cross the Pigeon boundary as a
  value). Surfacing the in-memory buffer to Dart (via the existing zero-copy texture bridge) is a
  follow-up, out of scope here.
- **Docs**: the still-capture consumer guide gains the in-memory method + the buffer lifetime
  contract.
