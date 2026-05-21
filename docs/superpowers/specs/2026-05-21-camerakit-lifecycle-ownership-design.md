# CameraKit Lifecycle Ownership — Design

**Status:** Draft — hardened 2026-05-21 after two independent adversarial reviews + a
transition-model audit (latest-intent-wins contract; OS-owned guard, both actuation directions;
safe `initialPhase`; two OS-owned predicates; event-vs-event interleave) — awaiting user review
**Date:** 2026-05-21
**Scope:** The public lifecycle API of CameraKit and the app-lifecycle/device-lifecycle
ownership boundary. Changes stay inside `eva-swift-stitch` (the package + the dev-harness
app target). The cam2fd Flutter plugin is documented as the downstream *consumer contract*
but is edited in its own repo — out of scope here.

---

## Context

A camera app is driven by **two independent, concurrent state machines**
(`docs/ios-camera-lifecycle.md` §2): the **device lifecycle** (OS-driven `AVCaptureSession`
interruptions) and the **app lifecycle** (host visibility transitions — SwiftUI `scenePhase`,
Flutter `AppLifecycleState`).

**Current boundary:**

- **Device lifecycle is already package-owned and correct.** `CameraSession` registers the
  interruption/runtime-error observers (`CameraSession.swift:213-233`); `CameraEngine.onSessionEvent`
  drives interruption → recovery → gate/watchdog discipline. This matches Apple's model: the
  OS interrupts the session itself on background
  (`AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground`) and the app
  reacts. **No change** (except the event-vs-event interleave hardening in *Concurrency*).
- **App lifecycle is host-owned, but the surface is wrong.** The package is headless (no
  SwiftUI views). The app's `ViewModel.handleScenePhase` (`eva-swift-stitch/UI/ViewModel.swift:321-354`)
  orchestrates **five** engine primitives in a brittle, order-dependent sequence (`setGate`,
  `drainSubmittedFrame`, `notifyScenePhasePaused`, `backgroundSuspend`, `backgroundResume`)
  and tracks `cameFromBackground` itself. Every consumer re-implements this — `docs/ios-camera-lifecycle.md`
  §10 explicitly tells Flutter integrators to replicate it.

**The problem:** the app-lifecycle surface is *mechanistically* sufficient but exposes
primitives that require understanding engine internals (gates, drains, the disarm/finalize/stop
ordering) and duplicates the policy per consumer. We want hosts to drive the lifecycle through
one simple, semantic call and let the package own the complexity in one place.

---

## Decision: two lifecycles, two owners

- **Device lifecycle → package.** Unchanged. CameraKit keeps observing the
  `AVCaptureSession` interruption notifications on `sessionQueue` (ADR-07).
- **App lifecycle → host *observes*, package *executes*.** The host forwards a single coarse
  phase value; the package translates it into the full internal sequence. **The package does
  NOT observe `UIApplication` / `UIScene` / `scenePhase`.**

### Why the package does not observe app lifecycle itself

1. **No permanent `@MainActor` notification-observer bridge added to the package.**
   `UIApplication`/`UIScene` notifications are `@MainActor`; `CameraEngine` is an `actor`.
   Keeping observation in the host avoids wiring a standing main-actor→actor observer bridge
   into the package. (The package already calls `UIApplication.shared` synchronously for
   `beginBackgroundTask` in `Recording.swift:33` — this is about not adding a lifecycle
   *observer*, not about avoiding UIKit entirely.)
2. **Insulation from the UIScene migration.** The lifecycle *observation* mechanism is
   mid-migration: AppDelegate → SceneDelegate, `FlutterSceneLifeCycleDelegate`, and the
   UIScene lifecycle becomes **mandatory** in the release after iOS 26. By accepting only a
   clean phase enum, CameraKit is untouched by that churn — the host/plugin absorbs it.
3. **Scene attribution stays where the knowledge is.** On iPad multi-window, per-window
   lifecycle is a `UIScene` concern; only the host knows its scene. (Today the app is
   single-window — `UIApplicationSceneManifest_Generation = YES`, no
   `UIApplicationSupportsMultipleScenes` — so this is latent, not active.)

---

## Public API

One enum + one method. This is the **entire** host-facing lifecycle surface.

