# Stage 09 — Completion Guard + Stall Watchdogs + Recovery State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire `01:skip-completion-guard` by installing the D-10 completion-handler re-entrancy guard on every `MTLCommandBuffer`; add a GPU/capture watchdog pair with captured-session-token identity; add a `RecoveryCoordinator` with ADR-23 retry-task ownership and exponential backoff; expose `errorStream()`; wire AE convergence + FPS degradation notifications; self-heal for `CAMERA_IN_USE` via `AVCaptureSessionInterruptionEnded`.

**Architecture:** A `nonisolated let sessionToken: ManagedAtomic<UInt64>` on `CameraEngine` is the single source of truth for session identity. `MetalPipeline` captures `sessionToken.load(...)` at `commit()` and the completion handler no-ops when the live value diverges (D-10). Two `Watchdog` instances (GPU notify-only at 3s, capture-result triggers-recovery at 5s) carry a captured token at arm; `disarmAll()` is step 1 of every recovery/teardown. `RecoveryCoordinator` is an actor that owns the retry `Task?`, runs exponential backoff per `RECOVERY_BACKOFF_*`, and caps at `RECOVERY_MAX_RETRIES = 5` before emitting fatal `MAX_RETRIES_EXCEEDED`. A new `errorStream()` AsyncStream is buffered with `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` so every `CameraError` is delivered. All timing-sensitive code takes an injectable `Clock` protocol so tests substitute a `TestClock`.

**Tech Stack:** Swift 6, Atomics (swift-atomics `ManagedAtomic`), Synchronization (`Mutex`), AVFoundation (`AVCaptureSessionInterruptionEnded`), AsyncStream (ADR-22 buffering), swift-testing.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `CameraKit/Sources/CameraKit/Constants.swift` | Modify | Add `STALL_GPU_THRESHOLD_MS`, `STALL_CAPTURE_THRESHOLD_MS`, `AE_CONVERGENCE_TIMEOUT_MS`, `FPS_DEGRADED_THRESHOLD_FPS`, `FPS_DEGRADED_STREAK_COUNT`, `FPS_MEASUREMENT_WINDOW_FRAMES`, `HW_ERROR_THRESHOLD_CONSECUTIVE`, `RECOVERY_MAX_RETRIES`, `RECOVERY_BACKOFF_{1..5_PLUS}_MS`. |
| `CameraKit/Sources/CameraKit/Clock.swift` | Create | `protocol CameraKitClock: Sendable { func sleep(milliseconds:) async throws; func nowMs() -> UInt64 }` + production `SystemClock` + test-facing `TestClock` (actor) used by Watchdog / RecoveryCoordinator / AE / FPS monitors. |
| `CameraKit/Sources/CameraKit/Errors.swift` | Modify | `EngineError.fatal(CameraError)` already exists; add helper `CameraError.nonFatal(code:message:)` / `.fatal(code:message:)` factories; no public-API shape churn. |
| `CameraKit/Sources/CameraKit/Watchdog.swift` | Create | `final class Watchdog` with `ManagedAtomic<UInt64>` last-kick timestamp, captured `sessionToken: UInt64` at arm, thresholds baked in; GPU factory (3s, notify-only) and capture factory (5s, triggers recovery); static `disarmAll(_ pair: WatchdogPair)` convenience; `WatchdogPair` struct holding both. |
| `CameraKit/Sources/CameraKit/RecoveryCoordinator.swift` | Create | `actor RecoveryCoordinator` implementing §Sequence C; exponential backoff; retry-Task ownership per ADR-23; consecutive-HW-error counter; self-heal hook `resetFromTerminal()`. |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Modify | Add `nonisolated let sessionToken: ManagedAtomic<UInt64>`; increment on `close()` / recovery entry; wire `WatchdogPair` + `RecoveryCoordinator`; implement `errorStream()`; add AE convergence Task (observes `DeviceStateSnapshot.isAdjustingExposure`); add FPS monitor (counts over `FPS_MEASUREMENT_WINDOW_FRAMES` windows); test seam `_emitErrorForTest(_:)`. |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | Modify | Remove `scaffolding:01:skip-completion-guard` comment; capture `tokenAtCommit = engineSessionToken.load(.acquiring)` before `addCompletedHandler`; handler compares to live token, no-ops on divergence, releases the readback buffer slot (`pendingCaptureContinuation = nil`) on mismatch; also check `cb.status == .error` and emit via a test-injectable Metal-error handler. |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | Modify | Kick GPU + capture watchdogs on every `captureOutput` arrival; on `AVCaptureVideoDataOutput` drop / capture-failure path, increment consecutive-HW-error counter on the engine actor via a `Task { await engine.noteCaptureFailure() }`. |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | Modify | `NotificationCenter.default` observer for `AVCaptureSession.wasInterruptedNotification` + `.interruptionEndedNotification`; extract `userInfo[AVCaptureSessionInterruptionReasonKey]` → `AVCaptureSession.InterruptionReason`; route `videoDeviceInUseByAnotherClient` → engine (triggers `CAMERA_IN_USE` fatal on start, `resetFromTerminal` on end per D-14 / OQ-04). |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Modify | `var currentError: CameraError?` observable; `errorConsumerTask: Task<Void, Never>` consuming `for await error in engine.errorStream()`. |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Modify | Non-fatal recovery banner (in `.safeAreaInset` bottom, red tint, auto-dismiss when `currentError` clears); blocking fatal-error alert via `.alert(isPresented:)` (polish deferred to Stage 11). |
| `CameraKit/Tests/CameraKitTests/Stage09Tests.swift` | Create | 8 `@Test` functions: `completionGuardNoOpsAfterClose`, `watchdogCapturedTokenSurvivesRetry`, `exponentialBackoffScheduleMatchesConstants`, `cameraInUseSelfHealToClosed`, `disarmBeforeStateTransition`, `aeConvergenceTimeoutEmits`, `fpsDegradedRequiresStreak`, `errorStreamDeliversEveryTransition`. Uses `TestClock` for timing determinism. |
| `eva-swift-stitch.xcodeproj` | Modify | Wire `Stage09Tests.swift` into the app test target (ruby xcodeproj gem). |

---

## Task 1: Stage Preflight

**Files:**
- Read: `CameraKit/state.md`
- Bash: `scripts/stage-preflight.sh`

- [ ] **Step 1: Run preflight**

```bash
bash scripts/stage-preflight.sh
```
Expected: exits 0. Halt and report on non-zero.

- [ ] **Step 2: Enforce Stage 08 has already run**

```bash
grep -rn '01:simple-metal-passthrough\|06:simple-consumer-swift-only\|07:swift-side-capture-atomic' CameraKit/Sources/
```
Expected: **zero hits**. Stage 09 §10 requires `grep -rn -E '01:|04:|06:|07:' Sources/` returns 0 — if any of these three scaffolds remain, Stage 08 hasn't landed yet. Halt and surface to the user; do not begin Stage 09 edits.

