# CameraKit Lifecycle Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the host-orchestrated, 5-primitive scenePhase handling with a single public lifecycle API — `CameraEngine.setLifecyclePhase(_:)` + a required `initialPhase` — backed by one declarative reconciliation routine the package owns end-to-end.

**Architecture:** The host forwards a coarse `AppLifecyclePhase` (`.active`/`.inactive`/`.background`); the engine carries `currentPhase` as a property and reconciles hardware (GPU gate, session start/stop, stall watchdogs, recording finalize) to the target each phase implies. The routine runs at **three actuation sites** — `open()`, `setLifecyclePhase`, and OS-recovery exit — each reading `currentPhase`. A latest-intent-wins contract makes superseded in-flight reconciliations abort. Device-interruption lifecycle stays package-owned and unchanged except where it shares the actor with the phase path.

**Tech Stack:** Swift 6.2, iOS 26, `actor`-isolated `CameraEngine`, AVFoundation, swift-testing, XcodeBuildMCP (device-only).

**Spec:** `docs/superpowers/specs/2026-05-21-camerakit-lifecycle-ownership-design.md` — read it before starting. Section names below (e.g. *What moves inside the package*, *Concurrency*, *The OS-owned guard*) refer to that spec.

---

## Plan conventions (read once)

- **Code density (user directive):** tasks give **contracts, file:line anchors, and test intent** — not full implementations. Each step states *what to assert* and *what to build / where*; the executing agent writes the Swift. Small declarations (enum cases, method signatures) are shown because they are contracts; method bodies and full test bodies are not.
- **No simulators, ever (CLAUDE.md §6).** Destination order: physical iPad → Mac "Designed for iPad" → error.
- **Build:** `mcp__XcodeBuildMCP__build_run_device` (primary) or `scripts/build-summary.sh` (fallback). Never raw `xcodebuild` / `swift build`.
- **Test:** `mcp__XcodeBuildMCP__test_device` with session default scheme `eva-swift-stitch` (call `session_set_defaults { scheme: "eva-swift-stitch" }` once; never pass `-scheme` via extraArgs), or `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStructName>` (fallback). **Filter by `@Suite` struct name, not filename** (CLAUDE.md §8).
- **New test file → run `scripts/sync-test-target.sh`** (idempotent) before testing, so the Xcode `eva-swift-stitchTests` dual-member target picks it up.
- **Commits (CLAUDE.md §7):** each `git` op needs explicit user approval; hooks are never skipped (`--no-verify` is forbidden). The pre-commit hook runs swift-format `--strict` (a blank `///` line is required after the first sentence of any multi-sentence doc comment), SwiftLint, and `CONTRACTS.md` regen. "Commit" steps below are checkpoints — surface them for approval rather than committing autonomously.
- **SourceKit cross-file errors are advisory.** Trust the build log, not the Issue Navigator (CLAUDE.md §6.1).
- **Test seam in place:** `_postSessionEventForTest(_:)` (`CameraEngine.swift:1859`) injects `CameraSession.SessionEvent`s; `_markOpenForTest()` (`:591`), `_armWatchdogsForTest()` (`:1875`), `_captureWatchdogArmedTokenForTest` (`:1866`) exist. Add new test-only seams in the same style (clearly-named, `_…ForTest`).

---

## File Structure

**Modify (package):**
- `CameraKit/Sources/CameraKit/SessionState.swift` — home of public lifecycle value types; gains `AppLifecyclePhase` (Task 2).
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — the bulk: `currentPhase`, `initialPhase` param, `setLifecyclePhase`, the shared `reconcile` routine, latest-intent-wins, two predicates, third-actuation-site wiring, demotions (Tasks 3–8, 10).

**Modify (host app):**
- `eva-swift-stitch/UI/ViewModel.swift` — engine construction with `initialPhase` (Task 3); `handleScenePhase` collapse + `cameFromBackground` removal + `map(_:)` (Task 9).

**Create:**
- `CameraKit/Tests/CameraKitTests/LifecycleReconciliationTests.swift` — new swift-testing suites (Tasks 4–8).
- `CameraKit/README.md` — package README with "Lifecycle" section; none exists today (Task 11).

**Regenerate:**
- `CameraKit/CONTRACTS.md` — via `scripts/regen-contracts.sh` (auto on pre-commit) (Task 11).