```swift
/// The host's current visibility. The only lifecycle vocabulary a host needs —
/// nothing about gates, drains, or sessions.
public enum AppLifecyclePhase: Sendable {
    case active       // foreground & interactive
    case inactive     // visible but not receiving input (Control Center, call banner, app-switcher peek)
    case background   // not visible
}

extension CameraEngine {
    /// Update the host's current lifecycle phase. Never throws; safe to call on
    /// every transition and before `open()`. The engine performs the full
    /// gate/session/watchdog reconciliation internally.
    ///
    /// Concurrency: the **latest call wins** — a superseded, still-in-flight
    /// reconciliation is abandoned rather than allowed to apply stale work
    /// (see *Concurrency: latest-intent-wins*). Rapid bounces are therefore safe.
    ///
    /// Calling convention:
    /// - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward the matching
    ///   case — `.active`/`.inactive`/`.background` map 1:1.
    /// - **Flutter (cam2fd):** the plugin's *native* Swift layer
    ///   (`FlutterSceneLifeCycleDelegate`) maps UIScene callbacks and calls this —
    ///   `resumed → .active`, `inactive → .inactive`, `hidden`/`paused → .background`,
    ///   `detached →` don't call. Do **not** forward lifecycle from Dart over the
    ///   method channel: observe natively so a backgrounding can't outrun an
    ///   in-flight recording's finalize.
    public func setLifecyclePhase(_ phase: AppLifecyclePhase) async
}
```

**Names locked** (advisor-reviewed):

- `AppLifecyclePhase` — the `App` prefix disambiguates from the engine-internal `SessionState`.
- Cases `active`/`inactive`/`background` — **deliberately** identical to SwiftUI `ScenePhase`'s
  vocabulary (different type, same case names; the SwiftUI host mapping reads as identity).
- `setLifecyclePhase(_:)` — a method, not a property, because reconciliation is `async`.
- 3 cases, no more (YAGNI — no host signal drives a 4th today). A plain public `Sendable`
  enum; no other annotations.

### Phase is a property, not an event

The engine carries `currentPhase` from construction — a continuous property, not a one-shot
command. This removes "ready to receive" as a concept and makes pre-`open()` calls a non-issue:

- `CameraEngine` takes a **required** `initialPhase: AppLifecyclePhase` — **no default.** A
  default of `.active` is a privacy trap: if `open()` runs before the host's first phase forward
  (prewarm / direct-into-background launch), the engine would go fully live and **turn the camera
  on with no foreground UI** — an App-Review red flag (adversarial review F4). Requiring the
  phase forces the host to state it; pass `.background` when unsure. (This deliberately overrides
  "existing callers unaffected" — an unsafe default is worse than a one-line call-site change.)
- `setLifecyclePhase(_:)` **writes `currentPhase` unconditionally and never throws.** It
  reconciles hardware (the table below) **only when the engine is open**; before `open()` it
  records the phase (and may publish the `SessionState` label).
- `open()` performs hardware *creation* (build session, add I/O) then runs the **same
  reconciliation routine** against `currentPhase` — opening into `.background` configures the
  session but doesn't `startRunning`; into `.inactive` starts it with the gate closed; into
  `.active` goes fully live. A phase arriving *during* `open()` is handled by the same
  latest-intent-wins contract (below), not dropped.
- `close()` tears down hardware; `currentPhase` persists, so a later `open()` picks up the
  latest phase.

Concurrency safety across interleaved `setLifecyclePhase` / `open()` / `close()` is **not**
automatic from actor isolation — see *Concurrency: latest-intent-wins*. There is **one
reconciliation routine**, invoked at **three actuation sites** — `open()`, `setLifecyclePhase`,
and **when the state machine exits an OS-owned state** (`.recovering`/`.interrupted` →
`.streaming`; see *The OS-owned guard*) — each reading `currentPhase`, all governed by that
contract. Consulting `currentPhase` at *every* actuation site is what makes "phase is a property"
load-bearing: no path — host command, `open()`, or OS recovery — can turn the camera on or arm a
watchdog against the host's current intent.

### Host mapping

The host maps its native lifecycle to the 3 cases:

