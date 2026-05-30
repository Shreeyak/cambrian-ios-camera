# CameraKit Architecture Review

**Date:** 2026-04-24
**Scope:** architecture/ docs + stage-01..stage-12 briefs + current source under `CameraKit/Sources/`
**Purpose:** Independent assessment of the architectural pattern the briefs lay out. Pattern identification, fit analysis, comparison to TCA / Redux alternatives, concrete problems in the current design, prioritized recommendations.

---

## Executive summary

The briefs and architecture/ docs describe a **three-layer sandwich MVVM** (ADR-01) with a **Swift-6 actor-based service layer** and a **unidirectional AsyncStream event bus** for engine → UI notifications. The pattern is well-matched to the app's shape: one screen, real-time hot path, AVFoundation queue discipline, GPU-to-encoder zero-copy.

The engine layer is solid. The VM layer is where discipline will erode as the app grows. The highest-value fixes are cheap documentation additions (stream ordering contract, error-routing rule, test-seam convention), not framework migrations. TCA would work for the VM-ward half and be actively harmful for the engine-ward half; Redux offers no advantage over TCA on Apple platforms in 2026.

Twelve concrete problems are identified below, ranked by severity × likelihood. Of those, four have low-cost fixes worth doing now; the rest are flagged for future attention.

---

## 1. The pattern

### 1.1 Shape

```
CameraView (SwiftUI, @MainActor)
  ↓ commands (async method calls)
ViewModel (@Observable, @MainActor)
  ↓ commands
CameraEngine (public actor — the whole API surface)
  ↓ delegates to internal collaborators
CameraSession / MetalPipeline / Recording / RecoveryCoordinator /
  ConsumerRegistry / StillCapture / Watchdog / AE monitor / FPS monitor
```

Events flow **upward** through four parallel `AsyncStream`s owned by the engine:

- `stateStream() -> AsyncStream<SessionState>`
- `errorStream() -> AsyncStream<CameraError>`
- `frameResultStream() -> AsyncStream<FrameResult>`
- `recordingStateStream() -> AsyncStream<RecordingState>`
- (Stage 12) `ConsumerRegistry.metricsStream() -> AsyncStream<FrameDeliveryStats>`

All use `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` per ADR-22 (every event delivered).

Commands flow **downward** through `async` methods on the engine actor.

### 1.2 Classification

Closest canonical fit: **MVVM** (per the standard iOS pattern table), with Swift-6 wrinkles:

| Wrinkle | Effect |
|---|---|
| Engine is `actor`, not a class | Concurrency isolation is structural. `AVCaptureSession` mutations hop to `sessionQueue` (ADR-07) inside the actor; sample-buffer delegate is `nonisolated` on the delivery queue (ADR-02). MVVM-2020 had no vocabulary for this. |
| Pure helpers carry the math | `CalibrationCompute`, `SettingsCoupling`, `UniformStorage` are stateless value-level modules. VM orchestrates; engine applies; helpers compute. Closer to ports-and-adapters hygiene than pure MVVM. |
| AsyncStream event bus (unidirectional events) | State flows up via streams, commands down via method calls. Redux-lite flavor — no reducer, no central store, but one-way event flow per concern. |
| Narrow protocol seams | `CaptureDeviceProviding`, `AssetWriting`, `CameraKitClock`, `BackgroundTaskHost` are test-injection boundaries, added when a test needed them. No framework DI container. |

In-codebase name for the pattern: **"the three-layer sandwich"** (ADR-01 §The three-layer sandwich anti-pattern — the ADR names the *anti-*pattern it avoids; the sandwich is the positive prescription).

---

## 2. Is the pattern right for this app?

### 2.1 What works

