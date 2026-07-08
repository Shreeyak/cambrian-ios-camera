## ADDED Requirements

### Requirement: Engine-level recovery budget

CameraKit SHALL track recovery reopens that deliver no frame on the engine itself,
not on the per-`open()` recovery coordinator, so the budget persists across the
reopens recovery drives. The counter SHALL reset to zero when a frame is delivered
and on a user-initiated `open()`. A recovery reopen SHALL increment it. The
recovery/restart teardown SHALL NOT reset it.

#### Scenario: Budget accumulates across reopens

- **WHEN** successive recovery reopens each complete but deliver no frame
- **THEN** the engine budget increases on each reopen (it is not reset by the
  reopen), so a persistent fault reaches the escalation thresholds

#### Scenario: A delivered frame resets the budget

- **WHEN** a recovery reopen delivers a frame
- **THEN** the engine budget resets to zero, so a later isolated fault starts with
  a fresh budget

### Requirement: Two-tier bounded escalation

On a recoverable stall CameraKit SHALL first attempt quick reopens up to
`Constants.recoveryQuickReopens`. On quick-budget exhaustion it SHALL escalate to a
full restart — a heavier teardown, a settle delay of
`Constants.fullRestartSettleSeconds`, and a fresh open — up to
`Constants.maxFullRestarts`. Escalation SHALL be linear: the quick budget SHALL NOT
be reset after a full restart, so a persistent fault progresses
quick → full → fatal in `recoveryQuickReopens + maxFullRestarts` total reopens. On
exhaustion of full restarts it SHALL emit a permanent fatal and stop reopening.
Recovery SHALL NOT loop unbounded.

#### Scenario: Persistent fault escalates quick then full then fatal, bounded

- **WHEN** a fault persists and no reopen ever delivers a frame
- **THEN** CameraKit performs exactly `recoveryQuickReopens` quick reopens, then
  exactly `maxFullRestarts` full restarts, then emits exactly one permanent fatal
  and performs no further reopen

#### Scenario: Recovery converges when a reopen delivers a frame

- **WHEN** a reopen during escalation delivers a frame
- **THEN** escalation ends, the budgets reset, and no fatal is emitted

### Requirement: Recovery observability without terminating consumers

Each escalation step SHALL publish a `.recovering` state and a NON-fatal
`CameraError`. Only the terminal give-up SHALL publish a fatal error. A non-fatal
recovery/escalation error SHALL NOT terminate consumer lane streams.

#### Scenario: Escalation emits a non-fatal signal

- **WHEN** a quick reopen or a full restart is attempted
- **THEN** a `.recovering` state and a non-fatal error are published, and no
  consumer lane stream is finished or thrown

#### Scenario: Terminal give-up emits a fatal signal

- **WHEN** full restarts are exhausted with no delivered frame
- **THEN** a fatal error is published exactly once and reopening stops
