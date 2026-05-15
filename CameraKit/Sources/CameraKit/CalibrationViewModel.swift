import Foundation

/// How long the Calibrate-WB button shows the "Calibrated ✓" confirmation
/// before the sidebar button reverts to its idle label.
///
/// UI display timing — kept here so `Constants` (a package-internal grab-bag)
/// does not need to become public for this one UI value. Phase 1A migration:
/// moved from `Constants.wbCompletedDisplayMs`.
private let wbCompletedDisplayMs: Int = 1500

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
    /// Apple's `grayWorldDeviceWhiteBalanceGains` — neutralizing gains for the
    /// center 50% of the frame, computed by AVF.
    func grayWorldDeviceWBGains() async throws -> WhiteBalanceGains
    /// Switches WB to continuous auto, awaits AWB convergence, then reads
    /// `grayWorldDeviceWhiteBalanceGains` for the freshly-settled scene.
    /// Used as `calibrateWB`'s iter-0 seed.
    func freshGrayWorldDeviceWBGains() async throws -> WhiteBalanceGains
    /// Locks WB to one of Apple's named presets, awaits AVF buffer-with-gains
    /// confirmation, then awaits the natural pipeline catching up to that
    /// buffer's PTS — natural texture is fresh on return.
    func setWBPreset(_ preset: WhiteBalancePreset) async throws
    /// Locks WB to explicit gains, awaits handler + natural-PTS catchup.
    /// Used inside the calibrate-WB iterative loop.
    func applyManualGainsAndAwait(_ gains: WhiteBalanceGains) async throws
    /// Awaits `isAdjustingExposure == false` (KVO, 2 s timeout).
    func awaitAESettled() async
}

extension CameraEngine: CalibrationEngineProtocol {}

/// Live state of a `CalibrationViewModel.calibrateWB` invocation.
///
/// The sidebar button reads this to switch between the idle label, an
/// in-progress indicator, and a brief completion confirmation.
public enum WBCalibrationStatus: Sendable, Equatable {
    case idle
    case calibrating
    case completed
}

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

    /// Effective WB mode, mirrored locally for sidebar button styling.
    ///
    /// Updated after each WB action because `HardwareControlsViewModel`'s
    /// `currentSettings` mirror is only refreshed by its own slider debouncers
    /// (ISO/shutter/focus/zoom) — calibration writes bypass that path. Initial
    /// value is `.auto` because `SettingsPersistence.load` strips manual on
    /// load, leaving each session in continuous AWB.
    var wbMode: WhiteBalanceMode = .auto

    /// Live state of the WB calibrate action — drives the sidebar button's
    /// in-progress / completed feedback. `.completed` auto-reverts to `.idle`
    /// after `wbCompletedDisplayMs`.
    var wbCalibrationStatus: WBCalibrationStatus = .idle

    private let engine: any CalibrationEngineProtocol
    private let processingVM: ProcessingViewModel

    init(engine: any CalibrationEngineProtocol, processingVM: ProcessingViewModel) {
        self.engine = engine
        self.processingVM = processingVM
    }

    /// Single-shot WB calibration via Apple's `grayWorldDeviceWhiteBalanceGains`.
    ///
    /// Switches WB to continuous auto so AVF's hardware statistics engine
    /// recomputes against the current scene, awaits convergence, reads the
    /// hardware gray-world gains (Bayer-domain, pre-CCM, pre-gamma), clamps
    /// to `[1.0, maxGain]`, locks the device to those gains. No iteration,
    /// no patch sampling, no log-cap damping — Apple does the math; we apply
    /// the result.
    ///
    /// Sets `wbCalibrationStatus` to `.calibrating` on entry and
    /// `.completed` on success so the sidebar button can render in-progress
    /// and confirmation feedback. The completed state auto-reverts to
    /// `.idle` after `wbCompletedDisplayMs`.
    func calibrateWB() {
        let engine = self.engine
        Task { @MainActor in
            self.wbCalibrationStatus = .calibrating
            do {
                let maxGain = try await engine.maxWhiteBalanceGain()
                let raw = try await engine.freshGrayWorldDeviceWBGains()
                let gains = WhiteBalanceGains(
                    red: min(maxGain, max(1.0, raw.red)),
                    green: min(maxGain, max(1.0, raw.green)),
                    blue: min(maxGain, max(1.0, raw.blue)))
                CameraKitLog.notice(
                    .engine,
                    "[wb] start max-gain=\(fmtF(maxGain)) | apple-gray-world raw=\(fmtG(raw)) clamped=\(fmtG(gains))")
                try await engine.applyManualGainsAndAwait(gains)
                CameraKitLog.notice(.engine, "[wb] done gains=\(fmtG(gains))")

                var manual = CameraSettings()
                manual.wbMode = .manual
                manual.wbGainR = Double(gains.red)
                manual.wbGainG = Double(gains.green)
                manual.wbGainB = Double(gains.blue)
                try await engine.updateSettings(manual)

                self.wbMode = .manual
                self.wbCalibrationStatus = .completed
                try? await Task.sleep(for: .milliseconds(wbCompletedDisplayMs))
                if self.wbCalibrationStatus == .completed {
                    self.wbCalibrationStatus = .idle
                }
            } catch {
                CameraKitLog.error(.engine, "[wb] calibrateWB threw: \(error)")
                self.wbCalibrationStatus = .idle
            }
        }
    }

    /// Returns to AVFoundation continuous auto white balance.
    func resetToAutoWB() {
        let engine = self.engine
        Task { @MainActor in
            var delta = CameraSettings()
            delta.wbMode = .auto
            try? await engine.updateSettings(delta)
            self.wbMode = .auto
        }
    }

    /// Freezes whatever WB gains AVFoundation currently has — useful for
    /// "stop the colors from shifting" without sample-and-compute calibration.
    func lockCurrentWB() {
        let engine = self.engine
        Task { @MainActor in
            var delta = CameraSettings()
            delta.wbMode = .locked
            try? await engine.updateSettings(delta)
            self.wbMode = .locked
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

// MARK: - Calibrate-WB log formatters
//
// File-private helpers so the per-iteration log line stays readable without
// inline `String(format:)` clutter. All width-fixed (3 dp for sample/gains,
// 4 dp for residuals) so columns align in Console.

private func fmt3(_ d: Double) -> String { String(format: "%.3f", d) }
private func fmtF(_ f: Float) -> String { String(format: "%.3f", Double(f)) }
private func fmtD4(_ d: Double) -> String { String(format: "%.4f", d) }
private func fmtD4Signed(_ d: Double) -> String { String(format: "%+.4f", d) }
private func fmtS(_ s: RgbSample) -> String {
    "(\(fmt3(s.r)), \(fmt3(s.g)), \(fmt3(s.b)))"
}
private func fmtG(_ g: WhiteBalanceGains) -> String {
    "(\(fmt3(Double(g.red))), \(fmt3(Double(g.green))), \(fmt3(Double(g.blue))))"
}
