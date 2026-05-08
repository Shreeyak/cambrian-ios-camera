import Foundation

/// Engine surface used by `CalibrationViewModel`.
///
/// Test-injection seam: production wires `CameraEngine` directly via the
/// extension below. Tests substitute a stub that records inputs/outputs without
/// requiring an `AVCaptureSession`.
protocol CalibrationEngineProtocol: Sendable {
    func sampleCenterPatch() async throws -> RgbSample
    func currentDeviceWBGains() async throws -> WhiteBalanceGains
    func maxWhiteBalanceGain() async throws -> Float
    func updateSettings(_ settings: CameraSettings) async throws
}

extension CameraEngine: CalibrationEngineProtocol {}

/// White-balance + black-balance calibrate actions.
///
/// Each action is a one-shot flow:
///   1. `engine.sampleCenterPatch()` → `RgbSample`
///   2. WB: `CalibrationCompute.grayWorldGains` → `engine.updateSettings(.manual + gains)`
///      BB: forward sample to `processingVM.applyBlackBalance(sample:)`
///
/// Holds a reference to `ProcessingViewModel` so BB writes the per-channel
/// pedestal into the same `currentProcessing` source the sliders read from
/// (single owner per the MVVM-decomposition ownership rules).
@Observable @MainActor
final class CalibrationViewModel {

    private let engine: any CalibrationEngineProtocol
    private let processingVM: ProcessingViewModel

    init(engine: any CalibrationEngineProtocol, processingVM: ProcessingViewModel) {
        self.engine = engine
        self.processingVM = processingVM
    }

    /// Brief §8 TESTABLE `11:wb-calibrate-applies-computed-gains`.
    ///
    /// Sample → gray-world reciprocal gains → switch WB to `.manual` and write the gains.
    func calibrateWB() {
        let engine = self.engine
        Task {
            do {
                let sample = try await engine.sampleCenterPatch()
                let currentGains = try await engine.currentDeviceWBGains()
                let maxGain = try await engine.maxWhiteBalanceGain()
                let gains = CalibrationCompute.grayWorldGains(
                    sample: sample,
                    current: currentGains,
                    maxGain: maxGain
                )
                var delta = CameraSettings()
                delta.wbMode = .manual
                delta.wbGainR = Double(gains.red)
                delta.wbGainG = Double(gains.green)
                delta.wbGainB = Double(gains.blue)
                try await engine.updateSettings(delta)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }

    /// Brief §8 TESTABLE `11:bb-calibrate-updates-processing-params`.
    ///
    /// Sample → forward to `ProcessingViewModel` so the BB sliders and engine
    /// state stay coherent.
    func calibrateBB() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task {
            do {
                let sample = try await engine.sampleCenterPatch()
                await processingVM.applyBlackBalance(sample: sample)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }
}
