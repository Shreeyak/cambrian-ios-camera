## Why

The streaming `natural` lane was debug-only; both real consumers use `processed`
(stitcher + Flutter preview). It costs a GPU convert pass (Pass-7n) and a pooled
buffer every frame. Cutting it is pure efficiency — but it must not break the two
things that genuinely depend on the *natural texture*: the public
`captureNaturalPicture` still-capture API, and the WB/BB calibration sampler. The
distinction is critical: the **internal 16F natural working texture**
(`latestNaturalTex16F`, the Pass-1 output) is load-bearing; the **streaming
natural lane** (Pass-7n BGRA8 → `FrameSet.natural` → `latestNaturalBuffer` →
`StreamId.natural`) is not.

## What Changes

- **BREAKING: Cut the streaming `natural` lane.** Remove `StreamId.natural`, the
  natural `Frame`/`FrameSet` lane, the Pass-7n BGRA8 conversion + its
  `naturalPool`/`eightBitNaturalPool` allocations, the `latestNaturalBuffer`
  streaming mailbox and its yield, and `SessionCapabilities.naturalTextureId`.
- **Repoint `captureNaturalPicture` to an on-demand readback** from the preserved
  16F natural texture (`latestNaturalTex16F`), converting to BGRA8 at capture
  time. This keeps the public still-capture API while genuinely removing the
  per-frame Pass-7n cost (the whole point of the cut — if Pass-7n stayed for the
  mailbox, no GPU pass would be saved).
- **Preserve the internal 16F natural texture + Pass-1 write** so WB/BB
  calibration is unaffected.
- *(Flutter-facing `StreamId.natural` / `naturalTextureId` removal is in
  `flutter-single-preview`; this change removes the Swift/CameraKit side.)*

## Capabilities

### New Capabilities

- `still-capture`: how the engine produces a single natural-lane still
  (`captureNaturalPicture`) and how that survives the removal of the streaming
  natural lane, plus the guarantee that calibration remains independent of the
  streaming lane.

### Modified Capabilities

<!-- None — openspec/specs/ is empty. The two-lane delivery shape is defined by
     frame-delivery-contract; this change asserts the natural streaming lane's
     removal and the still-capture/calibration survival. -->

## Impact

- **CameraKit API (BREAKING):** remove `StreamId.natural`,
  `SessionCapabilities.naturalTextureId`; `captureNaturalPicture` signature
  unchanged but re-implemented.
- **CameraKit internals:** `MetalPipeline` (drop Pass-7n + natural BGRA8 pools +
  `latestNaturalBuffer`; keep `latestNaturalTex16F` + Pass-1), `StillCapture`
  (on-demand 16F→BGRA8 readback), `Errors` (natural-lane error cases),
  `OutputPathResolution`.
- **Depends on** `frame-delivery-contract` (the `Frame` shape that replaces
  `FrameSet.natural`).
- **Tests:** calibration still passes; `captureNaturalPicture` returns a valid
  image with no streaming natural lane; no `StreamId.natural` remains.
- **Docs:** DocC guides referencing the natural lane; regenerated `Documentation/`.
