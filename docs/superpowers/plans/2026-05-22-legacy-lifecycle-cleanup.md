# Legacy lifecycle cleanup — implementation plan

**Goal:** Remove the three legacy lifecycle entry points the `setLifecyclePhase`/
`reconcile` rework superseded, retire/repoint their tests **without losing any
coverage**, and fix the doc-comments that reference them.

**Status:** investigated + advisor-reviewed 2026-05-22; not yet executed.

---

## Context — what's orphaned (and what is NOT)

Production now drives lifecycle through **one** path: the host calls
`setLifecyclePhase(_:)`, which runs `reconcile()`. `reconcile`'s `.background`/
`.active` cases do the suspend/resume work inline, and the label/deferral logic
lives in `publishCommandLabel` / `shouldDeferCommandLabel`. That left three
methods with **no production callers**:

| Method (`CameraEngine+Lifecycle.swift`) | Code callers | Disposition |
|---|---|---|
| `backgroundSuspend()` (`:35`) | none (only doc-comments) | remove |
| `backgroundResume()` (`:57`) | `Stage02Tests` idempotence test only | remove + delete test |
| `notifyScenePhasePaused(_:)` (`:102`) | `LifecycleTests` only | remove + retire/repoint tests |

**NOT orphaned — do not touch:** the resume-latency instrumentation
(`framesToLog` in `CaptureDelegate.swift:42`, armed at `CameraEngine+Lifecycle.swift:47,182`
and `CameraEngine.swift:792,1869`; `logNextCommit` in `MetalPipeline.swift:237`,
armed at `CameraEngine+Lifecycle.swift:174`). An earlier note called a
`logNextFrame` hook orphaned — that symbol no longer exists; it was renamed to the
live `framesToLog`. There is nothing to clean up there.

**Coverage is already preserved by `setLifecyclePhase`-driven tests** — the key
finding that makes this safe:
- `LifecycleTests.commandLabelDefersUnderOSOwnership` (`:572`, doc says "parity
  with notifyScenePhasePaused") proves the Bug-2 OS-deferral guard through
  `setLifecyclePhase` for `.interrupted` and `.error`.
- `deferralParityOpeningToPaused` (`:606`) covers the `.opening → .paused` rider.
- `activeReconcileDefersWhileOSOwnsDevice` (`:530`) covers F2.
- OS→phase exit tests (`:634`, `:667`) cover interruption-ended reconciliation.

So the `notifyScenePhasePaused` tests are **redundant**, with exactly two gaps to
close (Task 2).

---

## Task 1 — Remove the three production methods

**File:** `CameraKit/Sources/CameraKit/CameraEngine+Lifecycle.swift`

- [ ] Delete `// MARK: - Legacy background entries` (`:22`) and the three methods
  with their doc-comments: `backgroundSuspend` (`:24`–`:51`), `backgroundResume`
  (`:53`–`:71`), `notifyScenePhasePaused` (`:73`–`:104`). I.e. remove everything
  from line 22 through line 104, leaving `extension CameraEngine {` (`:20`)
  followed directly by `// MARK: - App lifecycle (reconciliation)` (`:106`).
- [ ] Fix the file header (`:7`–`:8`): drop "plus the legacy
  `backgroundSuspend`/`backgroundResume`/`notifyScenePhasePaused` entries."
- [ ] Fix header ADR ref (`:17`): ADR-30 is still real (recording finalize uses
  it) — repoint, don't delete: "ADR-30 (async-with-timeout — see `Recording.swift`
  finalize)" instead of "(suspend/resume async-with-timeout)".
- [ ] In `reconcile`/`publishCommandLabel` doc-comments (`:147`, `:158`, `:286` in
  the current file — re-grep `notifyScenePhasePaused` after the deletion shifts
  lines), reword "folded in from `notifyScenePhasePaused`" → "the OS-authoritative
  label publish (formerly a standalone scenePhase mirror)". Historical, but should
  not name a deleted symbol.

**Access levels:** leave as-is. `reconcile` & friends still use the widened
members. `watchdogs` (`CameraEngine.swift:81`) *could* revert to `private` (only
`backgroundSuspend` referenced it directly from this file) — note as an optional
follow-up; do not chase here.

---

## Task 2 — Tests: delete redundant, extend one, rewrite one

**File:** `CameraKit/Tests/CameraKitTests/LifecycleTests.swift`

- [ ] **Delete** the redundant `notifyScenePhasePaused` tests:
  `scenePhaseResumeIgnoredWhileInterrupted` (`:149`–`:163`),
  `scenePhaseMirrorAllowsLegitEdges` (`:185`–`:199`), `makeInterruptedEngine`
  helper (`:240`–`:248`, callers confirmed only at `:252/:261/:268`),
  `scenePhaseActiveFromInterruptedIsSkipped` (`:250`–`:257`),
  `scenePhaseInactiveFromInterruptedIsSkipped` (`:259`–`:264`),
  `interruptionEndStillRestoresStreaming` (`:266`–`:272`),
  `scenePhaseMirrorStillWorksFromStreaming` (`:274`–`:282`), and the now-orphaned
  "Relocated: scenePhase × interruption off-map guard" MARK + comment block
  (`:229`–`:238`).
  - **KEEP** `otherInterruptionTogglesInterruptedState` (`:203`–`:227`) — it uses
    `_postSessionEventForTest`, not the trio.
