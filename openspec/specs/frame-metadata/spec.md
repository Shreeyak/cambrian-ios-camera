# frame-metadata Specification

## Purpose

Define the per-frame metadata contract CameraKit attaches to every delivered
`Frame`: a typed `CameraFrameMetadata` carrying the sensor-state fields consumers
branch on for control decisions, and a separate low-rate JSON diagnostics channel
for heavyweight, debug-only sensor detail that must never drive control decisions.

## Requirements

### Requirement: Typed per-frame camera metadata

CameraKit SHALL attach a `CameraFrameMetadata` (conforming to `FrameMetadata`) to
every delivered `Frame`, carrying typed fields a consumer branches on: `settled`,
`focusState`, `wbState`, and `exposureState`. These SHALL be derived from the real
device state (`device.lastSnapshot` / `DeviceStateSnapshot`), not a zero-valued
placeholder.

#### Scenario: Metadata reflects real sensor state

- **WHEN** a frame is delivered while the camera is mid-autofocus
- **THEN** its `CameraFrameMetadata.focusState` reflects the adjusting state and
  `settled` is `false`

#### Scenario: Settled is the conjunction of all three

- **WHEN** AE has converged, white balance has settled, and focus has converged
- **THEN** `CameraFrameMetadata.settled` is `true`
- **AND** if any one has not converged, `settled` is `false`

### Requirement: Decision data is typed, not untyped

Any datum a consumer makes a control decision on SHALL be a typed member of
`CameraFrameMetadata`. Decision-relevant signals SHALL NOT be delivered only as an
untyped JSON/string payload.

#### Scenario: Seed gate reads a typed field

- **WHEN** the consumer gates a mosaic seed on convergence
- **THEN** it reads the typed `settled` (and/or `focusState`) field, not a parsed
  JSON string

### Requirement: Low-rate JSON debug channel

The ~3 Hz `frameResultStream` SHALL carry a JSON diagnostics payload of heavyweight,
debug-only sensor detail (e.g. AF status detail, WB settling progress, full AE
state) forwarded from the camera library. This payload SHALL NOT be used for control
decisions. The former `ProcessingMetadata` grade parameters
(brightness/contrast/saturation/gamma/cropRegion/white-balance gains) SHALL be
carried here, not as per-frame typed metadata.

#### Scenario: Grade params are not per-frame typed metadata

- **WHEN** a `Frame` is delivered
- **THEN** its metadata does not carry the grade parameters; those appear only in
  the 3 Hz JSON diagnostics payload

#### Scenario: Debug detail is available without a rebuild

- **WHEN** a developer needs the current AF/WB settling detail
- **THEN** it is present in the 3 Hz JSON diagnostics payload
