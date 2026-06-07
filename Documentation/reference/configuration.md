# Configuration

## OpenConfiguration

*Struct*

```swift
struct OpenConfiguration
```

Startup arguments for CameraEngine.open(configuration:).

### init(cameraId:captureResolution:cropRegion:initialSettings:trackerHeight:)

```swift
init(cameraId: String? = nil, captureResolution: Size? = nil, cropRegion: Rect? = nil, initialSettings: CameraSettings? = nil, trackerHeight: Int? = nil)
```

### cameraId

```swift
var cameraId: String?
```

### captureResolution

```swift
var captureResolution: Size?
```

### cropRegion

```swift
var cropRegion: Rect?
```

### initialSettings

```swift
var initialSettings: CameraSettings?
```

Hardware settings to apply during session setup, before the first frame is delivered. Folds the Pigeon contract's `open(cameraId, settings)` shape into CameraKit's structural `OpenConfiguration` so the requested settings are live from frame one (no defaults-then-snap flicker). Applied via the same `updateSettings` merge+coupling+commit path after `setupSession` returns and before the first `startRunning`.

### trackerHeight

```swift
var trackerHeight: Int?
```

Target height (px) of the downsampled `tracker` lane. The tracker width is derived to preserve the output (processed) lane's aspect ratio — the two lanes must share an aspect so a motion vector measured on the tracker scales linearly to the processed frame. `nil` uses the package default. Clamped to `2... outputHeight` (the lane is a downsample, never an upscale) and rounded down to an even value.

## SessionCapabilities

*Struct*

```swift
struct SessionCapabilities
```

### init(supportedSizes:previewTextureId:naturalTextureId:activeCaptureResolution:activeCropRegion:streamPixelFormat:isoRange:exposureDurationRangeNs:focusRange:zoomRange:evCompensationRange:)

```swift
init(supportedSizes: [Size], previewTextureId: Int, naturalTextureId: Int, activeCaptureResolution: Size, activeCropRegion: Rect, streamPixelFormat: String, isoRange: ClosedRange<Float>, exposureDurationRangeNs: ClosedRange<Int64>, focusRange: ClosedRange<Double>, zoomRange: ClosedRange<Double>, evCompensationRange: ClosedRange<Float>)
```

### activeCaptureResolution

```swift
let activeCaptureResolution: Size
```

### activeCropRegion

```swift
let activeCropRegion: Rect
```

### evCompensationRange

```swift
let evCompensationRange: ClosedRange<Float>
```

`AVCaptureDevice.minExposureTargetBias`... `maxExposureTargetBias`. Reported in EV stops (signed).

### exposureDurationRangeNs

```swift
let exposureDurationRangeNs: ClosedRange<Int64>
```

### focusRange

```swift
let focusRange: ClosedRange<Double>
```

Lens-position range — always `0.0...1.0` on iOS. `AVCaptureDevice.lensPosition` is normalized, not real diopters. Kept for shape parity with the Pigeon contract's `focusMin`/`focusMax`.

### isoRange

```swift
let isoRange: ClosedRange<Float>
```

### naturalTextureId

```swift
let naturalTextureId: Int
```

### previewTextureId

```swift
let previewTextureId: Int
```

### streamPixelFormat

```swift
let streamPixelFormat: String
```

Always `"BGRA8"` (`kCVPixelFormatType_32BGRA`, `.bgra8Unorm`) — Apple's `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS, and the single delivery format for every lane and every surface type. The **texture accessors** — `currentTexture()`, `currentProcessedTexture()`, `currentTrackerTexture()` — return the same BGRA8 IOSurface as the matching `currentPixelBuffer(stream:)`. RGBA16F survives only as an internal Metal-compute intermediate (the camera is 8-bit-locked, so float precision buys nothing at the boundary). Note this is **not** the camera *source* format (YUV `420f`, converted by MetalPipeline Pass-1).

### supportedSizes

```swift
let supportedSizes: [Size]
```

### zoomRange

```swift
let zoomRange: ClosedRange<Double>
```

`AVCaptureDevice.minAvailableVideoZoomFactor`... `maxAvailableVideoZoomFactor`. Returned for the active format.

## StreamConfiguration

*Struct*

```swift
struct StreamConfiguration
```

Active stream configuration emitted on `CameraEngine.streamConfigurationStream()`. Fires after `setResolution(...)` resolves to a new camera stream size or after `setCropRegion(...)` mutates the active crop.

### init(activeCaptureResolution:activeCropRegion:)

```swift
init(activeCaptureResolution: Size, activeCropRegion: Rect)
```

### activeCaptureResolution

```swift
let activeCaptureResolution: Size
```

### activeCropRegion

```swift
let activeCropRegion: Rect
```

## Size

*Struct*

```swift
struct Size
```

### init(width:height:)

```swift
init(width: Int, height: Int)
```

### height

```swift
let height: Int
```

### width

```swift
let width: Int
```

## Rect

*Struct*

```swift
struct Rect
```

### init(x:y:width:height:)

```swift
init(x: Int, y: Int, width: Int, height: Int)
```

### height

```swift
let height: Int
```

### width

```swift
let width: Int
```

### x

```swift
let x: Int
```

### y

```swift
let y: Int
```
