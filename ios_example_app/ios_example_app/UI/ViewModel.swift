import CameraKit
import SwiftUI

/// Top-level orchestrator for the SwiftUI camera UI.
///
/// ADR-21 pattern (decomposed): UI state is owned by `@Observable @MainActor`
/// view models; actor-isolated engine state flows in via async `for await` loops
/// on the engine's streams. The parent owns engine lifecycle + cross-cutting
/// session-level state (`sessionState`, `capabilities`, `lastFrameResult`,
/// `captureConfirmation`); per-feature state lives on the corresponding child VM —
/// see `display`, `recording`, `hardware`, `processing`, `calibration`, `errors`.
///
/// `handleScenePhase(_:)` is a 1:1 forward of SwiftUI `ScenePhase` to
/// `engine.setLifecyclePhase(_:)` (mapped to `AppLifecyclePhase`). CameraKit owns
/// all reconciliation — GPU gate, session start/stop, watchdogs, `SessionState`
/// label — so the host neither gates nor suspends/resumes directly;
/// `setLifecyclePhase` never throws and the latest call wins.
@Observable @MainActor
final class ViewModel {

    // MARK: - Session-level state owned by parent

    var sessionState: SessionState = .closed
    var capabilities: SessionCapabilities?
    var lastFrameResult: FrameResult?

    /// Last successful still-capture — drives the transient bottom confirmation
    /// banner ("Image saved: …").
    ///
    /// Success-only: capture *failures* route to `errors` (the unified top-toast
    /// surface, shared with recording-failure errors), not here.
    var captureConfirmation: StillCaptureOutput?

    /// Dev-harness flag: true when the fixed 1440×1440 center crop is active
    /// (drives the Crop/Full bottom-bar button label). Toggled by `toggleCenterCrop`.
    var isCenterCropped = false

    #if DEBUG
    /// Latest per-window frame-delivery stats (D-11) — drives the long-press
    /// debug overlay.
    ///
    /// DEBUG-only; the production UI never surfaces this.
    var frameDeliveryStats: FrameDeliveryStats?
    #endif

    /// Cached supported capture resolutions, populated once at `engine.open()`.
    ///
    /// The set of supported sizes is a property of the active `AVCaptureDevice`
    /// and does not change during a session, so the resolution picker reads
    /// from this stable slot instead of `capabilities?.supportedSizes` —
    /// `capabilities` is rebuilt by `setResolution` to update
    /// `activeCaptureResolution`, and SwiftUI would otherwise rebuild the
    /// Menu's `ForEach` content tree on every resolution change.
    /// `@ObservationIgnored` because the value never changes after open.
    @ObservationIgnored var supportedSizesCache: [Size] = []

    /// Per-resolution frame-rate ranges from the last `open()` — drives the fps
    /// picker's valid-value filtering. Populated at open; stable per device.
    @ObservationIgnored var supportedFrameRatesCache: [FrameRateRange] = []

    /// Selected target frame rate (open-time). `setTargetFps` reopens the engine to
    /// apply a change (configurable-frame-rate: fps is open-time only).
    var selectedFps: Int = 30

    // MARK: - Engine + child VMs

    /// Open configuration for this demo harness.
    ///
    /// The app locks its UI to landscape-left (see `OrientationLock`), so it
    /// rotates the delivered capture buffers 180° from the package's default
    /// landscape-right convention to keep the preview/stills upright. This is a
    /// per-open override — other CameraKit consumers (e.g. the Flutter plugin)
    /// keep the default 0° and are unaffected. `targetFps` follows the picker.
    ///
    /// `captureResolution` is pinned to the currently active resolution once open
    /// (`capabilities` is `nil` before the first open, so the initial open still
    /// gets the package default — the largest 4:3). This keeps an fps change
    /// (`setTargetFps`, which reopens) or a fatal retry from silently jumping the
    /// resolution back to the 4:3 default.
    private var openConfiguration: OpenConfiguration {
        OpenConfiguration(
            captureResolution: capabilities?.activeCaptureResolution,
            targetFps: selectedFps,
            captureOrientationAngleDeg: 180)
    }

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

