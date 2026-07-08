import Foundation
import Testing

@testable import CameraKit

/// configurable-frame-rate — the fps-constrained exposure ceiling (pure) and the
/// open()/capabilities behaviors that need real hardware.
///
/// The exposure-ceiling math is unit-tested through the pure static helper
/// `CameraEngine.fpsConstrainedExposureRange` so it is deterministic without a
/// live session. The selection/locking behaviors (largest-4:3 default, locked
/// active frame rate, `(resolution, fps)` validation) run on real hardware in
/// `ConfigurableFrameRateDeviceTests`. HDR-off verification remains app HITL.
@Suite("ConfigurableFrameRateTests", .progressLogged)
struct ConfigurableFrameRateTests {

    // Sensor range on the test iPad: 0.024 ms … 1000 ms.
    private let sensor: ClosedRange<Int64> = 24_000...1_000_000_000

    @Test func exposureCeilingAt30Fps() {
        let r = CameraEngine.fpsConstrainedExposureRange(sensorRange: sensor, lockedFps: 30)
        #expect(r.lowerBound == 24_000)
        #expect(r.upperBound == 33_333_333)  // 1e9 / 30
    }

    @Test func exposureCeilingAt60Fps() {
        let r = CameraEngine.fpsConstrainedExposureRange(sensorRange: sensor, lockedFps: 60)
        #expect(r.lowerBound == 24_000)
        #expect(r.upperBound == 16_666_666)  // floor(1e9 / 60)
    }

    @Test func lowFpsKeepsSensorMax() {
        // At 1 fps the ceiling (1e9 ns) is not below the sensor max, so the sensor
        // upper bound wins — long exposures need a low targetFps.
        let r = CameraEngine.fpsConstrainedExposureRange(sensorRange: sensor, lockedFps: 1)
        #expect(r.upperBound == 1_000_000_000)
    }

    @Test func ceilingNeverInvertsTheRange() {
        // A degenerate sensor whose floor already exceeds the fps ceiling collapses
        // to a point rather than producing an inverted (upper < lower) range.
        let tightSensor: ClosedRange<Int64> = 40_000_000...1_000_000_000
        let r = CameraEngine.fpsConstrainedExposureRange(sensorRange: tightSensor, lockedFps: 60)
        #expect(r.lowerBound == 40_000_000)
        #expect(r.upperBound == 40_000_000)
    }
}

/// Real-open frame-rate behaviors (device only, serialized to avoid camera
/// contention). Mirrors `CameraCropConfigDeviceTests`.
@Suite("ConfigurableFrameRateDeviceTests", .serialized)
struct ConfigurableFrameRateDeviceTests {

    /// A default open (no `targetFps`, no `captureResolution`) locks 30 fps and lands
    /// on the largest 4:3 supported size, and capabilities expose the fps ranges.
    @Test func defaultOpenIsLargest4x3At30Fps() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let caps = try await engine.open(configuration: OpenConfiguration())
        #expect(caps.activeFrameRate == 30)
        // Active resolution is 4:3 …
        let active = caps.activeCaptureResolution
        #expect(active.width * 3 == active.height * 4)
        // … and the largest 4:3 among the supported sizes.
        let largest4x3 =
            caps.supportedSizes
            .filter { $0.width * 3 == $0.height * 4 }
            .max { ($0.width * $0.height) < ($1.width * $1.height) }
        #expect(active == largest4x3)
        #expect(!caps.supportedFrameRates.isEmpty)
        await engine.close()
    }

    /// Opening at 60 fps on a 60-capable resolution locks the active rate to 60.
    @Test func opensAt60OnACapableResolution() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let probe = try await engine.open(configuration: OpenConfiguration())
        let sixty = probe.supportedFrameRates.first { $0.maxFps >= 60 }
        await engine.close()
        guard let sixty else {
            Issue.record("device reported no 60fps-capable resolution")
            return
        }
        let caps = try await engine.open(
            configuration: OpenConfiguration(captureResolution: sixty.size, targetFps: 60))
        #expect(caps.activeFrameRate == 60)
        let measured = try await engine._activeFormatSizeForTest()
        #expect(measured == sixty.size)
        await engine.close()
    }

    /// A frame rate above what the requested resolution supports is rejected with
    /// `settingsConflict` (no silent coercion).
    @Test func unsupportedFrameRateThrows() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let probe = try await engine.open(configuration: OpenConfiguration())
        // A resolution whose max supported fps is below 60 (e.g. the 4K/HDR-only sizes).
        let thirtyOnly = probe.supportedFrameRates.first { $0.maxFps < 60 }
        await engine.close()
        guard let thirtyOnly else {
            Issue.record("device reported no sub-60fps resolution to exercise the reject path")
            return
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.open(
                configuration: OpenConfiguration(
                    captureResolution: thirtyOnly.size, targetFps: thirtyOnly.maxFps + 30))
            await engine.close()
        }
    }
}