| Host signal | → `AppLifecyclePhase` |
|---|---|
| SwiftUI `scenePhase` `.active` / `.inactive` / `.background` | identity (scenePhase has exactly these 3 cases) |
| Flutter `resumed` | `.active` |
| Flutter `inactive` | `.inactive` |
| Flutter `hidden` / `paused` | `.background` |
| Flutter `detached` | (don't call; pre-UI / teardown) |

- **SwiftUI app** — mapping lives in the **host**, so the package imports no SwiftUI / no
  lifecycle-aware UIKit:
  ```swift
  // in the app target, not the package
  func map(_ p: ScenePhase) -> AppLifecyclePhase {
      switch p {
      case .active: .active
      case .inactive: .inactive
      case .background: .background
      @unknown default: .inactive
      }
  }
  .onChange(of: scenePhase) { _, p in Task { await engine.setLifecyclePhase(map(p)) } }
  ```
- **Flutter (cam2fd)** — the plugin's **native** Swift layer (`FlutterSceneLifeCycleDelegate`)
  maps scene callbacks → enum and calls `setLifecyclePhase`. Dart's role is limited to
  user-intent commands (start/stop scanning) and its own texture rendering — **not** lifecycle
  forwarding over the method channel. (Native observation in the plugin is plain iOS code, not
  a Flutter feature, and avoids the Dart round-trip latency that matters for recording-finalize
  timing.)
- **Caveat (host's responsibility):** Flutter's `inactive` can fire for Flutter-internal
  reasons (route-push to a native VC, a FaceID prompt) without the app leaving the foreground.
  The plugin decides whether to forward it; a spurious `.inactive` → gate-close is cheap and
  self-corrects on the next `.active`, so over-forwarding is safe.

---

## What moves inside the package

The policy currently spread across `ViewModel.handleScenePhase` collapses into a **single
reconciliation routine** (shared by `setLifecyclePhase`, `open()`, and the OS-recovery exit —
the three actuation sites above). There is **no previous-phase tracking**: each call derives the
target from the *current* phase alone and reconciles the engine's *current actual* state to it.

**Target each phase reconciles to:**

| Phase | gate | session | watchdogs |
|---|---|---|---|
| `.active` | open | running (start if not — unless `osOwnsDevice`) | armed (unless `osOwnsDevice`) |
| `.inactive` | closed | running (start if not — unless `osOwnsDevice`) | disarmed |
| `.background` | closed | stopped + recording finalized | disarmed |

This is the field guide's invariants made declarative. (`⟺` reads "if and only if" — true in
*exactly* that phase and no other; `≠` reads "not".)

- **gate open ⟺ `.active`** — the GPU submission gate is open only in `.active`; closed in
  `.inactive` and `.background`.
- **watchdogs armed ⟺ gate open AND not `osOwnsDevice`** — the stall watchdogs are armed only
  while the gate is open *and* the OS does not own the current state (`osOwnsDevice` — `current ∈
  {.interrupted, .recovering, .error}`). Gate-alone would re-arm during a *foreground* OS
  interruption and fire a spurious stall → recovery (see *Concurrency*).
- **session start/stop** (stated as the reconciler's *action*, not a clean biconditional — the
  `osOwnsDevice` rider makes it conditional, unlike the two invariants above). The reconciler
  issues `startRunning` in `.active`/`.inactive` **unless `osOwnsDevice`** (don't fight an OS
  interruption / in-flight recovery for the device — adversarial review F2); it issues
  `stopRunning` only for `.background`.

The intermediate `background → inactive → active` (emitted by *both* SwiftUI and Flutter on
resume) needs no flag — at `.inactive` the session restarts (it isn't `.background`); at
`.active` the gate opens.

- **Reconciliation is unordered between the three facts** (gate, session, watchdogs are
  independent), **except**: the gate close — a synchronous atomic — is sequenced **before any
  suspending step** (the *Concurrency* invariants below rely on this), and the
  into-`.background` transition follows the field-guide §5 ordered sequence: disarm watchdogs +
  cancel retry → **finalize any active recording** → drain → `stopRunning`. Recording-finalize
  is **correctness, not optimization** — the OS interruption stops frame delivery but never
  calls `AVAssetWriter.finishWriting()`, so skipping it yields a corrupt `.mp4`
  (`docs/ios-camera-lifecycle.md` §5e); the ordered disarm is what makes the concurrent OS
  interruption safe (Bugs 1 & 3).
- **Recording finalize delegates entirely to `Recording.stop()` — the reconciliation adds no
  background task or timeout of its own.** `Recording.stop()` brackets *only* the writer drain
  in its own `beginBackgroundTask("recording-drain")` (`Recording.swift:195`), extending the OS
  budget past the unbracketed ~5 s, and races `finishWriting()` against a
  `Constants.recordingFinishTimeoutSeconds` deadline (the ADR-30 `ManagedAtomic` resume-once
  pattern; `withTaskGroup` is deliberately avoided). On **either** the deadline **or**
  background-task expiration it calls `cancelWriting()` (empty file) and emits
  `.recordingTruncated` — **never** an interrupted `finishWriting()` (corrupt MP4, no `moov`
  atom), ADR-16 / G-08. The other `.background` steps (gate-close, watchdog-disarm,
  `drainSubmittedFrame`, `stopRunning`) are deliberately **not** bracketed: each is synchronous,
  time-bounded, or suspend-safe — only the writer finalize is corruption-sensitive.
- **Behavior change vs. today (intentional):** session `startRunning` fires on entering the
  first foreground phase (`.inactive`), not at `.active`. Net latency to visible frames is
  unchanged (the gate still opens at `.active`); `startRunning` is dispatched marginally
  earlier, never later. The wider in-flight `startRunning` window this opens (a `.background`
  arriving mid-start) is covered by the latest-intent-wins contract (*Concurrency*).
- **The `SessionState` label + OS-authoritative deferral guard** (the job
  `notifyScenePhasePaused` does today — `CameraEngine.swift:561`) folds into the routine: it
  publishes `.paused`/`.streaming` and defers via `shouldDeferCommandLabel` (below) so a UI
  command can't overwrite OS truth (Bug 2).

### Concurrency: latest-intent-wins, and the three interleave cases

**Governing contract (latest-intent-wins).** `CameraEngine` is an `actor`, so concurrent calls
never race shared *state*. But actor isolation does **not** make a *method* atomic: the
reconciliation suspends at its `await`s (session `startRunning`/`stopRunning` — which run on
`sessionQueue`, ADR-07, not the actor — plus `cancelPendingRetry` and recording finalize), and
at every suspension point another reconciliation or an OS-event handler can be admitted to the
actor and run to completion. The design therefore requires an explicit contract: **a
superseded, in-flight reconciliation must not apply stale work — the most-recent intent wins.**

> Earlier drafts asserted *"actor serialization makes every ordering safe … resolve to whatever
> the most-recent phase implies."* **That is false** and was the spec's central hole (both
> adversarial reviews, independently): actor isolation prevents data races, not *logical
> staleness*. This contract is what actually delivers "the most-recent phase wins"; nothing in
> actor semantics does it for free.

The contract is stated at spec altitude; **the implementation plan picks the mechanism.** Two
equivalent realizations: (a) a **monotonic generation counter** captured on entry and re-checked
before each suspending step — abort if a newer call bumped it; (b) a **single-flight reconciler**
that re-reads the latest target after every `await` and abandons a stale target. Either makes
"latest wins" structural rather than asserted.

With that contract in force, the three interleave cases are safe:

**1. Phase vs. phase** (e.g. `.background` then `.active` on a lock-then-unlock, call-decline,
or app-switch bounce). *Without* the contract this **will break**: a `.background` reconciliation
suspended at recording-finalize is straggled by a completing `.active`; the straggler then runs
`drain`/`stopRunning` and leaves **gate-open + watchdogs-armed + session-stopped → permanent
black preview + spurious recovery**, with no OS interruption involved (adversarial review F1).
The recording-finalize await widens this window to *seconds*. The contract closes it: the
superseded `.background` reconciliation detects it is stale at its next checkpoint and abandons
the remaining steps. Gate-first (below) keeps frame-flow safe even within the window.

**2. Phase vs. OS event.** The host phase path and the OS interruption (`onSessionEvent`,
delivered via `Task { await onSessionEvent(...) }`, `CameraEngine.swift:260`) interleave at the
same `await`s. Safe by three primitives that hold *in addition to* the contract:
- **Gate-first, synchronously.** The gate (a synchronous atomic) is closed before any suspending
  step, so frames are gated before any interleave is possible; `.interrupted` gates them too.
  Frame-flow correctness never depends on which path runs first.
- **Idempotent steps.** `disarmAll()`, `cancelPendingRetry()`, the gate store, and `stopRunning`
  are no-ops when repeated, so the interruption handler (`CameraEngine.swift:1846-1848`) and the
  reconciliation may run them in any interleaving with the same result — there is no "redundant
  stop" to reject; repeats are absorbed. (Idempotency is repeat-safety; it is **not**
  reorder-safety — `stop ∘ start ≠ start ∘ stop` — which is precisely why case 1 needs the
  contract, not idempotency.)