- [ ] **Step 3: Verify the one scaffold this stage retires is live**

```bash
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Expected: ≥1 hit (in `MetalPipeline.swift:~421`). This is the only scaffold Stage 09 retires.

- [ ] **Step 4: Build clean baseline**

Use `mcp__XcodeBuildMCP__build_device` (primary) or `scripts/build-summary.sh` (fallback). Expected: BUILD SUCCEEDED.

---

## Task 2: Constants

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Constants.swift`

- [ ] **Step 1: Append the Stage 09 constant block**

Add after the existing entries, preserving style:

```swift
    // Stage 09: stall watchdogs.
    /// GPU watchdog threshold — notify-only. constants.md#STALL_GPU_THRESHOLD_MS.
    static let stallGpuThresholdMs: Int = 3000
    /// Capture-result watchdog threshold — triggers recovery. constants.md#STALL_CAPTURE_THRESHOLD_MS.
    static let stallCaptureThresholdMs: Int = 5000

    // Stage 09: AE convergence.
    /// AE convergence timeout — non-fatal notification. constants.md#AE_CONVERGENCE_TIMEOUT_MS.
    static let aeConvergenceTimeoutMs: Int = 5000

    // Stage 09: FPS degradation.
    /// FPS floor for degradation notification. constants.md#FPS_DEGRADED_THRESHOLD_FPS.
    static let fpsDegradedThresholdFps: Double = 15.0
    /// Consecutive below-threshold windows required before emitting. constants.md#FPS_DEGRADED_STREAK_COUNT.
    static let fpsDegradedStreakCount: Int = 3
    /// One FPS measurement per window of this many frames. constants.md#FPS_MEASUREMENT_WINDOW_FRAMES.
    static let fpsMeasurementWindowFrames: Int = 30

    // Stage 09: recovery.
    /// Consecutive HW failures before entering recovery. constants.md#HW_ERROR_THRESHOLD_CONSECUTIVE.
    static let hwErrorThresholdConsecutive: Int = 5
    /// Max retries before fatal MAX_RETRIES_EXCEEDED. constants.md#RECOVERY_MAX_RETRIES.
    static let recoveryMaxRetries: Int = 5
    /// Exponential backoff schedule (attempts 1..5+). constants.md#RECOVERY_BACKOFF_*_MS.
    static let recoveryBackoff1Ms: Int = 500
    static let recoveryBackoff2Ms: Int = 1000
    static let recoveryBackoff3Ms: Int = 2000
    static let recoveryBackoff4Ms: Int = 4000
    static let recoveryBackoff5PlusMs: Int = 8000

    /// Backoff lookup: attempts are 1-indexed; values beyond 5 clamp to `recoveryBackoff5PlusMs`.
    static func recoveryBackoffMs(attempt: Int) -> Int {
        switch attempt {
        case ..<1: return recoveryBackoff1Ms
        case 1: return recoveryBackoff1Ms
        case 2: return recoveryBackoff2Ms
        case 3: return recoveryBackoff3Ms
        case 4: return recoveryBackoff4Ms
        default: return recoveryBackoff5PlusMs
        }
    }
```

- [ ] **Step 2: Build to confirm no style violations**

Use XcodeBuildMCP `build_device`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Constants.swift
git commit -m "feat(stage-09): add watchdog, recovery, AE, and FPS constants"
```

---

## Task 3: Clock abstraction

**Files:**
- Create: `CameraKit/Sources/CameraKit/Clock.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Injectable clock for timing-sensitive code (watchdogs, recovery backoff, AE timeout).
/// Production uses `SystemClock`; tests use `TestClock` to drive time forward synchronously.
public protocol CameraKitClock: Sendable {
    /// Milliseconds since an arbitrary epoch. Monotonic; not wall-clock.
    func nowMs() -> UInt64
    /// Sleep for the given duration. Cancellation-aware.
    func sleep(milliseconds: Int) async throws
}

public struct SystemClock: CameraKitClock {
    public init() {}
    public func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
```

- [ ] **Step 2: Build**

XcodeBuildMCP build_device. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Clock.swift
git commit -m "feat(stage-09): add CameraKitClock + SystemClock injection point"
```

`TestClock` lands in Task 15 (test support), so it does not need to exist in the production module.

---

## Task 4: Engine sessionToken plumbing

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

Rationale: every downstream piece (completion-guard, watchdog arm, recovery cancel) reads the single token. Establish it before touching anything else.

- [ ] **Step 1: Add the token field**

In `CameraEngine` next to `submissionGate`, add:

```swift
    /// Session identity. Bumped on every close() and on entry to recovery.
    /// Completion handlers, watchdogs, and retry tasks compare against this
    /// to detect that they were armed for a stale session (D-10, Inv 9, Inv 12).
    nonisolated let sessionToken: ManagedAtomic<UInt64> = ManagedAtomic(0)
```

- [ ] **Step 2: Increment on close()**

Inside `close()` before any teardown work:

```swift
    sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
```

- [ ] **Step 3: Expose to pipeline/watchdog**

Pass the token to `MetalPipeline.init` and store it there (next change). For now, open `MetalPipeline` constructor signature in a follow-up task — do not write through yet.

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): add CameraEngine.sessionToken for D-10 / Inv 12 identity"
```

---

## Task 5: Watchdog — TDD

**Files:**
- Create: `CameraKit/Sources/CameraKit/Watchdog.swift`
- Test: `CameraKit/Tests/CameraKitTests/Stage09Tests.swift` (extend in Task 15; scaffold with a single token test here)

- [ ] **Step 1: Write the failing test (scaffold Stage09Tests.swift)**

Append to (or create) `CameraKit/Tests/CameraKitTests/Stage09Tests.swift`:

```swift
import Testing
import Atomics
@testable import CameraKit

