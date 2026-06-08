## Why

CameraKit's crop API is low-level: callers must hand in a pre-validated pixel
`Rect`, there is no center-relative ergonomics, no "crop enabled/disabled"
concept, and `captureResolution` is accepted without checking it against the
formats the device actually supports. The stitcher (and any consumer that always
runs cropped at a fixed working resolution) needs crop-on-open, a remembered
default, and a size+offset API that computes the ROI safely. The
`Constants.cropDefault*` values (1440×1440) exist but are vestigial — wired
nowhere.

## What Changes

- **Validate `captureResolution` against supported formats.** Reject an
  `OpenConfiguration.captureResolution` not present in
  `SessionCapabilities.supportedSizes` with a clear configuration error instead
  of silently accepting it. `nil` keeps the device-default behavior.
- **New ergonomic crop API `setCenterCrop(width:height:offsetX:offsetY:)`.** Crop
  is a size `(width, height)` plus an optional center displacement
  `(offsetX, offsetY)` given as a ratio of the active resolution dimensions.
  CameraKit computes the pixel ROI: even centerpoint, even extents, clamped fully
  in-bounds. Layers over the existing `setCropRegion` pipeline-rebuild path.
- **Crop as an enable/disable toggle with a remembered default.** Crop is
  disabled by default (full-frame). `setCropEnabled(_:)` + an open-time flag turn
  it on; enabling with no configured geometry applies the **`Constants.cropDefault*`
  (1440×1440)** centered, clamped to the active resolution. Disabling returns to
  full-frame; re-enabling restores the last geometry.
- **Wire `Constants.cropDefault*` into `open()`** so it is the single source of
  the default crop size (no longer vestigial).
- *Reused, not rebuilt:* open-time `Rect` crop via `OpenConfiguration.cropRegion`,
  the bounds + even-coordinate validation (`validateCropRegion`), and the live
  `setCropRegion(_:)` rebuild.

## Capabilities

### New Capabilities

- `camera-crop`: How a consumer selects capture resolution from supported formats
  and configures the output crop — open-time, live, center-relative ergonomics,
  enable/disable semantics, the 1440×1440 default, and the even/in-bounds
  invariants the engine enforces at every entry point.

### Modified Capabilities

<!-- None — openspec/specs/ is empty. -->

## Impact

- **CameraKit API (mostly additive; one breaking validation):**
  `OpenConfiguration` (+`cropEnabled`), `CameraEngine.setCenterCrop(...)`,
  `setCropEnabled(_:)`, `captureResolution` validation, `CameraEngineProtocol`.
- **CameraKit internals:** `CameraEngine` crop state (`cropEnabled`,
  `configuredCrop`), `Constants` wiring.
- **Docs:** DocC guide `06-controlling-the-camera.md`, regenerated `Documentation/`.
- **Independent** of the frame-delivery changes; can land and ship first.
