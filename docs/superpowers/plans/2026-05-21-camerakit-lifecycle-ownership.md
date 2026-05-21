# CameraKit Lifecycle Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the host-orchestrated, 5-primitive scenePhase handling with a single public lifecycle API — `CameraEngine.setLifecyclePhase(_:)` + a required `initialPhase` — backed by one declarative reconciliation routine the package owns end-to-end.

**Architecture:** The host forwards a coarse `AppLifecyclePhase` (`.active`/`.inactive`/`.background`); the engine carries `currentPhase` as a property and reconciles hardware (GPU gate, session start/stop, stall watchdogs, recording finalize) to the target each phase implies. The routine runs at **three actuation sites** — `open()`, `setLifecyclePhase`, and OS-recovery exit — each reading `currentPhase`. A latest-intent-wins contract makes superseded in-flight reconciliations abort. Device-interruption lifecycle stays package-owned and unchanged except where it shares the actor with the phase path.

**Tech Stack:** Swift 6.2, iOS 26, `actor`-isolated `CameraEngine`, AVFoundation, swift-testing, XcodeBuildMCP (device-only).

**Spec:** `docs/superpowers/specs/2026-05-21-camerakit-lifecycle-ownership-design.md` — read it before starting. Section names below (e.g. *What moves inside the package*, *Concurrency*, *The OS-owned guard*) refer to that spec.

---

## Plan conventions (read once)

- **Code density (user directive):** tasks give **contracts, file:line anchors, and test intent** — not full implementations. Each step states *what to assert* and *what to build / where*; the executing agent writes the Swift. Small declarations (enum cases, method signatures) are shown because they are contracts; method bodies and full test bodies are not.
- **One lifecycle test suite (user directive):** every lifecycle test — new *and* the relocated existing ones — lives in a single `@Suite struct LifecycleTests` in `CameraKit/Tests/CameraKitTests/LifecycleTests.swift`. Group by `// MARK:` comments, not by separate suites. The test filter is therefore always `eva-swift-stitchTests/LifecycleTests`.
- **No simulators, ever (CLAUDE.md §6).** Destination order: physical iPad → Mac "Designed for iPad" → error.
- **Build:** `mcp__XcodeBuildMCP__build_run_device` (primary) or `scripts/build-summary.sh` (fallback). Never raw `xcodebuild` / `swift build`.
- **Test:** `mcp__XcodeBuildMCP__test_device` with session default scheme `eva-swift-stitch` (call `session_set_defaults { scheme: "eva-swift-stitch" }` once; never pass `-scheme` via extraArgs), or `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStructName>` (fallback). **Filter by `@Suite` struct name, not filename** (CLAUDE.md §8).
- **New test file → run `scripts/sync-test-target.sh`** (idempotent) before testing, so the Xcode `eva-swift-stitchTests` dual-member target picks it up.
- **Commits (CLAUDE.md §7):** each `git` op needs explicit user approval; hooks are never skipped (`--no-verify` is forbidden). The pre-commit hook runs swift-format `--strict` (a blank `///` line is required after the first sentence of any multi-sentence doc comment), SwiftLint, and `CONTRACTS.md` regen. "Commit" steps below are checkpoints — surface them for approval rather than committing autonomously.
- **SourceKit cross-file errors are advisory.** Trust the build log, not the Issue Navigator (CLAUDE.md §6.1).
- **Worktree setup — verify before trusting build/commit automation.** In a fresh worktree confirm (1) XcodeBuildMCP's `projectPath` points at the *worktree* xcodeproj (`session_show_defaults`) — a stale default builds the **main** repo and silently ignores your edits; (2) `git config --get core.hooksPath` is `.githooks`, not `.git/hooks` — otherwise commits skip the swift-format gate **and** the `CONTRACTS.md` regen. Both bit this session; see project memory `feedback_worktree_xcodebuild_projectpath`.
- **Test seam in place:** `_postSessionEventForTest(_:)` (`CameraEngine.swift:1859`) injects `CameraSession.SessionEvent`s; `_markOpenForTest()` (`:591`), `_armWatchdogsForTest()` (`:1875`), `_captureWatchdogArmedTokenForTest` (`:1866`) exist. Add new test-only seams in the same style (clearly-named, `_…ForTest`).

---

## File Structure

**Modify (package):**
- `CameraKit/Sources/CameraKit/SessionState.swift` — home of public lifecycle value types; gains `AppLifecyclePhase` (Task 3).
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — the bulk: `currentPhase`, `initialPhase` param, `setLifecyclePhase`, the shared `reconcile` routine, latest-intent-wins, two predicates, third-actuation-site wiring, demotions (Tasks 4–9, 11).

**Modify (host app):**
- `eva-swift-stitch/UI/ViewModel.swift` — engine construction with `initialPhase` (Task 4); `handleScenePhase` collapse + `cameFromBackground` removal + `map(_:)` (Task 10).

