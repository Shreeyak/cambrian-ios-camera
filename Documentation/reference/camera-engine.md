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

### calibrationPatchSizePx

```swift
static var calibrationPatchSizePx: Int { get }
```

Side length (px) of the centered square patch that calibration samples from the primary frame. Black-point calibration reads back this centered patch and computes its statistics over it. Hosts draw their calibration reticle to this size — mapped through the preview's aspect-fit scale — so the on-screen rectangle marks **exactly** the sampled region, leaving no ambiguity about where pixels come from.

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

### calibrateBlack()

```swift
func calibrateBlack() async throws -> BlackPointDebug
```

Calibrates the linear black point from a dark-field readback (linear-normalization-stage). Reads back the centered sampled patch of the natural (pre-grade) lane — extracted on the GPU, so calibration never touches the full-frame CPU path — derives per-channel **linear** offsets (`mean + k·σ` over the near-black pixels), writes them into `ProcessingParameters.blackPoint{R,G,B}`, and enables the black point. The shader folds the offset into the normalization affine pre-grade. On failure the existing black point is left untouched. Same exclusive + abort-on-lifecycle contract as `calibrateWhite()`. Toggle the calibrated black point on/off without recalibrating via `enableBlackPoint()` / `disableBlackPoint()`; `clearBlackPoint()` discards it.

### calibrateWhite(whitePoint:)

