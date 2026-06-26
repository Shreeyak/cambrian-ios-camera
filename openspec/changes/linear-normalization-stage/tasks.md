# Tasks

## 1. Parameter surface & constants

- [x] 1.1 Extend `ProcessingParameters` (Capabilities.swift) with per-channel linear black point, WB chroma residual, and white-point level coefficients plus their enable/disable toggles; default to identity / disabled (white-point level off).
- [x] 1.2 Extend `ColorUniform` (ColorShaders.metal + Swift mirror) with the fused per-channel affine coefficients `a`/`b`, and a transfer-function/linearize flag if needed.
- [x] 1.3 Add `Constants.swift` entries: `whitePointTargetDisplay` (= 250.0/255.0), `blackPointSigmaK` (= 1.5), `blackPointMaxSampleGamma` (= 0.3, the per-pixel near-black gate), `blackPointMinKeptFraction` (= 0.4, the kept-fraction floor). `blackBalanceOverscan` is removed in §4.4. (The originally-planned `blackPointSelectSigmaK` value-mask constant was never shipped — the value-mask was dropped; see §4.1 and design D8.)
- [x] 1.4 Update `SettingsPersistence` to persist/restore the new coefficients and toggles; keep the existing rule that manual white-balance is not silently restored into auto. Back-compat handled via `ProcessingParameters.init(from:)` (decodeIfPresent, no key bump): old grade values are preserved; legacy black keys are ignored (no value migration — legacy black is removed entirely in §4).

## 2. Linear-light normalization in the shaders

- [x] 2.1 Add linearize/re-encode helpers — true **piecewise sRGB** `srgbToLinear`/`linearToSrgb` in `ColorShaders.metal`. (Deferred sub-item: the Swift-side `kCVImageBufferTransferFunctionKey` read; `transferFn` defaults to sRGB, the correct fallback — wire the attachment read when confirming what the camera reports.)
- [x] 2.2 Implement the fused per-channel affine `out = a·in + b` in linear light, before the gamma grade, gated by `normalizeEnabled` (all-off ⇒ block skipped ⇒ byte-identical off-path). Fusion in `ColorUniform.init`. Verified by `normalizationAffineInLinearLight` + `normalizationSrgbRoundTripIsIdentity` (Stage04Tests).
- [x] 2.3 Endpoint deviation documented (option b): grade unchanged & not endpoint-anchored; identity-grade leaves a normalized solid background solid (covered by the off-path suite). No S-curve / re-pin.

## 3. Pipeline wiring (shared graded-core)

- [x] 3.0 (Precursor, behavior-preserving) Extract a shared `gradedCore` function (decode → grade → pack) from `encode()` and `gradeOneShot()`; rename historical pass numbers to role names consistently across both paths (decode / normalize / grade / pack / tracker / encodeNV12 — kill `Pass-7p`/`p3` and the non-sequential numbering); rename methods `encode(sampleBuffer:)` → `renderFrame(sampleBuffer:)` and `gradeOneShot(pixelBuffer:)` → `renderStill(pixelBuffer:)` (both package-internal; reserve "encode" for the NV12 step). Verify both paths produce byte-identical output before/after. Update call sites in `CameraEngine` and test seams (`encodePass2Only`).
- [x] 3.1 Normalization wired into `renderFrame(sampleBuffer:)` via `gradedCore` (it lives in the grade step) so preview, `captureImage`, tracker, and recording all inherit it.
- [x] 3.2 `renderStill(pixelBuffer:)` inherits the same normalization through `gradedCore` (single insertion point, not duplicated) so `captureNaturalPicture` matches.
- [x] 3.3 Pre-grade ("natural") texture tap preserved: `latestNaturalTex16F` is the decode output, sampled by WB/black-point calibration before any normalization/grade.

## 4. Black-point calibration (statistical, patch-only with a per-pixel near-black gate)