**Modify (tests — relocation, Task 2):**
- `CameraKit/Tests/CameraKitTests/Stage09Tests.swift` — remove the `HitlLifecycleTests` suite (its tests move to `LifecycleTests`); leave the watchdog/recovery/AE/FPS suites untouched.
- `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift` — remove `Stage13Phase2InterruptedStateTests` and `Stage13Phase2ScenePhaseMirrorGuardTests` (their tests move); leave the other Stage13Phase2 suites untouched.

**Create:**
- `CameraKit/Tests/CameraKitTests/LifecycleTests.swift` — the single `@Suite struct LifecycleTests` (relocated existing tests + all new ones).
- `CameraKit/README.md` — package README with "Lifecycle" section; none exists today (Task 12).

**Regenerate:**
- `CameraKit/CONTRACTS.md` — via `scripts/regen-contracts.sh` (auto on pre-commit) (Task 12).

**Out of scope (file as follow-ups, do not implement):** `StopReason.pause` cleanup; `sensitiveContentMitigationActivated`; permission/route revocation mid-session (spec *Follow-ups*). Downstream cam2fd plugin native-layer change is documented, edited in its own repo.

---

## Task 1: Baseline — confirm the committed tree builds and lifecycle tests are green

The pause/resume removal (commit `31ca8af`) was committed build-unverified. Establish a green baseline before changing anything. This task runs against the **current** layout (suites still in their stage files).

**Files:** none (verification only).

- [ ] **Step 1: Set session scheme default**
  Call `mcp__XcodeBuildMCP__session_set_defaults { scheme: "eva-swift-stitch" }` (and `deviceId` if a physical iPad is connected — verify with `session_show_defaults` / `xcrun xctrace list devices`).

- [ ] **Step 2: Build the app + package**
  Run the build (conventions). Expected: `BUILD SUCCEEDED`. If it fails on a missing `pause`/`resume` reference, a caller was missed — grep `\.pause(\|\.resume(` across `eva-swift-stitch/` and `CameraKit/` and fix before continuing.

- [ ] **Step 3: Run the existing lifecycle/interruption suites (current names/locations)**
  Filters: `eva-swift-stitchTests/HitlLifecycleTests`, `eva-swift-stitchTests/Stage13Phase2InterruptedStateTests`, `eva-swift-stitchTests/Stage13Phase2ScenePhaseMirrorGuardTests`, `eva-swift-stitchTests/SessionStateMachineTests`.
  Expected: all PASS. **Record the per-test pass list** — this exact set must stay green after the Task 2 relocation (pure move, no behavior change).

- [ ] **Step 4: Record the baseline** in the plan's task notes (suite + per-test pass list). No commit.

---

## Task 2: Consolidate all lifecycle tests into one `LifecycleTests` suite

Pure test refactor — **no source change, no behavior change**. Per user directive, gather the existing lifecycle tests into a single suite that the new tests will also join. This is a *move* (every test still runs); provenance lives in git history.

**Scope of "lifecycle related" (move these):**
- `HitlLifecycleTests` (Stage09Tests.swift:303) — incl. `interruptionEndedRearmsWatchdog()` (`:338`), `interruptionEndedWhileBackgroundedDoesNotRearm()` (`:369`), `scenePhaseMirrorAllowsLegitEdges()` (`:444`), **and every other `@Test` in that suite**.
- `Stage13Phase2InterruptedStateTests` (Stage13Phase2Tests.swift:107) — `interruptionEndStillRestoresStreaming()`, `scenePhaseActiveFromInterruptedIsSkipped()`.
- `Stage13Phase2ScenePhaseMirrorGuardTests` (Stage13Phase2Tests.swift:200) — `scenePhaseActiveFromInterruptedIsSkipped()`.

**Do NOT move** the pure device-mechanism suites (`Stage09WatchdogTests`, `Stage09RecoveryTests`, `Stage09DisarmTests`, `Stage09CameraInUseTests`, AE/FPS, etc.) — they test watchdog/recovery primitives, not the app-lifecycle surface. (Flagged for your review: if you want those in too, say so.)

**Files:** Create `LifecycleTests.swift`; modify `Stage09Tests.swift`, `Stage13Phase2Tests.swift`.

- [ ] **Step 1: Create `LifecycleTests.swift`** with `@Suite struct LifecycleTests { }` and `@testable import CameraKit` + `import Testing` (match the imports the source suites use).

- [ ] **Step 2: Move the in-scope tests** into `LifecycleTests` as `@Test` methods, grouped under a `// MARK: - Relocated (interruption / scenePhase)` section. Preserve each test's body verbatim and any run-gating traits (e.g. `.disabled`, `.tags`, HITL gating) exactly.

- [ ] **Step 3: Resolve name collisions.** Two suites both define `scenePhaseActiveFromInterruptedIsSkipped()` — `@Test` names must be unique within one struct. Rename the mirror-guard one (e.g. `scenePhaseActiveFromInterruptedIsSkipped_mirrorGuard()`); keep its `@Test("…")` display string descriptive.