**Preserve unchanged (must stay green):**
- `CameraKit/Tests/CameraKitTests/Stage09Tests.swift` — `HitlLifecycleTests` (`:303`), incl. `interruptionEndedRearmsWatchdog()` (`:338`) and `interruptionEndedWhileBackgroundedDoesNotRearm()` (`:369`).
- `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift` — `Stage13Phase2InterruptedStateTests` (`:107`), `Stage13Phase2ScenePhaseMirrorGuardTests` (`:200`).

**Out of scope (file as follow-ups, do not implement):** `StopReason.pause` cleanup; `sensitiveContentMitigationActivated`; permission/route revocation mid-session (spec *Follow-ups*). Downstream cam2fd plugin native-layer change is documented, edited in its own repo.

---

## Task 1: Baseline — confirm the committed tree builds and lifecycle tests are green

The pause/resume removal (commit `31ca8af`) was committed build-unverified. Establish a green baseline before changing anything.

**Files:** none (verification only).

- [ ] **Step 1: Set session scheme default**
  Call `mcp__XcodeBuildMCP__session_set_defaults { scheme: "eva-swift-stitch" }` (and `deviceId` if a physical iPad is connected — verify with `session_show_defaults` / `xcrun xctrace list devices`).

- [ ] **Step 2: Build the app + package**
  Run the build (conventions). Expected: `BUILD SUCCEEDED`. If it fails on a missing `pause`/`resume` reference, a caller was missed — grep `\.pause(\|\.resume(` across `eva-swift-stitch/` and `CameraKit/` and fix before continuing.

- [ ] **Step 3: Run the existing lifecycle/interruption suites**
  Test filters: `eva-swift-stitchTests/HitlLifecycleTests`, `eva-swift-stitchTests/Stage13Phase2InterruptedStateTests`, `eva-swift-stitchTests/Stage13Phase2ScenePhaseMirrorGuardTests`, `eva-swift-stitchTests/SessionStateMachineTests`.
  Expected: all PASS. This is the regression set the rest of the plan must keep green.

- [ ] **Step 4: Record the baseline** in the plan's task notes (suite pass counts). No commit.

---

## Task 2: Add the `AppLifecyclePhase` public enum

**Files:**
- Modify: `CameraKit/Sources/CameraKit/SessionState.swift` (cluster with `SessionState:3`, `RecordingState:16`, `StreamId:23`, `RecordingOptions:34`, `RecordingStart:73`).
- Create: `CameraKit/Tests/CameraKitTests/LifecycleReconciliationTests.swift`.

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

- [ ] **Step 1: Write the failing test**
  In the new file, suite `LifecyclePhaseTests`. One test: construct all three cases and pass one through a `Sendable`-constrained generic helper (compile-level conformance guard). Assert a trivial round-trip (e.g. an array of all three has count 3). Intent: prove the type exists, is public, and is `Sendable`.

- [ ] **Step 2: Wire the new test file into the Xcode target**
  Run `scripts/sync-test-target.sh`.

- [ ] **Step 3: Run it — verify it fails**
  Filter `eva-swift-stitchTests/LifecyclePhaseTests`. Expected: FAIL (`cannot find type 'AppLifecyclePhase'`).

- [ ] **Step 4: Add the enum** to `SessionState.swift` per the contract above.

- [ ] **Step 5: Run it — verify it passes.** Expected: PASS.

- [ ] **Step 6: Commit** — `feat(camerakit): add AppLifecyclePhase public enum`.

---

## Task 3: Add `currentPhase` + the required `initialPhase` init parameter

