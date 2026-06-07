## ADDED Requirements

### Requirement: Single on-demand preview lane

The Flutter plugin SHALL expose exactly one human-facing preview lane, `primary`,
obtained on demand via `createPreviewTexture(stream:)`. The `tracker` lane SHALL
remain available as a separate consumer texture but is not the human preview. There
SHALL be no `natural` preview lane and no `.processed`/`.natural` `StreamId` case.

#### Scenario: Primary preview created on demand

- **WHEN** the example app builds its preview
- **THEN** it calls `createPreviewTexture(stream: .primary)` and renders the
  returned texture, referencing no `.natural` or `.processed` stream

#### Scenario: Tracker is a consumer texture, not the preview

- **WHEN** a consumer requests the tracker lane via `createPreviewTexture(stream: .tracker)`
- **THEN** a valid texture is returned, but the app's human preview remains the
  `primary` lane

### Requirement: SessionCapabilities carries no preview texture id

The `SessionCapabilities` returned by `open()` SHALL NOT carry `previewTextureId`
or `naturalTextureId`, neither on the CameraKit struct nor on its Pigeon mirror.
Preview texture ids are allocated on demand by `createPreviewTexture(stream:)`, not
advertised on the capabilities struct.

#### Scenario: Capabilities has no texture-id fields

- **WHEN** a consumer inspects `SessionCapabilities` returned by `open()`
- **THEN** neither `previewTextureId` nor `naturalTextureId` is present on the
  struct (CameraKit or Pigeon)

#### Scenario: Preview id comes from createPreviewTexture, not capabilities

- **WHEN** a consumer needs a preview texture id
- **THEN** it obtains the id from the `createPreviewTexture(stream:)` return value,
  not from any field on `SessionCapabilities`
