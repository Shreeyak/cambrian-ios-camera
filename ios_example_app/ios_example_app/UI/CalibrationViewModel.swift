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
/// `calibrateWhite(whitePoint:)` / `calibrateBlack()` and writes WB-mode
/// deltas via `updateSettings`. After black-point calibration the VM resyncs its
/// processing-params mirror via `currentProcessingParametersSnapshot()`.
protocol CalibrationEngineProtocol: Sendable {
    /// Full white calibration (sample → compute → enable). `whitePoint: true` =
    /// brightfield (chroma + level); `false` = phase contrast (chroma only).
    /// Throws if the patch isn't a bright white field.
    func calibrateWhite(whitePoint: Bool) async throws -> CalibrationResult
    /// linear-normalization-stage: the linear, pre-grade black point. Returns
    /// per-channel diagnostics for the demo app to display; throws
    /// `EngineError.blackPointCalibrationFailed` when the field isn't dark enough.
    func calibrateBlack() async throws -> BlackPointDebug
    /// Clears the applied black point (demo "undo").
    func clearBlackPoint() async
    /// linear-normalization-stage §5.2 — independent enable/disable of each
    /// software normalization setting on the stored coefficients (no resampling).
    /// `enable*` throws `EngineError.{whiteBalance,blackPoint}NotCalibrated` if the
    /// field was never calibrated; white point is enable-able only while chroma is
    /// active, and disabling chroma also disables white point.
    func enableWhiteBalance() async throws
    func disableWhiteBalance() async
    func clearWhiteBalance() async
    func enableWhitePoint() async throws
    func disableWhitePoint() async
    func enableBlackPoint() async throws
    func disableBlackPoint() async
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
/// (`CameraEngine.calibrateWhite(whitePoint:)` / `calibrateBlack()`).
/// This VM is a thin caller — it triggers the engine method, surfaces
/// in-progress / completed UI feedback, and resyncs the `ProcessingViewModel`
/// mirror after a calibration completes (via
/// `engine.currentProcessingParametersSnapshot()`).
///
/// User-facing actions:
///   1. `calibrateWB()`     — invoke `engine.calibrateWhite(whitePoint:)`; status feedback
///   2. `resetToAutoWB()`   — return to AVFoundation continuous AWB
///   3. `lockCurrentWB()`   — freeze whatever AVF currently has (`.locked` mode)
///   4. `calibrateBP()`     — invoke `engine.calibrateBlack()`; refresh VM mirror
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

    /// Whether the WB chroma residual is applied (mirrors the engine's gated truth;
    /// `false` in auto WB or before calibration). Drives the "White balance" toggle.
    var wbChromaEnabled: Bool = false

    /// Whether the calibrated black point is applied (mirrors the engine). Drives the
    /// "Black point" toggle; `false` before calibration or after clear.
    var blackPointEnabled: Bool = false

    /// Whether WB has been calibrated (chroma coefficients differ from identity) —
    /// distinct from *enabled*. Lets the WB toggle stay operable after a `disable`
    /// so it can be re-enabled without recalibrating; `false` after `clearWB`.
    var wbCalibrated: Bool = false

    /// Whether the black point has been calibrated (offsets non-zero) — distinct from
    /// *enabled*. Gates the black-point toggle; `false` after `clearBP`.
    var blackPointCalibrated: Bool = false

    private let engine: any CalibrationEngineProtocol
    private let processingVM: ProcessingViewModel

    init(engine: any CalibrationEngineProtocol, processingVM: ProcessingViewModel) {
        self.engine = engine
        self.processingVM = processingVM
    }

    /// Pulls the engine's processing snapshot and mirrors the normalization toggles
    /// (enabled + calibrated) + the processing sliders from it — the single source of
    /// truth after any calibrate / toggle / clear action, so the UI always reflects
    /// the engine's *gated* state (e.g. toggles read `false` when WB is auto).
    private func syncCalibrationState() async {
        guard let snap = await engine.currentProcessingParametersSnapshot() else { return }
        self.whitePointEnabled = snap.whitePointEnabled
        self.wbChromaEnabled = snap.wbChromaEnabled
        self.blackPointEnabled = snap.blackPointEnabled
        self.wbCalibrated =
            snap.wbChromaR != 1.0 || snap.wbChromaG != 1.0 || snap.wbChromaB != 1.0
        self.blackPointCalibrated =
            snap.blackPointR != 0 || snap.blackPointG != 0 || snap.blackPointB != 0
        self.processingVM.refreshFromEngineSnapshot(snap)
    }

