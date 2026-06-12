## Why

A consumer can already pick the tracker lane's size via
`OpenConfiguration.trackerHeight`, but two things are missing. First, there is no
way to **disable downsampling**: setting `trackerHeight` to the primary lane's
height still runs the Pass-4 downsample kernel as a wasteful 1:1 resample. Second,
that kernel uses **bilinear** sampling, which aliases badly at the large downscale
ratios the tracker uses (e.g. 4160→480 ≈ 8.7×) — moiré and shimmer the motion
consumer would rather not see. The motion consumer wants a clean, anti-aliased
tracker frame and the option to run the tracker at full primary resolution with no
resampling at all.

## What Changes

- **No-resampling path when tracker size equals primary size.** When the resolved
  tracker size equals the primary (output) size — i.e. `trackerHeight ==
  primaryHeight` — CameraKit SHALL NOT resample. It performs a 1:1 copy from the
  primary BGRA8 buffer into the tracker buffer, producing a full-resolution tracker
  frame with no interpolation. This is how a consumer "turns off" downsampling.
- **Anti-aliased downscale via MPS Lanczos.** When the tracker is smaller than
  primary, downscaling SHALL use `MPSImageLanczosScale` (Metal Performance Shaders,
  anti-aliased) instead of the bilinear sampler. This is the INTER_AREA-equivalent
  for this pipeline (MPS has no literal area-averaging resampler; Lanczos is its
  high-quality anti-aliased downscaler — see design.md for the recorded deviation).
- **New `SessionCapabilities.trackerResolution: Size`.** The effective tracker size
  after clamping/even-rounding SHALL be reported back so a consumer can confirm what
  it got (today the resolved size is unobservable).
- **Remove the bilinear `trackerDownsample` Metal kernel**, its compute pipeline
  state, and the linear sampler — superseded by the MPS scaler and the blit copy.
- *Reused, not rebuilt:* the open-time `OpenConfiguration.trackerHeight` input,
  height-driven aspect-preserving sizing (`2…primaryHeight`, even-rounded), and the
  "tracker absent when unsubscribed" guarantee.

## Capabilities

### New Capabilities

<!-- None — the tracker lane is already specified under frame-delivery. -->

### Modified Capabilities

- `frame-delivery`: The "Consumer-specified tracker resolution" requirement gains
  the resampling contract — anti-aliased (MPS Lanczos) downscale when smaller than
  primary, a no-resample 1:1 copy when equal — and a `trackerResolution` readback in
  `SessionCapabilities`.

## Impact

- **CameraKit API (additive):** `SessionCapabilities` (+`trackerResolution: Size`).
  `OpenConfiguration.trackerHeight` and the protocol are unchanged.
- **CameraKit internals:** `MetalPipeline` Pass-4 rework (MPS Lanczos scaler +
  blit-copy branch, both sourcing the BGRA8 processed texture; encoder-boundary
  management), removal of `TrackerDownsample.metal` + its PSO/sampler, and
  `import MetalPerformanceShaders`.
- **Tests:** CameraKit tests for the no-resize-vs-resize size paths via the existing
  `trackerSizeForTest` seam plus the new `trackerResolution` capability; device
  verification of MPS bgra8→bgra8 (tracker-pool `.shaderWrite` usage) and correct
  tracker output (no green/garbage) at both a small height and full-res.
- **Docs:** tracker-lane guidance in the consumer docs; regenerated `Documentation/`.
- **Scope:** Swift/CameraKit only — no Flutter/Pigeon surface change. Independent of
  other in-flight frame work.