- **OS-authoritative label.** The only contended label value: the reconciliation publishes
  `.paused`/`.streaming` (`.command`); the interruption publishes `.interrupted` (`.event`). The
  deferral (`shouldDeferCommandLabel`) makes the *command* publish defer whenever the machine
  already sits in an OS-owned state, so the terminal label is `.interrupted` (OS truth), never an
  overwriting `.paused` (Bug 2). The brief label-vs-gate mismatch is the accepted truthfulness
  gap (`docs/ios-camera-lifecycle.md` §7) — the gate, not the label, owns correctness.

**3. OS event vs. OS event** (adversarial review F5). AVCaptureSession interruptions arrive in
`begin`/`ended` pairs, each delivered as its **own** `Task { await onSessionEvent(...) }`
(`CameraEngine.swift:260`). `onSessionEvent` itself suspends (it drives recovery), so two
handlers can interleave **with each other**, not only with the phase path. The device-lifecycle
half is otherwise unchanged (§Decision), but this interleave is real and shares the actor with
the phase path, so it is **in scope here**: event handlers must be idempotent and obey the same
latest-intent-wins / authoritative-state discipline — a stale `.ended`/recovery handler must not
re-arm watchdogs or republish a label over a newer `.begin`/interruption. (The same generation
or single-flight mechanism that serializes the phase path covers event handlers, since both run
on the actor.)

#### The OS-owned guard (both actuation directions)

A *foreground* OS interruption — `videoDeviceInUseByAnotherClient`, system-pressure, or iPad
multi-foreground, all of which coexist with `.active` (unlike backgrounding) — disarms the
watchdogs via `onSessionEvent`; an interleaved `.active` reconciliation would otherwise re-arm
them (and `startRunning` the session) **while frames are still OS-stopped**. The re-armed
watchdog fires a spurious stall → `RecoveryCoordinator` teardown+reopen; for
`videoDeviceInUseByAnotherClient` (terminal `.error`) this drives the doubly-off-map `.error →
.recovering` and can escalate to a fatal `maxRetriesExceeded` the OS would otherwise have let
self-heal. Pre-existing (today's only re-arm site is `backgroundResume`'s `:789 → await :792 →
armWatchdogs :797` window); the declarative model **widens** it (every `.active` reconcile is a
re-arm + start site).

