## 1. Consumer-preserving teardown

- [x] 1.1 Add an internal `teardown(preserveConsumers: Bool)` (or `close(releaseConsumers:)`) that performs the full `close()` teardown EXCEPT, when preserving, it skips `consumers.release()` and the `frameResultStream` continuation finish. `close()` (user + terminal fatal) calls it with full release; recovery/restart calls it preserving.
- [x] 1.2 Confirm/verify `open()` rebuilds `MetalPipeline` with the engine-owned `consumers` so a preserved subscriber resumes from the new pipeline (no new wiring expected).

## 2. Engine-level recovery budget

- [x] 2.1 Add engine state `recoveryReopensWithoutFrame: Int` and `fullRestartCount: Int`.
- [x] 2.2 Reset both to 0 in `onFrameTick` on a delivered frame, and on a user-initiated `open()`. Do NOT reset them in the recovery/restart teardown.

## 3. Two-tier escalation in the recovery reopen path

- [x] 3.1 In `performTeardownAndReopen`, choose the tier from the engine counters: quick reopen while `recoveryReopensWithoutFrame <= recoveryMaxRetries`; full restart while `fullRestartCount < maxFullRestarts`; else terminal fatal.
- [x] 3.2 Quick reopen: increment the counter, `teardown(preserveConsumers: true)` + `open(fromRecovery:)`.
- [x] 3.3 Full restart: increment `fullRestartCount`, reset the quick counter, sleep `Constants.fullRestartSettleSeconds`, then preserve-teardown + open.
- [x] 3.4 Terminal fatal: `publishError(isFatal: true)` (→ `failAllLanes`) then full `close()`; perform no further reopen. Ensure the coordinator's own `maxRetriesExceeded` path does not double-emit a fatal.
- [x] 3.5 Publish `.recovering` + a NON-fatal error on each escalation step (quick + full); reserve `isFatal` for the terminal step only.

## 4. Constants

- [x] 4.1 Add `Constants.fullRestartSettleSeconds` (~1.0) and `Constants.maxFullRestarts` (~3). Keep `recoveryMaxRetries` (5) as the quick-reopen bound.

## 5. Docs

- [x] 5.1 README: add a short subsection under the recovery/lifecycle material stating a restart is transparent to consumers iff it skips `release()`/`failAllLanes()` — surviving subscribers see a frame gap then resume; lanes terminate only on user `close()` or the terminal fatal.
- [x] 5.2 Docstrings: document the same on the new teardown method, on `ConsumerRegistry.release()`/`failAllLanes()`, and on `open()`/`close()` where the consumer-lifecycle contract is stated.

## 6. Verification

- [x] 6.1 Device test (physical iPad): subscribe a lane, force a stall (test seam, e.g. the first-frame/no-frame override or a synthetic watchdog fire), trigger recovery/full restart, and assert the lane keeps yielding valid frames after the restart with no finish/throw.
- [x] 6.2 Test: persistent no-frame fault escalates quick → full → fatal in bounded steps (no infinite loop); assert `failAllLanes` fires only at the terminal fatal and the counts match `recoveryMaxRetries` + `maxFullRestarts`.
- [x] 6.3 Test: a reopen that delivers a frame ends escalation and resets the budgets (no fatal).
- [x] 6.4 Existing recovery tests (Stage09) remain green; run the CameraKit suite on device.
