# Calibration

White-balance and black-point calibration, and reading the result.

Assumes you have read [06-controlling-the-camera](06-controlling-the-camera.md).

Calibration is a **two-layer surface**: a one-call procedure per field
(`calibrateWhite` / `calibrateBlack`) that samples, computes, and enables in one
shot, plus independent enable/disable/clear toggles to adjust the result
afterward without recalibrating.

## White-balance calibration

`CameraEngine.calibrateWhite(whitePoint:)` samples a white field, locks the
hardware white balance, derives **both** the per-channel chroma residual
(neutralizes the color cast) and the white-point level, and enables them. Point
the camera at a bright, evenly-lit white field before calling it; it **throws**
`EngineError.whiteBalanceCalibrationFailed(reason:)` if the patch is too dark to
be a white reference.

The `whitePoint` argument selects the look:

- `whitePoint: true` (default) — **brightfield**: chroma + white-point level, so
  the white field maps to solid white.
- `whitePoint: false` — **phase contrast**: chroma only, so a grey field is
  neutralized but its level is preserved (not stretched to white).

```swift
let result = try await engine.calibrateWhite(whitePoint: true)   // brightfield
// ...or engine.calibrateWhite(whitePoint: false) for phase contrast.
```

Switch between the two modes later without recapturing a white field:
`CameraEngine.enableWhitePoint()` / `CameraEngine.disableWhitePoint()`.
Toggle the chroma residual itself with `CameraEngine.enableWhiteBalance()` /
`CameraEngine.disableWhiteBalance()`, and discard the calibration with
`CameraEngine.clearWhiteBalance()`. `enableWhitePoint()` / `enableWhiteBalance()`
**throw** `EngineError.whiteBalanceNotCalibrated` if no white field has been
calibrated (white point cannot apply without chroma).

> Note: the chroma residual and white point are **software** normalization, gated
> to a locked hardware white balance. Returning the camera to continuous auto
> white balance is a separate axis — set `wbMode: .auto` — which also switches
> these off (a software residual can't ride on moving auto gains).

## Black-point calibration

`CameraEngine.calibrateBlack()` derives a per-channel linear black point from a
dark field and applies it (subtracted in linear light, before the grade — a
dark-field/pedestal subtraction, *not* a range-stretching levels black point).
Point the camera at a uniformly dark/black field, then call it. It **throws**
`EngineError.blackPointCalibrationFailed(reason:)` when the field isn't dark
enough — too little of the sampled patch reads as near-black — leaving any
existing black point untouched.

```swift
do {
    let debug = try await engine.calibrateBlack()
    // The black point is now calibrated and enabled.
} catch {
    // Field wasn't dark enough — show the error and let the user retry.
}
```

Toggle a calibrated black point with `CameraEngine.enableBlackPoint()` (throws
`EngineError.blackPointNotCalibrated` if never calibrated) /
`CameraEngine.disableBlackPoint()`, and discard it with
`CameraEngine.clearBlackPoint()`.

## Reading CalibrationResult

`CalibrationResult` reports:

- `CalibrationResult.before` and `CalibrationResult.after` — the measured
  `RgbSample` (`RgbSample.r`, `RgbSample.g`, `RgbSample.b`) before and
  after calibration.
- `CalibrationResult.converged` — whether the calibration reached a stable
  result.
- `CalibrationResult.iterations` — how many steps it took.

## Convergence and failure

For white balance, when `CalibrationResult.converged` is `false` the scene was
unsuitable (not neutral enough, or too dark) — leave the previous settings in
place and prompt the user to retry against a neutral surface. Black point instead
signals failure by **throwing** (the field wasn't dark enough). Both methods are
`async throws`; handle thrown errors as a calibration failure
([09-observing-state-and-errors](09-observing-state-and-errors.md)).

## Reference integration

`ios_example_app/ios_example_app/UI/CalibrationViewModel.swift` calls
`CameraEngine.calibrateWhite(whitePoint:)` and presents the `CalibrationResult`.
