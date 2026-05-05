import OSLog
import SwiftUI

private let scenePhaseLog = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")

/// Top-level orchestrator for the SwiftUI camera UI.
///
/// ADR-21 pattern (decomposed): UI state is owned by `@Observable @MainActor`
/// view models; actor-isolated engine state flows in via async `for await` loops
/// on the engine's streams. The parent owns engine lifecycle + cross-cutting
/// session-level state (`sessionState`, `capabilities`, `lastFrameResult`,
/// `captureResult`); per-feature state lives on the corresponding child VM —
/// see `display`, `recording`, `hardware`, `processing`, `calibration`, `errors`.
///
/// `handleScenePhase(_:)` enforces D-06 strict gating: `.inactive` always closes
/// the GPU submission gate regardless of `UIApplication.applicationState`;
/// `.background` calls `backgroundSuspend`; `.active` reopens the gate (and
/// calls `backgroundResume` first if returning from `.background`).
@Observable @MainActor
final class ViewModel {

    // MARK: - Session-level state owned by parent

    var sessionState: SessionState = .closed
    var capabilities: SessionCapabilities?
    var lastFrameResult: FrameResult?
    var captureResult: Result<StillCaptureOutput, Error>?
    var error: EngineError?

    // MARK: - Engine + child VMs

    let engine: CameraEngine

    @ObservationIgnored let display: DisplayViewModel
    @ObservationIgnored let recording: RecordingViewModel
    @ObservationIgnored let hardware: HardwareControlsViewModel
    @ObservationIgnored let processing: ProcessingViewModel
    @ObservationIgnored let calibration: CalibrationViewModel
    @ObservationIgnored let errors: ErrorPresenterViewModel

    // MARK: - Subscription tasks (parent-owned)

    @ObservationIgnored private var frameResultTask: Task<Void, Never>?
    @ObservationIgnored private var bannerDismissTask: Task<Void, Never>?

    // MARK: - ScenePhase tracking (ADR-09, D-06, 08-ui.md §scenePhase wiring)

    /// Tracks the previous scene phase so `.active` can distinguish a return
    /// from `.background` (needs `backgroundResume`) from a return from
    /// `.inactive` (gate-reopen only).
    private var previousPhase: ScenePhase = .active

    /// True when the app entered `.background` and has not yet returned to `.active`.
    ///
    /// iOS transitions `.background → .inactive → .active` on restore, so
    /// `previousPhase == .background` is never true at the `.active` site.
    /// This flag survives the intermediate `.inactive` hop.
    private var cameFromBackground = false

    // MARK: - Init

    init() {
        let engine = CameraEngine()
        self.engine = engine
        self.display = DisplayViewModel(engine: engine)
        self.recording = RecordingViewModel(engine: engine)
        self.hardware = HardwareControlsViewModel(engine: engine)
        self.processing = ProcessingViewModel(engine: engine)
        self.calibration = CalibrationViewModel(engine: engine, processingVM: processing)
        self.errors = ErrorPresenterViewModel(engine: engine)
    }

    /// Convenience derived value for the view's `disabled` and `opacity` modifiers.
    var controlEnablement: ControlEnablement {
        ControlEnablement(sessionState: sessionState, recordingState: recording.recordingState)
    }

    // MARK: - Lifecycle

    /// Open the engine, start every child VM, then subscribe to stateStream.
    ///
    /// Order:
    ///   1. `engine.open()` (yields `SessionCapabilities`).
    ///   2. `display.attachAfterOpen()` — grab session-stable Metal textures.
    ///   3. Start each child VM in parallel (each subscribes to its own engine stream).
    ///   4. Subscribe to `frameResultStream` for slider readback.
    ///   5. `for await state in engine.stateStream()` — keeps the parent's
    ///      `sessionState` mirror in sync until the stream finishes.
    func start() async {
        do {
            let caps = try await engine.open()
            capabilities = caps
            await display.attachAfterOpen()
            await hardware.start()
            await processing.start()
            await recording.start()
            await errors.start()
            dumpCapabilities(caps)
        } catch let e as EngineError {
            error = e
            sessionState = .error
            return
        } catch {
            sessionState = .error
            return
        }

        frameResultTask = Task { [weak self] in
            guard let engine = self?.engine else { return }
            for await r in await engine.frameResultStream() {
                guard let self else { return }
                await MainActor.run { self.lastFrameResult = r }
            }
        }

        var needsPostRecoverySetup = false
        for await state in await engine.stateStream() {
            sessionState = state
            if state == .recovering { needsPostRecoverySetup = true }
            if state == .streaming && needsPostRecoverySetup {
                needsPostRecoverySetup = false
                frameResultTask?.cancel()
                frameResultTask = nil
                frameResultTask = Task { [weak self] in
                    guard let engine = self?.engine else { return }
                    for await r in await engine.frameResultStream() {
                        guard let self else { return }
                        await MainActor.run { self.lastFrameResult = r }
                    }
                }
                await display.detachBeforeClose()
                await display.attachAfterOpen()
            }
        }
    }

