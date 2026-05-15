import CameraKit
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
///
/// **Phase-2 §2b shrink** — the VM no longer drives the multi-step calibration
/// algorithm itself; it just calls the engine's high-level
/// `calibrateWhiteBalance()` / `calibrateBlackBalance()` and writes WB-mode
/// deltas via `updateSettings`. After BB calibration the VM resyncs its
/// processing-params mirror via `currentProcessingParametersSnapshot()`.
protocol CalibrationEngineProtocol: Sendable {
    func calibrateWhiteBalance() async throws -> CalibrationResult
    func calibrateBlackBalance() async throws -> CalibrationResult
    func updateSettings(_ settings: CameraSettings) async throws
    func currentProcessingParametersSnapshot() async -> ProcessingParameters?
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
/// **Phase-2 §2b move-down:** the engine now owns the calibration algorithms
/// (`CameraEngine.calibrateWhiteBalance()` / `calibrateBlackBalance()`).
/// This VM is a thin caller — it triggers the engine method, surfaces
/// in-progress / completed UI feedback for WB, and resyncs the
/// `ProcessingViewModel` mirror after BB completes (via
/// `engine.currentProcessingParametersSnapshot()`).
///
/// Five user-facing actions:
///   1. `calibrateWB()`        — invoke `engine.calibrateWhiteBalance()`; status feedback
///   2. `resetToAutoWB()`      — return to AVFoundation continuous AWB
///   3. `lockCurrentWB()`      — freeze whatever AVF currently has (`.locked` mode)
///   4. `calibrateBB()`        — invoke `engine.calibrateBlackBalance()`; refresh VM mirror
///   5. `resetBlackBalance()`  — zero the BB pedestal
///
/// Holds a reference to `ProcessingViewModel` so the BB-result mirror sync
/// writes into the same `currentProcessing` source the sliders read from
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

    /// Triggers single-shot WB calibration via the engine's `calibrateWhiteBalance()`.
    ///
    /// Phase-2 §2b move-down: the algorithm now lives engine-side. The VM
    /// becomes a thin caller that sets `wbCalibrationStatus` for in-progress /
    /// completed feedback and updates the locally-mirrored `wbMode`.
    func calibrateWB() {
        let engine = self.engine
        Task { @MainActor in
            self.wbCalibrationStatus = .calibrating
            do {
                _ = try await engine.calibrateWhiteBalance()
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

    /// Triggers BB calibration via the engine's `calibrateBlackBalance()`.
    ///
    /// Resyncs the local `ProcessingViewModel` mirror from the engine's
    /// authoritative snapshot. Phase-2 §2b.
    func calibrateBB() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task {
            do {
                _ = try await engine.calibrateBlackBalance()
                if let snap = await engine.currentProcessingParametersSnapshot() {
                    await MainActor.run { processingVM.refreshFromEngineSnapshot(snap) }
                }
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
