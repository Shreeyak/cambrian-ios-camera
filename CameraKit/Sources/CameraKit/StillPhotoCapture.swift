import AVFoundation
import CoreVideo

/// One-shot still photo via AVCapturePhotoOutput.
///
/// `capture(using:)` is invoked on sessionQueue (ADR-07); the delegate callback
/// (nonisolated) bridges the resulting CVPixelBuffer back through a checked
/// continuation. Photo settings honor the device's live exposure/ISO/WB/focus —
/// there is no separate photo-settings surface; the user controls those via the
/// existing `CameraSettings` mechanism and this capture inherits them.
final class StillPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    /// Builds the fixed photo settings.
    ///
    /// Requests 420f to match the video format so `MetalPipeline.gradeOneShot`
    /// consumes the buffer directly. Flash off and `.balanced` quality (nice
    /// native-camera look while honoring device exposure). Does NOT set
    /// `maxPhotoDimensions` — photo dims default to the active format dims so
    /// `gradeOneShot`'s 1:1 crop mapping holds.
    static func makeSettings() -> AVCapturePhotoSettings {
        let fmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let s = AVCapturePhotoSettings(
            format: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
        s.flashMode = .off
        s.photoQualityPrioritization = .balanced
        return s
    }

    private var continuation: CheckedContinuation<CVPixelBuffer, Error>?

    /// Must be called on sessionQueue.
    ///
    /// Shoots one photo and returns its pixel buffer.
    func capture(using output: AVCapturePhotoOutput) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            output.capturePhoto(with: Self.makeSettings(), delegate: self)
        }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { continuation = nil }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let pb = photo.pixelBuffer else {
            continuation?.resume(throwing: StillCaptureError.bufferUnavailable)
            return
        }
        continuation?.resume(returning: pb)
    }
}