- **Phase → OS (the host command must not fight the OS):** while `osOwnsDevice`, the
  `.active`/`.inactive` reconciliation neither arms the watchdogs **nor** issues `startRunning`
  (adversarial review F2 extends the guard from the watchdog to the session-start in the same
  row).
- **OS → phase (OS recovery must not fight the host — the third actuation site):** when the OS
  event path resolves an OS-owned state (`.otherInterruptionEnded` driving
  `.recovering`/`.interrupted` → `.streaming`), it does **not** unconditionally re-arm /
  `startRunning`; it runs the **same reconciliation routine against `currentPhase`**. So
  `interruptionEnded` arriving while the host is `.background` leaves the session **stopped** (no
  camera LED, no spurious watchdog re-arm); while `.inactive` it restarts with the gate closed;
  only while `.active` does it go fully live. Without this, `osOwnsDevice` is **asymmetric** — it
  stops the phase path from fighting the OS but lets the OS-event path restart into a backgrounded
  app (camera-on with no foreground UI — an F4-class privacy gap the **gate does not cover**,
  since the gate gates GPU submission, not `AVCaptureSession` running state). Reachable: `.active`
  + recording → foreground interruption → `.background` → interruption ends. (Surfaced by the
  transition-model audit's compound-state lens — the one `(phase × device-state)` cell the
  earlier draft left open.)
