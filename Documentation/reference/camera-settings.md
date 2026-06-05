# Camera Settings

## CameraSettings

*Struct*

```swift
struct CameraSettings
```

Partial-update settings object.

### init(from:)

```swift
init(from decoder: any Decoder) throws
```

### init(isoMode:iso:exposureMode:exposureTimeNs:focusMode:focusDistance:wbMode:wbGainR:wbGainG:wbGainB:zoomRatio:evCompensation:)

```swift
init(isoMode: CameraMode? = nil, iso: Int? = nil, exposureMode: CameraMode? = nil, exposureTimeNs: Int64? = nil, focusMode: CameraMode? = nil, focusDistance: Double? = nil, wbMode: WhiteBalanceMode? = nil, wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil, zoomRatio: Double? = nil, evCompensation: Int? = nil)
```

### evCompensation

```swift
var evCompensation: Int?
```

### exposureMode

```swift
var exposureMode: CameraMode?
```

### exposureTimeNs

```swift
var exposureTimeNs: Int64?
```

### focusDistance

```swift
var focusDistance: Double?
```

### focusMode

```swift
var focusMode: CameraMode?
```

### iso

```swift
var iso: Int?
```

### isoMode

```swift
var isoMode: CameraMode?
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

### wbMode

```swift
var wbMode: WhiteBalanceMode?
```

### zoomRatio

```swift
var zoomRatio: Double?
```

### merging(onto:)

```swift
func merging(onto prior: CameraSettings) -> CameraSettings
```

Overlay every non-nil field from `self` onto `prior`. Nil fields in `self` preserve `prior`.

## CameraMode

*Enum*

```swift
enum CameraMode
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### CameraMode.auto

```swift
case auto
```

### CameraMode.manual

```swift
case manual
```

## WhiteBalanceMode

*Enum*

```swift
enum WhiteBalanceMode
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### WhiteBalanceMode.auto

```swift
case auto
```

### WhiteBalanceMode.locked

```swift
case locked
```

### WhiteBalanceMode.manual

```swift
case manual
```

## WhiteBalancePreset

*Enum*

```swift
enum WhiteBalancePreset
```

Apple's named WB temperature/tint presets. Each case maps 1:1 to `AVCaptureDevice.WhiteBalanceTemperatureAndTintValues` static properties (iOS 26.0+). Underlying Kelvin/tint values are sensor-calibrated and not published by Apple.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### WhiteBalancePreset.cloudy

```swift
case cloudy
```

### WhiteBalancePreset.daylight

```swift
case daylight
```

### WhiteBalancePreset.fluorescent

```swift
case fluorescent
```

### WhiteBalancePreset.shadow

```swift
case shadow
```

### WhiteBalancePreset.tungsten

```swift
case tungsten
```

## CameraPosition

*Enum*

```swift
enum CameraPosition
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### CameraPosition.back

```swift
case back
```

### CameraPosition.front

```swift
case front
```

### CameraPosition.wide

```swift
case wide
```
