import Foundation
import Testing

@testable import CameraKit
@testable import FrameTransport

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
            Combo(size: Size(width: 3840, height: 2160), fps: 30, label: "3840x2160@30 (4K)"),
            Combo(size: Size(width: 3840, height: 2160), fps: 60, label: "3840x2160@60 (4K60 — suspect)"),
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

    /// BISECTION control: does a back-to-back close→reopen at 4K60 (no reconfigure,
    /// no settle gap) stall? Isolates the reopen dance from the resolution change.
    @Test func reopen4K60BackToBack() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let s4k = Size(width: 3840, height: 2160)
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s4k, targetFps: 60))
        let f1 = await countFrames(engine, seconds: 3)
        await engine.close()
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s4k, targetFps: 60))
        let f2 = await countFrames(engine, seconds: 3)
        CameraKitLog.notice(.engine, "BISECT reopen4K60BackToBack: firstOpen=\(f1) reopen=\(f2)")
        await engine.close()
        #expect(f1 > 0)
        #expect(f2 > 0)  // reopen must stream (reconciledSessionRunning reset in close)
    }

    /// BISECTION repro: the exact demo sequence — open 4032@30, setResolution to
    /// 3840×2160 (reconfigure, keeps 30), then close+reopen at 3840×2160@60 (the
    /// setTargetFps dance). Does step 3 stall like the demo?
    @Test func demoSequenceReconfigureThenReopen4K60() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let s4k = Size(width: 3840, height: 2160)
        _ = try await engine.open(
            configuration: OpenConfiguration(captureResolution: Size(width: 4032, height: 3024), targetFps: 30))
        let f1 = await countFrames(engine, seconds: 3)
        try await engine.setResolution(size: s4k)
        let f2 = await countFrames(engine, seconds: 3)
        await engine.close()
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s4k, targetFps: 60))
        let f3 = await countFrames(engine, seconds: 3)
        CameraKitLog.notice(
            .engine,
            "BISECT demoSequence: open4032@30=\(f1) setRes3840=\(f2) reopen3840@60=\(f3)")
        await engine.close()
        #expect(f1 > 0)
        #expect(f3 > 0)  // the fps-change reopen (setTargetFps dance) must stream
    }

    /// BISECTION: does a 2 s settle gap between close and reopen fix the 4K60 stall?
    /// If yes → the cause is incomplete hardware teardown (timing); if no → structural.
    @Test func reopen4K60WithSettleGap() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let s4k = Size(width: 3840, height: 2160)
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s4k, targetFps: 60))
        let f1 = await countFrames(engine, seconds: 3)
        await engine.close()
        try? await Task.sleep(for: .seconds(2))
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s4k, targetFps: 60))
        let f2 = await countFrames(engine, seconds: 3)
        CameraKitLog.notice(.engine, "BISECT reopen4K60WithSettleGap: firstOpen=\(f1) reopenAfter2s=\(f2)")
        await engine.close()
        #expect(f1 > 0)
    }

    /// BISECTION: is close→reopen broken at a MODEST resolution too, or only 4K60?
    @Test func reopenModestBackToBack() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let s = Size(width: 1920, height: 1440)
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s, targetFps: 30))
        let f1 = await countFrames(engine, seconds: 3)
        await engine.close()
        _ = try await engine.open(configuration: OpenConfiguration(captureResolution: s, targetFps: 30))
        let f2 = await countFrames(engine, seconds: 3)
        CameraKitLog.notice(.engine, "BISECT reopenModestBackToBack: firstOpen=\(f1) reopen=\(f2)")
        await engine.close()
        #expect(f2 > 0)  // reopen must stream at a modest resolution too
    }

    /// Defensive guarantee: a user `open()` that delivers no frame within the
    /// deadline THROWS `sessionLifecycleTimeout` instead of returning a dead session
    /// (silent black preview). Forced deterministically via a 1 ms timeout override,
    /// which fires before any real first frame (~100–200 ms). This is what makes a
    /// no-frame condition impossible for a library caller to hit silently.
    @Test func openThrowsWhenFirstFrameTimesOut() async throws {
        let engine = CameraEngine(initialPhase: .active)
        await engine._setFirstFrameTimeoutForTest(0.001)
        await #expect(throws: EngineError.self) {
            _ = try await engine.open(configuration: OpenConfiguration())
        }
        await engine.close()
    }

    /// recovery-restart-budget: a subscribed consumer lane survives recovery quick
    /// reopens AND full restarts (transparent restart — subscriber preserved), and
    /// is terminated ONLY at the terminal fatal after escalation is exhausted.
    /// Budgets are shrunk (2 quick, 1 full restart → fatal on the 6th reopen) and
    /// frames suppressed so escalation advances deterministically.
    @Test func recoveryPreservesConsumersUntilTerminalFatal() async throws {
        let engine = CameraEngine(initialPhase: .active)
        _ = try await engine.open()
        // Subscribe a lane and hold the stream so the subscription stays registered.
        let stream = await engine.consumers.subscribe(stream: .primary, buffering: .latestWins)
        _ = stream
        #expect(engine.consumers.subscriberCount(for: .primary) == 1)

        await engine._suppressFrameDeliveryForTest(true)
        await engine._setRecoveryBudgetsForTest(maxQuick: 2, maxFullRestarts: 1)

        // Non-terminal escalation: 2 quick + 1 full restart + 2 quick = 5 reopens.
        // The subscription MUST survive every one (restart is transparent).
        for _ in 1...5 {
            try? await engine._triggerRecoveryReopenForTest()
            #expect(engine.consumers.subscriberCount(for: .primary) == 1)
        }
        // The 6th reopen is the terminal fatal → failAllLanes → subscriber removed.
        try? await engine._triggerRecoveryReopenForTest()
        #expect(engine.consumers.subscriberCount(for: .primary) == 0)

        await engine.close()
    }
}
