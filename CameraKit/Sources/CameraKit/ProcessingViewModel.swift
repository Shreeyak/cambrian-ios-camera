import Foundation

/// GPU color-pipeline shader-uniform sliders (brightness, contrast, saturation,
/// gamma, per-channel black balance R/G/B).
///
/// Sole owner of `currentProcessing`. Each push coalesces via a per-control
/// `SliderDebouncer`; the dispatch closure mutates `currentProcessing`
/// optimistically and forwards via `engine.setProcessingParameters(_:)`. The
/// engine's `Mutex<UniformStorage>` (D-17 / ADR-34 / Inv-6) is the single
/// host-write path — this VM does not bypass it.
///
/// `applyBlackBalance(sample:)` is the public entry point used by
/// `CalibrationViewModel` after a BB-Calibrate sample.
@Observable @MainActor
final class ProcessingViewModel {

    var currentProcessing: ProcessingParameters = .identity

    @ObservationIgnored private var brightnessDebouncer: SliderDebouncer?
    @ObservationIgnored private var contrastDebouncer: SliderDebouncer?
    @ObservationIgnored private var saturationDebouncer: SliderDebouncer?
    @ObservationIgnored private var gammaDebouncer: SliderDebouncer?
    @ObservationIgnored private var blackRDebouncer: SliderDebouncer?
    @ObservationIgnored private var blackGDebouncer: SliderDebouncer?
    @ObservationIgnored private var blackBDebouncer: SliderDebouncer?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Seed `currentProcessing` from persisted parameters + start 7 debouncers.
    func start() async {
        if let persisted = engine.getPersistedProcessingParameters() {
            currentProcessing = persisted
        }

        brightnessDebouncer = makeDebouncer { $0.brightness = $1 }
        contrastDebouncer = makeDebouncer { $0.contrast = $1 }
        saturationDebouncer = makeDebouncer { $0.saturation = $1 }
        gammaDebouncer = makeDebouncer { $0.gamma = $1 }
        blackRDebouncer = makeDebouncer { $0.blackR = $1 }
        blackGDebouncer = makeDebouncer { $0.blackG = $1 }
        blackBDebouncer = makeDebouncer { $0.blackB = $1 }

        await brightnessDebouncer?.start()
        await contrastDebouncer?.start()
        await saturationDebouncer?.start()
        await gammaDebouncer?.start()
        await blackRDebouncer?.start()
        await blackGDebouncer?.start()
        await blackBDebouncer?.start()
    }

    func stop() async {
        for d in [
            brightnessDebouncer, contrastDebouncer, saturationDebouncer, gammaDebouncer,
            blackRDebouncer, blackGDebouncer, blackBDebouncer,
        ] {
            await d?.stop()
        }
        brightnessDebouncer = nil
        contrastDebouncer = nil
        saturationDebouncer = nil
        gammaDebouncer = nil
        blackRDebouncer = nil
        blackGDebouncer = nil
        blackBDebouncer = nil
    }

    // MARK: - Push entry points (called from view sliders)

    func pushBrightness(_ v: Double) { brightnessDebouncer?.push(v) }
    func pushContrast(_ v: Double) { contrastDebouncer?.push(v) }
    func pushSaturation(_ v: Double) { saturationDebouncer?.push(v) }
    func pushGamma(_ v: Double) { gammaDebouncer?.push(v) }
    func pushBlackR(_ v: Double) { blackRDebouncer?.push(v) }
    func pushBlackG(_ v: Double) { blackGDebouncer?.push(v) }
    func pushBlackB(_ v: Double) { blackBDebouncer?.push(v) }

    // MARK: - Calibration / reset entry points

    /// Writes per-channel black-balance pedestal into `currentProcessing`
    /// based on a dark-patch sample.
    ///
    /// The GPU pipeline subtracts these pedestals as the **final** color
    /// step, after brightness/contrast/saturation/gamma — see
    /// `Shaders/ColorShaders.metal`.
    ///
    /// **Sample lane requirement:** the sample must be read from a render
    /// where BCSG is applied and BB is zeroed — typically via
    /// `CameraEngine.sampleCenterPatchForBBCalibration`, which runs a
    /// one-shot Pass-2 encode into a scratch texture with BB temporarily
    /// zeroed. Rationale:
    ///   - BB operates on the graded image, so the sample must be in the
    ///     same color space (BCSG applied) for the offsets to correctly
    ///     subtract a dark patch.
    ///   - The sample must NOT include the previously-written BB pedestal,
    ///     or each calibrate would stack on top of the prior result.
    /// Sampling from `processedTex` would violate the second requirement;
    /// sampling from `naturalTex` would violate the first.
    ///
    /// Mutates the mirror BEFORE dispatching so the MainActor read-modify-write is
    /// atomic — `await engine.setProcessingParameters` would otherwise suspend
    /// MainActor between the read and the write, letting concurrent slider
    /// debouncers clobber black-balance fields. The engine actor's mailbox
    /// serializes the eventual GPU-side write.
    func applyBlackBalance(sample: RgbSample) async {
        let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
        var next = currentProcessing
        next.blackR = offsets.r
        next.blackG = offsets.g
        next.blackB = offsets.b
        currentProcessing = next
        await engine.setProcessingParameters(next)
    }

    /// Reset all color uniforms to identity.
    func resetProcessing() async {
        let next = ProcessingParameters.identity
        currentProcessing = next
        await engine.setProcessingParameters(next)
    }

    // MARK: - Private

    /// Build a debouncer whose dispatch atomically RMWs the `currentProcessing` mirror.
    ///
    /// `SliderDebouncer`'s consumer task runs OFF MainActor, so we hop on with
    /// `MainActor.run` and perform the full read-modify-write inside that single
    /// hop — guaranteeing each debouncer (and `applyBlackBalance`) observes a
    /// consistent prior state. The `engine.setProcessingParameters` dispatch
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
            await engine.setProcessingParameters(next)
        }
    }
}
