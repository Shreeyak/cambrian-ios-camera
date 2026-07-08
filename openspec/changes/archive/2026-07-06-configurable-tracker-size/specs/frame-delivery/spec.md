## MODIFIED Requirements

### Requirement: Consumer-specified tracker resolution

The tracker lane resolution SHALL be set by the consumer via
`OpenConfiguration.trackerHeight` (aspect-preserving against the primary/output
size, even, clamped to `2…primaryHeight`). The motion consumer's expected size is
authoritative; CameraKit produces exactly that size and does not silently
re-resize.

The resolved tracker size (after clamping and even-rounding) SHALL be reported to
the consumer as `SessionCapabilities.trackerResolution`.

Resampling SHALL depend on whether the resolved tracker size equals the primary
(output) size:

- **Equal** (i.e. `trackerHeight == primaryHeight`): CameraKit SHALL NOT resample.
  It SHALL produce the tracker frame by a 1:1 copy of the primary BGRA8 buffer, with
  no interpolation — the means by which a consumer disables downsampling.
- **Smaller**: CameraKit SHALL downscale with an anti-aliased resampler
  (`MPSImageLanczosScale`), not a bilinear sampler.

#### Scenario: Tracker honors the configured size

- **WHEN** a consumer opens with `trackerHeight` set for a square working resolution
- **THEN** the delivered tracker frames are exactly that square size

#### Scenario: Resolved tracker size is reported back

- **WHEN** a consumer opens with a `trackerHeight` that the engine clamps and/or
  even-rounds
- **THEN** `SessionCapabilities.trackerResolution` reports the effective tracker
  size, and that size equals the size of the delivered tracker frames

#### Scenario: Tracker height equal to primary disables downsampling

- **WHEN** a consumer opens with `trackerHeight` equal to the primary lane height
- **THEN** `trackerResolution` equals the primary resolution
- **AND** tracker frames are produced by a 1:1 copy with no resampling

#### Scenario: Smaller tracker is downscaled anti-aliased

- **WHEN** a consumer opens with `trackerHeight` smaller than the primary lane height
- **THEN** tracker frames are produced by an anti-aliased downscale (MPS Lanczos),
  not a bilinear sampler
