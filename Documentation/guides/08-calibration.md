# Calibration

White- and black-balance calibration, and reading the result.

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

## Black-balance calibration

`CameraEngine.calibrateBlackBalance()` calibrates the black level the same way
and also returns a `CalibrationResult`.

## Reading CalibrationResult

`CalibrationResult` reports:

- `CalibrationResult.before` and `CalibrationResult.after` — the measured
  `RgbSample` (`RgbSample.r`, `RgbSample.g`, `RgbSample.b`) before and
  after calibration.
- `CalibrationResult.converged` — whether the calibration reached a stable
  result.
- `CalibrationResult.iterations` — how many steps it took.

## Convergence and failure

When `CalibrationResult.converged` is `false`, the scene was unsuitable (for
example, not neutral enough, or too dark). Leave the previous settings in place
and prompt the user to retry against a neutral surface. Both methods are `async
throws`; handle thrown errors as a calibration failure ([09-observing-state-and-errors](09-observing-state-and-errors.md)).

## Reference integration

`ios_example_app/ios_example_app/UI/CalibrationViewModel.swift` calls
`CameraEngine.calibrateWhiteBalance()` and presents the `CalibrationResult`.
