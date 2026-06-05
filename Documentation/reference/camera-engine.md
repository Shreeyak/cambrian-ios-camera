# Camera Engine

## CameraEngine

*Actor*

```swift
actor CameraEngine
```

### init(initialPhase:clock:)

```swift
init(initialPhase: AppLifecyclePhase, clock: any CameraKitClock = SystemClock())
```

### consumers

```swift
nonisolated let consumers: ConsumerRegistry
```

Lifetime matches the engine; every `open()` passes this same instance to the `MetalPipeline` so publication (nonisolated `yield` on the delivery queue) and subscription (actor-isolated `subscribe` from Swift callers) share state.

### cameraPermissionStatus()

```swift
nonisolated static func cameraPermissionStatus() -> CameraPermissionStatus
```

Camera authorization status (`.video`). `nonisolated static` so the Flutter side can query before instantiating an engine handle (handle creation requires authorization).

### photosAddPermissionStatus()

```swift
nonisolated static func photosAddPermissionStatus() -> CameraPermissionStatus
```

Photos library add-only authorization status.

### requestCameraPermission()

```swift
nonisolated static func requestCameraPermission() async -> CameraPermissionStatus
```

Triggers the system camera-permission prompt. Returns immediately if already prompted. Returns the status after the prompt resolves.

### requestPhotosAddPermission()

```swift
nonisolated static func requestPhotosAddPermission() async -> CameraPermissionStatus
```

Triggers the system Photos add-only prompt.

### calibrateBlackBalance()

```swift
func calibrateBlackBalance() async throws -> CalibrationResult
```

Single-shot BB calibration. Samples the center patch through the current BCSG with BB temporarily zeroed, computes per-channel pedestal via `CalibrationCompute.blackBalanceOffsets`, writes into `ProcessingParameters.blackR/G/B` via `setProcessingParams`. Same exclusive + abort-on-lifecycle contract as `calibrateWhiteBalance()`.

### calibrateWhiteBalance()

```swift
func calibrateWhiteBalance() async throws -> CalibrationResult
```

Single-shot WB calibration. Switches WB to continuous auto so AVF's hardware statistics engine recomputes against the current scene, awaits convergence, reads the device's gray-world gains, clamps to `[1.0, maxGain]`, locks the device to those gains. Future iterative-loop port: see `docs/superpowers/plans/2026-05-15-wb-calibration-dart-port.md`. Concurrency contract:

- **Exclusive**: a second `calibrate*()` while one is in flight throws `EngineError.calibrationInProgress`.
- **Conflict guard**: `updateSettings(...)` touching white balance and `setResolution(...)` throw `.calibrationInProgress` while live.
- **Abort on lifecycle**: `close()` and the `.interrupted` SessionState transition cancel the in-flight task. The task's catch path returns WB to `.auto` before propagating `CancellationError`.

### captureImage(outputURL:photosDestination:)

```swift
func captureImage(outputURL: URL? = nil, photosDestination: PhotosDestination = .none) async throws -> StillCaptureOutput
```

If `photosDestination` is `.copy` or `.move`, the file is also published to Photos before this method returns; failures emit on `errorStream()` and the file at `output.filePath` is always preserved (even when `.move` was requested and failed). See `PhotosLibraryClient` for the full contract and known error codes.

- Parameters:
- outputURL: Resolved per `OutputPathResolver.image`. `nil` → `<Documents>/<timestamp>.png` (PNG). A name's extension picks the format: `.png` / `.jpg`/`.jpeg` / `.tif`/`.tiff`. A name with no extension, or an unsupported one, throws.
- photosDestination: See `PhotosDestination`. Independent of `outputURL`; defaults to `.none` (no Photos interaction).
- Returns: A `StillCaptureOutput` with the on-disk file path. With `.move` and a successful Photos publish, that file no longer exists.
- Throws: `EngineError.notOpen` if the engine is not open or not running.
- Throws: `EngineError.invalidOutputPath(_:)` if `outputURL` resolves outside the app sandbox.
- Throws: `EngineError.capture(_:)` wrapping any `StillCaptureError` — including `.missingFileExtension` / `.unsupportedImageFormat`.

### captureNaturalPicture(outputURL:photosDestination:)

```swift
func captureNaturalPicture(outputURL: URL? = nil, photosDestination: PhotosDestination = .none) async throws -> StillCaptureOutput
```

ISP one-shot via `AVCapturePhotoOutput` → live Metal crop+grade → still cropped to the active region. Same device and grade settings as `captureImage`, differing only by source: this method fires an ISP one-shot rather than reading the latest processed-lane buffer. The graded output is encoded at `outputSize` in the format chosen by `outputURL`'s extension (see `OutputPathResolver.image`). EXIF carries `"lane": "natural"` inside the `CamPlugin/v1` envelope so consumers can distinguish natural-lane stills from processed-lane stills written by `captureImage` (`"lane": "processed"`). Errors cleanly when the session is not running (no last-frame fallback on pause — reverses D-2P-10).

