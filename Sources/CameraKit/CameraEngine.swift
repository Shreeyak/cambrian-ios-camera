import AVFoundation
import Atomics
import CoreMedia
import Metal

/// The public actor that orchestrates the entire camera pipeline.
/// This is the ONLY type callers interact with at the API layer.
///
/// ADR-07: All AVCaptureSession mutations go through sessionQueue.
/// ADR-09: submissionGate guards every commandBuffer.commit() on the delivery queue.
/// ADR-22: stateStream() returns AsyncStream<SessionState> buffered with .bufferingOldest.
/// ADR-30: backgroundSuspend() / backgroundResume() use async-with-timeout for session lifecycle.
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
    private var currentSettings: CameraSettings?

    // ADR-09: GPU submission gate. Shared by reference with MetalPipeline.
    // Reads: delivery queue (.acquiring load). Writes: engine actor (.sequentiallyConsistent store).
    // `let` — same instance for the lifetime of the engine; nonisolated for synchronous
    // access by tests and by MetalPipeline (which holds it as a reference).
    nonisolated let submissionGate: ManagedAtomic<Bool> = ManagedAtomic(true)

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

        // 4. Metal pipeline — pass the shared submission gate (ADR-09).
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let pipeline = try MetalPipeline(device: mtlDevice, captureSize: captureSize, gate: submissionGate)

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

        // Install KVO ingest so `lastSnapshot` is populated for Rule 3.
        if let live = device as? LiveCaptureDevice {
            await live.installKVOIngest()
        }

        self.isOpen = true

        // 7. Open the gate (idempotent — starts true; explicit after any prior close).
        submissionGate.store(true, ordering: .sequentiallyConsistent)

        // 8. Start running on sessionQueue (ADR-07).
        session.sessionQueue.async {
            session.startRunning()
        }

        // 9. Publish .streaming state.
        publishState(.streaming)

        // Apply persisted settings if any. Swallow failures (pre-first-readback Rule 3).
        if let persisted = SettingsPersistence.load() {
            do {
                try await self.updateSettings(persisted)
            } catch {
                // intentional — don't block open() on a transient Rule 3
            }
        }

        // 10. Build and return SessionCapabilities.
        let supportedSizes = await device.supportedSizes
        let activeCropRegion = Rect(
            x: 0,
            y: 0,
            width: Constants.cropDefaultWidthPx,
            height: Constants.cropDefaultHeightPx
        )
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,  // stub: texture IDs arrive Stage 05
            naturalTextureId: 0,  // stub: texture IDs arrive Stage 05
            activeCaptureResolution: captureSize,
            activeCropRegion: activeCropRegion,
            streamPixelFormat: "420f"
        )
    }

    /// Closes the camera session and releases all resources.
    public func close() async {
        guard isOpen else { return }
        // Disarm watchdogs (placeholder; real watchdog disarm arrives Stage 09).
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        if let session = cameraSession {
            session.sessionQueue.sync { session.stopRunning() }
        }
        if let live = cameraSession?.device as? LiveCaptureDevice {
            await live.cancelKVO()
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

    /// Full settings merge→couple→validate→commit→persist pipeline (Stage 03).
    ///
    /// - Merges onto prior state
    /// - Applies coupling rules (Rules 1/2/3 from 07-settings.md)
    /// - Validates ranges against device capabilities
    /// - Commits to device via sessionQueue (ADR-07)
    /// - Persists asynchronously (detached Task)
    ///
    /// - Throws: `EngineError.notOpen` if engine not open
    /// - Throws: `EngineError.settingsConflict` if range validation fails or Rule 3 pre-readback
    public func updateSettings(_ settings: CameraSettings) async throws {
        guard let session = cameraSession, let device = session.device else {
            throw EngineError.notOpen
        }

        // 1. Merge onto prior state.
        let prior = currentSettings ?? CameraSettings()
        let merged = settings.merging(onto: prior)

        // 2. Couple (Rules 1/2/3). Reads the last KVO snapshot for Rule 3.
        let latched = await device.lastSnapshot
        let resolved = try SettingsCoupling.apply(rules: merged, latched: latched)

        // 3. Range-validate against the device's supported ranges (brief §7).
        let isoRange = await device.isoRange
        let expRange = await device.exposureDurationRangeNs
        if let iso = resolved.iso, !isoRange.contains(Float(iso)) {
            throw EngineError.settingsConflict(
                reason: "iso=\(iso) outside supported range \(isoRange)")
        }
        if let exp = resolved.exposureTimeNs, !expRange.contains(exp) {
            throw EngineError.settingsConflict(
                reason: "exposureTimeNs=\(exp) outside supported range \(expRange)")
        }
        if let focus = resolved.focusDistance, !(0.0...1.0).contains(focus) {
            throw EngineError.settingsConflict(
                reason: "focusDistance=\(focus) outside [0.0, 1.0]")
        }

        // 4. Commit through session (ADR-07).
        try await session.applySettings(resolved, on: device)
        currentSettings = resolved

        // 5. Persist. Detached so the actor doesn't block on I/O.
        let toSave = resolved
        Task.detached { SettingsPersistence.save(toSave) }
    }

    public func registerPixelSink(_ callbacks: PixelSinkCallbacks) async -> ConsumerToken {
        consumerRegistry.register(callbacks)
    }

    public func deregisterPixelSink(_ token: ConsumerToken) async {
        consumerRegistry.deregister(token)
    }

    /// Signals the app entered background.
    ///
    /// Gates GPU submission, drains any in-flight
    /// frame, and stops the capture session via sessionQueue with timeout (ADR-30).
    ///
    /// Step 1 (disarm watchdogs) is a placeholder no-op until Stage 09.
    public func backgroundSuspend() async {
        // Disarm watchdogs (placeholder; arrives Stage 09).
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()
        if let session = cameraSession {
            await session.stopRunningAsync()
        }
    }

    /// Signals the app returned to foreground.
    ///
    /// Re-opens the GPU submission gate.
    ///
    /// Session restart is driven by AVCaptureSessionInterruptionEnded (not wired until
    /// a later stage). Until then the session remains stopped — idempotent and harmless
    /// per brief test 02:background-resume-is-noop-until-interruption-ended.
    public func backgroundResume() async {
        submissionGate.store(true, ordering: .sequentiallyConsistent)
    }

    /// Exposes the naturalTex for the MTKView draw pass. nil if engine not open.
    /// nonisolated so ViewModel can call synchronously without actor hop (MTLTexture is non-Sendable).
    public nonisolated func currentTexture() -> (any MTLTexture)? {
        _naturalTex
    }

    // MARK: - Internal helpers (accessible via @testable import)

    /// Sets the GPU submission gate (ADR-09, D-06).
    /// `.inactive` policy is strict — always gates, regardless of UIApplication state.
    func setGate(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    /// Waits for the most recently committed command buffer to be scheduled.
    ///
    /// Bounds the drain window to FRAME_LATENCY_BUDGET_MS (ADR-09).
    /// No-op if no buffer has been committed yet this session.
    func drainSubmittedFrame() async {
        metalPipeline?.drainLastBuffer()
    }

    /// Internal accessor for gate state — used by Stage02Tests.
    var isGateOpen: Bool {
        submissionGate.load(ordering: .acquiring)
    }

    // MARK: - Private helpers

    private func setStateContinuation(_ continuation: AsyncStream<SessionState>.Continuation) {
        stateContinuation = continuation
    }

    private func publishState(_ state: SessionState) {
        stateContinuation?.yield(state)
    }
}
