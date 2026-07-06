## MODIFIED Requirements

### Requirement: Capture resolution must be a supported format

The engine SHALL accept a requested `captureResolution` only if it equals one of
the sizes the active camera device reports in `SessionCapabilities.supportedSizes`.
A `captureResolution` not in that set SHALL be rejected at `open()` (and
`setResolution`) with a configuration error; the engine SHALL NOT silently fall
back to an arbitrary format. A `nil` `captureResolution` SHALL select the **largest
4:3 supported capture resolution discovered from the live device format list**,
independent of the target frame rate — not an fps-entangled device default. The
default resolution SHALL be computed from the live formats, not hardcoded.

#### Scenario: Requested resolution is supported

- **WHEN** `open()` is called with a `captureResolution` equal to a supported size
- **THEN** the session is configured at that resolution and `activeCaptureResolution` reflects it

#### Scenario: Requested resolution is not supported

- **WHEN** `open()` is called with a `captureResolution` not in the supported set
- **THEN** `open()` throws a configuration error naming the requested size and the supported sizes, and the session is not started

#### Scenario: No resolution requested selects the largest 4:3

- **WHEN** `open()` is called with `captureResolution == nil`
- **THEN** the engine selects the largest 4:3 supported capture resolution discovered from the live format list, without error, and independent of the target frame rate

#### Scenario: Default resolution does not move with frame rate

- **WHEN** `open()` is called with `captureResolution == nil` at two different `targetFps` values
- **THEN** the same largest-4:3 default resolution is selected in both cases (a lower frame rate does not enlarge, nor a higher frame rate shrink, the default resolution)