    #if DEBUG
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    #endif

    // MARK: - ScenePhase tracking (ADR-09, D-06, 08-ui.md §scenePhase wiring)

    /// Previous scene phase — diagnostics only (the `scenePhase: prev → next` log).
    ///
    /// The engine reconciles from the current phase alone (latest call wins), so
    /// the host no longer needs the previous phase to sequence resume; it survives
    /// purely for the transition log.
    private var previousPhase: ScenePhase = .active

    // MARK: - Init

    init() {
        let engine = CameraEngine(initialPhase: .background)
        self.engine = engine
        self.display = DisplayViewModel(engine: engine)
        let errors = ErrorPresenterViewModel(engine: engine)
        self.errors = errors
        self.recording = RecordingViewModel(engine: engine, errorPresenter: errors)
        self.hardware = HardwareControlsViewModel(engine: engine)
        self.processing = ProcessingViewModel(engine: engine)
        self.calibration = CalibrationViewModel(engine: engine, processingVM: processing)
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
            let caps = try await engine.open(configuration: openConfiguration)
            supportedSizesCache = caps.supportedSizes
            supportedFrameRatesCache = caps.supportedFrameRates
            capabilities = caps
            await display.attachAfterOpen()
            await hardware.start()
            await processing.start()
            await recording.start()
            await errors.start()
            await dumpCapabilities(caps)
        } catch {
            sessionState = .error
            return
        }

        frameResultTask = makeFrameResultTask()
        #if DEBUG
        metricsTask = makeMetricsTask()
        #endif