- [ ] **Step 4: Fix dependencies.** If a moved test referenced a `private`/`fileprivate` helper inside its old stage file, move that helper too or promote it to a shared test helper (`TestPixelHelpers.swift` / `TestProgressLog.swift` are already shared and need no change). Remove the now-empty source suites from `Stage09Tests.swift` / `Stage13Phase2Tests.swift`.

- [ ] **Step 5: Wire the new file in** — `scripts/sync-test-target.sh`.

- [ ] **Step 6: Verify the move is behavior-neutral.**
  Run `eva-swift-stitchTests/LifecycleTests` → every relocated test PASSES and the set matches Task 1's recorded list (same tests, new home).
  Run the untouched siblings (`eva-swift-stitchTests/Stage09WatchdogTests`, `…/Stage13Phase2InterruptedStateTests`? — now gone; run remaining Stage13Phase2 suites) to confirm removal didn't break neighbors. Build the package + app: `BUILD SUCCEEDED`.

- [ ] **Step 7: Note the relocation** in `CameraKit/state.md` (Decisions / Open-questions) or `DECISIONS.md` — lifecycle tests consolidated out of the stage files by design, per user direction.

- [ ] **Step 8: Commit** — `refactor(test): consolidate lifecycle tests into one LifecycleTests suite`.

---

## Task 3: Add the `AppLifecyclePhase` public enum

**Files:**
- Modify: `CameraKit/Sources/CameraKit/SessionState.swift` (cluster with `SessionState:3`, `RecordingState:16`, `StreamId:23`, `RecordingOptions:34`, `RecordingStart:73`).
- Modify: `CameraKit/Tests/CameraKitTests/LifecycleTests.swift`.

**Contract (show this exactly — it is the public surface):**
```swift
/// The host's current visibility. The only lifecycle vocabulary a host needs —
/// nothing about gates, drains, or sessions.
public enum AppLifecyclePhase: Sendable {
    case active       // foreground & interactive
    case inactive     // visible but not receiving input (Control Center, call banner, app-switcher peek)
    case background   // not visible
}
```
Carry the doc comment. Plain `Sendable` enum, no other annotations (spec *Public API*, "Names locked").

- [ ] **Step 1: Write the failing test** — add to `LifecycleTests` (MARK `// MARK: - Public surface`): construct all three cases and pass one through a `Sendable`-constrained generic helper (compile-level conformance guard); assert an array of all three has count 3. Intent: prove the type exists, is public, and is `Sendable`.

- [ ] **Step 2: Run it — verify it fails** (`eva-swift-stitchTests/LifecycleTests`). Expected: FAIL (`cannot find type 'AppLifecyclePhase'`).

- [ ] **Step 3: Add the enum** to `SessionState.swift` per the contract above.

- [ ] **Step 4: Run it — verify it passes.** Expected: PASS.

- [ ] **Step 5: Commit** — `feat(camerakit): add AppLifecyclePhase public enum`.

---

## Task 4: Add `currentPhase` + the required `initialPhase` init parameter

A **breaking init change** (spec F4: no default — an unsafe default turns the camera on with no foreground UI). It ripples to **every** `CameraEngine(...)` construction site, so they are all updated here to keep every target buildable.

**Files:**
- Modify: `CameraEngine.swift:118` (`public init(clock:)`), add a stored `currentPhase` property near the other lifecycle state.
- Modify: `eva-swift-stitch/UI/ViewModel.swift:89` (construction site only — the `handleScenePhase` rewrite is Task 10).
- Modify: every `CameraEngine(` call site under `CameraKit/Tests/CameraKitTests/`.

**Contract:**
```swift
public init(initialPhase: AppLifecyclePhase, clock: any CameraKitClock = SystemClock())
```
- `currentPhase` is engine-internal state (not a stored public var). It is the single phase source; **no** `previousPhase`, **no** sticky flag (spec *What moves inside the package*).
- Pre-`open()`, the property is just recorded (no hardware exists yet).

- [ ] **Step 1: Write the failing test** — add to `LifecycleTests` (MARK `// MARK: - Construction`): `CameraEngine(initialPhase: .background)` constructs; after `open()` with `initialPhase: .background`, the session is **not** running (no `startRunning`) — assert via the session-running probe the relocated/Stage suites use (grep `isRunning`/`startRunning` assertions). Intent: F4 safe-construction guard, minimal form.

- [ ] **Step 2: Run it — verify it fails** (`initialPhase:` not a parameter). Expected: FAIL.

- [ ] **Step 3: Add the parameter + property**, store `initialPhase` into `currentPhase`.

- [ ] **Step 4: Fix all construction sites.**
  `grep -rn 'CameraEngine(' CameraKit/Tests/ eva-swift-stitch/`. For existing tests that assume a live engine, pass `initialPhase: .active` (preserves prior behavior). For `ViewModel.swift:89`, pass `initialPhase: .background` (privacy-safe launch default; the first host forward corrects it — spec *Phase is a property*, "pass `.background` when unsure"). Do **not** add a default to silence call sites.

