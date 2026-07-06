## Why

CameraKit's fault recovery has two defects that can produce a permanent, opaque
failure and disrupt downstream consumers:

1. **Recovery can loop forever.** The `RecoveryCoordinator` is recreated on every
   `open()` (`CameraEngine.swift:445`), and the recovery reopen path is
   `performTeardownAndReopen → close() → open()`. Because each reopen destroys and
   recreates the coordinator, its `attempt` budget resets every cycle, the
   `maxRetriesExceeded` fatal is never reached, and a persistent no-frame fault
   loops indefinitely behind a black screen instead of surfacing an error.

2. **Every recovery reopen terminates downstream frame streams.** `close()` calls
   `consumers.release()` (`ConsumerRegistry`, `PixelSink.swift`), which *finishes*
   all per-lane `AsyncThrowingStream<Frame>` subscriptions. Since recovery reopens
   go through `close()`, apps consuming frames (EvaScan, the Flutter texture
   preview) have their streams terminated on a transient fault they should never
   have noticed.

Now that engine reuse works (the `reconciledSessionRunning` reopen fix), recovery
should be the last line of defense: bounded, escalating, and invisible to
consumers until the camera genuinely cannot come back.

## What Changes

- **Engine-level recovery budget.** Track reopens-without-a-delivered-frame on the
  engine (persists across reopens, unlike the recreated coordinator); reset on a
  delivered frame in `onFrameTick`; increment per recovery reopen.
- **Two-tier escalation.** (a) *Quick reopens* with the existing backoff up to
  `Constants.recoveryMaxRetries`; (b) on quick-budget exhaustion, escalate to a
  *full restart* — a heavier teardown + a longer settle delay
  (`Constants.fullRestartSettleSeconds`) + a fresh open, resetting the quick budget
  — up to `Constants.maxFullRestarts`; (c) only after full restarts are exhausted,
  emit a **permanent fatal**. Each escalation publishes `.recovering` plus a
  **non-fatal** error for observability.
- **Consumer-transparent restarts.** Recovery/restart teardown PRESERVES consumer
  subscriptions — it skips `consumers.release()` and the `frameResultStream`
  finish. The engine-owned `ConsumerRegistry` survives reopens and is re-wired to
  each rebuilt `MetalPipeline`, so surviving subscribers resume from the new
  pipeline after a frame gap. Consumer lanes are terminated **only** by a
  user-initiated `close()` or the terminal fatal (`failAllLanes`).
- **Docs.** Document in the project README and in docstrings that a restart is
  transparent to consumers iff it skips `release()`/`failAllLanes()` — surviving
  subscribers see a frame gap then resume; lanes are terminated only on user
  `close()` or the terminal fatal.

## Capabilities

### New Capabilities
- `camera-recovery`: bounded, escalating fault recovery — engine-level retry
  budget, two-tier quick-reopen → full-restart → permanent-fatal escalation, and
  the observability signals emitted at each step.

### Modified Capabilities
- `frame-delivery`: consumer lane streams survive recovery/restart teardown
  (transparent restart); they are terminated only by a user-initiated `close()`
  or the terminal fatal, not by a transient recovery reopen.

## Impact

- `CameraKit/Sources/CameraKit/CameraEngine.swift` — teardown mode that preserves
  consumers, engine-level budget counter, escalation in `performTeardownAndReopen`,
  reset in `onFrameTick`, terminal-fatal path.
- `CameraKit/Sources/CameraKit/PixelSink.swift` / close teardown — the
  preserve-consumers path (skip `release()`).
- `CameraKit/Sources/CameraKit/Constants.swift` — `fullRestartSettleSeconds`,
  `maxFullRestarts`.
- `README.md` and CameraKit docstrings — restart-transparency guidance.
- Tests — device test that a lane subscribed before a forced stall keeps yielding
  frames after the restart; escalation test that persistent no-frame faults go
  quick → full → fatal in bounded steps with `failAllLanes` only at terminal fatal.
- No public API signature change; `open()`/`close()`/`subscribe()` shapes unchanged
  (the preserve-consumers teardown is internal).
