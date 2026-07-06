# Tasks

## 1. Shared capture helper

- [ ] 1.1 Extract a private `renderNaturalStill() async throws -> CVPixelBuffer` from the current `captureNaturalPicture` body — the shared prefix: guard `isOpen` + running session (`notOpen` / capture-`bufferUnavailable`), `session.capturePhoto()`, then `pipeline.renderStill(pixelBuffer:)` → the graded BGRA8 IOSurface buffer.

## 2. Engine methods

- [ ] 2.1 Rewrite `captureNaturalPicture(outputURL:photosDestination:)` to call `renderNaturalStill()` then encode → write → (Photos) → return `StillCaptureOutput` — signature and behavior unchanged (no source break, no call-site churn).
- [ ] 2.2 Add `captureNaturalPictureBuffer() async throws -> PixelHandle`: call `renderNaturalStill()`, wrap the buffer in a `PixelHandle` lease, and return it; skip encode, disk write, and Photos.
- [ ] 2.3 Resolve the buffer-lifetime open question (design D4/Open Questions): confirm whether `renderStill`'s output pool buffer survives past the call, or add a dedicated still-buffer pool / explicit retain so the lease holds the IOSurface valid until release.

## 3. Verification & docs

- [ ] 3.1 Device test: `captureNaturalPictureBuffer()` returns a non-nil IOSurface-backed BGRA8 buffer of the expected (crop) dimensions and writes no file; plus a regression test that `captureNaturalPicture(...)` still writes the file and returns the unchanged `StillCaptureOutput`.
- [ ] 3.2 Consumer docs: the still-capture guide gains the in-memory method + the buffer lifetime/ownership contract, alongside the unchanged file-based method.
- [ ] 3.3 (Deferred) Flutter: route the in-memory buffer to Dart via the zero-copy texture bridge — separate change (design D6).