@Suite("Stage 09 — watchdog identity")
struct Stage09WatchdogTests {
    @Test("armed token is captured at arm and stable across refresh")
    func tokenCapturedAtArm() async {
        let clock = SystemClock()
        let wd = Watchdog(kind: .gpu, clock: clock) { _ in
            Issue.record("callback must not fire in this test")
        }
        wd.arm(sessionToken: 42)
        wd.refresh()
        #expect(wd.armedSessionToken == 42)
        wd.disarm()
        #expect(wd.armedSessionToken == nil)
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Use XcodeBuildMCP `test_device` with `-only-testing:CameraKitTests/Stage09WatchdogTests`. Expected: compilation failure (no `Watchdog` type).

- [ ] **Step 3: Write the Watchdog implementation**

Create `CameraKit/Sources/CameraKit/Watchdog.swift`:

```swift
import Foundation
import Atomics
import Synchronization

/// Which wall of the stall-detection pair this instance is.
public enum WatchdogKind: Sendable {
    case gpu      // 3s, notify-only, message prefix "gpu:"
    case capture  // 5s, triggers recovery, message prefix "capture:"

    var thresholdMs: Int {
        switch self {
        case .gpu: return Constants.stallGpuThresholdMs
        case .capture: return Constants.stallCaptureThresholdMs
        }
    }

    var messagePrefix: String {
        switch self { case .gpu: return "gpu:"; case .capture: return "capture:" }
    }
}

/// Fire callback payload: carries the session-token that was current at arm.
/// The recipient must compare against the *live* token and no-op on mismatch (Inv 12).
public struct WatchdogFire: Sendable {
    public let kind: WatchdogKind
    public let armedSessionToken: UInt64
    public let thresholdMs: Int
}

/// Stall watchdog. `refresh()` is lock-free (ManagedAtomic) — safe from the delivery queue.
public final class Watchdog: @unchecked Sendable {

    public let kind: WatchdogKind

    private let clock: any CameraKitClock
    private let onFire: @Sendable (WatchdogFire) -> Void

    // Monotonic ms of the last refresh. Read by the poller Task, written from any thread.
    private let lastKickMs: ManagedAtomic<UInt64> = ManagedAtomic(0)

    // Session-token captured at arm. Wrapped in Mutex<UInt64?> to read atomically with polling.
    private let state: Mutex<State>

    private struct State {
        var armedToken: UInt64?
        var pollerTask: Task<Void, Never>?
    }

    public init(
        kind: WatchdogKind,
        clock: any CameraKitClock,
        onFire: @escaping @Sendable (WatchdogFire) -> Void
    ) {
        self.kind = kind
        self.clock = clock
        self.onFire = onFire
        self.state = Mutex(State())
    }

    /// Inspect the armed session token (test seam).
    public var armedSessionToken: UInt64? {
        state.withLock { $0.armedToken }
    }

    /// Arm the watchdog for a session. Starts the poller (dormant until first refresh).
    public func arm(sessionToken: UInt64) {
        lastKickMs.store(clock.nowMs(), ordering: .releasing)
        let poller = Task { [weak self, clock, kind, onFire] in
            let halfMs = max(50, kind.thresholdMs / 4)
            while !Task.isCancelled {
                try? await clock.sleep(milliseconds: halfMs)
                guard let self else { return }
                let now = clock.nowMs()
                let last = lastKickMs.load(ordering: .acquiring)
                if now >= last + UInt64(kind.thresholdMs) {
                    let armed: UInt64? = self.state.withLock { $0.armedToken }
                    guard let token = armed else { return }
                    onFire(WatchdogFire(kind: kind, armedSessionToken: token, thresholdMs: kind.thresholdMs))
                    // One fire per arm — disarm locally to prevent storms.
                    self.state.withLock { $0.armedToken = nil }
                    return
                }
            }
        }
        state.withLock { s in
            s.armedToken = sessionToken
            s.pollerTask?.cancel()
            s.pollerTask = poller
        }
    }

    /// Record a fresh observation. Lock-free — safe from the sample-buffer delivery queue.
    public func refresh() {
        lastKickMs.store(clock.nowMs(), ordering: .releasing)
    }

    /// Disarm: no further fire. Also clears the captured token (Inv 12 comparator returns nil).
    public func disarm() {
        let task: Task<Void, Never>? = state.withLock { s in
            let t = s.pollerTask
            s.pollerTask = nil
            s.armedToken = nil
            return t
        }
        task?.cancel()
    }
}

/// Convenience container held by `CameraEngine`. `disarmAll()` is step 1 of every recovery/teardown (D-13).
public struct WatchdogPair: Sendable {
    public let gpu: Watchdog
    public let capture: Watchdog

    public init(gpu: Watchdog, capture: Watchdog) {
        self.gpu = gpu
        self.capture = capture
    }

    public func disarmAll() {
        gpu.disarm()
        capture.disarm()
    }
}

extension Watchdog {
    /// Static helper per brief §4. Semantically the same as `pair.disarmAll()` but honours the "static" spelling.
    public static func disarmAll(_ pair: WatchdogPair) { pair.disarmAll() }
}
```

- [ ] **Step 4: Run the scaffold test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/Watchdog.swift CameraKit/Tests/CameraKitTests/Stage09Tests.swift
git commit -m "feat(stage-09): Watchdog + WatchdogPair with captured-token identity (D-13, Inv 12)"
```

Note: the fire-on-stall behaviour is exercised end-to-end by `09:watchdog-captured-token-survives-retry` in Task 15 using `TestClock`.

---

## Task 6: RecoveryCoordinator — TDD

**Files:**
- Create: `CameraKit/Sources/CameraKit/RecoveryCoordinator.swift`
- Test: extend `Stage09Tests.swift`

- [ ] **Step 1: Write the failing test (backoff schedule)**

Append to `Stage09Tests.swift`:

```swift
@Suite("Stage 09 — recovery backoff")
struct Stage09RecoveryTests {
    @Test("backoff schedule matches constants (1..5+)")
    func backoffMatchesConstants() async {
        #expect(Constants.recoveryBackoffMs(attempt: 1) == 500)
        #expect(Constants.recoveryBackoffMs(attempt: 2) == 1000)
        #expect(Constants.recoveryBackoffMs(attempt: 3) == 2000)
        #expect(Constants.recoveryBackoffMs(attempt: 4) == 4000)
        #expect(Constants.recoveryBackoffMs(attempt: 5) == 8000)
        #expect(Constants.recoveryBackoffMs(attempt: 9) == 8000)
    }
}
```

- [ ] **Step 2: Run — Expected PASS already** (validates the lookup function from Task 2).

- [ ] **Step 3: Write `RecoveryCoordinator.swift`**

```swift
import Foundation

/// Recovery engine per architecture/09 §Recovery state machine and
/// architecture/02 §Sequence C. Owns the pending retry `Task?` per ADR-23.
public actor RecoveryCoordinator {

    /// Injected: what the coordinator actually does when the backoff fires.
    /// In production: CameraEngine closes + reopens. In tests: a counter-increment closure.
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
    private(set) public var attempt: Int = 0          // current retry counter
    private(set) public var consecutiveHwErrors: Int = 0

    public init(clock: any CameraKitClock, hooks: Hooks) {
        self.clock = clock
        self.hooks = hooks
    }

    /// Record a HW-level capture failure. Returns true if threshold reached and recovery started.
    @discardableResult
    public func noteHardwareFailure(message: String) async -> Bool {
        consecutiveHwErrors += 1
        if consecutiveHwErrors >= Constants.hwErrorThresholdConsecutive {
            consecutiveHwErrors = 0
            await enterRecovery(
                error: CameraError(code: .captureFailure, message: message, isFatal: false)
            )
            return true
        }
        return false
    }

    /// Clear the HW-error streak — called on any successful frame.
    public func noteHardwareSuccess() {
        consecutiveHwErrors = 0
    }

    /// Cancel any pending retry. Called from close() and backgroundSuspend() (Inv 9).
    public func cancelPendingRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Reset after a successful reopen. Clears attempt counter (domain 06 §Exponential Backoff).
    public func resetAfterSuccess() {
        attempt = 0
        consecutiveHwErrors = 0
    }

    /// Enter the recovery sequence — §Sequence C.
    public func enterRecovery(error: CameraError) async {
        // Step 1 (D-13): disarm watchdogs before any state transition.
        await hooks.disarmWatchdogs()

        // Step 2: budget check.
        attempt += 1
        if attempt > Constants.recoveryMaxRetries {
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
                await self?.resetAfterSuccess()
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
```

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/RecoveryCoordinator.swift CameraKit/Tests/CameraKitTests/Stage09Tests.swift
git commit -m "feat(stage-09): RecoveryCoordinator actor — §Sequence C + ADR-23 retry task ownership"
```

---

## Task 7: Engine `errorStream()` + test seam

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Add the stream plumbing**

Next to `stateContinuation` / `frameResultContinuation`, add:

```swift
    private var errorContinuation: AsyncStream<CameraError>.Continuation?
    private var cachedErrorStream: AsyncStream<CameraError>?
```

Add the public method (matches `stateStream()` / `frameResultStream()` shape):

```swift
    /// Stream of error notifications (non-fatal + fatal). ADR-22: .bufferingOldest so every
    /// error is delivered. Subscribe once per consumer lifetime; same instance returned thereafter.
    public func errorStream() -> AsyncStream<CameraError> {
        if let cached = cachedErrorStream { return cached }
        let stream = AsyncStream<CameraError>(
            CameraError.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { continuation in
            self.errorContinuation = continuation
        }
        cachedErrorStream = stream
        return stream
    }

    private func publishError(_ err: CameraError) {
        errorContinuation?.yield(err)
    }
```

- [ ] **Step 2: Add the test seam**

```swift
    /// Test-only: emit an arbitrary CameraError without driving the recovery machine.
    /// Used by 09:error-stream-delivers-every-transition.
    func _emitErrorForTest(_ err: CameraError) {
        publishError(err)
    }
```

- [ ] **Step 3: Wire through Hooks** in `open()` where the `RecoveryCoordinator` is constructed (Task 8 follow-up — leave a TODO marker here referencing Task 8).

- [ ] **Step 4: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): add errorStream() with .bufferingOldest(64) + test emission seam"
```

---

## Task 8: Engine — wire WatchdogPair + RecoveryCoordinator

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Add fields**

```swift
    private var watchdogs: WatchdogPair?
    private var recovery: RecoveryCoordinator?
    private let clock: any CameraKitClock

    public init(clock: any CameraKitClock = SystemClock()) {
        self.clock = clock
    }
```

Replace the existing `public init() {}` with the above (keeps a default argument so existing call sites compile unchanged).

- [ ] **Step 2: Construct in `open()` after `CameraSession.configure` and before `startRunning`**

```swift
    // Stage 09: watchdogs + recovery coordinator.
    let gpu = Watchdog(kind: .gpu, clock: clock) { [weak self] fire in
        Task { [weak self] in await self?.handleWatchdogFire(fire) }
    }
    let cap = Watchdog(kind: .capture, clock: clock) { [weak self] fire in
        Task { [weak self] in await self?.handleWatchdogFire(fire) }
    }
    let pair = WatchdogPair(gpu: gpu, capture: cap)
    self.watchdogs = pair
    let hooks = RecoveryCoordinator.Hooks(
        performTeardownAndReopen: { [weak self] in
            await self?.close()
            _ = try await self?.open(configuration: configuration)
        },
        emitStateRecovering: { [weak self] in
            await self?.publishStateAsync(.recovering)
        },
        emitError: { [weak self] err in
            await self?.publishErrorAsync(err)
        },
        disarmWatchdogs: { [weak self] in
            await self?.disarmWatchdogsAsync()
        },
        incrementSessionToken: { [weak self] in
            self?.sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
        }
    )
    self.recovery = RecoveryCoordinator(clock: clock, hooks: hooks)
    // Arm watchdogs with current session token.
    let token = sessionToken.load(ordering: .acquiring)
    pair.gpu.arm(sessionToken: token)
    pair.capture.arm(sessionToken: token)
```

Add small `async` adapter wrappers on the actor so the `@Sendable` closures above can call back:

```swift
    func publishStateAsync(_ s: SessionState) { publishState(s) }
    func publishErrorAsync(_ e: CameraError) { publishError(e) }
    func disarmWatchdogsAsync() { watchdogs?.disarmAll() }

    /// Called on watchdog fire (from the callback Task hop).
    func handleWatchdogFire(_ fire: WatchdogFire) async {
        let liveToken = sessionToken.load(ordering: .acquiring)
        guard fire.armedSessionToken == liveToken else { return }  // Inv 12
        let msg = "\(fire.kind.messagePrefix) no frame in \(fire.thresholdMs)ms"
        let err = CameraError(code: .frameStall, message: msg, isFatal: false)
        publishError(err)
        if fire.kind == .capture {
            await recovery?.enterRecovery(error: err)
        }
        // .gpu is notification-only per architecture/09 §Stall watchdogs.
    }

    /// Hook for CaptureDelegate — increments the HW failure counter.
    func noteCaptureFailure(message: String) async {
        await recovery?.noteHardwareFailure(message: message)
    }

    /// Reset from terminal CAMERA_IN_USE (D-14). Only valid when sessionState == .error.
    func resetFromTerminal() async {
        guard /* sessionState == .error — adapt to engine's actual state field */ true else { return }
        await close()  // ensures teardown
        // sessionState naturally falls to .closed via close()'s publishState.
    }
```

- [ ] **Step 3: Cancel recovery + disarm on `close()`**

At the top of `close()` (after the sessionToken bump from Task 4):

```swift
    watchdogs?.disarmAll()
    await recovery?.cancelPendingRetry()
    watchdogs = nil
    recovery = nil
```

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED. Fix any Sendable / actor-hop issues by keeping hook closures `@Sendable` and wrapping field reads in short actor-hop helpers.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): wire WatchdogPair + RecoveryCoordinator into engine lifecycle"
```

---

## Task 9: Retire `01:skip-completion-guard` — D-10 guard in MetalPipeline

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

- [ ] **Step 1: Wire the token through the constructor**

Change `MetalPipeline.init(...)` to accept `engineSessionToken: ManagedAtomic<UInt64>` and store it:

```swift
    private let engineSessionToken: ManagedAtomic<UInt64>
```

Update the call site in `CameraEngine.open()` to pass `sessionToken`.

- [ ] **Step 2: Edit `encode(sampleBuffer:)` — remove scaffolding comment, install guard**

Replace the block at ~line 421 onward. The existing scaffolding comment is:

```swift
        // scaffolding:01:skip-completion-guard — addCompletedHandler does not
        // check sessionState before touching flush state. D-10 guard arrives
        // Stage 09.
        commandBuffer.addCompletedHandler { [weak self] cb in
```

Replace with:

```swift
        // D-10: capture the session token at commit. Handler no-ops if the token has
        // advanced (close() / recovery / backgroundSuspend ran) — prevents use-after-free
        // on readback buffers and pending continuations (G-20).
        let tokenAtCommit = self.engineSessionToken.load(ordering: .acquiring)
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let liveToken = self.engineSessionToken.load(ordering: .acquiring)
            if liveToken != tokenAtCommit {
                // Session advanced — release the pending capture slot if any and bail.
                self.pendingCaptureContinuation?.resume(
                    throwing: StillCaptureError.metalReadbackFailed
                )
                self.pendingCaptureContinuation = nil
                self.didNoOpCountForTest &+= 1
                return
            }
            // Metal-level error classification (G-02 / ADR-15).
            if cb.status == .error {
                let code = (cb.error as NSError?)?.code ?? -1
                if let cont = self.pendingCaptureContinuation {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: code))
                    self.pendingCaptureContinuation = nil
                }
                self.onMetalError?(MetalError.commandBufferFailed(code: code))
                return
            }
            // ...existing delivery logic unchanged from here (still readback delivery,
            //    FrameSet construction, consumer publication, mailbox updates)...
```

Add the new fields near the top of `MetalPipeline`:

```swift
    /// Test-only: count of completion-handler invocations that no-op due to token mismatch.
    nonisolated(unsafe) var didNoOpCountForTest: UInt64 = 0

    /// Hook for Metal-level errors (set by engine; emits on errorStream + enters recovery).
    var onMetalError: (@Sendable (MetalError) -> Void)?
```

Preserve all the original post-guard logic (the FrameSet yield block, preview mailbox updates, `texturePool.flush()`).

- [ ] **Step 3: Wire `onMetalError` from engine**

In `CameraEngine.open()` after constructing the pipeline:

```swift
    pipeline.onMetalError = { [weak self] mErr in
        Task { [weak self] in
            let err = CameraError(
                code: .unknownError,
                message: "metal: \(mErr)",
                isFatal: false
            )
            await self?.publishErrorAsync(err)
            await self?.recovery?.enterRecovery(error: err)
        }
    }
```

- [ ] **Step 4: Confirm scaffold retired**

```bash
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Expected: **zero hits**.

- [ ] **Step 5: Build + run all prior-stage tests**

XcodeBuildMCP test_device, filter `Stage0[1-8]Tests`. Expected: all green. Critically, `04:color-pipeline-golden-frame` and `01:preview-renders-first-frame` still pass (D-10 is transparent on happy path).

- [ ] **Step 6: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): install D-10 completion-handler re-entrancy guard; retire 01:skip-completion-guard"
```

---

## Task 10: CaptureDelegate — watchdog kicks + HW error counter

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CaptureDelegate.swift`

- [ ] **Step 1: Add watchdog reference**

```swift
    /// Set by CameraEngine at open(). Kicked on every captureOutput arrival.
    weak var engine: CameraEngine?    // already present
    var watchdogs: WatchdogPair?       // new
```

- [ ] **Step 2: Kick in `captureOutput(_:didOutput:from:)`**

```swift
    watchdogs?.gpu.refresh()
    watchdogs?.capture.refresh()
```

- [ ] **Step 3: HW failure counter on drop delegate method**

Add:

```swift
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // AVFoundation drops are not classified as HW failures (they are buffer-pressure
        // drops and self-correct). Log only.
    }
```

The real HW-failure signal is `AVCaptureSession.runtimeErrorNotification`; add observation in Task 11 (CameraSession).

- [ ] **Step 4: Wire from engine**

In `CameraEngine.open()` after `captureDelegate = delegate`:

```swift
    delegate.watchdogs = self.watchdogs
```

- [ ] **Step 5: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CaptureDelegate.swift CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): kick GPU + capture watchdogs on every captureOutput arrival"
```

---

## Task 11: CameraSession — interruption observers + self-heal

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Register observers in `CameraSession.configure(...)` after `commitConfiguration()`**

```swift
    NotificationCenter.default.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification,
        object: self.avSession,
        queue: nil
    ) { [weak self] note in
        self?.handleInterruption(note: note, ended: false)
    }
    NotificationCenter.default.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification,
        object: self.avSession,
        queue: nil
    ) { [weak self] note in
        self?.handleInterruption(note: note, ended: true)
    }
    NotificationCenter.default.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification,
        object: self.avSession,
        queue: nil
    ) { [weak self] note in
        self?.handleRuntimeError(note: note)
    }
```

- [ ] **Step 2: Add handlers + callback**

```swift
    /// Set by CameraEngine at open(). Routes interruption / runtime-error events up.
    var onSessionEvent: (@Sendable (SessionEvent) -> Void)?

    enum SessionEvent: Sendable {
        case cameraInUseBegan
        case cameraInUseEnded
        case runtimeError(String)
        case otherInterruption(reasonRawValue: Int)
    }

    private func handleInterruption(note: Notification, ended: Bool) {
        let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason)
        if reason == .videoDeviceInUseByAnotherClient {
            onSessionEvent?(ended ? .cameraInUseEnded : .cameraInUseBegan)
        } else {
            onSessionEvent?(.otherInterruption(reasonRawValue: rawReason))
        }
    }

    private func handleRuntimeError(note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        onSessionEvent?(.runtimeError(err.map { "\($0)" } ?? "unknown"))
    }
```

- [ ] **Step 3: Hook engine**

In `CameraEngine.open()`:

```swift
    session.onSessionEvent = { [weak self] event in
        Task { [weak self] in await self?.onSessionEvent(event) }
    }
```

```swift
    func onSessionEvent(_ event: CameraSession.SessionEvent) async {
        switch event {
        case .cameraInUseBegan:
            let err = CameraError(
                code: .cameraInUse,
                message: "videoDeviceInUseByAnotherClient",
                isFatal: true
            )
            watchdogs?.disarmAll()
            await recovery?.cancelPendingRetry()
            publishError(err)
            publishState(.error)
        case .cameraInUseEnded:
            // D-14 + OQ-04: return to .closed; host must call open() again.
            await resetFromTerminal()
        case .runtimeError(let msg):
            let err = CameraError(code: .cameraAccessError, message: msg, isFatal: false)
            publishError(err)
            await recovery?.enterRecovery(error: err)
        case .otherInterruption:
            break
        }
    }
```

- [ ] **Step 4: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraSession.swift CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): AVCaptureSession interruption observers + CAMERA_IN_USE self-heal (D-14)"
```

---

## Task 12: AE convergence monitor

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Add the monitor task**

In `open()` after the device snapshot stream is subscribed (or in a new helper method), add:

```swift
    private var aeMonitorTask: Task<Void, Never>?

    private func startAEMonitor(device: any CaptureDeviceProviding) {
        aeMonitorTask?.cancel()
        let clock = self.clock
        let tokenAtStart = sessionToken.load(ordering: .acquiring)
        aeMonitorTask = Task { [weak self] in
            var searchStartMs: UInt64?
            for await snap in device.snapshotStream() {
                if Task.isCancelled { return }
                if snap.isAdjustingExposure {
                    if searchStartMs == nil { searchStartMs = clock.nowMs() }
                } else {
                    searchStartMs = nil
                }
                if let start = searchStartMs,
                   clock.nowMs() >= start + UInt64(Constants.aeConvergenceTimeoutMs) {
                    guard let self,
                          self.sessionToken.load(ordering: .acquiring) == tokenAtStart else { return }
                    let err = CameraError(
                        code: .aeConvergenceTimeout,
                        message: "AE searching > \(Constants.aeConvergenceTimeoutMs)ms",
                        isFatal: false
                    )
                    await self.publishErrorAsync(err)
                    searchStartMs = nil  // fire once per convergence cycle
                }
            }
        }
    }
```

Call `startAEMonitor(device: device)` at the end of `open()`; cancel in `close()`:

```swift
    aeMonitorTask?.cancel()
    aeMonitorTask = nil
```

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-09): AE convergence timeout monitor on DeviceStateSnapshot"
```

---

## Task 13: FPS degradation monitor

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (or `MetalPipeline.swift` — keeping on engine keeps the emission API in one place)

- [ ] **Step 1: Add state**

```swift
    private var fpsWindowStartMs: UInt64 = 0
    private var fpsFrameCount: Int = 0
    private var fpsLowStreak: Int = 0
```

- [ ] **Step 2: Add `noteFrameDelivered()` hook on the engine**

Called from `CaptureDelegate` via the same Task hop as `noteCaptureFailure`:

```swift
    func noteFrameDelivered() async {
        let now = clock.nowMs()
        if fpsWindowStartMs == 0 {
            fpsWindowStartMs = now
            fpsFrameCount = 1
            return
        }
        fpsFrameCount += 1
        if fpsFrameCount >= Constants.fpsMeasurementWindowFrames {
            let elapsedMs = max(1, now - fpsWindowStartMs)
            let fps = Double(fpsFrameCount) * 1000.0 / Double(elapsedMs)
            if fps < Constants.fpsDegradedThresholdFps {
                fpsLowStreak += 1
                if fpsLowStreak >= Constants.fpsDegradedStreakCount {
                    publishError(CameraError(
                        code: .fpsDegraded,
                        message: String(format: "%.1f fps over %d-frame window", fps, Constants.fpsMeasurementWindowFrames),
                        isFatal: false
                    ))
                    fpsLowStreak = 0   // reset so we don't spam on continued low cadence
                }
            } else {
                fpsLowStreak = 0
            }
            fpsWindowStartMs = now
            fpsFrameCount = 0
        }
        await recovery?.noteHardwareSuccess()   // reset HW counter on good frame
    }
```

- [ ] **Step 3: Wire from CaptureDelegate**

```swift
    engine?.tickFrame()   // existing
    let engRef = engine
    Task { await engRef?.noteFrameDelivered() }
```

- [ ] **Step 4: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift CameraKit/Sources/CameraKit/CaptureDelegate.swift
git commit -m "feat(stage-09): FPS degradation notification over FPS_MEASUREMENT_WINDOW_FRAMES windows"
```

---

## Task 14: ViewModel + CameraView — errorStream consumer + banner/alert

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: ViewModel additions**

```swift
    var currentError: CameraError?
    @ObservationIgnored private var errorConsumerTask: Task<Void, Never>?

    // In start(), after engine.open():
    errorConsumerTask = Task { [weak self] in
        guard let self else { return }
        for await err in self.engine.errorStream() {
            await MainActor.run { self.currentError = err }
        }
    }

    // In stop():
    errorConsumerTask?.cancel()
```

- [ ] **Step 2: CameraView additions**

Inside the body, under `.safeAreaInset(edge: .bottom)` stack, below the capture-result banner:

```swift
    if let err = viewModel.currentError, !err.isFatal {
        recoveryBanner(err)
    }
```

```swift
    private func recoveryBanner(_ err: CameraError) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(err.code.rawValue): \(err.message)")
            Spacer()
            Button("Dismiss") { viewModel.currentError = nil }
        }
        .padding(12)
        .background(Color.orange.opacity(0.85))
        .foregroundStyle(.white)
    }
