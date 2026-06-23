## Context

CameraKit's Metal color pipeline (`MetalPipeline.swift`) runs two orchestrations over a set of
shared compiled kernels:

- `encode(sampleBuffer:)` — per-frame streaming path: Pass-1 `YUVToRGBA` (YUV→RGB + crop) →
  Pass-2 `colorTransform` (brightness/contrast/saturation/gamma + a final black-balance subtract)
  → Pass-7p `Rgba16fToBgra8` → Pass-4 tracker (MPS Lanczos / 1:1 blit) → Pass-5 NV12 (recording).
- `gradeOneShot(pixelBuffer:)` — one-shot still (`captureNaturalPicture`): Pass-1 → Pass-2 →
  convert, reusing the same PSOs, pools, and live uniforms.

Today: white balance is **hardware-only** (`AVCaptureDevice` gains, pre-pipeline); there is **no
GPU white-balance, no white point, and no early black point**. "Black balance" is a per-channel
subtraction applied **last**, after the gamma-space grade (`ColorShaders.metal` step 5). Working
intermediates are RGBA16F; the camera delivers gamma-encoded YUV.

The driving use cases are microscopy: H&E brightfield (solid **white** background), fluorescence
(solid **black** background), and phase contrast (inherently **grey** — features are texture and
grey-level variation, so it must NOT be stretched to white). Solid black/white feeds both human
visual differentiation and downstream DL/detection. See `proposal.md`.

Confirmed decisions from design discussion: a **single graded feed** for all consumers (no
normalized-only lane); **scalar per-channel** correction is sufficient (illumination flat enough,
no per-pixel flat-field needed now).

## Goals / Non-Goals

**Goals:**
- A calibrated, **linear-light** normalization stage applied **before** the gamma-space grade.
- Per-channel **black point**, **white point**, and **white-balance post-process** — each
  independently toggleable; white point and white balance are **separate** functions.
- White-balance post-process **gated to manual WB mode**; computed after hardware-gain lock.
- **Solid black/white stays pinned** through operator brightness/contrast adjustments
  (endpoint preservation).
- Express the three ops as **one fused per-channel affine** (`a·x + b`) folded into the pointwise
  kernel chain — no extra full-frame pass for normalization.
- Uniform application across preview, `captureImage`, `captureNaturalPicture`, tracker, recording.

**Non-Goals:**
- Per-pixel **flat-field / shading correction** (scalar per-channel only for now).
- A separate **normalized-only** output lane for DL (single graded feed chosen).
- Rewriting the pipeline on **MPSGraph** or a tensor framework.
- Changing the creative grade's operations or order (they stay in gamma space).
- RAW/Bayer capture for true scene-linear (streaming path stays gamma-encoded YUV).

## Decisions

### D1. Normalize in linear, grade in gamma — split by operation physics
Physical ops (black/white point, WB gain) are multiply/subtract on light → correct only in linear.
Perceptual ops (contrast, saturation, gamma) match human vision in gamma/log space → stay there.
So: **linearize (inverse transfer fn) → normalization affine → re-encode → existing grade.**
*Alternative considered:* do everything in gamma (simpler, no round-trip) — rejected: distorts
midtone/feature relationships and makes black subtraction physically wrong near the floor.

### D2. One fused per-channel affine `out = a·x + b` in linear
Black point (offset), white-point level (scale), and WB chroma residual (scale) are all per-channel
linear ops, so they compose into a single multiply-add: `a = chromaGain · whitePointScale`, `b`
carries the black-point offset (`a,b` derived so the calibrated black→0 and white→target). Toggles
select which terms contribute; all-off ⇒ `a=1, b=0`. Chroma and level are both per-channel scales;
a scalar level and a per-channel chroma commute (`a·(L·x) = L·(a·x)`), so application order is
immaterial and they fold into one `a`.
*Alternative:* three separate passes/uniforms — rejected: more bandwidth, more code, same result.

