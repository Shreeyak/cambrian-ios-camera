import Foundation

/// Engine surface used by `CalibrationViewModel`.
///
/// Test-injection seam: production wires `CameraEngine` directly via the
/// extension below. Tests substitute a stub that records inputs/outputs without
/// requiring an `AVCaptureSession`.
protocol CalibrationEngineProtocol: Sendable {
    /// WB-calibration sample: naturalTex (no BCSG, no BB).
    func sampleCenterPatchOnNatural() async throws -> RgbSample
    /// BB-calibration sample: scratch render with current BCSG and BB zeroed.
    func sampleCenterPatchForBBCalibration() async throws -> RgbSample
    func updateSettings(_ settings: CameraSettings) async throws
    func currentDeviceWBGains() async throws -> WhiteBalanceGains
    func maxWhiteBalanceGain() async throws -> Float
    func awaitWBSettled() async
}

extension CameraEngine: CalibrationEngineProtocol {}

/// White-balance + black-balance calibrate / reset / lock actions.
///
/// Five user-facing actions:
///   1. `calibrateWB()`     — sample-and-compute (resolution-scaled center patch (96 px at default 4160×3120; floor of 16) on naturalTex)
///   2. `resetToAutoWB()`   — return to AVFoundation continuous AWB
///   3. `lockCurrentWB()`   — freeze whatever AVF currently has (`.locked` mode)
///   4. `calibrateBB()`     — sample dark patch on naturalTex; write per-channel pedestal
///   5. `resetBlackBalance()` — zero the BB pedestal
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

    /// Bug 13 (revised) — re-baseline + custom-patch gray-world calibration.
    ///
    /// Steps:
    ///   1. Switch device to `.auto` so the next sample is taken from a known baseline.
    ///   2. Await `isAdjustingWhiteBalance == false` via KVO (2s timeout).
    ///   3. Read `currentDeviceWBGains` — the gains AVF converged on.
    ///   4. Sample 96-px patch from `naturalTex` (pre-tonemap, no GPU-side WB).
    ///   5. Compute new manual gains via `CalibrationCompute.grayWorldGains`
    ///      (linearize → stack onto current → normalize → clamp).
    ///   6. Write `wbMode = .manual` with the computed gains.
    func calibrateWB() {
        let engine = self.engine
        Task {
            do {
                var resetDelta = CameraSettings()
                resetDelta.wbMode = .auto
                try await engine.updateSettings(resetDelta)
                await engine.awaitWBSettled()
                let current = try await engine.currentDeviceWBGains()
                let maxGain = try await engine.maxWhiteBalanceGain()
                let sample = try await engine.sampleCenterPatchOnNatural()
                let gains = CalibrationCompute.grayWorldGains(
                    sample: sample, current: current, maxGain: maxGain)
                var manual = CameraSettings()
                manual.wbMode = .manual
                manual.wbGainR = Double(gains.red)
                manual.wbGainG = Double(gains.green)
                manual.wbGainB = Double(gains.blue)
                try await engine.updateSettings(manual)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }

    /// Returns to AVFoundation continuous auto white balance.
    func resetToAutoWB() {
        let engine = self.engine
        Task {
            var delta = CameraSettings()
            delta.wbMode = .auto
            try? await engine.updateSettings(delta)
        }
    }

    /// Freezes whatever WB gains AVFoundation currently has — useful for
    /// "stop the colors from shifting" without sample-and-compute calibration.
    func lockCurrentWB() {
        let engine = self.engine
        Task {
            var delta = CameraSettings()
            delta.wbMode = .locked
            try? await engine.updateSettings(delta)
        }
    }

    /// Black balance: sample a dark patch through the current BCSG with BB
    /// temporarily zeroed, write per-channel pedestal into
    /// `ProcessingParameters.blackR/G/B`.
    ///
    /// The pedestal is subtracted at the
    /// *end* of the GPU color pipeline (after BCSG) per `ColorShaders.metal`.
    /// The sampling path mirrors that order: BCSG applied (so the sample is
    /// in the same color space the pedestal will subtract from), BB zeroed
    /// (so the sample isn't biased by the previously-applied pedestal). See
    /// `MetalPipeline.dispatchBBCalibrationSample` for the implementation.
    func calibrateBB() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task {
            do {
                let sample = try await engine.sampleCenterPatchForBBCalibration()
                await processingVM.applyBlackBalance(sample: sample)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }

    /// Zeroes the BB pedestal so the GPU pipeline subtracts nothing.
    func resetBlackBalance() {
        let processingVM = self.processingVM
        Task {
            await processingVM.applyBlackBalance(sample: RgbSample(r: 0, g: 0, b: 0))
        }
    }
}
