import CameraKit
import Flutter
import Foundation

// ─── Geometry ───────────────────────────────────────────────────────────────

extension PSize {
    func toCameraKit() -> Size { Size(width: Int(width), height: Int(height)) }
}

extension Size {
    func toPigeon() -> PSize { PSize(width: Int64(width), height: Int64(height)) }
}

extension PRect {
    func toCameraKit() -> Rect {
        Rect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }
}

extension Rect {
    func toPigeon() -> PRect {
        PRect(x: Int64(x), y: Int64(y), width: Int64(width), height: Int64(height))
    }
}

// ─── Settings ───────────────────────────────────────────────────────────────

extension CameraSettings {
    func toCameraKit() -> CameraKit.CameraSettings {
        var s = CameraKit.CameraSettings()
        s.isoMode = isoMode?.toCameraKit()
        s.iso = iso.map { Int($0) }
        s.exposureMode = exposureMode?.toCameraKit()
        s.exposureTimeNs = exposureTimeNs
        s.focusMode = focusMode?.toCameraKit()
        s.focusDistance = focusDistance
        s.wbMode = wbMode?.toCameraKit()
        s.wbGainR = wbGainR
        s.wbGainG = wbGainG
        s.wbGainB = wbGainB
        s.zoomRatio = zoomRatio
        s.evCompensation = evCompensation.map { Int($0) }
        return s
    }
}

extension CameraKit.CameraSettings {
    func toPigeon() -> CameraSettings {
        CameraSettings(
            isoMode: isoMode?.toPigeon(),
            iso: iso.map { Int64($0) },
            exposureMode: exposureMode?.toPigeon(),
            exposureTimeNs: exposureTimeNs,
            focusMode: focusMode?.toPigeon(),
            focusDistance: focusDistance,
            wbMode: wbMode?.toPigeon(),
            wbGainR: wbGainR,
            wbGainG: wbGainG,
            wbGainB: wbGainB,
            zoomRatio: zoomRatio,
            evCompensation: evCompensation.map { Int64($0) }
        )
    }
}

// CameraMode mirror: { auto, manual } only — see DSL note in
// pigeons/cambrian_ios_camera_api.dart.
extension CameraMode {
    func toCameraKit() -> CameraKit.CameraMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        }
    }
}

extension CameraKit.CameraMode {
    func toPigeon() -> CameraMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        }
    }
}

// WhiteBalanceMode mirror: { auto, locked, manual }.
extension WhiteBalanceMode {
    func toCameraKit() -> CameraKit.WhiteBalanceMode {
        switch self {
        case .auto: return .auto
        case .locked: return .locked
        case .manual: return .manual
        }
    }
}

extension CameraKit.WhiteBalanceMode {
    func toPigeon() -> WhiteBalanceMode {
        switch self {
        case .auto: return .auto
        case .locked: return .locked
        case .manual: return .manual
        }
    }
}

// ─── ProcessingParameters ───────────────────────────────────────────────────

extension ProcessingParameters {
    func toCameraKit() -> CameraKit.ProcessingParameters {
        var p = CameraKit.ProcessingParameters.identity
        p.brightness = brightness
        p.contrast = contrast
        p.saturation = saturation
        p.blackR = blackR
        p.blackG = blackG
        p.blackB = blackB
        p.gamma = gamma
        return p
    }
}

extension CameraKit.ProcessingParameters {
    func toPigeon() -> ProcessingParameters {
        ProcessingParameters(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            blackR: blackR,
            blackG: blackG,
            blackB: blackB,
            gamma: gamma
        )
    }
}

// ─── OpenConfiguration ──────────────────────────────────────────────────────

extension OpenConfiguration {
    func toCameraKit() -> CameraKit.OpenConfiguration {
        var c = CameraKit.OpenConfiguration()
        c.cameraId = cameraId
        c.captureResolution = captureResolution?.toCameraKit()
        c.cropRegion = cropRegion?.toCameraKit()
        c.initialSettings = initialSettings?.toCameraKit()
        return c
    }
}

// ─── SessionCapabilities ────────────────────────────────────────────────────

