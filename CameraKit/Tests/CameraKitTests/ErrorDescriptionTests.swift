import Foundation
import Testing

@testable import CameraKit

/// Task #1: every CameraKit error type provides an operator-facing, non-empty
/// `errorDescription` (so `error.localizedDescription`, the demo banner, and the
/// Flutter `asPigeonError()` message read like instructions, not case names).
@Suite("ErrorDescriptionTests")
struct ErrorDescriptionTests {

    private func assertDescribed(_ e: any LocalizedError, _ label: String) {
        let d = e.errorDescription
        #expect(d != nil, "\(label): errorDescription is nil")
        #expect(!(d ?? "").isEmpty, "\(label): errorDescription is empty")
    }

    @Test func metalErrorCasesDescribed() {
        let cases: [MetalError] = [
            .commandBufferFailed(code: 1), .textureCacheCreateFailed(code: 2),
            .textureWrapFailed(code: 3), .textureAllocationFailed,
            .pipelineStateCompilation("shader"), .unsupportedFormat, .noFrameAvailable,
        ]
        for e in cases { assertDescribed(e, "MetalError.\(e)") }
    }

    @Test func interopErrorCasesDescribed() {
        let cases: [InteropError] = [
            .pixelSinkRegistrationRejected(code: 1), .pipelineHandleUnavailable,
            .invalidCallbacks, .missingOnOverwrite, .retainMismatch,
        ]
        for e in cases { assertDescribed(e, "InteropError.\(e)") }
    }

    @Test func recordingErrorCasesDescribed() {
        let cases: [RecordingError] = [
            .writerStartFailed(status: 1), .appendFailed(status: 2), .finishTimeout,
            .diskFull, .notReadyForMoreMediaData, .finalizeTimeout,
            .finalizeFailed(reason: "x"), .cancelledByPause,
            .missingFileExtension("clip"), .unsupportedVideoFormat("mov"),
        ]
        for e in cases { assertDescribed(e, "RecordingError.\(e)") }
    }

    @Test func stillCaptureErrorCasesDescribed() {
        let cases: [StillCaptureError] = [
            .alreadyInFlight, .metalReadbackFailed, .fileWriteFailed("/tmp/p.png"),
            .bufferUnavailable, .missingFileExtension("shot"), .unsupportedImageFormat("bmp"),
        ]
        for e in cases { assertDescribed(e, "StillCaptureError.\(e)") }
    }

    @Test func cameraErrorDescribesFromMessage() {
        let cam = CameraError(code: .frameStall, message: "no frame in 5000ms", isFatal: false)
        assertDescribed(cam, "CameraError")
        #expect(cam.errorDescription == "no frame in 5000ms")
    }

    @Test func engineErrorCasesDescribedAndWrappersDelegate() {
        let cam = CameraError(code: .hardwareError, message: "hw fault", isFatal: true)
        let cases: [EngineError] = [
            .alreadyOpen, .notOpen, .cameraDenied, .noBackCamera,
            .noSupportedFormat(reason: "no 420f"), .lockForConfigurationFailed,
            .settingsConflict(reason: "60fps unsupported"), .sessionLifecycleTimeout,
            .metal(.unsupportedFormat), .interop(.retainMismatch),
            .recording(.diskFull), .capture(.alreadyInFlight), .fatal(cam),
            .invalidOutputPath(URL(fileURLWithPath: "/etc/x")), .calibrationInProgress,
            .blackPointCalibrationFailed(reason: "too bright"),
            .whiteBalanceCalibrationFailed(reason: "too dim"),
            .whiteBalanceNotCalibrated, .blackPointNotCalibrated,
        ]
        for e in cases { assertDescribed(e, "EngineError.\(e)") }

        // Wrapping cases delegate to the wrapped error's description.
        #expect(
            EngineError.metal(.unsupportedFormat).errorDescription
                == MetalError.unsupportedFormat.errorDescription)
        #expect(EngineError.capture(.alreadyInFlight).errorDescription
            == StillCaptureError.alreadyInFlight.errorDescription)
        #expect(EngineError.fatal(cam).errorDescription == "hw fault")
        #expect(EngineError.settingsConflict(reason: "boom").errorDescription == "boom")

        // The bridged user-visible string uses errorDescription.
        let notOpen = EngineError.notOpen
        #expect((notOpen as any Error).localizedDescription == notOpen.errorDescription)
    }
}