- Parameters:
- outputURL: Resolved per `OutputPathResolver.image`. `nil` → `<Documents>/<timestamp>.png` (PNG). A name's extension picks the format: `.png` / `.jpg`/`.jpeg` / `.tif`/`.tiff`. A name with no extension, or an unsupported one, throws.
- photosDestination: See `PhotosDestination`. Independent of `outputURL`; defaults to `.none` (no Photos interaction).
- Returns: A `StillCaptureOutput` with the on-disk file path. With `.move` and a successful Photos publish, that file no longer exists.
- Throws: `EngineError.notOpen` if the engine is not open.
- Throws: `EngineError.capture(.bufferUnavailable)` if the session is not running (paused or not yet started).
- Throws: `EngineError.invalidOutputPath(_:)` if `outputURL` resolves outside the app sandbox.
- Throws: `EngineError.capture(_:)` wrapping any other `StillCaptureError`.

### close()

```swift
func close() async
```

Closes the camera session and releases all resources.

### currentPixelBuffer(stream:)

```swift
nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer?
```

Returns the latest IOSurface-backed `CVPixelBuffer` for the requested lane, or `nil` if no frame has been delivered yet (or post-pause/close). **Format:** All three lanes return `kCVPixelFormatType_32BGRA` (BGRA8).

- `.natural` / `.processed`: Pass-7 RGBA16F→BGRA8 conversion.
- `.tracker`: fused — `trackerPool` is BGRA8; Pass-4 writes BGRA8 directly.

### currentProcessedTexture()

```swift
nonisolated func currentProcessedTexture() -> (any MTLTexture)?
```

Exposes the live processed-lane texture for the right-half MTKView draw. `.bgra8Unorm` — see `currentTexture()`. Same live-mailbox contract; re-evaluate per draw.

### currentProcessingParametersSnapshot()

```swift
func currentProcessingParametersSnapshot() -> ProcessingParameters?
```

Returns the last applied `ProcessingParameters`, or nil if none have been applied. Symmetric with `currentSettingsSnapshot()`. Used by `CalibrationViewModel` to refresh its mirror after engine-side `calibrateBlackBalance()`.

### currentSettingsSnapshot()

```swift
func currentSettingsSnapshot() -> CameraSettings?
```

Returns the last successfully committed settings, or nil if none have been applied.

### currentStateSnapshot()

```swift
func currentStateSnapshot() -> SessionState
```

Returns the engine's actual current `SessionState` (the state machine's live value). A fresh point-in-time read — NOT a replay of a past event. Lets a late observer (e.g. a Flutter preview widget that subscribes after `open()` already published `.streaming`) learn the true current state instead of waiting for the next transition. `.closed` before `open()`.

### currentTexture()

```swift
nonisolated func currentTexture() -> (any MTLTexture)?
```

Exposes the live natural-lane texture for the MTKView draw pass. `.bgra8Unorm` — the same IOSurface delivered by `currentPixelBuffer(stream:.natural)`, exposed as an `MTLTexture` for the preview. One 8-bit surface per lane; the camera is 8-bit-locked, so there is no precision to preserve at the delivery boundary (RGBA16F survives only as an internal compute intermediate for the Metal math / calibration sampling). Forwards to `MetalPipeline.latestNaturalBgra8Tex` (single writer: delivery queue). MUST be re-evaluated each draw; do not cache (Bug 4: pool rotation strands cached pointers).

### currentTrackerTexture()

```swift
nonisolated func currentTrackerTexture() -> (any MTLTexture)?
```

Returns `.bgra8Unorm`. Pass-4's tracker downsample kernel writes `float4` via `texture2d<float, access::write>` into a BGRA8 pool texture — the hardware clamps [0,1] and stores 8-bit BGRA with no shader change. `nonisolated` so callers can access synchronously without an actor hop. Reads `latestTrackerTex` from the pipeline's `Mailbox<T>`. Returns nil if no frame has been encoded yet or the engine is closed.

### dumpDeviceFormats()

```swift
func dumpDeviceFormats() async -> [String]
```

Debug: dump every `AVCaptureDevice.Format` the active device exposes. Includes FourCC + dimensions + FPS ranges + bit-depth/range tag. Returns `[]` when no live device is bound (e.g., closed engine or fake provider in tests). Used by `ViewModel.dumpCapabilities` to snapshot the format table to `Documents/capabilities.txt`.

### errorStream()

```swift
func errorStream() -> AsyncStream<CameraError>
```

Stream of error notifications (non-fatal + fatal). Subscribe once per consumer lifetime; same instance returned thereafter.

### frameResultStream()

