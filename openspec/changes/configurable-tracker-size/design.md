## Context

The tracker lane is produced in `MetalPipeline` Pass-4. Today it samples the
graded **processed** texture (rgba16Float) through a custom `trackerDownsample`
Metal kernel with a **linear (bilinear) sampler**, writing into a BGRA8 tracker
pool buffer sized from `OpenConfiguration.trackerHeight` (height-driven, aspect
preserved against `outputSize`, clamped `2…outputHeight`, even-rounded). The pass
runs only when a `.tracker` consumer is subscribed.

Two constraints frame this work:
- **OpenCV is not linked into CameraKit** (CLAUDE.md §5); the pipeline is
  zero-copy GPU/Metal. A literal `cv::resize(INTER_AREA)` is not available, so the
  anti-aliased downscale must be a GPU operation.
- The pipeline already produces a **BGRA8 processed** texture (`eightBitProcessedPool`
  / `_latestProcessedBgra8Tex`) for the primary lane, currently *after* Pass-4.

The current bilinear sampler aliases at the tracker's large downscale ratios, and
there is no path that avoids resampling when the consumer wants full resolution.

## Goals / Non-Goals

**Goals:**
- Anti-aliased downscale for the tracker lane (resolve aliasing/moiré).
- A true no-resample path when `trackerHeight == primaryHeight` (tracker == primary
  size): a 1:1 copy, no interpolation.
- Report the effective tracker size back to the consumer.
- Keep the change additive to the public API and zero-copy on the GPU.

**Non-Goals:**
- Bit-for-bit parity with OpenCV `INTER_AREA` (see Decisions).
- Runtime/live reconfiguration of tracker size — open-time only, as today.
- Any Flutter/Pigeon surface change.
- Width-independent sizing — width stays aspect-derived from height.

## Decisions

**1. Downscale with `MPSImageLanczosScale`, not a hand-rolled kernel.**
Metal Performance Shaders ships a maintained, anti-aliased scaler that widens its
kernel for downscaling, integrating directly into the frame's `MTLCommandBuffer`
via `encode(commandBuffer:sourceTexture:destinationTexture:)` (no `scaleTransform`
⇒ scales the full source to fill the destination). Created once at pipeline init,
reused per frame.
- *Alternatives:* (a) custom area-average compute kernel — closest to INTER_AREA
  but more code to write and verify; (b) mipmap + sample — approximate, poor for
  non-power-of-two ratios. MPS Lanczos was chosen on the user's direction toward
  MPS and is the standard high-quality MPS downscaler.

**2. Lanczos is the recorded INTER_AREA-equivalent (deviation).**
MPS has no literal pixel-area-averaging resampler. Lanczos (windowed sinc) is
sharper than INTER_AREA's box average and can ring slightly on hard edges, but it
resolves the aliasing the tracker suffers under bilinear. **If the tracker must
match an Android INTER_AREA reference bit-for-bit, revisit with a custom
area-average kernel** — tracked in Open Questions, not done now.

**3. No-resample path = 1:1 blit copy, not buffer aliasing.**
When `trackerSize == outputSize`, skip MPS and `MTLBlitCommandEncoder`-copy the
BGRA8 processed buffer into a tracker-pool buffer, origins `(0,0,0)` (CLAUDE.md §8
IOSurface-blit invariant). This is "no resizing operation" — no interpolation.
- *Alternative considered:* alias the primary's BGRA8 buffer onto the `.tracker`
  lane to avoid even the copy. Rejected: `.primary` (`latestWins`) and `.tracker`
  (`keepBuffered(depth:)`) have different buffering policies, so a shared buffer
  could let the tracker lane pin/starve the primary pool. The blit keeps lane
  buffers independent and respects the "tracker absent when unsubscribed" rule.

**4. Both paths source the BGRA8 processed texture.**
Produce the BGRA8 processed texture *before* the tracker step and source both the
MPS scale and the blit from it. This makes the scale **bgra8→bgra8** (sidesteps any
rgba16Float→bgra8 MPS format-compat concern) and unifies the two paths on one
source. Sampling 8-bit vs 16-bit-float is immaterial for a coarse tracker that was
already being delivered as BGRA8.
- *Reorder note:* the BGRA8 processed conversion moves ahead of the tracker
  encode; the primary lane is unaffected.

**5. `SessionCapabilities.trackerResolution: Size` (additive).**
The consumer sets a height; the engine clamps and even-rounds. Expose the resolved
size so the consumer can confirm it, and so tests have a public assertion point
beyond the `trackerSizeForTest` internal seam.

**6. Remove the dead bilinear kernel.**
With MPS + blit covering both paths, `trackerDownsample` (the kernel, its
`MTLComputePipelineState`, and the linear `MTLSamplerState`) is dead; delete it and
`Shaders/TrackerDownsample.metal`.

## Risks / Trade-offs

- **MPS manages its own encoder.** `MPSImageLanczosScale.encode(...)` opens and
  closes its own command encoder, so it cannot be invoked while another compute/blit
  encoder is open. → Slot the MPS scale (and the blit) at an encoder boundary in
  Pass-4: end the prior encoder, encode MPS/blit, then continue. Verify pass
  ordering on device.
- **Tracker-pool texture usage flags.** MPS scale destination needs
  `.shaderWrite` (and source `.shaderRead`); the blit needs copy usage. → The BGRA8
  lane pool already backs a written texture today; confirm the usage flags carry
  the MPS/blit requirements, adjust the pool descriptor if not.
- **Lanczos ringing on hard edges.** Sharper than INTER_AREA; acceptable for a
  coarse-motion tracker. → Recorded deviation (Decision 2); revisit only if tracking
  quality regresses.
- **Format/visual correctness.** A wrong source format or origin can render the
  tracker green/garbage with no error (CLAUDE.md §8). → Device check at both a small
  height (e.g. 480) and the full-res no-resample case before claiming done.

## Open Questions

- Does the tracker need bit-for-bit parity with Android's `INTER_AREA`? If a future
  measurement shows tracking divergence attributable to the resampler, swap MPS
  Lanczos for a custom area-average compute kernel. Not pursued now.
