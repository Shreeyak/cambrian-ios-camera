# still-capture Specification

## Purpose

Define how CameraKit produces still images after the streaming `natural` lane is
removed, so the streaming lanes are exactly `primary` and `tracker`. The
on-demand `captureNaturalPicture` still capture is preserved without a per-frame
streaming natural buffer: the engine shoots a one-shot ISP capture and runs the
live Metal grade pipeline at full-sensor resolution. Calibration continues to
sample the internal 16F natural working texture, independent of the removed
streaming lane.

## Requirements

### Requirement: Streaming natural lane is removed

The engine SHALL NOT expose a streaming `natural` lane. There SHALL be no
`StreamId.natural`, no natural lane in the per-frame delivery, no per-frame Pass-7n
BGRA8 natural conversion, no streaming `latestNaturalBuffer` mailbox, and no
`SessionCapabilities.naturalTextureId`. The streaming lanes are exactly `primary`
(the processed lane; renamed in frame-delivery-rework) and `tracker`.

#### Scenario: No natural streaming lane

- **WHEN** a consumer enumerates streaming lanes or inspects `StreamId`
- **THEN** only `primary` and `tracker` are present; `natural` is absent

#### Scenario: No per-frame natural conversion cost

- **WHEN** frames are delivered
- **THEN** no per-frame Pass-7n BGRA8 natural conversion or natural pooled buffer is produced for streaming

### Requirement: Natural still capture survives the lane removal

The engine SHALL keep `captureNaturalPicture` working without the streaming
natural lane, producing the natural still **on demand** (not from a per-frame
streaming buffer). The public still-capture signature and the running-session
error gating SHALL be unchanged from the consumer's perspective.

The on-demand mechanism is an implementation choice (see design §D2). As
implemented, the engine shoots a one-shot ISP capture and runs the live Metal
grade pipeline (`gradeOneShot`) at capture time — full-sensor resolution.

#### Scenario: Capture a natural still with no streaming lane

- **WHEN** `captureNaturalPicture` is called while only `primary`/`tracker` stream
- **THEN** it returns a valid natural-lane still image, produced on demand (no streaming natural lane is required)

#### Scenario: No source available before capture

- **WHEN** `captureNaturalPicture` is called with no capture source available (e.g. while the session is not running)
- **THEN** it surfaces the existing capture error (`bufferUnavailable`) rather than returning garbage

### Requirement: Calibration is independent of the streaming natural lane

The engine SHALL preserve the internal 16F natural working texture
(`latestNaturalTex16F`) and the Pass-1 write that produces it, so white-balance and
black-balance calibration continue to sample it regardless of the streaming
natural lane's removal.

#### Scenario: Calibration after lane removal

- **WHEN** white-balance or black-balance calibration runs after the natural lane is removed
- **THEN** it samples the internal 16F texture and produces a valid (non-default) result
