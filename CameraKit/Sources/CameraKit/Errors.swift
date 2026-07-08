import Foundation

// MARK: - Error routing contract
//
// CameraKit has two parallel error surfaces. Route by phase:
//
// 1. Synchronous rejections at the command boundary — caller precondition
//    violations, invalid arguments, .alreadyOpen / .notOpen, alreadyInFlight,
//    invalidOutputPath — surface as typed `EngineError` throws on the
//    suspension point. Caller code handles via `try` / `catch`.
//
// 2. Asynchronous hardware / session / encoding failures — capture device
//    errors, AVCaptureSession runtime errors, AVAssetWriter failures,
//    watchdog firings, max-retries-exceeded — surface as `CameraError` on
//    `errorStream()`. UI subscribes to the stream and routes by `isFatal`.
//
// `EngineError.fatal(CameraError)` bridges (1) → (2) when a synchronous
// path discovers an async-origin fatal condition that already exists as a
// `CameraError` value.
//
// Rationale: synchronous APIs cannot block on future hardware state; async
// failures cannot be observed by a caller that has already returned. The
// surfaces are not interchangeable. Each throw / emit site picks one
// according to its phase, not its severity.

/// Domain-public error-code taxonomy per domain-revised/10-api-contract.md §ErrorCode.
public enum ErrorCode: String, Sendable, Hashable {
    case cameraNotFound = "CAMERA_NOT_FOUND"
    case cameraInUse = "CAMERA_IN_USE"
    case permissionDenied = "PERMISSION_DENIED"
    case cameraAccessError = "CAMERA_ACCESS_ERROR"
    case cameraDisconnected = "CAMERA_DISCONNECTED"
    case configurationFailed = "CONFIGURATION_FAILED"
    case captureFailure = "CAPTURE_FAILURE"
    case recordingStartFailed = "RECORDING_START_FAILED"
    case recordingFailed = "RECORDING_FAILED"
    case recordingTruncated = "RECORDING_TRUNCATED"
    case frameStall = "FRAME_STALL"
    case maxRetriesExceeded = "MAX_RETRIES_EXCEEDED"
    case unknownError = "UNKNOWN_ERROR"
    case settingsConflict = "SETTINGS_CONFLICT"
    case invalidFormat = "INVALID_FORMAT"
    case fpsDegraded = "FPS_DEGRADED"
    case aeConvergenceTimeout = "AE_CONVERGENCE_TIMEOUT"
    case invalidState = "INVALID_STATE"
    case hardwareError = "HARDWARE_ERROR"
}

/// onError payload per domain-revised/10-api-contract.md §Error.
public struct CameraError: Sendable, Error, Hashable {
    public let code: ErrorCode
    public let message: String
    public let isFatal: Bool

