# Calibration

White-balance and black-point calibration, and reading the result.

Assumes you have read [06-controlling-the-camera](06-controlling-the-camera.md).

## White-balance calibration

`CameraEngine.calibrateWhiteBalance()` runs a gray-world calibration against
the current scene and returns a `CalibrationResult`. Point the camera at a
neutral (gray or white) surface before calling it.

```swift
let result = try await engine.calibrateWhiteBalance()
if result.converged {
    // White balance is now calibrated for the scene.
}
```

## Black-point calibration

`CameraEngine.calibrateBlackPoint()` derives a per-channel linear black point
from a dark field and applies it (subtracted in linear light, before the grade).
Point the camera at a uniformly dark/black field, then call it. It returns no
value on success; it **throws** when the field isn't dark enough — too little of
the sampled patch reads as near-black — leaving any existing black point
untouched. Catch the error and prompt the user to retry against a darker field.

```swift
do {
    try await engine.calibrateBlackPoint()
    // The black point is now calibrated and enabled.
} catch {
    // Field wasn't dark enough — show the error and let the user retry.
}
```

Clear an applied black point with `CameraEngine.clearBlackPoint()`.

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
`CameraEngine.calibrateWhiteBalance()` and presents the `CalibrationResult`.
