## ADDED Requirements

### Requirement: Capture pixel format is always full-range 420f

The engine SHALL select only a `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` ("420f") capture
format for the video path — the full-range 8-bit 4:2:0 format the linear-light normalization pipeline
expects. If the active device exposes no 420f format at all, `open()` SHALL throw a configuration error
rather than silently falling back to a video-range ("420v") or other pixel format.

#### Scenario: A full-range format is selected

- **WHEN** `open()` succeeds on a device that offers 420f formats
- **THEN** the active capture format's media subtype is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
- **AND** `SessionCapabilities.streamPixelFormat` continues to report the delivered lane format (BGRA8)

#### Scenario: No full-range format available

- **WHEN** `open()` is attempted on a device that exposes no 420f format
- **THEN** `open()` throws a configuration error and the session is not started

### Requirement: Video HDR is always disabled

The engine SHALL disable video HDR on the selected capture format so no extended-range tone-mapping is
applied to the delivered frames (which would fight the linear-light normalization stage). It SHALL set
`automaticallyAdjustsVideoHDREnabled = false` and `isVideoHDREnabled = false` on the active device. When
more than one 420f format matches the requested `(resolution, frame rate)`, the engine SHALL prefer a
format that is not HDR-capable (`isVideoHDRSupported == false`); when the only matching format is
HDR-capable (as for the largest sensor resolutions), it SHALL still be used, with HDR disabled.

#### Scenario: Non-HDR format preferred when available

- **WHEN** a requested `(resolution, frame rate)` is satisfied by both an HDR-capable and a non-HDR 420f format
- **THEN** the engine selects the non-HDR (`isVideoHDRSupported == false`) format

#### Scenario: HDR-capable-only resolution runs with HDR off

- **WHEN** the requested resolution is offered only by an HDR-capable 420f format (e.g. the largest sensor sizes)
- **THEN** the engine selects that format and disables video HDR (`isVideoHDREnabled == false`), so no HDR tone-mapping is applied

### Requirement: Target frame rate is caller-configurable and validated against live capabilities

`OpenConfiguration` SHALL expose an optional `targetFps: Int?`. A `nil` value SHALL resolve to a default
of 30 fps. A non-nil value SHALL be accepted only if the selected capture resolution has a 420f format
whose `videoSupportedFrameRateRanges` contains that value; an unsupported `(resolution, targetFps)` pair
SHALL be rejected at `open()` with a configuration error that names the requested value and the frame
rates valid for that resolution. The frame rate SHALL NOT be silently coerced to a nearby supported
value. The set of legal frame rates SHALL be derived from live device format data, not a hardcoded list
— including high-rate (slow-mo) formats where the device supports them.

#### Scenario: Supported frame rate is applied

- **WHEN** `open()` is called with a `targetFps` that the selected resolution's format supports
- **THEN** the session runs at that frame rate and `SessionCapabilities` reports it as the active frame rate

#### Scenario: Unsupported frame rate is rejected

- **WHEN** `open()` is called with a `targetFps` no format at the selected resolution supports (e.g. 60 fps at a 30-fps-only resolution)
- **THEN** `open()` throws a configuration error naming the requested frame rate and the valid frame rates for that resolution, and the session is not started

#### Scenario: Default frame rate

- **WHEN** `open()` is called with `targetFps == nil`
- **THEN** the session runs at 30 fps

### Requirement: Frame rate is locked in every mode

The engine SHALL pin the capture frame rate to `targetFps` in every operating mode — preview, still
capture, and recording — by setting `activeVideoMinFrameDuration` equal to `activeVideoMaxFrameDuration`
equal to `1/targetFps`. The engine SHALL NOT widen the frame-duration range for recording (no variable
low-light frame-rate floor); the delivered frame rate SHALL be the same in recording as in preview.

#### Scenario: Recording runs at the locked frame rate