This is a **breaking init change** (spec F4: no default — an unsafe default turns the camera on with no foreground UI). It ripples to **every** `CameraEngine(...)` construction site, so they are all updated here to keep every target buildable.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:118` (`public init(clock:)`), add a stored `currentPhase` property near the other lifecycle state.
- Modify: `eva-swift-stitch/UI/ViewModel.swift:89` (construction site only — the `handleScenePhase` rewrite is Task 9).
- Modify: every `CameraEngine(` call site under `CameraKit/Tests/CameraKitTests/`.

**Contract:**
```swift
public init(initialPhase: AppLifecyclePhase, clock: any CameraKitClock = SystemClock())
```
- `currentPhase` is engine-internal state (not a stored public var). It is the single phase source; **no** `previousPhase`, **no** sticky flag (spec *What moves inside the package*).
- Pre-`open()`, the property is just recorded (no hardware exists yet).

- [ ] **Step 1: Write the failing test**
  Suite `LifecyclePhaseTests` (extend). Test: `CameraEngine(initialPhase: .background)` constructs; after `open()` (use `_markOpenForTest()` / the suites' standard open helper) with `initialPhase: .background`, the session is **not** running (no `startRunning`) — assert via the existing session-running probe used by Stage09/Stage13 suites (find it: grep `isRunning`/`startRunning` assertions in those suites). Intent: F4 safe-construction guard, minimal form.

- [ ] **Step 2: Run it — verify it fails** (`initialPhase:` not a parameter). Expected: FAIL.

- [ ] **Step 3: Add the parameter + property**, store `initialPhase` into `currentPhase`.

- [ ] **Step 4: Fix all construction sites.**
  `grep -rn 'CameraEngine(' CameraKit/Tests/ eva-swift-stitch/`. For existing tests that assume a live engine, pass `initialPhase: .active` (preserves prior behavior). For `ViewModel.swift:89`, pass `initialPhase: .background` (privacy-safe launch default; the first host forward corrects it — spec *Phase is a property*, "pass `.background` when unsure"). Do **not** add a default to silence call sites.

- [ ] **Step 5: Build + run the Task 1 regression set.** Expected: `BUILD SUCCEEDED`, all prior suites PASS (behavior unchanged — the engine only stores a phase so far).

- [ ] **Step 6: Commit** — `feat(camerakit)!: require initialPhase at CameraEngine construction`.

---

## Task 4: The shared reconciliation routine + `setLifecyclePhase`

The core. Build the single routine that derives the target from `currentPhase` and reconciles the engine's *actual* state to it, then expose `setLifecyclePhase`. Reuse the existing step primitives — do not duplicate ordering logic. Reference the logic being consolidated: `notifyScenePhasePaused:561`, `backgroundSuspend:763`, `backgroundResume:785`, and the steps `setGate:1641`, `drainSubmittedFrame:1649`, `armWatchdogs:1713`, `disarmWatchdogsAsync:1695`, session `startRunning`/`stopRunning` (on `sessionQueue`, ADR-07), `finalizeActiveRecording(reason: .user)`, `publishState:1660`.

**Target table (spec *What moves inside the package*) — the routine's contract:**

| Phase | gate | session | watchdogs |
|---|---|---|---|
| `.active` | open | start if not (guarded in Task 6) | armed (guarded in Task 6) |
| `.inactive` | closed | start if not (guarded in Task 6) | disarmed |
| `.background` | closed | stopped + recording finalized | disarmed |

**Ordering invariants (spec):** gate close is a synchronous atomic sequenced **before any suspending step**; the into-`.background` path follows the field-guide §5 sequence: **disarm + cancel retry → finalize active recording → drain → `stopRunning`**. Recording finalize delegates entirely to `Recording.stop()` (`Recording.swift:165`, its own `beginBackgroundTask("recording-drain"):195` + `recordingFinishTimeoutSeconds`) — the routine adds no background task or timeout of its own.

**Contract:**
```swift
extension CameraEngine {
    public func setLifecyclePhase(_ phase: AppLifecyclePhase) async   // writes currentPhase unconditionally, never throws; reconciles only when open
}
```
Also: `open()` (`:180`) and `close()` (`:391`) — `open()` runs the same routine against `currentPhase` after hardware creation; `close()` leaves `currentPhase` intact. (The OS-recovery-exit third site is Task 7.)

> Sub-tasks 4a–4d each add one test and the minimal routine code to pass it. 4a builds the skeleton (`.active`/`.inactive` cheap-pause path); later sub-tasks extend it. Assert against the **target table** (gate state, session running, watchdog armed, recording finalized) **and** `stateStream()` output. Find the existing gate/session/watchdog probes in the Stage09/Stage13 suites and reuse them.

### Task 4a: `.active → .inactive → .active` cheap pause
- [ ] **Step 1: Failing test** — suite `LifecycleReconciliationTests`, test `cheapPauseDoesNotStopSession`. Drive the sequence; assert the session **never** stopped (no `stopRunning`), gate closed at `.inactive` then open at `.active`, watchdogs disarmed at `.inactive` then armed at `.active`. (~4 ms gate-flip path, spec *Rejected* S2 rationale.)
- [ ] **Step 2: Run — fail** (`setLifecyclePhase` undefined).
- [ ] **Step 3: Implement** `setLifecyclePhase` + the `reconcile` skeleton + the `.active`/`.inactive` branches (gate, session-start-if-not, watchdog arm/disarm), reusing primitives. Gate-close synchronous-first.
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `feat(camerakit): setLifecyclePhase + reconciliation (active/inactive)`.

### Task 4b: `.active → .inactive → .background` suspend
- [ ] **Step 1: Failing test** — `backgroundSuspendFinalizesAndStops`. With an active recording, drive to `.background`; assert ordered sequence ran (watchdogs disarmed, recording finalized, session stopped, gate closed). Assert finalize happened **before** `stopRunning`.
- [ ] **Step 2: Run — fail.**
- [ ] **Step 3: Implement** the `.background` branch as the field-guide §5 ordered sequence, delegating finalize to `Recording.stop()`.
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `feat(camerakit): reconciliation .background ordered suspend`.

### Task 4c: `.background → .inactive → .active` resume
- [ ] **Step 1: Failing test** — `resumeRestartsAtInactiveGateOpensAtActive`. Open with `initialPhase: .background`; drive `.background → .inactive → .active`; assert session restarts at `.inactive` with gate **still closed**, gate opens at `.active`. This is the case the old `cameFromBackground` flag handled — no flag now.
- [ ] **Step 2: Run — fail or pass.** (May already pass from 4a/4b — that is the point of the declarative model. If it passes, keep the test as a guard and note it.)
- [ ] **Step 3: Implement** only if needed.
- [ ] **Step 4: Run — pass.**
- [ ] **Step 5: Commit** — `test(camerakit): resume ordering reconciles without sticky flag`.

### Task 4d: Flutter ordering `.background → .background → .inactive → .active`
- [ ] **Step 1: Failing test** — `duplicateBackgroundIsNoOpAndConverges`. Assert the duplicate `.background` is a no-op (idempotent) and the sequence converges to the same terminal state as 4c.
- [ ] **Step 2–4:** run; implement idempotency if a repeat misbehaves; run.
- [ ] **Step 5: Commit** — `test(camerakit): Flutter resume ordering converges`.

---

## Task 5: latest-intent-wins contract

Make a superseded, in-flight reconciliation abort rather than apply stale work (spec *Concurrency*, governing contract). Without it, a `.background` reconcile straggled by a completing `.active` leaves gate-open + watchdogs-armed + session-stopped → permanent black preview + spurious recovery (F1).

**Files:** `CameraEngine.swift` (the routine from Task 4) + a test-only interleave seam.

**Contract / direction:**
- Pick **one** mechanism (spec leaves it to the implementer): (a) a **monotonic generation counter** captured on entry, re-checked before each suspending step, abort if bumped; or (b) a **single-flight reconciler** that re-reads the latest target after every `await` and abandons a stale target. Recommend (a) for simplicity. Whichever is chosen must also cover OS-event-vs-event (Task 8) since both run on the actor.
- Add a clearly-named test-only suspension hook at the post-gate / pre-`stopRunning` checkpoint of the `.background` path (style of `_postSessionEventForTest`), so a test can deterministically admit a second call mid-flight. Alternatively reuse a slow fake recording writer if the suites already have one (grep the Stage10 / recording suites).

- [ ] **Step 1: Write the failing test** — suite `LifecycleLatestIntentWinsTests`, test `backgroundSupersededByActiveEndsActive` (the F1 regression guard). Drive `.background` then `.active` so `.active` is admitted while the `.background` reconcile is suspended at the seam. Assert terminal state = **`.active`** (session running, gate open, watchdogs armed), **not** session-stopped, and **no** `RecoveryCoordinator` entry / off-map fault logged.
- [ ] **Step 2: Run — verify it fails** (the straggler applies stale `stopRunning`). Expected: FAIL with session-stopped terminal state.
- [ ] **Step 3: Implement** the chosen mechanism so the superseded reconcile aborts at its next checkpoint.
- [ ] **Step 4: Run — verify it passes.**
- [ ] **Step 5: Run the full Task 1 + Task 4 sets** — no regressions.
- [ ] **Step 6: Commit** — `fix(camerakit): latest-intent-wins reconciliation (F1)`.

---

## Task 6: Two predicates + the phase→OS guard (F2) + label deferral

**Files:** `CameraEngine.swift` (reconcile + the label-publish path that `notifyScenePhasePaused:561` owns today).

**Contracts (both over `SessionState` — single source of truth, no parallel mirror; spec *The OS-owned guard*):**
```
osOwnsDevice            = current ∈ {.interrupted, .recovering, .error}
shouldDeferCommandLabel = osOwnsDevice || (current == .opening && target == .paused)
```
- Apply `osOwnsDevice` to **both** the watchdog-arm guard **and** the `.active`/`.inactive` session-start in `reconcile` (don't fight an OS interruption / in-flight recovery for the device).
- Apply `shouldDeferCommandLabel` to the label-deferral, replacing the inline `classify(...) == .offMap` check (`:561`/`:564` region). It must preserve the `.opening → .paused` launch-race that `classify` covers today (`commandMap[.opening] = [.streaming, .closed, .error]` — no `.paused`).

- [ ] **Step 1: Write the failing tests** — suite `LifecycleOSOwnedGuardTests`:
  - `activeReconcileDefersWhileOSOwnsDevice`: drive into an OS-owned state (`_postSessionEventForTest(.otherInterruption(...))` → `.interrupted`, or `videoDeviceInUseByAnotherClient` → `.error`), then `setLifecyclePhase(.active)`; assert watchdogs stay **disarmed** **and** no `startRunning` — no spurious watchdog fire, no `RecoveryCoordinator` entry, no fatal escalation.
  - `commandLabelDefersUnderOSOwnership`: `setLifecyclePhase(.active)` while `.interrupted`/`.recovering` must not overwrite the OS label (terminal label stays OS truth) — parity with `notifyScenePhasePaused` today.
  - `deferralParityOpeningToPaused`: `.opening → .paused` defers; `.opening → .streaming` publishes.
- [ ] **Step 2: Run — verify they fail.**
- [ ] **Step 3: Implement** the two predicates and apply them at the three sites above.
- [ ] **Step 4: Run — verify they pass**, plus the existing `Stage13Phase2ScenePhaseMirrorGuardTests` and `SessionStateMachineTests` (deferral/classifier parity) stay green.
- [ ] **Step 5: Commit** — `fix(camerakit): osOwnsDevice + shouldDeferCommandLabel guards (F2)`.

---

## Task 7: Third actuation site — OS-recovery exit reconciles against `currentPhase`

Make the OS event path stop unconditionally re-arming / restarting. When it resolves an OS-owned state, run the **same** `reconcile` against `currentPhase` (spec *The OS-owned guard*, OS→phase direction). Closes the asymmetry where `interruptionEnded` while backgrounded turns the camera on (F4-class — the gate gates GPU submission, not `AVCaptureSession` running state).

**Files:** `CameraEngine.swift:1849-1854` — the `.otherInterruptionEnded` branch of `onSessionEvent` (currently `publishState(.streaming, kind: .event)` + `armWatchdogs()`).

- [ ] **Step 1: Write the failing tests** — suite `LifecycleThirdActuationSiteTests`:
  - `interruptionEndedWhileBackgroundStaysStopped`: `.active` + recording → inject `.otherInterruption` (`.interrupted`) → `setLifecyclePhase(.background)` → inject `.otherInterruptionEnded`. Assert session **stays stopped**, watchdogs **disarmed**, no camera LED (no `startRunning`), no `RecoveryCoordinator` restart.
  - `interruptionEndedWhileInactiveRestartsGateClosed`: same but standing phase `.inactive` → session **restarts**, gate **closed**, watchdogs disarmed.
- [ ] **Step 2: Run — observe what fails (fail or partial-pass).** The preserved `:369` test proves the gate-guarded re-arm is *already* suppressed when backgrounded, so the "watchdogs disarmed" assertion may already hold; the likely current divergences are the **label republish** (`publishState(.streaming)` on `interruptionEnded` regardless of phase) and the **`.inactive` row** (no reconcile to gate-closed/session-running). Note exactly which assertions fail — that is what the fix must address.
- [ ] **Step 3: Implement** — route the `.otherInterruptionEnded` resolve through `reconcile` (reading `currentPhase`) instead of the inline `publishState(.streaming)` + `armWatchdogs()`. This makes `reconcile`'s caller list three (update the count in any in-code comment that enumerates callers).
- [ ] **Step 4: Run — verify the new tests pass AND the preserved ones stay green:** `HitlLifecycleTests.interruptionEndedRearmsWatchdog` (`:338`, the `.active` case must still re-arm), `HitlLifecycleTests.interruptionEndedWhileBackgroundedDoesNotRearm` (`:369`), `Stage13Phase2InterruptedStateTests` (`:107`). If any preserved test now fails, the reconcile path is not reproducing prior `.active` behavior — fix forward, do not edit the preserved tests.
- [ ] **Step 5: Commit** — `fix(camerakit): OS-recovery exit reconciles against currentPhase`.

---

## Task 8: OS-event-vs-event interleave (F5)

Two interruption handlers (`begin`/`ended`), each dispatched as its own `Task { await onSessionEvent(...) }` (`:260-261`), can interleave on the actor. Ensure a stale `.ended`/recovery handler doesn't re-arm / republish over a newer `.begin` (spec *Concurrency*, case 3). The Task 5 mechanism should already cover this since both run on the actor — this task confirms and closes any gap.

**Files:** `CameraEngine.swift` (`onSessionEvent:1816` handlers + the Task 5 mechanism).

- [ ] **Step 1: Write the failing test** — suite `LifecycleThirdActuationSiteTests` (or a sibling `LifecycleEventInterleaveTests`), test `staleEndedDoesNotOverrideNewerBegin`. Inject `.otherInterruption` then `.otherInterruptionEnded` so the `.ended` handler is admitted while the `.begin` handler is suspended; assert no stale re-arm / label republish; terminal state matches the **latest** event.
- [ ] **Step 2: Run — fail or pass.** If Task 5 already covers it, the test passes — keep it as a guard and note it; otherwise implement.
- [ ] **Step 3: Implement** event-handler idempotency / latest-wins discipline as needed.
- [ ] **Step 4: Run — pass**, full regression set green.
- [ ] **Step 5: Commit** — `test(camerakit): OS event-vs-event interleave guard (F5)`.

---

## Task 9: Host migration — collapse `handleScenePhase`

**Files:** `eva-swift-stitch/UI/ViewModel.swift` — `handleScenePhase:321-354`, `cameFromBackground:84`. (`CameraView.swift:99` keeps forwarding `scenePhase` to the view model; `.task(id: scenePhase)` is now redundant with latest-intent-wins but harmless — leave it, or optionally simplify in this task.)

- [ ] **Step 1: Replace the body** of `handleScenePhase` with a single `await engine.setLifecyclePhase(map(phase))`.
- [ ] **Step 2: Add the host mapping** — a private `map(_ p: ScenePhase) -> AppLifecyclePhase` (identity over the three cases; `@unknown default → .inactive`). This is the only place SwiftUI types touch the lifecycle path; the package imports no SwiftUI (spec *Host mapping*).
- [ ] **Step 3: Remove `cameFromBackground`** and any now-dead helper state it fed.
- [ ] **Step 4: Build + smoke the lifecycle suites** (conventions). Expected: `BUILD SUCCEEDED`; regression set green. Device HITL smoke (foreground/background/lock-unlock, recording across background) is deferred evidence — note it for the device pass (Task 12).
- [ ] **Step 5: Commit** — `refactor(app): drive lifecycle via setLifecyclePhase`.

---

## Task 10: Demote the now-internal drivers

With the host on `setLifecyclePhase`, the old drivers have no external caller (Migration verification: grep returns hits only in `ViewModel.swift`, now rewritten). Demote — keep them reachable to `@testable import` tests.

**Files:** `CameraEngine.swift` — `setGate:1641`, `drainSubmittedFrame:1649`, `notifyScenePhasePaused:561`, `backgroundSuspend:763`, `backgroundResume:785`.

- [ ] **Step 1: Verify no external callers remain** — `grep -rn 'setGate\|drainSubmittedFrame\|notifyScenePhasePaused\|backgroundSuspend\|backgroundResume' eva-swift-stitch/ eva-swift-stitchTests/ eva-swift-stitchUITests/`. Expect zero in app/UI targets. (Test targets under `CameraKitTests/` may call them — that's fine, `@testable import`.)
- [ ] **Step 2: Change `public` → `internal`** on the five methods. If `notifyScenePhasePaused`/`backgroundSuspend`/`backgroundResume` are now fully subsumed by `reconcile` and called by **no** test, prefer removing them; if any test calls them, keep as `internal`. Decide per grep, don't guess.
- [ ] **Step 3: Build + full test run.** Expected: `BUILD SUCCEEDED`, all suites green (tests reach internals via `@testable`).
- [ ] **Step 4: Commit** — `refactor(camerakit): demote lifecycle drivers to internal`.

---

## Task 11: Documentation — README + docstrings + CONTRACTS

**Files:**
- Create: `CameraKit/README.md`.
- Modify (if not already carrying the convention): docstrings on `setLifecyclePhase` / `AppLifecyclePhase`.
- Regenerate: `CameraKit/CONTRACTS.md`.

- [ ] **Step 1: Create `CameraKit/README.md`** with a "Lifecycle" section — use the verbatim prose block under spec *Documentation deliverables* (SwiftUI 1:1 forward; Flutter native-layer mapping `resumed→.active`, `inactive→.inactive`, `hidden`/`paused→.background`, `detached→`skip; "never throws, latest call wins"; construct with `initialPhase`, no default). Keep it in sync with the docstrings.
- [ ] **Step 2: Confirm the docstrings** on `setLifecyclePhase(_:)` and `AppLifecyclePhase` carry the same calling convention (the source text is in spec *Public API*). Mind the swift-format `--strict` rule: blank `///` line after the first sentence of any multi-sentence doc comment.
- [ ] **Step 3: Regenerate CONTRACTS** — `bash scripts/regen-contracts.sh` (also auto-runs on pre-commit). Confirm `setLifecyclePhase` + `AppLifecyclePhase` appear and the demoted methods no longer show as `public`.
- [ ] **Step 4: Commit** — `docs(camerakit): add README Lifecycle section; regen CONTRACTS`.

---

## Task 12: Final verification + follow-up filing

- [ ] **Step 1: Clean full build + full test run** on physical iPad (preferred) → Mac "Designed for iPad". Expected: `BUILD SUCCEEDED`, entire suite green. If SourceKit phantoms appear but the build log is green, discard them (CLAUDE.md §6.1).
- [ ] **Step 2: Device HITL smoke** (physical iPad — required for camera-indicator / off-main `startRunning`): foreground→background→foreground; lock→unlock; recording active across a background; a foreground OS interruption (e.g. incoming call / Control Center) then resume. Confirm no black preview, no spurious recovery, no corrupt `.mp4`, and the camera LED is **off** whenever the app is backgrounded. Save evidence under `measurements/` if the repo convention calls for it.
- [ ] **Step 3: File the out-of-scope follow-ups** (spec *Follow-ups*) wherever the repo tracks them (`CameraKit/state.md` "Open questions" or DECISIONS log): `StopReason.pause` now production-dead; `sensitiveContentMitigationActivated` unenumerated; permission/route revocation mid-session unmodeled.
- [ ] **Step 4: Note the cam2fd downstream change** (documented, not edited here): plugin native layer maps UIScene → `AppLifecyclePhase` and calls `setLifecyclePhase`; Dart stops forwarding lifecycle.
- [ ] **Step 5: Final commit** if any verification artifacts were produced — `chore(camerakit): lifecycle ownership verification + follow-ups`.

---

## Self-review (completed during plan authoring)

**Spec coverage:** Public API enum+method → T2,T4. Phase-as-property / required initialPhase → T3. Reconciliation target table + ordered background sequence + recording-finalize delegation → T4. latest-intent-wins (F1) → T5. Two predicates + phase→OS guard (F2) + label deferral + parity → T6. Third actuation site / OS→phase → T7. Event-vs-event (F5) → T8. Host migration (handleScenePhase, cameFromBackground, initialPhase) → T3 (construction) + T9. Demotions → T10. Docs (README + docstrings) + CONTRACTS regen → T11. Removed pause/resume → already committed (`31ca8af`), baseline-verified in T1. Testing section cases → mapped across T4–T8 + T12 (device HITL). Follow-ups → T12. **No uncovered spec requirement.**

**Type/name consistency:** `AppLifecyclePhase` (`.active`/`.inactive`/`.background`), `setLifecyclePhase(_:)`, `currentPhase`, `initialPhase`, `reconcile`, `osOwnsDevice`, `shouldDeferCommandLabel` — used consistently across tasks and matching the spec verbatim.