```swift
func frameResultStream() -> AsyncStream<FrameResult>
```

Sensor-metadata heartbeat at `frameRateTargetFPS / frameResultHeartbeatIntervalFrames` Hz.

### getNativePipelineHandle()

```swift
func getNativePipelineHandle() -> UInt64?
```

Returns the raw C++ PixelSinkPool pointer as UInt64 while holding the engine actor. Returns nil when the engine is not open.

### getPersistedProcessingParameters()

```swift
nonisolated func getPersistedProcessingParameters() -> ProcessingParameters?
```

### open(configuration:)

```swift
func open(configuration: OpenConfiguration = OpenConfiguration()) async throws -> SessionCapabilities
```

Opens the camera session and returns capabilities.

- Throws: `EngineError.alreadyOpen` if already open.
- Throws: `EngineError.cameraDenied` if permission not granted.
- Throws: `EngineError.noBackCamera` if no back camera found.
- Throws: `EngineError.metal(_:)` if MetalPipeline fails to initialise.

### recordingStateStream()

```swift
func recordingStateStream() -> AsyncStream<RecordingState>
```

Returns a stream of `RecordingState` transitions. Cached — multiple callers receive the same stream.

### sampleCenterPatch()

```swift
func sampleCenterPatch() async throws -> RgbSample
```

Samples processedTex's CENTER_PATCH_SIZE_PX x CENTER_PATCH_SIZE_PX center, awaits completion, sorts each channel and returns the trimmed mean per CENTER_PATCH_TRIM_PERCENT.

- Throws: `EngineError.notOpen` if the session is not open.
- Throws: `EngineError.metal(_:)` on Metal failures.

### setCropRegion(_:)

```swift
func setCropRegion(_ rect: Rect) async throws
```

P2a: applies a TRUE crop — the natural/processed output resolution becomes the crop-region size. The AVCaptureSession keeps producing full capture-resolution buffers; Pass-1 reads the `rect`-offset sub-region at 1:1 into `rect.width × rect.height` output textures (no zoom, no masking). Implemented by recreating the `MetalPipeline` with the new `outputSize`/`cropOrigin` — the capture resolution is unchanged, so (unlike `setResolution`) the AVF session is NOT reconfigured.

- Throws: `EngineError.notOpen` if the session is not open.
- Throws: `EngineError.calibrationInProgress` if a calibration is in flight (the rebuild would invalidate its pipeline reference).
- Throws: `EngineError.settingsConflict` if the rect is degenerate, out of capture-resolution bounds, or has odd coordinates (4:2:0 chroma).

### setLifecyclePhase(_:)

```swift
func setLifecyclePhase(_ phase: AppLifecyclePhase) async
```

Update the host's current lifecycle phase. Never throws; safe on every transition and before `open()`. Writes `currentPhase` unconditionally and reconciles hardware (gate, session, watchdogs, label) only when the engine is open — before `open()` the phase is recorded, and `open()` applies it by running the same routine against `currentPhase`. Concurrency: the **latest call wins** — a superseded, still-in-flight reconciliation is abandoned rather than allowed to apply stale work, so rapid bounces (lock/unlock, app-switch) are safe. Calling convention:

- **SwiftUI:** observe `@Environment(\.scenePhase)` and forward the matching case — `.active` / `.inactive` / `.background` map 1:1.
- **Flutter (cam2fd):** the plugin's *native* Swift layer implements `FlutterSceneLifeCycleDelegate` (registered via `addSceneDelegate`) and maps the UIScene callbacks to this call — `sceneDidBecomeActive →.active`, `sceneWillResignActive →.inactive`, `sceneDidEnterBackground →.background`. Do **not** forward lifecycle from Dart over the method channel: observe natively so a backgrounding can't outrun an in-flight recording's finalize and corrupt the `.mp4`.

### setProcessingParams(_:)

```swift
func setProcessingParams(_ params: ProcessingParameters) async
```

Wholesale replacement. **Pipeline order (`Shaders/ColorShaders.metal`):** 1. Brightness → 2. Contrast → 3. Saturation → 4. Gamma → 5. Black balance. Black balance is the **last** step — pedestal is subtracted from the graded output, behaving like a final shadow lift rather than a pre-grade noise-floor compensation. Calibration sampling for BB must therefore read from a render where BCSG is applied and BB is zeroed (see `MetalPipeline.dispatchBBCalibrationSample`) so each calibrate isn't biased by the previously-applied pedestal.

### setResolution(size:)

```swift
func setResolution(size: Size) async throws
```

Session-only teardown + re-select format + restart for new resolution.

- Throws: `EngineError.notOpen` if not yet open.

### startRecording(options:)

```swift
func startRecording(options: RecordingOptions) async throws -> RecordingStart
```

Starts a recording session using the current capture pipeline.

