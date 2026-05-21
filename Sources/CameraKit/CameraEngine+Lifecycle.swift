import AVFoundation
import Atomics

// Extension of `CameraEngine` holding the App-lifecycle reconciliation cluster —
// the *host-intent* side of lifecycle: `setLifecyclePhase(_:)` and the
// `reconcile()` routine that actuates the gate, session, watchdogs, and
// `SessionState` label from `currentPhase`, plus the legacy
// `backgroundSuspend`/`backgroundResume`/`notifyScenePhasePaused` entries.
//
// The *OS-event* side (`onSessionEvent`, `RecoveryCoordinator`, watchdog
// handling) deliberately stays in `CameraEngine.swift`; it calls `reconcile()`
// across the file boundary, which is why `reconcile` is `internal` here while the
// helpers it owns stay `private` to this file. This is the repo's first
// `Type+Feature.swift` split — extracted purely for file size; every member
// remains actor-isolated on `CameraEngine`, so behaviour is unchanged.
//
// Refs: ADR-09 (gate guards GPU commit), ADR-30 (suspend/resume async-with-
// timeout), spec *OS-authoritative label*, adversarial F1 (latest-intent-wins)
// and F2 (the OS-owned guard).
extension CameraEngine {

    // MARK: - Legacy background entries

    /// Signals the app entered background.
    ///
    /// Gates GPU submission, drains any in-flight
    /// frame, and stops the capture session via sessionQueue with timeout (ADR-30).
    ///
    /// Disarms the stall watchdogs and cancels any pending recovery retry (Inv 9):
    /// the session is being stopped on purpose, so no frames are expected and a
    /// stall is not a fault. Leaving them armed fires spurious recovery while
    /// backgrounded, which collides with the OS-interruption state and aborts in
    /// DEBUG — the HITL background crash (measurements 2026-05-20 §1). Re-armed by
    /// `backgroundResume()`.
    func backgroundSuspend() async {
        CameraKitLog.notice(.engine, "[bgsuspend] enter gate=false stopRunning")
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        watchdogs?.disarmAll()
        await recovery?.cancelPendingRetry()
        if recording != nil {
            CameraKitLog.notice(
                .engine, "[bgsuspend] active recording — finalizing via background-task drain")
            _ = await finalizeActiveRecording(reason: .user)
        }
        await drainSubmittedFrame()
        if let session = cameraSession {
            captureDelegate?.framesToLog = 1
            await session.stopRunningAsync()
        }
        CameraKitLog.notice(.engine, "[bgsuspend] stopRunning returned")
    }

    /// Signals the app returned to foreground.
    ///
    /// Re-opens the GPU submission gate and restarts the capture session that was
    /// stopped by `backgroundSuspend()`.
    func backgroundResume() async {
        CameraKitLog.notice(
            .engine,
            "[bgresume] enter gate=true sessionRunning=\(cameraSession?.avSession.isRunning == true)")
        submissionGate.store(true, ordering: .sequentiallyConsistent)
        CameraKitLog.notice(.engine, "[bgresume] gate opened")
        if let session = cameraSession {
            await session.startRunningAsync()
            CameraKitLog.notice(
                .engine,
                "[bgresume] startRunning returned sessionRunning=\(session.avSession.isRunning)")
            // Frames resume — re-arm the watchdogs disarmed by backgroundSuspend().
            armWatchdogs()
        }
    }