- [ ] **Step 5: Build + run the full regression set** (`eva-swift-stitchTests/LifecycleTests` + the untouched Stage suites). Expected: `BUILD SUCCEEDED`, all PASS (behavior unchanged — the engine only stores a phase so far).

- [ ] **Step 6: Commit** — `feat(camerakit)!: require initialPhase at CameraEngine construction`.

**As-built (done 2026-05-21, in combined commit `4e9a811`).** Implemented as a *store-only* change per spec lines 125–132 (`open()`-runs-reconcile is Task 5, so Task 4 only records `currentPhase`). Deviations applied during execution, all advisor-confirmed:
- **F4 behavioral test deferred to Task 5a.** "Construct `.background` + `open()` → no `startRunning`" needs the reconcile routine `open()` gains in Task 5, so Step 1's runtime assertion moved there. Task 4's actual test, `initialPhaseIsRecordedAtConstruction`, asserts the phase is *recorded* via the new `_currentPhaseForTest` seam.
- **`AppLifecyclePhase` is plain `Sendable`, no `Equatable`** (spec lines 111–112) — tests compare via a `switch`-to-`String`, not `==`.
- **Full-suite regression deferred to Task 13.** Build success already proves all 35 call sites compile; `.active` is behavior-neutral (nothing reads `currentPhase` until Task 5), so only `LifecycleTests` + `SessionStateMachineTests` were run (20/20 green on device).
- The Task 2 name collision the plan predicted did not exist — no rename was needed.

---

## Task 5: The shared reconciliation routine + `setLifecyclePhase`

The core. Build the single routine that derives the target from `currentPhase` and reconciles the engine's *actual* state to it, then expose `setLifecyclePhase`. Reuse the existing step primitives — do not duplicate ordering logic. Reference the logic being consolidated: `notifyScenePhasePaused:561`, `backgroundSuspend:763`, `backgroundResume:785`, and the steps `setGate:1641`, `drainSubmittedFrame:1649`, `armWatchdogs:1713`, `disarmWatchdogsAsync:1695`, session `startRunning`/`stopRunning` (on `sessionQueue`, ADR-07), `finalizeActiveRecording(reason: .user)`, `publishState:1660`.

**Target table (spec *What moves inside the package*) — the routine's contract:**

| Phase | gate | session | watchdogs |
|---|---|---|---|
| `.active` | open | start if not (guarded in Task 7) | armed (guarded in Task 7) |
| `.inactive` | closed | start if not (guarded in Task 7) | disarmed |
| `.background` | closed | stopped + recording finalized | disarmed |

**Ordering invariants (spec):** gate close is a synchronous atomic sequenced **before any suspending step**; the into-`.background` path follows the field-guide §5 sequence: **disarm + cancel retry → finalize active recording → drain → `stopRunning`**. Recording finalize delegates entirely to `Recording.stop()` (`Recording.swift:165`, its own `beginBackgroundTask("recording-drain"):195` + `recordingFinishTimeoutSeconds`) — the routine adds no background task or timeout of its own.

**Contract:**
```swift
extension CameraEngine {
    public func setLifecyclePhase(_ phase: AppLifecyclePhase) async   // writes currentPhase unconditionally, never throws; reconciles only when open
}
```
Also: `open()` (`:180`) and `close()` (`:391`) — `open()` runs the same routine against `currentPhase` after hardware creation; `close()` leaves `currentPhase` intact. (The OS-recovery-exit third site is Task 8.)

> Sub-tasks 5a–5d each add one `@Test` to `LifecycleTests` (MARK `// MARK: - Reconciliation`) and the minimal routine code to pass it. 5a builds the skeleton (`.active`/`.inactive` cheap-pause path); later sub-tasks extend it. Assert against the **target table** (gate state, session running, watchdog armed, recording finalized) **and** `stateStream()` output, reusing the gate/session/watchdog probes already in the suite.

**Carried forward from the Task 4 pause (advisor-flagged — do these in 5a):**
- **Add a `_isSessionRunningForTest` seam** mirroring `cameraSession?.avSession.isRunning`. No session-running probe exists today (tests use `_currentStateForTest` / watchdog tokens / `stateStream`); the F4 and session-start assertions need a direct one — indirect probes ("state stays `.opening`") are brittle.
- **Home the deferred F4 test here** (moved from Task 4): construct `initialPhase: .background`, run `open()` (which now runs `reconcile`), assert session **not** running (`_isSessionRunningForTest == false`) + gate closed. This *is* the F4 safe-construction guarantee — do not drop it.
- **Leave a no-op latest-intent-wins checkpoint at `reconcile`'s entry** — capture a generation token even though Task 6 fills in the abort logic. Otherwise Task 6 forces a `reconcile` refactor between sub-tasks.