- Throws: `EngineError.notOpen` if the engine has not been opened.

### stateStream()

```swift
func stateStream() -> AsyncStream<SessionState>
```

Returns an AsyncStream of SessionState events. The stream is cached — multiple callers receive the same stream instance.

### stopRecording()

```swift
func stopRecording() async throws -> String
```

Stops the active recording session and returns the output file URI. If `RecordingOptions.photosDestination` was `.copy` or `.move`, the resulting `.mp4` is also published to the Photos library before this method returns. The Photos round-trip adds a few hundred ms to wall time. Failures are non-fatal: the file at `uri` is always preserved (even when `.move` was requested), and a non-fatal `CameraError` is emitted on `errorStream()`. See `PhotosLibraryClient` for the full contract and known error codes.

- Returns: The on-disk URI of the recorded file. With `.move` and a successful Photos publish, the file at this URI no longer exists — Photos owns the bytes.
- Throws: `EngineError.notOpen` if no recording is active or the engine is not open.

### streamConfigurationStream()

```swift
func streamConfigurationStream() -> AsyncStream<StreamConfiguration>
```

Active stream configuration changes — fires when `setResolution(...)` resolves to a new size or `setCropRegion(...)` mutates the active crop. Cached stream — multiple callers receive the same instance. `.bufferingOldest` so every config change is delivered.

### updateSettings(_:)

```swift
func updateSettings(_ settings: CameraSettings) async throws
```

Full settings merge→couple→validate→commit→persist pipeline.

- Merges onto prior state
- Applies coupling rules (Rules 1/2/3 from 07-settings.md)
- Validates ranges against device capabilities
- Commits to device via sessionQueue
- Persists asynchronously (detached Task)
- Throws: `EngineError.notOpen` if engine not open
- Throws: `EngineError.settingsConflict` if range validation fails or Rule 3 pre-readback
- Throws: `EngineError.calibrationInProgress` if a `calibrate*()` is in flight and `settings` touches white balance.

## CameraEngineProtocol

*Protocol*

```swift
protocol CameraEngineProtocol : Actor
```

Public surface of `CameraEngine` that the Flutter iOS adapter consumes. Mirrors every public method the adapter calls. `CameraEngine` (an `actor`) conforms automatically via member parity — see the `extension CameraEngine: CameraEngineProtocol {}` at the bottom of this file. Adapter unit tests (`flutter/example/ios/RunnerTests/`) mock against this protocol so the adapter can be tested without standing up a real capture session. Not for general public consumption — most call sites should hold a concrete `CameraEngine`. The protocol exists for testability.

### consumers

```swift
nonisolated var consumers: ConsumerRegistry { get }
```

### calibrateBlackBalance()

```swift
func calibrateBlackBalance() async throws -> CalibrationResult
```

### calibrateWhiteBalance()

```swift
func calibrateWhiteBalance() async throws -> CalibrationResult
```

### captureImage(outputURL:photosDestination:)

```swift
func captureImage(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput
```

### captureNaturalPicture(outputURL:photosDestination:)

```swift
func captureNaturalPicture(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput
```

### close()

```swift
func close() async
```

### currentPixelBuffer(stream:)

```swift
nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer?
```

### currentProcessingParametersSnapshot()

```swift
func currentProcessingParametersSnapshot() -> ProcessingParameters?
```

### currentSettingsSnapshot()

```swift
func currentSettingsSnapshot() -> CameraSettings?
```

### currentStateSnapshot()

```swift
func currentStateSnapshot() -> SessionState
```

### errorStream()

```swift
func errorStream() -> AsyncStream<CameraError>
```

### frameResultStream()

```swift
func frameResultStream() -> AsyncStream<FrameResult>
```

### open(configuration:)

```swift
func open(configuration: OpenConfiguration) async throws -> SessionCapabilities
```

### recordingStateStream()

```swift
func recordingStateStream() -> AsyncStream<RecordingState>
```

### setCropRegion(_:)

```swift
func setCropRegion(_ rect: Rect) async throws
```

### setLifecyclePhase(_:)

```swift
func setLifecyclePhase(_ phase: AppLifecyclePhase) async
```

### setProcessingParams(_:)

```swift
func setProcessingParams(_ params: ProcessingParameters) async
```

### setResolution(size:)

```swift
func setResolution(size: Size) async throws
```

### startRecording(options:)

```swift
func startRecording(options: RecordingOptions) async throws -> RecordingStart
```

### stateStream()

```swift
func stateStream() -> AsyncStream<SessionState>
```

### stopRecording()

```swift
func stopRecording() async throws -> String
```

### streamConfigurationStream()

```swift
func streamConfigurationStream() -> AsyncStream<StreamConfiguration>
```

### updateSettings(_:)

```swift
func updateSettings(_ settings: CameraSettings) async throws
```
