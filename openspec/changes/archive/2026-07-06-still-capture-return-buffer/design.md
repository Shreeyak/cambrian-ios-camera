## Context

`captureNaturalPicture(outputURL:photosDestination:)` (CameraEngine.swift) today:

1. Guards `isOpen` + a running session (`reconciledSessionRunning`; no last-frame fallback).
2. Shoots the ISP one-shot photo (`session.capturePhoto()`, sessionQueue/ADR-07).
3. Crops + grades it through `MetalPipeline.renderStill(pixelBuffer:)` → a **BGRA8 IOSurface-backed
   `CVPixelBuffer`** (`graded`), the same format/surface class the processed lane delivers.
4. Encodes `graded` to the extension-chosen format, writes to `outputURL`, optionally publishes to
   Photos, and returns `StillCaptureOutput { filePath }`.

Steps 1–3 already produce exactly the buffer a downstream in-memory consumer wants; step 4 is the
disk round-trip we want to make optional — via a *separate method*, not a flag on the existing one.

## Goals / Non-Goals

**Goals:**
- A dedicated `captureNaturalPictureBuffer()` that returns the graded BGRA8 IOSurface buffer directly,
  skipping encode/write/Photos.
- A clear buffer lifetime contract so the IOSurface isn't recycled under the caller.
- **Zero change** to `captureNaturalPicture(...)` — same signature, same behavior.
- The two entry points share their capture code; only the delivery differs.

**Non-Goals:**
- Surfacing the raw buffer across the Pigeon/Dart boundary (native-only first; Flutter follow-up).
- A new streaming lane or any change to preview/`captureImage`/tracker/recording.
- Changing the grade/crop applied to the still (identical to today's `renderStill`).

## Decisions

### D1. A separate method, not a flag on `captureNaturalPicture`
Add `captureNaturalPictureBuffer()` rather than `captureNaturalPicture(returnBuffer:)`. A boolean flag
that flips the return *type* forces an awkward sum-type return (or a both-optional struct) and makes
every existing caller reason about a mode it doesn't use. Two named methods read clearly at the call
site — `...Picture()` saves a file, `...PictureBuffer()` hands back a buffer — and each keeps a single,
honest return type. *(Supersedes the earlier flag + `NaturalCaptureResult` sum-type design, which the
reviewer rejected as ugly.)*

### D2. `captureNaturalPicture` is unchanged
It keeps `(outputURL:photosDestination:) async throws -> StillCaptureOutput` verbatim — no source
break, no call-site churn (demo, tests, Flutter Swift adapter untouched).

### D3. Shared private capture helper
Factor the common prefix — guard `isOpen` + running session, `session.capturePhoto()`,
`pipeline.renderStill(pixelBuffer:)` → the graded BGRA8 IOSurface buffer — into one private method,
e.g. `private func renderNaturalStill() async throws -> CVPixelBuffer`. Both public methods call it and
then diverge: `captureNaturalPicture` encodes → writes → (Photos) → `StillCaptureOutput`;
`captureNaturalPictureBuffer` wraps the buffer in a `PixelHandle` lease and returns it. The
`notOpen` / `bufferUnavailable` guards live in the helper, so both entry points enforce them
identically.

### D4. Return a `PixelHandle` lease for buffer lifetime
`captureNaturalPictureBuffer()` returns a `PixelHandle` (the same leased-handle type the streaming
lanes use via `currentPixelBuffer`/`Frame`), so the caller holds the lease and the pool buffer is
retained until release. This reuses the established ownership contract rather than inventing a new one.
The exact pool/retain wiring (does `renderStill` dequeue from a pool that outlives the call?) is settled
in implementation; the contract is: **the caller owns the returned handle and must release it; the
IOSurface stays valid until then.**

### D5. Format is BGRA8 (processed-lane parity)
The returned buffer is `kCVPixelFormatType_32BGRA` / `.bgra8Unorm` — identical to
`SessionCapabilities.streamPixelFormat` and what `currentPixelBuffer(stream:)` delivers — so a
downstream consumer treats the still buffer exactly like a processed-lane buffer. No RGBA16F is exposed
(the camera is 8-bit-locked; float precision buys nothing at the boundary).

### D6. Flutter is a follow-up
A raw IOSurface is not a Pigeon value type. `captureNaturalPictureBuffer()` is native (Swift) only in
this change; routing it to Dart through the existing zero-copy texture bridge is a separate change. The
Pigeon `captureNaturalPicture` stays file-only for now.

## Risks / Trade-offs

- **Leaked lease** → if a caller drops the `PixelHandle` without releasing, the pool buffer is pinned.
  Mitigation: the handle follows the established lease contract (same as frame delivery); document it.
- **Pool exhaustion** if a caller holds many still buffers → the still pool sizing must tolerate the
  intended usage (typically one at a time); document the expectation, revisit sizing if needed.
- **Two methods to keep in sync** — the shared `renderNaturalStill()` helper mitigates drift; the only
  per-method code is the delivery tail.

## Migration Plan

1. Extract `renderNaturalStill()` (guard → `capturePhoto` → `renderStill`) from the current
   `captureNaturalPicture` body; `captureNaturalPicture` calls it, then encodes/writes/Photos as before
   (behavior identical).
2. Add `captureNaturalPictureBuffer()` calling the helper and returning `.buffer` under a `PixelHandle`
   lease; skip encode/write/Photos.
3. Docs + tests (a device test capturing a buffer and asserting format/dimensions/non-nil IOSurface,
   plus a regression test that the file path is unchanged).

## Open Questions

- Does `renderStill` currently dequeue from a pool whose buffer survives past the method return, or is
  a dedicated still-buffer pool / explicit retain needed for the lease? (Implementation-time; determines
  whether D4 is a straight hand-back or needs a small pool addition.)