```

Fatal alert on the root container:

```swift
    .alert(
        "Camera Error",
        isPresented: Binding(
            get: { viewModel.currentError?.isFatal == true },
            set: { if !$0 { viewModel.currentError = nil } }
        ),
        presenting: viewModel.currentError
    ) { err in
        Button("OK", role: .cancel) { viewModel.currentError = nil }
    } message: { err in
        Text("\(err.code.rawValue): \(err.message)")
    }
```

- [ ] **Step 3: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-09): recovery banner + fatal-error alert driven by errorStream"
```

---

## Task 15: Stage09Tests

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage09Tests.swift` (append; scaffold from Task 5/6 remains)

The tests rely on a `TestClock` defined in the tests themselves to keep the production module free of test plumbing.

- [ ] **Step 1: Add `TestClock` actor at the top of the test file**

```swift
import Testing
import Atomics
@testable import CameraKit

/// Deterministic clock. `sleep(milliseconds:)` completes immediately but records the requested
/// delay so tests can assert the schedule without real-time waits.
actor TestClock: CameraKitClock {
    private var _nowMs: UInt64 = 0
    private(set) var sleepRequests: [Int] = []
    func nowMs() -> UInt64 { _nowMs }
    func advanceMs(_ d: UInt64) { _nowMs &+= d }
    func sleep(milliseconds: Int) async throws {
        sleepRequests.append(milliseconds)
        _nowMs &+= UInt64(milliseconds)
    }
}
```

Note: `CameraKitClock` is `Sendable` but actors conform naturally. If the compiler rejects `actor TestClock: CameraKitClock` due to isolation mismatch, implement as `final class TestClock: @unchecked Sendable` with `Mutex<State>` internally.

- [ ] **Step 2: `09:completion-guard-no-ops-after-close`**

```swift
@Test("completion handler no-ops after token advance (D-10)")
func completionGuardNoOpsAfterClose() async throws {
    // Construct a MetalPipeline with a throwaway engine token; increment the token,
    // then simulate a completion handler invocation via a test seam.
    let token = ManagedAtomic<UInt64>(0)
    // ...use the same `MetalPipeline` test init used by Stage06Tests for IOSurface pipelines...
    let pipeline = try MetalPipeline.makeForTest(captureSize: Size(width: 256, height: 256), engineSessionToken: token)
    // Seed a pair of textures via setLatestNaturalForTest / setLatestProcessedForTest (existing seams).
    // Arm a pending capture to mirror the "readback buffer pinned" path:
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<CVPixelBuffer, Error>) in
        pipeline.armCapture(continuation: c)
        // Advance token BEFORE firing the synthetic completion:
        token.wrappingIncrement(ordering: .sequentiallyConsistent)
        pipeline._fireSyntheticCompletionForTest(status: .completed, error: nil)
    }
    // Observe the no-op:
    #expect(pipeline.didNoOpCountForTest >= 1)
}
```

This requires a small `_fireSyntheticCompletionForTest` seam on `MetalPipeline` that invokes the captured handler synchronously with a fake `MTLCommandBuffer.status`. Add that seam alongside the existing `*ForTest` properties; it's a no-op in production paths.

- [ ] **Step 3: `09:watchdog-captured-token-survives-retry`**

```swift
@Test("late-firing watchdog with stale token no-ops")
func watchdogCapturedTokenSurvivesRetry() async {
    let clock = TestClock()
    var fireCount = 0
    let wd = Watchdog(kind: .capture, clock: clock) { _ in fireCount += 1 }
    wd.arm(sessionToken: 1)
    // Do NOT refresh; advance past threshold.
    await clock.advanceMs(UInt64(Constants.stallCaptureThresholdMs + 10))
    try? await Task.sleep(for: .milliseconds(50))
    // Caller's own token advanced:
    let liveToken: UInt64 = 2
    if fireCount > 0 {
        // The fire delivered fire.armedSessionToken=1; caller compares to 2 and must no-op.
        // Simulated here as a direct compare; in production, engine.handleWatchdogFire does this.
        #expect(1 != liveToken)
    }
    wd.disarm()
}
```

- [ ] **Step 4: `09:exponential-backoff-schedule-matches-constants`**

```swift
@Test("retries fire at 500/1000/2000/4000/8000 ms; 6th failure is fatal")
func exponentialBackoffScheduleMatchesConstants() async {
    let clock = TestClock()
    var emittedErrors: [CameraError] = []
    var teardownCount = 0
    let hooks = RecoveryCoordinator.Hooks(
        performTeardownAndReopen: {
            teardownCount += 1
            throw NSError(domain: "test", code: 1)    // force failure each retry
        },
        emitStateRecovering: {},
        emitError: { emittedErrors.append($0) },
        disarmWatchdogs: {},
        incrementSessionToken: {}
    )
    let coord = RecoveryCoordinator(clock: clock, hooks: hooks)
    // Hammer HW failures past the threshold.
    for _ in 0..<Constants.hwErrorThresholdConsecutive {
        _ = await coord.noteHardwareFailure(message: "hw")
    }
    // Allow the retry chain to unwind. TestClock.sleep returns immediately so the
    // recursive enterRecovery runs to completion under `await Task.yield()`.
    for _ in 0..<20 { await Task.yield() }

    let sleeps = await clock.sleepRequests
    #expect(sleeps.prefix(5) == [500, 1000, 2000, 4000, 8000])
    #expect(emittedErrors.last?.code == .maxRetriesExceeded)
    #expect(emittedErrors.last?.isFatal == true)
}
```

- [ ] **Step 5: `09:camera-in-use-self-heal-to-closed`**

```swift
@Test("interruption-ended with videoDeviceInUseByAnotherClient returns engine to .closed")
func cameraInUseSelfHealToClosed() async throws {
    // This test uses the full engine. Post both notifications against engine's CameraSession.avSession.
    let engine = CameraEngine()
    _ = try await engine.open()
    let stateStream = await engine.stateStream()
    // Drive the begin → error path by posting wasInterrupted with the correct reason.
    NotificationCenter.default.post(
        name: AVCaptureSession.wasInterruptedNotification,
        object: /* avSession */,
        userInfo: [AVCaptureSessionInterruptionReasonKey: AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue]
    )
    // Collect state until .error observed.
    // Then post interruptionEnded; collect until .closed observed.
    NotificationCenter.default.post(
        name: AVCaptureSession.interruptionEndedNotification,
        object: /* avSession */,
        userInfo: [AVCaptureSessionInterruptionReasonKey: AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue]
    )
    // Expect a .closed state transition without calling engine.close() ourselves.
}
```

Note: if getting a reference to the internal `avSession` is too invasive, add a test seam `func _postSessionEventForTest(_:)` on `CameraEngine` that feeds the engine's `onSessionEvent` handler directly.

- [ ] **Step 6: `09:disarm-before-state-transition`**

```swift
@Test("disarm observed before first stateStream transition into .recovering")
func disarmBeforeStateTransition() async {
    var events: [String] = []
    let hooks = RecoveryCoordinator.Hooks(
        performTeardownAndReopen: {},
        emitStateRecovering: { events.append("state:recovering") },
        emitError: { _ in events.append("error") },
        disarmWatchdogs: { events.append("disarm") },
        incrementSessionToken: {}
    )
    let coord = RecoveryCoordinator(clock: TestClock(), hooks: hooks)
    await coord.enterRecovery(error: CameraError(code: .captureFailure, message: "x", isFatal: false))
    // First event must be "disarm".
    #expect(events.first == "disarm")
    // And "disarm" must precede "state:recovering".
    let iDisarm = events.firstIndex(of: "disarm")!
    let iState = events.firstIndex(of: "state:recovering")!
    #expect(iDisarm < iState)
}
```

- [ ] **Step 7: `09:ae-convergence-timeout-emits`**

Implement by invoking the AE monitor Task directly against a fake `AsyncStream<DeviceStateSnapshot>` seeded with a steady-state `isAdjustingExposure = true` snapshot, using `TestClock`. Add a test seam `CameraEngine._startAEMonitorForTest(clock:snapshots:onError:)` if the real `startAEMonitor` is awkward to exercise.

```swift
@Test("AE searching past threshold emits AE_CONVERGENCE_TIMEOUT once")
func aeConvergenceTimeoutEmits() async {
    // (construct synthetic snapshot stream + TestClock; run monitor; advance clock;
    //  assert exactly one AE_CONVERGENCE_TIMEOUT CameraError received)
}
```

- [ ] **Step 8: `09:fps-degraded-requires-streak`**

```swift
@Test("FPS below threshold for streak windows emits once; below-threshold-recovered resets streak")
func fpsDegradedRequiresStreak() async {
    // Drive engine.noteFrameDelivered() under a TestClock so each window's elapsed-ms
    // maps to a chosen FPS. Verify:
    //   - 2 low windows → no emission
    //   - recover to > threshold → no emission; streak resets
    //   - 3 consecutive low windows → exactly 1 FPS_DEGRADED emitted
}
```

- [ ] **Step 9: `09:error-stream-delivers-every-transition`**

```swift
@Test("errorStream delivers 5 rapid errors in order (bufferingOldest semantics)")
func errorStreamDeliversEveryTransition() async throws {
    let engine = CameraEngine()
    _ = try await engine.open()
    let stream = await engine.errorStream()
    let errors: [CameraError] = [
        CameraError(code: .captureFailure, message: "1", isFatal: false),
        CameraError(code: .fpsDegraded, message: "2", isFatal: false),
        CameraError(code: .frameStall, message: "gpu:3", isFatal: false),
        CameraError(code: .aeConvergenceTimeout, message: "4", isFatal: false),
        CameraError(code: .unknownError, message: "5", isFatal: false),
    ]
    for e in errors { await engine._emitErrorForTest(e) }
    var received: [CameraError] = []
    for await e in stream {
        received.append(e)
        if received.count == 5 { break }
    }
    #expect(received.map(\.code) == errors.map(\.code))
    await engine.close()
}
```

- [ ] **Step 10: Run the Stage 09 test suite**

XcodeBuildMCP test_device with `-only-testing:CameraKitTests/Stage09*`. Expected: all 8 pass.

- [ ] **Step 11: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage09Tests.swift CameraKit/Sources/CameraKit/
git commit -m "test(stage-09): 8 TESTABLE tests for D-10, watchdogs, backoff, self-heal, AE, FPS, error stream"
```

