import CameraKit
import Foundation

/// Hardware-control sliders for ISO / Shutter / Focus / Zoom.
///
/// Owns four `SliderDebouncer`s that coalesce 240 Hz slider input to ≤60 Hz
/// (brief §7 mechanism-independent assertion). Each push translates a raw slider
/// value into a `CameraSettings` delta and dispatches via `engine.updateSettings`.
/// Owns `currentSettings` as a local mirror seeded from the persisted snapshot.
///
/// Hardware vs Processing kept separate: different engine endpoints
/// (`updateSettings` vs `setProcessingParameters`), different failure modes
/// (hardware can fail per device caps; processing cannot), different
/// concurrency concerns.
@Observable @MainActor
final class HardwareControlsViewModel {

    /// Local mirror of the device-applied `CameraSettings`.
    ///
    /// Seeded from `engine.currentSettingsSnapshot()` in `start()`; updated
    /// optimistically after each successful `engine.updateSettings(delta)`.
    var currentSettings: CameraSettings = CameraSettings()

    @ObservationIgnored private var isoDebouncer: SliderDebouncer?
    @ObservationIgnored private var shutterDebouncer: SliderDebouncer?
    @ObservationIgnored private var focusDebouncer: SliderDebouncer?
    @ObservationIgnored private var zoomDebouncer: SliderDebouncer?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Seed `currentSettings` from engine snapshot + start the four debouncers.
    func start() async {
        if let restored = await engine.currentSettingsSnapshot() {
            currentSettings = restored
        }

        let engine = self.engine
        let applyDelta: @Sendable (CameraSettings) async -> Void = { [weak self] delta in
            do {
                try await engine.updateSettings(delta)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentSettings = delta.merging(onto: self.currentSettings)
                }
            } catch {
                CameraKitLog.warning(
                    .engine, "updateSettings failed: \(String(describing: error))")
                // ADR-22 errorStream is not yet wired for inline `updateSettings`
                // throws. Routing user-facing toasts here is DEFERRED to a
                // future engine pass; the warning lands in Console only.
            }
        }

        isoDebouncer = SliderDebouncer { v in
            var d = CameraSettings()
            d.isoMode = .manual
            d.iso = Int(v)
            await applyDelta(d)
        }
        shutterDebouncer = SliderDebouncer { v in
            var d = CameraSettings()
            d.exposureMode = .manual
            d.exposureTimeNs = Int64(v)
            await applyDelta(d)
        }
        focusDebouncer = SliderDebouncer { v in
            var d = CameraSettings()
            d.focusMode = .manual
            d.focusDistance = v
            await applyDelta(d)
        }
        zoomDebouncer = SliderDebouncer { v in
            var d = CameraSettings()
            d.zoomRatio = v
            await applyDelta(d)
        }

        await isoDebouncer?.start()
        await shutterDebouncer?.start()
        await focusDebouncer?.start()
        await zoomDebouncer?.start()
    }

    func stop() async {
        await isoDebouncer?.stop()
        await shutterDebouncer?.stop()
        await focusDebouncer?.stop()
        await zoomDebouncer?.stop()
        isoDebouncer = nil
        shutterDebouncer = nil
        focusDebouncer = nil
        zoomDebouncer = nil
    }

    // MARK: - Push from view's slider onChange

    func pushISO(_ v: Double) { isoDebouncer?.push(v) }
    func pushShutter(_ v: Double) { shutterDebouncer?.push(v) }
    func pushFocus(_ v: Double) { focusDebouncer?.push(v) }
    func pushZoom(_ v: Double) { zoomDebouncer?.push(v) }
}
