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
    /// `.otherInterruptionEnded` can fire while the app is still backgrounded. The
    /// old unconditional re-arm armed the stall watchdog anyway; it fired ~9 s
    /// later with no frames and drove `interrupted → recovering` (off-map —
    /// aborted DEBUG builds before Fix 2; now a spurious recovery — measurements
    /// 2026-05-20 §1 case #14). Now the OS-recovery exit reconciles against
    /// `currentPhase` (Task 8): while `.background` the session stays stopped and
    /// the watchdogs disarmed, so no spurious recovery can fire. The terminal
    /// label settles at `.paused` — Task 7's reconcile-owned label CLOSES the old
    /// "Known gap" (state used to read `.streaming` while the gate stayed closed).
    /// Migrated from a direct `setGate(false)` to the lifecycle API, the new-model
    /// equivalent of backgrounding.
    @Test("interruption-ended while backgrounded does not re-arm; settles at .paused")
    func interruptionEndedWhileBackgroundedDoesNotRearm() async {
        let clock = ManualClock()
        let engine = CameraEngine(initialPhase: .active, clock: clock)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        #expect(await engine._captureWatchdogArmedTokenForTest != nil)

        // Background via the lifecycle API: session stops, watchdogs disarm, gate
        // closes (reconcile against `.background`).
        await engine.setLifecyclePhase(.background)
        #expect(await engine._captureWatchdogArmedTokenForTest == nil)

        // The OS interrupts the (already stopped) session, then "ends" while still
        // backgrounded — the OS-recovery exit must NOT re-arm or restart.
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(
            await engine._currentStateForTest == .paused,
            "backgrounded interruption-ended reconciles to .paused (gap closed)")
        #expect(
            await engine._isSessionRunningForTest == false,
            "session stays stopped while backgrounded (no camera LED)")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdog must stay disarmed while backgrounded")

        // Pushing past the stall threshold must not drive a spurious recovery —
        // the disarmed poller cannot fire, so state stays .paused.
        clock.advanceMs(UInt64(Constants.stallCaptureThresholdMs) + 1000)
        for _ in 0..<50 { await Task.yield() }
        #expect(
            await engine._currentStateForTest == .paused,
            "no spurious recovery may fire while backgrounded")

        await engine.close()
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
        // Positive-control: the host command publishes the .paused label from a
        // running .streaming origin (the direct-publish coverage formerly held by
        // the retired scenePhaseMirrorStillWorksFromStreaming test).
        #expect(
            await engine._currentStateForTest == .paused,
            ".inactive publishes the .paused command label from .streaming")

        await engine.setLifecyclePhase(.active)
        #expect(await engine._isSessionRunningForTest == true)
        #expect(await engine.isGateOpen == true, "gate reopens at .active")
        #expect(
            await engine._captureWatchdogArmedTokenForTest != nil,
            "watchdogs re-arm at .active")
        #expect(
            await engine._currentStateForTest == .streaming,
            ".active publishes the .streaming command label")

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
        await engine._installLifecycleTestHookForTest()  // record the suspend trace

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

    // MARK: - OS-owned guard

    /// F2: a `.active` reconcile while the OS owns the device neither re-arms the
    /// watchdogs nor restarts the session, and does not overwrite the OS label.
    ///
    /// Two constructions. Foreground (the realistic F2): session running + armed,
    /// an interruption disarms the watchdogs, and a host `.active` must NOT re-arm
    /// them — a re-armed watchdog fires a spurious stall → recovery while frames
    /// are still OS-stopped. Background: the session-start half of the guard is
    /// observable only when the running mirror is `false` going in (a foreground
    /// interruption leaves it `true`, so the start is a no-op there). The gate
    /// opens unconditionally in `.active` — the guard is on start/arm/label, not
    /// the gate (frames are OS-stopped, so an open gate has nothing to submit).
    @Test("OS-owned guard: .active reconcile while OS-owned neither re-arms nor starts (F2)")
    func activeReconcileDefersWhileOSOwnsDevice() async {
        let fg = CameraEngine(initialPhase: .active)
        await fg._markOpenForTest()  // running, gate open
        await fg._armWatchdogsForTest()  // armed (gate open)
        #expect(await fg._captureWatchdogArmedTokenForTest != nil)
        await fg._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        #expect(await fg._currentStateForTest == .interrupted)
        #expect(
            await fg._captureWatchdogArmedTokenForTest == nil,
            "interruption disarmed the watchdogs")

        await fg.setLifecyclePhase(.active)
        #expect(
            await fg._captureWatchdogArmedTokenForTest == nil,
            "F2: .active must not re-arm watchdogs while the OS owns the device")
        #expect(
            await fg._currentStateForTest == .interrupted,
            "label stays OS truth (.interrupted), not overwritten by .streaming")
        #expect(
            await fg.isGateOpen == true,
            "gate opens in .active regardless — guard is on start/arm/label, not the gate")
        await fg.close()

        let bg = CameraEngine(initialPhase: .background)
        await bg._markOpenForTest()  // stopped, gate closed
        await bg._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        #expect(await bg._currentStateForTest == .interrupted)
        #expect(await bg._isSessionRunningForTest == false)
        await bg.setLifecyclePhase(.active)
        #expect(
            await bg._isSessionRunningForTest == false,
            "F2: no startRunning while the OS owns the device")
        await bg.close()
    }

    /// A host command label (`setLifecyclePhase`) cannot overwrite OS truth while
    /// the OS owns the device.
    ///
    /// Both command directions defer: `.active` (would publish `.streaming`) and
    /// `.inactive` (would publish `.paused`), covered across all three OS-owned
    /// origins — an `.interrupted` origin, a terminal `.error`
    /// (`videoDeviceInUseByAnotherClient`), and an in-flight `.recovering`.
    @Test("OS-owned guard: setLifecyclePhase can't overwrite the OS label")
    func commandLabelDefersUnderOSOwnership() async {
        let interrupted = CameraEngine(initialPhase: .active)
        await interrupted._markOpenForTest()
        await interrupted._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        #expect(await interrupted._currentStateForTest == .interrupted)
        await interrupted.setLifecyclePhase(.active)
        #expect(
            await interrupted._currentStateForTest == .interrupted,
            ".active (.streaming) command deferred under .interrupted")
        await interrupted.setLifecyclePhase(.inactive)
        #expect(
            await interrupted._currentStateForTest == .interrupted,
            ".inactive (.paused) command deferred under .interrupted")
        await interrupted.close()

        let errored = CameraEngine(initialPhase: .active)
        await errored._markOpenForTest()
        await errored._postSessionEventForTest(.cameraInUseBegan)
        #expect(await errored._currentStateForTest == .error)
        await errored.setLifecyclePhase(.active)
        #expect(
            await errored._currentStateForTest == .error,
            ".active (.streaming) command deferred under .error")
        await errored.close()

        // In-flight recovery is OS-owned too: a resume command must not force
        // `recovering → streaming` (folded in from the retired
        // scenePhaseResumeIgnoredWhileRecovering test, now via setLifecyclePhase).
        let recovering = CameraEngine(initialPhase: .active, clock: ManualClock())
        await recovering._markOpenForTest()
        await recovering._armWatchdogsForTest()
        await recovering._postSessionEventForTest(.runtimeError("boom"))
        #expect(await recovering._currentStateForTest == .recovering)
        await recovering.setLifecyclePhase(.active)
        #expect(
            await recovering._currentStateForTest == .recovering,
            ".active (.streaming) command deferred under an in-flight .recovering")
        await recovering.close()
    }

    /// Deferral parity for the `.opening → .paused` launch-race rider.
    ///
    /// From `.opening`, a `.paused` command defers but a `.streaming` command
    /// publishes — the rider preserves the launch race the old
    /// `classify(...) == .offMap` check covered (`commandMap[.opening]` has no
    /// `.paused`), so a pre-`open()` `.inactive`/`.background` phase must not
    /// strand the engine in `.paused` before `open()` publishes `.streaming`.
    @Test("deferral parity: .opening → .paused defers, .opening → .streaming publishes")
    func deferralParityOpeningToPaused() async {
        // `.opening` is set via `_setStateForTest` (not `_markOpenForTest`, which
        // lands in `.streaming` with different deferral semantics): it leaves the
        // state machine at `.opening`, and `isOpen` (== `current != .closed`) is
        // true, so `setLifecyclePhase` runs `reconcile` → `publishCommandLabel`.
        let pausing = CameraEngine(initialPhase: .background)
        await pausing._setStateForTest(.opening)
        await pausing.setLifecyclePhase(.inactive)  // target .paused
        #expect(
            await pausing._currentStateForTest == .opening,
            ".opening → .paused deferred (launch race)")

        let streaming = CameraEngine(initialPhase: .active)
        await streaming._setStateForTest(.opening)
        await streaming.setLifecyclePhase(.active)  // target .streaming
        #expect(
            await streaming._currentStateForTest == .streaming,
            ".opening → .streaming published (open() completing)")
    }

    // MARK: - Third actuation site (OS→phase)

    /// Third actuation site: interruption-ended while backgrounded leaves the
    /// session stopped.
    ///
    /// The OS→phase direction of the OS-owned guard — OS recovery must not fight
    /// the host. `.otherInterruptionEnded` reconciles against `.background`: no
    /// `startRunning` (no camera LED), watchdogs stay disarmed, label settles at
    /// `.paused`. A live recording would also be finalized before stop (the
    /// ordered `.background` suspend), but that needs a real writer — verified on
    /// device (Task 13 HITL); here the hardware-free invariants are asserted.
    @Test("OS→phase: interruption-ended while backgrounded stays stopped")
    func interruptionEndedWhileBackgroundStaysStopped() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        await engine.setLifecyclePhase(.background)
        #expect(await engine._isSessionRunningForTest == false)

        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        await engine._postSessionEventForTest(.otherInterruptionEnded)

        #expect(
            await engine._isSessionRunningForTest == false,
            "session must stay stopped (no startRunning → no camera LED)")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdogs stay disarmed while backgrounded")
        #expect(await engine.isGateOpen == false, "gate stays closed while backgrounded")
        #expect(
            await engine._currentStateForTest == .paused,
            "label settles at .paused, not .streaming (no recovery restart)")

        await engine.close()
    }

    /// Third actuation site: interruption-ended while inactive restarts the
    /// session with the gate closed.
    ///
    /// Contrast with the `.background` case (session stopped): the OS-recovery
    /// exit applies the phase's target, not unconditional `.streaming`. "Restart"
    /// here means reconcile guarantees the `.inactive` target; the literal
    /// stopped→running flip is unobservable without a synthetic seam (acceptable —
    /// the end-state matches the spec's target table).
    @Test("OS→phase: interruption-ended while inactive restarts gate-closed")
    func interruptionEndedWhileInactiveRestartsGateClosed() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        await engine.setLifecyclePhase(.inactive)
        #expect(await engine.isGateOpen == false)

        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        await engine._postSessionEventForTest(.otherInterruptionEnded)

        #expect(
            await engine._isSessionRunningForTest == true,
            "session runs for .inactive (contrast with .background stopped)")
        #expect(await engine.isGateOpen == false, "gate stays closed at .inactive")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "watchdogs stay disarmed at .inactive")
        #expect(
            await engine._currentStateForTest == .paused,
            "label settles at .paused for .inactive")

        await engine.close()
    }

    // MARK: - Event-vs-event (F5)

    /// F5: a stale interruption-ended handler must not override a newer
    /// interruption-begin event.
    ///
    /// Both interruption handlers dispatch as their own `Task { await
    /// onSessionEvent(...) }` and interleave on the actor. With the engine
    /// backgrounded, the `.ended` handler suspends inside reconcile's `.background`
    /// path (the existing park seam); a newer `.begin` is admitted and publishes
    /// `.interrupted`; the released `.ended` must not override it. Passes
    /// structurally: `.ended`'s label publishes happen at reconcile's top (before
    /// the suspend), and its post-suspend `.background` tail only stops the session
    /// — no label publish, no re-arm — so the newer `.begin` wins. Asserts both
    /// faces of the stale-override risk: the label and the watchdog.
    @Test("event-vs-event (F5): stale interruption-ended does not override newer begin")
    func staleEndedDoesNotOverrideNewerBegin() async {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        await engine._armWatchdogsForTest()
        await engine.setLifecyclePhase(.background)  // backgrounded: stopped, disarmed

        // Park the stale .ended mid-reconcile (post-disarm, pre-stop).
        await engine._armBackgroundReconcileParkForTest()
        let ended = Task { await engine._postSessionEventForTest(.otherInterruptionEnded) }
        while await engine._isBackgroundReconcileParkedForTest == false {
            await Task.yield()
        }

        // Admit the newer .begin while .ended is parked — it publishes .interrupted.
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 1))
        #expect(await engine._currentStateForTest == .interrupted)

        // Release the stale .ended — it must not republish a label over the newer
        // .interrupted, nor re-arm the watchdogs.
        await engine._releaseBackgroundReconcileParkForTest()
        await ended.value

        #expect(
            await engine._currentStateForTest == .interrupted,
            "stale .ended must not republish a label over the newer .begin")
        #expect(
            await engine._captureWatchdogArmedTokenForTest == nil,
            "stale .ended must not re-arm the watchdogs over the newer .begin")

        await engine.close()
    }
}
