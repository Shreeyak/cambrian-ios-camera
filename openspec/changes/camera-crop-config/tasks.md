# Tasks

Build/test via XcodeBuildMCP `*_device` (fallback `scripts/build-summary.sh` /
`scripts/test-summary.sh`); device-only, never simulators. Independent of the
frame-delivery changes.

## 1. Resolution validation

- [ ] 1.1 In `CameraEngine.open()` and `setResolution(size:)`, validate the requested `captureResolution` against `device.supportedSizes`; throw `EngineError.settingsConflict` naming the requested size + supported set when absent. `nil` keeps default-format behavior.
- [ ] 1.2 Test: open with an unsupported size throws; supported size succeeds; `nil` selects default.

## 2. Center-relative crop API

- [ ] 2.1 Add `func setCenterCrop(width:height:offsetX:offsetY:) async throws` to `CameraEngineProtocol` + `CameraEngine`, computing the ROI per design D2 (even-down extents capped at resolution, even-nearest center from resolution-ratio offset, derive origin, clamp in-bounds, even-snap origin).
- [ ] 2.2 Route the derived `Rect` through the existing `setCropRegion` rebuild path (reuse `validateCropRegion` as a final assertion).
- [ ] 2.3 Tests: centered (offset 0) → centered even rect; the worked example (100×100, 0.1/0.2) clamps to (0,0); a smaller crop (1440×1440 in 1920×1440, offsetX 0.1) honors center 1152; odd/oversized dims normalize to even ≤ resolution.

## 3. Enable/disable + remembered default

- [ ] 3.1 Add engine state `cropEnabled: Bool` (default false) and `configuredCrop: Rect?`; full-frame output when disabled.
- [ ] 3.2 Add `func setCropEnabled(_:) async throws`: enable applies `configuredCrop` or a centered `Constants.cropDefault*` clamped to the active resolution; disable rebuilds at full `captureSize`.
- [ ] 3.3 `setCropRegion`/`setCenterCrop` set `configuredCrop` and imply `cropEnabled = true`.
- [ ] 3.4 Add `OpenConfiguration.cropEnabled: Bool = false`; `true` + `cropRegion == nil` → apply default crop at open (first frame cropped); `cropRegion != nil` → configured crop (enabled).
- [ ] 3.5 Wire `Constants.cropDefault*` (1440×1440) as the default-crop source in `open()` (no longer vestigial).
- [ ] 3.6 Tests: default state full-frame; enable-no-geometry → centered 1440×1440; disable→re-enable restores geometry; crop-on-open delivers a cropped first frame.

## 4. Docs + verify

- [ ] 4.1 Update DocC guide `06-controlling-the-camera.md`: `setCenterCrop` (worked example + "offset on a full-size crop is a no-op after clamp"), enable/disable, resolution-from-formats. Regenerate `Documentation/` via `scripts/regen-docs.sh`.
- [ ] 4.2 Build green on device; run crop tests; `swift-format lint --strict` passes. Independently committable.
