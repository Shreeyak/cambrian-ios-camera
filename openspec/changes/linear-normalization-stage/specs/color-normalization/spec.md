## ADDED Requirements

### Requirement: Linear-light normalization stage

The pipeline SHALL apply a normalization stage to camera frames in **linear light** and
**before** the gamma-space creative grade. The stage SHALL linearize the incoming
(gamma-encoded) signal via the inverse transfer function, apply the normalization, then
re-encode to the working/display transfer function so the existing creative grade
(brightness/contrast/saturation/gamma) continues to operate in gamma space unchanged. When the
pixel-buffer transfer function attachment (`kCVImageBufferTransferFunctionKey`) is present it SHALL
be used; otherwise the stage SHALL fall back to an sRGB transfer function.

#### Scenario: Physical operations run in linear light

- **WHEN** a frame is normalized
- **THEN** black point, white-balance chroma, and white-point level are applied to linearized values
- **AND** the result is re-encoded before brightness/contrast/saturation/gamma are applied

#### Scenario: Creative grade order is preserved

- **WHEN** normalization is active
- **THEN** the gamma-space creative grade still runs after normalization, in its existing order

### Requirement: Fused per-channel affine

Normalization SHALL be expressed as a single per-channel affine map in linear light
(`out = a·in + b`, computed independently for R, G, B), combining black point, white-balance chroma,
and white-point level into one operation. The affine SHALL be evaluated within the existing
pointwise GPU kernel chain without introducing an additional full-frame intermediate texture.

#### Scenario: Single fused evaluation

- **WHEN** any combination of black point, white-balance chroma, or white-point level is enabled
- **THEN** their effect is realized by one per-channel multiply-add per pixel
- **AND** no extra intermediate texture pass is added solely for normalization

#### Scenario: Disabled normalization is identity

- **WHEN** all normalization operations are disabled
- **THEN** the affine coefficients are `a = 1, b = 0` per channel and pixels pass through unchanged
  (apart from the linearize/re-encode round-trip, which is mathematically identity)

### Requirement: Black point (statistical, dark-field calibrated)

The system SHALL support a per-channel black point that maps a calibrated dark reference to 0
(solid black), applied in linear light before the creative grade. It SHALL be independently
enable/disable-able. The black-point offset SHALL be derived statistically as `mean + k·σ` per
channel (computed in linear light over the kept sample), where `k` is a build-time constant
(`blackPointSigmaK`, default 1.5). The dark-field sample SHALL be taken over the centered square
patch (`centerPatchSizePx`), keeping only pixels every channel of which is below a near-black
threshold (`blackPointMaxSampleGamma`, default 0.3 in gamma/display space); brighter or off-color
pixels are excluded per pixel. Calibration SHALL fail — surfacing an error and leaving any existing
black point unchanged — when fewer than `blackPointMinKeptFraction` (default 0.4) of the patch
passes the near-black gate.

#### Scenario: Dark background renders solid black

- **WHEN** the black point is calibrated from a dark field and enabled
- **THEN** background pixels at or below `mean + k·σ` clamp to solid black after normalization

#### Scenario: Dim real signal is preserved

- **WHEN** the black point is calibrated with the default `k = 1.5`
- **THEN** signal meaningfully above the noise floor is retained (the gentle margin does not crush dim features to black)

#### Scenario: Non-black pixels are excluded per pixel

- **WHEN** a pixel in the patch is at or above the near-black threshold in any channel
- **THEN** it is excluded from the mean/σ statistic and does not bias the black-point offset

#### Scenario: Insufficient dark field fails calibration

- **WHEN** fewer than `blackPointMinKeptFraction` of the patch passes the near-black gate (the field is not dark enough)
- **THEN** calibration fails with an error whose reason is surfaced to the caller, and any existing black point is left unchanged

#### Scenario: Black point is applied pre-grade in linear light

- **WHEN** the black point is applied
- **THEN** it is applied in linear light before the creative grade, not as a post-grade subtraction

### Requirement: White-balance chroma neutralization gated to manual mode