- [x] 4.1 Sample the centered 96² patch only — the GPU value-mask was dropped (design D8). A compute kernel (`extractCenterRegion`) copies just the patch into a small texture (`MetalPipeline.readbackNaturalCenterRegion`); the CPU (`CalibrationCompute.blackPointDebug`) keeps only pixels whose every channel is below `blackPointMaxSampleGamma` (per-pixel near-black gate) and computes `mean`/`σ` over the kept set in linear light. No GPU reduction, no full-frame readback.
- [x] 4.2 Derive the per-channel offset as `mean + blackPointSigmaK·σ` over the kept pixels; wire it into the affine `b` term.
- [x] 4.3 Add `calibrateBlackPoint()` + `clearBlackPoint()` (CameraEngine.swift + CalibrationCompute.swift). Calibration **fails** — throwing `EngineError.blackPointCalibrationFailed(reason:)`, existing black point untouched — when fewer than `blackPointMinKeptFraction` of the patch passes the gate.
- [x] 4.4 Clean break (breaking): removed the legacy black-balance entirely — `calibrateBlackBalance` (Swift/Pigeon/Dart), `ProcessingParameters.blackR/G/B` (+ `ColorUniform` mirror), `CalibrationCompute.blackBalanceOffsets`, `Constants.blackBalanceOverscan`, and the post-grade subtraction in `ColorShaders.metal` (step 5). No alias/forwarding. All call sites and tests updated.

## 5. White-balance + white-point calibration

- [ ] 5.1 Extend `calibrateWhiteBalance()` to derive and store all three from one white-field sample: hardware gains (existing lock), the per-channel chroma residual (brightness-preserving), and the per-channel white-point level (to `whitePointTargetDisplay`, converted to linear). No white-point argument.
- [ ] 5.2 Add `applyWhiteBalance(whitePoint: Bool = false)`: chroma only when false, chroma + level when true; make "level without chroma" unrepresentable.
- [ ] 5.3 Gate the chroma residual to manual WB mode (identity in auto); confirm the decomposition (chroma neutralizes without changing level; level lifts to target) on real data.

## 6. Mode gating & toggles

- [ ] 6.1 Make black point, WB chroma, and white-point level independently reflected in the affine; white-point level disabled by default.
- [ ] 6.2 Confirm phase-contrast path (chroma on, level off) preserves grey structure; brightfield path (chroma + level) yields solid neutral white at the target.

## 7. Kernel fusion (profile-driven)

- [ ] 7.1 Profile the current pipeline on device to establish a baseline before fusing.
- [ ] 7.2 Fuse the pointwise passes (YUV→RGB+crop → linearize → normalize → re-encode → grade → BGRA8) into fewer kernels to cut intermediate-texture bandwidth; keep tracker (MPS Lanczos) and NV12 encode separate; no MPSGraph.
- [ ] 7.3 Confirm the calibration tap and all outputs remain correct after fusion.

## 8. Flutter surface

- [x] 8.1 Remove the legacy black-balance Dart/Pigeon method entirely (breaking — no forwarder); add `void calibrateBlackPoint()` + `CameraErrorCode.calibrationFailed` to the Pigeon API and Dart `CameraEngine`, with the adapter mapping `EngineError.blackPointCalibrationFailed` → `calibrationFailed` (and friendlier messages for bare `MetalError`/`CancellationError`). Regenerated Pigeon + mocks; `flutter test` + `flutter build ios` green.
- [ ] 8.2 Surface the white-point toggle and any new WB / white-point parameter fields through the Pigeon API and Dart `CameraEngine` (depends on §5).

## 9. Verification & docs

- [ ] 9.1 Tests in place: affine math, black-point `mean + k·σ` + per-pixel near-black gate, endpoint preservation, and persistence (Stage04 / Stage11 / FrameMetadata; legacy keys ignored). Remaining: chroma/level decomposition + auto/manual WB gating tests (depend on §5). (The value-mask derivation test was dropped with the value-mask.)
- [ ] 9.2 Build via XcodeBuildMCP (device-only) and verify on the iPad: solid white (H&E, white point on), solid black (fluorescence, dim signal preserved), grey preserved (phase contrast, white point off, chroma on), and that an identity grade leaves the normalized background solid (endpoint drift under grade is accepted, not tested as preserved).
- [ ] 9.3 Consumer docs updated for the black-balance→black-point clean break + linear normalization (`07-image-processing.md`, `08-calibration.md`); `Documentation/` regenerated. Remaining: the WB chroma / white-point split + auto/manual WB gating docs (depend on §5).
- [ ] 9.4 Call out the black-balance **removal as a breaking change** in the GitHub release notes at release time (consumers migrate `calibrateBlackBalance` → `calibrateBlackPoint`).
