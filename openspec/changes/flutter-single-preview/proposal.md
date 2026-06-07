## Why

The CameraKit-side natural-lane removal (`remove-natural-lane`) deleted
`SessionCapabilities.naturalTextureId`, but the Flutter adapter still reads it
(`ValueTypeMappers.swift:158`) — so `flutter build ios` does not compile. The
`StreamId` rename (`processed → primary`, `.natural` dropped) already landed in
the Pigeon contract + generated mirrors (`frame-delivery-rework`), but left the
Flutter test suite referencing the removed `.processed`/`.natural` cases
(accept-broken debt).

Separately, **both** `SessionCapabilities` texture-id fields are dead Stage-05
stubs: CameraKit's `open()` hardcodes `previewTextureId: 0` (`CameraEngine.swift:488`)
and `naturalTextureId: 0`, and **no consumer reads the value** — preview textures
are allocated on demand by `createPreviewTexture(stream:)`; the only readers of the
capability fields are pass-through plumbing (`ValueTypeMappers.toPigeon()`, the
native example `ViewModel` round-trip). The plugin should expose one honest preview
surface: a single on-demand preview lane (`primary`), no vestigial texture-id
fields on the capabilities struct, and a green build/test suite consistent with the
natural-lane removal.

## What Changes

- **BREAKING: Remove both `previewTextureId` and `naturalTextureId`** from
  `SessionCapabilities` — CameraKit `Capabilities.swift` (field + init param +
  assignment) and the `previewTextureId: 0` stub in `CameraEngine.open()`, plus
  the Pigeon DSL `SessionCapabilities`. Regenerate Pigeon (Dart/Swift/Kotlin
  mirrors). Capabilities carry no preview texture id; previews are obtained on
  demand. *(Despite the `flutter-` name, the honest contract requires retiring the
  CameraKit-origin `previewTextureId` too — user decision, see design D1.)*
- **Fix the Flutter adapter:** drop the `previewTextureId`/`naturalTextureId`
  mappings in `ValueTypeMappers` and the round-trip in the native example
  `ViewModel`.
- **Close accept-broken debt:** repair Flutter tests/mocks/fixtures to the
  `primary`/`tracker` vocabulary — remove `.processed`/`.natural` references and
  `previewTextureId:`/`naturalTextureId:` fixtures.
- **Single preview:** confirm the example app renders one preview from
  `createPreviewTexture(stream: .primary)` (already the case); fix the stale
  "processed-lane" doc comment.
- *Non-goals:* the `StreamId` rename itself (already landed); Flutter metadata
  plumbing (`settled`/`focusState` — `frame-metadata-signals`).

## Capabilities

### New Capabilities

- `flutter-preview`: the Flutter plugin's preview/texture-bridge contract — a
  single on-demand preview lane (`primary`), the `tracker` lane available as a
  separate consumer texture, and `SessionCapabilities` carrying no preview texture
  id.

### Modified Capabilities

<!-- None. `frame-delivery` owns the `.primary`/`.tracker` lane vocabulary (already
     synced); this change asserts the Flutter preview surface and the removal of
     the vestigial texture-id capability fields. -->

## Impact

- **CameraKit API (BREAKING):** remove `SessionCapabilities.previewTextureId`
  (and `naturalTextureId`, already gone). Sweep every `SessionCapabilities(...)`
  construction (CameraKit tests, example `ViewModel`).
- **Flutter contract (BREAKING):** Pigeon `SessionCapabilities` loses both
  fields; regenerate Dart/Swift/Kotlin.
- **Adapter:** `ValueTypeMappers.swift` (drop both mappings), example
  `ViewModel.swift:347` (drop round-trip).
- **Tests:** Dart `camera_engine_texture_test`, `camera_engine_open_close_test`,
  example `plugin_test`; Swift `TextureMapTests`, `MockCameraEngine`.
- **Depends on** `remove-natural-lane` (CameraKit natural-lane removal) and
  `frame-delivery-rework` (StreamId rename) — both landed.
- **Verify:** `flutter analyze` + `flutter test` (host); Swift RunnerTests via
  `xcodebuild test` (wireless OK); `integration_test` (USB + re-prime
  `flutter build ios --config-only`).