### Task 5a: `.active → .inactive → .active` cheap pause
- [ ] **Step 1: Failing tests** —
  - `cheapPauseDoesNotStopSession`: drive `.active → .inactive → .active`; assert the session **never** stopped (no `stopRunning`), gate closed at `.inactive` then open at `.active`, watchdogs disarmed at `.inactive` then armed at `.active`. (~4 ms gate-flip path, spec *Rejected* S2 rationale.)
  - `openIntoBackgroundDoesNotStartSession` (F4, deferred from Task 4): construct `initialPhase: .background`, `open()`, assert session **not** running (`_isSessionRunningForTest == false`) and gate closed.
- [ ] **Step 2: Run — fail** (`setLifecyclePhase` / `_isSessionRunningForTest` undefined).
- [ ] **Step 3: Implement** `setLifecyclePhase` + the `reconcile` skeleton + the `.active`/`.inactive` branches (gate, session-start-if-not, watchdog arm/disarm), reusing primitives. Gate-close synchronous-first. **Also: wire `open()` to run `reconcile` against `currentPhase`** (so opening into `.background` skips `startRunning` — the F4 test); **add the `_isSessionRunningForTest` seam**; and **leave a no-op generation capture at `reconcile`'s entry** (latest-intent-wins hook; Task 6 fills the abort logic).
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `feat(camerakit): setLifecyclePhase + reconciliation (active/inactive)`.

### Task 5b: `.active → .inactive → .background` suspend
- [ ] **Step 1: Failing test** — `backgroundSuspendFinalizesAndStops`. With an active recording, drive to `.background`; assert ordered sequence ran (watchdogs disarmed, recording finalized, session stopped, gate closed) and finalize happened **before** `stopRunning`.
- [ ] **Step 2: Run — fail.**
- [ ] **Step 3: Implement** the `.background` branch as the field-guide §5 ordered sequence, delegating finalize to `Recording.stop()`.
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `feat(camerakit): reconciliation .background ordered suspend`.

### Task 5c: `.background → .inactive → .active` resume
- [ ] **Step 1: Failing test** — `resumeRestartsAtInactiveGateOpensAtActive`. Open with `initialPhase: .background`; drive `.background → .inactive → .active`; assert session restarts at `.inactive` with gate **still closed**, gate opens at `.active`. The case the old `cameFromBackground` flag handled — no flag now.
- [ ] **Step 2: Run — fail or pass.** (May already pass from 5a/5b — that is the point of the declarative model. If it passes, keep the test as a guard and note it.)
- [ ] **Step 3: Implement** only if needed.
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `test(camerakit): resume ordering reconciles without sticky flag`.

### Task 5d: Flutter ordering `.background → .background → .inactive → .active`
- [ ] **Step 1: Failing test** — `duplicateBackgroundIsNoOpAndConverges`. Assert the duplicate `.background` is a no-op (idempotent) and the sequence converges to the same terminal state as 5c.
- [ ] **Step 2–4:** run; implement idempotency if a repeat misbehaves; run.
- [ ] **Step 5: Commit** — `test(camerakit): Flutter resume ordering converges`.

---

## Task 6: latest-intent-wins contract

Make a superseded, in-flight reconciliation abort rather than apply stale work (spec *Concurrency*, governing contract). Without it, a `.background` reconcile straggled by a completing `.active` leaves gate-open + watchdogs-armed + session-stopped → permanent black preview + spurious recovery (F1).

**Files:** `CameraEngine.swift` (the routine from Task 5) + a test-only interleave seam.

**Contract / direction:**
- Pick **one** mechanism (spec leaves it to the implementer): (a) a **monotonic generation counter** captured on entry, re-checked before each suspending step, abort if bumped; or (b) a **single-flight reconciler** that re-reads the latest target after every `await` and abandons a stale target. Recommend (a) for simplicity. Whichever is chosen must also cover OS-event-vs-event (Task 9) since both run on the actor.
- Add a clearly-named test-only suspension hook at the post-gate / pre-`stopRunning` checkpoint of the `.background` path (style of `_postSessionEventForTest`), so a test can deterministically admit a second call mid-flight. Alternatively reuse a slow fake recording writer if the suites already have one (grep the Stage10 / recording suites).

- [ ] **Step 1: Write the failing test** — add to `LifecycleTests` (MARK `// MARK: - Latest-intent-wins`), `backgroundSupersededByActiveEndsActive` (the F1 regression guard). Drive `.background` then `.active` so `.active` is admitted while the `.background` reconcile is suspended at the seam. Assert terminal state = **`.active`** (session running, gate open, watchdogs armed), **not** session-stopped, and **no** `RecoveryCoordinator` entry / off-map fault logged.
- [ ] **Step 2: Run — verify it fails** (the straggler applies stale `stopRunning`). Expected: FAIL with session-stopped terminal state.
- [ ] **Step 3: Implement** the chosen mechanism so the superseded reconcile aborts at its next checkpoint.
- [ ] **Step 4: Run — verify it passes.**
- [ ] **Step 5: Run the full regression set** (`LifecycleTests` + untouched Stage suites) — no regressions.
- [ ] **Step 6: Commit** — `fix(camerakit): latest-intent-wins reconciliation (F1)`.