### D3. Fold into the pointwise kernel; do not add a pass; no MPSGraph
The linearize + affine + re-encode are pointwise and fuse into Pass-1/Pass-2. Opportunistically
fuse Pass-1→Pass-2→convert into fewer kernels to cut intermediate-texture round-trips. Keep
tracker (different size → MPS Lanczos) and NV12 (different format) as separate passes.
*Alternative:* MPSGraph — rejected: tensor-oriented, poor fit for real-time YUV/NV12 + IOSurface
zero-copy + custom color kernels; manual fusion gets the bandwidth win with full control.
*Note:* a calibration **tap** of the pre-grade ("natural") texture must be preserved for WB/BB
sampling even if Pass-1 and Pass-2 are fused.

### D4. White balance splits into chroma (neutralize) + level (white point)
The single white-field calibration yields a per-channel scale to the target. It decomposes into:
- **Chroma residual** — the part that equalizes the channels (removes cast). Brightness-preserving.
  Stays under the name **white balance** (it *is* white balance). Safe for phase contrast.
- **Level (white point)** — the scalar that lifts the neutralized reference to the target. Stretches
  toward white. A **separate, optional** function, **off by default** (phase contrast must not be
  stretched). Level is only valid when chroma is also active; "level without chroma" is forbidden.

### D5. WB chroma gated to manual mode
In auto WB the hardware gains move continuously; a software correction on top would chase/oscillate.
So the chroma residual is identity in auto mode and only computes/applies once manual gains are
locked. The locking gesture itself (`calibrateWhiteBalance`) computes fresh gray-world gains from
the current frame, applies them, and sets WB to manual — it is the active calibrate, not a passive
freeze of the last auto value.

### D6. White-point target is a build-time constant, not pure 1.0
The white reference maps to `whitePointTargetDisplay` (default `250/255 ≈ 0.9804` in display space,
converted to linear before forming the scale), not a forced 1.0. This keeps the reference neutral
and balanced without mandatory highlight clipping; consumers wanting pure white for DL can raise the
constant. Build-time only (a `static let` in `Constants.swift`), not a runtime parameter.

### D7. Migrate "black balance" into a statistical linear black point
The existing post-grade subtraction becomes the linear, pre-grade black point. The fixed `1.5×mean`
overscan is replaced by a principled `mean + k·σ` margin (`k = blackPointSigmaK`, default 1.5 — now
a σ-multiplier, **not** a mean-multiplier), computed in linear light so the margin adapts to the
measured noise. **Behavioral migration is complete (no compat toggle for the old look)** — but the
*API* stays non-breaking (D9).
*Note the semantic shift:* old offset `= 1.5 · mean`; new offset `= mean + 1.5 · σ`. The reused
value 1.5 plays an entirely different (and now statistically meaningful) role.

### D8. Black-point calibration: patch-seeded value-mask
Calibration seeds from the 96² center patch to learn the "black signature" (`patchMean`, `patchσ`),
then grows the sample to every frame pixel within `patchMean ± k_select·patchσ`
(`k_select = blackPointSelectSigmaK`, default 3.0). `mean` and `σ` for the offset are computed over
that masked background set via a single GPU reduction (count, sum, sum-of-squares). This yields a
far larger, more reliable statistic and automatically excludes brighter objects in frame. The
±3σ_patch band is the *collection* width (be generous, ~99.7% of background); the `+1.5σ` margin is
the *floor* (be gentle, preserve dim signal) — two different k for two different jobs.

### D9. Calibration & apply surface; non-breaking black-balance deprecation
- **White balance**: one `calibrateWhiteBalance()` (no white-point arg) derives device gains +
  chroma residual + level from one white-field sample and stores all three. `applyWhiteBalance(
  whitePoint: Bool = false)` selects at use time — chroma only (phase contrast) or chroma + level
  (brightfield). A single function with the flag makes "level without chroma" unrepresentable; order
  is moot (D2), so no two-function ordering hazard.
- **Black point**: `calibrateBlackBalance` (Swift/Pigeon/Dart) is kept as a **deprecated alias**
  forwarding to new `calibrateBlackPoint`, emitting a runtime `.notice` deprecation log. Persisted
  legacy values migrate via a shim (no reset). Deprecation documented in consumer docs and called
  out in the GitHub release notes.

### D10. Parameter surface & persistence
Extend `ProcessingParameters` (and `ColorUniform`) with the per-channel linear black point, WB
chroma residual, and white-point level coefficients and their toggles; persist via
`SettingsPersistence` (manual WB state still not silently restored into auto; legacy black-balance
keys migrated). Surface the white-point toggle through the Flutter Pigeon API. New `Constants.swift`
entries: `whitePointTargetDisplay`, `blackPointSigmaK`, `blackPointSelectSigmaK` (renaming
`blackBalanceOverscan`).