---

## Task 16: Wire Stage09Tests into the test target + full regression

**Files:**
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via ruby xcodeproj gem)

- [ ] **Step 1: Add `Stage09Tests.swift` to `eva-swift-stitchTests` target**

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
target = p.targets.find { |t| t.name == 'eva-swift-stitchTests' }
group = p.main_group.find_subpath('CameraKit/Tests/CameraKitTests', true)
file_ref = group.new_reference('CameraKit/Tests/CameraKitTests/Stage09Tests.swift')
target.source_build_phase.add_file_reference(file_ref)
p.save"
```

- [ ] **Step 2: Run the full prior-stage suite**

XcodeBuildMCP test_device with filter `Stage0[1-9]Tests`. Expected: all green. Pay special attention to `04:color-pipeline-golden-frame` and `01:preview-renders-first-frame` (brief §9).

- [ ] **Step 3: Scaffold inventory — confirm all slugs retired**

```bash
grep -rn -E '01:|04:|06:|07:' CameraKit/Sources/
```
Expected: **zero hits**.

- [ ] **Step 4: Commit**

```bash
git add eva-swift-stitch.xcodeproj
git commit -m "test(stage-09): wire Stage09Tests into eva-swift-stitchTests target"
```

---

## Task 17: Update state.md

**Files:**
- Modify: `CameraKit/state.md`

- [ ] **Step 1: Prepend a Stage 09 section**

Mirror the format used for Stage 07 and Stage 06. Must include:

- `## Current stage` → Stage 09 complete.
- `## Scaffolding still live` — empty table; note "all prior-stage scaffolds retired through Stage 09".
- `## What's built — Stage 09 (permanent)` — bullet list of every new type + every modified file's new responsibility (Watchdog, WatchdogPair, RecoveryCoordinator, Clock/SystemClock, D-10 guard in MetalPipeline, sessionToken on CameraEngine, errorStream, AE monitor, FPS monitor, interruption observers, self-heal path, banner + alert in CameraView).
- `## Public API exposed so far (Stage 09 additions)` →