1. **Actor-based engine matches AVFoundation naturally.** `sessionQueue` discipline is structural once `CameraEngine: actor`. The alternative (ObservableObject class) requires either `@MainActor` hops on the hot path or manual queue discipline at every call site.
2. **Hot path stays off `MainActor`.** Sample-buffer → 6-pass GPU → NV12 encoder never crosses the UI thread. The delivery queue owns the fast path; the engine actor owns lifecycle.
3. **Value types + pure helpers are testable without mocking AVFoundation.** `CalibrationCompute` tests run in milliseconds with no device, no GPU, no mock. This is the single biggest ergonomic win of the design.
4. **Protocol seams are narrow and earned.** Four seams added across twelve stages, each driven by a specific test. No premature abstractions.
5. **One screen = MVVM's happy path.** The pattern's weakness (doesn't compose across many screens) doesn't apply.

### 2.2 What will hurt

1. **The VM is becoming the dumping ground.** Stage 11 alone added 8 slider debouncers, WB/BB calibrate actions, enablement derivation, toast/dialog split, scanning animation binding. Stage 12 adds metrics stream subscription. The file is heading north of 400 lines. MVVM does not scale beyond one big VM — there is no second-level coordination primitive.
2. **Stream ordering between parallel `AsyncStream`s is undefined.** Stage 10 §7 says "fatal finalize emits `onError(RECORDING_FAILED, isFatal: true)` **before** the state transition" — but this is a per-emitter promise with no enforcement mechanism. Subtle UI-ordering bugs live here.
3. **UI state is scattered.** `sidebarVisible` / `showExpandedBar` / `showDeliveryStats` are view-local `@State`; `currentToast` / `fatalDialog` / `recordingElapsedSeconds` live on the VM. No single "what's the UI showing?" value.
4. **No formal state machine.** `ControlEnablement` is a derivation; the engine's `SessionState` is an enum; transitions are enforced by convention in engine code. Stage 11's brief referencing a `.closing` state that doesn't exist is the canary.
5. **Test seams are ad-hoc.** Naming, visibility, and gating vary by stage. See §4.10 below.

---

## 3. Alternative patterns: TCA and Redux fit

### 3.1 TCA mapping (concrete)

```swift
@Reducer
struct CameraFeature {
    @ObservableState
    struct State: Equatable {
        var sessionState: SessionState = .closed
        var recordingState: RecordingState = .idle(lastUri: nil)
        var currentSettings: CameraSettings = .init()
        var currentProcessing: ProcessingParameters = .identity
        var lastFrameResult: FrameResult?
        var deliveryStats: FrameDeliveryStats?
        var currentToast: CameraError?
        var fatalDialog: CameraError?
        var recordingElapsedSeconds: Int = 0
        var sidebarVisible = false
        var showExpandedBar = false
    }

    enum Action {
        case onAppear
        case captureTapped, recordTapped, pauseTapped, resumeTapped
        case isoSlid(Double), shutterSlid(Int64), focusSlid(Double), zoomSlid(Double)
        case calibrateWBTapped, calibrateBBTapped
        case sessionStateReceived(SessionState)
        case recordingStateReceived(RecordingState)
        case errorReceived(CameraError)
        case frameResultReceived(FrameResult)
        case deliveryStatsReceived(FrameDeliveryStats)
        case recordingTick, toastExpired
    }

    @Dependency(\.cameraEngine) var engine
    @Dependency(\.continuousClock) var clock

    enum CancelID { case iso, shutter, focus, zoom, toast, streams }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .merge(
                    .run { send in
                        for await s in await engine.stateStream() { await send(.sessionStateReceived(s)) }
                    },
                    .run { send in
                        for await e in await engine.errorStream() { await send(.errorReceived(e)) }
                    }
                    // ...two more streams
                ).cancellable(id: CancelID.streams)

            case .isoSlid(let v):
                return .run { _ in
                    var d = CameraSettings(); d.isoMode = .manual; d.iso = Int(v)
                    try? await engine.updateSettings(d)
                }
                .debounce(id: CancelID.iso, for: .milliseconds(16), scheduler: DispatchQueue.main)

            case .errorReceived(let e) where e.isFatal:
                state.fatalDialog = e
                return .none

            case .errorReceived(let e):
                state.currentToast = e
                return .run { send in
                    try await clock.sleep(for: .seconds(3))
                    await send(.toastExpired)
                }.cancellable(id: CancelID.toast, cancelInFlight: true)
            }
        }
    }
}
```

**What moves:** `ViewModel` is replaced by `CameraFeature` + child reducers (`CalibrationFeature`, `RecordingFeature`, `ErrorFeature`). `CameraEngine` becomes a `@Dependency`. `AsyncStream`s are consumed by long-running Effects.

**What stays:** `CameraEngine` actor, `MetalPipeline`, `CameraSession`, `Recording`, `ConsumerRegistry`, `StillCapture`, `Watchdog`, `RecoveryCoordinator`. Sample-buffer delivery, 6-pass GPU, completion handlers, C++ `PixelSinkPool` — unchanged.

**Wins:**
- Slider debouncing for free via `.debounce(id:, for:, scheduler:)`. Eliminates Stage 11's custom `SliderDebouncer` infrastructure (~80 lines → 0, per control).
- Toast auto-dismiss via `.cancellable(id:, cancelInFlight: true)`. Solves the "new toast arrives while old timer is running" race for free.
- Formalized VM decomposition via child reducers instead of ad-hoc `@Observable` objects.
- `TestStore` for UI tests: explicit, exhaustive, replayable.

**Costs:**
- Every state mutation becomes an action case + reducer branch. `CameraSettings` has 12 fields → 12+ control-binding action cases alone.
- State must be `Equatable`. `FrameSet` (holds `CVPixelBuffer`) can't live in TCA state; it stays in the dependency layer. Usable via `FrameResult` projection (already Equatable).
- `@Dependency` proliferation: engine, `UserDefaults`, `UIApplication` (for `beginBackgroundTask`), `PHPhotoLibrary`, clock — all protocol seams that exist as ad-hoc protocols today become `DependencyKey` declarations.
- The hot path stays outside TCA. You cannot route 30fps sample buffers through actions. TCA replaces the VM only; it does not *unify* anything.
- Framework lock-in + learning curve.

**Verdict:** TCA fits the VM-ward half of the app cleanly. It is **wrong for the engine-ward half** — AVFoundation queues, Metal command graphs, completion handlers, and C++ interop are fundamentally imperative and side-effectful; they are already optimally expressed as `actor` + `ManagedAtomic` + completion handlers.

### 3.2 Redux (ReSwift-style)

Shape identical to TCA's State / Action / Reducer, minus the framework. Middleware replaces Effects; no scoped reducers; no `@Observable` bridging; no `TestStore`. On Apple platforms in 2026, **pick TCA or don't pick either** — there is no reason to hand-roll what TCA provides, and the maintained Swift Redux libraries are effectively abandoned.

### 3.3 Decision matrix

| Migration | Works? | Recommended? |
|---|---|---|
| Current → TCA for VM layer only | Yes, cleanly | **Only if** adding multiple screens or team grows past ~3 iOS engineers |
| Current → TCA all the way down (engine included) | No | Hot path cannot fit in a reducer. Don't try. |
| Current → Redux | Yes, but worse ergonomics than TCA, no maintained library | Skip |
| Current → VIPER / Clean Architecture | Overkill for one screen | Skip |
| Stay with current, decompose the monolith VM | Yes, incremental | **Yes** — highest ROI |

---

## 4. Concrete problems (ranked)

Severity = likelihood × blast radius. All citations are to files present in the repo or symlinked from `implementation/`.

### 4.1 Four parallel event streams, no ordering guarantee *(severity: high)*

**Issue:** `stateStream`, `errorStream`, `recordingStateStream`, `frameResultStream` all `.bufferingOldest(64)` per ADR-22. Each stream guarantees every event is delivered. **No architecture doc describes relative ordering between streams.**

Stage 10 brief §7: "Fatal finalization failure emits `onError(RECORDING_FAILED, isFatal: true)` **before the state transition**." This is a per-emitter promise the emitter has to honor manually. Stage 09 §8 test `09:disarm-before-state-transition` covers one specific ordering but not cross-stream.

**Failure mode:** UI toast fires for a non-fatal error from a session that `stateStream` already marked `.closed`. Or the fatal dialog appears after `SessionState` has already resolved to `.error`, making the Retry button semantics ambiguous. Reproduces intermittently; hard to test.

**Citations:** `architecture/09-errors-and-recovery.md#classification`, `architecture/api-surface.md`, `implementation/briefs/stage-10.md` §7.

### 4.2 `nonisolated(unsafe)` sprawl *(severity: medium)*

**Issue:** `CameraEngine._naturalTex / _processedTex / _metalPipeline`; `MetalPipeline.latestNaturalTex / latestProcessedTex / latestTrackerTex / latestNaturalBuffer / latestProcessedBuffer / latestTrackerBuffer`. Every site documents "single writer on delivery queue; read from MainActor" — the invariant is real, but **Swift 6's type system has been bypassed as a matter of style rather than as exceptional cases.**

**Failure mode:** New contributor adds `nonisolated(unsafe)` to match surroundings without checking the single-writer invariant. Race emerges; symptom is stale preview frames or green artifacts; root cause takes hours to find.

**Citations:** `CameraKit/Sources/CameraKit/CameraEngine.swift:48-58`, `CameraKit/Sources/CameraKit/MetalPipeline.swift:958-964`.

### 4.3 Three overlapping sources of truth for session identity *(severity: medium)*

**Issue:**
- `sessionState: SessionState` (actor-isolated enum: `opening/streaming/recovering/paused/error/closed`)
- `isOpen: Bool` (actor-isolated; derivable but stored)
- `isBackgroundSuspended: Bool` (per domain 06; not in the enum)
- `sessionToken: ManagedAtomic<UInt64>` (Stage 09 addition for D-10 / Inv 12 identity)

Stage 11's brief §8 enablement matrix names a `.closing` case that does not exist in the `SessionState` enum. Brief ↔ architecture ↔ source already diverge.

**Failure mode:** Logic branches on `sessionState` but misses a transient state; or branches on `isOpen` when it should branch on `sessionState`; or forgets to gate on `isBackgroundSuspended`.

**Citations:** `CameraKit/Sources/CameraKit/CameraEngine.swift:33`, `CameraKit/Sources/CameraKit/SessionState.swift:3-10`, `implementation/briefs/stage-11.md` §8.

### 4.4 CVPixelBuffer lifetime discipline is implicit *(severity: medium)*

**Issue:** `FrameSet: @unchecked Sendable` holds three `CVPixelBuffer`s. `ConsumerRegistry` yields it on `AsyncStream.bufferingNewest(1)`. `MetalPipeline` also stores buffers as nonisolated mailboxes. `CVPixelBufferPool` has a cap via `POOL_CAP_RULE`.

**No doc says "consumers must not retain FrameSet across an `await`."** Or "buffers are valid until the next yield." G-13 addresses the Sendable type-system bypass, not the lifetime contract.

**Failure mode:** A subscriber stores a `FrameSet` in `@State` → buffer pinned → pool exhausts → frames drop → GPU watchdog fires → UI shows `FRAME_STALL` notification. Root cause is consumer discipline but the diagnostic chain is three hops long.

**Citations:** `CameraKit/Sources/CameraKit/FrameSet.swift:559-571`, `architecture/05-consumers.md`, `architecture/04-metal-pipeline.md#pool-configuration`.

### 4.5 Recovery state machine is prose + procedure, not a type *(severity: medium)*

**Issue:** `architecture/09 §Recovery state machine` is an ASCII diagram. `RecoveryCoordinator` implements it as an actor with `enterRecovery(_:)` / `cancelPendingRetry()`. **Nothing enforces that `.recovering` is unreachable from `.error` except via self-heal (D-14).** A stray call chain that enters recovery from `.paused` (e.g. pause-during-recording racing with a watchdog fire) would happily transition.

**Failure mode:** Recovery retries while session is `.paused`, session token advances, late watchdog fires with valid-looking state but against a session that was meant to be dormant.

**Citations:** `architecture/09-errors-and-recovery.md#recovery-state-machine`, `architecture/09-errors-and-recovery.md#d-13-watchdog-disarm-precedes-all-recovery-actions`.

### 4.6 Two parallel error taxonomies with undocumented routing *(severity: medium)*

**Issue:**
- `EngineError` (typed throws; structural: `.metal/.interop/.recording/.capture/.fatal`) — **sync**, developer-facing
- `CameraError` (wire-format: code + message + isFatal; emitted on `errorStream`) — **async**, UI-facing

`StillCaptureError.alreadyInFlight` bubbles only as a typed throw. `MAX_RETRIES_EXCEEDED` appears only on `errorStream`. **No doc states the routing rule.**

**Failure mode:** A future contributor emits the same error on both channels, double-handling in the UI; or emits on neither, silent failure.

**Citations:** `CameraKit/Sources/CameraKit/Errors.swift:42-55`, `architecture/09-errors-and-recovery.md#engineerror-vs-cameraerror`.

### 4.7 Engine is a monolith actor accumulating every concern *(severity: medium, cumulative)*

**Issue:** `CameraEngine` owns lifecycle, configuration, settings/persistence, still capture, recording, recovery, observability, AE monitor, FPS monitor, watchdogs, interruption handling, self-heal, pause/resume, background suspension, plus five stream continuations. CONTRACTS.md shows ~60 methods. Every stage adds; nothing leaves.

**Failure mode:** Concurrency bugs concentrate in the densest actor. Reading the engine requires tracing method interactions across dozens of methods.

**Citations:** `CameraKit/Sources/CameraKit/CameraEngine.swift`, `CameraKit/CONTRACTS.md`.

### 4.8 Scaffold chain ordering is implicit *(severity: low-medium)*

**Issue:** Stage 09's §10 acceptance requires zero hits for `01:|04:|06:|07:` — i.e. Stage 08 must have run — but §1 *Depends on* only lists Stage 01 and Stage 04. Stage 10's starting state lists the C++ pool as pre-existing but only depends on Stage 04 / Stage 09 / Stage 02 per frontmatter. **The real chain dependency lives in starting-state prose, not in a machine-readable graph.**

`scripts/stage-preflight.sh` checks `state.md ↔ source slug coherence` but not "did the preceding stage run?"

**Failure mode:** A contributor who thinks they can run Stage 09 without running Stage 08 (branch planning) gets acceptance-check failures with no clear signal as to cause.

**Citations:** `implementation/briefs/stage-09.md` §1 vs §10, `implementation/briefs/stage-10.md` §1.

### 4.9 Three time abstractions coexist *(severity: low)*

**Issue:**
- Stage 09 `CameraKitClock` for watchdog + recovery (test-injectable)
- Stage 11 `SliderDebouncer` uses raw `Task.sleep` (not injectable)
- Stage 11 recording timer uses `Task.sleep` + wall clock
- `CMTime` from sample buffers for recording PTS

Tests that advance time forward only work on clock-injected paths. VM-timer tests must actually wait.

**Failure mode:** New timing-sensitive feature picks the wrong abstraction; test suite grows slow; flakes appear.

**Citations:** `CameraKit/Sources/CameraKit/Clock.swift` (Stage 09 addition), `docs/superpowers/plans/2026-04-23-stage-11-ui-polish-calibration-sidebar-toasts.md` Task 5.

### 4.10 Test seams are ad-hoc and inconsistent *(severity: low, cumulative)*

**Issue:** Naming: `texturePoolForTest` (suffix), `_emitErrorForTest` (prefix + suffix), `_fireSyntheticCompletionForTest` (prefix), `encodeToTIFF(readbackBuffer:)` (looks public, is test-only). Visibility: `internal` vs `public` inconsistently. Gating: some `#if DEBUG`, most not. Twenty-plus test seams accumulated across 11 stages with no shape.

**Failure mode:** Test seams leak into public API surface by accident; tests that depend on internal state can't find seams; `public` seams appear in `.swiftinterface` and look like supported API.

**Citations:** scattered; see `grep -rn 'ForTest\|forTest' CameraKit/Sources/`.

### 4.11 No architecture doc for the VM → View layer *(severity: low-medium)*

**Issue:** `architecture/08-ui.md` covers topology, scenePhase, error display, recording indicator — what *appears*. **It does not cover VM composition, responsibilities, or testing strategy.** Stage 11 invented `ControlEnablement` / `SliderDebouncer` / toast-dialog split because no reference model existed. Stage 12 invents metrics-stream VM binding. Every stage rebuilds VM-layer primitives from scratch.

**Failure mode:** Cross-stage inconsistency in VM shape; integration bugs when features interact via the VM.

**Citations:** `architecture/08-ui.md` (absent sections).

### 4.12 Architecture drift from briefs *(severity: low, growing)*

**Issue:** CLAUDE.md §8 says briefs win over architecture. Stage 10 reshaped `RecordingState` from arch's `preparing/stopping` to brief's `finalizing/paused`. Stage 11 references `.closing` which neither source has. Nothing reconciles brief overrides back into `architecture/`. **Twelve stages in, architecture/ is increasingly a historical document.**

**Failure mode:** New contributors reading `architecture/` are mis-led about current shape.

**Citations:** `implementation/briefs/stage-10.md` §4 vs `implementation/architecture/06-capture-and-recording.md#recording-state-machine`.

---

## 5. Recommendations

Ordered by ROI (effort × payoff × urgency).

### 5.1 Do now (low effort, real payoff)

| # | Recommendation | Effort | Payoff |
|---|---|---|---|
| 1 | **Document stream ordering** in `architecture/09`, or merge the four streams into a single `AsyncStream<CameraKitEvent>` sum type with filtered projections. Address §4.1. | Low-medium | Prevents a real bug class that's hard to test |
| 2 | **Error-routing contract** added to `architecture/09`: "synchronous rejections at the command boundary → typed `EngineError` throw; asynchronous hardware / session / encoding failures → `errorStream` as `CameraError`." Address §4.6. | Low (one paragraph) | Prevents re-derivation per stage |
| 3 | **Test-seam convention** in CLAUDE.md: single naming rule (e.g. `_name` prefix), visibility rule (`internal` only, never `public`), gating rule (always `#if DEBUG`). Retrofit existing seams opportunistically. Address §4.10. | Low | Reins in the sprawl |
| 4 | **Machine-readable stage dependency graph** — YAML sidecar per brief (`depends_on: [stage-04, stage-08, stage-09]`), consumed by `scripts/stage-preflight.sh`. Address §4.8. | Low | Catches skip-a-stage mistakes cheaply |

### 5.2 Do next (medium effort, high payoff when pain appears)

| # | Recommendation | Effort | Payoff |
|---|---|---|---|
| 5 | **`Mailbox<T>` wrapper type** encapsulating the "single writer on delivery queue, read from any isolation" pattern. Replace scattered `nonisolated(unsafe)` with a single typed abstraction. Address §4.2. | Medium | Removes convention-driven type-system bypass; one-time cost |
| 6 | **Decompose the monolith VM** into 4–5 small `@Observable` feature objects (`ControlsViewModel`, `CalibrationViewModel`, `RecordingViewModel`, `ErrorViewModel`, `DiagnosticsViewModel`), composed in `CameraView`. Each owns its own debouncers, stream subscriptions, enablement slice. Address §2.2.1. | Medium | Pattern's biggest weak spot; pure SwiftUI idiom |
| 7 | **VM-layer architecture section** in `architecture/08-ui.md`: composition, primitives (`ControlEnablement`, `SliderDebouncer`, toast/dialog split), testing strategy. Address §4.11. | Medium | Ends per-stage re-invention |
| 8 | **Single `UIState` value type** on the VM replacing scattered `@State` (`sidebarVisible`, `showExpandedBar`, etc). Makes UI transitions testable + screenshottable. Address §2.2.3. | Low-medium | Cleans up the last piece of hidden UI state |

### 5.3 Consider (higher effort, conditional payoff)

| # | Recommendation | When to do it |
|---|---|---|
| 9 | **`SessionStateMachine` type** with validated transitions. Would eliminate §4.3 + §4.5 entirely. | When lifecycle bugs appear, not before |
| 10 | **Clock unification**: make `CameraKitClock` the canonical time abstraction; retrofit `SliderDebouncer` and VM timers. Address §4.9. | When test suite timing flake becomes a recurring cost |
| 11 | **Engine sub-actor split**: move `Recording`, `StillCapture`, `RecoveryCoordinator` from "owned by engine" to "peer actors accessed via protocol". Address §4.7. | When the engine monolith itself causes concurrency bugs; cost is high (actor-hop overhead + test refactoring) |
| 12 | **Architecture ↔ brief reconciliation pass**. Address §4.12. | Between Stage 12 completion and any "v1.1" scope. Not mid-chain. |

### 5.4 Do not do

- **Migrate to TCA for the entire app.** The engine layer is wrong for TCA; you'd end up with two architectures coexisting, which is worse than one monolith.
- **Migrate to Redux.** No maintained library, same costs as TCA, worse ergonomics.
- **Adopt VIPER / Clean Architecture layering.** One screen, one engine; the ceremony buys nothing.
- **Add a Coordinator / Router.** One screen; nothing to coordinate.

### 5.5 TCA as a future option (conditional)

**Adopt TCA for the VM layer only** if and when any of the following become true:
1. App adds multiple screens (settings modal, gallery, onboarding flow) with navigation state
2. Team grows past ~3 iOS engineers and shared mental model of VM shape degrades
3. Time-travel debugging or replay of user sessions becomes necessary for support
4. Screenshot testing of discrete UI states becomes a priority

In all three TCA-adoption scenarios, **treat `CameraEngine` as a `@Dependency`** — do not push TCA down into the engine.

---

## 6. Appendix

### 6.1 Reading path for a new contributor

1. `CLAUDE.md` — repo rules, build/test tooling, load-bearing invariants
2. `CameraKit/state.md` — current stage and what's built
3. `CameraKit/CONTRACTS.md` — current API + internal shape (auto-generated)
4. `implementation/architecture/01-system-shape.md` — top-level composition
5. `implementation/architecture/02-concurrency.md` — ADR-07 / ADR-09 / D-10 / Sequence A/B/C
6. `implementation/architecture/api-surface.md` — public API surface
7. Current stage brief at `implementation/briefs/stage-NN.md`

### 6.2 Key ADRs and invariants

| ID | Topic | File |
|---|---|---|
| ADR-01 | Three-layer sandwich (View → VM → Engine) | 01-system-shape.md |
| ADR-02 | `nonisolated` sample-buffer delegate on delivery queue | 02-concurrency.md |
| ADR-07 | AVCaptureSession mutations on `sessionQueue` | 03-camera-session.md |
| ADR-09 | Submission gate + `waitUntilScheduled` drain | 04-metal-pipeline.md |
| ADR-16 | Recording finalize deadline + `cancelWriting` | 06-capture-and-recording.md |
| ADR-22 | `.bufferingOldest` on engine streams | 02-concurrency.md |
| ADR-23 | Retry `Task?` owned by `RecoveryCoordinator` | 09-errors-and-recovery.md |
| ADR-25 | Typed throws (`EngineError`) | 09-errors-and-recovery.md |
| D-10 | Completion-handler re-entrancy guard | 02-concurrency.md |
| D-11 | `FrameDeliveryStats` aggregates Swift + C++ counters | 05-consumers.md |
| D-13 | Watchdog disarm precedes all recovery actions | 09-errors-and-recovery.md |
| D-14 | Self-healing scope (CAMERA_IN_USE only) | 09-errors-and-recovery.md |
| G-08 | Never `finishWriting` after background-task expiry | 04-avfoundation.md (guide) |
| G-13 | CVPixelBuffer Sendable workaround | 02-concurrency.md |
| G-20 | Use-after-free on readback buffers | 02-concurrency.md |
| G-26 | Quality gate: reject consumer without `onOverwrite` | 05-consumers.md |
| Inv 12 | Watchdog captures session-token at arm | 02-concurrency.md |

### 6.3 File-map highlights

| Concern | File | Owner |
|---|---|---|
| Public API surface | `CameraEngine.swift` | Engine actor |
| AVFoundation session | `CameraSession.swift` | `sessionQueue` |
| Sample-buffer delegate | `CaptureDelegate.swift` | delivery queue, nonisolated |
| Metal command graph | `MetalPipeline.swift` | engine actor + delivery queue (completion) |
| Consumer fan-out | `PixelSink.swift` | `ConsumerRegistry` actor + C++ pool |
| Still capture | `StillCapture.swift` | engine actor |
| Recording | `Recording.swift` | engine actor + background task |
| Recovery | `RecoveryCoordinator.swift` | engine actor |
| Watchdog pair | `Watchdog.swift` | poll task + delivery-queue refresh |
| SwiftUI root | `CameraView.swift` | @MainActor |
| View model | `ViewModel.swift` | @Observable @MainActor |
| Pure helpers | `CalibrationCompute.swift`, `SettingsCoupling.swift`, `UniformStorage.swift` | stateless |

### 6.4 Glossary

- **Scaffold**: `// scaffolding:NN:kebab-slug` inline marker for temporary code retired by a named later stage.
- **TESTABLE / HITL / DEFERRED**: test-evidence categories (see `implementation/briefs/README.md`).
- **Three-layer sandwich**: the View → VM → Engine composition (ADR-01). Not to be confused with the "three-layer sandwich anti-pattern" (ADR-01's negative term for an unnecessary coordinator layer between them).

---

*End of report.*
