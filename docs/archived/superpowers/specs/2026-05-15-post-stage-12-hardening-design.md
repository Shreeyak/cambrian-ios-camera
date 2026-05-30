# Post-Stage-12 hardening — design

## Problem

The brief-driven pipeline ended at Stage 12. A retrospective review surfaced
six cross-cutting points that survive independently of any future stage:

1. **#6** — sync-throw vs. async-stream error routing is undocumented; each
   contributor re-derives the rule from call sites.
2. **#4** — `FrameSet` lifetime contract (no retain across `await`, buffers are
   pool-backed) is implicit; a consumer that retains a `FrameSet` exhausts the
   pool and the failure surfaces three hops away as a recovery event.
3. **#2** — ~12 `nonisolated(unsafe)` single-writer mailbox sites re-cite the
   same safety invariant; the convention has no named carrier, so new sites
   drift (paraphrased comments) or regress to `Mutex` on the hot path.
4. **#3 + #5** — `CameraEngine` has no in-memory `SessionState`. It stores
   `isOpen: Bool` (a 2-state degenerate view of a 6-case enum) plus
   `sessionToken: ManagedAtomic`, and fire-and-forget emits state transitions.
   Transition legality is enforced procedurally, not structurally; off-expected
   transitions emit silently.
5. **#11** — the post-#3 engine↔VM state relationship (engine authoritative,
   VM downstream mirror) is a new non-obvious fact that needs recording.

The pipeline is done, so there is no future stage to absorb these. They are
treated as a single standalone hardening effort outside brief discipline.

## Goal

Two coding changes (Mailbox, engine state machine) and three doc changes
(error routing, FrameSet lifetime, DECISIONS entry). One design, one plan,
one PR. Production behavior change ≈ zero — the value is reduced unsafe
surface and structured diagnostic visibility.

