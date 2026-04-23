import CameraKitInterop
import CoreMedia
import Metal
import OSLog
import SwiftUI

private let scenePhaseLog = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")

/// Main-actor view model for CameraView.
///
/// ADR-21: UI state is owned by @Observable @MainActor ViewModel; actor-isolated
/// engine state flows in via an async for-await loop on stateStream().
/// ADR-09 / D-06: scenePhase transitions are handled by handleScenePhase(_:), which
/// drives the GPU submission gate and session lifecycle. Strict policy: .inactive
/// always gates regardless of UIApplication.applicationState.
@Observable @MainActor
final class ViewModel {

    // MARK: - Observable state

    var sessionState: SessionState = .closed
    var capabilities: SessionCapabilities?
    var error: EngineError?
    var currentSettings: CameraSettings = CameraSettings()
    var deviceSnapshot: DeviceStateSnapshot?
    var lastFrameResult: FrameResult?
    var currentProcessing: ProcessingParameters = .identity

    // MARK: - Texture handoff

    /// Set once after open() succeeds.
    ///
    /// Read by MTKViewCoordinator.draw(in:) on the
    /// Metal thread. @ObservationIgnored skips @Observable's tracking rewrite so the
    /// property is a plain stored field; nonisolated(unsafe) allows cross-isolation reads
    /// (naturalTex is written exactly once per session, before the coordinator calls draw).
    @ObservationIgnored
    nonisolated(unsafe) var naturalTex: MTLTexture?

    @ObservationIgnored
    nonisolated(unsafe) var processedTex: MTLTexture?

    // MARK: - Stage 06 — Debug overlay + tracker thumbnail

    struct DebugOverlay: Equatable {
        var frameNumber: UInt64
        var captureTimeMs: Int64
        // Stage 08 HITL — most-recent Canny edge pixel count from tracker stream.
        var edgeCount: UInt32?
    }

    var debugOverlay: DebugOverlay?
    var debugTrackerSubscribed: Bool = false
    var captureResult: Result<StillCaptureOutput, Error>? = nil
    var currentError: CameraError?

    @ObservationIgnored private var bannerDismissTask: Task<Void, Never>?
    @ObservationIgnored private var errorConsumerTask: Task<Void, Never>?

    @ObservationIgnored
    nonisolated(unsafe) var trackerTex: MTLTexture?

    @ObservationIgnored private var naturalSubscriberTask: Task<Void, Never>?
    @ObservationIgnored private var trackerSubscriberTask: Task<Void, Never>?

    // Stage 08 HITL — Canny stub registered on tracker stream (ADR-29).
    @ObservationIgnored private let cannyStub: CppCannyStub = CppCannyStub()
    @ObservationIgnored private var cannyToken: ConsumerToken?

    // MARK: - Engine

    let engine: CameraEngine

    // MARK: - ScenePhase tracking (ADR-09, D-06, 08-ui.md §scenePhase wiring)

    /// Tracks the previous scene phase so handleScenePhase can distinguish
    /// .active-from-.inactive (gate re-open only) from .active-from-.background
    /// (backgroundResume + gate re-open).
    private var previousPhase: ScenePhase = .active

