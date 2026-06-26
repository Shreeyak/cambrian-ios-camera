# Calibration

## CalibrationResult

*Struct*

```swift
struct CalibrationResult
```

Returned by `CameraEngine.calibrateWhiteBalance()`. Fields mirror the Pigeon contract's `CamCalibrationResult`.

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

## BlackPointDebug

*Struct*

```swift
struct BlackPointDebug
```

Per-channel black-point calibration diagnostics.

### init(keptCount:totalCount:r:g:b:)

```swift
init(keptCount: Int, totalCount: Int, r: BlackPointChannelStats, g: BlackPointChannelStats, b: BlackPointChannelStats)
```

### b

```swift
let b: BlackPointChannelStats
```

### g

```swift
let g: BlackPointChannelStats
```

### keptCount

```swift
let keptCount: Int
```

Pixels that passed the per-pixel near-black gate (all channels < threshold).

### r

```swift
let r: BlackPointChannelStats
```

### totalCount

```swift
let totalCount: Int
```

Total pixels in the sampled patch.

## BlackPointChannelStats

*Struct*

```swift
struct BlackPointChannelStats
```

Per-channel diagnostics from a black-point calibration (linear-normalization-stage). Surfaced to the demo app so an operator can see *why* a calibration produced the offset it did — e.g. a too-bright surface yields `keptCount == 0` and a high `maxGamma`, explaining a zero (no-op) black point.

### init(offsetLinear:meanGamma:minGamma:maxGamma:)

```swift
init(offsetLinear: Double, meanGamma: Double, minGamma: Double, maxGamma: Double)
```

### maxGamma

```swift
let maxGamma: Double
```

Max over ALL patch pixels (gamma) — if this exceeds the near-black threshold, those pixels were gated out.

### meanGamma

```swift
let meanGamma: Double
```

Mean of the *kept* (near-black) pixels, in gamma/display space (0…1).

### minGamma

```swift
let minGamma: Double
```

Min over ALL patch pixels (gamma) — shows how dark the darkest pixel was.

### offsetLinear

```swift
let offsetLinear: Double
```

The applied linear black-point offset (`mean + k·σ` over the kept pixels).
