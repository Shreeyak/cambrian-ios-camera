## Why

CameraKit's color pipeline grades in gamma space and tacks black-level subtraction on at the
very *end*, with no white anchor at all. Two problems follow: (1) there is no way to pin a
background to **solid white** (H&E brightfield) or **solid black** (fluorescence) — the values
microscopy users and downstream DL/detection models depend on; and (2) the moment an operator
adjusts brightness/contrast, the calibrated black/white levels drift, so any "solid" background
is lost. Physically-linear operations (black point, white point, white balance) are also being
applied in gamma space, which distorts midtone/feature relationships. We need a calibrated,
linear-light normalization stage that establishes solid black/white *before* the creative grade
and keeps them stable through it.

## What Changes

- Add a **linear-light normalization stage** to the Metal color pipeline, applied **before** the
  existing gamma-space creative grade (brightness/contrast/saturation/gamma stay in gamma space).
- Normalization is a single **fused per-channel affine** in linear light (`out = a·x + b`),
  covering three independently-toggleable operations:
  - **Black point** — per-channel offset so the dark reference maps to 0 (solid black). Migrates
    the existing post-grade "black balance". The fixed `1.5×mean` overscan is replaced by a
    statistical `mean + k·σ` margin (`k = blackPointSigmaK`, default 1.5 — now a σ-multiplier),
    computed in linear light over a patch-seeded value-mask (grow the 96² center patch to all frame
    pixels within `patchMean ± k_select·patchσ`, `k_select = blackPointSelectSigmaK`, default 3.0).
  - **White-balance chroma residual** — per-channel cast-neutralization gain on top of the locked
    hardware gains; brightness-preserving; stays under the **white balance** name. Corrects Apple's
    WB where it falls short.
  - **White-point level** — the scalar that lifts the neutralized white reference to a configurable
    target (`whitePointTargetDisplay`, default `250/255 ≈ 0.9804`, build-time only). A **separate,
    optional** function, **disabled by default** (phase-contrast grey must NOT be stretched).
- **White balance (chroma) and white point (level) are separate functions** from one white-field
  calibration. `calibrateWhiteBalance()` (no white-point arg) derives hardware gains + chroma +
  level; `applyWhiteBalance(whitePoint: Bool = false)` selects chroma-only (phase contrast) or
  chroma+level (brightfield) at use time, so mode switches need no recalibration. "Level without
  chroma" is unrepresentable.
- **WB chroma is gated to manual WB mode** — inactive in auto WB (no fighting a moving hardware
  auto-WB); in manual mode the residual is computed after the hardware gains lock.
- Pipeline is operated in **linear light** for the physical ops: linearize (inverse transfer
  function, from `kCVImageBufferTransferFunctionKey` or sRGB fallback) → normalize → re-encode →
  existing gamma-space grade.
- **Kernel fusion**: hand-fuse the pointwise passes (YUV→RGB+crop → linearize → normalize →
  re-encode → grade → BGRA8) to cut intermediate-texture bandwidth. Tracker (MPS Lanczos) and
  NV12 encode remain separate passes. **No MPSGraph.**
- **Black-balance → black-point is non-breaking**: legacy `calibrateBlackBalance` (Swift/Pigeon/
  Dart) is retained as a deprecated alias forwarding to `calibrateBlackPoint`, with a runtime
  deprecation notice and a persistence migration shim; the deprecation is documented and called out
  in the GitHub release notes.
- **Behavioral change (not API-breaking)**: default output is unchanged only when all toggles are
  off; with black point migrated from the old post-grade subtraction, calibrated black behaviour
  shifts to linear space (corrected, not byte-identical). No compat toggle for the old look.

## Capabilities

### New Capabilities
- `color-normalization`: A calibrated, linear-light normalization stage (per-channel black point,
  white point, and white-balance post-process) applied before the gamma-space creative grade —
  including the calibration that derives each per-channel coefficient, the enable/disable toggles,
  the auto/manual WB-mode gating, and the endpoint-preservation contract that keeps solid
  black/white stable across operator grade adjustments.

### Modified Capabilities
<!-- None: still-capture / frame-delivery requirements are unchanged; both lanes simply inherit
     the new normalization through the shared grade pipeline. -->

## Impact

- **Swift package (`CameraKit/Sources/CameraKit`)**:
  - `Shaders/YUVToRGBA.metal`, `Shaders/ColorShaders.metal` — fold in linearize / normalization
    affine / re-encode; candidate fusion of pointwise passes.
  - `MetalPipeline.swift` — `encode(sampleBuffer:)` and `gradeOneShot()` pass orchestration; new
    normalization uniform; pass fusion.
  - `Capabilities.swift` (`ProcessingParameters`) — new per-channel white-point + linear
    black-point fields and toggles; `ColorUniform` gains the normalization affine.
  - `CameraEngine.swift` (`calibrateWhiteBalance` / `calibrateBlackBalance`) + `CalibrationCompute.swift`
    — derive linear black/white points and the manual-mode WB residual; mode gating.
  - `SettingsPersistence.swift` — persist the new coefficients/toggles.
- **Outputs affected**: preview, `captureImage`, `captureNaturalPicture`, tracker, and recording
  all inherit normalization (single graded feed).
- **Flutter plugin**: Pigeon API + Dart surface gain the white-point toggle and any new
  calibration/parameter fields.
- **Docs**: `08-calibration.md`, `07-image-processing.md` consumer guides.
