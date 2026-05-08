import AVFoundation
import Atomics
import CoreMedia
import CoreVideo
import Metal
import Synchronization

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
    private var stillCapture: StillCapture?
    /// Stage 06: public consumer registry per D-01 / D-03.
    ///
    /// Lifetime matches the engine; every `open()` passes this same instance to
    /// the `MetalPipeline` so publication (nonisolated `yield` on the delivery
    /// queue) and subscription (actor-isolated `subscribe` from Swift callers)
    /// share state.
    public nonisolated let consumers: ConsumerRegistry = ConsumerRegistry()
    private var deliveryQueue: DispatchQueue?
    // Bug 3 fix (docs/stage-11-pre-existing-bugs.md): continuations live in nonisolated
    // Mutex boxes so the AsyncStream init closure can install them synchronously. The
    // previous `Task { await self?.setXContinuation(c) }` hop returned to the caller
    // before the continuation was non-nil; emits during that window were dropped.
    private nonisolated let stateContinuationBox =
        Mutex<AsyncStream<SessionState>.Continuation?>(nil)
    // Bug 5: nonisolated(unsafe) so the eager construction in init() can install
    // the continuation before any publishX(...) call. Writers afterwards are
    // actor-isolated (init then optional clear in close()); single-writer-per-phase.
    nonisolated(unsafe) private var cachedStateStream: AsyncStream<SessionState>?
    private nonisolated let errorContinuationBox =
        Mutex<AsyncStream<CameraError>.Continuation?>(nil)
    nonisolated(unsafe) private var cachedErrorStream: AsyncStream<CameraError>?
    private var isOpen: Bool = false
    private var currentSettings: CameraSettings?
    private nonisolated let frameResultContinuationBox =
        Mutex<AsyncStream<FrameResult>.Continuation?>(nil)
    nonisolated(unsafe) private var cachedFrameResultStream: AsyncStream<FrameResult>?
    private var frameCounter: UInt64 = 0

    private var watchdogs: WatchdogPair?
    private var recovery: RecoveryCoordinator?
    private let clock: any CameraKitClock
    private var aeMonitorTask: Task<Void, Never>?
    private var fpsWindowStartMs: UInt64 = 0
    private var fpsFrameCount: Int = 0
    private var fpsLowStreak: Int = 0

    // ADR-09: GPU submission gate. Shared by reference with MetalPipeline.
    // Reads: delivery queue (.acquiring load). Writes: engine actor (.sequentiallyConsistent store).
    // `let` — same instance for the lifetime of the engine; nonisolated for synchronous
    // access by tests and by MetalPipeline (which holds it as a reference).
    nonisolated let submissionGate: ManagedAtomic<Bool> = ManagedAtomic(true)

    /// Session identity.
    ///
    /// Bumped on every close() and on entry to recovery. Completion handlers,
    /// watchdogs, and retry tasks compare against this to detect that they were
    /// armed for a stale session (D-10, Inv 9, Inv 12).
    nonisolated let sessionToken: ManagedAtomic<UInt64> = ManagedAtomic(0)

    // Bug 4 fix: previewTex accessors forward live to MetalPipeline mailboxes
    // (`latestNaturalTex` / `latestProcessedTex`) — which the pipeline rewrites
    // every frame. The previous capture-once snapshot pattern sat on whichever
    // pool buffer was dequeued at open() time and froze whenever pool rotation
    // moved past it (typical after any transient back-pressure). Tracker tex
    // already followed this live-forward pattern (line ~565).

    // Stage 06: tracker texture mailbox — see latestTrackerTex on MetalPipeline (G-13).
    // Written on the delivery queue via the pipeline's completedHandler; read by
    // ViewModel without actor hop (nonisolated(unsafe) — single writer: delivery queue).
    nonisolated(unsafe) private var _metalPipeline: MetalPipeline?

    // MARK: - Public API

    public init(clock: any CameraKitClock = SystemClock()) {
        self.clock = clock
        // Bug 5 (docs/stage-11-pre-existing-bugs.md): eagerly construct each
        // cached stream so its continuation is installed in the box *before*
        // any publishX(...) can fire. The lazy first-call pattern dropped the
        // .streaming emit fired inside engine.open() because ViewModel.start()
        // did not call stateStream() until after open() returned.
        self.cachedStateStream = AsyncStream<SessionState>(
            SessionState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.stateContinuationBox.withLock { $0 = continuation }
        }
        self.cachedErrorStream = AsyncStream<CameraError>(
            CameraError.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.errorContinuationBox.withLock { $0 = continuation }
        }
        self.cachedFrameResultStream = AsyncStream<FrameResult>(
            FrameResult.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { [weak self] continuation in
            self?.frameResultContinuationBox.withLock { $0 = continuation }
        }
        self.cachedRecordingStream = AsyncStream<RecordingState>(
            RecordingState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.recordingContinuationBox.withLock { $0 = continuation }
        }
    }

    /// Returns the last successfully committed settings, or nil if none have been applied.
    public func currentSettingsSnapshot() -> CameraSettings? { currentSettings }

    /// Opens the camera session and returns capabilities.
    ///
    /// - Throws: `EngineError.alreadyOpen` if already open.
    /// - Throws: `EngineError.cameraDenied` if permission not granted.
    /// - Throws: `EngineError.noBackCamera` if no back camera found.
    /// - Throws: `EngineError.metal(_:)` if MetalPipeline fails to initialise.
    public func open(configuration: OpenConfiguration = OpenConfiguration()) async throws -> SessionCapabilities {
        guard !isOpen else { throw EngineError.alreadyOpen }
        CameraKitLog.notice(.engine, "open: requesting camera permission")

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
        let pipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: captureSize,
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken
        )
        pipeline.onMetalError = { [weak self] mErr in
            Task { [weak self] in
                let err = CameraError(
                    code: .unknownError,
                    message: "metal: \(mErr)",
                    isFatal: false
                )
                await self?.publishErrorAsync(err)
                await self?.recovery?.enterRecovery(error: err)
            }
        }

        // 5. Wire sample buffer → Metal encode.
        //    Closure runs on delivery queue (ADR-02); pipeline is @unchecked Sendable.
        delegate.onSampleBuffer = { [weak pipeline] sampleBuffer in
            try? pipeline?.encode(sampleBuffer: sampleBuffer)
        }
        delegate.engine = self

        // 6. Store state.
        self.cameraSession = session
        session.onSessionEvent = { [weak self] event in
            Task { [weak self] in await self?.onSessionEvent(event) }
        }
        self.captureDelegate = delegate
        self.metalPipeline = pipeline
        self._metalPipeline = pipeline
        stillCapture = StillCapture()
        self.deliveryQueue = delivery

        // Install KVO ingest so `lastSnapshot` is populated for Rule 3.
        if let live = device as? LiveCaptureDevice {
            await live.installKVOIngest()
        }

        self.isOpen = true

        // 7. Open the gate (idempotent — starts true; explicit after any prior close).
        submissionGate.store(true, ordering: .sequentiallyConsistent)

        // 8. Stage 09: watchdogs + recovery coordinator.
        let gpu = Watchdog(kind: .gpu, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let cap = Watchdog(kind: .capture, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let pair = WatchdogPair(gpu: gpu, capture: cap)
        self.watchdogs = pair
        delegate.watchdogs = pair
        let hooks = RecoveryCoordinator.Hooks(
            performTeardownAndReopen: { [weak self] in
                await self?.close()
                _ = try await self?.open(configuration: configuration)
            },
            emitStateRecovering: { [weak self] in
                await self?.publishStateAsync(.recovering)
            },
            emitError: { [weak self] err in
                await self?.publishErrorAsync(err)
            },
            disarmWatchdogs: { [weak self] in
                await self?.disarmWatchdogsAsync()
            },
            incrementSessionToken: { [weak self] in
                self?.sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
            }
        )
        self.recovery = RecoveryCoordinator(clock: clock, hooks: hooks)
        let token = sessionToken.load(ordering: .acquiring)
        pair.gpu.arm(sessionToken: token)
        pair.capture.arm(sessionToken: token)

        startAEMonitor(device: device)

        // 9. Start running on sessionQueue (ADR-07).
        session.sessionQueue.async {
            session.startRunning()
        }

        // 10. Publish .streaming state.
        publishState(.streaming)

        // Apply persisted settings if any. Clamp ISO to the device's current range
        // before restoring — a stored ISO from a different session can exceed the new
        // device's max, causing a settingsConflict throw that silently aborts the entire
        // restore including zoom and focus. Swallow remaining failures (Rule 3).
        if let persisted = SettingsPersistence.load() {
            do {
                let deviceIsoRange = await device.isoRange
                var clamped = persisted
                if let iso = clamped.iso {
                    clamped.iso = Int(max(deviceIsoRange.lowerBound, min(deviceIsoRange.upperBound, Float(iso))))
                }
                try await self.updateSettings(clamped)
            } catch {
                // intentional — don't block open() on a transient Rule 3
            }
        }

        // Apply persisted ProcessingParameters if any (07-settings.md §Persistence).
        if let persistedProcessing = SettingsPersistence.loadProcessing() {
            await self.setProcessingParameters(persistedProcessing)
        }

        // 11. Build and return SessionCapabilities.
        let supportedSizes = await device.supportedSizes
        let activeCropRegion = Rect(
            x: 0,
            y: 0,
            width: Constants.cropDefaultWidthPx,
            height: Constants.cropDefaultHeightPx
        )
        let isoRange = await device.isoRange
        let exposureDurationRangeNs = await device.exposureDurationRangeNs
        let poolPtr = consumers.nativePipelinePointer()
        CameraKitLog.notice(
            .engine,
            "open: pipeline ready — \(captureSize.width)×\(captureSize.height) pool=0x\(String(poolPtr, radix: 16))"
        )
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,  // stub: texture IDs arrive Stage 05
            naturalTextureId: 0,  // stub: texture IDs arrive Stage 05
            activeCaptureResolution: captureSize,
            activeCropRegion: activeCropRegion,
            streamPixelFormat: "420f",
            isoRange: isoRange,
            exposureDurationRangeNs: exposureDurationRangeNs
        )
    }

    /// Closes the camera session and releases all resources.
    public func close() async {
        sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
        watchdogs?.disarmAll()
        aeMonitorTask?.cancel()
        aeMonitorTask = nil
        fpsWindowStartMs = 0
        fpsFrameCount = 0
        fpsLowStreak = 0
        await recovery?.cancelPendingRetry()
        watchdogs = nil
        recovery = nil
        guard isOpen else { return }
        CameraKitLog.notice(.engine, "close: tearing down pipeline")
        // Disarm watchdogs (placeholder; real watchdog disarm arrives Stage 09).
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        if let session = cameraSession {
            session.sessionQueue.sync { session.stopRunning() }
        }
        if let live = cameraSession?.device as? LiveCaptureDevice {
            await live.cancelKVO()
        }
        frameResultContinuationBox.withLock {
            $0?.finish()
            $0 = nil
        }
        cachedFrameResultStream = nil
        frameCounter = 0
        await consumers.release()
        cameraSession = nil
        captureDelegate = nil
        metalPipeline = nil
        stillCapture = nil
        _metalPipeline = nil
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
            // Synchronous install via nonisolated box — see Bug 3.
            self?.stateContinuationBox.withLock { $0 = continuation }
        }
        cachedStateStream = stream
        return stream
    }

    /// Sensor-metadata heartbeat at `frameRateTargetFPS / frameResultHeartbeatIntervalFrames` Hz.
    /// `.bufferingNewest(1)` per ADR-22 (frame-rate stream).
    public func frameResultStream() -> AsyncStream<FrameResult> {
        if let existing = cachedFrameResultStream { return existing }
        let stream = AsyncStream<FrameResult>(
            FrameResult.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { [weak self] continuation in
            self?.frameResultContinuationBox.withLock { $0 = continuation }
        }
        cachedFrameResultStream = stream
        return stream
    }

    /// Stream of error notifications (non-fatal + fatal).
    ///
    /// ADR-22: .bufferingOldest so every error is delivered. Subscribe once per consumer
    /// lifetime; same instance returned thereafter.
    public func errorStream() -> AsyncStream<CameraError> {
        if let cached = cachedErrorStream { return cached }
        let stream = AsyncStream<CameraError>(
            CameraError.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.errorContinuationBox.withLock { $0 = continuation }
        }
        cachedErrorStream = stream
        return stream
    }

    private func publishError(_ err: CameraError) {
        errorContinuationBox.withLock { $0?.yield(err) }
    }

    /// Test-only: emit an arbitrary CameraError without driving the recovery machine.
    func _emitErrorForTest(_ err: CameraError) {
        publishError(err)
    }

    /// Called from `CaptureDelegate` on every sample buffer (nonisolated — delivery queue).
    nonisolated func tickFrame() {
        Task { await self.onFrameTick() }
    }

    private func onFrameTick() async {
        frameCounter &+= 1
        guard frameCounter % UInt64(Constants.frameResultHeartbeatIntervalFrames) == 0,
            let device = cameraSession?.device,
            let snap = await device.lastSnapshot
        else { return }
        let r = FrameResult(
            iso: Int(snap.iso),
            exposureTimeNs: snap.exposureDurationNs,
            focusDistance: Double(snap.lensPosition),
            wbGainR: Double(snap.whiteBalanceGains.red),
            wbGainG: Double(snap.whiteBalanceGains.green),
            wbGainB: Double(snap.whiteBalanceGains.blue))
        frameResultContinuationBox.withLock { $0?.yield(r) }
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

    /// Session-only teardown + re-select format + restart for new resolution.
    ///
    /// Pool-resize is a placeholder until Stage 06 introduces the trio (brief §4).
    ///
    /// - Throws: `EngineError.notOpen` if not yet open.
    public func setResolution(size: Size) async throws {
        guard let session = cameraSession else { throw EngineError.notOpen }

        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()

        await session.stopRunningAsync()
        metalPipeline = nil
        _metalPipeline = nil

        try await session.reconfigureSize(size)

        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let pipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: size,
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken
        )
        pipeline.onMetalError = { [weak self] mErr in
            Task { [weak self] in
                let err = CameraError(
                    code: .unknownError,
                    message: "metal: \(mErr)",
                    isFatal: false
                )
                await self?.publishErrorAsync(err)
                await self?.recovery?.enterRecovery(error: err)
            }
        }
        metalPipeline = pipeline
        _metalPipeline = pipeline

        submissionGate.store(true, ordering: .sequentiallyConsistent)
        await session.startRunningAsync()
    }

    /// Signals the app entered background.
    ///
    /// Gates GPU submission, drains any in-flight
    /// frame, and stops the capture session via sessionQueue with timeout (ADR-30).
    ///
    /// Step 1 (disarm watchdogs) is intentionally omitted: watchdogs must stay armed
    /// during background suspension so the capture stall is detected and recovery fires.
    public func backgroundSuspend() async {
        CameraKitLog.notice(.engine, "[bgsuspend] enter gate=false stopRunning")
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()
        if let session = cameraSession {
            captureDelegate?.logNextFrame = true
            await session.stopRunningAsync()
        }
        CameraKitLog.notice(.engine, "[bgsuspend] stopRunning returned")
    }

    /// Signals the app returned to foreground.
    ///
    /// Re-opens the GPU submission gate and restarts the capture session that was
    /// stopped by `backgroundSuspend()`.
    public func backgroundResume() async {
        CameraKitLog.notice(
            .engine,
            "[bgresume] enter gate=true sessionRunning=\(cameraSession?.avSession.isRunning == true)")
        submissionGate.store(true, ordering: .sequentiallyConsistent)
        CameraKitLog.notice(.engine, "[bgresume] gate opened")
        if let session = cameraSession {
            await session.startRunningAsync()
            CameraKitLog.notice(
                .engine,
                "[bgresume] startRunning returned sessionRunning=\(session.avSession.isRunning)")
        }
    }

    /// Exposes the live natural-tex mailbox for the MTKView draw pass.
    ///
    /// Forwards to `MetalPipeline.latestNaturalTex` — the pipeline updates this
    /// mailbox in the per-frame completion handler (single writer: delivery
    /// queue). MUST be re-evaluated each draw; do not cache the returned
    /// pointer (Bug 4: pool rotation strands cached pointers).
    public nonisolated func currentTexture() -> (any MTLTexture)? {
        _metalPipeline?.latestNaturalTex
    }

    /// Exposes the live processed-tex mailbox for the right-half MTKView draw.
    ///
    /// Same live-mailbox contract as `currentTexture()` — re-evaluate per draw.
    public nonisolated func currentProcessedTexture() -> (any MTLTexture)? {
        _metalPipeline?.latestProcessedTex
    }

    /// Stage 06: returns the latest tracker texture for external consumers.
    ///
    /// nonisolated so callers can access synchronously without an actor hop.
    /// Reads `latestTrackerTex` from the pipeline's nonisolated(unsafe) mailbox
    /// (G-13). Returns nil if no frame has been encoded yet or the engine is closed.
    public nonisolated func currentTrackerTexture() -> (any MTLTexture)? {
        _metalPipeline?.latestTrackerTex
    }

    /// Returns the raw C++ PixelSinkPool pointer as UInt64 while holding the engine actor (D-15).
    ///
    /// Returns nil when the engine is not open.
    public func getNativePipelineHandle() -> UInt64? {
        guard isOpen else {
            CameraKitLog.warning(.engine, "getNativePipelineHandle: engine not open — returning nil")
            return nil
        }
        let ptr = consumers.nativePipelinePointer()
        CameraKitLog.info(.engine, "getNativePipelineHandle: 0x\(String(ptr, radix: 16))")
        return ptr
    }

    /// Stage 05: writes color-transform uniforms through `Mutex<UniformStorage>` (ADR-34, D-17, Inv 6).
    ///
    /// Wholesale replacement (no merge — `ProcessingParameters` is non-nullable per
    /// architecture/07-settings.md §ProcessingParameters).
    public func setProcessingParameters(_ params: ProcessingParameters) async {
        // Route through the mutex so the delivery-queue snapshot in encode() is always coherent.
        metalPipeline?.uniforms.withLock { storage in
            storage.color = ColorUniform(params)
        }
        // Persist on every successful update (07-settings.md §Write path).
        let toSave = params
        Task.detached { SettingsPersistence.saveProcessing(toSave) }
    }

    /// Stage 04: writes the Pass-1 crop rectangle into the pipeline's `UniformsHost.crop` field.
    ///
    /// Coordinates are pixel-space within the active capture size; pixels outside the rect render as black.
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.settingsConflict` if the rect is degenerate
    ///   (zero width/height) or extends past the capture bounds.
    public func setCropRegion(_ rect: Rect) async throws {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        let texW = pipeline.captureSize.width
        let texH = pipeline.captureSize.height
        guard rect.width > 0, rect.height > 0,
            rect.x >= 0, rect.y >= 0,
            rect.x + rect.width <= texW,
            rect.y + rect.height <= texH
        else {
            throw EngineError.settingsConflict(
                reason: "crop rect \(rect) outside capture bounds \(texW)x\(texH)")
        }
        // Route through the mutex so the delivery-queue snapshot in encode() is always coherent (Inv 6).
        pipeline.uniforms.withLock { storage in
            storage.crop = CropUniform(
                originX: UInt32(rect.x),
                originY: UInt32(rect.y),
                width: UInt32(rect.width),
                height: UInt32(rect.height)
            )
        }
    }

    /// Stage 04: dispatches the center-patch sampler and returns per-channel trimmed mean.
    ///
    /// Samples processedTex's CENTER_PATCH_SIZE_PX x CENTER_PATCH_SIZE_PX center, awaits
    /// completion, sorts each channel and returns the trimmed mean per
    /// CENTER_PATCH_TRIM_PERCENT (07-settings.md §Center-patch sampling).
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.metal(_:)` on Metal failures.
    public func sampleCenterPatch() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchCenterPatch()
    }

    /// Stage 04: returns the persisted ProcessingParameters without requiring
    /// an active session. Implementation per architecture/07-settings.md
    /// §Load path: "static / nonisolated accessor so the UI can pre-populate
    /// sliders before `open()`."
    public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters? {
        SettingsPersistence.loadProcessing()
    }

    /// Stage 07: captures the current processed frame as a still image.
    ///
    /// - Parameter outputPath: If non-nil, write the TIFF to this path directly.
    ///   If nil, saves to the Photos library (or Documents as fallback).
    /// - Returns: A `StillCaptureOutput` with the final file path.
    /// - Throws: `EngineError.notOpen` if the engine is not open or not running.
    /// - Throws: `EngineError.capture(_:)` wrapping any `StillCaptureError`.
    public func captureImage(outputPath: String? = nil) async throws -> StillCaptureOutput {
        guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
            throw EngineError.notOpen
        }
        guard let session = cameraSession, session.avSession.isRunning else {
            throw EngineError.capture(.metalReadbackFailed)
        }

        let snap = await cameraSession?.device?.lastSnapshot

        let apertureValue: Double
        if let live = cameraSession?.device as? LiveCaptureDevice {
            apertureValue = Double(live.avDevice.lensAperture)
        } else {
            apertureValue = 0
        }

        let outputURL = outputPath.map { URL(fileURLWithPath: $0) }

        do {
            return try await capture.captureImage(
                pipeline: pipeline,
                captureSize: pipeline.captureSize,
                deviceSnapshot: snap,
                focalLengthMm: 0,
                apertureValue: apertureValue,
                outputURL: outputURL
            )
        } catch let e as StillCaptureError {
            throw EngineError.capture(e)
        }
    }

    // MARK: - Stage 10: Recording

    private var recording: Recording?
    private nonisolated let recordingContinuationBox =
        Mutex<AsyncStream<RecordingState>.Continuation?>(nil)
    nonisolated(unsafe) private var cachedRecordingStream: AsyncStream<RecordingState>?
    private var assetWriterFactory: AssetWriterFactory = DefaultAssetWriterFactory.make

    /// Returns a stream of `RecordingState` transitions.
    ///
    /// Buffered with `.bufferingOldest` per ADR-22. Cached — multiple callers receive the same stream.
    public func recordingStateStream() -> AsyncStream<RecordingState> {
        if let s = cachedRecordingStream { return s }
        let stream = AsyncStream<RecordingState>(
            RecordingState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] c in
            self?.recordingContinuationBox.withLock { $0 = c }
        }
        cachedRecordingStream = stream
        return stream
    }

    private func publishRecordingState(_ s: RecordingState) {
        recordingContinuationBox.withLock { $0?.yield(s) }
    }

    /// Test seam — swap the writer factory before startRecording().
    func _setAssetWriterFactoryForTest(_ f: @escaping AssetWriterFactory) {
        assetWriterFactory = f
    }

    /// Starts a recording session using the current capture pipeline.
    ///
    /// - Throws: `EngineError.notOpen` if the engine has not been opened.
    public func startRecording(options: RecordingOptions) async throws -> RecordingStart {
        guard isOpen, let session = cameraSession, let pipeline = metalPipeline else {
            throw EngineError.notOpen
        }
        try await session.setRecordingFrameRateRange()
        pipeline.onEncodedBufferReady = { [weak self] buf, pts in
            Task { [weak self] in
                await self?.onEncodedBufferReady(buf, pts: pts)
            }
        }
        let hooks = Recording.Hooks(
            publishState: { [weak self] s in
                Task { [weak self] in await self?.publishRecordingStateFromHook(s) }
            },
            emitError: { [weak self] err in
                Task { [weak self] in await self?.publishErrorAsync(err) }
            }
        )
        let rec = Recording(clock: clock, hooks: hooks, writerFactory: assetWriterFactory)
        self.recording = rec
        let start = try await rec.start(options: options, captureSize: pipeline.captureSize)
        pipeline.isRecording.store(true, ordering: .sequentiallyConsistent)
        return start
    }

    /// Stops the active recording session and returns the output file URI.
    ///
    /// - Throws: `EngineError.notOpen` if no recording is active or the engine is not open.
    public func stopRecording() async throws -> String {
        guard let rec = recording,
            let pipeline = metalPipeline,
            let session = cameraSession
        else { throw EngineError.notOpen }
        pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
        let uri = await rec.stop(reason: .user)
        try? await session.setPreviewFrameRateRange()
        self.recording = nil
        pipeline.onEncodedBufferReady = nil
        return uri
    }

    /// Pauses capture and finalizes any active recording synchronously on the engine actor.
    ///
    /// scaffolding:10:synchronous-drain-pause — pause() during recording runs finalize
    /// synchronously on the engine actor. There is NO UIApplication.beginBackgroundTask
    /// wrapper, so the drain cannot survive backgrounding. Stage 12 retires this scaffold
    /// by adding the background-task assertion around the same finalize path.
    public func pause() async throws {
        if let rec = recording, let pipeline = metalPipeline {
            pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
            _ = await rec.stop(reason: .pause)
            self.recording = nil
            pipeline.onEncodedBufferReady = nil
        }
        await cameraSession?.stopRunningAsync()
        publishState(.paused)
    }

    /// Resumes capture after a pause().
    ///
    /// - Throws: `EngineError.notOpen` if the engine has not been opened.
    public func resume() async throws {
        guard isOpen, let session = cameraSession else { throw EngineError.notOpen }
        await session.startRunningAsync()
        publishState(.streaming)
    }

    func publishRecordingStateFromHook(_ s: RecordingState) {
        publishRecordingState(s)
    }

    func onEncodedBufferReady(_ buffer: CVPixelBuffer, pts: CMTime) async {
        guard let rec = recording else { return }
        _ = await rec.submitEncodedBuffer(buffer, pts: pts)
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

    private func publishState(_ state: SessionState) {
        stateContinuationBox.withLock { $0?.yield(state) }
    }

    // MARK: - Stage 09 internal hooks

    func publishStateAsync(_ s: SessionState) { publishState(s) }
    func publishErrorAsync(_ e: CameraError) { publishError(e) }
    func disarmWatchdogsAsync() { watchdogs?.disarmAll() }

    private func startAEMonitor(device: any CaptureDeviceProviding) {
        aeMonitorTask?.cancel()
        let clock = self.clock
        let tokenAtStart = sessionToken.load(ordering: .acquiring)
        aeMonitorTask = Task { [weak self] in
            var searchStartMs: UInt64?
            for await snap in device.snapshotStream() {
                if Task.isCancelled { return }
                if snap.isAdjustingExposure {
                    if searchStartMs == nil { searchStartMs = clock.nowMs() }
                } else {
                    searchStartMs = nil
                }
                if let start = searchStartMs,
                    clock.nowMs() >= start + UInt64(Constants.aeConvergenceTimeoutMs)
                {
                    guard let self,
                        self.sessionToken.load(ordering: .acquiring) == tokenAtStart
                    else { return }
                    let err = CameraError(
                        code: .aeConvergenceTimeout,
                        message: "AE searching > \(Constants.aeConvergenceTimeoutMs)ms",
                        isFatal: false
                    )
                    await self.publishErrorAsync(err)
                    searchStartMs = nil
                }
            }
        }
    }

    func handleWatchdogFire(_ fire: WatchdogFire) async {
        let liveToken = sessionToken.load(ordering: .acquiring)
        guard fire.armedSessionToken == liveToken else { return }
        let msg = "\(fire.kind.messagePrefix) no frame in \(fire.thresholdMs)ms"
        let err = CameraError(code: .frameStall, message: msg, isFatal: false)
        publishError(err)
        if fire.kind == .capture {
            await recovery?.enterRecovery(error: err)
        }
    }

    func noteCaptureFailure(message: String) async {
        await recovery?.noteHardwareFailure(message: message)
    }

    func noteFrameDelivered() async {
        let now = clock.nowMs()
        if fpsWindowStartMs == 0 {
            fpsWindowStartMs = now
            fpsFrameCount = 1
            return
        }
        fpsFrameCount += 1
        if fpsFrameCount >= Constants.fpsMeasurementWindowFrames {
            let elapsedMs = max(1, now - fpsWindowStartMs)
            let fps = Double(fpsFrameCount) * 1000.0 / Double(elapsedMs)
            if fps < Constants.fpsDegradedThresholdFps {
                fpsLowStreak += 1
                if fpsLowStreak >= Constants.fpsDegradedStreakCount {
                    publishError(
                        CameraError(
                            code: .fpsDegraded,
                            message: String(
                                format: "%.1f fps over %d-frame window", fps, Constants.fpsMeasurementWindowFrames),
                            isFatal: false
                        ))
                    fpsLowStreak = 0
                }
            } else {
                fpsLowStreak = 0
            }
            fpsWindowStartMs = now
            fpsFrameCount = 0
        }
        await recovery?.noteHardwareSuccess()
    }

    func resetFromTerminal() async {
        await close()
    }

    func onSessionEvent(_ event: CameraSession.SessionEvent) async {
        switch event {
        case .cameraInUseBegan:
            let err = CameraError(
                code: .cameraInUse,
                message: "videoDeviceInUseByAnotherClient",
                isFatal: true
            )
            watchdogs?.disarmAll()
            await recovery?.cancelPendingRetry()
            publishError(err)
            publishState(.error)
        case .cameraInUseEnded:
            // D-14 + OQ-04: return to .closed; host must call open() again.
            await resetFromTerminal()
        case .runtimeError(let msg):
            let err = CameraError(code: .cameraAccessError, message: msg, isFatal: false)
            publishError(err)
            await recovery?.enterRecovery(error: err)
        case .otherInterruption:
            break
        }
    }

    /// Test-only: inject a session event directly (avoids needing avSession reference).
    func _postSessionEventForTest(_ event: CameraSession.SessionEvent) async {
        await onSessionEvent(event)
    }
}
