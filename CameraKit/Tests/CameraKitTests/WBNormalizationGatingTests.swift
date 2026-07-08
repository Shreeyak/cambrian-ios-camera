import Testing

@testable import CameraKit

/// linear-normalization-stage §9.1: auto/manual WB-normalization gating.
///
/// The WB chroma residual and the white-point level (`gateWBNormalization`) apply
/// only when white balance is LOCKED (`.locked`/`.manual`). In auto WB they are
/// forced off — a software residual would chase the continuously-moving hardware
/// gains — and only the enable toggles change, never the stored coefficients, so
/// re-locking re-activates the last calibration without recomputing.
@Suite("WBNormalizationGatingTests")
struct WBNormalizationGatingTests {

    /// Params with chroma + white point enabled and non-identity coefficients, so a
    /// test can assert both the gated toggles and that the coefficients survive.
    private func calibrated() -> ProcessingParameters {
        var p = ProcessingParameters.identity
        p.wbChromaR = 1.2
        p.wbChromaG = 1.0
        p.wbChromaB = 0.85
        p.wbChromaEnabled = true
        p.whitePointLevel = 0.9
        p.whitePointEnabled = true
        p.blackPointR = 0.02
        p.blackPointEnabled = true
        return p
    }

    @Test func lockedLeavesChromaAndWhitePointUntouched() {
        let p = calibrated()
        for mode: WhiteBalanceMode in [.locked, .manual] {
            let g = CameraEngine.gateWBNormalization(p, wbMode: mode)
            #expect(g == p)  // fully unchanged when locked
        }
    }

    @Test func autoForcesChromaAndWhitePointOff() {
        let g = CameraEngine.gateWBNormalization(calibrated(), wbMode: .auto)
        #expect(g.wbChromaEnabled == false)
        #expect(g.whitePointEnabled == false)
    }

    @Test func nilModeIsTreatedAsNotLocked() {
        // An unknown (nil) mode is not `.locked`/`.manual`, so it gates off.
        let g = CameraEngine.gateWBNormalization(calibrated(), wbMode: nil)
        #expect(g.wbChromaEnabled == false)
        #expect(g.whitePointEnabled == false)
    }

    @Test func gatingChangesOnlyTogglesNotCoefficients() {
        let p = calibrated()
        let g = CameraEngine.gateWBNormalization(p, wbMode: .auto)
        // Stored coefficients survive (re-lock re-activates without recompute).
        #expect(g.wbChromaR == p.wbChromaR)
        #expect(g.wbChromaG == p.wbChromaG)
        #expect(g.wbChromaB == p.wbChromaB)
        #expect(g.whitePointLevel == p.whitePointLevel)
        // Black point is independent of the WB gate.
        #expect(g.blackPointEnabled == p.blackPointEnabled)
        #expect(g.blackPointR == p.blackPointR)
    }
}

/// linear-normalization-stage §9.2 (restore-gate sub-item): `open()` applies the WB
/// gate to persisted processing params. Persist `wbChromaEnabled == true`, open with
/// WB defaulting to auto, and assert chroma starts DISABLED — the §5.3 hole-closer
/// (a stale persisted chroma must not apply in auto WB). Device-only (real `open()`),
/// serialized; the app's real persisted processing is preserved and restored.
@Suite("WBRestoreGateDeviceTests", .serialized)
struct WBRestoreGateDeviceTests {
    @Test func persistedChromaStartsDisabledWhenWBAuto() async throws {
        let saved = SettingsPersistence.loadProcessing()
        defer { SettingsPersistence.saveProcessing(saved ?? .identity) }

        var chromaOn = ProcessingParameters.identity
        chromaOn.wbChromaR = 1.2
        chromaOn.wbChromaEnabled = true
        SettingsPersistence.saveProcessing(chromaOn)

        let engine = CameraEngine(initialPhase: .active)
        _ = try await engine.open(configuration: OpenConfiguration())
        // WB defaults to auto on a fresh open → the persisted chroma is gated off.
        let applied = await engine.currentProcessingParametersSnapshot()
        #expect(applied?.wbChromaEnabled == false)
        await engine.close()
    }
}
