# Frames

## FrameResult

*Struct*

```swift
struct FrameResult
```

Sensor metadata delivered at constants.md#FRAME_RESULT_HEARTBEAT_HZ.

### init(iso:exposureTimeNs:focusDistance:wbGainR:wbGainG:wbGainB:)

```swift
init(iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil, wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil)
```

### exposureTimeNs

```swift
var exposureTimeNs: Int64?
```

### focusDistance

```swift
var focusDistance: Double?
```

### iso

```swift
var iso: Int?
```

### wbGainB

```swift
var wbGainB: Double?
```

### wbGainG

```swift
var wbGainG: Double?
```

### wbGainR

```swift
var wbGainR: Double?
```

## FrameSet

*Struct*

```swift
struct FrameSet
```

Published to subscribed lanes via `ConsumerRegistry.yield(_:stream:)`. # Lifetime contract Consumers must not retain a `FrameSet` (or its `natural` / `processed` / `tracker` `CVPixelBuffer`s) across an `await` or beyond the next stream yield. The buffers are pool-backed (POOL_CAP_RULE); retention exhausts the pool, starves frame delivery, and surfaces three hops away as `frameStall` / watchdog recovery — root cause invisible from the symptom. Snapshot any fields you need (`frameNumber`, `captureTime`, `capture`, `processing`, `blurScore`, `trackerQuality`) into your own storage before yielding control. If you need the pixel data itself, copy it under `CVPixelBufferLockBaseAddress` into your own backing store.

### init(frameNumber:captureTime:natural:processed:tracker:capture:processing:blurScore:trackerQuality:)

```swift
init(frameNumber: UInt64, captureTime: CMTime, natural: CVPixelBuffer, processed: CVPixelBuffer, tracker: CVPixelBuffer, capture: CaptureMetadata, processing: ProcessingMetadata, blurScore: Float, trackerQuality: TrackerQuality)
```

### blurScore

```swift
let blurScore: Float
```

### capture

```swift
let capture: CaptureMetadata
```

### captureTime

```swift
let captureTime: CMTime
```

### frameNumber

```swift
let frameNumber: UInt64
```

### natural

```swift
let natural: CVPixelBuffer
```

### processed

```swift
let processed: CVPixelBuffer
```

### processing

```swift
let processing: ProcessingMetadata
```

### tracker

```swift
let tracker: CVPixelBuffer
```

### trackerQuality

```swift
let trackerQuality: TrackerQuality
```

### hash(into:)

```swift
func hash(into hasher: inout Hasher)
```

### ==(_:_:)

```swift
static func == (lhs: FrameSet, rhs: FrameSet) -> Bool
```

## CaptureMetadata

*Struct*

```swift
struct CaptureMetadata
```

### init(iso:exposureDurationNs:whiteBalanceGains:whiteBalanceModeActive:lensPosition:focusModeActive:exposureModeActive:zoomFactor:cameraPosition:)

```swift
init(iso: Float, exposureDurationNs: Int64, whiteBalanceGains: WhiteBalanceGains, whiteBalanceModeActive: WhiteBalanceMode, lensPosition: Float, focusModeActive: CameraMode, exposureModeActive: CameraMode, zoomFactor: Double, cameraPosition: CameraPosition)
```

### cameraPosition

```swift
let cameraPosition: CameraPosition
```

### exposureDurationNs

```swift
let exposureDurationNs: Int64
```

### exposureModeActive

```swift
let exposureModeActive: CameraMode
```

### focusModeActive

```swift
let focusModeActive: CameraMode
```

### iso

```swift
let iso: Float
```

### lensPosition

```swift
let lensPosition: Float
```

### whiteBalanceGains

```swift
let whiteBalanceGains: WhiteBalanceGains
```

### whiteBalanceModeActive

```swift
let whiteBalanceModeActive: WhiteBalanceMode
```

### zoomFactor

```swift
let zoomFactor: Double
```

## ProcessingMetadata

*Struct*

```swift
struct ProcessingMetadata
```

Per-frame snapshot of color-transform and crop parameters applied by the GPU. Constructed during `MetalPipeline.encode()` from the `Mutex<UniformStorage>` snapshot so the consumer-visible metadata exactly matches what the GPU rendered.

### init(cropRegion:brightness:contrast:saturation:gamma:whiteBalanceGains:)

```swift
init(cropRegion: Rect, brightness: Float, contrast: Float, saturation: Float, gamma: Float, whiteBalanceGains: WhiteBalanceGains)
```

### brightness

```swift
let brightness: Float
```

### contrast

```swift
let contrast: Float
```

### cropRegion

```swift
let cropRegion: Rect
```

### gamma

```swift
let gamma: Float
```

### saturation

```swift
let saturation: Float
```

### whiteBalanceGains

```swift
let whiteBalanceGains: WhiteBalanceGains
```

## FrameDeliveryStats

*Struct*

```swift
struct FrameDeliveryStats
```

### init(producedByLane:deliveredByLane:droppedByLane:holdOverBudgetByLane:poolExhaustion:cppOverwriteByLane:)

```swift
init(producedByLane: [StreamId : UInt64], deliveredByLane: [StreamId : UInt64], droppedByLane: [StreamId : UInt64], holdOverBudgetByLane: [StreamId : UInt64], poolExhaustion: UInt64, cppOverwriteByLane: [StreamId : UInt64])
```

### cppOverwriteByLane

```swift
let cppOverwriteByLane: [StreamId : UInt64]
```

### deliveredByLane

```swift
let deliveredByLane: [StreamId : UInt64]
```

### droppedByLane

```swift
let droppedByLane: [StreamId : UInt64]
```

### holdOverBudgetByLane

```swift
let holdOverBudgetByLane: [StreamId : UInt64]
```

### poolExhaustion

```swift
let poolExhaustion: UInt64
```

### producedByLane

```swift
let producedByLane: [StreamId : UInt64]
```

## TrackerQuality

*Enum*

```swift
enum TrackerQuality
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### TrackerQuality.degraded

```swift
case degraded
```

### TrackerQuality.good

```swift
case good
```

### TrackerQuality.invalid

```swift
case invalid
```
