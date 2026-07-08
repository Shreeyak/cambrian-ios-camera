import CoreVideo
import Foundation
import FrameTransport

/// Public surface of `CameraEngine` that the Flutter iOS adapter consumes.
///
/// Mirrors every public method the adapter calls. `CameraEngine` (an `actor`)
/// conforms automatically via member parity — see the
/// `extension CameraEngine: CameraEngineProtocol {}` at the bottom of this file.
/// Adapter unit tests (`flutter/example/ios/RunnerTests/`) mock against this
/// protocol so the adapter can be tested without standing up a real
/// capture session.
///
/// Not for general public consumption — most call sites should hold a
/// concrete `CameraEngine`. The protocol exists for testability.
public protocol CameraEngineProtocol: Actor {
    // MARK: Lifecycle
    func setLifecyclePhase(_ phase: AppLifecyclePhase) async
    func open(configuration: OpenConfiguration) async throws -> SessionCapabilities
    func close() async

    // MARK: Snapshots
    func currentStateSnapshot() -> SessionState
    func currentSettingsSnapshot() -> CameraSettings?
    func currentProcessingParametersSnapshot() -> ProcessingParameters?

    // MARK: Streams
    func stateStream() -> AsyncStream<SessionState>
    func errorStream() -> AsyncStream<CameraError>
    func streamConfigurationStream() -> AsyncStream<StreamConfiguration>
    func frameResultStream() -> AsyncStream<FrameResult>
    func recordingStateStream() -> AsyncStream<RecordingState>

    // MARK: Control
    func updateSettings(_ settings: CameraSettings) async throws
    func setResolution(size: Size) async throws
    func setProcessingParams(_ params: ProcessingParameters) async
    func setCropRegion(_ rect: Rect) async throws
    func setCenterCrop(width: Int, height: Int, offsetX: Double, offsetY: Double) async throws
    func setCropEnabled(_ enabled: Bool) async throws

    // MARK: Capture
    func captureImage(
        outputURL: URL?,
        photosDestination: PhotosDestination
    ) async throws -> StillCaptureOutput
    func captureNaturalPicture(
        outputURL: URL?,
        photosDestination: PhotosDestination
    ) async throws -> StillCaptureOutput
    /// In-memory natural (pre-grade) still as a leased ``PixelHandle`` (no disk/Photos).
    func captureNaturalPictureBuffer() async throws -> PixelHandle

    // MARK: Recording
    func startRecording(options: RecordingOptions) async throws -> RecordingStart
    func stopRecording() async throws -> String

    // MARK: Calibration
    // Full procedures: sample → compute → enable.
    func calibrateWhite(whitePoint: Bool) async throws -> CalibrationResult
    func calibrateBlack() async throws -> BlackPointDebug
    // Independent toggles on the stored coefficients (no resampling).
    func enableWhiteBalance() async throws
    func disableWhiteBalance() async
    func enableWhitePoint() async throws
    func disableWhitePoint() async
    func clearWhiteBalance() async
    func enableBlackPoint() async throws
    func disableBlackPoint() async
    func clearBlackPoint() async

    // MARK: Texture bridge
    nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer?

    // MARK: Frame subscription
    nonisolated var consumers: ConsumerRegistry { get }
}

extension CameraEngine: CameraEngineProtocol {}
