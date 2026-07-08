# Image Processing

## ProcessingParameters

*Struct*

```swift
struct ProcessingParameters
```

GPU color-processing shader parameters. All fields required.

### init(brightness:contrast:saturation:gamma:blackPointR:blackPointG:blackPointB:blackPointEnabled:wbChromaR:wbChromaG:wbChromaB:wbChromaEnabled:whitePointLevel:whitePointEnabled:)

```swift
init(brightness: Double = 0.0, contrast: Double = 0.0, saturation: Double = 0.0, gamma: Double = 1.0, blackPointR: Double = 0.0, blackPointG: Double = 0.0, blackPointB: Double = 0.0, blackPointEnabled: Bool = false, wbChromaR: Double = 1.0, wbChromaG: Double = 1.0, wbChromaB: Double = 1.0, wbChromaEnabled: Bool = false, whitePointLevel: Double = 1.0, whitePointEnabled: Bool = false)
```

### init(from:)

```swift
init(from decoder: any Decoder) throws
```

Migration-safe decode: old `…v2` blobs predate the normalization fields, and Swift's synthesized `Decodable` throws on missing keys. Decoding every field via `decodeIfPresent` with the identity default keeps persisted brightness/contrast/saturation/gamma *values* (so settings don't reset) while normalization fields default to identity/disabled. This does NOT preserve the old operation order: the order is linear normalization (WB / white point / black point) then the gamma-space grade. Legacy `blackR/G/B` keys in old blobs are ignored (the legacy black-balance was removed — a breaking change); the linear black point is recalibrated fresh.

### identity

```swift
static let identity: ProcessingParameters
```

### blackPointB

```swift
var blackPointB: Double
```

### blackPointEnabled

```swift
var blackPointEnabled: Bool
```

### blackPointG

```swift
var blackPointG: Double
```

### blackPointR

```swift
var blackPointR: Double
```

Per-channel linear black point that offsets dark values toward 0 (identity `0`). Folded into the normalization affine `b` term when `blackPointEnabled`. Derived statistically (`mean + blackPointSigmaK·σ`) from a dark field.

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

### wbChromaB

```swift
var wbChromaB: Double
```

### wbChromaEnabled

```swift
var wbChromaEnabled: Bool
```

### wbChromaG

```swift
var wbChromaG: Double
```

### wbChromaR

```swift
var wbChromaR: Double
```

Per-channel white-balance chroma residual gain (identity `1`). Brightness-preserving cast neutralization applied on top of the locked hardware gains; gated to manual WB mode (identity in auto — enforced by `CameraEngine`, so the stored value is always "effective"). Folded into the affine `a` term when `wbChromaEnabled`.

### whitePointEnabled

```swift
var whitePointEnabled: Bool
```

### whitePointLevel

```swift
var whitePointLevel: Double
```

Separate, optional, off by default (phase-contrast grey must not be stretched). Only valid alongside `wbChroma`; folded into the affine `a`.