- **Two honestly-named predicates, both over `SessionState` (single source of truth; no parallel
  mirror).** Two independent reviews flagged the earlier "one shared helper" as leaky — the
  deferral needs a `.opening` rider the watchdog/start guard does not — so a single name would
  *look* identical at both sites while carrying a hidden clause. Instead:
  - `osOwnsDevice` = `current ∈ {.interrupted, .recovering, .error}` — used by the watchdog-arm
    guard **and** the `.active`/`.inactive` session-start guard.
  - `shouldDeferCommandLabel` = `osOwnsDevice || (current == .opening && target == .paused)` —
    used by the label-deferral. The `.opening → .paused` rider preserves the launch-race the
    current `classify(...) == .offMap` check covers (`commandMap[.opening] = [.streaming,
    .closed, .error]` — no `.paused`; `CameraEngine.swift:564`, `:548`); it reproduces today's
    behavior for the `.paused`/`.streaming` targets. Existing deferral + classifier tests verify
    equivalence.

  (This reverses last round's "one shared helper" decision; see *Rejected / parked* for why.)

### Visibility changes

These become `internal` (still reachable by in-module `@testable import` tests; removed from
the consumer-facing API):

- `setGate(_:)`
- `drainSubmittedFrame()`
- `notifyScenePhasePaused(_:)`
- `backgroundSuspend()`
- `backgroundResume()`

> Demoting them is only possible *because* `ViewModel.handleScenePhase` is rewritten to the
> single `setLifecyclePhase` call (see Migration). The pre-implementation verification below
> confirms no other caller blocks this.

---

## Surface output, hide input

Observation streams stay **public** (hosts observe them to drive UI); the methods that *drive*
state stay internal. This convention already exists (ADR-22); the design draws the line
explicitly:

- **Public (observe):** `stateStream()` → `SessionState` (`CameraEngine.swift:434`), plus
  `recordingStateStream()`, `errorStream()`, `frameResultStream()`, `streamConfigStream()`,
  device `snapshotStream()`.
- **Internal (drive):** `publishState` / `publishStateAsync`, and the demoted methods above.

A host renders "streaming / paused / interrupted / recovering / error" from `stateStream()`,
and drives the engine only through `setLifecyclePhase` + the existing capture/record commands.

---

## Removed: user-intent pause/resume

`CameraEngine.pause()` / `resume()` (formerly `CameraEngine.swift:1634-1647`) are **removed** —
user-initiated pause/resume while the app is active is **not a required capability**. They had
**zero internal callers**, so removal is clean. *(Source edit applied 2026-05-21; build
verification deferred.)*

**Why this also simplifies the design:** a user-intent pause would be a *second, independent*
reason to stop frame delivery, which cannot share the lifecycle gate — it would require
composing two gates (`framesShouldFlow ⟺ lifecycle == .active AND userIntent == .resumed`) or
a lifecycle resume would silently override a user pause (and vice versa). Removing it means
**no second app-side pause source to compose** — the submission-gate boolean has one writer
(lifecycle), and the OS-authoritative deferral remains the only cross-source coordination. If
reintroduced, user pause/resume must be modeled as a composed second gate, not by reusing
`setLifecyclePhase`.

---

## Not in scope / deferred

- **Memory-pressure handling — dropped.** Deliberately not wired. The only source is
  `UIApplication.didReceiveMemoryWarningNotification` (no AVFoundation-native source), so
  observing it inside the package would reintroduce the exact app-process observation this
  design excludes. If ever needed it follows the same pattern: **host observes, forwards a
  call** (SwiftUI via the notification; Flutter via `WidgetsBindingObserver.didHaveMemoryPressure`).
  Parked, not lost.
- **`willEnterForeground` prewarm — not pursued.** Pre-warming `startRunning` during the
  foreground transition would hide part of the ~410 ms background-resume cost, but **no host
  signal for it exists**: SwiftUI `scenePhase` (3 "did" states) and Flutter `AppLifecycleState`
  (5 "did" states) both observe transitions after the fact; the only source is the native
  `sceneWillEnterForeground` / `UIApplication.willEnterForegroundNotification`. The field guide
  measures and accepts the ~410 ms cost (`docs/ios-camera-lifecycle.md` §3). Recorded as a
  known, accepted cost — **no extra phase case and no prewarm code are added.**

### Rejected / parked (from the adversarial reviews)

- **Rejected — "run the session only in `.active`" (drop `.inactive` session-running, review B's
  S2).** This would regress the field guide's *measured* cheap-pause: a **~4 ms gate-flip** on a
  Control Center / Notification Center dismiss instead of a **~410 ms `startRunning`**
  (`docs/ios-camera-lifecycle.md` §3). Keep `.inactive` session-running. The genuine half of the
  concern (starting at `.inactive` widens the in-flight `startRunning` window) is closed by the
  latest-intent-wins contract, **not** by deleting the optimization. (Review B could not read the
  field guide and proposed it as a "free" simplification; review A, with the field guide, did
  not — the contrast is why both reviews were run.)
- **Parked — arm watchdogs on first actual frame instead of predicatively (review A's S3).** A
  stronger structural idea: arming on the first delivered `CMSampleBuffer` after `startRunning`
  (disarm on gate-close) would delete the entire "armed while OS-stopped" class outright, making
  the `osOwnsDevice` arm-guard unnecessary. But it is more invasive (changes the arm trigger),
  and the latest-intent-wins contract + `osOwnsDevice` guard already close the cases. Revisit as
  a future simplification, not in this design.

---

## Documentation deliverables

The **lifecycle calling convention** — how a host drives `setLifecyclePhase`, including the
Flutter mapping — is canonical and must be documented in two places, kept in sync:

1. **API docstrings** on `setLifecyclePhase(_:)` and `AppLifecyclePhase`. The `setLifecyclePhase`
   docstring shown under *Public API* is the source text (SwiftUI 1:1 mapping + Flutter
   native-layer mapping + the latest-call-wins note).
2. **`CameraKit/README.md`** — a package README with a "Lifecycle" section. CameraKit has **no
   README today**; this design adds one. The section reads, in plain prose:

   > **Driving the lifecycle.** The host tells CameraKit its visibility by calling
   > `engine.setLifecyclePhase(_:)` on every transition — that is the entire lifecycle API.
   > CameraKit owns everything downstream (GPU gate, session start/stop, stall watchdogs,
   > recording finalize) plus the device-interruption lifecycle; the host owns only *observing*
   > its own app lifecycle and forwarding the phase.
   >
   > - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward `.active` / `.inactive` /
   >   `.background` (1:1 — they share names with `AppLifecyclePhase`).
   > - **Flutter:** observe the iOS app lifecycle in the **plugin's native Swift layer**
   >   (`FlutterSceneLifeCycleDelegate`), **not** in Dart, and call `setLifecyclePhase`:
   >   `resumed → .active`, `inactive → .inactive`, `hidden` / `paused → .background`,
   >   `detached →` skip. Forwarding from Dart over the method channel adds round-trip latency
   >   that can let a backgrounding outrun an in-flight recording's finalize and corrupt the
   >   `.mp4` — observe natively instead.
   >
   > Call it freely on every transition: it never throws, and the latest call wins (a superseded
   > in-flight transition is abandoned). Construct the engine with your current phase
   > (`initialPhase`) — there is no default.

---

## Migration

**Pre-implementation verification (confirmed 2026-05-21):**

- *Demotion is safe.* `grep` for `setGate` / `drainSubmittedFrame` / `notifyScenePhasePaused`
  / `backgroundSuspend` / `backgroundResume` across `eva-swift-stitch/`,
  `eva-swift-stitchTests/`, `eva-swift-stitchUITests/` returns hits only in `ViewModel.swift`
  (the `handleScenePhase` calls this migration rewrites, plus doc comments). No other caller
  blocks demoting them to `internal`.
- *Tests unaffected.* Every test file in both `CameraKit/Tests/CameraKitTests/` and the Xcode
  `eva-swift-stitchTests/` dual-member target uses `@testable import CameraKit`, so `internal`
  methods remain reachable.
- *Provenance of the interleave hole.* The current host invokes `handleScenePhase` via
  `.task(id: scenePhase)` (`CameraView.swift:99`) — which cancels a stale phase task and pairs
  with the sticky `cameFromBackground` flag — but cancellation is cooperative and the hardware
  ops aren't cancellation-aware, so the phase-vs-phase interleave (case 1) is **latent today,
  not closed**. The redesign neither introduces nor (by itself) fixes it; the latest-intent-wins
  contract is the fix, landed as part of this work.

Files changed in this repo:

1. **`CameraKit/Sources/CameraKit/SessionState.swift`** — add the public `AppLifecyclePhase`
   enum here (clusters with the other public lifecycle types — not an extension in
   `CameraEngine.swift`).
2. **`CameraKit/Sources/CameraKit/CameraEngine.swift`**
   - Add `public func setLifecyclePhase(_:)`, the `currentPhase` property, the **required**
     `initialPhase: AppLifecyclePhase` init parameter (no default), and the **shared
     reconciliation routine** invoked at all three actuation sites — `setLifecyclePhase`,
     `open()`, and the OS-recovery exit (below).
   - Implement the **latest-intent-wins** mechanism (generation guard or single-flight
     reconciler — implementer's choice) so a superseded in-flight reconciliation aborts at its
     next checkpoint. The same mechanism must cover OS-event-vs-event interleave.
   - Add the two predicates `osOwnsDevice` and `shouldDeferCommandLabel`; apply `osOwnsDevice` to
     both the watchdog-arm guard and the `.active`/`.inactive` session-start; apply
     `shouldDeferCommandLabel` to the label-deferral (replacing the inline `classify` check).
   - Wire the **third actuation site**: when `onSessionEvent` resolves an OS-owned state
     (`.otherInterruptionEnded` → `.streaming`), invoke the shared reconciliation routine against
     `currentPhase` instead of unconditionally re-arming / restarting (the OS→phase symmetric
     guard — *The OS-owned guard*).
   - Demote `setGate` / `drainSubmittedFrame` / `notifyScenePhasePaused` / `backgroundSuspend`
     / `backgroundResume` to `internal`.
   - Remove `pause()` / `resume()`. *(Source edit applied 2026-05-21; build verification deferred.)*
3. **`eva-swift-stitch/UI/ViewModel.swift`**
   - Replace the 5-call `handleScenePhase` body with a single
     `await engine.setLifecyclePhase(map(phase))`.
   - Remove the `cameFromBackground` property (no longer needed — the engine tracks nothing;
     it reconciles).
   - Pass the launch phase as `initialPhase` when constructing the engine.
4. **`CameraKit/CONTRACTS.md`** — regenerate (`scripts/regen-contracts.sh`).
5. **`CameraKit/README.md`** — create it (none exists today) with the "Lifecycle" section from
   *Documentation deliverables*, and ensure the `setLifecyclePhase` / `AppLifecyclePhase`
   docstrings carry the same calling convention.

Downstream (separate repos, documented not edited here):

6. **cam2fd plugin** — the native layer conforms to `FlutterSceneLifeCycleDelegate`, maps
   scene callbacks → `AppLifecyclePhase`, and calls `setLifecyclePhase`. Dart stops forwarding
   lifecycle.

---

## Testing

- **Reconciliation tests** drive `setLifecyclePhase` through realistic orderings and assert the
  target table (gate state, session running, watchdog armed, recording finalize) +
  `stateStream()` output:
  - `.active → .inactive → .active` (cheap pause; session never stops).
  - `.active → .inactive → .background` (suspend; into-`.background` ordered sequence; recording
    finalized if active).
  - **`.background → .inactive → .active`** (the resume ordering both SwiftUI and Flutter emit;
    asserts the session restarts at `.inactive` with the gate still closed, gate opens at
    `.active`) — the case the old `cameFromBackground` flag existed to handle.
  - **Flutter ordering** `.background → .background → .inactive → .active` (from `paused →
    hidden → inactive → resumed`) — asserts the duplicate `.background` is a no-op and the
    sequence converges identically.
- **Latest-intent-wins / phase-vs-phase** — drive `.background` then `.active` so the `.active`
  call is admitted while the `.background` reconciliation is suspended (inject a slow
  recording-finalize / session-stop seam). Terminal state must match **`.active`** (session
  running, gate open, watchdogs armed) — **not** session-stopped — and no `RecoveryCoordinator`
  entry / off-map fault is logged. This is the F1 regression guard.
- **Pre-`open()` + safe construction** — `CameraEngine(initialPhase: .background)` then `open()`
  opens the session **without** `startRunning` (camera off, no privacy indicator); a later
  `setLifecyclePhase(.active)` goes fully live. `initialPhase: .active` then `open()` goes live.
  (F4 guard: no path turns the camera on while the host's phase is `.background`.)
- **OS-authoritative deferral** preserved — `setLifecyclePhase(.active)` issued while the state
  machine is in an OS-owned origin (`.interrupted`/`.recovering`) must defer
  (`shouldDeferCommandLabel`), as `notifyScenePhasePaused` does today.
- **Recording-finalize durability** — `.background` with an active recording whose
  `finishWriting()` exceeds `recordingFinishTimeoutSeconds` (inject a slow fake writer): the
  writer is **cancelled** (empty file, `.recordingTruncated` emitted), never left corrupt; the
  background-task expiration path reaches the same outcome.
- **Phase-vs-event interleave** — an interruption event injected mid-`.background` reconciliation
  (via `_postSessionEventForTest(.otherInterruption(...))` between the sequence's `await`s):
  terminal `SessionState` is `.interrupted` (not `.paused`), the gate is closed, watchdogs are
  disarmed, no off-map/double-stop fault.
- **Event-vs-event interleave** (F5) — inject `.otherInterruption` then `.otherInterruptionEnded`
  so the `.ended` handler is admitted while the `.begin` handler is suspended: no stale re-arm /
  label republish over the newer event; terminal state matches the latest event.
- **`.active` OS-owned guard** — with the engine driven into an OS-owned state (inject
  `videoDeviceInUseByAnotherClient` → `.error`, or `.otherInterruption` → `.interrupted`),
  re-issuing `setLifecyclePhase(.active)` leaves the watchdogs **disarmed** **and** issues no
  `startRunning` — no spurious fire, no `RecoveryCoordinator` entry, no fatal escalation. Asserts
  `osOwnsDevice` blocks both the arm and the start.
- **OS-recovery exit reconciles against `currentPhase` (third actuation site)** — drive `.active`
  → inject `.otherInterruption` (`.interrupted`) → `setLifecyclePhase(.background)` → inject
  `.otherInterruptionEnded`. The resolve reconciles against `currentPhase == .background`: session
  stays **stopped**, watchdogs **disarmed**, no camera LED, no `RecoveryCoordinator` restart.
  Repeat with `.inactive` standing → session **restarts**, gate stays **closed**, watchdogs
  disarmed. Guards the OS→phase asymmetry (the transition-model audit's example #2).
- **Deferral parity** — `.opening → .paused` (a scenePhase pause arriving during `open()`) still
  defers; `.opening → .streaming` still publishes. Confirms `shouldDeferCommandLabel` preserved
  the broader `classify` coverage.
- Existing `SessionStateMachine` classifier unit tests (off-map gate, `docs/ios-camera-lifecycle.md`
  §5b / Bug 5) — unchanged.
- Build/verify on physical iPad → Mac "Designed for iPad" (no simulators).

---

## Follow-ups (file separately — out of scope)

- **`StopReason.pause` is now production-dead.** With `engine.pause()` removed, the only
  producer of `Recording.StopReason.pause` is gone; it survives in two recording-layer tests
  (`Stage10Tests.swift:265, :293`) exercising `Recording.stop(reason: .pause)` directly, and
  the orphaned `RecordingState.paused` terminal state. Decide whether to rip out the
  recording-layer pause plumbing (`StopReason.pause`, the `Recording.stop` pause branch,
  `RecordingState.paused`, the 2 tests) or leave it. **A recording-subsystem change; not part
  of this lifecycle design.**
- **`sensitiveContentMitigationActivated`** — the iOS 17+ `AVCaptureSession.InterruptionReason`
  (resume requires `SCVideoStreamAnalyzer.continueStream`) is likely not enumerated in
  `onSessionEvent`. File as a device-lifecycle gap.
- **Permission/route revocation mid-session** — the reconciliation table has no row for "device
  became unauthorized / route lost"; a `.active` reconcile assumes authorization holds. Out of
  the lifecycle surface's scope, but flagged by the adversarial review as an unmodeled product
  state worth a dedicated path.

---

## Rationale anchors

The two-lifecycle model, the gate (ADR-09 / D-06), OS-authoritative deferral, gate-guarded
watchdogs, and recording-finalize-before-suspend are all grounded in `docs/ios-camera-lifecycle.md`
§2–§6 (the on-device bug catalog is the evidence that "let the OS interruption handle
everything" alone produces real crashes). Apple model (OS interrupts on background; observe
`AVCaptureSession.*`; `startRunning` off-main; actor-based service) — all already satisfied by
CameraKit. Flutter/UIScene mandate (3.41 default, required after iOS 26) — Flutter
breaking-changes docs. The latest-intent-wins contract, the OS-owned guard (both actuation
directions — incl. the third actuation site, the OS-recovery exit), the safe `initialPhase`, the
two predicates, and the event-vs-event interleave were added 2026-05-21 after two independent
adversarial design reviews (one with field-guide context, one spec-only) plus a transition-model
audit.