    public init(code: ErrorCode, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Typed throws per ADR-25.
///
/// Wraps framework errors without losing root cause.
public enum EngineError: Error, Sendable {
    case alreadyOpen
    case notOpen
    case cameraDenied
    case noBackCamera
    case noSupportedFormat(reason: String)
    case lockForConfigurationFailed
    case settingsConflict(reason: String)
    case sessionLifecycleTimeout
    case metal(MetalError)
    case interop(InteropError)
    case recording(RecordingError)
    case capture(StillCaptureError)
    case fatal(CameraError)
    /// Caller passed an `outputURL` that resolves outside the app sandbox.
    ///
    /// iOS apps are kernel-sandboxed; only paths under `NSHomeDirectory()` are writable.
    ///
    /// See `OutputPathResolver` for the valid-locations list.
    case invalidOutputPath(URL)
    /// A `calibrate*()` call is in flight; conflicting mutating ops
    /// (`updateSettings(...)` touching white balance, `setResolution(...)`)
    /// must not race with it. Phase-2 design §2b concurrency contract.
    case calibrationInProgress
    /// A `calibrateBlack()` call could not derive a valid black point — the
    /// sampled patch was not dark enough (too few near-black pixels). The
    /// `reason` is operator-facing (e.g. "point at a uniformly dark field").
    case blackPointCalibrationFailed(reason: String)
    /// A `calibrateWhite()` call could not derive a valid white reference — the
    /// sampled patch was not bright enough to be a white field. The `reason` is
    /// operator-facing (e.g. "point at a bright, evenly-lit white field").
    case whiteBalanceCalibrationFailed(reason: String)
    /// `enableWhiteBalance()` / `enableWhitePoint()` was called before a white
    /// reference was calibrated (or while white balance is in auto, where a
    /// software residual can't sit on moving hardware gains). Run
    /// `calibrateWhite()` first.
    case whiteBalanceNotCalibrated
    /// `enableBlackPoint()` was called before a dark field was calibrated (the
    /// stored offsets are still identity). Run `calibrateBlack()` first.
    case blackPointNotCalibrated
}

// MARK: - LocalizedError (Task #1 — full sweep)
//
// Every CameraKit error type provides an operator-facing `errorDescription` so
// `error.localizedDescription`, the demo's error banner, and the Flutter
// `asPigeonError()` message read like instructions, not enum-case names. Wrapping
// `EngineError` cases delegate to the wrapped error's description. Switches are
// exhaustive (no `default`) so a new case forces an intentional description.

extension CameraError: LocalizedError {
    public var errorDescription: String? { message }
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            return "The camera is already open."
        case .notOpen:
            return "The camera isn't open — call open() first."
        case .cameraDenied:
            return "Camera access was denied. Enable camera access for this app in Settings."
        case .noBackCamera:
            return "No back camera is available on this device."
        case .noSupportedFormat(let reason):
            return "No supported camera format: \(reason)"
        case .lockForConfigurationFailed:
            return "Couldn't lock the camera for configuration — it may be in use by another app."
        case .settingsConflict(let reason):
            return reason
        case .sessionLifecycleTimeout:
            return "The camera didn't start delivering frames in time."
        case .metal(let e):
            return e.errorDescription
        case .interop(let e):
            return e.errorDescription
        case .recording(let e):
            return e.errorDescription
        case .capture(let e):
            return e.errorDescription
        case .fatal(let cam):
            return cam.errorDescription
        case .invalidOutputPath(let url):
            return "The output path is outside the app's sandbox and can't be written: \(url.path)"
        case .calibrationInProgress:
            return "A calibration is in progress — try again once it finishes."
        case .blackPointCalibrationFailed(let reason),
            .whiteBalanceCalibrationFailed(let reason):
            return reason
        case .whiteBalanceNotCalibrated:
            return
                "White balance isn't calibrated. Point at a white field and run "
                + "white-balance calibration before enabling white balance or white point."
        case .blackPointNotCalibrated:
            return
                "Black point isn't calibrated. Point at a dark field and run "
                + "black-point calibration before enabling the black point."
        }
    }
}

extension MetalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandBufferFailed(let code):
            return "The GPU command buffer failed (code \(code))."
        case .textureCacheCreateFailed(let code):
            return "Couldn't create the Metal texture cache (code \(code))."
        case .textureWrapFailed(let code):
            return "Couldn't wrap the pixel buffer as a Metal texture (code \(code))."
        case .textureAllocationFailed:
            return "Couldn't allocate a Metal texture."
        case .pipelineStateCompilation(let detail):
            return "Metal pipeline compilation failed: \(detail)"
        case .unsupportedFormat:
            return "The pixel format isn't supported by the Metal pipeline."
        case .noFrameAvailable:
            return "No camera frame is available yet — try again once frames are flowing."
        }
    }
}

extension InteropError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pixelSinkRegistrationRejected(let code):
            return "Pixel-sink registration was rejected (code \(code))."
        case .pipelineHandleUnavailable:
            return "The native pipeline handle is unavailable (the session isn't open)."
        case .invalidCallbacks:
            return "A required frame callback was missing at registration."
        case .missingOnOverwrite:
            return "The overwrite callback was missing at registration (drops can't be surfaced)."
        case .retainMismatch:
            return "A retain/release mismatch was detected on unregister."
        }
    }
}