    /// Publishes `.paused` (when `paused == true`) or `.streaming` for SwiftUI scenePhase pause/resume.
    ///
    /// Covers Control Center pull-down, Notification Center, app-switcher
    /// peek, etc. The camera stays bound across these transitions; only GPU
    /// submission is gated. Phase-2 follow-up to §2d.5 (distinct from the
    /// AVF-interruption `.interrupted` case).
    ///
    /// Caller (the app's SwiftUI `ScenePhase` observer) is still responsible
    /// for the gate via `setGate` — this method only mirrors the lifecycle
    /// transition into `SessionState` so downstream consumers
    /// (`ErrorPresenterViewModel`, Phase-3's Pigeon adapter) see a consistent
    /// pause/resume signal.
    ///
    /// Defers to OS-driven events when the state machine sits in an OS-owned
    /// origin (`.interrupted`/`.recovering`/`.error`) or the `.opening → .paused`
    /// launch race — the `shouldDeferCommandLabel` guard, shared with the
    /// reconciliation routine. From an OS-owned state a scenePhase-driven
    /// `.streaming`/`.paused` is off-map and would overwrite OS truth with a
    /// wrong value; the publish is skipped (logged) and the OS event path
    /// restores `.streaming` (`onSessionEvent(.otherInterruptionEnded)`, recovery
    /// completion). Caught under `test_device`, where a harness/bring-up AVF
    /// interruption raced a `.active` scenePhase into the off-map path in
    /// `publishState` — a wrong-value overwrite of OS-owned state (a DEBUG abort
    /// too, before Fix 2; measurements 2026-05-20 §1, case #12).
    ///
    /// Superseded by `setLifecyclePhase`/`reconcile`, which now own the label
    /// (spec *OS-authoritative label*); this remains the legacy host entry until
    /// the host migrates (then demoted to `internal`). Thin wrapper over the same
    /// `publishCommandLabel` the routine uses, so both paths behave identically.
    func notifyScenePhasePaused(_ paused: Bool) {
        publishCommandLabel(paused ? .paused : .streaming)
    }

    // MARK: - App lifecycle (reconciliation)

    /// Update the host's current lifecycle phase.
    ///
    /// Never throws; safe on every transition and before `open()`. Writes
    /// `currentPhase` unconditionally and reconciles hardware (gate, session,
    /// watchdogs, label) only when the engine is open — before `open()` the phase
    /// is recorded, and `open()` applies it by running the same routine against
    /// `currentPhase`.
    ///
    /// Concurrency: the **latest call wins** — a superseded, still-in-flight
    /// reconciliation is abandoned rather than allowed to apply stale work, so
    /// rapid bounces (lock/unlock, app-switch) are safe.
    ///
    /// Calling convention:
    /// - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward the
    ///   matching case — `.active` / `.inactive` / `.background` map 1:1.
    /// - **Flutter (cam2fd):** the plugin's *native* Swift layer implements
    ///   `FlutterSceneLifeCycleDelegate` (registered via `addSceneDelegate`) and
    ///   maps the UIScene callbacks to this call — `sceneDidBecomeActive →
    ///   .active`, `sceneWillResignActive → .inactive`, `sceneDidEnterBackground →
    ///   .background`. Do **not** forward lifecycle from Dart over the method
    ///   channel: observe natively so a backgrounding can't outrun an in-flight
    ///   recording's finalize and corrupt the `.mp4`.
    public func setLifecyclePhase(_ phase: AppLifecyclePhase) async {
        currentPhase = phase
        guard isOpen else { return }
        await reconcile()
    }