extension CameraKit.SessionCapabilities {
    func toPigeon() -> SessionCapabilities {
        SessionCapabilities(
            supportedSizes: supportedSizes.map { $0.toPigeon() as PSize? },
            previewTextureId: Int64(previewTextureId),
            naturalTextureId: Int64(naturalTextureId),
            activeCaptureResolution: activeCaptureResolution.toPigeon(),
            activeCropRegion: activeCropRegion.toPigeon(),
            streamPixelFormat: streamPixelFormat,
            isoMin: Double(isoRange.lowerBound),
            isoMax: Double(isoRange.upperBound),
            exposureDurationMinNs: exposureDurationRangeNs.lowerBound,
            exposureDurationMaxNs: exposureDurationRangeNs.upperBound,
            focusMin: focusRange.lowerBound,
            focusMax: focusRange.upperBound,
            zoomMin: zoomRange.lowerBound,
            zoomMax: zoomRange.upperBound,
            evMin: Double(evCompensationRange.lowerBound),
            evMax: Double(evCompensationRange.upperBound)
        )
    }
}

// ─── StreamConfiguration ────────────────────────────────────────────────────

extension CameraKit.StreamConfiguration {
    func toPigeon() -> StreamConfiguration {
        StreamConfiguration(
            activeCaptureResolution: activeCaptureResolution.toPigeon(),
            activeCropRegion: activeCropRegion.toPigeon()
        )
    }
}

// ─── FrameResult ────────────────────────────────────────────────────────────

extension CameraKit.FrameResult {
    func toPigeon() -> FrameResult {
        FrameResult(
            iso: iso.map { Int64($0) },
            exposureTimeNs: exposureTimeNs,
            focusDistance: focusDistance,
            wbGainR: wbGainR,
            wbGainG: wbGainG,
            wbGainB: wbGainB
        )
    }
}

// ─── Recording ──────────────────────────────────────────────────────────────

extension RecordingOptions {
    func toCameraKit() -> CameraKit.RecordingOptions {
        CameraKit.RecordingOptions(
            bitrateBps: bitrateBps.map { Int($0) },
            fps: fps.map { Int($0) },
            outputURL: outputPath.flatMap { URL(fileURLWithPath: $0) },
            photosDestination: photosDestination.toCameraKit()
        )
    }
}

extension CameraKit.RecordingStart {
    func toPigeon() -> RecordingStart {
        RecordingStart(uri: uri, displayName: displayName)
    }
}

extension PhotosDestination {
    func toCameraKit() -> CameraKit.PhotosDestination {
        switch self {
        case .none: return .none
        case .copy: return .copy
        case .move: return .move
        }
    }
}

extension CameraKit.RecordingState {
    func toPigeon() -> RecordingStateValue {
        switch self {
        case .idle(let lastUri):
            return RecordingStateValue(kind: .idle, lastUri: lastUri)
        case .recording:
            return RecordingStateValue(kind: .recording, lastUri: nil)
        case .finalizing:
            return RecordingStateValue(kind: .finalizing, lastUri: nil)
        }
    }
}

// ─── Calibration ────────────────────────────────────────────────────────────

extension CameraKit.RgbSample {
    func toPigeon() -> RgbSample { RgbSample(r: r, g: g, b: b) }
}

extension CameraKit.CalibrationResult {
    func toPigeon() -> CalibrationResult {
        CalibrationResult(
            before: before.toPigeon(),
            after: after.toPigeon(),
            converged: converged,
            iterations: Int64(iterations)
        )
    }
}

// ─── SessionState ───────────────────────────────────────────────────────────

extension CameraKit.SessionState {
    func toPigeon() -> SessionState {
        switch self {
        case .opening: return .opening
        case .streaming: return .streaming
        case .recovering: return .recovering
        case .paused: return .paused
        case .error: return .error
        case .closed: return .closed
        case .interrupted: return .interrupted
        }
    }
}

// ─── StreamId ───────────────────────────────────────────────────────────────

extension StreamId {
    func toCameraKit() -> CameraKit.StreamId {
        switch self {
        case .primary: return .primary
        case .tracker: return .tracker
        }
    }
}

// ─── Errors ─────────────────────────────────────────────────────────────────

extension CameraKit.CameraError {
    func toPigeon() -> CameraError {
        CameraError(code: code.toPigeon(), message: message, isFatal: isFatal)
    }
}