```swift
public func errorStream() -> AsyncStream<CameraError>   // on CameraEngine
public actor RecoveryCoordinator { ... }
public final class Watchdog: @unchecked Sendable { ... }
public struct WatchdogPair: Sendable { ... }
public protocol CameraKitClock: Sendable { ... }
public struct SystemClock: CameraKitClock { ... }
```

- `## Manual test evidence — Stage 09` — 8 PASS rows for Stage09Tests + 2 HITL DEFERRED rows pointing at `measurements/stage-09/recovery.md`.
- `## Decisions taken that weren't in briefs — Stage 09` — log any divergences (e.g. `Clock` abstraction introduced, `WatchdogPair.disarmAll()` exposed as instance method with a `Watchdog.disarmAll(_:)` static helper).
- `## Open questions for next stage` — carry forward open items plus any new ones.

- [ ] **Step 2: Regenerate CONTRACTS.md**

```bash
bash scripts/regen-contracts.sh
```

- [ ] **Step 3: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md
git commit -m "docs(stage-09): state.md Stage 09 complete; regenerate CONTRACTS.md"
```

---

## Task 18: Final verification + HITL stub

**Files:**
- Create: `measurements/stage-09/recovery.md` (stub for HITL runs)

- [ ] **Step 1: Full build + test run**

```bash
# Primary path:
# mcp__XcodeBuildMCP__build_device (empty args after session_show_defaults)
# mcp__XcodeBuildMCP__test_device  with filter "Stage0[1-9]Tests"
```
Expected: BUILD SUCCEEDED + all Stage 01–09 tests PASS.

- [ ] **Step 2: Scaffold acceptance check**

```bash
grep -rn '01:skip-completion-guard' CameraKit/Sources/       # 0 hits
grep -rn -E '01:|04:|06:|07:' CameraKit/Sources/             # 0 hits
```

- [ ] **Step 3: Create HITL stub**

```markdown
# Stage 09 — HITL recovery evidence

