import Foundation
import Testing

@testable import CameraKit

// Single home for every lifecycle test — app-lifecycle phase forwarding,
// device-interruption handling, scenePhase mirroring, and the reconciliation
// surface added by the lifecycle-ownership work. New lifecycle tests belong
// here (grouped by `// MARK:`), not scattered across stage files. The relocated
// suites below were moved verbatim from Stage09Tests / Stage13Phase2Tests; their
// provenance lives in git history.

// MARK: - ManualClock (moved with the Hitl tests — its only users)

/// Clock whose `sleep` yields without advancing time; `advanceMs` moves it.
///
/// Unlike `TestClock` (whose `sleep` auto-advances and makes a watchdog poller
/// self-fire immediately), this lets a test hold the poller in its wait loop and
/// control exactly when it crosses the stall threshold.
final class ManualClock: CameraKitClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _nowMs: UInt64 = 0
    func nowMs() -> UInt64 { lock.withLock { _nowMs } }
    func sleep(milliseconds: Int) async throws { await Task.yield() }
    func advanceMs(_ d: UInt64) { lock.withLock { _nowMs &+= d } }
}

@Suite("Lifecycle", .progressLogged)
struct LifecycleTests {

    // MARK: - Relocated: background/interrupt FSM (from Stage09 HitlLifecycleTests)
    //
    // Regression coverage for the background/interrupt FSM crash. Two off-map
    // `SessionState` transitions aborted the app on backgrounding (measurements
    // 2026-05-20 §1): `interrupted → recovering` (a stall watchdog firing while
    // the OS interrupted the session) and `recovering → streaming` (a scenePhase
    // resume forced over an in-flight recovery). Both are fixed at the trigger,
    // not by widening the transition maps.

    /// Crash #1 regression: the stall watchdog must disarm on interruption.
    ///
    /// It previously stayed armed while the OS interrupted the session, fired
    /// with no frames, and drove `interrupted → recovering` (off-map — it
    /// aborted DEBUG builds before Fix 2; now logged + applied but still a
    /// spurious recovery). The fix disarms watchdogs on `.otherInterruption`.
    @Test("interrupted disarms stall watchdog — clock past threshold emits no .recovering")
    func interruptedDisarmsWatchdog() async {
        let clock = ManualClock()
        let engine = CameraEngine(initialPhase: .active, clock: clock)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)

        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        #expect(await engine._currentStateForTest == .interrupted)
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdog must disarm when the session is interrupted")

