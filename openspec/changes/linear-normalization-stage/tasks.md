# Tasks

## 1. Parameter surface & constants

- [x] 1.1 Extend `ProcessingParameters` (Capabilities.swift) with per-channel linear black point, WB chroma residual, and white-point level coefficients plus their enable/disable toggles; default to identity / disabled (white-point level off).
- [x] 1.2 Extend `ColorUniform` (ColorShaders.metal + Swift mirror) with the fused per-channel affine coefficients `a`/`b`, and a transfer-function/linearize flag if needed.
- [x] 1.3 Add `Constants.swift` entries: `whitePointTargetDisplay` (= 250.0/255.0), `blackPointSigmaK` (= 1.5), `blackPointSelectSigmaK` (= 3.0). (Note: kept `blackBalanceOverscan` marked deprecated rather than renaming now — the rename completes in §4 when its `1.5×mean` usage is replaced by the statistical path, so the doc/usage stay consistent during the transition.)
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

## 4. Black-point calibration (statistical, patch-seeded mask)

- [ ] 4.1 Implement the GPU dark-field reduction: seed `patchMean`/`patchσ` from the 96² center patch, build the value-mask `patchMean ± blackPointSelectSigmaK·patchσ` per channel, then compute `mean`/`σ` over the masked set in a single reduction (count, sum, sum-of-squares), in linear light.
- [ ] 4.2 Derive the per-channel offset as `mean + blackPointSigmaK·σ`; wire it into the affine `b` term.
- [ ] 4.3 Add `calibrateBlackPoint()` (CameraEngine.swift + CalibrationCompute.swift) as the new entry point.
- [ ] 4.4 Clean break (breaking): remove the legacy black-balance entirely — delete `calibrateBlackBalance` (Swift/Pigeon/Dart), `ProcessingParameters.blackR/G/B` (+ `ColorUniform` mirror), `CalibrationCompute.blackBalanceOffsets`, `Constants.blackBalanceOverscan`, and the post-grade subtraction in `ColorShaders.metal` (step 5). No alias/forwarding. Update all call sites and tests.

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

- [ ] 8.1 Surface the white-point toggle and any new calibration/parameter fields through the Pigeon API and Dart `CameraEngine`; remove the legacy black-balance Dart/Pigeon method entirely (breaking — no forwarder).

## 9. Verification & docs

- [ ] 9.1 Add/adjust tests for the affine math, black-point `mean + k·σ` + value-mask derivation, chroma/level decomposition, auto/manual gating, endpoint preservation, and persistence (including legacy-key migration).
- [ ] 9.2 Build via XcodeBuildMCP (device-only) and verify on the iPad: solid white (H&E, white point on), solid black (fluorescence, dim signal preserved), grey preserved (phase contrast, white point off, chroma on), and that an identity grade leaves the normalized background solid (endpoint drift under grade is accepted, not tested as preserved).
- [ ] 9.3 Update consumer docs (`07-image-processing.md`, `08-calibration.md`) to describe normalization, the WB chroma/white-point split, the auto/manual WB gating, and the black-balance→black-point deprecation; regenerate `Documentation/`.
- [ ] 9.4 Call out the black-balance **removal as a breaking change** in the GitHub release notes at release time (consumers migrate `calibrateBlackBalance` → `calibrateBlackPoint`).
