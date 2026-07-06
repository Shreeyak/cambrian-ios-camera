# Configuration

## OpenConfiguration

*Struct*

```swift
struct OpenConfiguration
```

Startup arguments for CameraEngine.open(configuration:).

### init(cameraId:captureResolution:targetFps:cropRegion:cropEnabled:initialSettings:trackerHeight:captureOrientationAngleDeg:)

```swift
init(cameraId: String? = nil, captureResolution: Size? = nil, targetFps: Int? = nil, cropRegion: Rect? = nil, cropEnabled: Bool = false, initialSettings: CameraSettings? = nil, trackerHeight: Int? = nil, captureOrientationAngleDeg: CGFloat = 0)
```

### cameraId

```swift
var cameraId: String?
```

### captureOrientationAngleDeg

```swift
var captureOrientationAngleDeg: CGFloat
```

Capture-buffer rotation in degrees, applied to the video/photo connections via `videoRotationAngle`. This rotates the *delivered pixel buffers* themselves, so every lane (preview, processed, tracker) and stills inherit it consistently. Valid values are `0` / `90` / `180` / `270`; an unsupported angle throws at `open()`. A host that locks its UI to landscape-left, for example, passes `180` so the delivered frame reads upright.

### captureResolution

```swift
var captureResolution: Size?
```

### cropEnabled

```swift
var cropEnabled: Bool
```

Whether the output is cropped at open. Separates crop *policy* from *geometry* (camera-crop-config). When `cropRegion` is set, that rect is the configured crop and is applied regardless of this flag. Defaults to `false` (full-frame output).

### cropRegion

```swift
var cropRegion: Rect?
```

### initialSettings

```swift
var initialSettings: CameraSettings?
```

Hardware settings to apply during session setup, before the first frame is delivered. Folds the Pigeon contract's `open(cameraId, settings)` shape into CameraKit's structural `OpenConfiguration` so the requested settings are live from frame one (no defaults-then-snap flicker). Applied via the same `updateSettings` merge+coupling+commit path after `setupSession` returns and before the first `startRunning`.

### targetFps

```swift
var targetFps: Int?
```

Target capture frame rate, locked in every mode (preview / still / recording). Any integer is accepted but is validated at `open()` against the selected resolution's live `videoSupportedFrameRateRanges` — an unsupported `(captureResolution, targetFps)` pair throws `EngineError.settingsConflict` naming the frame rates valid for that resolution (the valid set is discoverable via `SessionCapabilities`, including slow-mo rates where a binned format supports them). Frame rate and resolution are independent: choosing a lower `targetFps` does not enlarge the default resolution. Because a frame's exposure cannot exceed its frame duration, `targetFps` also caps the max usable manual exposure at `1/targetFps`; open at a lower `targetFps` for longer exposures. Open-time only — change it by close + reopen.

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

### init(supportedSizes:supportedFrameRates:activeFrameRate:previewTextureId:activeCaptureResolution:activeCropRegion:streamPixelFormat:isoRange:exposureDurationRangeNs:focusRange:zoomRange:evCompensationRange:trackerResolution:)

```swift
init(supportedSizes: [Size], supportedFrameRates: [FrameRateRange] = [], activeFrameRate: Int = 30, previewTextureId: Int, activeCaptureResolution: Size, activeCropRegion: Rect, streamPixelFormat: String, isoRange: ClosedRange<Float>, exposureDurationRangeNs: ClosedRange<Int64>, focusRange: ClosedRange<Double>, zoomRange: ClosedRange<Double>, evCompensationRange: ClosedRange<Float>, trackerResolution: Size)
```

### activeCaptureResolution

```swift
let activeCaptureResolution: Size
```

### activeCropRegion

```swift
let activeCropRegion: Rect
```

### activeFrameRate

```swift
let activeFrameRate: Int
```

The frame rate the session is locked to (the resolved `OpenConfiguration.targetFps`).

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

### previewTextureId

```swift
let previewTextureId: Int
```

### streamPixelFormat

```swift
let streamPixelFormat: String
```

Always `"BGRA8"` (`kCVPixelFormatType_32BGRA`, `.bgra8Unorm`) — Apple's `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS, and the single delivery format for every lane and every surface type. The **texture accessors** — `currentProcessedTexture()`, `currentTrackerTexture()` — return the same BGRA8 IOSurface as the matching `currentPixelBuffer(stream:)`. RGBA16F survives only as an internal Metal-compute intermediate (the camera is 8-bit-locked, so float precision buys nothing at the boundary). Note this is **not** the camera *source* format (YUV `420f`, converted by MetalPipeline Pass-1).

### supportedFrameRates

```swift
let supportedFrameRates: [FrameRateRange]
```

Frame-rate ranges supported per resolution, live from the device's 420f formats. Includes slow-mo where offered. A caller reads this to pick a valid `(captureResolution, targetFps)` before `open()`. See `FrameRateRange`.

### supportedSizes

```swift
let supportedSizes: [Size]
```

### trackerResolution

```swift
let trackerResolution: Size
```

Effective (clamped and even-rounded) tracker lane resolution. Derived from `OpenConfiguration.trackerHeight` (height-driven, aspect-preserved against the primary output size, clamped `2…primaryHeight`, rounded to even). When `trackerHeight == primaryHeight`, this equals `activeCaptureResolution` and the tracker is produced by a 1:1 copy with no resampling.

### zoomRange

```swift
let zoomRange: ClosedRange<Double>
```

`AVCaptureDevice.minAvailableVideoZoomFactor`... `maxAvailableVideoZoomFactor`. Returned for the active format.

## FrameRateRange

*Struct*

```swift
struct FrameRateRange
```

A capture resolution paired with a frame-rate range it supports. One entry per (size, `videoSupportedFrameRateRanges` range) the device offers as a full-range 420f format, so a size can appear more than once — e.g. a full-FOV `1–60` range and a binned slow-mo `2–240` range at the same dimensions (configurable-frame-rate). `minFps`/`maxFps` are the inclusive integer bounds a caller may pass as `OpenConfiguration.targetFps` for that resolution.

### init(size:minFps:maxFps:)

```swift
init(size: Size, minFps: Int, maxFps: Int)
```

### maxFps

```swift
let maxFps: Int
```

### minFps

```swift
let minFps: Int
```

### size

```swift
let size: Size
```

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
