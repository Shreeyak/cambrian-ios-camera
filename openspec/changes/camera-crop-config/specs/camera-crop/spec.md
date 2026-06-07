## ADDED Requirements

### Requirement: Capture resolution must be a supported format

The engine SHALL accept a requested `captureResolution` only if it equals one of
the sizes the active camera device reports in `SessionCapabilities.supportedSizes`.
A `captureResolution` not in that set SHALL be rejected at `open()` (and
`setResolution`) with a configuration error; the engine SHALL NOT silently fall
back to an arbitrary format. A `nil` `captureResolution` SHALL select the device
default.

#### Scenario: Requested resolution is supported

- **WHEN** `open()` is called with a `captureResolution` equal to a supported size
- **THEN** the session is configured at that resolution and `activeCaptureResolution` reflects it

#### Scenario: Requested resolution is not supported

- **WHEN** `open()` is called with a `captureResolution` not in the supported set
- **THEN** `open()` throws a configuration error naming the requested size and the supported sizes, and the session is not started

#### Scenario: No resolution requested

- **WHEN** `open()` is called with `captureResolution == nil`
- **THEN** the engine selects the device default format without error

### Requirement: Center-relative crop API

The engine SHALL expose `setCenterCrop(width:height:offsetX:offsetY:)` that
specifies a crop by output size plus an optional center displacement, translating
it into the pixel ROI used by the existing crop machinery. `offsetX`/`offsetY`
are ratios of the active resolution's width/height and default to `0` (centered).
The requested center SHALL be `centerX = evenNearest(resW/2 + offsetX*resW)`,
`centerY = evenNearest(resH/2 + offsetY*resH)`. The crop `width`/`height` SHALL be
snapped down to even values, each capped at the corresponding resolution
dimension. The derived origin SHALL be clamped so the crop lies fully within the
active resolution. Calling `setCenterCrop` SHALL enable crop.

#### Scenario: Centered crop, no offset

- **WHEN** `setCenterCrop(width: 1440, height: 1440)` is called on a 1920×1440 resolution
- **THEN** the active crop is a 1440×1440 rectangle centered horizontally and vertically with even origin and extents

#### Scenario: Offset displaces the center by a ratio of the resolution

- **WHEN** `setCenterCrop(width: 1000, height: 1000, offsetX: 0.1, offsetY: 0.2)` is called on a 1920×1440 resolution
- **THEN** the requested center is `(960 + 192, 720 + 288) = (1152, 1008)` snapped to even, and the crop origin/size are derived from that center, clamped in-bounds and even

#### Scenario: 1440×1440 crop with a horizontal offset

- **WHEN** `setCenterCrop(width: 1440, height: 1440, offsetX: 0.05)` is called on a 1920×1440 resolution
- **THEN** the requested center is `(960 + 96, 720) = (1056, 720)`, giving origin `x = 1056 - 720 = 336` (in-bounds), `y = 0` (height fills the frame), and a 1440×1440 even rect

#### Scenario: Offset would push the crop out of bounds

- **WHEN** the requested center would place part of the crop outside the active resolution
- **THEN** the origin is clamped so the full crop stays within the resolution (the effective center moves back inside the legal range)

#### Scenario: Odd or oversized dimensions are normalized

- **WHEN** `setCenterCrop` is called with an odd width/height or a dimension larger than the active resolution
- **THEN** the dimension is snapped down to an even value no larger than the resolution before the ROI is computed

### Requirement: Crop is disabled by default with a remembered default size

Crop SHALL be disabled by default, producing full-frame output at the active
capture resolution. The engine SHALL expose enable/disable without re-specifying
geometry. Enabling crop with no geometry ever configured SHALL apply a centered
crop of the package default size (`Constants.cropDefault*`, 1440×1440), clamped to
the active resolution. Disabling crop SHALL return output to full-frame; enabling
again SHALL restore the most recently configured geometry (or the default).

#### Scenario: Default state is full-frame

- **WHEN** the engine is opened with no crop configuration
- **THEN** the output resolution equals the active capture resolution (crop disabled)

#### Scenario: Enable crop with no prior geometry

- **WHEN** crop is enabled and no crop size has ever been configured
- **THEN** a centered 1440×1440 crop is applied (clamped to the active resolution if smaller)

#### Scenario: Disable then re-enable preserves geometry

- **WHEN** a crop is configured, then disabled, then re-enabled
- **THEN** the previously configured crop geometry is restored

#### Scenario: Crop-on-open for always-cropped consumers

- **WHEN** `open()` is called with crop enabled in the configuration
- **THEN** the first delivered frame is already cropped (no full-frame-then-crop transition)

### Requirement: Default crop size sources from Constants

The default crop size SHALL be sourced from `Constants.cropDefault*` (1440×1440)
and wired into `open()` so there is a single source of truth for the default crop
geometry. The default SHALL NOT be a vestigial constant consumed nowhere.

#### Scenario: Default crop matches the constant

- **WHEN** crop is enabled with no explicit geometry
- **THEN** the applied crop size equals `Constants.cropDefault*` (clamped to the active resolution)

### Requirement: Crop geometry invariants

The engine SHALL enforce identical geometry invariants on every crop it applies,
regardless of entry point (`open()`, `setCropRegion`, `setCenterCrop`,
enable-with-default). Origin and extents MUST be even (4:2:0 chroma alignment) and
the rectangle MUST lie fully within the active capture resolution. A crop that
cannot satisfy these after normalization SHALL be rejected with a configuration
error rather than silently distorted.

#### Scenario: Even-coordinate enforcement

- **WHEN** any crop is applied
- **THEN** its `x`, `y`, `width`, and `height` are all even

#### Scenario: In-bounds enforcement

- **WHEN** any crop is applied
- **THEN** `x + width <= resolutionWidth` and `y + height <= resolutionHeight`