### D11. Role-based pass naming (behavior-preserving)
Existing pass numbers encode *project history*, not execution order (`encode()` runs `1 → 2 → 7p →
4 → 5`; `Pass-7` is a fossil of the removed natural-lane convert), and the same `rgba16fToBgra8`
kernel is "Pass-7p" in `encode()` but "p3" in `gradeOneShot()`. When extracting `gradedCore`
(task 3.0), rename passes by **role** — `decode → normalize → grade → pack → tracker → encodeNV12` —
used identically in both paths. Role names also survive kernel fusion (D3/§7), where numbers become
meaningless. Methods rename to a sibling pair: `encode` → `renderFrame`, `gradeOneShot` →
`renderStill`; "encode" is reserved for the NV12 step only. All package-internal, no consumer break,
no behavioral delta (hence a task, not a spec requirement).

## Risks / Trade-offs

- **Unknown/incorrect transfer function** → mitigation: read the actual transfer function from the
  pixel buffer attachments (`kCVImageBufferTransferFunctionKey`) when available; otherwise
  approximate sRGB/BT.709. Validate on device that linearize/re-encode round-trips to identity.
- **White point clips highlights above the reference** → accepted/desired for flat backgrounds
  (background = brightest); document it and keep white point optional/off by default.
- **Behavioral change to calibrated black** (linear vs old post-grade subtract) → mitigation: gate
  behind the toggle; document as intended; verify on device against the previous look.
- **Fusing Pass-1/Pass-2 breaks the calibration tap** → mitigation: keep an explicit pre-grade
  (natural) texture output for WB/BB sampling even when kernels are fused.
- **Premature optimization** (fusing before measuring) → mitigation: profile first; treat fusion as
  the natural moment when these kernels are already being edited, not a separate goal.
- **Float precision through linearize→affine→re-encode** → keep intermediates RGBA16F (already the
  case); confirm no banding in shadows on device.

## Migration Plan

1. Land the normalization affine + linearize/re-encode with all toggles **off by default**
   (behavior unchanged except the linear round-trip, which is identity).
2. Migrate "black balance" to the statistical linear black point (`mean + k·σ`, patch-seeded
   value-mask). Keep `calibrateBlackBalance` as a deprecated alias + persistence migration shim.
3. Add manual-mode WB chroma residual + gating (under the existing "white balance" name).
4. Add white point (off by default) + its level coefficient + the shared white-field calibration.
5. (Optional, profile-driven) fuse pointwise passes; keep the calibration tap.
6. Surface white-point toggle through Flutter; update consumer docs (`07`, `08`); record the
   black-balance deprecation in the GitHub release notes.

Rollback: each operation is independently toggleable; disabling all returns to the existing look
(modulo the identity linear round-trip). The black-balance behavioral migration is complete (no
old-look toggle), but the legacy API alias remains, so downstream consumers are unaffected.

## Resolved Questions

- **Transfer function when attachment absent** → use `kCVImageBufferTransferFunctionKey` when
  present, else fall back to **sRGB**. Validate round-trip identity on device.
- **White-point target** → not pure 1.0; map to a configurable build-time target
  `whitePointTargetDisplay = 250/255 ≈ 0.9804` (D6). Neutral/balanced without forced clipping;
  raise the constant for pure-white DL feeds.
- **WB-chroma vs white-point order in the affine** → they commute (scalar level × per-channel
  chroma), so they fold into a single `a` (D2). Confirm on real data during implementation.
- **`captureImage` vs `gradeOneShot`** → `captureImage` snapshots the already-normalized streamed
  buffer (inherits normalization for free); `gradeOneShot` re-runs the shared kernel. Sharing the
  fused kernel covers both; no path-specific handling expected (confirm on device).

## Open Questions

- Confirm on real fluorescence data that `mean + k·σ` (Gaussian assumption) holds; if the dark-field
  distribution is materially non-Gaussian, switch the black-point floor to a high-percentile method
  (cheap given the sample is already reduced).
