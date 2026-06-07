## ADDED Requirements

### Requirement: Streaming natural lane is removed

The engine SHALL NOT expose a streaming `natural` lane. There SHALL be no
`StreamId.natural`, no natural lane in the per-frame delivery, no per-frame Pass-7n
BGRA8 natural conversion, no streaming `latestNaturalBuffer` mailbox, and no
`SessionCapabilities.naturalTextureId`. The streaming lanes are exactly `processed`
and `tracker`.

#### Scenario: No natural streaming lane

- **WHEN** a consumer enumerates streaming lanes or inspects `StreamId`
- **THEN** only `processed` and `tracker` are present; `natural` is absent

#### Scenario: No per-frame natural conversion cost

- **WHEN** frames are delivered
- **THEN** no per-frame Pass-7n BGRA8 natural conversion or natural pooled buffer is produced for streaming

### Requirement: Natural still capture survives the lane removal

The engine SHALL keep `captureNaturalPicture` working without the streaming
natural lane, by producing the natural still on demand from the preserved internal
16F natural working texture (converted to BGRA8 at capture time). The public
still-capture behavior SHALL be unchanged from the consumer's perspective.

#### Scenario: Capture a natural still with no streaming lane

- **WHEN** `captureNaturalPicture` is called while only `processed`/`tracker` stream
- **THEN** it returns a valid natural-lane still image, produced on demand from the 16F texture

#### Scenario: No frame delivered before capture

- **WHEN** `captureNaturalPicture` is called before any frame has been processed
- **THEN** it surfaces the existing "no natural frame yet" error rather than returning garbage

### Requirement: Calibration is independent of the streaming natural lane

The engine SHALL preserve the internal 16F natural working texture
(`latestNaturalTex16F`) and the Pass-1 write that produces it, so white-balance and
black-balance calibration continue to sample it regardless of the streaming
natural lane's removal.

#### Scenario: Calibration after lane removal

- **WHEN** white-balance or black-balance calibration runs after the natural lane is removed
- **THEN** it samples the internal 16F texture and produces a valid (non-default) result
