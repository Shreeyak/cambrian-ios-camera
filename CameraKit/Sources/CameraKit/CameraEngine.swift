import AVFoundation
import Metal
import CoreMedia

/// The public actor that orchestrates the entire camera pipeline.
/// This is the ONLY type callers interact with at the API layer.
///
/// ADR-07: All AVCaptureSession mutations go through sessionQueue.
/// ADR-22: stateStream() returns AsyncStream<SessionState> buffered with .bufferingOldest.
/// ADR-32: Production code never creates AVCaptureDevice directly — CameraSession handles that.
public actor CameraEngine {

    // MARK: - Private state

    private var cameraSession: CameraSession?
    private var captureDelegate: CaptureDelegate?
    private var metalPipeline: MetalPipeline?
    private var consumerRegistry: ConsumerRegistry = ConsumerRegistry()
    private var deliveryQueue: DispatchQueue?
    private var stateContinuation: AsyncStream<SessionState>.Continuation?
    private var cachedStateStream: AsyncStream<SessionState>?
    private var isOpen: Bool = false

    // MTLTexture is non-Sendable; stored nonisolated(unsafe) so ViewModel can read it
    // synchronously after open() returns, without crossing an actor boundary.
    // Written once in open() before startRunning(); read after open() completes — no race.
    nonisolated(unsafe) private var _naturalTex: (any MTLTexture)?

    // MARK: - Public API

    public init() {}

    /// Opens the camera session and returns capabilities.
    ///
    /// - Throws: `EngineError.alreadyOpen` if already open.
    /// - Throws: `EngineError.cameraDenied` if permission not granted.
    /// - Throws: `EngineError.noBackCamera` if no back camera found.
    /// - Throws: `EngineError.metal(_:)` if MetalPipeline fails to initialise.
    public func open(configuration: OpenConfiguration = OpenConfiguration()) async throws -> SessionCapabilities {
        guard !isOpen else { throw EngineError.alreadyOpen }

        // 1. Camera permission (ADR-32: permission check uses AVFoundation directly —
        //    it's a process-level gate, not a device operation).
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { throw EngineError.cameraDenied }

        // 2. Set up queues and delegates.
        let session = CameraSession()
        let delegate = CaptureDelegate()
        let delivery = DispatchQueue(label: "com.cambrian.camerakit.delivery", qos: .userInitiated)

        // 3. Configure the session on sessionQueue (ADR-07, ADR-30).
        //    session.configure() runs synchronously on the queue; the closure only
        //    touches session internals — no actor re-entry.
        let (device, captureSize): (any CaptureDeviceProviding, Size) = try session.sessionQueue.sync {
            try session.configure(deliveryQueue: delivery, sampleBufferDelegate: delegate)
        }

        // 4. Metal pipeline.
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let pipeline = try MetalPipeline(device: mtlDevice, captureSize: captureSize)

        // 5. Wire sample buffer → Metal encode.
        //    Closure runs on delivery queue (ADR-02); pipeline is @unchecked Sendable.
        delegate.onSampleBuffer = { [weak pipeline] sampleBuffer in
            try? pipeline?.encode(sampleBuffer: sampleBuffer)
        }

        // 6. Store state.
        self.cameraSession = session
        self.captureDelegate = delegate
        self.metalPipeline = pipeline
        self._naturalTex = pipeline.currentTexture()
        self.deliveryQueue = delivery
        self.isOpen = true

        // 7. Start running on sessionQueue (ADR-07).
        session.sessionQueue.async {
            session.startRunning()
        }

        // 8. Publish .streaming state.
        publishState(.streaming)

        // 9. Build and return SessionCapabilities.
        let supportedSizes = await device.supportedSizes
        let activeCropRegion = Rect(
            x: 0,
            y: 0,
            width: Constants.cropDefaultWidthPx,
            height: Constants.cropDefaultHeightPx
        )
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,   // stub: texture IDs arrive Stage 05
            naturalTextureId: 0,   // stub: texture IDs arrive Stage 05
            activeCaptureResolution: captureSize,
            activeCropRegion: activeCropRegion,
            streamPixelFormat: "420f"
        )
    }

    /// Closes the camera session and releases all resources.
    public func close() async {
        guard isOpen else { return }
        if let session = cameraSession {
            session.sessionQueue.sync { session.stopRunning() }
        }
        cameraSession = nil
        captureDelegate = nil
        metalPipeline = nil
        _naturalTex = nil
        deliveryQueue = nil
        isOpen = false
        publishState(.closed)
    }

    /// Returns an AsyncStream of SessionState events.
    ///
    /// ADR-22: buffered with .bufferingOldest(Constants.stateStreamBufferSize).
    /// The stream is cached — multiple callers receive the same stream instance.
    public func stateStream() -> AsyncStream<SessionState> {
        if let existing = cachedStateStream { return existing }
        let stream = AsyncStream<SessionState>(
            SessionState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            // Store the continuation so the engine can publish state changes.
            // This closure runs synchronously during AsyncStream init.
            Task { await self?.setStateContinuation(continuation) }
        }
        cachedStateStream = stream
        return stream
    }

    /// Stage 01 stub. Full settings merge arrives Stage 03.
    public func updateSettings(_ settings: CameraSettings) async throws {
        // Stage 01 stub: full settings merge arrives Stage 03.
    }

    public func registerPixelSink(_ callbacks: PixelSinkCallbacks) async -> ConsumerToken {
        consumerRegistry.register(callbacks)
    }

    public func deregisterPixelSink(_ token: ConsumerToken) async {
        consumerRegistry.deregister(token)
    }

    /// Called by ViewModel on .background scene phase.
    func naiveBackgroundStop() {
        // scaffolding:01:naive-scenephase-stop — plain sessionQueue.async with no GPU-submission
        // gate, no waitUntilScheduled(), no UIApplication.beginBackgroundTask. Retires Stage 02.
        guard let session = cameraSession else { return }
        session.sessionQueue.async {
            session.stopRunning()
        }
    }

    /// Exposes the naturalTex for the MTKView draw pass. nil if engine not open.
    /// nonisolated so ViewModel can call synchronously without actor hop (MTLTexture is non-Sendable).
    public nonisolated func currentTexture() -> (any MTLTexture)? {
        _naturalTex
    }

    // MARK: - Private helpers

    private func setStateContinuation(_ continuation: AsyncStream<SessionState>.Continuation) {
        stateContinuation = continuation
    }

    private func publishState(_ state: SessionState) {
        stateContinuation?.yield(state)
    }
}