    /// Cancel parent subscriptions, stop every child VM, and close the engine.
    func stop() async {
        frameResultTask?.cancel()
        frameResultTask = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        await recording.stop()
        await hardware.stop()
        await processing.stop()
        await errors.stop()
        await display.detachBeforeClose()
        await engine.close()
    }

    // MARK: - Recovery (08-ui.md §error display; parent owns lifecycle orchestration)

    /// Recover from a fatal error: tear down display, close + reopen the
    /// engine, re-attach display, restart `frameResultTask`.
    ///
    /// Child VM stream subscriptions (state / error / recordingState) survive
    /// close+reopen because their AsyncStreams are cached on the engine actor;
    /// only `frameResultContinuation.finish()` runs on close (see
    /// `CameraEngine.close()`). The display textures and frame-result task,
    /// on the other hand, are bound to the prior session — those need
    /// re-attach.
    func retryFromFatal() async {
        errors.dismissFatal()
        frameResultTask?.cancel()
        frameResultTask = nil
        await display.detachBeforeClose()
        await engine.close()
        do {
            let caps = try await engine.open()
            capabilities = caps
            await display.attachAfterOpen()
            frameResultTask = Task { [weak self] in
                guard let engine = self?.engine else { return }
                for await r in await engine.frameResultStream() {
                    guard let self else { return }
                    await MainActor.run { self.lastFrameResult = r }
                }
            }
        } catch let e as EngineError {
            error = e
            sessionState = .error
        } catch {
            sessionState = .error
        }
    }

    // MARK: - Capture (parent-owned because banner is a session-level UI element)

    func captureImage() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.engine.captureImage()
                self.captureResult = .success(output)
            } catch {
                self.captureResult = .failure(error)
            }
            self.bannerDismissTask?.cancel()
            self.bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.captureResult = nil }
            }
        }
    }

    // MARK: - ScenePhase handler (08-ui.md §scenePhase wiring, 02-concurrency.md §Sequence A)

    /// Phase mapping per D-06 strict policy.
    ///
    ///   `.inactive`   → close gate; drain last submitted frame.
    ///   `.background` → `backgroundSuspend()` (gate-close + drain + session stop).
    ///   `.active`     → re-open gate; if returning from `.background`,
    ///                   `backgroundResume()` first.
    func handleScenePhase(_ phase: ScenePhase) async {
        let prev = String(describing: self.previousPhase)
        let next = String(describing: phase)
        scenePhaseLog.notice("scenePhase: \(prev, privacy: .public) → \(next, privacy: .public)")
        switch phase {
        case .inactive:
            await engine.setGate(false)
            await engine.drainSubmittedFrame()
            scenePhaseLog.notice("scenePhase inactive: gate closed, drain complete")

        case .background:
            cameFromBackground = true
            await engine.backgroundSuspend()
            scenePhaseLog.notice("scenePhase background: backgroundSuspend complete")

        case .active:
            if cameFromBackground {
                cameFromBackground = false
                await engine.backgroundResume()
            }
            await engine.setGate(true)
            let prevActive = String(describing: self.previousPhase)
            scenePhaseLog.notice("scenePhase active: gate open (prevPhase=\(prevActive, privacy: .public))")

        @unknown default:
            break
        }
        previousPhase = phase
    }

    // MARK: - Capabilities dump (debug helper, written to Documents/capabilities.txt)

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
}
