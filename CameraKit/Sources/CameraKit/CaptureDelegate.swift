import AVFoundation
import CoreMedia

/// Receives raw sample buffers from `AVCaptureVideoDataOutput` on the `delivery`
/// DispatchQueue (ADR-02).
///
/// - This class is intentionally NOT an actor. All work happens on the `delivery`
///   queue; no hops to any actor boundary, MainActor, or other DispatchQueue are
///   permitted in this file (ADR-02 / ADR-07).
/// - `@unchecked Sendable`: the instance is captured in `@Sendable` closures on
///   `delivery`. `onSampleBuffer` is set by `CameraEngine` on `sessionQueue` before
///   `startRunning()` — no concurrent mutation occurs during streaming.
/// - GPU submission gate (ADR-09, D-06) is enforced inside `MetalPipeline.encode()`
///   after CPU-side work and immediately before `commandBuffer.commit()`. The
///   `captureOutput(_:didOutput:from:)` path passes through that gate check.
final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// Called on the `delivery` queue for every successfully delivered frame.
    ///
    /// Set by `CameraEngine` on `sessionQueue` before the session starts running.
    /// This is the Metal pipeline's entry point (Stage 08+).
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    /// Stage 05: weak reference to the pipeline for reading per-frame `ProcessingMetadata`.
    ///
    /// Populated by `CameraEngine.open()` alongside `onSampleBuffer`. The delegate reads
    /// `pipeline.lastProcessingMetadata` after `onSampleBuffer` fires; the delivery queue
    /// serialises both the encode write and this read so no lock is needed here.
    /// Full population of the downstream consumer path (FrameSet.processing) arrives Stage 06.
    weak var pipeline: MetalPipeline?

    /// Weak reference to the engine for frame-result heartbeat (Stage 03).
    weak var engine: CameraEngine?

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    /// Invoked on the `delivery` queue for each frame that AVFoundation delivers.
    ///
    /// Forwards the buffer directly to `onSampleBuffer`; no actor hops (ADR-02).
    /// Stage 05: reads `lastProcessingMetadata` after encode for downstream plumbing (no-op until Stage 06).
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
        // Stage 05: capture the per-frame metadata snapshot written by MetalPipeline.encode().
        // The delivery queue serialises encode() (which writes lastProcessingMetadata) and
        // this read, so no additional synchronisation is required.
        // Full FrameSet construction with this metadata attached arrives in Stage 06.
        _ = pipeline?.lastProcessingMetadata
        engine?.tickFrame()
    }

    /// Invoked on the `delivery` queue when a frame is dropped.
    ///
    /// Drop accounting is deferred to a later stage; no-op here (Stage 01).
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // no-op: drop metrics arrive in a later stage
    }
}
