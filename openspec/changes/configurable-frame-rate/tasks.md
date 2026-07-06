# Tasks

## 1. Configuration & constants

- [x] 1.1 Add `OpenConfiguration.targetFps: Int?` (default `nil` → resolves to 30), with doc comment covering the exposure↔fps coupling and that it's validated live.
- [x] 1.2 `Constants.frameRateTargetFPS` 60 → 30 (now the *default* when `targetFps == nil`, not a hard target); retire `frameRateRecordingMinFps`.

## 2. Format selection (CameraSession.configure)

- [x] 2.1 Split selection into (a) resolve resolution — requested, or the **computed largest-4:3** 420f size from the live format list (no fps filter) — and (b) pick a 420f format at that resolution whose `videoSupportedFrameRateRanges` contains `targetFps`.
- [x] 2.2 Make 420f FullRange a hard invariant: throw a configuration error at `open()` if no 420f format exists (replace the nearest-dimension fallback).
- [x] 2.3 Prefer a non-HDR (`isVideoHDRSupported == false`) format when multiple 420f formats match `(resolution, fps)`; fall back to the HDR-capable format only when it is the sole match.
- [x] 2.4 Disable HDR on the selected device: `automaticallyAdjustsVideoHDREnabled = false; isVideoHDREnabled = false`.
- [x] 2.5 Reject an unsupported `(resolution, targetFps)` at `open()` with an error naming the requested fps and the frame rates valid for that resolution (no silent coercion).

## 3. Locked frame rate (all modes)

- [x] 3.1 Introduce one locked-frame-rate setter (`activeVideoMinFrameDuration == activeVideoMaxFrameDuration == 1/targetFps`, clamped via `clampFrameDuration`); route both preview and recording through it.
- [x] 3.2 Remove the variable-rate recording window (`setRecordingFrameRateRange` floor); recording runs at the same locked fps as preview.

## 4. Exposure bounded by frame rate

- [x] 4.1 Compute the exposure ceiling `min(sensorMaxExposureNs, 1e9 / targetFps)`; validate manual-exposure requests against it and throw a configuration error when exceeded (before calling `setExposureModeCustom`) — reject, do not clamp.
- [x] 4.2 Report `SessionCapabilities.exposureDurationRangeNs` with the fps-constrained upper bound.

## 5. Capabilities surface

- [x] 5.1 Add per-resolution supported frame-rate range(s) to `SessionCapabilities`, sourced live from the 420f formats' `videoSupportedFrameRateRanges` (including slow-mo where offered).
- [x] 5.2 Add the active frame rate to `SessionCapabilities`.
- [x] 5.3 Confirm the new fields keep `SessionCapabilities` `Sendable`/`Hashable` (and note the Pigeon-shape implication for the deferred Flutter change).

## 6. Demo app

- [x] 6.1 Add an fps picker (15/30/60 presets) to the demo, wired to `OpenConfiguration.targetFps` (close + reopen to apply, per open-time-only scope); surface the exposure-ceiling error in the existing error toast.

## 7. Flutter / Pigeon

- [x] 7.1 Pigeon DSL (`flutter/pigeons/cambrian_ios_camera_api.dart`): add `targetFps: int?` to `OpenConfiguration`; add `activeFrameRate: int` to `SessionCapabilities`, have `exposureDurationMaxNs` carry the fps-constrained ceiling, and add a new `PFrameRateRange { PSize size; int minFps; int maxFps }` class exposed as `List<PFrameRateRange?>` (a list so a size can carry multiple ranges incl. slow-mo).
- [x] 7.2 Reconcile `RecordingOptions.fps` with the locked model (recording runs at `targetFps`): deprecate/ignore or remove the field.
- [x] 7.3 Regenerate Pigeon (Dart + Swift) and surface the new open arg + capability fields on the Dart API.
- [x] 7.4 Swift adapter (`CameraEngineHostApiImpl.swift`): forward `targetFps` into the native `OpenConfiguration`; map native `SessionCapabilities` (per-resolution fps, active fps, fps-constrained exposure) into the Pigeon message; map the unsupported-`(resolution, fps)` and exposure-ceiling errors through the existing typed Pigeon error path.
- [x] 7.5 Update `MockCameraEngine.swift` (RunnerTests) and the example app for the new open arg + capability fields.
- [x] 7.6 Flutter integration test (USB per the repo constraint): open at 30 and 60, assert the active frame rate; assert an unsupported `(resolution, fps)` surfaces the mapped typed error. — VERIFIED on device: `plugin_test.dart` "Test 5" passes (`flutter test integration_test`, iPad, ~5s). Needs a 2-min per-test timeout (real open/close cycles); Xcode must be closed during `flutter test` (26.6 debug-session attach bug).

## 8. Verification & docs

- [x] 8.1 Logic tests: largest-4:3 default is computed and fps-independent; `(resolution, fps)` validation accepts supported and rejects unsupported pairs naming the valid set; exposure > `1/targetFps` throws; 420f invariant throws when absent (via a fake with no 420f format).
- [x] 8.2 Device tests (iPad): open at 30 and 60 and confirm the active frame rate is locked in both preview and recording; nil-resolution default lands on the largest 4:3 (4032×3024 on the test iPad); a 60-fps request at a 30-fps-only resolution throws; a slow-mo fps is accepted where a binned format supports it.
- [ ] 8.3 Device HITL: confirm HDR is actually off on an HDR-capable-only resolution via a calibration-tap / neutral-field check (no tone-mapping); confirm the exposure ceiling error fires at the expected duration for 30 vs 60 fps.
- [ ] 8.4 Docs: capture-format consumer guide (configurable/locked frame rate, exposure↔fps coupling with the reject-not-clamp contract, always-420f, HDR-off, computed largest-4:3 default) and a migration note for the exposure behavior change + default-resolution jump.
- [x] 8.5 Project README: add a "Setting up the camera" section walking a consumer through the open flow — read `SessionCapabilities` (supported resolutions, the per-resolution supported frame rates incl. slow-mo, and the fps-constrained exposure range), choose a `captureResolution` + `targetFps`, and what to expect from the defaults (computed largest-4:3 resolution, 30 fps, always-420f/HDR-off). Include a short code snippet of the capabilities → `OpenConfiguration` → `open()` sequence. Cover the Dart/Flutter open flow too.
- [x] 8.6 Docstrings: document the new/changed API surface inline so it is self-explaining — `OpenConfiguration.targetFps` (default, valid range comes from capabilities, open-time only), the new `SessionCapabilities` fields (per-resolution frame rates, active frame rate, fps-constrained exposure range), and the `open()` / `setResolution` / manual-exposure error contracts (unsupported `(resolution, fps)` and exposure-beyond-`1/targetFps` both throw, naming the valid values). Split multi-sentence doc comments per the swift-format `--strict` one-line-summary rule. Include Dart doc comments on the Pigeon-surfaced `targetFps` + capability fields.