extension RecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .writerStartFailed(let status):
            return "Recording couldn't start (writer status \(status))."
        case .appendFailed(let status):
            return "Recording failed while writing frames (append status \(status))."
        case .finishTimeout:
            return "Recording timed out while stopping."
        case .diskFull:
            return "Recording stopped because the disk is full."
        case .notReadyForMoreMediaData:
            return "The recorder wasn't ready for more media data."
        case .finalizeTimeout:
            return "Recording timed out while finalizing the file."
        case .finalizeFailed(let reason):
            return "Recording couldn't finalize the file: \(reason)"
        case .cancelledByPause:
            return "Recording was cancelled because the app was backgrounded."
        case .missingFileExtension(let name):
            return "The recording filename \"\(name)\" has no extension — use a name ending in .mp4."
        case .unsupportedVideoFormat(let ext):
            return "\"\(ext)\" isn't a supported video format — only .mp4 is supported."
        }
    }
}

extension StillCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyInFlight:
            return "A still capture is already in progress."
        case .metalReadbackFailed:
            return "Couldn't read the captured image back from the GPU."
        case .fileWriteFailed(let path):
            return "Couldn't write the image to \(path)."
        case .bufferUnavailable:
            return
                "No image is available yet — try again once frames are flowing (a "
                + "natural picture needs a running session)."
        case .missingFileExtension(let name):
            return "The image filename \"\(name)\" has no extension — use .png, .jpg, or .tif."
        case .unsupportedImageFormat(let ext):
            return "\"\(ext)\" isn't a supported image format — use .png, .jpg, or .tif."
        }
    }
}

public enum MetalError: Error, Sendable, Equatable {
    case commandBufferFailed(code: Int)
    case textureCacheCreateFailed(code: Int32)
    case textureWrapFailed(code: Int32)
    case textureAllocationFailed
    case pipelineStateCompilation(String)
    case unsupportedFormat
    /// Calibration / sampling path required the latest natural texture but the
    /// mailbox is still empty (no frame delivered yet, or post-pause/close).
    case noFrameAvailable
}

public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    /// on_frame was nil on registerCallback (D-03 quality gate).
    case invalidCallbacks
    /// on_overwrite was nil on registerCallback — the G-26-avoidance quality
    /// gate (D-11): a sink that cannot surface mailbox-overwrite drops is
    /// rejected at registration, never silently degraded at runtime.
    case missingOnOverwrite
    /// Unmanaged retain/release mismatch detected on unregister.
    case retainMismatch
}

public enum RecordingError: Error, Sendable {
    case writerStartFailed(status: Int)
    case appendFailed(status: Int)
    case finishTimeout
    case diskFull
    case notReadyForMoreMediaData
    case finalizeTimeout
    case finalizeFailed(reason: String)
    case cancelledByPause
    /// The output filename carried no extension; the format cannot be inferred.
    ///
    /// Only `.mp4` is supported — pass a name ending in `.mp4`, or pass no name
    /// at all to get a timestamped default. Associated value is the offending
    /// filename.
    case missingFileExtension(String)
    /// The output filename extension is not a supported video format.
    ///
    /// Only `.mp4` is supported. Associated value is the offending extension.
    case unsupportedVideoFormat(String)
}

// MARK: - Still capture types (compressed here per Stage 01 type-compression decision)

/// Output of a successful captureImage() call.
///
/// Full implementation Stage 06.
public struct StillCaptureOutput: Sendable, Hashable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}

/// Errors specific to still capture.
///
/// Full implementation Stage 06.
public enum StillCaptureError: Error, Sendable {
    case alreadyInFlight
    case metalReadbackFailed
    case fileWriteFailed(String)
    /// A still capture had no source buffer available.
    ///
    /// For `captureImage`, the processed-lane mailbox is `nil` (caller raced the
    /// first sample-buffer-delegate fire). For `captureNaturalPicture`
    /// (remove-natural-lane), the ISP one-shot path requires a running session —
    /// it is surfaced when capture is attempted while paused. Try again once
    /// frames are flowing. Distinct from `metalReadbackFailed`, which covers
    /// GPU-readback failures (vImage, CGImage build, IOSurface lock).
    case bufferUnavailable
    /// The output filename carried no extension; the image format cannot be
    /// inferred.
    ///
    /// Supply one of: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff` — or pass no name
    /// at all to get a timestamped `.png` default. Associated value is the
    /// offending filename.
    case missingFileExtension(String)
    /// The output filename extension is not a supported still-image format.
    ///
    /// Supported: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff`. Associated value is
    /// the offending extension.
    case unsupportedImageFormat(String)
}
