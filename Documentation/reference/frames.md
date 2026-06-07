# Frames

## FrameResult

*Struct*

```swift
struct FrameResult
```

Sensor metadata delivered at constants.md#FRAME_RESULT_HEARTBEAT_HZ.

### init(iso:exposureTimeNs:focusDistance:wbGainR:wbGainG:wbGainB:diagnosticsJSON:)

```swift
init(iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil, wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil, diagnosticsJSON: String? = nil)
```

### diagnosticsJSON

```swift
var diagnosticsJSON: String?
```

Heavyweight, debug-only diagnostics as a JSON string (frame-metadata-signals). Carries detail a consumer does NOT branch on — full AF/WB/AE convergence state and the grade params (brightness/contrast/saturation/gamma/cropRegion/ white-balance gains, formerly `ProcessingMetadata`). It is NOT a control surface: anything load-bearing must be promoted to a typed field (on `CameraFrameMetadata` for per-frame decisions). Shape is intentionally unstable — debug grade, not a contract.

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

## CameraFrameMetadata

*Struct*

```swift
struct CameraFrameMetadata
```

The camera's per-frame metadata, carried on every delivered ``Frame``. Carries the **typed decision signals** a consumer branches on — convergence state derived from the real device (`DeviceStateSnapshot` / KVO), never a zero-valued placeholder. Heavyweight debug detail (full AF/WB/AE state, grade params) is NOT here — it rides the low-rate `frameResultStream()` JSON payload (`FrameResult.diagnosticsJSON`). Rule (frame-metadata-signals): anything a consumer makes a control decision on is a typed member here. Consumers downcast `Frame.metadata` to this type at the camera-source boundary, then read `settled` (and/or the per-axis states) to gate decisions such as a first-writer-wins mosaic seed.

### init(focusState:wbState:exposureState:)

```swift
init(focusState: FocusState = .unknown, wbState: WhiteBalanceState = .unknown, exposureState: ExposureState = .unknown)
```

Designated init. `settled` is computed as the conjunction of the three axes; it is never set independently. Defaults are `.unknown` (pre-snapshot fail-safe: `settled == false`, so an unconverged-or-unknown frame never seeds).

### exposureState

```swift
let exposureState: ExposureState
```

### focusState

```swift
let focusState: FocusState
```

### settled

```swift
let settled: Bool
```

`true` iff all three axes have converged. `AE converged && WB settled && focus converged`. A single Bool would hide which axis is unconverged, so the per-axis fields below are also exposed for finer gating.

### wbState

```swift
let wbState: WhiteBalanceState
```

## FocusState

*Enum*

```swift
enum FocusState
```

Lens convergence state for the frame.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### FocusState.adjusting

```swift
case adjusting
```

Mid-autofocus — the lens is still moving.

### FocusState.converged

```swift
case converged
```

Lens is locked or has finished adjusting.

### FocusState.unknown

```swift
case unknown
```

No device snapshot was available when the frame was built.

## WhiteBalanceState

*Enum*

```swift
enum WhiteBalanceState
```

White-balance convergence state for the frame.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### WhiteBalanceState.adjusting

```swift
case adjusting
```

White balance is still adjusting.

### WhiteBalanceState.settled

```swift
case settled
```

White balance has settled (locked, manual, or finished adjusting).

### WhiteBalanceState.unknown

```swift
case unknown
```

No device snapshot was available when the frame was built.

## ExposureState

*Enum*

```swift
enum ExposureState
```

Auto-exposure convergence state for the frame.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### ExposureState.adjusting

```swift
case adjusting
```

Auto-exposure is still searching.

### ExposureState.converged

```swift
case converged
```

Exposure is locked or has finished converging.

### ExposureState.unknown

```swift
case unknown
```

No device snapshot was available when the frame was built.

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