---

## Task 7: Two predicates + the phase→OS guard (F2) + label deferral

**Files:** `CameraEngine.swift` (reconcile + the label-publish path that `notifyScenePhasePaused:561` owns today).

**Contracts (both over `SessionState` — single source of truth, no parallel mirror; spec *The OS-owned guard*):**
```
osOwnsDevice            = current ∈ {.interrupted, .recovering, .error}
shouldDeferCommandLabel = osOwnsDevice || (current == .opening && target == .paused)
```
- Apply `osOwnsDevice` to **both** the watchdog-arm guard **and** the `.active`/`.inactive` session-start in `reconcile` (don't fight an OS interruption / in-flight recovery for the device).
- Apply `shouldDeferCommandLabel` to the label-deferral, replacing the inline `classify(...) == .offMap` check (`:561`/`:564` region). It must preserve the `.opening → .paused` launch-race that `classify` covers today (`commandMap[.opening] = [.streaming, .closed, .error]` — no `.paused`).

- [ ] **Step 1: Write the failing tests** — add to `LifecycleTests` (MARK `// MARK: - OS-owned guard`):
  - `activeReconcileDefersWhileOSOwnsDevice`: drive into an OS-owned state (`_postSessionEventForTest(.otherInterruption(...))` → `.interrupted`, or `videoDeviceInUseByAnotherClient` → `.error`), then `setLifecyclePhase(.active)`; assert watchdogs stay **disarmed** **and** no `startRunning` — no spurious watchdog fire, no `RecoveryCoordinator` entry, no fatal escalation.
  - `commandLabelDefersUnderOSOwnership`: `setLifecyclePhase(.active)` while `.interrupted`/`.recovering` must not overwrite the OS label (terminal label stays OS truth) — parity with `notifyScenePhasePaused` today.
  - `deferralParityOpeningToPaused`: `.opening → .paused` defers; `.opening → .streaming` publishes.
- [ ] **Step 2: Run — verify they fail.**
- [ ] **Step 3: Implement** the two predicates and apply them at the three sites above.
- [ ] **Step 4: Run — verify they pass**, plus the relocated `scenePhaseActiveFromInterruptedIsSkipped_mirrorGuard` and `SessionStateMachineTests` (deferral/classifier parity) stay green.
- [ ] **Step 5: Commit** — `fix(camerakit): osOwnsDevice + shouldDeferCommandLabel guards (F2)`.

---

## Task 8: Third actuation site — OS-recovery exit reconciles against `currentPhase`

Make the OS event path stop unconditionally re-arming / restarting. When it resolves an OS-owned state, run the **same** `reconcile` against `currentPhase` (spec *The OS-owned guard*, OS→phase direction). Closes the asymmetry where `interruptionEnded` while backgrounded turns the camera on (F4-class — the gate gates GPU submission, not `AVCaptureSession` running state).

**Files:** `CameraEngine.swift:1849-1854` — the `.otherInterruptionEnded` branch of `onSessionEvent` (currently `publishState(.streaming, kind: .event)` + `armWatchdogs()`).

- [ ] **Step 1: Write the failing tests** — add to `LifecycleTests` (MARK `// MARK: - Third actuation site (OS→phase)`):
  - `interruptionEndedWhileBackgroundStaysStopped`: `.active` + recording → inject `.otherInterruption` (`.interrupted`) → `setLifecyclePhase(.background)` → inject `.otherInterruptionEnded`. Assert session **stays stopped**, watchdogs **disarmed**, no camera LED (no `startRunning`), no `RecoveryCoordinator` restart.
  - `interruptionEndedWhileInactiveRestartsGateClosed`: same but standing phase `.inactive` → session **restarts**, gate **closed**, watchdogs disarmed.
- [ ] **Step 2: Run — observe what fails (fail or partial-pass).** The relocated `interruptionEndedWhileBackgroundedDoesNotRearm` proves the gate-guarded re-arm is *already* suppressed when backgrounded, so the "watchdogs disarmed" assertion may already hold; the likely current divergences are the **label republish** (`publishState(.streaming)` on `interruptionEnded` regardless of phase) and the **`.inactive` row** (no reconcile to gate-closed/session-running). Note exactly which assertions fail — that is what the fix must address.
- [ ] **Step 3: Implement** — route the `.otherInterruptionEnded` resolve through `reconcile` (reading `currentPhase`) instead of the inline `publishState(.streaming)` + `armWatchdogs()`. This makes `reconcile`'s caller list three (update the count in any in-code comment that enumerates callers).
- [ ] **Step 4: Run — verify the new tests pass AND the relocated guards stay green:** `interruptionEndedRearmsWatchdog` (the `.active` case must still re-arm), `interruptionEndedWhileBackgroundedDoesNotRearm`, `interruptionEndStillRestoresStreaming`. If any relocated test now fails, the reconcile path is not reproducing prior `.active` behavior — fix forward, do not weaken the relocated tests.
- [ ] **Step 5: Commit** — `fix(camerakit): OS-recovery exit reconciles against currentPhase`.

---

## Task 9: OS-event-vs-event interleave (F5)

Two interruption handlers (`begin`/`ended`), each dispatched as its own `Task { await onSessionEvent(...) }` (`:260-261`), can interleave on the actor. Ensure a stale `.ended`/recovery handler doesn't re-arm / republish over a newer `.begin` (spec *Concurrency*, case 3). The Task 6 mechanism should already cover this since both run on the actor — this task confirms and closes any gap.

**Files:** `CameraEngine.swift` (`onSessionEvent:1816` handlers + the Task 6 mechanism).

- [ ] **Step 1: Write the failing test** — add to `LifecycleTests` (MARK `// MARK: - Event-vs-event (F5)`), `staleEndedDoesNotOverrideNewerBegin`. Inject `.otherInterruption` then `.otherInterruptionEnded` so the `.ended` handler is admitted while the `.begin` handler is suspended; assert no stale re-arm / label republish; terminal state matches the **latest** event.
- [ ] **Step 2: Run — fail or pass.** If Task 6 already covers it, the test passes — keep it as a guard and note it; otherwise implement.
- [ ] **Step 3: Implement** event-handler idempotency / latest-wins discipline as needed.
- [ ] **Step 4: Run — pass**, full regression set green.
- [ ] **Step 5: Commit** — `test(camerakit): OS event-vs-event interleave guard (F5)`.

---

## Task 10: Host migration — collapse `handleScenePhase`

**Files:** `eva-swift-stitch/UI/ViewModel.swift` — `handleScenePhase:321-354`, `cameFromBackground:84`. (`CameraView.swift:99` keeps forwarding `scenePhase` to the view model; `.task(id: scenePhase)` is now redundant with latest-intent-wins but harmless — leave it, or optionally simplify in this task.)

- [ ] **Step 1: Replace the body** of `handleScenePhase` with a single `await engine.setLifecyclePhase(map(phase))`.
- [ ] **Step 2: Add the host mapping** — a private `map(_ p: ScenePhase) -> AppLifecyclePhase` (identity over the three cases; `@unknown default → .inactive`). This is the only place SwiftUI types touch the lifecycle path; the package imports no SwiftUI (spec *Host mapping*).
- [ ] **Step 3: Remove `cameFromBackground`** and any now-dead helper state it fed.
- [ ] **Step 4: Build + smoke the regression set** (conventions). Expected: `BUILD SUCCEEDED`; `LifecycleTests` + untouched Stage suites green. Device HITL smoke (foreground/background/lock-unlock, recording across background) is deferred evidence — note it for the device pass (Task 13).
- [ ] **Step 5: Commit** — `refactor(app): drive lifecycle via setLifecyclePhase`.

---

## Task 11: Demote the now-internal drivers

With the host on `setLifecyclePhase`, the old drivers have no external caller (Migration verification: grep returns hits only in `ViewModel.swift`, now rewritten). Demote — keep them reachable to `@testable import` tests.

**Files:** `CameraEngine.swift` — `setGate:1641`, `drainSubmittedFrame:1649`, `notifyScenePhasePaused:561`, `backgroundSuspend:763`, `backgroundResume:785`.

- [ ] **Step 1: Verify no external callers remain** — `grep -rn 'setGate\|drainSubmittedFrame\|notifyScenePhasePaused\|backgroundSuspend\|backgroundResume' eva-swift-stitch/ eva-swift-stitchTests/ eva-swift-stitchUITests/`. Expect zero in app/UI targets. (Test targets under `CameraKitTests/` may call them — that's fine, `@testable import`.)
- [ ] **Step 2: Change `public` → `internal`** on the five methods. If `notifyScenePhasePaused`/`backgroundSuspend`/`backgroundResume` are now fully subsumed by `reconcile` and called by **no** test, prefer removing them; if any test calls them, keep as `internal`. Decide per grep, don't guess.
- [ ] **Step 3: Build + full test run.** Expected: `BUILD SUCCEEDED`, all suites green (tests reach internals via `@testable`).
- [ ] **Step 4: Commit** — `refactor(camerakit): demote lifecycle drivers to internal`.

---

## Task 12: Documentation — README + docstrings + CONTRACTS

**Files:**
- Create: `CameraKit/README.md`.
- Modify (if not already carrying the convention): docstrings on `setLifecyclePhase` / `AppLifecyclePhase`.
- Regenerate: `CameraKit/CONTRACTS.md`.

- [ ] **Step 1: Create `CameraKit/README.md`** with a "Lifecycle" section — use the verbatim prose block under spec *Documentation deliverables* (SwiftUI 1:1 forward; Flutter native-layer mapping `resumed→.active`, `inactive→.inactive`, `hidden`/`paused→.background`, `detached→`skip; "never throws, latest call wins"; construct with `initialPhase`, no default). Keep it in sync with the docstrings.
- [ ] **Step 2: Add the Dart-side lifecycle guidance for Flutter consumers.** In the README's "Lifecycle" section, immediately after the Flutter native-layer mapping, add a short note telling Flutter apps what their Dart layer should — and should not — do about app lifecycle. Mirror it into the cam2fd plugin's Flutter-facing README as part of the downstream change noted in Task 13 Step 4 (the CameraKit README is the source of truth; cam2fd points at it). Use this verbatim:

  > The Dart side still sees the lifecycle changes, it just doesn't need to act on them for camera purposes. The only thing the Dart layer should use its own lifecycle awareness for is managing its own rendering — like whether to paint the Texture widget or show a placeholder. And even that is better driven by the stateStream coming up from CameraKit through the EventChannel, since that reflects what the camera is actually doing rather than what the OS said a few milliseconds ago.

  This completes the Flutter picture the native-layer mapping starts: the **native** plugin layer owns the single camera-lifecycle forward (UIScene → `AppLifecyclePhase` → `setLifecyclePhase`); the **Dart** layer must not duplicate that forward, and drives its own widget rendering off `stateStream` / `EventChannel`, not a raw `WidgetsBindingObserver`.

- [ ] **Step 3: Confirm the docstrings** on `setLifecyclePhase(_:)` and `AppLifecyclePhase` carry the same calling convention (source text in spec *Public API*). Mind the swift-format `--strict` rule: blank `///` line after the first sentence of any multi-sentence doc comment.
- [ ] **Step 4: Regenerate CONTRACTS** — `bash scripts/regen-contracts.sh` (also auto-runs on pre-commit). Confirm `setLifecyclePhase` + `AppLifecyclePhase` appear and the demoted methods no longer show as `public`.
- [ ] **Step 5: Commit** — `docs(camerakit): add README Lifecycle section + Flutter Dart-side guidance; regen CONTRACTS`.

---

## Task 13: Final verification + follow-up filing

- [ ] **Step 1: Clean full build + full test run** on physical iPad (preferred) → Mac "Designed for iPad". Expected: `BUILD SUCCEEDED`, entire suite green. If SourceKit phantoms appear but the build log is green, discard them (CLAUDE.md §6.1).
- [ ] **Step 2: Device HITL smoke** (physical iPad — required for camera-indicator / off-main `startRunning`): foreground→background→foreground; lock→unlock; recording active across a background; a foreground OS interruption (e.g. incoming call / Control Center) then resume. Confirm no black preview, no spurious recovery, no corrupt `.mp4`, and the camera LED is **off** whenever the app is backgrounded. Save evidence under `measurements/` if the repo convention calls for it.
- [ ] **Step 3: File the out-of-scope follow-ups** (spec *Follow-ups*) wherever the repo tracks them (`CameraKit/state.md` "Open questions" or DECISIONS log): `StopReason.pause` now production-dead; `sensitiveContentMitigationActivated` unenumerated; permission/route revocation mid-session unmodeled.
- [ ] **Step 4: Note the cam2fd downstream change** (documented, not edited here): plugin native layer maps UIScene → `AppLifecyclePhase` and calls `setLifecyclePhase`; Dart stops forwarding lifecycle.
- [ ] **Step 5: Final commit** if any verification artifacts were produced — `chore(camerakit): lifecycle ownership verification + follow-ups`.

---

## Self-review (completed during plan authoring)

**Spec coverage:** Public API enum+method → T3,T5. Phase-as-property / required initialPhase → T4. Reconciliation target table + ordered background sequence + recording-finalize delegation → T5. latest-intent-wins (F1) → T6. Two predicates + phase→OS guard (F2) + label deferral + parity → T7. Third actuation site / OS→phase → T8. Event-vs-event (F5) → T9. Host migration (handleScenePhase, cameFromBackground, initialPhase) → T4 (construction) + T10. Demotions → T11. Docs (README + docstrings) + CONTRACTS regen → T12. Removed pause/resume → already committed (`31ca8af`), baseline-verified in T1. Single lifecycle suite (user directive) → T2 (relocation) + every test step targets `LifecycleTests`. Testing-section cases → mapped across T5–T9 + T13 (device HITL). Follow-ups → T13. **No uncovered spec requirement.**

**Type/name consistency:** `AppLifecyclePhase` (`.active`/`.inactive`/`.background`), `setLifecyclePhase(_:)`, `currentPhase`, `initialPhase`, `reconcile`, `osOwnsDevice`, `shouldDeferCommandLabel`, suite `LifecycleTests` — used consistently across tasks and matching the spec verbatim.

**Test-relocation integrity:** every test named in T1's baseline is accounted for in T2's move (HitlLifecycleTests + the two Stage13Phase2 interruption suites); name collision (`scenePhaseActiveFromInterruptedIsSkipped`) resolved; T7/T8 reference the relocated tests by their new home, not the old stage files.