Non-goals: bug fixing (nothing currently observed is being fixed); engine
decomposition (#7 — explicitly declined; actor-hop cost not justified);
parallel-stream ordering contract (#1 — separate effort if pursued); time
abstractions (#9); engine-monolith split.

## Sequencing — Approach A (risk-graded)

1. **Docs of existing behavior** (#6 + #4). Zero code-behavior risk.
2. **`Mailbox<T>`** (#2). New leaf type + mechanical migration of true
   mailbox sites; no behavioral change.
3. **Engine state machine** (#3+#5). The only behavioral surface change —
   bounded to ~12 call sites in `CameraEngine.swift`, observability-first.
4. **DECISIONS.md entry** (#11). Written last so it records post-#3 truth.

#11 must come after #3 — it documents a relationship #3 changes.

---

## #6 — Error-routing rule (doc)

A header doc-comment block on `Errors.swift` stating the routing contract:

> Synchronous rejections at the command boundary (caller violates a
> precondition, invalid arg, alreadyOpen/notOpen) → typed `EngineError`
> throw. Asynchronous hardware/session/encoding failures (capture device,
> AVCaptureSession runtime error, AVAssetWriter, watchdog) → `CameraError`
> on `errorStream`. `EngineError.fatal(CameraError)` is the bridge when a
> synchronous path discovers a fatal async-origin condition.

Same rule appended to `CameraKit/DECISIONS.md` as an entry.

No code change. Documents what every existing throw/emit site already does.

## #4 — `FrameSet` lifetime contract (doc)

A doc comment on the `FrameSet` struct in `FrameSet.swift`:

> Consumers must not retain a `FrameSet` (or its `natural` / `processed` /
> `tracker` `CVPixelBuffer`s) across an `await` or beyond the next stream
> yield. Buffers are pool-backed (POOL_CAP_RULE); retention exhausts the
> pool, starves frame delivery, and surfaces three hops away as
> `frameStall` / watchdog recovery. Snapshot fields you need (frame number,
> capture time, metadata) before yielding control.

## #2 — `Mailbox<T>`

New file `CameraKit/Sources/CameraKit/Mailbox.swift`. Approximate shape:

Approximate shape — exact storage form (`nonisolated(unsafe) var` vs.
plain `var` under `@unchecked Sendable`) is plan-pinned:

```swift
/// Single-writer cross-isolation reference cell. Names the convention used
/// at every `nonisolated(unsafe)` mailbox site so the safety contract lives
/// once, on the type, instead of being re-cited at each site.
///
/// Contract:
///   - Exactly one writer, on one fixed queue / isolation domain.
///   - Stored values are pointer-sized references (class / CF / NS) or
///     written exactly once before any read (lazy-init form).
///   - Readers tolerate seeing the old or new reference; tearing is
///     precluded by single-pointer-sized stores.
///
/// Mailbox adds NO synchronization. It does not catch new categories of
/// bug at compile time. Its value is that the invariant is stated once,
/// and the pattern is grepable (`Mailbox<`) and reviewable
/// (`mailbox.store(...)` outside the documented writer is a review smell).
public final class Mailbox<T>: @unchecked Sendable {
    private var _value: T?
    public init(_ initial: T? = nil) { self._value = initial }
    public func store(_ value: T?) { _value = value }
    public var latest: T? { _value }
}
```

**Migration target — true mailbox sites only:**

- `MetalPipeline.swift` — `latestNaturalTex`, `latestProcessedTex`,
  `latestTrackerTex`, `latestNaturalBuffer`, `latestProcessedBuffer`,
  `latestTrackerBuffer` (6 sites; written on delivery queue, read from
  MainActor / sessionQueue).
- `CameraEngine.swift` — `cachedStateStream`, `cachedErrorStream`,
  `cachedFrameResultStream`, `cachedRecordingStream`, `_metalPipeline`
  (5 sites; lazy-init form, write-once-before-read).
- `DisplayViewModel.swift` — `trackerTex` (1 site).

**Not migrated (explicitly out of scope):**

- `CaptureDeviceProviding` / `KVOAsyncStream` `nonisolated(unsafe) let
  device = avDevice` — framework-capture of non-`Sendable` `AVCaptureDevice`
  into closures. Different pattern; safety argument differs.
- `MetalPipeline.pendingCaptureContinuation` — one-shot continuation handoff.
- `MetalPipeline.didNoOpCountForTest`, `CaptureDelegate.logNextFrame` — test
  / debug counters; not the mailbox pattern.
- `CameraKitLog.isEnabled` / `fileHandle` — startup-write-then-read statics.
- `PhotosLibraryClient.authorizationProvider` — test-injection point.

The plan pins each migrated site against the contract (which queue is the
single writer; pointer-size vs. write-once safety argument) and updates the
existing site comments to reference the `Mailbox<T>` doc instead of restating
the invariant locally.

## #3 + #5 — Engine authoritative `SessionState` + expected-transition map

### Current shape

`CameraEngine` (actor) stores:
- `private var isOpen: Bool` — set true at the tail of `open()`, false at the
  end of `close()`. Two-state.
- `nonisolated let sessionToken: ManagedAtomic<UInt64>` — atomic identity
  counter for watchdog / D-10 races. **Stays as-is.** Different concern.
- `private nonisolated let stateContinuationBox` — emits `SessionState` to
  subscribers but does not retain the current value.

There is no engine-side stored `SessionState`. The canonical current state
lives off-actor on `ViewModel.sessionState` as a downstream mirror of the
stream. The engine cannot consult its own state.

### New shape

New file `CameraKit/Sources/CameraKit/SessionStateMachine.swift`:

```swift
/// Authoritative SessionState for the engine actor. Routes every transition
/// through a legality check classified against the expected-transition map.
///
/// The map is NOT a closed FSM. AVCaptureSession has its own independent
/// state (isRunning, isInterrupted) mutated asynchronously by the OS via
/// wasInterruptedNotification / interruptionEndedNotification /
/// runtimeErrorNotification. Those are inbound events, not commands. The map
/// distinguishes:
///
///   - command-driven transitions (open/close/pause/resume — initiated by
///     our code). Strict expected set.
///   - event-driven transitions (interruption began/ended, runtime error —
///     initiated by the OS). Permissive expected set; can arrive from many
///     states.
///
/// Off-map transitions are LOGGED with structured data (from, to, kind,
/// caller via `#function`) and `assertionFailure(...)` in DEBUG. The
/// transition is then APPLIED — observability first; we do not reject.
/// Hard rejection of off-map transitions could
/// wedge a session on a legitimate-but-rare OS event ordering (e.g.
/// system-pressure interruption followed by a runtime error during the
/// interruption: paused → recovering, which the analysis flagged as a
/// suspected bug but Apple's model permits as a legitimate sequence).
///
/// The state machine is therefore a diagnostic instrument: a `paused →
/// recovering` log entry correlated with an OS notification is the legitimate
/// path; the same entry with no OS event in the preceding window is the
/// watchdog-race bug the analysis predicted. Logs distinguish them.
struct SessionStateMachine {
    private(set) var current: SessionState = .closed

    enum Kind { case command, event }

    /// Mutates current. Returns whether the transition was on the
    /// expected-map for its kind. Caller logs off-map cases.
    @discardableResult
    mutating func transition(to next: SessionState, kind: Kind) -> Bool { ... }

    /// Pure query — used by callers that want to validate without mutating.
    func isExpected(from: SessionState, to: SessionState, kind: Kind) -> Bool { ... }
}
```

**Proposed expected-transition map** (plan refines after auditing every
`publishState` site for the actual `kind` per site):

```
command-driven (host-initiated; D-14 self-heal counted as engine-commanded):
  closed     → opening, streaming         // direct closed→streaming today
                                          // if .opening is never emitted;
                                          // Open Q #1 decides
  opening    → streaming, closed
  streaming  → paused, closed
  paused     → streaming, closed
  recovering → closed                     // close() during recovery
  error      → closed                     // D-14 self-heal back to closed

event-driven (OS-initiated via AVCaptureSession notifications):
  streaming  → recovering, error, paused
  paused     → streaming, recovering, error    // OS interruption ended,
                                                // OR overlap with runtime err
  recovering → streaming, error
  opening    → error                            // open() failure
  any        → error                            // in extremis
```

Everything not listed is off-map (logged + DEBUG-assert + applied).

### `CameraEngine` adoption

- Add `private var stateMachine = SessionStateMachine()`.
- Existing `publishState(x)` (~6 call sites) becomes
  `transition(to: x, kind: …)` followed by `stateContinuationBox.yield(x)`.
  Each site explicitly classifies command vs. event at the call.
- Existing `publishStateAsync(.recovering)` (event-driven) classified
  accordingly.
- `isOpen` becomes a computed property:
  `var isOpen: Bool { stateMachine.current != .closed }`. The `error` /
  `opening` predicate handling is pinned in the plan after the source audit
  confirms whether `.opening` is ever emitted today (grep suggests it is
  not — open() jumps `.closed` → `.streaming` directly).
- `_markOpenForTest()` becomes a state-machine test seam:
  `stateMachine._setCurrentForTest(.streaming)`.
- `AVCaptureSession.startRunning() / stopRunning()` stay on the serial
  `sessionQueue` per ADR-07. **Do not** couple the actor-stored
  `SessionState` to those calls beyond the existing publish points. The
  validator runs on the actor; the AV session mutations run on
  `sessionQueue`; the two coordinate via the existing publish boundaries.

### `sessionToken` is explicitly NOT folded in

`sessionToken: ManagedAtomic<UInt64>` is a nonisolated atomic identity
counter consumed by watchdogs and the D-10 completion-handler guard. It
serves race-detection ("did the session change since I armed?"), not
lifecycle modeling. It stays exactly as-is.

### Engine self-consultation — payoff sites

After adoption, internal callers that today gate on `isOpen` can branch on
`stateMachine.current`:

- `RecoveryCoordinator` (via a new hook reading engine state) can check
  current state rather than relying solely on `attempt` + external
  `cancelPendingRetry()`.
- Watchdogs can skip firing during legitimate non-streaming states
  (`.paused` / `.recovering`) instead of token-comparison races.

These are payoff sites enabled by #3, not part of #3's scope. The plan
notes them as "follow-up consumers" but does not change watchdog or
recovery logic in this PR.

## #11 — DECISIONS.md entry (not a doc file)

Append to `CameraKit/DECISIONS.md`:

> **Post-Stage-12 hardening — engine-authoritative `SessionState`.** The
> `CameraEngine` actor now stores its own `SessionState` via
> `SessionStateMachine` and is the authoritative source. `ViewModel` holds
> a downstream `@Observable` mirror updated from `stateStream()` — used for
> SwiftUI invalidation, not as the canonical answer. Synchronous truth is
> available to actor-isolated callers via `engine.stateMachine.current`.
> `isOpen` is now a derived computed property; the prior parallel `Bool`
> store is removed. `sessionToken` is unchanged and remains the identity
> mechanism for watchdog / D-10 race detection.

No standalone `VIEWMODEL-LAYER.md` doc is written. The forward-looking
justification ("each future stage rebuilds VM primitives") does not apply
post-Stage-12; the VMs already exist and are heavily doc-commented; a
standalone doc would risk staleness without ongoing maintenance pressure.

---

## Testing

New files (each `@Suite` is its own struct per repo convention; run
`scripts/sync-test-target.sh` after creating):

- `CameraKit/Tests/CameraKitTests/MailboxTests.swift`
  - `latest` is `nil` before first store.
  - `store(x); latest == x`.
  - Last-write-wins: `store(a); store(b); latest == b`.
  - `store(nil)` clears.
  - `Mailbox<T>` usage compiles in `@Sendable` contexts (witness, not assert).

- `CameraKit/Tests/CameraKitTests/SessionStateMachineTests.swift`
  - Initial `current == .closed`.
  - Every command-driven (from, to) pair: assert classifier matches table.
  - Every event-driven (from, to) pair: assert classifier matches table.
  - `transition(to:kind:)` updates `current` regardless of classification
    (observability-first behavior pinned).
  - Off-map transitions: `isExpected(...)` returns `false`; current still
    updates. (DEBUG `assertionFailure` is not asserted in tests — release
    behavior is the contract.)

No new tests are added for `CameraEngine` adoption itself. The existing
suite covers behavior; adoption is a structural refactor that the device
build + existing tests validate. Diagnostic-log assertions on off-map
transitions are out of scope.

## Verification & integration

- Build via `mcp__XcodeBuildMCP__build_run_device` (device-only per
  CLAUDE.md §6). Wrapper fallback: `scripts/build-summary.sh`.
- Tests via `mcp__XcodeBuildMCP__test_device` (scheme `eva-swift-stitch`),
  filtered to the two new suite structs. Wrapper fallback:
  `scripts/test-summary.sh --filter eva-swift-stitchTests/MailboxTests` and
  `…/SessionStateMachineTests`.
- swiftlint, swift-format `--strict` (pre-commit hook).
- `scripts/regen-contracts.sh` runs on pre-commit; verify `CONTRACTS.md`
  picks up `Mailbox<T>` and `SessionStateMachine`.
- `state.md` gets a post-Stage-12 hardening section noting the scope and
  pointing at this spec.
- One PR pending explicit git approval per CLAUDE.md §7.

## File inventory

**New:**
- `CameraKit/Sources/CameraKit/Mailbox.swift`
- `CameraKit/Sources/CameraKit/SessionStateMachine.swift`
- `CameraKit/Tests/CameraKitTests/MailboxTests.swift`
- `CameraKit/Tests/CameraKitTests/SessionStateMachineTests.swift`

**Modified:**
- `CameraKit/Sources/CameraKit/Errors.swift` — error-routing rule doc
  header (#6).
- `CameraKit/Sources/CameraKit/FrameSet.swift` — lifetime contract comment
  on `FrameSet` struct (#4).
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — 6 mailbox sites
  migrate (#2); local comments shortened to reference `Mailbox<T>`.
- `CameraKit/Sources/CameraKit/DisplayViewModel.swift` — `trackerTex`
  migrates (#2).
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — 5 cached-stream
  mailboxes migrate (#2); adopts `SessionStateMachine`, routes
  `publishState` through `transition(to:kind:)`, removes stored `isOpen`,
  adds derived computed property (#3 + #5).
- `CameraKit/DECISIONS.md` — error-routing + engine-authoritative entries
  appended.
- `CameraKit/state.md` — post-Stage-12 hardening section.

**Not changed:**
- `RecoveryCoordinator.swift`, `Watchdog.swift` — payoff consumers of #3
  but out of scope this PR.
- `ViewModel.swift` and child VMs — the `@Observable` mirror pattern is
  unchanged; DECISIONS entry describes the new relationship.
- All `nonisolated(unsafe)` sites listed under "Not migrated" above.

## Open questions — pinned for the plan

1. Exact `isOpen` predicate: confirm whether `.opening` is ever emitted in
   the current source. If not (grep suggests not), `state != .closed` is
   correct. If yes, predicate becomes `state == .streaming || state ==
   .recovering || state == .paused`.
2. `_markOpenForTest()` consumers — verify nothing depends on `isOpen`
   being set without `SessionState` advancing; if anything does, decide
   between a dedicated test seam or a state poke.
3. Per-call-site `Kind` classification for the ~6 `publishState` sites —
   the plan walks each site and pins command vs. event.
4. Whether the existing `_emitErrorForTest` / `_postSessionEventForTest`
   seams need any update to drive transitions through the state machine,
   or whether they remain pure stream pokes.