- **WHEN** recording starts on a session opened at a given `targetFps`
- **THEN** the frame rate stays locked at `targetFps` (min and max frame duration both `1/targetFps`) for the duration of recording, identical to preview

#### Scenario: Frame rate does not drop in low light

- **WHEN** the scene is dim while running at the locked `targetFps`
- **THEN** the engine does not lower the frame rate to lengthen exposure (auto low-light rate reduction is out of scope); the frame rate remains `targetFps`

### Requirement: Manual exposure is bounded by the frame rate

The engine SHALL bound manual exposure by the locked frame rate. Because a frame's exposure cannot
exceed its frame duration, the maximum usable manual exposure at a locked `targetFps` is
`min(sensorMaxExposure, 1/targetFps)`. A requested manual exposure duration longer than that ceiling
SHALL be rejected with a configuration error naming the requested duration and the ceiling; the engine
SHALL NOT silently clamp the exposure to the ceiling. To use longer exposures a caller opens at a lower
`targetFps`.

#### Scenario: Exposure within the frame-rate ceiling is applied

- **WHEN** a manual exposure duration `≤ min(sensorMax, 1/targetFps)` is requested
- **THEN** the exposure is applied unchanged

#### Scenario: Exposure beyond the frame-rate ceiling is rejected

- **WHEN** a manual exposure duration greater than `1/targetFps` is requested (e.g. 100 ms at 30 fps)
- **THEN** the request is rejected with a configuration error naming the requested duration and the `1/targetFps` ceiling, and the exposure is not changed

### Requirement: Capabilities expose the valid configuration space

`SessionCapabilities` SHALL surface everything a caller needs to choose a valid `(resolution, frame
rate)` and a legal exposure, derived from live device format data: for each supported resolution, the
supported frame-rate range(s) (including slow-mo where offered); the active frame rate; and the
exposure duration range constrained by the active frame rate (upper bound `min(sensorMax,
1/activeFrameRate)`).

#### Scenario: Supported frame rates are reported per resolution

- **WHEN** a caller reads `SessionCapabilities`
- **THEN** it can determine, for each supported resolution, the frame rates that resolution supports (e.g. 30 at 4032×3024, up to 60 at 1920×1440, up to 240 at a binned slow-mo resolution)

#### Scenario: Exposure range reflects the active frame rate

- **WHEN** the session is running at a given active frame rate
- **THEN** `SessionCapabilities` reports an exposure duration range whose upper bound is `min(sensorMax, 1/activeFrameRate)`

### Requirement: Flutter/Pigeon API exposes frame-rate selection and the capability space

The Flutter/Pigeon API SHALL expose frame-rate configuration and the capability space with parity to the
native CameraKit API. The Pigeon `OpenConfiguration` SHALL carry `targetFps`, and the Pigeon
`SessionCapabilities` SHALL carry the active frame rate, the per-resolution supported frame rate range(s)
(a value-typed list, since Pigeon has no Range type), and the fps-constrained exposure range. The Dart
API SHALL let a Flutter caller set `targetFps` at open and read those capability fields. An unsupported
`(resolution, targetFps)` pair or an exposure beyond the frame-rate ceiling SHALL surface across the
Pigeon boundary as the same typed error the native API raises.

#### Scenario: Flutter caller selects a frame rate

- **WHEN** a Flutter consumer opens with a `targetFps` supported by the chosen resolution
- **THEN** the session runs at that frame rate and the returned `SessionCapabilities` reports it as the active frame rate

#### Scenario: Flutter capabilities expose the valid config space

- **WHEN** a Flutter consumer reads the returned `SessionCapabilities`
- **THEN** it can determine, per supported resolution, the supported frame rate range(s) and the fps-constrained exposure range

#### Scenario: Flutter surfaces the validation error

- **WHEN** a Flutter consumer opens with an unsupported `(resolution, targetFps)` pair
- **THEN** open fails with the mapped typed error naming the valid frame rates, and the session is not started
