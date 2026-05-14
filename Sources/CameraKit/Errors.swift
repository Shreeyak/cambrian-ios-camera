import Foundation

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
    /// See `PhotosLibraryClient.resolve` for the valid-locations list.
    case invalidOutputPath(URL)
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
}
