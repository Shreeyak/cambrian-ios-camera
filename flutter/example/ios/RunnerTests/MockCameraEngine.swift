import CameraKit
import CoreVideo
import Foundation

/// In-memory test double for `CameraEngineProtocol`.
///
/// Conforms via member parity — adding a protocol requirement fails to compile
/// here until the mock implements it. Imports only `CameraKit`: every type in
/// the protocol is a CameraKit type, and importing the plugin module too would
/// make `StreamId` / `CameraSettings` / `PhotosDestination` ambiguous (the
/// Pigeon layer redeclares them).
actor MockCameraEngine: CameraEngineProtocol {
    var phaseHistory: [AppLifecyclePhase] = []
    var lastConfig: OpenConfiguration?
    var openCalls = 0
    var closeCalls = 0
    var openResult: SessionCapabilities = MockCameraEngine.placeholderCaps()
    var startResult = RecordingStart(uri: "file:///tmp/r.mp4", displayName: "r.mp4")
    var stopResult = "file:///tmp/r.mp4"

    static func placeholderCaps() -> SessionCapabilities {
        SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            supportedFrameRates: [
                FrameRateRange(size: Size(width: 1920, height: 1080), minFps: 1, maxFps: 60)
            ],
            activeFrameRate: 30,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: "BGRA8",
            isoRange: 50.0...3200.0,
            exposureDurationRangeNs: 100_000...33_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...8.0,
            evCompensationRange: -8.0...8.0,
            trackerResolution: Size(width: 854, height: 480)
        )
    }

    func setLifecyclePhase(_ phase: AppLifecyclePhase) async { phaseHistory.append(phase) }
    func open(configuration: OpenConfiguration) async throws -> SessionCapabilities {
        openCalls += 1
        lastConfig = configuration
        return openResult
    }
    func close() async { closeCalls += 1 }
    var currentStateValue: SessionState = .closed
    func setCurrentState(_ s: SessionState) { currentStateValue = s }
    func currentStateSnapshot() -> SessionState { currentStateValue }
    func currentSettingsSnapshot() -> CameraSettings? { nil }
    func currentProcessingParametersSnapshot() -> ProcessingParameters? { nil }
    func stateStream() -> AsyncStream<SessionState> { AsyncStream { _ in } }
    func errorStream() -> AsyncStream<CameraError> { AsyncStream { _ in } }
    func streamConfigurationStream() -> AsyncStream<StreamConfiguration> { AsyncStream { _ in } }
    func frameResultStream() -> AsyncStream<FrameResult> { AsyncStream { _ in } }
    func recordingStateStream() -> AsyncStream<RecordingState> { AsyncStream { _ in } }
    func updateSettings(_ settings: CameraSettings) async throws {}
    func setResolution(size: Size) async throws {}
    func setProcessingParams(_ params: ProcessingParameters) async {}
    func setCropRegion(_ rect: Rect) async throws {}
    func setCenterCrop(width: Int, height: Int, offsetX: Double, offsetY: Double) async throws {}
    func setCropEnabled(_ enabled: Bool) async throws {}
    func captureImage(
        outputURL: URL?, photosDestination: PhotosDestination
    ) async throws -> StillCaptureOutput {
        StillCaptureOutput(filePath: outputURL?.path ?? "/tmp/x.heic")
    }
    func captureNaturalPicture(
        outputURL: URL?, photosDestination: PhotosDestination
    ) async throws -> StillCaptureOutput {
        StillCaptureOutput(filePath: outputURL?.path ?? "/tmp/n.heic")
    }
    func startRecording(options: RecordingOptions) async throws -> RecordingStart { startResult }
    func stopRecording() async throws -> String { stopResult }
    func calibrateWhite(whitePoint: Bool) async throws -> CalibrationResult {
        let s = RgbSample(r: 0.5, g: 0.5, b: 0.5)
        return CalibrationResult(before: s, after: s, converged: true, iterations: 1)
    }
    func calibrateBlack() async throws -> BlackPointDebug {
        let s = BlackPointChannelStats(offsetLinear: 0, meanGamma: 0, minGamma: 0, maxGamma: 0)
        return BlackPointDebug(keptCount: 1, totalCount: 1, r: s, g: s, b: s)
    }
    func enableWhiteBalance() async throws {}
    func disableWhiteBalance() async {}
    func enableWhitePoint() async throws {}
    func disableWhitePoint() async {}
    func clearWhiteBalance() async {}
    func enableBlackPoint() async throws {}
    func disableBlackPoint() async {}
    func clearBlackPoint() async {}
    nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer? { nil }
    nonisolated var consumers: ConsumerRegistry { ConsumerRegistry() }
}