The system SHALL support a per-channel white-balance chroma residual applied in linear light on top
of the hardware white-balance gains, to neutralize the residual color cast the hardware gains could
not remove. The chroma residual SHALL be **brightness-preserving** (it equalizes the channels
relative to each other without changing overall level), so it is safe to apply to phase-contrast
imagery. It SHALL be **inactive while white balance is in auto mode** and SHALL only apply in
**manual (locked) mode**; the residual SHALL be computed after the hardware gains are locked.

#### Scenario: No chroma residual in auto white balance

- **WHEN** white balance is in auto mode
- **THEN** the white-balance chroma residual contributes identity (no correction) to the affine

#### Scenario: Chroma residual neutralizes without stretching to white

- **WHEN** white balance is in manual mode and the chroma residual is applied to a grey reference
- **THEN** the reference becomes neutral (channels equalized) and its overall level is preserved (not pushed toward white)

### Requirement: White point (level) separate and optional

The system SHALL support a per-channel white-point level that lifts the neutralized white reference
to a calibrated target (solid white). The white point SHALL be a **separate, optional function**
from white-balance chroma and SHALL be **disabled by default**. The target SHALL be a build-time
constant (`whitePointTargetDisplay`, default `250/255 ≈ 0.9804` in display space, converted to
linear before forming the scale). White-point level SHALL only be applicable when white-balance
chroma is also active (level without chroma is not a valid state).

#### Scenario: White background renders solid white

- **WHEN** the white point is enabled in brightfield (chroma + level)
- **THEN** the white reference maps to the configured target (≈250 in uint8) per channel as solid, neutral white, and brighter values clamp to white

#### Scenario: Phase-contrast grey is preserved when white point is off

- **WHEN** the white point is disabled (default) and only white-balance chroma is active
- **THEN** a grey phase-contrast image is neutralized but not stretched toward white, retaining its grey-level structure

### Requirement: Single white-field calibration

A single white-field calibration procedure (`calibrateWhite(whitePoint:)`) SHALL, from one
white-field sample, derive and store all of: the hardware white-balance gains, the per-channel
chroma residual, and the per-channel white-point level, and enable the chroma residual. The
`whitePoint` argument (default `true`) SHALL select the initial look — `true` enables the white-point
level (brightfield), `false` leaves it disabled (phase contrast) — and the operator MAY switch
between the two afterward without recalibrating (see *Apply-time white-point selection*). The
procedure SHALL fail — surfacing an error and leaving prior state unchanged — when the sampled patch
is not bright enough to be a white reference (below `whiteFieldMinSampleGamma`).

#### Scenario: One sample, three coefficient sets

- **WHEN** the operator calibrates against a white field
- **THEN** hardware gains, chroma residual, and white-point level are all derived and stored from that one sample, and the chroma residual is enabled

#### Scenario: Initial look selected by the calibrate argument

- **WHEN** the operator calibrates with `whitePoint: true` (default)
- **THEN** the white-point level is enabled (brightfield); with `whitePoint: false` only the chroma residual is enabled (phase contrast)

#### Scenario: Mode switch without recalibration

- **WHEN** the operator has calibrated and switches between brightfield and phase contrast
- **THEN** no new white-field capture is required; only the white-point toggle changes

#### Scenario: Non-white field fails calibration

- **WHEN** the sampled patch is too dark to be a white reference (below `whiteFieldMinSampleGamma`)
- **THEN** calibration fails with an error whose reason is surfaced to the caller, and prior white-balance state is left unchanged

### Requirement: Independent normalization toggles with calibration guards

Beyond the full `calibrate*` procedures, each normalization setting SHALL be independently
enable/disable-able on its stored coefficients without resampling: white-balance chroma
(`enableWhiteBalance()` / `disableWhiteBalance()`), white point (`enableWhitePoint()` /
`disableWhitePoint()`), and black point (`enableBlackPoint()` / `disableBlackPoint()`); and each
field's calibration SHALL be discardable (`clearWhiteBalance()`, `clearBlackPoint()`). The API SHALL
make the invalid "level without chroma" state unrepresentable: white point SHALL only be enable-able
while chroma is active, and disabling chroma SHALL also disable white point. `enable*` SHALL **throw**
when the setting has not been calibrated (or, for white balance, while hardware WB is in auto), rather
than silently doing nothing.

#### Scenario: Phase contrast — chroma only

- **WHEN** the operator disables the white point (or calibrated with `whitePoint: false`)
- **THEN** the chroma residual applies and the white-point level does not

