# Tasks

Build/test via XcodeBuildMCP `*_device` (fallback `scripts/build-summary.sh` /
`scripts/test-summary.sh`); device-only, never simulators. Swift/CameraKit only —
no Flutter changes. Real-open device tests are viable (the non-finite CMTime open
crash is fixed). Reference `design.md` for the "how" and `specs/frame-delivery/`
for the requirements.

## 1. Capability surface

- [x] 1.1 Add `public let trackerResolution: Size` to `SessionCapabilities`
      (`Capabilities.swift`) and its initializer; update every construction site.
- [x] 1.2 In `CameraEngine.open(...)`, populate `trackerResolution` from the
      pipeline's resolved tracker size (expose a `MetalPipeline.trackerSize`
      accessor if not already public to the engine; `trackerSizeForTest` exists for
      tests). Ensure it reflects clamping/even-rounding.

## 2. MetalPipeline tracker rework

- [x] 2.1 `import MetalPerformanceShaders`; create one `MPSImageLanczosScale` at
      pipeline init, stored as a property.
- [x] 2.2 Compute `trackerNeedsResize = (trackerSize != outputSize)` at init.
- [x] 2.3 Reorder so the BGRA8 processed texture is produced **before** the tracker
      step; both tracker paths source it (bgra8→bgra8).
- [x] 2.4 Resize path (`trackerNeedsResize`, `.tracker` subscribed): encode the MPS
      Lanczos scale from the BGRA8 processed texture → tracker buffer on the frame's
      command buffer. Manage encoder boundaries (end any open encoder before the MPS
      encode; MPS opens/closes its own).
- [x] 2.5 No-resize path (`!trackerNeedsResize`, `.tracker` subscribed): 1:1
      `MTLBlitCommandEncoder` copy from the BGRA8 processed buffer/texture into the
      tracker buffer, origins `(0,0,0)`. No MPS, no interpolation.
- [x] 2.6 Confirm/adjust the tracker BGRA8 pool texture-usage flags so the
      destination has `.shaderWrite` (MPS) and copy usage (blit), and source has
      `.shaderRead`.
- [x] 2.7 Preserve the "tracker absent when unsubscribed" behavior (no buffer
      dequeued/delivered when no `.tracker` subscriber).

## 3. Remove dead bilinear downsample

- [x] 3.1 Delete `Shaders/TrackerDownsample.metal` and remove the
      `trackerDownsample` function references, its `MTLComputePipelineState`, and the
      linear `MTLSamplerState` from `MetalPipeline`.
- [x] 3.2 Build clean with no dangling references to the removed kernel/sampler.

## 4. Tests

- [x] 4.1 Unit/logic: tracker-size resolution — `trackerHeight == primaryHeight`
      yields `trackerSize == outputSize` (no-resize selected); a smaller height
      yields aspect-preserved, even-rounded `trackerSize`; clamp behavior at the
      `2…primaryHeight` bounds. Assert via `trackerSizeForTest`.
- [x] 4.2 Device: open with `trackerHeight` smaller than primary → delivered tracker
      frames match `SessionCapabilities.trackerResolution` and the downscale path
      runs (no green/garbage output).
- [x] 4.3 Device: open with `trackerHeight == primaryHeight` → `trackerResolution`
      equals the primary resolution and tracker frames are full-res via the blit copy
      (no resampling, correct pixels).
- [x] 4.4 Confirm `CameraEngineProtocolConformanceTests` and existing frame-delivery
      / tracker tests still pass.

## 5. Docs + verify

- [x] 5.1 Update the consumer DocC guidance for the tracker lane (configurable size,
      disable-downsampling via `trackerHeight == primaryHeight`, MPS Lanczos
      downscale, `trackerResolution` readback). Regenerate `Documentation/` via
      `scripts/regen-docs.sh` (drift guard clean).
- [x] 5.2 Build green on iPad; new + existing tracker/frame-delivery tests pass;
      `swift-format lint --strict` clean on changed Sources; CONTRACTS.md
      regenerates cleanly. Device-verify tracker output at a small height and at
      full-res no-resample.