        var needsPostRecoverySetup = false
        for await state in await engine.stateStream() {
            sessionState = state
            if state == .recovering { needsPostRecoverySetup = true }
            if state == .streaming && needsPostRecoverySetup {
                needsPostRecoverySetup = false
                frameResultTask?.cancel()
                frameResultTask = nil
                frameResultTask = makeFrameResultTask()
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
        #if DEBUG
        metricsTask?.cancel()
        metricsTask = nil
        #endif
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
            let caps = try await engine.open(configuration: openConfiguration)
            supportedSizesCache = caps.supportedSizes
            supportedFrameRatesCache = caps.supportedFrameRates
            capabilities = caps
            await display.attachAfterOpen()
            frameResultTask = makeFrameResultTask()
            #if DEBUG
            metricsTask?.cancel()
            metricsTask = makeMetricsTask()
            #endif
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
                self.captureConfirmation = output
                self.bannerDismissTask?.cancel()
                self.bannerDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.captureConfirmation = nil }
                }
            } catch {
                self.errors.present(
                    CameraError(
                        code: .captureFailure,
                        message: "Capture failed: \(error)",
                        isFatal: false
                    ))
            }
        }
    }

    /// Dev-harness hook for the ISP one-shot natural capture (AVCapturePhotoOutput
    /// → Metal grade → TIFF). Mirrors `captureImage`; lets HITL exercise the
    /// natural path the library exposes via `engine.captureNaturalPicture()`.
    func captureNaturalPicture() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.engine.captureNaturalPicture()
                self.captureConfirmation = output
                self.bannerDismissTask?.cancel()
                self.bannerDismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.captureConfirmation = nil }
                }
            } catch {
                self.errors.present(
                    CameraError(
                        code: .captureFailure,
                        message: "Natural capture failed: \(error)",
                        isFatal: false
                    ))
            }
        }
    }

    /// Dev-harness toggle to exercise the P2a true-crop path and cropped natural
    /// capture: applies a fixed 1440×1440 center crop of the active sensor frame,
    /// or resets to the full frame. Origins are rounded to even pixels (4:2:0 chroma).
    func toggleCenterCrop() {
        Task { [weak self] in
            guard let self, let caps = self.capabilities else { return }
            let sensor = caps.activeCaptureResolution
            do {
                if self.isCenterCropped {
                    try await self.engine.setCropRegion(
                        Rect(x: 0, y: 0, width: sensor.width, height: sensor.height))
                    self.isCenterCropped = false
                    CameraKitLog.notice(.engine, "[crop] reset to full \(sensor.width)x\(sensor.height)")
                } else {
                    let cropW = 1440
                    let cropH = 1440
                    var x = max(0, (sensor.width - cropW) / 2)
                    var y = max(0, (sensor.height - cropH) / 2)
                    x -= x % 2
                    y -= y % 2
                    try await self.engine.setCropRegion(
                        Rect(x: x, y: y, width: cropW, height: cropH))
                    self.isCenterCropped = true
                    CameraKitLog.notice(.engine, "[crop] applied center 1440x1440 at (\(x),\(y))")
                }
            } catch {
                self.errors.present(
                    CameraError(
                        code: .captureFailure,
                        message: "Crop toggle failed: \(error)",
                        isFatal: false
                    ))
            }
        }
    }

    // MARK: - Frame-result subscription

    /// Subscribes to `engine.frameResultStream()` and writes `lastFrameResult`.
    ///
    /// `engine.frameResultStream()` emits per frame (30 Hz). We skip writes
    /// where the new `FrameResult` equals the last published one — that
    /// drops to zero writes for static scenes (engine still emits every
    /// frame even when nothing changed). Changing scenes pass through at
    /// the camera's full 30 Hz so slider readback feels smooth.
    ///
    /// No time-based throttle: when an earlier 100 ms (10 Hz) cap was in
    /// place, the ISO/Shutter/Focus readback text jumped in 100 ms chunks
    /// during slow slider drags. The picker stays responsive because
    /// `ExpandedSliderBar` (the only consumer of `lastFrameResult`) is a
    /// separate `View` struct — its 30 Hz re-renders are local to that
    /// sub-view and don't invalidate `CameraView.body`.
    private func makeFrameResultTask() -> Task<Void, Never> {
        Task { [weak self] in
            guard let engine = self?.engine else { return }
            var lastPublished: FrameResult? = nil
            for await r in await engine.frameResultStream() {
                guard let self else { return }
                if r == lastPublished { continue }
                lastPublished = r
                await MainActor.run { self.lastFrameResult = r }
            }
        }
    }

    #if DEBUG
    /// DEBUG metrics overlay: `metricsStream()` was removed with the C-ABI path
    /// (frame-delivery-rework). Stubbed to a no-op; `frameDeliveryStats` stays nil.
    private func makeMetricsTask() -> Task<Void, Never> {
        Task {}
    }
    #endif

    // MARK: - Frame-rate change (open-time only → close + reopen)

    /// Apply a new target frame rate by reopening the engine.
    ///
    /// fps is fixed at open (configurable-frame-rate), so a change is a close +
    /// reopen with the new `OpenConfiguration.targetFps` — the same dance as
    /// `retryFromFatal`. If the fps isn't valid at the current resolution the reopen
    /// throws and the session drops to `.error`.
    func setTargetFps(_ fps: Int) {
        guard fps != selectedFps else { return }
        let previousFps = selectedFps
        selectedFps = fps
        Task { [weak self] in
            guard let self else { return }
            CameraKitLog.notice(.engine, "[fps] applying targetFps=\(fps) via reopen")
            self.frameResultTask?.cancel()
            self.frameResultTask = nil
            await self.display.detachBeforeClose()
            await self.engine.close()
            do {
                let caps = try await self.engine.open(configuration: self.openConfiguration)
                self.supportedSizesCache = caps.supportedSizes
                self.supportedFrameRatesCache = caps.supportedFrameRates
                self.capabilities = caps
                await self.display.attachAfterOpen()
                self.frameResultTask = self.makeFrameResultTask()
                #if DEBUG
                self.metricsTask?.cancel()
                self.metricsTask = self.makeMetricsTask()
                #endif
                CameraKitLog.notice(.engine, "[fps] applied targetFps=\(fps)")
            } catch {
                // Roll the picker back to the last working fps so it reflects reality
                // (an unsupported (resolution, fps) throws settingsConflict here).
                CameraKitLog.error(
                    .engine, "[fps] setTargetFps(\(fps)) reopen threw: \(error) — reverting to \(previousFps)")
                self.selectedFps = previousFps
                self.sessionState = .error
            }
        }
    }

    // MARK: - Resolution change (parent-owned because it mutates session capabilities)

    /// Switch active capture resolution to one of `capabilities.supportedSizes`.
    ///
    /// Fires-and-forgets the engine call; on success refreshes the local
    /// `capabilities` mirror so the bottom-bar label reflects the new
    /// `activeCaptureResolution`. `CameraSession.reconfigureSize` matches
    /// exactly on width+height, so the user-tapped value is authoritative.
    func setResolution(_ size: Size) {
        Task { [weak self] in
            guard let self else { return }
            if let current = self.capabilities?.activeCaptureResolution, current == size {
                CameraKitLog.notice(.engine, "[resolution] tap \(size.width)x\(size.height) is current — no-op")
                return
            }
            CameraKitLog.notice(.engine, "[resolution] applying \(size.width)x\(size.height)")
            do {
                try await self.engine.setResolution(size: size)
                if let caps = self.capabilities {
                    self.capabilities = SessionCapabilities(
                        supportedSizes: caps.supportedSizes,
                        previewTextureId: caps.previewTextureId,
                        activeCaptureResolution: size,
                        activeCropRegion: caps.activeCropRegion,
                        streamPixelFormat: caps.streamPixelFormat,
                        isoRange: caps.isoRange,
                        exposureDurationRangeNs: caps.exposureDurationRangeNs,
                        focusRange: caps.focusRange,
                        zoomRange: caps.zoomRange,
                        evCompensationRange: caps.evCompensationRange,
                        trackerResolution: caps.trackerResolution
                    )
                }
                CameraKitLog.notice(.engine, "[resolution] applied \(size.width)x\(size.height)")
            } catch let e as EngineError {
                CameraKitLog.error(.engine, "[resolution] EngineError: \(e)")
            } catch {
                CameraKitLog.error(.engine, "[resolution] setResolution threw: \(error)")
            }
        }
    }

    // MARK: - ScenePhase handler (08-ui.md §scenePhase wiring, 02-concurrency.md §Sequence A)

    /// Forward the SwiftUI scene phase to the engine, which reconciles all
    /// hardware (gate, session, watchdogs, label) from the phase alone.
    ///
    /// The host no longer sequences gate / drain / suspend / resume — that policy
    /// moved into `CameraEngine.setLifecyclePhase` / `reconcile` (single owner).
    /// This is a 1:1 forward; `setLifecyclePhase` never throws and the latest call
    /// wins, so the intermediate `.background → .inactive → .active` restore needs
    /// no `cameFromBackground` flag.
    func handleScenePhase(_ phase: ScenePhase) async {
        let prev = String(describing: self.previousPhase)
        let next = String(describing: phase)
        CameraKitLog.notice(.scenePhase, "scenePhase: \(prev) → \(next)")
        await engine.setLifecyclePhase(map(phase))
        previousPhase = phase
    }

    /// Map SwiftUI's `ScenePhase` to the engine's `AppLifecyclePhase`.
    ///
    /// Identity over the three cases — the only place SwiftUI types touch the
    /// lifecycle path (CameraKit imports no SwiftUI). An `@unknown default` (a
    /// future SwiftUI case) maps to `.inactive`, the safe middle ground (gate
    /// closed, session kept running) — never a spurious teardown.
    private func map(_ phase: ScenePhase) -> AppLifecyclePhase {
        switch phase {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .inactive
        }
    }

    // MARK: - Capabilities dump (debug helper, written to Documents/capabilities.txt)

    private func dumpCapabilities(_ caps: SessionCapabilities) async {
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

        // All device.formats entries (unfiltered) — useful when picker results
        // look surprising. FourCC + dimensions + FPS range + bit-depth/range.
        let formatLines = await engine.dumpDeviceFormats()
        if !formatLines.isEmpty {
            lines.append("")
            lines.append("All device.formats (unfiltered):")
            for line in formatLines {
                lines.append("  \(line)")
            }
        }

        let text = lines.joined(separator: "\n") + "\n"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("capabilities.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
