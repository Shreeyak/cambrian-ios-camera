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
/// `calibrateWhiteBalance()` / `calibrateBlackPoint()` and writes WB-mode
/// deltas via `updateSettings`. After black-point calibration the VM resyncs its
/// processing-params mirror via `currentProcessingParametersSnapshot()`.
protocol CalibrationEngineProtocol: Sendable {
    func calibrateWhiteBalance() async throws -> CalibrationResult
    /// linear-normalization-stage: the linear, pre-grade black point. Returns
    /// per-channel diagnostics for the demo app to display; throws
    /// `EngineError.blackPointCalibrationFailed` when the field isn't dark enough.
    func calibrateBlackPoint() async throws -> BlackPointDebug
    /// Clears the applied black point (demo "undo").
    func clearBlackPoint() async
    /// linear-normalization-stage §5.2: selects chroma-only (phase contrast) vs
    /// chroma + white-point level (brightfield). A no-op in auto WB (engine-gated
    /// to a locked WB).
    func applyWhiteBalance(whitePoint: Bool) async
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

/// White-balance + black-point calibrate / reset / lock actions.
///
/// **Phase-2 §2b move-down:** the engine owns the calibration algorithms
/// (`CameraEngine.calibrateWhiteBalance()` / `calibrateBlackPoint()`).
/// This VM is a thin caller — it triggers the engine method, surfaces
/// in-progress / completed UI feedback, and resyncs the `ProcessingViewModel`
/// mirror after a calibration completes (via
/// `engine.currentProcessingParametersSnapshot()`).
///
/// User-facing actions:
///   1. `calibrateWB()`     — invoke `engine.calibrateWhiteBalance()`; status feedback
///   2. `resetToAutoWB()`   — return to AVFoundation continuous AWB
///   3. `lockCurrentWB()`   — freeze whatever AVF currently has (`.locked` mode)
///   4. `calibrateBP()`     — invoke `engine.calibrateBlackPoint()`; refresh VM mirror
///   5. `clearBP()`         — clear the applied black point
///
/// Holds a reference to `ProcessingViewModel` so the calibration mirror sync
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

    /// True while `calibrateBP()` is running — drives the Black Point button's
    /// in-progress indicator. The black-point calibration reads back the full
    /// frame + computes CPU stats, so it takes up to ~1 s (Debug); without this
    /// the button looks unresponsive.
    var bpCalibrating: Bool = false

    /// Diagnostics from the most recent black-point calibration (sampled patch +
    /// per-channel stats) — surfaced in a debug panel so the operator can see what
    /// was measured (e.g. `keptCount == 0` ⇒ surface too bright). `nil` until first run.
    var lastBlackPointDebug: BlackPointDebug?

    /// Operator-facing reason the most recent black-point calibration failed
    /// (e.g. the field wasn't dark enough), or `nil` on success / not-yet-run.
    var blackPointError: String?

    /// Whether the white-point level (brightfield) is applied on top of the WB
    /// chroma residual (linear-normalization-stage §5.2). `false` = phase contrast
    /// (chroma only, neutralize without stretching to white). Mirrors the engine's
    /// gated truth — read back from the processing snapshot after each WB action,
    /// so it reads `false` whenever WB is in auto (the engine disables it there).
    var whitePointEnabled: Bool = false

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
                // Calibration stores + enables the WB chroma residual (white point
                // stays off — phase-contrast default). Resync the processing mirror
                // and the white-point toggle from the engine's snapshot.
                if let snap = await engine.currentProcessingParametersSnapshot() {
                    self.whitePointEnabled = snap.whitePointEnabled
                    self.processingVM.refreshFromEngineSnapshot(snap)
                }
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
    ///
    /// The engine gates the WB chroma residual + white point off in auto WB
    /// (§5.3), so resync the toggle + processing mirror to reflect that.
    func resetToAutoWB() {
        let engine = self.engine
        Task { @MainActor in
            var delta = CameraSettings()
            delta.wbMode = .auto
            try? await engine.updateSettings(delta)
            self.wbMode = .auto
            if let snap = await engine.currentProcessingParametersSnapshot() {
                self.whitePointEnabled = snap.whitePointEnabled  // engine forces false in auto
                self.processingVM.refreshFromEngineSnapshot(snap)
            }
        }
    }

    /// Selects brightfield (chroma + white-point level) vs phase contrast (chroma
    /// only) via the engine's `applyWhiteBalance(whitePoint:)` (§5.2).
    ///
    /// A no-op while WB is in auto (the engine gates chroma/white point to a locked
    /// WB), so the toggle reflects the engine's gated truth read back from the
    /// snapshot rather than the requested value.
    func setWhitePoint(_ enabled: Bool) {
        let engine = self.engine
        Task { @MainActor in
            await engine.applyWhiteBalance(whitePoint: enabled)
            if let snap = await engine.currentProcessingParametersSnapshot() {
                self.whitePointEnabled = snap.whitePointEnabled
                self.processingVM.refreshFromEngineSnapshot(snap)
            }
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

    /// Triggers black-point calibration via the engine's `calibrateBlackPoint()`.
    ///
    /// linear-normalization-stage: the linear, pre-grade black point. Point the
    /// camera at a dark field, then tap — the engine reads back the frame, derives
    /// `mean + k·σ` per channel in linear light, applies + enables the black point.
    /// Resyncs the `ProcessingViewModel` mirror. On failure (field not dark enough)
    /// the operator-facing reason is published to `blackPointError` for display.
    func calibrateBP() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task { @MainActor in
            self.bpCalibrating = true
            self.blackPointError = nil
            defer { self.bpCalibrating = false }
            do {
                self.lastBlackPointDebug = try await engine.calibrateBlackPoint()
                if let snap = await engine.currentProcessingParametersSnapshot() {
                    processingVM.refreshFromEngineSnapshot(snap)
                }
            } catch let EngineError.blackPointCalibrationFailed(reason) {
                self.blackPointError = reason
            } catch {
                self.blackPointError = "Black-point calibration failed: \(error)"
            }
        }
    }

    /// Clears the applied black point ("undo") and refreshes the mirror.
    func clearBP() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task { @MainActor in
            await engine.clearBlackPoint()
            self.lastBlackPointDebug = nil
            self.blackPointError = nil
            if let snap = await engine.currentProcessingParametersSnapshot() {
                processingVM.refreshFromEngineSnapshot(snap)
            }
        }
    }
}