    /// Reconcile actual hardware state to the target `currentPhase` implies.
    ///
    /// The single routine behind the three lifecycle actuation sites:
    /// `setLifecyclePhase`, `open()`, and the OS-recovery exit
    /// (`onSessionEvent(.otherInterruptionEnded)`). Derives the target from
    /// `currentPhase` alone — no previous-phase
    /// tracking — per the design's target table: `.active` → gate open / session
    /// running / watchdogs armed; `.inactive` → gate closed / session running /
    /// disarmed (cheap pause, ~4 ms gate-flip vs ~410 ms restart); `.background`
    /// → gate closed / session stopped + recording finalized / disarmed.
    ///
    /// Also publishes the `SessionState` label (the job `notifyScenePhasePaused`
    /// did) and applies the phase→OS guard (F2): while `osOwnsDevice` the
    /// `.active`/`.inactive` rows neither `startRunning` nor re-arm the watchdogs.
    func reconcile() async {
        // Latest-intent-wins (F1): each entry bumps the generation so a later
        // call supersedes an in-flight one. The `.background` path re-checks
        // `generation` after each suspending step and aborts if a newer call
        // bumped it.
        reconcileGeneration &+= 1
        let generation = reconcileGeneration

        // Label half — folded in from `notifyScenePhasePaused` (spec
        // *OS-authoritative label*): `.active` publishes `.streaming`, every gated
        // phase publishes `.paused`; `publishCommandLabel` defers to OS truth.
        // Published before the (suspending) `.background` steps so latest-intent-
        // wins covers the label too: only `.background` suspends, and it aborts
        // without republishing, so a superseding `.active`'s `.streaming` is the
        // last word.
        publishCommandLabel(currentPhase == .active ? .streaming : .paused)

        switch currentPhase {
        case .active:
            setGate(true)
            CameraKitLog.notice(.engine, "[resume] gate opened (t0b)")
            // Arm the pipeline's one-shot commit/texture probes (t1b/t1c): the first
            // frame past the now-open gate logs its commit and texture-store, which
            // splits AVF delivery-resume (t1) from GPU/commit cost downstream.
            metalPipeline?.logNextCommit = true
            // Resume-latency probe: arm the one-shot first-frame log so
            // `[resume] first frame (t1)` also covers a pure `.inactive → .active`
            // (Control Center, no interruption) resume. t1 minus the `scenePhase:
            // … → active` time (t0) splits "OS throttled delivery while .inactive"
            // (t1 ≈ 500 ms) from a downstream submit/draw delay (t1 ≈ one frame) —
            // ADR-09: the gate gates GPU commit, not delivery, so framesToLog
            // (capture delegate) logs delivery cadence — continuous vs stall.
            captureDelegate?.framesToLog = 1
            // Phase → OS guard (F2; spec *The OS-owned guard*): while the OS owns
            // the device (`.interrupted`/`.recovering`/`.error`) the host command
            // must not fight it — no `startRunning`, no watchdog re-arm. A re-armed
            // watchdog fires a spurious stall → `RecoveryCoordinator` teardown
            // while frames are still OS-stopped (and for the terminal `.error`
            // case escalates toward a fatal `maxRetriesExceeded` the OS would
            // otherwise let self-heal).
            if !osOwnsDevice {
                startSessionIfNeeded()
                armWatchdogs()
            }
        case .inactive:
            setGate(false)
            // F2: same OS-owned guard on the session-start (the `.inactive` row
            // restarts the session unless the OS owns the device).
            if !osOwnsDevice {
                startSessionIfNeeded()
            }
            disarmWatchdogsAsync()
        case .background:
            // Field-guide §5 ordered suspend: gate close (synchronous, before any
            // suspending step) → disarm + cancel retry → finalize any active
            // recording → drain → stopRunning. After each suspending step a
            // latest-intent-wins re-check (F1) aborts a superseded reconcile
            // before it applies stale work — a `.background` straggled by a
            // completing `.active` must not stop the session `.active` just kept
            // running. The pre-checkpoint gate-close + disarm are left unguarded:
            // cheap, idempotent, and overwritten by the winning `.active`.
            // `backgroundActionTrace` records the order for the 5b test
            // (finalize-before-stop needs a live recording → Task 13 HITL).
            backgroundActionTrace.removeAll(keepingCapacity: true)
            setGate(false)
            disarmWatchdogsAsync()
            backgroundActionTrace.append("disarm")
            await backgroundReconcileParkForTest()
            guard generation == reconcileGeneration else { return }
            await recovery?.cancelPendingRetry()
            guard generation == reconcileGeneration else { return }
            if recording != nil {
                _ = await finalizeActiveRecording(reason: .user)
                backgroundActionTrace.append("finalize")
                guard generation == reconcileGeneration else { return }
            }
            await drainSubmittedFrame()
            backgroundActionTrace.append("drain")
            guard generation == reconcileGeneration else { return }
            reconciledSessionRunning = false
            if let session = cameraSession {
                await session.stopRunningAsync()
            }
            backgroundActionTrace.append("stop")
        }
    }

