import CameraKit
import Foundation

/// GPU color-pipeline shader-uniform sliders (brightness, contrast, saturation,
/// gamma).
///
/// Sole owner of `currentProcessing`. Each push coalesces via a per-control
/// `SliderDebouncer`; the dispatch closure mutates `currentProcessing`
/// optimistically and forwards via `engine.setProcessingParams(_:)`. The
/// engine's `Mutex<UniformStorage>` (D-17 / ADR-34 / Inv-6) is the single
/// host-write path — this VM does not bypass it.
@Observable @MainActor
final class ProcessingViewModel {

    var currentProcessing: ProcessingParameters = .identity

    @ObservationIgnored private var brightnessDebouncer: SliderDebouncer?
    @ObservationIgnored private var contrastDebouncer: SliderDebouncer?
    @ObservationIgnored private var saturationDebouncer: SliderDebouncer?
    @ObservationIgnored private var gammaDebouncer: SliderDebouncer?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Seed `currentProcessing` from persisted parameters + start the debouncers.
    func start() async {
        if let persisted = engine.getPersistedProcessingParameters() {
            currentProcessing = persisted
        }

        brightnessDebouncer = makeDebouncer { $0.brightness = $1 }
        contrastDebouncer = makeDebouncer { $0.contrast = $1 }
        saturationDebouncer = makeDebouncer { $0.saturation = $1 }
        gammaDebouncer = makeDebouncer { $0.gamma = $1 }

        await brightnessDebouncer?.start()
        await contrastDebouncer?.start()
        await saturationDebouncer?.start()
        await gammaDebouncer?.start()
    }

    func stop() async {
        for d in [
            brightnessDebouncer, contrastDebouncer, saturationDebouncer, gammaDebouncer,
        ] {
            await d?.stop()
        }
        brightnessDebouncer = nil
        contrastDebouncer = nil
        saturationDebouncer = nil
        gammaDebouncer = nil
    }

    // MARK: - Push entry points (called from view sliders)

    func pushBrightness(_ v: Double) { brightnessDebouncer?.push(v) }
    func pushContrast(_ v: Double) { contrastDebouncer?.push(v) }
    func pushSaturation(_ v: Double) { saturationDebouncer?.push(v) }
    func pushGamma(_ v: Double) { gammaDebouncer?.push(v) }

    // MARK: - Calibration / reset entry points

    /// Refresh `currentProcessing` from the engine's authoritative snapshot.
    ///
    /// Called by `CalibrationViewModel` after engine-side calibration so the
    /// slider mirror reflects the just-applied parameters. No engine dispatch —
    /// the engine already has the values; this only updates the UI mirror.
    func refreshFromEngineSnapshot(_ snap: ProcessingParameters) {
        currentProcessing = snap
    }

    /// Reset all color uniforms to identity.
    func resetProcessing() async {
        let next = ProcessingParameters.identity
        currentProcessing = next
        await engine.setProcessingParams(next)
    }

    // MARK: - Private

    /// Build a debouncer whose dispatch atomically RMWs the `currentProcessing` mirror.
    ///
    /// `SliderDebouncer`'s consumer task runs OFF MainActor, so we hop on with
    /// `MainActor.run` and perform the full read-modify-write inside that single
    /// hop — guaranteeing each debouncer observes a
    /// consistent prior state. The `engine.setProcessingParams` dispatch
    /// runs after the hop; the engine actor serializes downstream writes.
    private func makeDebouncer(
        _ mutate: @escaping @Sendable (inout ProcessingParameters, Double) -> Void
    ) -> SliderDebouncer {
        let engine = self.engine
        return SliderDebouncer { [weak self] v in
            guard let self else { return }
            let next = await MainActor.run { () -> ProcessingParameters in
                var p = self.currentProcessing
                mutate(&p, v)
                self.currentProcessing = p
                return p
            }
            await engine.setProcessingParams(next)
        }
    }
}
