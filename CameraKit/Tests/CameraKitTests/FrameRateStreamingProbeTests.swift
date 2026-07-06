import Foundation
import Testing

@testable import CameraKit

/// Regression guard for the configurable-frame-rate lock (configurable-frame-rate).
///
/// The frame-rate lock (`activeVideoMin/MaxFrameDuration`) must be applied AFTER
/// `commitConfiguration` in `CameraSession.configure`: a `sessionPreset` change
/// resets it (Apple docs), so an earlier lock is silently wiped and the session
/// runs at the format default instead of `targetFps`. This suite opens each
/// suspect `(resolution, fps)` at INITIAL open and asserts, via the non-tautological
/// hardware read-back `_activeFrameRateRangeForTest`, that the lock is EXACT
/// (min == max == targetFps) — not a range — and that frames actually stream.
///
/// Device-only (serialized to avoid camera contention). Measurements are also
/// logged (`PROBE` markers in `camerakit.log`) for debugging.
@Suite("FrameRateStreamingProbeTests", .serialized)
struct FrameRateStreamingProbeTests {

    private struct Combo {
        let size: Size
        let fps: Int
        let label: String
    }

    /// Count frames delivered on `frameResultStream` within `seconds`.
    private func countFrames(_ engine: CameraEngine, seconds: Double) async -> Int {
        let stream = await engine.frameResultStream()
        let probe = Task { () -> Int in
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }
        try? await Task.sleep(for: .seconds(seconds))
        probe.cancel()
        return await probe.value
    }

    @Test func lockIsExactAndStreamsAtRequestedFps() async throws {
        let combos = [
            Combo(size: Size(width: 4032, height: 3024), fps: 30, label: "4032x3024@30"),
            Combo(size: Size(width: 4032, height: 3024), fps: 15, label: "4032x3024@15 (HDR-only)"),
            Combo(size: Size(width: 1920, height: 1440), fps: 15, label: "1920x1440@15"),
            Combo(size: Size(width: 1920, height: 1440), fps: 60, label: "1920x1440@60"),
        ]

        for combo in combos {
            let engine = CameraEngine(initialPhase: .active)
            let caps = try await engine.open(
                configuration: OpenConfiguration(
                    captureResolution: combo.size, targetFps: combo.fps))

            let size = try await engine._activeFormatSizeForTest()
            let rate = try await engine._activeFrameRateRangeForTest()
            var frames = await countFrames(engine, seconds: 5)
            if frames == 0 {
                // Transient camera contention (videoDeviceInUseByAnotherClient) can
                // steal a measurement window on a shared device. Retry once — the
                // engine's own recovery re-arms the session — before declaring a stall.
                try? await Task.sleep(for: .seconds(2))
                frames = await countFrames(engine, seconds: 5)
            }
            CameraKitLog.notice(
                .engine,
                "PROBE \(combo.label): applied=\(size.width)x\(size.height) "
                    + "locked=\(String(format: "%.1f", rate.minFps))-\(String(format: "%.1f", rate.maxFps))fps "
                    + "framesIn5s=\(frames)")

            // The requested resolution is honored.
            #expect(size == combo.size)
            // The lock is EXACT (min == max == targetFps) — the reorder fix — not a range.
            #expect(abs(rate.minFps - Double(combo.fps)) < 0.5)
            #expect(abs(rate.maxFps - Double(combo.fps)) < 0.5)
            // capabilities echoes the same locked rate.
            #expect(caps.activeFrameRate == combo.fps)
            // And frames actually stream (no stall).
            #expect(frames > 0)

            await engine.close()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