    /// Start the capture session unless `reconcile` already decided it runs.
    ///
    /// Records the decision in `reconciledSessionRunning` *before* dispatching so
    /// the mirror reflects intent (the start itself is fire-and-forget on
    /// sessionQueue, matching `open()`'s original step-9b timing). No-op without
    /// a live `cameraSession` (the test pattern).
    private func startSessionIfNeeded() {
        guard !reconciledSessionRunning else { return }
        reconciledSessionRunning = true
        // Resume-latency instrumentation: this line on a resume means a real
        // session restart was issued (~400 ms `startRunning`); its ABSENCE
        // confirms the cheap path — e.g. a Control Center interruption never stops
        // the session, so no restart is on the resume critical path.
        CameraKitLog.notice(.engine, "[resume] startSessionIfNeeded — issuing startRunning")
        if let session = cameraSession {
            session.sessionQueue.async { session.startRunning() }
        }
    }

    /// True when the OS owns the device: a foreground interruption, an in-flight
    /// recovery, or a terminal error.
    ///
    /// The reconciliation must not fight the OS for the device while this holds
    /// (spec *The OS-owned guard*, adversarial review F2): the `.active`/
    /// `.inactive` rows skip both `startRunning` and the watchdog arm. Reads the
    /// single source of truth — `SessionStateMachine.current` — with no parallel
    /// mirror.
    private var osOwnsDevice: Bool {
        switch stateMachine.current {
        case .interrupted, .recovering, .error: return true
        case .opening, .streaming, .paused, .closed: return false
        }
    }

    /// True when a host `.command` label publish must defer to OS truth.
    ///
    /// `osOwnsDevice` plus the `.opening → .paused` launch race (a pre-`open()`
    /// `.inactive`/`.background` phase arriving before `open()` publishes
    /// `.streaming`). The rider is the one off-map edge `osOwnsDevice` alone does
    /// not cover but the prior `classify(...) == .offMap` check did
    /// (`commandMap[.opening]` has no `.paused`); honestly named separately
    /// because the watchdog/start guard must NOT carry it (spec: a single shared
    /// helper would hide the `.opening` clause at the device-guard site).
    private func shouldDeferCommandLabel(target: SessionState) -> Bool {
        osOwnsDevice || (stateMachine.current == .opening && target == .paused)
    }

    /// Publish a host-`.command` `SessionState` label, deferring to OS truth.
    ///
    /// The label half of reconciliation, folded in from `notifyScenePhasePaused`
    /// (spec *OS-authoritative label*, Bug 2): publishes `.streaming`/`.paused`
    /// as a `.command` transition unless `shouldDeferCommandLabel` holds — in
    /// which case the OS event path owns the terminal label
    /// (`onSessionEvent`/recovery) and this publish is skipped (logged), so a UI
    /// command can't overwrite `.interrupted`/`.recovering`/`.error` with a stale
    /// `.paused`/`.streaming`.
    private func publishCommandLabel(_ target: SessionState, function: String = #function) {
        guard !shouldDeferCommandLabel(target: target) else {
            CameraKitLog.notice(
                .engine,
                "[lifecycle] skipping command label from=\(stateMachine.current.rawValue) "
                    + "to=\(target.rawValue) caller=\(function) (deferring to OS-owned state)"
            )
            return
        }
        publishState(target, kind: .command)
    }

    /// Test interleave seam (F1): park the in-flight `.background` reconcile at
    /// the post-disarm checkpoint until a test releases it.
    ///
    /// Lets a test deterministically admit a second `setLifecyclePhase` while a
    /// `.background` reconcile is suspended, to prove the straggler aborts. No-op
    /// in production (never armed). One-shot — re-arm with
    /// `_armBackgroundReconcileParkForTest()` for a second park.
    private func backgroundReconcileParkForTest() async {
        guard backgroundParkArmed else { return }
        backgroundParkArmed = false
        backgroundParkedFlag = true
        await withCheckedContinuation { backgroundParkRelease = $0 }
        backgroundParkedFlag = false
    }
}