        // Push well past the capture stall threshold; the disarmed poller must
        // not fire recovery while interrupted.
        clock.advanceMs(UInt64(Constants.stallCaptureThresholdMs) + 1000)
        for _ in 0..<50 { await Task.yield() }
        #expect(
            await engine._currentStateForTest == .interrupted,
            "no .recovering may be emitted while interrupted")

        await engine.close()
    }

    /// `.otherInterruptionEnded` resumes frame delivery, so the watchdog must re-arm.
    @Test("interruption-ended re-arms the stall watchdog and returns to .streaming")
    func interruptionEndedRearmsWatchdog() async {
        let clock = ManualClock()
        let engine = CameraEngine(initialPhase: .active, clock: clock)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()

        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        #expect(await engine._captureWatchdogArmedTokenForTest == nil)

        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(await engine._currentStateForTest == .streaming)
        #expect(
            await engine._captureWatchdogArmedTokenForTest != nil,
            "watchdog must re-arm when the interruption ends")

        await engine.close()
    }

    /// Crash #3 regression: interruption-ended while backgrounded must NOT re-arm.
    ///
    /// On backgrounding, `stopRunning` triggers an OS interruption whose
    /// `.otherInterruptionEnded` fires while the app is still backgrounded — the
    /// gate is closed and no frames flow. The old unconditional re-arm armed the
    /// stall watchdog anyway; it fired ~9 s later with no frames and drove
    /// `interrupted → recovering` (off-map — aborted DEBUG builds before Fix 2;
    /// now a spurious recovery — measurements 2026-05-20 §1 case #14).
    /// `armWatchdogs()` is now gate-guarded, so the
    /// watchdog only arms when frames can actually flow. This also pins the
    /// "Known gap" documented on `notifyScenePhasePaused` (state reads
    /// `.streaming` while the gate stays closed) as a tested invariant.
    @Test("interruption-ended while backgrounded (gate closed) does not re-arm the watchdog")
    func interruptionEndedWhileBackgroundedDoesNotRearm() async {
        let clock = ManualClock()
        let engine = CameraEngine(initialPhase: .active, clock: clock)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)

        // Background: gate closes, then the OS interrupts the session.
        await engine.setGate(false)
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        #expect(await engine._captureWatchdogArmedTokenForTest == nil)

        // The interruption "ends" while still backgrounded — must NOT re-arm.
        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(await engine._currentStateForTest == .streaming)
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdog must stay disarmed while the gate is closed (backgrounded)")

        // Pushing past the stall threshold must not drive a spurious recovery —
        // the disarmed poller cannot fire, so state stays .streaming.
        clock.advanceMs(UInt64(Constants.stallCaptureThresholdMs) + 1000)
        for _ in 0..<50 { await Task.yield() }
        #expect(
            await engine._currentStateForTest == .streaming,
            "no spurious recovery may fire while backgrounded (gate closed)")

        await engine.close()
    }

    /// Crash #2 regression: a scenePhase resume while interrupted is ignored.
    ///
    /// `notifyScenePhasePaused(false)` arriving while `.interrupted` previously
    /// forced `→ .streaming` as a command (off-map — it aborted DEBUG builds
    /// before Fix 2, and would still overwrite the OS-authoritative state). The
    /// guard makes resume a no-op unless the engine is paused.
    @Test("scenePhase resume while interrupted is ignored (no off-map command)")
    func scenePhaseResumeIgnoredWhileInterrupted() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        #expect(await engine._currentStateForTest == .interrupted)

        await engine.notifyScenePhasePaused(false)
        #expect(
            await engine._currentStateForTest == .interrupted,
            "resume must not override the OS-authoritative .interrupted state")

        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(await engine._currentStateForTest == .streaming)
    }

    /// The same guard must protect `.recovering`: a resume during a real
    /// recovery must not force `recovering → streaming` (off-map command).
    @Test("scenePhase resume while recovering is ignored")
    func scenePhaseResumeIgnoredWhileRecovering() async {
        let clock = ManualClock()
        let engine = CameraEngine(initialPhase: .active, clock: clock)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()

        await engine._postSessionEventForTest(.runtimeError("boom"))
        #expect(await engine._currentStateForTest == .recovering)

        await engine.notifyScenePhasePaused(false)
        #expect(
            await engine._currentStateForTest == .recovering,
            "resume must not override an in-flight recovery")

        await engine.close()
    }

    /// The guard must still allow the legitimate scenePhase edges, including the
    /// pre-open `closed → paused` publish (D-2P-07).
    @Test("scenePhase mirror still allows closed→paused (pre-open) and streaming↔paused")
    func scenePhaseMirrorAllowsLegitEdges() async {
        let engine = CameraEngine(initialPhase: .active)
        // Pre-open pause publishes .paused from .closed (D-2P-07).
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .paused)
        // Resume mirrors paused → streaming.
        await engine.notifyScenePhasePaused(false)
        #expect(await engine._currentStateForTest == .streaming)
        // And streaming → paused round-trips.
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .paused)
    }

    // MARK: - Relocated: interrupted-state toggle (from Stage13Phase2InterruptedStateTests)

    @Test(".otherInterruption publishes .interrupted; .otherInterruptionEnded reverts to .streaming")
    func otherInterruptionTogglesInterruptedState() async {
        let engine = CameraEngine(initialPhase: .active)
        // Post-Stage-12: SessionStateMachine treats `.closed → .interrupted
        // (event)` as off-map (AVF only fires `.otherInterruption` against a
        // running session; the test was bypassing that precondition). Set the
        // realistic precondition via the existing test seam.
        await engine._markOpenForTest()
        let states = await engine.stateStream()
        // Drain in this task; post events from a child task with a tiny stagger
        // so the stream is being consumed when the events fire.
        let poster = Task {
            try? await Task.sleep(for: .milliseconds(50))
            await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
            await engine._postSessionEventForTest(.otherInterruptionEnded)
        }
        var observed: [SessionState] = []
        for await s in states {
            observed.append(s)
            if observed.count >= 2 { break }
        }
        _ = await poster.value
        #expect(observed.contains(.interrupted), "observed=\(observed)")
        #expect(observed.last == .streaming, "observed=\(observed)")
    }

    // MARK: - Relocated: scenePhase × interruption off-map guard (from Stage13Phase2ScenePhaseMirrorGuardTests)
    //
    // Regression for the `interrupted → streaming (command)` off-map trap.
    // Caught under `test_device`: a harness/bring-up AVF interruption drives the
    // engine to `.interrupted`, then a `.active` scenePhase made
    // `notifyScenePhasePaused` publish `.streaming (command)` — off-map from
    // `.interrupted`, which tripped the `publishState` `assertionFailure` before
    // Fix 2 (off-map is now logged + applied, not fatal) and would still
    // overwrite the OS-authoritative state. The mirror now defers to the
    // classifier (`SessionStateMachine` is SSOT) when the origin is OS-owned.

    /// Drive engine `.streaming → .interrupted` via the same seam the existing
    /// interrupted-state test uses, mirroring the `test_device` precondition.
    private func makeInterruptedEngine() async -> CameraEngine {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        #expect(await engine._currentStateForTest == .interrupted)
        return engine
    }

    @Test("from .interrupted, notifyScenePhasePaused(false) does not force .streaming (command)")
    func scenePhaseActiveFromInterruptedIsSkipped() async {
        let engine = await makeInterruptedEngine()
        // Pre-fix: off-map `.interrupted → .streaming (command)` overwrote the
        // OS-authoritative state (and aborted DEBUG builds before Fix 2).
        await engine.notifyScenePhasePaused(false)
        #expect(await engine._currentStateForTest == .interrupted)
    }

    @Test("from .interrupted, notifyScenePhasePaused(true) does not force .paused (command)")
    func scenePhaseInactiveFromInterruptedIsSkipped() async {
        let engine = await makeInterruptedEngine()
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .interrupted)
    }

    @Test("OS event path still restores .streaming after the mirror deferred")
    func interruptionEndStillRestoresStreaming() async {
        let engine = await makeInterruptedEngine()
        await engine.notifyScenePhasePaused(false)  // deferred, no-op
        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(await engine._currentStateForTest == .streaming)
    }

    @Test("positive control: from .streaming the mirror still publishes .paused (command)")
    func scenePhaseMirrorStillWorksFromStreaming() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()  // .streaming
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .paused)
        await engine.notifyScenePhasePaused(false)
        #expect(await engine._currentStateForTest == .streaming)
    }

    // MARK: - Public surface

    /// `AppLifecyclePhase` is a public, `Sendable` enum with the three host-facing cases.
    @Test("AppLifecyclePhase is public + Sendable with three cases")
    func appLifecyclePhaseIsPublicSendable() {
        func requireSendable<T: Sendable>(_: T) {}
        let all: [AppLifecyclePhase] = [.active, .inactive, .background]
        requireSendable(all[0])
        #expect(all.count == 3)
    }

    // MARK: - Construction

    /// `initialPhase` is required at construction and recorded as `currentPhase`.
    ///
    /// Pre-`open()` the engine only stores the phase (no hardware exists yet). The
    /// reconciliation that *acts* on it — opening into `.background` not starting
    /// the session, etc. — lands with the reconcile routine (Task 5), and is
    /// tested there.
    @Test("initialPhase is required and recorded as currentPhase")
    func initialPhaseIsRecordedAtConstruction() async {
        func label(_ p: AppLifecyclePhase) -> String {
            switch p {
            case .active: return "active"
            case .inactive: return "inactive"
            case .background: return "background"
            }
        }
        let bg = CameraEngine(initialPhase: .background)
        #expect(label(await bg._currentPhaseForTest) == "background")
        let active = CameraEngine(initialPhase: .active)
        #expect(label(await active._currentPhaseForTest) == "active")
    }

    // MARK: - Reconciliation

    /// `.active → .inactive → .active` is a cheap pause: only the gate flips and
    /// the watchdogs toggle; the session is never stopped (~4 ms, not ~410 ms).
    @Test("cheap pause: active→inactive→active never stops the session")
    func cheapPauseDoesNotStopSession() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        // Baseline (.active): session running, gate open, watchdogs armed.
        #expect(await engine._isSessionRunningForTest == true)
        #expect(await engine.isGateOpen == true)
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)

        await engine.setLifecyclePhase(.inactive)
        #expect(
            await engine._isSessionRunningForTest == true,
            "cheap pause must keep the session running")
        #expect(await engine.isGateOpen == false, "gate closes at .inactive")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdogs disarm at .inactive")

        await engine.setLifecyclePhase(.active)
        #expect(await engine._isSessionRunningForTest == true)
        #expect(await engine.isGateOpen == true, "gate reopens at .active")
        #expect(
            await engine._captureWatchdogArmedTokenForTest != nil,
            "watchdogs re-arm at .active")

        await engine.close()
    }

    /// F4: launching into `.background` must not turn the camera on — no
    /// `startRunning`, gate closed (no privacy indicator with no foreground UI).
    ///
    /// Asserts the post-open state `open()`-then-`reconcile` leaves for a
    /// `.background` launch via the phase-aware `_markOpenForTest` seam (real
    /// `open()` needs hardware; the wiring is covered by Task 13 device HITL).
    @Test("open into .background does not start the session (F4)")
    func openIntoBackgroundDoesNotStartSession() async {
        let engine = CameraEngine(initialPhase: .background)
        await engine._markOpenForTest()
        #expect(
            await engine._isSessionRunningForTest == false,
            "no startRunning when launched into background")
        #expect(await engine.isGateOpen == false, "gate stays closed in background")
        await engine.close()
    }

    /// `.active → .background` runs the ordered suspend: gate closes, watchdogs
    /// disarm, the session stops, in the field-guide §5 order disarm→drain→stop.
    ///
    /// The finalize-before-stop step needs a live recording (and `_markOpenForTest`
    /// builds none), so finalize ordering is a device-HITL claim (Task 13); this
    /// asserts the hardware-free steps and their order.
    @Test("suspend: active→background stops the session in disarm→drain→stop order")
    func backgroundSuspendFinalizesAndStops() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)
        #expect(await engine._isSessionRunningForTest == true)

        await engine.setLifecyclePhase(.background)

        #expect(await engine._isSessionRunningForTest == false, "session stops in background")
        #expect(await engine.isGateOpen == false, "gate closed in background")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdogs disarmed in background")

        let actions = await engine._backgroundActionsForTest
        #expect(
            actions.firstIndex(of: "disarm") != nil
                && actions.firstIndex(of: "drain") != nil
                && actions.firstIndex(of: "stop") != nil,
            "missing a step: \(actions)")
        if let d = actions.firstIndex(of: "disarm"),
            let dr = actions.firstIndex(of: "drain"),
            let s = actions.firstIndex(of: "stop")
        {
            #expect(d < dr && dr < s, "expected disarm<drain<stop, got \(actions)")
        }

        await engine.close()
    }

    /// `.background → .inactive → .active` is the resume ordering both SwiftUI and
    /// Flutter emit.
    ///
    /// The session restarts at `.inactive` (gate still closed), the gate opens at
    /// `.active` — the case the old `cameFromBackground` flag handled, now falling
    /// out of the declarative model with no flag.
    @Test("resume: background→inactive→active restarts at inactive (gate closed), opens at active")
    func resumeRestartsAtInactiveGateOpensAtActive() async {
        let engine = CameraEngine(initialPhase: .background)
        await engine._markOpenForTest()  // open into background: not running, gate closed
        await engine._armWatchdogsForTest()  // pair built; arm skipped (gate closed)
        #expect(await engine._isSessionRunningForTest == false)
        #expect(await engine.isGateOpen == false)
        #expect(await engine._captureWatchdogArmedTokenForTest == nil)

        await engine.setLifecyclePhase(.inactive)
        #expect(
            await engine._isSessionRunningForTest == true,
            "session restarts at .inactive (no cameFromBackground flag needed)")
        #expect(await engine.isGateOpen == false, "gate stays closed at .inactive")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdogs stay disarmed at .inactive")

        await engine.setLifecyclePhase(.active)
        #expect(await engine._isSessionRunningForTest == true)
        #expect(await engine.isGateOpen == true, "gate opens at .active")
        #expect(
            await engine._captureWatchdogArmedTokenForTest != nil,
            "watchdogs arm at .active")

        await engine.close()
    }

    /// Flutter emits `paused → hidden → inactive → resumed` →
    /// `.background → .background → .inactive → .active`.
    ///
    /// The duplicate `.background` must be a no-op and the sequence must converge
    /// to the same terminal `.active` state as the SwiftUI resume.
    @Test("Flutter resume: duplicate .background is idempotent and converges to active")
    func duplicateBackgroundIsNoOpAndConverges() async {
        let engine = CameraEngine(initialPhase: .background)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()

        await engine.setLifecyclePhase(.background)  // duplicate of the launch phase
        #expect(
            await engine._isSessionRunningForTest == false,
            "duplicate .background is a no-op")
        #expect(await engine.isGateOpen == false)
        #expect(await engine._captureWatchdogArmedTokenForTest == nil)

        await engine.setLifecyclePhase(.inactive)
        #expect(await engine._isSessionRunningForTest == true, "restarts at .inactive")
        #expect(await engine.isGateOpen == false)

        await engine.setLifecyclePhase(.active)
        #expect(await engine._isSessionRunningForTest == true)
        #expect(await engine.isGateOpen == true, "converges to .active: gate open")
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)

        await engine.close()
    }

    // MARK: - Latest-intent-wins

    /// F1: a `.background` reconcile straggled by a completing `.active` must
    /// abort, not apply a stale `stopRunning`.
    ///
    /// Without the generation guard the straggler runs drain/stop after `.active`
    /// already reopened the gate + re-armed, leaving gate-open + armed +
    /// session-stopped — a permanent black preview and spurious recovery with no
    /// OS interruption involved. The park seam admits `.active` while
    /// `.background` is suspended mid-flight.
    @Test("latest-intent-wins: .background superseded by .active ends .active (F1)")
    func backgroundSupersededByActiveEndsActive() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        #expect(await engine._isSessionRunningForTest == true)

        // Park the .background reconcile mid-flight (post-disarm, pre-stop).
        await engine._armBackgroundReconcileParkForTest()
        let bg = Task { await engine.setLifecyclePhase(.background) }
        while await engine._isBackgroundReconcileParkedForTest == false {
            await Task.yield()
        }

        // Admit .active while .background is parked. Its branch has no awaits, so
        // it completes and bumps the reconcile generation.
        await engine.setLifecyclePhase(.active)

        // Release the straggler — it must detect supersession and abort before
        // touching the session the .active just kept running.
        await engine._releaseBackgroundReconcileParkForTest()
        await bg.value

        #expect(
            await engine._isSessionRunningForTest == true,
            "the .active that won must not be undone by the stale .background stop")
        #expect(await engine.isGateOpen == true, "gate stays open (.active won)")
        #expect(
            await engine._captureWatchdogArmedTokenForTest != nil,
            "watchdogs stay armed (.active won)")
        #expect(
            await engine._currentStateForTest == .streaming,
            "no spurious recovery / off-map (state stays .streaming)")

        await engine.close()
    }
}
