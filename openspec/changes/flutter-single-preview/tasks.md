# Tasks

Depends on `remove-natural-lane` (CameraKit natural-lane removal) and
`frame-delivery-rework` (StreamId rename) — both landed. Build/test per CLAUDE.md
§6 + §10: CameraKit via XcodeBuildMCP `*_device` (fallback `scripts/*-summary.sh`),
device-only; Dart on host; Swift RunnerTests via `xcodebuild test` (wireless OK);
`integration_test` needs **USB** + re-prime.

## 1. Remove texture-id fields from the contract

- [ ] 1.1 CameraKit `Capabilities.swift`: remove `previewTextureId` field + init
  param + assignment; update the struct's doc comment. (`naturalTextureId` already
  removed in `remove-natural-lane`.)
- [ ] 1.2 CameraKit `CameraEngine.open()`: remove the `previewTextureId: 0,` stub
  line (`~:488`) from the `SessionCapabilities(...)` construction.
- [ ] 1.3 Pigeon DSL (`flutter/pigeons/cambrian_ios_camera_api.dart`): remove
  `previewTextureId` and `naturalTextureId` from `SessionCapabilities` (ctor params
  + fields); update the struct comment. Regenerate:
  `cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart`
  (updates the Dart/Swift/Kotlin `.g` mirrors — all committed).
- [ ] 1.4 `ValueTypeMappers.swift`: drop `previewTextureId:`/`naturalTextureId:`
  from `SessionCapabilities.toPigeon()` (`:157-158`).
- [ ] 1.5 Native example `ViewModel.swift:347`: drop
  `previewTextureId: caps.previewTextureId,` from the `SessionCapabilities`
  reconstruction.

## 2. Single preview surface

- [ ] 2.1 Confirm the example app renders one preview via
  `createPreviewTexture(stream: .primary)` (already so in
  `flutter/example/lib/widgets/preview_widget.dart`); fix the stale "processed-lane"
  doc comment (`:5`) → "primary lane".

## 3. Repair tests / mocks / fixtures (close accept-broken debt)

- [ ] 3.1 Dart `flutter/test/camera_engine_texture_test.dart`: `.processed` →
  `.primary`; remove the `.natural` second-texture case (or repoint it to
  `.tracker` if the two-distinct-textures assertion is still wanted).
- [ ] 3.2 Dart `flutter/test/camera_engine_open_close_test.dart`: remove
  `previewTextureId: 1,` and `naturalTextureId: 2,` from the capabilities fixture.
- [ ] 3.3 Dart `flutter/example/integration_test/plugin_test.dart:45`: `.processed`
  → `.primary`.
- [ ] 3.4 Swift `flutter/example/ios/RunnerTests/TextureMapTests.swift`:
  `.processed` → `.primary` (4 sites: `:16,36,57,75`).
- [ ] 3.5 Swift `flutter/example/ios/RunnerTests/MockCameraEngine.swift`: remove
  `previewTextureId: 1,` and `naturalTextureId: 2,` from the mock capabilities.
- [ ] 3.6 Sweep CameraKit tests that construct `SessionCapabilities` with
  `previewTextureId:` (e.g. `RgbaConversionTests` stream-pixel-format test) and drop
  the field; the Swift compiler flags any miss.

## 4. Verify

- [ ] 4.1 `cd flutter && flutter analyze && flutter test` (host) — green.
- [ ] 4.2 CameraKit build + tests green on iPad (RemoveNaturalLaneTests,
  RgbaConversion, etc.); `swift-format lint --strict` clean on `CameraKit/Sources`.
- [ ] 4.3 Swift adapter RunnerTests via `xcodebuild test` (wireless OK).
- [ ] 4.4 `integration_test`: connect USB, re-prime `flutter build ios --config-only`,
  then `flutter/example/scripts/test-integration.sh`; retry once on a transient
  VM-service "Connection refused".
- [ ] 4.5 `openspec validate flutter-single-preview --strict`.
