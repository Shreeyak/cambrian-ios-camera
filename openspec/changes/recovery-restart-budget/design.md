## Context

Fault recovery today: a watchdog stall calls `RecoveryCoordinator.enterRecovery`,
which schedules `performTeardownAndReopen` (`{ close(); open() }`) after a backoff.
`open()` creates a fresh `RecoveryCoordinator` (`CameraEngine.swift:445`), so the
coordinator that scheduled the reopen is replaced by the reopen it scheduled — the
`attempt` counter can never accumulate across reopens, and `maxRetriesExceeded` is
unreachable. On a persistent no-frame fault this loops forever.

Consumer delivery: downstream apps subscribe via `ConsumerRegistry.subscribe(...)`
(`PixelSink.swift`) and receive an `AsyncThrowingStream<Frame>`. The registry is
engine-owned — `let consumers = ConsumerRegistry()` created once at init and passed
into every rebuilt `MetalPipeline`. So the registry itself survives reopens; the
only things that terminate a subscriber stream are `consumers.release()` (clean
finish, from `close()`) and `consumers.failAllLanes(error)` (throwing finish, from
`publishError` when `isFatal`). Because recovery reopens call `close()`, they
currently `release()` — terminating consumers on a transient fault.

The user-facing `open()` no-frame case is already handled by the first-frame check
(`EngineError.sessionLifecycleTimeout`). This change covers the *internal*
recovery/restart path and its transparency to consumers.

## Goals / Non-Goals

**Goals:**
- Bound recovery so a persistent fault cannot loop forever; escalate quick reopens
  → full restarts → a single permanent fatal.
- Keep restarts invisible to frame consumers: surviving subscribers see a frame gap
  then resume; lanes terminate only on user `close()` or the terminal fatal.
- Emit observability (`.recovering` + non-fatal error) at each escalation without
  terminating consumer streams.

**Non-Goals:**
- Changing the user-driven `open()`/`close()`/`subscribe()` public signatures.
- Re-architecting the watchdog or the backoff schedule.
- Replaying missed frames — streams are non-replaying; a gap is expected.
- Handling the user-driven open no-frame case (already the first-frame check).

## Decisions

**D1 — Budget lives on the engine, not the coordinator.** Add
`recoveryReopensWithoutFrame: Int` on `CameraEngine`. Reset to 0 in `onFrameTick`
on any delivered frame (real recovery proof). Increment inside
`performTeardownAndReopen` before each reopen. This persists across the
coordinator's per-`open()` recreation, so the budget actually accumulates. The
`RecoveryCoordinator` keeps owning backoff/scheduling for quick reopens.

**D2 — Two-tier escalation in `performTeardownAndReopen`.** The reopen closure
decides the tier from the engine counters:
- `recoveryReopensWithoutFrame <= recoveryMaxRetries` → **quick reopen**:
  `teardown(preserveConsumers: true)` + `open(fromRecovery:)`.
- quick budget exhausted, `fullRestartCount < maxFullRestarts` → **full restart**:
  increment `fullRestartCount`, reset the quick counter, sleep
  `fullRestartSettleSeconds`, then `teardown(preserveConsumers: true)` + `open`.
- full restarts exhausted → **permanent fatal**: `publishError(isFatal: true)` →
  `failAllLanes`, then `close()` (full release). No further reopen.

**D3 — Consumer-preserving teardown.** Introduce an internal
`teardown(preserveConsumers: Bool)` (or `close(releaseConsumers:)`). When
preserving, skip `consumers.release()` and the `frameResultStream` finish; keep the
session/pipeline/watchdog teardown. `close()` (user + terminal fatal) uses the full
release. The new `MetalPipeline` built by `open()` already receives the same
engine-owned `consumers`, so surviving subscribers resume automatically.

**D4 — Only the terminal fatal is `isFatal`.** Escalation steps publish
`.recovering` + a NON-fatal `CameraError` (a new/existing code, e.g. `.recovering`
or `captureFailure` with `isFatal: false`). `failAllLanes` is reachable only from
the terminal `publishError(isFatal: true)`. This is the single point where
consumer streams throw — justified because the camera cannot recover.

**D5 — Reset semantics.** `recoveryReopensWithoutFrame` and `fullRestartCount`
reset to 0 on a delivered frame (`onFrameTick`) and on a user-initiated `open()`
(fresh session). They are NOT reset by the recovery/restart teardown (that would
defeat the budget). A user `close()` resets them (fresh start next open).

## Risks / Trade-offs

- **A preserved-consumer teardown that forgets a resource → leak or stale
  delivery.** Mitigation: `teardown(preserveConsumers:)` differs from `close()`
  only in skipping `consumers.release()` + the `frameResultStream` finish;
  everything else (session stop, pipeline nil-out, watchdog disarm) is identical.
  A device test asserts a subscribed lane keeps yielding valid frames post-restart.
- **Escalation counters interacting with the coordinator's own `attempt`.** The
  coordinator still increments its own `attempt` per `enterRecovery`, but that is
  now advisory; the engine counters own the escalation decision. Keep the
  coordinator's `maxRetriesExceeded` path as a no-op or align it with the engine
  budget to avoid double-fatal.
- **Full restart may not clear a genuine hardware fault** (a settle delay did not
  help the structural `reconciledSessionRunning` bug, now fixed). Accepted: the
  bounded escalation guarantees termination (fatal) rather than a fix; the value is
  no infinite loop + consumer transparency, not a cure for dead hardware.
- **Observability floods.** Each escalation emits an error; bounded by
  `recoveryMaxRetries` + `maxFullRestarts`, so a finite, small number of events.