extension CameraKit.ErrorCode {
    func toPigeon() -> CameraErrorCode {
        switch self {
        case .cameraNotFound: return .cameraNotFound
        case .cameraInUse: return .cameraInUse
        case .permissionDenied: return .permissionDenied
        case .cameraAccessError: return .cameraAccessError
        case .cameraDisconnected: return .cameraDisconnected
        case .configurationFailed: return .configurationFailed
        case .captureFailure: return .captureFailure
        case .recordingStartFailed: return .recordingStartFailed
        case .recordingFailed: return .recordingFailed
        case .recordingTruncated: return .recordingTruncated
        case .frameStall: return .frameStall
        case .maxRetriesExceeded: return .maxRetriesExceeded
        case .unknownError: return .unknownError
        case .settingsConflict: return .settingsConflict
        case .invalidFormat: return .invalidFormat
        case .fpsDegraded: return .fpsDegraded
        case .aeConvergenceTimeout: return .aeConvergenceTimeout
        case .invalidState: return .invalidState
        case .hardwareError: return .hardwareError
        }
    }
}

// ─── Permissions ────────────────────────────────────────────────────────────

extension CameraKit.CameraPermissionStatus {
    func toPigeon() -> CameraPermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        }
    }
}

// ─── PigeonError helpers ───────────────────────────────────────────────────

/// Translates any `Error` thrown from CameraKit into a typed `PigeonError`.
///
/// `code` is the Dart-side `CameraErrorCode` enum case name (e.g.
/// `"cameraNotFound"`), produced by `String(describing:)` on the Pigeon enum.
/// The Dart facade catches `PlatformException`, parses `.code` via
/// `CameraErrorCode.values.byName(...)`, and rethrows as `CameraException`.
///
/// `details["isFatal"]` carries CameraKit's fatal-vs-recoverable distinction;
/// the Dart facade reads it into `CameraException.isFatal`.
extension Error {
    func asPigeonError() -> PigeonError {
        // CameraError — async hardware/session/encoding failures with explicit isFatal.
        if let camErr = self as? CameraKit.CameraError {
            let codeName = "\(camErr.code.toPigeon())"
            return PigeonError(
                code: codeName,
                message: camErr.message,
                details: ["isFatal": camErr.isFatal]
            )
        }

        // EngineError — synchronous command-boundary rejections. Map the cases the
        // Dart facade reasons about by name; everything else falls through to
        // unknownError with a stringified description so the message is still
        // diagnostic.
        if let engErr = self as? EngineError {
            let pigeonCode: CameraErrorCode
            let message: String
            let isFatal: Bool
            switch engErr {
            case .notOpen:
                pigeonCode = .notOpen
                message = "Engine is not open."
                isFatal = false
            case .alreadyOpen:
                pigeonCode = .invalidState
                message = "Engine is already open."
                isFatal = false
            case .cameraDenied:
                pigeonCode = .permissionDenied
                message = "Camera access was denied."
                isFatal = false
            case .noBackCamera:
                pigeonCode = .cameraNotFound
                message = "No back-facing camera available on this device."
                isFatal = true
            case .noSupportedFormat(let reason):
                pigeonCode = .invalidFormat
                message = "No supported format: \(reason)"
                isFatal = true
            case .settingsConflict(let reason):
                pigeonCode = .settingsConflict
                message = reason
                isFatal = false
            case .lockForConfigurationFailed:
                pigeonCode = .cameraAccessError
                message = "lockForConfiguration failed."
                isFatal = false
            case .sessionLifecycleTimeout:
                pigeonCode = .hardwareError
                message = "Session lifecycle operation timed out."
                isFatal = true
            case .invalidOutputPath(let url):
                pigeonCode = .invalidState
                message = "Output path outside app sandbox: \(url.path)"
                isFatal = false
            case .calibrationInProgress:
                pigeonCode = .invalidState
                message = "Calibration is already in flight."
                isFatal = false
            case .fatal(let cam):
                // Re-enter the CameraError branch — preserves its code/message/isFatal.
                return cam.asPigeonError()
            case .metal, .interop, .recording, .capture:
                pigeonCode = .unknownError
                message = String(describing: engErr)
                isFatal = false
            }
            return PigeonError(
                code: "\(pigeonCode)",
                message: message,
                details: ["isFatal": isFatal]
            )
        }

        // Anything else: stringify, classify as non-fatal unknownError.
        return PigeonError(
            code: "\(CameraErrorCode.unknownError)",
            message: String(describing: self),
            details: ["isFatal": false]
        )
    }
}
