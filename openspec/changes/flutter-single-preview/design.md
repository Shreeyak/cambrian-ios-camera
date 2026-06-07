## Context

The Flutter plugin mirrors CameraKit's `SessionCapabilities` over Pigeon.
CameraKit's `open()` has always hardcoded both texture ids to 0
(`previewTextureId: 0, // stub: texture IDs arrive Stage 05` at
`CameraEngine.swift:488`; `naturalTextureId` removed in `remove-natural-lane`).
Texture ids are actually allocated **on demand** by `createPreviewTexture(stream:)`
(`TextureBridge.swift`), and the example preview reads from that call, not from
`caps.previewTextureId`. The only readers of the capability fields are pass-through
plumbing: `ValueTypeMappers.toPigeon()` (`:157-158`) and the native
`ViewModel.swift:347` round-trip. So both fields are vestigial.

`frame-delivery-rework` already renamed `StreamId.processed → .primary` and dropped
`.natural` in the Pigeon DSL + generated mirrors, but the Flutter test suite
(`camera_engine_texture_test.dart`, `plugin_test.dart`, `TextureMapTests.swift`)
still references the removed cases — accept-broken debt. `remove-natural-lane`
deleted `SessionCapabilities.naturalTextureId` from CameraKit, leaving
`ValueTypeMappers.swift:158` reading a field that no longer exists, so
`flutter build ios` is red.

## Goals / Non-Goals

**Goals:** a single honest preview surface — one on-demand preview lane
(`primary`), no texture-id fields on `SessionCapabilities`, and a green Flutter
build/test suite consistent with the natural-lane removal.

**Non-Goals:** the `StreamId` rename itself (already landed); Flutter metadata
plumbing (`settled`/`focusState` — `frame-metadata-signals`); any change to
`createPreviewTexture`/`TextureBridge` mechanics (they already pass `StreamId`
through generically — no `.processed` literal to rename there).

## Decisions

### D1. Remove BOTH texture-id fields, not just `naturalTextureId` (user decision, 2026-06-08)
The authoritative doc's plain reading (§3.3/§3.7) removes only `naturalTextureId`.
But `previewTextureId` is an identical dead Stage-05 stub with no value-reader;
keeping it would leave a second misleading field advertising a texture id that is
always 0. The user chose the honest contract: remove both from CameraKit
`SessionCapabilities` (`Capabilities.swift`) **and** the Pigeon mirror; previews are
purely on demand. This makes the change touch CameraKit despite the `flutter-` name.
- *Alternative rejected:* remove only `naturalTextureId` (design's letter) —
  smaller diff, but leaves the `previewTextureId` stub on the public struct.

### D2. Regenerate Pigeon; never hand-edit generated mirrors
The DSL (`pigeons/cambrian_ios_camera_api.dart`) is the source of truth. Remove the
two fields from `SessionCapabilities` there and run
`cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart` to
update the Dart/Swift/Kotlin `.g` files (all committed for review).

### D3. Single preview = `primary` on demand; `tracker` is a consumer lane, not the preview
The human preview is `createPreviewTexture(stream: .primary)`. `tracker` stays
subscribable as a texture for consumers (e.g. debugging/stitcher), but it is not the
app's preview. There is no `natural` preview path.

## Risks / Trade-offs

- **[Removing `previewTextureId` is a second CameraKit breaking change]** →
  acceptable; the field was never functional. Sweep all `SessionCapabilities(...)`
  constructions (CameraKit tests, mocks, example `ViewModel`) — the Swift compiler
  catches misses; the Dart side is caught by `flutter analyze`/`flutter test`.
- **[Android Kotlin stub regenerates]** → no-op stub; regen keeps it consistent,
  no behavior change.
- **[`integration_test` flakiness]** → per CLAUDE.md §10: requires USB, re-prime
  with `flutter build ios --config-only` (stale `FLUTTER_TARGET`), retry once on a
  transient VM-service "Connection refused".

## Migration Plan

After `remove-natural-lane` + `frame-delivery-rework` (both landed). Remove the two
fields from the Pigeon DSL and `Capabilities.swift` (+ the `open()` stub line);
regenerate Pigeon; fix the adapter (`ValueTypeMappers`) + native example
`ViewModel`; repair Flutter tests/fixtures to `primary`/`tracker`; fix the stale
preview doc comment; verify the full matrix green.

## Source coverage

Covers authoritative doc `03` §3.3 (Flutter Pigeon ripple) and §3.7 (Flutter-side
natural removal) for the preview/texture-bridge surface, and extends them with the
user decision to also retire the vestigial `previewTextureId`. The CameraKit
streaming-lane removal is in `remove-natural-lane`; the `StreamId` rename is in
`frame-delivery-rework`.