    /// Triggers single-shot WB calibration via the engine's `calibrateWhite(whitePoint:)`.
    ///
    /// Phase-2 §2b move-down: the algorithm now lives engine-side. The VM
    /// becomes a thin caller that sets `wbCalibrationStatus` for in-progress /
    /// completed feedback and updates the locally-mirrored `wbMode`.
    func calibrateWB() {
        let engine = self.engine
        Task { @MainActor in
            self.wbCalibrationStatus = .calibrating
            do {
                // Full white calibration; brightfield by default (white point on).
                // Toggle to phase contrast afterward via the white-point switch.
                _ = try await engine.calibrateWhite(whitePoint: true)
                self.wbMode = .manual
                // Calibration stores + enables chroma + white point. Resync all
                // toggles + the processing mirror from the engine snapshot.
                await self.syncCalibrationState()
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
            // Engine forces chroma + white point off in auto — sync reflects that.
            await self.syncCalibrationState()
        }
    }

    /// Toggles the white-point level (brightfield) on top of the chroma residual
    /// via the engine's `enableWhitePoint()` / `disableWhitePoint()` (§5.2).
    ///
    /// `enableWhitePoint()` throws if WB isn't calibrated/active; the toggle then
    /// reflects the engine's gated truth read back from the snapshot rather than the
    /// requested value (so it stays off if the enable was rejected).
    func setWhitePoint(_ enabled: Bool) {
        let engine = self.engine
        Task { @MainActor in
            do {
                if enabled {
                    try await engine.enableWhitePoint()
                } else {
                    await engine.disableWhitePoint()
                }
            } catch {
                CameraKitLog.error(.engine, "[wb] setWhitePoint(\(enabled)) threw: \(error)")
            }
            await self.syncCalibrationState()
        }
    }

    /// Toggles the WB **chroma residual** on/off via `enableWhiteBalance()` /
    /// `disableWhiteBalance()` (§5.2). `enableWhiteBalance()` throws unless WB is
    /// calibrated and locked; disabling chroma also disables white point. The toggle
    /// reflects the engine's gated truth from the snapshot.
    func setWhiteBalanceEnabled(_ enabled: Bool) {
        let engine = self.engine
        Task { @MainActor in
            do {
                if enabled {
                    try await engine.enableWhiteBalance()
                } else {
                    await engine.disableWhiteBalance()
                }
            } catch {
                CameraKitLog.error(.engine, "[wb] setWhiteBalanceEnabled(\(enabled)) threw: \(error)")
            }
            await self.syncCalibrationState()
        }
    }

    /// Discards the WB chroma + white-point calibration (software only) via
    /// `clearWhiteBalance()`. The hardware WB mode is untouched (use "Auto").
    func clearWB() {
        let engine = self.engine
        Task { @MainActor in
            await engine.clearWhiteBalance()
            await self.syncCalibrationState()
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

    /// Triggers black-point calibration via the engine's `calibrateBlack()`.
    ///
    /// linear-normalization-stage: the linear, pre-grade black point. Point the
    /// camera at a dark field, then tap — the engine reads back the frame, derives
    /// `mean + k·σ` per channel in linear light, applies + enables the black point.
    /// Resyncs the `ProcessingViewModel` mirror. On failure (field not dark enough)
    /// the operator-facing reason is published to `blackPointError` for display.
    func calibrateBP() {
        let engine = self.engine
        Task { @MainActor in
            self.bpCalibrating = true
            self.blackPointError = nil
            defer { self.bpCalibrating = false }
            do {
                self.lastBlackPointDebug = try await engine.calibrateBlack()
                await self.syncCalibrationState()
            } catch let EngineError.blackPointCalibrationFailed(reason) {
                self.blackPointError = reason
            } catch {
                self.blackPointError = "Black-point calibration failed: \(error)"
            }
        }
    }

    /// Toggles the calibrated black point on/off via `enableBlackPoint()` /
    /// `disableBlackPoint()` (no recalibration). `enableBlackPoint()` throws
    /// `EngineError.blackPointNotCalibrated` if it was never calibrated.
    func setBlackPointEnabled(_ enabled: Bool) {
        let engine = self.engine
        Task { @MainActor in
            do {
                if enabled {
                    try await engine.enableBlackPoint()
                } else {
                    await engine.disableBlackPoint()
                }
            } catch {
                CameraKitLog.error(.engine, "[bp] setBlackPointEnabled(\(enabled)) threw: \(error)")
            }
            await self.syncCalibrationState()
        }
    }

    /// Clears the applied black point ("undo") — discards the offsets and refreshes.
    func clearBP() {
        let engine = self.engine
        Task { @MainActor in
            await engine.clearBlackPoint()
            self.lastBlackPointDebug = nil
            self.blackPointError = nil
            await self.syncCalibrationState()
        }
    }
}
