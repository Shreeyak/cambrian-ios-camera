# Image Processing

## ProcessingParameters

*Struct*

```swift
struct ProcessingParameters
```

GPU color-processing shader parameters. All fields required.

### init(brightness:contrast:saturation:blackR:blackG:blackB:gamma:)

```swift
init(brightness: Double = 0.0, contrast: Double = 0.0, saturation: Double = 0.0, blackR: Double = 0.0, blackG: Double = 0.0, blackB: Double = 0.0, gamma: Double = 1.0)
```

### init(from:)

```swift
init(from decoder: any Decoder) throws
```

### identity

```swift
static let identity: ProcessingParameters
```

### blackB

```swift
var blackB: Double
```

### blackG

```swift
var blackG: Double
```

### blackR

```swift
var blackR: Double
```

Per-channel black-balance pedestal. The GPU pipeline subtracts these values from the graded image as the **final** color step, after brightness, contrast, saturation, and gamma. Range typically `[0, 0.5]`. See `Shaders/ColorShaders.metal` for the exact order.

### brightness

```swift
var brightness: Double
```

### contrast

```swift
var contrast: Double
```

Contrast adjustment in `[-1, 1]`, `0.0` = identity. Linear scale around the 0.5 luma midpoint via a `1 + contrast` multiplier: `-1.0` = fully flat grey, `+1.0` = 2× contrast. Shares the `[-1, 1]` / `0.0`-identity convention with `brightness` and `saturation`. See `Shaders/ColorShaders.metal`.

### gamma

```swift
var gamma: Double
```

### saturation

```swift
var saturation: Double
```
