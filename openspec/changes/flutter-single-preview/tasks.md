# Tasks

Depends on `remove-natural-lane` (CameraKit natural-lane removal) and
`frame-delivery-rework` (StreamId rename) — both landed. Build/test per CLAUDE.md
§6 + §10: CameraKit via XcodeBuildMCP `*_device` (fallback `scripts/*-summary.sh`),
device-only; Dart on host; Swift RunnerTests via `xcodebuild test` (wireless OK);
`integration_test` needs **USB** + re-prime.

## 1. Remove texture-id fields from the contract

- [x] 1.1 CameraKit `Capabilities.swift`: remove `previewTextureId` field + init
  param + assignment; update the struct's doc comment. (`naturalTextureId` already
  removed in `remove-natural-lane`.)
- [x] 1.2 CameraKit `CameraEngine.open()`: remove the `previewTextureId: 0,` stub
  line (`~:607`) from the `SessionCapabilities(...)` construction.
- [x] 1.3 Pigeon DSL (`flutter/pigeons/cambrian_ios_camera_api.dart`): remove
  `previewTextureId` and `naturalTextureId` from `SessionCapabilities` (ctor params
  + fields); update the struct comment. Regenerated via
  `dart run pigeon --input pigeons/cambrian_ios_camera_api.dart`
  (Dart/Swift/Kotlin `.g` mirrors all updated — `previewTextureId` gone from all three).
- [x] 1.4 `ValueTypeMappers.swift`: drop `previewTextureId:`/`naturalTextureId:`
  from `SessionCapabilities.toPigeon()` (`:162`).
- [x] 1.5 Native example `ViewModel.swift:419`: drop
  `previewTextureId: caps.previewTextureId,` from the `SessionCapabilities`
  reconstruction.

## 2. Single preview surface

- [x] 2.1 Confirmed the example app renders one preview via
  `createPreviewTexture(stream: .primary)` (already so in
  `flutter/example/lib/widgets/preview_widget.dart`); fixed the stale "processed-lane"
  doc comment (`:5`) → "primary-lane".

## 3. Repair tests / mocks / fixtures (close accept-broken debt)

- [x] 3.1 Dart `flutter/test/camera_engine_texture_test.dart`: `.processed` →
  `.primary` / `.natural` case — already clean (repointed earlier in `222b001`; grep
  finds no `.processed`/`.natural`).
- [x] 3.2 Dart `flutter/test/camera_engine_open_close_test.dart`: removed
  `previewTextureId: 1,` from the capabilities fixture (`naturalTextureId` already gone).
- [x] 3.3 Dart `flutter/example/integration_test/plugin_test.dart:45`: `.processed`
  → `.primary` — already clean (no `.processed`/`.natural` refs remain).
- [x] 3.4 Swift `flutter/example/ios/RunnerTests/TextureMapTests.swift`:
  `.processed` → `.primary` — already clean (repointed in `222b001`).
- [x] 3.5 Swift `flutter/example/ios/RunnerTests/MockCameraEngine.swift`: removed
  `previewTextureId: 1,` from the mock capabilities.
- [x] 3.6 Swept CameraKit tests constructing `SessionCapabilities` with
  `previewTextureId:` — dropped the field from `RgbaConversionTests`, `Stage06Tests`,
  and `RemoveNaturalLaneTests` (whose reflection assertion is flipped to expect
  `previewTextureId` **absent**). The Swift compiler confirmed no miss (device build
  SUCCEEDED).

## 4. Verify

- [x] 4.1 `cd flutter && flutter analyze && flutter test` (host) — green
  (analyze: 0 issues; test: 58/58 passed, incl. the edited `open_close`/`texture` fixtures).
- [x] 4.2 CameraKit build + device tests green on iPad. `build_device` SUCCEEDED
  (the removal compiles across `Capabilities`/`CameraEngine`/`ViewModel`);
  `RemoveNaturalLaneTests` **2/2 passed on device** — the reflection assertion now
  confirms `previewTextureId` is absent at runtime, and recompiling the target
  proved the `RgbaConversion`/`Stage06` fixture edits compile. `swift-format lint
  --strict` runs at pre-commit.
- [x] 4.3 Swift adapter RunnerTests green on device — **11/11 passed** (NotOpenGuard 3,
  SceneLifecycle 4, TextureMap 4), via XcodeBuildMCP `test_device` on the `Runner`
  workspace. Confirms `ValueTypeMappers`/`MockCameraEngine` compile + the preview
  texture-map behavior is intact after the field removal. (One-time device hygiene:
  cleared a stale `cambrianIosCameraExample` install that had blocked the fresh install.)
- [~] 4.4 `integration_test` — **deferred** (needs USB + re-prime
  `flutter build ios --config-only`); folds into the device HITL pass.
- [x] 4.5 `openspec validate flutter-single-preview --strict` — valid.
