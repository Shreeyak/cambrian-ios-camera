# Calibration

## CalibrationResult

*Struct*

```swift
struct CalibrationResult
```

Returned by `CameraEngine.calibrateWhiteBalance()` / `calibrateBlackBalance()`. Fields mirror the Pigeon contract's `CamCalibrationResult`.

### init(before:after:converged:iterations:)

```swift
init(before: RgbSample, after: RgbSample, converged: Bool, iterations: Int)
```

### after

```swift
let after: RgbSample
```

RGB sample of the center patch *after* the calibration was applied.

### before

```swift
let before: RgbSample
```

RGB sample of the center patch *before* the calibration was applied.

### converged

```swift
let converged: Bool
```

Whether the algorithm converged. Always `true` for single-shot.

### iterations

```swift
let iterations: Int
```

Iteration count. Always `1` for single-shot.

## RgbSample

*Struct*

```swift
struct RgbSample
```

Per-channel trimmed-mean sample from sampleCenterPatch().

### init(r:g:b:)

```swift
init(r: Double, g: Double, b: Double)
```

### b

```swift
var b: Double
```

### g

```swift
var g: Double
```

### r

```swift
var r: Double
```

## WhiteBalanceGains

*Struct*

```swift
struct WhiteBalanceGains
```

### init(red:green:blue:)

```swift
init(red: Float, green: Float, blue: Float)
```

### blue

```swift
let blue: Float
```

### green

```swift
let green: Float
```

### red

```swift
let red: Float
```