    private var frameResultTask: Task<Void, Never>?
    private var deviceSnapshotTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        engine = CameraEngine()
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            let caps = try await engine.open()
            capabilities = caps
            // Grab naturalTex once after open — it's stable for the session lifetime.
            naturalTex = engine.currentTexture()
            processedTex = engine.currentProcessedTexture()
            // Pre-populate slider state from persisted ProcessingParameters
            // (07-settings.md §Load path: nonisolated accessor available before open()).
            if let persisted = engine.getPersistedProcessingParameters() {
                currentProcessing = persisted
            }
            // Seed slider state from whatever open() restored from persistence.
            if let restored = await engine.currentSettingsSnapshot() {
                currentSettings = restored
            }
            // Dump capabilities to Documents/capabilities.json for inspection.
            dumpCapabilities(caps)
            errorConsumerTask = Task { [weak self] in
                guard let self else { return }
                for await err in await self.engine.errorStream() {
                    await MainActor.run { self.currentError = err }
                }
            }
        } catch let e as EngineError {
            error = e
            sessionState = .error
        } catch {
            sessionState = .error
        }

        // Register Canny stub on tracker stream for HITL 08:external-canny-stub-runs-on-device.
        #if DEBUG
        let cbs = PixelSinkCallbacks(
            onFrame: cannyStub.onFrameCallback(),
            onOverwrite: { _, _ in },
            onError: nil,
            context: cannyStub.nativeContext)
        cannyToken = try? await engine.consumers.registerCallback(stream: .tracker, callbacks: cbs)
        #endif

        frameResultTask = Task { [weak self] in
            guard let engine = await self?.engine else { return }
            for await r in await engine.frameResultStream() {
                guard let self else { return }
                await MainActor.run { self.lastFrameResult = r }
            }
        }

        startDebugOverlay()

        // Observe state stream (ADR-22).
        for await state in await engine.stateStream() {
            sessionState = state
        }
    }

    func stop() async {
        frameResultTask?.cancel()
        frameResultTask = nil
        deviceSnapshotTask?.cancel()
        deviceSnapshotTask = nil
        naturalSubscriberTask?.cancel()
        naturalSubscriberTask = nil
        trackerSubscriberTask?.cancel()
        trackerSubscriberTask = nil
        errorConsumerTask?.cancel()
        errorConsumerTask = nil
        #if DEBUG
        if let t = cannyToken {
            await engine.consumers.unregister(token: t)
            cannyToken = nil
        }
        #endif
        await engine.close()
    }

    // MARK: - Debug overlay helpers (Stage 06, #if DEBUG only)

    func startDebugOverlay() {
        #if DEBUG
        naturalSubscriberTask?.cancel()
        naturalSubscriberTask = Task { [weak self] in
            guard let self else { return }
            for await fs in await self.engine.consumers.subscribe(stream: .natural) {
                // Update at ~3 fps — every 10th frame — to avoid 30 SwiftUI re-renders/sec.
                // The MTKView preview runs GPU-direct via nonisolated(unsafe) mailboxes;
                // only the text overlay needs MainActor.
                guard fs.frameNumber % 10 == 0 else { continue }
                let processed = self.cannyStub.processedCount
                let edgeCount: UInt32? =
                    processed > 0 ? self.cannyStub.edgeCount(at: Int((processed - 1) % 64)) : nil
                let overlay = DebugOverlay(
                    frameNumber: fs.frameNumber,
                    captureTimeMs: Int64(CMTimeGetSeconds(fs.captureTime) * 1000),
                    edgeCount: edgeCount)
                await MainActor.run { self.debugOverlay = overlay }
            }
        }
        #endif
    }

    func captureImage() {
        Task {
            do {
                let output = try await engine.captureImage()
                captureResult = .success(output)
            } catch {
                captureResult = .failure(error)
            }
            bannerDismissTask?.cancel()
            bannerDismissTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                captureResult = nil
            }
        }
    }

    func toggleDebugTrackerSubscription() async {
        debugTrackerSubscribed.toggle()
        if debugTrackerSubscribed {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = Task { [weak self] in
                guard let self else { return }
                for await _ in await self.engine.consumers.subscribe(stream: .tracker) {
                    let tex = self.engine.currentTrackerTexture()
                    await MainActor.run { self.trackerTex = tex }
                }
                await MainActor.run { self.trackerTex = nil }
            }
        } else {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = nil
            trackerTex = nil
        }
    }

    // MARK: - ScenePhase handler (08-ui.md §scenePhase wiring, 02-concurrency.md §Sequence A)

    /// Called by CameraView via .task(id: scenePhase) on every scene phase change.
    ///
    /// Phase mapping (D-06 strict policy):
    ///   .inactive   → close gate; drain last submitted frame.
    ///   .background → backgroundSuspend() (gate-close + drain + session stop).
    ///   .active     → re-open gate; if returning from .background, backgroundResume() first.
    func handleScenePhase(_ phase: ScenePhase) async {
        scenePhaseLog.info("scenePhase: \(String(describing: self.previousPhase)) → \(String(describing: phase))")
        switch phase {
        case .inactive:
            await engine.setGate(false)
            await engine.drainSubmittedFrame()
            scenePhaseLog.info("scenePhase inactive: gate closed, drain complete")

        case .background:
            await engine.backgroundSuspend()
            scenePhaseLog.info("scenePhase background: backgroundSuspend complete")

        case .active:
            if previousPhase == .background {
                await engine.backgroundResume()
            }
            await engine.setGate(true)
            scenePhaseLog.info("scenePhase active: gate open (prevPhase=\(String(describing: self.previousPhase)))")

        @unknown default:
            break
        }
        previousPhase = phase
    }

    // MARK: - Settings bindings

    func updateISO(_ iso: Int) async {
        var delta = CameraSettings()
        delta.isoMode = .manual
        delta.iso = iso
        await applyDelta(delta)
    }

    func updateShutterNs(_ ns: Int64) async {
        var delta = CameraSettings()
        delta.exposureMode = .manual
        delta.exposureTimeNs = ns
        await applyDelta(delta)
    }

    func updateFocus(_ d: Double) async {
        var delta = CameraSettings()
        delta.focusMode = .manual
        delta.focusDistance = d
        await applyDelta(delta)
    }

    func updateZoom(_ r: Double) async {
        var delta = CameraSettings()
        delta.zoomRatio = r
        await applyDelta(delta)
    }

    private func dumpCapabilities(_ caps: SessionCapabilities) {
        var lines: [String] = [
            "SessionCapabilities",
            "===================",
            "isoRange:                  \(caps.isoRange.lowerBound) – \(caps.isoRange.upperBound)",
            "exposureDurationRangeNs:   \(caps.exposureDurationRangeNs.lowerBound) – \(caps.exposureDurationRangeNs.upperBound)",
            "  → min shutter:           \(String(format: "%.4f", Double(caps.exposureDurationRangeNs.lowerBound) / 1_000_000)) ms"
                + "  (1/\(Int((1_000_000_000.0 / Double(caps.exposureDurationRangeNs.lowerBound)).rounded())) s)",
            "  → max shutter:           \(String(format: "%.1f", Double(caps.exposureDurationRangeNs.upperBound) / 1_000_000)) ms"
                + "  (1/\(String(format: "%.2f", 1_000_000_000.0 / Double(caps.exposureDurationRangeNs.upperBound))) s)",
            "activeCaptureResolution:   \(caps.activeCaptureResolution.width) × \(caps.activeCaptureResolution.height)",
            "activeCropRegion:          x=\(caps.activeCropRegion.x) y=\(caps.activeCropRegion.y)"
                + " w=\(caps.activeCropRegion.width) h=\(caps.activeCropRegion.height)",
            "streamPixelFormat:         \(caps.streamPixelFormat)",
            "supportedSizes:",
        ]
        for s in caps.supportedSizes {
            lines.append("  \(s.width) × \(s.height)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("capabilities.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - ProcessingParameters update path (08-ui.md §Color calibration sidebar)

    func updateProcessing(_ next: ProcessingParameters) async {
        currentProcessing = next
        await engine.setProcessingParameters(next)
    }

    func resetProcessing() async {
        await updateProcessing(.identity)
    }

    private func applyDelta(_ delta: CameraSettings) async {
        do {
            try await engine.updateSettings(delta)
            currentSettings = delta.merging(onto: currentSettings)
        } catch let e as EngineError {
            self.error = e
        } catch {
            // non-EngineError — ignore
        }
    }
}