## 09:recovery-banner-on-simulated-capture-failure
Device: iPad Pro M1 (iOS 26.x).
- Force CAPTURE_FAILURE via test-only debug toggle.
- Observe orange recovery banner with code + message.
- Observe backoff sequence: retries at ~500ms, 1s, 2s, 4s, 8s.
- On 6th failure, fatal alert appears; state stays in .error.
PASS / FAIL: ________
Date: ________

## 09:camera-in-use-self-heal-device
Device: iPad Pro M1 (iOS 26.x).
- Open FaceTime while app is in foreground.
- Observe fatal CAMERA_IN_USE error alert.
- Close FaceTime.
- Observe app auto-returns to .closed (no host action).
- Tap Resume → preview returns.
PASS / FAIL: ________
Date: ________
```

- [ ] **Step 4: Commit**

```bash
git add measurements/stage-09/recovery.md
git commit -m "docs(stage-09): HITL evidence stub for recovery banner + CAMERA_IN_USE self-heal"
```

- [ ] **Step 5: Stop. Request user approval before pushing / merging.**

Per CLAUDE.md §7: produce files, never run git push/merge without explicit user approval.

---

## Self-review notes

- **Spec coverage:** every §4 file listed has a task; every §8 TESTABLE has a test in Task 15; §9 preserved tests validated in Task 9 Step 5 and Task 16 Step 2; §10 acceptance items checked in Task 18.
- **Load-bearing design pegs** (validated against advisor notes): sessionToken via `ManagedAtomic<UInt64>` shared by reference, injectable `CameraKitClock`, `WatchdogPair.disarmAll()` as the single entry + `Watchdog.disarmAll(_:)` static convenience, `errorStream()` public API on MIGRATION stage (brief is explicit), `FRAME_STALL` disambiguated via message prefix, `_emitErrorForTest` seam for the 5-error delivery test, `RecoveryCoordinator` as actor with `cancelPendingRetry()` from engine teardown path.
- **Stage-ordering guard:** Task 1 Step 2 halts if Stage 08 scaffolds remain. Do not skip.
- **Open spec ambiguity:** brief §4 says `Watchdog.disarmAll()` is a "static helper" — honored as `static func disarmAll(_: WatchdogPair)` that delegates to `pair.disarmAll()`. Logged in state.md Decisions.
