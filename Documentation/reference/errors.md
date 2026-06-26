# Errors

## CameraError

*Struct*

```swift
struct CameraError
```

### init(code:message:isFatal:)

```swift
init(code: ErrorCode, message: String, isFatal: Bool)
```

### code

```swift
let code: ErrorCode
```

### isFatal

```swift
let isFatal: Bool
```

### message

```swift
let message: String
```

## ErrorCode

*Enum*

```swift
enum ErrorCode
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### ErrorCode.aeConvergenceTimeout

```swift
case aeConvergenceTimeout
```

### ErrorCode.cameraAccessError

```swift
case cameraAccessError
```

### ErrorCode.cameraDisconnected

```swift
case cameraDisconnected
```

### ErrorCode.cameraInUse

```swift
case cameraInUse
```

### ErrorCode.cameraNotFound

```swift
case cameraNotFound
```

### ErrorCode.captureFailure

```swift
case captureFailure
```

### ErrorCode.configurationFailed

```swift
case configurationFailed
```

### ErrorCode.fpsDegraded

```swift
case fpsDegraded
```

### ErrorCode.frameStall

```swift
case frameStall
```

### ErrorCode.hardwareError

```swift
case hardwareError
```

### ErrorCode.invalidFormat

```swift
case invalidFormat
```

### ErrorCode.invalidState

```swift
case invalidState
```

### ErrorCode.maxRetriesExceeded

```swift
case maxRetriesExceeded
```

### ErrorCode.permissionDenied

```swift
case permissionDenied
```

### ErrorCode.recordingFailed

```swift
case recordingFailed
```

### ErrorCode.recordingStartFailed

```swift
case recordingStartFailed
```

### ErrorCode.recordingTruncated

```swift
case recordingTruncated
```

### ErrorCode.settingsConflict

```swift
case settingsConflict
```

### ErrorCode.unknownError

```swift
case unknownError
```

## EngineError

*Enum*

```swift
enum EngineError
```

Wraps framework errors without losing root cause.

### EngineError.alreadyOpen

```swift
case alreadyOpen
```

### EngineError.blackPointCalibrationFailed(reason:)

```swift
case blackPointCalibrationFailed(reason: String)
```

A `calibrateBlackPoint()` call could not derive a valid black point — the sampled patch was not dark enough (too few near-black pixels). The `reason` is operator-facing (e.g. "point at a uniformly dark field").

### EngineError.calibrationInProgress

```swift
case calibrationInProgress
```

A `calibrate*()` call is in flight; conflicting mutating ops (`updateSettings(...)` touching white balance, `setResolution(...)`) must not race with it.

### EngineError.cameraDenied

```swift
case cameraDenied
```

### EngineError.capture(_:)

```swift
case capture(StillCaptureError)
```

### EngineError.fatal(_:)

```swift
case fatal(CameraError)
```

### EngineError.interop(_:)

```swift
case interop(InteropError)
```

### EngineError.invalidOutputPath(_:)

```swift
case invalidOutputPath(URL)
```

Caller passed an `outputURL` that resolves outside the app sandbox. iOS apps are kernel-sandboxed; only paths under `NSHomeDirectory()` are writable. See `OutputPathResolver` for the valid-locations list.

### EngineError.lockForConfigurationFailed

```swift
case lockForConfigurationFailed
```

### EngineError.metal(_:)

```swift
case metal(MetalError)
```

### EngineError.noBackCamera

```swift
case noBackCamera
```

### EngineError.noSupportedFormat(reason:)

```swift
case noSupportedFormat(reason: String)
```

### EngineError.notOpen

```swift
case notOpen
```

### EngineError.recording(_:)

```swift
case recording(RecordingError)
```

### EngineError.sessionLifecycleTimeout

```swift
case sessionLifecycleTimeout
```

### EngineError.settingsConflict(reason:)

```swift
case settingsConflict(reason: String)
```

## MetalError

*Enum*

```swift
enum MetalError
```

### MetalError.commandBufferFailed(code:)

```swift
case commandBufferFailed(code: Int)
```

### MetalError.noFrameAvailable

```swift
case noFrameAvailable
```

Calibration / sampling path required the latest natural texture but the mailbox is still empty (no frame delivered yet, or post-pause/close).

### MetalError.pipelineStateCompilation(_:)

```swift
case pipelineStateCompilation(String)
```

### MetalError.textureAllocationFailed

```swift
case textureAllocationFailed
```

### MetalError.textureCacheCreateFailed(code:)

```swift
case textureCacheCreateFailed(code: Int32)
```

### MetalError.textureWrapFailed(code:)

```swift
case textureWrapFailed(code: Int32)
```

### MetalError.unsupportedFormat

```swift
case unsupportedFormat
```

## RecordingError

*Enum*

```swift
enum RecordingError
```

### RecordingError.appendFailed(status:)

```swift
case appendFailed(status: Int)
```

### RecordingError.cancelledByPause

```swift
case cancelledByPause
```

### RecordingError.diskFull

```swift
case diskFull
```

### RecordingError.finalizeFailed(reason:)

```swift
case finalizeFailed(reason: String)
```

### RecordingError.finalizeTimeout

```swift
case finalizeTimeout
```

### RecordingError.finishTimeout

```swift
case finishTimeout
```

### RecordingError.missingFileExtension(_:)

```swift
case missingFileExtension(String)
```

The output filename carried no extension; the format cannot be inferred. Only `.mp4` is supported — pass a name ending in `.mp4`, or pass no name at all to get a timestamped default. Associated value is the offending filename.

### RecordingError.notReadyForMoreMediaData

```swift
case notReadyForMoreMediaData
```

### RecordingError.unsupportedVideoFormat(_:)

```swift
case unsupportedVideoFormat(String)
```

The output filename extension is not a supported video format. Only `.mp4` is supported. Associated value is the offending extension.

### RecordingError.writerStartFailed(status:)

```swift
case writerStartFailed(status: Int)
```

## StillCaptureError

*Enum*

```swift
enum StillCaptureError
```

Errors specific to still capture.

### StillCaptureError.alreadyInFlight

```swift
case alreadyInFlight
```

### StillCaptureError.bufferUnavailable

```swift
case bufferUnavailable
```

A still capture had no source buffer available. For `captureImage`, the processed-lane mailbox is `nil` (caller raced the first sample-buffer-delegate fire). For `captureNaturalPicture` (remove-natural-lane), the ISP one-shot path requires a running session — it is surfaced when capture is attempted while paused. Try again once frames are flowing. Distinct from `metalReadbackFailed`, which covers GPU-readback failures (vImage, CGImage build, IOSurface lock).

### StillCaptureError.fileWriteFailed(_:)

```swift
case fileWriteFailed(String)
```

### StillCaptureError.metalReadbackFailed

```swift
case metalReadbackFailed
```

### StillCaptureError.missingFileExtension(_:)

```swift
case missingFileExtension(String)
```

The output filename carried no extension; the image format cannot be inferred. Supply one of: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff` — or pass no name at all to get a timestamped `.png` default. Associated value is the offending filename.

### StillCaptureError.unsupportedImageFormat(_:)

```swift
case unsupportedImageFormat(String)
```

The output filename extension is not a supported still-image format. Supported: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff`. Associated value is the offending extension.