```swift
func calibrateWhite(whitePoint: Bool = true) async throws -> CalibrationResult
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

### captureNaturalPictureBuffer()

```swift
func captureNaturalPictureBuffer() async throws -> PixelHandle
```

Captures the graded natural still as an in-memory buffer, skipping disk. still-capture-return-buffer: returns the graded still as an IOSurface-backed BGRA8 `CVPixelBuffer` in the processed-lane format — the same surface a downstream consumer treats like a `currentPixelBuffer(stream:)` frame — and does NOT encode, write a file, or publish to Photos. Same crop+grade as `captureNaturalPicture` (both share `renderNaturalStill`); same `notOpen` / `bufferUnavailable` guards. The buffer is delivered as a leased ``PixelHandle`` the caller owns and MUST release. The handle retains the underlying `CVPixelBuffer`, so its pooled IOSurface is not recycled until the handle is released (the `CVPixelBufferPool` only reclaims buffers with no external references). Hold at most a small number at once (typically one) to avoid pinning the still pool.

### clearBlackPoint()

```swift
func clearBlackPoint() async
```

Discards the black-point offsets and disables it (full reset). The demo app's "undo". Distinct from `disableBlackPoint()`, which keeps the offsets. Other processing parameters are untouched.

### clearWhiteBalance()

```swift
func clearWhiteBalance() async
```

Discards the white-balance + white-point coefficients (software only) and disables both. The inverse of `calibrateWhite()`'s normalization effect.

### close()

```swift
func close() async
```

Closes the camera session and releases all resources. Finishes consumer lane subscriptions cleanly (no throw). Recovery/restart uses `teardown(preserveConsumers:)` instead, which leaves them open.

### currentPixelBuffer(stream:)

```swift
nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer?
```

Returns the latest IOSurface-backed `CVPixelBuffer` for the requested lane, or `nil` if no frame has been delivered yet (or post-pause/close). **Format:** All three lanes return `kCVPixelFormatType_32BGRA` (BGRA8).

- `.primary`: Pass-7 RGBA16F→BGRA8 conversion.
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

Returns the last applied `ProcessingParameters`, or nil if none have been applied. Symmetric with `currentSettingsSnapshot()`. Used by `CalibrationViewModel` to refresh its mirror after engine-side calibration.

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

### currentTrackerTexture()

```swift
nonisolated func currentTrackerTexture() -> (any MTLTexture)?
```

Returns `.bgra8Unorm`. Pass-4's tracker downsample kernel writes `float4` via `texture2d<float, access::write>` into a BGRA8 pool texture — the hardware clamps [0,1] and stores 8-bit BGRA with no shader change. `nonisolated` so callers can access synchronously without an actor hop. Reads `latestTrackerTex` from the pipeline's `Mailbox<T>`. Returns nil if no frame has been encoded yet or the engine is closed.

### disableBlackPoint()

```swift
func disableBlackPoint() async
```

Disables the black point, keeping its offsets so `enableBlackPoint()` can restore them without recalibrating.

### disableWhiteBalance()

```swift
func disableWhiteBalance() async
```

Disables the white-balance chroma residual. Also disables the white point (it is meaningless without chroma — design D4). Coefficients are kept, so `enableWhiteBalance()` restores them without recalibrating. The hardware WB mode is untouched (use the WB-mode control to return the camera to auto).

### disableWhitePoint()

```swift
func disableWhitePoint() async
```

Disables the white-point level (back to phase contrast: chroma only).

### dumpDeviceFormats()

```swift
func dumpDeviceFormats() async -> [String]
```

Debug: dump every `AVCaptureDevice.Format` the active device exposes. Includes FourCC + dimensions + FPS ranges + bit-depth/range tag. Returns `[]` when no live device is bound (e.g., closed engine or fake provider in tests). Used by `ViewModel.dumpCapabilities` to snapshot the format table to `Documents/capabilities.txt`.

### enableBlackPoint()

```swift
func enableBlackPoint() async throws
```

Re-enables a previously-calibrated black point without recalibrating. Throws `EngineError.blackPointNotCalibrated` if the stored offsets are still identity (never calibrated, or cleared) — there is nothing to enable.

### enableWhiteBalance()

```swift
func enableWhiteBalance() async throws
```

Enables the white-balance chroma residual (neutralizes the cast). Throws `EngineError.whiteBalanceNotCalibrated` if no white field has been calibrated, or if white balance is in auto (a software residual can't sit on continuously-moving hardware gains — lock or `calibrateWhite()` first).

### enableWhitePoint()

```swift
func enableWhitePoint() async throws
```

Enables the white-point level (brightfield: lifts the neutralized white to the target). Throws `EngineError.whiteBalanceNotCalibrated` unless the chroma residual is active — white point is a child of white balance ("level without chroma" is not valid). Toggle freely after a `calibrateWhite()`; no resampling.

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

### getPersistedProcessingParameters()

```swift
nonisolated func getPersistedProcessingParameters() -> ProcessingParameters?
```

### lockedPixels(stream:)

```swift
nonisolated func lockedPixels(stream: StreamId) -> PixelHandle?
```

Returns a lease-holding ``FrameTransport/PixelHandle`` for the lane's latest buffer. The handle keeps the IOSurface read lock held for its lifetime, so a consumer may retain the pixels across a bounded pipeline hold. Returns nil when no buffer is available or the lock cannot be taken.

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

### setCenterCrop(width:height:offsetX:offsetY:)

```swift
func setCenterCrop(width: Int, height: Int, offsetX: Double = 0, offsetY: Double = 0) async throws
```

Sets a crop by output size plus an optional center displacement, computing the pixel ROI for the existing crop machinery (camera-crop-config D2). `offsetX`/`offsetY` are ratios of the active resolution's width/height (default `0`, centered) measured from the resolution center. The center is `evenNearest(resW/2 + offsetX*resW)` (and likewise for Y); `width`/`height` are snapped down to even, each capped at the resolution dimension; the origin is derived from the center, clamped fully in-bounds, and even-snapped. The derived rect is routed through `setCropRegion` (so it reuses the validation + rebuild + remembered-geometry path), which enables crop. Note the clamp is applied *after* the offset, so an offset on a crop sized to fill a dimension is a no-op in that axis (the only legal origin is the edge).

- Throws: `EngineError.notOpen` if the session is not open; `EngineError.calibrationInProgress` during calibration; `EngineError.settingsConflict` if the normalized rect is degenerate.

### setCropEnabled(_:)

```swift
func setCropEnabled(_ enabled: Bool) async throws
```

Enables or disables crop without re-specifying geometry (camera-crop-config D3). Disabling rebuilds at full capture resolution (full-frame output) while preserving `configuredCrop` so a later enable restores it.

- Throws: `EngineError.notOpen` if the session is not open; `EngineError.calibrationInProgress` during calibration; `EngineError.settingsConflict` if a remembered crop no longer fits the active resolution.

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

Wholesale replacement. **Pipeline order (`Shaders/ColorShaders.metal`):** 0. Normalization (linear light, pre-grade: black point / WB chroma / white point, fused affine) → 1. Brightness → 2. Contrast → 3. Saturation → 4. Gamma. The black point is part of the pre-grade normalization (linear light), derived statistically by `calibrateBlack()` from the raw natural lane.

### setResolution(size:)

```swift
func setResolution(size: Size) async throws
```

Session-only teardown + re-select format + restart for new resolution. The requested `size` is validated against the device's supported formats (camera-crop-config D1) before the reconfigure; the rebuilt pipeline is full-frame, so any active crop is dropped (re-apply via `setCropEnabled`/ `setCropRegion`).

- Throws: `EngineError.notOpen` if not yet open; `EngineError.settingsConflict` if `size` is not a supported format; `EngineError.calibrationInProgress` during calibration.

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

### calibrateBlack()

```swift
func calibrateBlack() async throws -> BlackPointDebug
```

### calibrateWhite(whitePoint:)

```swift
func calibrateWhite(whitePoint: Bool) async throws -> CalibrationResult
```

### captureImage(outputURL:photosDestination:)

```swift
func captureImage(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput
```

### captureNaturalPicture(outputURL:photosDestination:)

```swift
func captureNaturalPicture(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput
```

### clearBlackPoint()

```swift
func clearBlackPoint() async
```

### clearWhiteBalance()

```swift
func clearWhiteBalance() async
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

### disableBlackPoint()

```swift
func disableBlackPoint() async
```

### disableWhiteBalance()

```swift
func disableWhiteBalance() async
```

### disableWhitePoint()

```swift
func disableWhitePoint() async
```

### enableBlackPoint()

```swift
func enableBlackPoint() async throws
```

### enableWhiteBalance()

```swift
func enableWhiteBalance() async throws
```

### enableWhitePoint()

```swift
func enableWhitePoint() async throws
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

### setCenterCrop(width:height:offsetX:offsetY:)

```swift
func setCenterCrop(width: Int, height: Int, offsetX: Double, offsetY: Double) async throws
```

### setCropEnabled(_:)

```swift
func setCropEnabled(_ enabled: Bool) async throws
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
