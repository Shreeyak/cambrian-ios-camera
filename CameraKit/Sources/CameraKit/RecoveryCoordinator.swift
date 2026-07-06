import Foundation

/// Recovery engine per architecture/09 §Recovery state machine and
/// architecture/02 §Sequence C.
///
/// Owns the pending retry `Task?` per ADR-23.
public actor RecoveryCoordinator {

    /// Injected: what the coordinator actually does when the backoff fires.
    public struct Hooks: Sendable {
        public var performTeardownAndReopen: @Sendable () async throws -> Void
        public var emitStateRecovering: @Sendable () async -> Void
        public var emitError: @Sendable (CameraError) async -> Void
        public var disarmWatchdogs: @Sendable () async -> Void
        public var incrementSessionToken: @Sendable () async -> Void

        public init(
            performTeardownAndReopen: @escaping @Sendable () async throws -> Void,
            emitStateRecovering: @escaping @Sendable () async -> Void,
            emitError: @escaping @Sendable (CameraError) async -> Void,
            disarmWatchdogs: @escaping @Sendable () async -> Void,
            incrementSessionToken: @escaping @Sendable () async -> Void
        ) {
            self.performTeardownAndReopen = performTeardownAndReopen
            self.emitStateRecovering = emitStateRecovering
            self.emitError = emitError
            self.disarmWatchdogs = disarmWatchdogs
            self.incrementSessionToken = incrementSessionToken
        }
    }

    private let clock: any CameraKitClock
    private let hooks: Hooks
    private var retryTask: Task<Void, Never>?
    public private(set) var attempt: Int = 0
    public private(set) var consecutiveHwErrors: Int = 0

    public init(clock: any CameraKitClock, hooks: Hooks) {
        self.clock = clock
        self.hooks = hooks
    }

    /// Record a HW-level capture failure.
    ///
    /// Returns true if threshold reached and recovery started.
    @discardableResult
    public func noteHardwareFailure(message: String) async -> Bool {
        consecutiveHwErrors += 1
        CameraKitLog.warning(
            .engine,
            "[recovery] hw-failure consecutive=\(consecutiveHwErrors)/\(Constants.hwErrorThresholdConsecutive) msg=\(message)"
        )
        if consecutiveHwErrors >= Constants.hwErrorThresholdConsecutive {
            consecutiveHwErrors = 0
            await enterRecovery(
                error: CameraError(code: .captureFailure, message: message, isFatal: false)
            )
            return true
        }
        return false
    }

    /// Clear the recovery budget — called on any delivered frame.
    ///
    /// A real frame is the only proof a reopen actually recovered the session: a
    /// reopen can "succeed" (not throw) yet deliver nothing — e.g. a mis-configured
    /// format that stalls. So the retry `attempt` budget resets here, on frame
    /// delivery, NOT on reopen success. Resetting on reopen (the old behavior) let an
    /// open-then-stall config reset the budget every cycle, so the max-retries fatal
    /// was never reached and recovery looped forever behind a black screen.
    public func noteHardwareSuccess() {
        consecutiveHwErrors = 0
        if attempt != 0 {
            CameraKitLog.notice(
                .engine,
                "[recovery] frame delivered — recovery confirmed, resetting attempt=\(attempt)")
            attempt = 0
        }
    }

    /// Cancel any pending retry — called from close() and reconcile()'s .background path (Inv 9).
    public func cancelPendingRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    // NOTE: there is deliberately no "reset on reopen" here. The attempt budget
    // resets in `noteHardwareSuccess()` when a real frame arrives (see there).

    /// Enter the recovery sequence — §Sequence C.
    public func enterRecovery(error: CameraError) async {
        // Step 1 (D-13): disarm watchdogs before any state transition.
        await hooks.disarmWatchdogs()

        // Step 2: budget check.
        attempt += 1
        CameraKitLog.warning(
            .engine,
            "[recovery] enter attempt=\(attempt)/\(Constants.recoveryMaxRetries) error=\(error.message)"
        )
        if attempt > Constants.recoveryMaxRetries {
            CameraKitLog.error(.engine, "[recovery] max-retries exceeded, emitting fatal")
            let fatal = CameraError(
                code: .maxRetriesExceeded,
                message: "Exceeded \(Constants.recoveryMaxRetries) recovery retries: last=\(error.message)",
                isFatal: true
            )
            await hooks.emitError(fatal)
            return
        }

        // Step 3: state transition + notify.
        await hooks.incrementSessionToken()
        await hooks.emitStateRecovering()
        await hooks.emitError(error)

        // Step 4: cancel any in-flight retry; schedule a fresh one.
        retryTask?.cancel()
        let delayMs = Constants.recoveryBackoffMs(attempt: attempt)
        let clock = self.clock
        let hooks = self.hooks
        retryTask = Task { [weak self] in
            do { try await clock.sleep(milliseconds: delayMs) } catch { return }
            if Task.isCancelled { return }
            do {
                try await hooks.performTeardownAndReopen()
                // Reopen succeeded — but that is NOT recovery. Wait for a real frame:
                // `noteHardwareSuccess()` resets the attempt budget when one arrives. If
                // none does (open-then-stall), the next watchdog stall re-enters recovery
                // and the budget keeps counting up toward the max-retries fatal.
            } catch {
                let next = CameraError(
                    code: .unknownError,
                    message: "retry \(await (self?.attempt ?? 0)) failed: \(error)",
                    isFatal: false
                )
                await self?.enterRecovery(error: next)
            }
        }
    }
}