#### Scenario: Brightfield — chroma and level

- **WHEN** the operator enables the white point after calibration
- **THEN** both the chroma residual and the white-point level apply

#### Scenario: Enabling before calibration throws

- **WHEN** `enableWhitePoint()` / `enableWhiteBalance()` / `enableBlackPoint()` is called before the corresponding field has been calibrated
- **THEN** it throws a calibration-required error (operator-facing) instead of silently no-op'ing

#### Scenario: White point cannot apply without chroma

- **WHEN** white-balance chroma is disabled
- **THEN** the white-point level is also disabled, and it cannot be enabled until chroma is active again

#### Scenario: Toggling does not resample

- **WHEN** the operator enables/disables any setting after calibration
- **THEN** the stored coefficients are reused (no new patch sample / readback)

### Requirement: Creative grade unchanged; endpoints not pinned

The creative grade (brightness/contrast/saturation/gamma) SHALL operate **unchanged** in gamma
space after normalization. The grade is **not** endpoint-anchored: operator adjustments MAY move a
background that was normalized to solid black (0) or solid white (target) off those endpoints, and
this deviation is **accepted and documented** (the existing 0.5-pivot contrast and linear brightness
operators drift endpoints inward; no S-curve operators or post-grade re-pin are added). Consumers
needing a stable solid background SHALL keep the grade at (or near) identity.

#### Scenario: Grade may move the calibrated background

- **WHEN** the background is normalized to solid white (or black) and the operator changes brightness/contrast
- **THEN** the background may shift off the endpoint (the grade is not endpoint-anchored) — this is accepted, not a defect

#### Scenario: Identity grade leaves the normalized background solid

- **WHEN** normalization produces a solid background and the grade is at identity
- **THEN** the normalized output is delivered unmodified and the background remains solid

### Requirement: Normalization applies to all delivered outputs

Normalization SHALL apply uniformly to every delivered output produced from the streaming color
path — preview, `captureImage`, the tracker lane, and recording — and to the on-demand still
(`captureNaturalPicture`), so all consumers (including downstream detection/DL) receive a
consistently normalized image.

#### Scenario: Consistent normalization across outputs

- **WHEN** normalization is enabled
- **THEN** preview, `captureImage`, `captureNaturalPicture`, the tracker lane, and recording all reflect the same normalization

### Requirement: Persistence of normalization configuration

The system SHALL persist normalization coefficients and toggles (black point, white-balance chroma,
and white-point level) across sessions, consistent with how processing parameters are persisted
today. Manual white-balance state SHALL follow the existing rule that it is not silently restored
into auto mode on load.

#### Scenario: Coefficients restored on next launch

- **WHEN** the app relaunches after a calibration
- **THEN** the saved black-point / chroma / white-point coefficients and toggles are restored
- **AND** white-balance does not silently start in a stale manual lock

### Requirement: Legacy black-balance removed (breaking)

The legacy post-grade black-balance SHALL be **removed entirely** — its public API
(`calibrateBlackBalance` across Swift/Pigeon/Dart), its `ProcessingParameters.blackR/G/B` fields and
`ColorUniform` mirror, and its post-grade shader subtraction (`ColorShaders.metal` step 5). This is
an **accepted breaking API change**; no deprecated alias or forwarding is provided. The new linear
black point (`calibrateBlackPoint`) is the only black operation. Old persisted settings SHALL still
decode their grade values (brightness/contrast/saturation/gamma) without reset; the legacy black
keys SHALL be ignored (not applied, not migrated). The removal SHALL be documented in consumer docs
and called out as **breaking** in the GitHub release notes.

#### Scenario: Legacy API is gone

- **WHEN** a downstream consumer references `calibrateBlackBalance`
- **THEN** it no longer exists (Swift compile error / Flutter `PlatformException`) — consumers must migrate to `calibrateBlackPoint`

#### Scenario: Old settings decode grade values without legacy black

- **WHEN** the app loads settings persisted under the old schema
- **THEN** grade values are preserved (no crash, no reset) and the legacy black keys are ignored
- **AND** the black point starts disabled, awaiting fresh calibration

#### Scenario: Breaking removal recorded for release

- **WHEN** the change is released
- **THEN** the GitHub release notes call out the removal of black balance as a breaking change