- [ ] **Extend** `commandLabelDefersUnderOSOwnership` (`:572`) with a `.recovering`
  block — the only unique coverage from the deleted
  `scenePhaseResumeIgnoredWhileRecovering` (`:167`). **Copy that test's setup
  verbatim** (it is not a one-line seam): `clock: ManualClock()`,
  `_markOpenForTest()`, `_armWatchdogsForTest()`, then
  `_postSessionEventForTest(.runtimeError("boom"))` → assert `.recovering`, then
  `setLifecyclePhase(.active)` → assert still `.recovering`, then `close()`.
- [ ] **Delete** the standalone `scenePhaseResumeIgnoredWhileRecovering`
  (`:167`–`:183`) once its coverage is folded into `:572`.
- [ ] **Rewrite** `deferralParityOpeningToPaused` (`:606`–`:621`) to use
  `setLifecyclePhase` instead of `notifyScenePhasePaused`:
  `notifyScenePhasePaused(true)` → `setLifecyclePhase(.inactive)` (target `.paused`,
  must defer → stays `.opening`); `notifyScenePhasePaused(false)` →
  `setLifecyclePhase(.active)` (target `.streaming`, publishes → `.streaming`). Add
  a one-line comment: `.opening` is set first (`_setStateForTest(.opening)`) so
  `isOpen` is true and `reconcile` runs — do **not** switch to `_markOpenForTest()`
  (that lands in `.streaming`, different deferral semantics).

**File:** `CameraKit/Tests/CameraKitTests/Stage02Tests.swift`

- [ ] **Delete** `backgroundResumeIsNoopUntilInterruptionEnded` (`:106`–`:122`,
  including its MARK comment). Gate-flip behavior is covered by the cheap-pause
  test (`LifecycleTests.swift:322`). `setGate`/`isGateOpen` remain valid internal
  seams; if no other Stage02 test uses them after this, note as a follow-up — do
  not chase.

---

## Task 3 — Fix doc-comments elsewhere

Re-grep each first (line numbers shift after Task 1):
`grep -rn 'backgroundSuspend\|backgroundResume\|notifyScenePhasePaused' --include=*.swift CameraKit/Sources`

- [ ] `CameraEngine.swift:16` (ADR-30 file header): repoint to `Recording.swift`'s
  finalize path; don't delete the ADR-30 line.
- [ ] `CameraEngine.swift:806` (the cluster breadcrumb): drop "plus the legacy …
  entries"; it should describe only the live reconciliation cluster.
- [ ] `CameraEngine.swift:1592`: read the surrounding paragraph — it lists the
  "three triggers" for `finalizeActiveRecording` (`close()` / `backgroundSuspend` /
  recording-stop). With `backgroundSuspend` gone the third trigger is
  `reconcile()`'s `.background` case — update factually.
- [ ] `RecoveryCoordinator.swift:68`: "called from close() and backgroundSuspend()"
  → "called from close() and reconcile()'s .background path".
- [ ] `SessionStateMachine.swift:109`: "`notifyScenePhasePaused(true)` can fire at
  app launch before…" → "a pre-open `.inactive`/`.background` phase can fire
  before…".

---

## Task 4 — Verify

- [ ] Build: `scripts/build-summary.sh` (physical iPad). Expect `BUILD: success`,
  0 errors / 0 warnings.
- [ ] swift-format gate (the only pre-commit style gate):
  `swift-format lint --strict CameraKit/Sources/CameraKit/CameraEngine+Lifecycle.swift`
  (+ any other edited Sources file).
- [ ] Tests: `scripts/test-summary.sh` — **full suite, not filtered** (this path
  feeds the state-machine classifier reachable from anywhere). Expect 0 failures.
  Count = 208 baseline − (deleted tests) + 0 (extensions reuse existing `@Test`s);
  net ≈ 208 − 8 deleted = ~200. Record the exact number.
- [ ] `scripts/regen-contracts.sh` then `git diff CameraKit/CONTRACTS.md` —
  confirm **zero public-section changes** (`setLifecyclePhase` stays `public`; the
  removed trio were `internal`, so only internal-section deletions show).

---

## Notes for the commit / report

- **Removed behavior (call it out):** the deleted `scenePhaseMirrorAllowsLegitEdges`
  test asserted a pre-open `closed → paused` *publish* — behavior the rework
  intentionally dropped (pre-open `currentPhase` is *recorded*, not published;
  `open()` applies it — field guide §3a). This is not a regression; mention it so a
  diff reviewer doesn't read "test removed" as lost coverage.
- **Optional follow-ups (do not chase here):** revert `watchdogs` to `private`;
  audit `setGate`/`isGateOpen` internal seams if their only callers were removed
  tests.
- No git operations without explicit approval; the pre-commit hook regenerates
  `CONTRACTS.md` and runs `swift-format --strict` (SwiftLint is not a gate).
