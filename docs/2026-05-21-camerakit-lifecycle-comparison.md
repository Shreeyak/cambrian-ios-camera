# CameraKit Lifecycle — Comparison Against the Field

**Date:** 2026-05-21
**Status:** Reference analysis (companion to `docs/superpowers/specs/2026-05-21-camerakit-lifecycle-ownership-design.md`)
**Question:** How does CameraKit's lifecycle-ownership design compare to the canonical and most-mature open-source iOS camera implementations?

## What was compared

Three reference implementations, read at source (not from secondary summaries):

| Repo | Version / commit | Posture |
|---|---|---|
| **Apple AVCam** (actor-based "Building a camera app") | mirror, commit `8f731b9` | iOS 18, Swift 5, strict concurrency = **minimal**; `actor CaptureService` |
| **NextLevel** | `v0.19.0`, HEAD `763fb55` | iOS 16, Swift 6 mode, StrictConcurrency upcoming; `class … @unchecked Sendable` (no actor) |
| **MijickCamera** | `v3.0.3`, commit `0f02348` | iOS 14, Swift 6 mode, `@MainActor` throughout (no actor, no session queue) |

**Method.** One subagent per repo extracted, as verbatim code + `file:line`, how each handles seven fixed axes (observation locus, decision mechanism, background/foreground, the interruption begin/end pair, `startRunning` threading, concurrency/rapid-change handling, host API surface). The subagents were given **no** knowledge of our design, to avoid confirmation bias. Synthesis below is mine.

## Matrix

| Axis | Apple AVCam (actor) | NextLevel | MijickCamera | **CameraKit (ours)** |
|---|---|---|---|---|
| **App-lifecycle observation** | App layer; `scenePhase`→`syncState` only, no session action | Library self-observes (own `UIApplication` observers) | None — SwiftUI `onAppear`/`onDisappear` | **Host observes, forwards phase enum** |
| **Device-interruption observation** | Inside the actor (async notif streams) | Inside library (own observers) | Only `wasInterrupted`; **no `…Ended`** | Inside package (`CameraSession`) |
| **Decision mechanism** | Notif loops + `isInterrupted` bool | `@objc` selectors + 1 flag | Direct calls on view appear/disappear | **Declarative reconcile (target table, no flags)** |
| **`stopRunning` on background?** | **No** — relies on OS interrupt | **No** — pauses recording only | No (stops on view-disappear) | **Yes** — ordered disarm→finalize→drain→stop |
| **`interruptionEnded` → restart?** | Sets bool; **OS** auto-resumes, no self-restart | Resumes *recording* after 0.1 s; checks `isRunning`, **not app state** | **No handler at all** | **Reconciles vs `currentPhase`** (stays stopped if backgrounded) |
| **Recording finalize on background** | None (user-stop only) | `pause()` recording | None before teardown (corrupt-file risk) | **Explicit finalize w/ timeout + bg-task** |
| **`startRunning` off-main** | Yes (actor serial executor) | Yes (`_sessionQueue`) | Questionable — no dedicated queue; buffers on `.main` | Yes (sessionQueue, ADR-07) |
| **Stale / rapid-change guard** | None (serial only) | None (serial; unlocked flag) | None (setup/cancel can race) | **latest-intent-wins (gen/single-flight)** |
| **Host lifecycle wiring** | Observe `scenePhase`→`syncState` | **None** (auto) | **None** (auto, via view) | Observe + forward `setLifecyclePhase` |
| **Concurrency posture** | Swift 5, strict = *minimal* | Swift 6, `@unchecked Sendable` | Swift 6, `@MainActor` | Swift 6, strict = *complete*, actor |

## Findings

**1. The ownership split isn't novel; our *consumer-agnostic* version is.** Apple observes device interruptions in the actor (like us) but has essentially no app-lifecycle→session path — `scenePhase` only triggers `syncState()` (`AVCamApp.swift:31-36`); it leans entirely on OS interruption. NextLevel observes app lifecycle *itself* (`addApplicationObservers`, `NextLevel.swift:3215-3217`). Mijick uses SwiftUI view lifecycle. Ours is the only one that decouples app-lifecycle observation from the package via a forwarded phase — driven by a requirement none of them face: serving a SwiftUI host **and** a Flutter plugin across the UIScene migration. Right for our constraints, not universally better.

**2. Nobody stops the session on background.** The two most authoritative references — Apple's own sample and the most-mature third-party lib — both leave the session "running" and trust the OS `videoDeviceNotAvailableInBackground` interruption to stop frames, with OS auto-resume on return. We explicitly `stopRunning`. This is our single biggest divergence (see "Open question").

**3. Our reconciliation / latest-intent-wins / restart guards are absent from all three — because all three are simpler.** They have no GPU submission gate, no stall watchdogs, no active recovery coordinator that re-issues `startRunning`, and they don't stop the session on background. Those features are exactly what *create* the multi-fact-consistency, staleness, and restart-into-background problems our guards solve. A library with one fact ("running?") and OS-delegated resume **cannot** have the bugs our guards prevent. The correct claim is "our guards are required by our capability set" — not "they missed these bugs."

**4. The restart-into-background guard, precisely located in the field:**
- **Mijick** can't have it — no `interruptionEnded` handler exists (`rg "interruptionEnded" Sources/` → nothing); it never self-resumes.
- **Apple** can't have it — its `interruptionEnded` body is literally `isInterrupted = false` (`CaptureService.swift:552-554`); it never calls `startRunning`, so the OS only resumes when foregrounded.
- **NextLevel** has the **milder cousin**: on `interruptionEnded` it resumes *recording* after 0.1 s, gated on `self.isRunning && !self._recording` (`NextLevel.swift:3325`) — checking session state but **not app state** (a latent "resume recording while backgrounded").
- **Ours** is the only one that actively restarts the *session* via recovery, so the only one that needs — and has — an explicit app-phase check on that restart.

**5. Where we just match best practice** (validation we're not over-rotating): off-main `startRunning` (Apple, NextLevel), actor + serial executor (Apple, `CaptureService.swift:68-73`), package-owned device-interruption observation (Apple), observe-streams-public / drive-methods-internal (NextLevel exposes AsyncStream events + delegate to observe, `start`/`stop` to drive). We are *ahead* of Apple's sample on concurrency posture — it ships Swift 5 / strict = minimal; we are Swift 6 / strict = complete.

**6. Primary source corrected the research.** A secondary summary claimed NextLevel "handles audio interruption distinctly (bug #281)." The code has **no** `AVAudioSession.interruptionNotification` handler — it delegates to `automaticallyConfiguresApplicationAudioSession` (`NextLevel.swift:763`). Reading the code beat the summary.

## Open question this raises

**Do we need to `stopRunning` on `.background` at all?** Apple and NextLevel don't — they finalize/pause recording (or nothing) and let the OS interruption own the session stop *and* resume. Our field-guide bug catalog (`docs/ios-camera-lifecycle.md` §2–§6) is the counter-evidence for *our* app, and the explicit stop buys deterministic teardown ordering for recording-finalize + GPU drain + watchdog disarm. But because **Apple's own sample does the opposite**, any reviewer will ask "why not just let the OS interrupt, like AVCam?" That rationale is not currently in the design's *Rejected / parked* section (only the narrower "run session only in `.active`" rejection is).

## Proportionality (the honest capstone)

Measured against these libraries our design is far heavier — and that weight is justified *only* by features they lack and we require: a custom per-frame Metal pipeline (the references use system-managed `AVCaptureVideoPreviewLayer`, gated by the OS for free), cheap-pause via the GPU gate, active stall recovery, recording-finalize correctness, and a multi-host (SwiftUI + Flutter) surface. If any of those features were in doubt, this comparison would argue for simplification. Since they are not, the engineering is proportionate to constraints the references do not carry.

## Simplification follow-up (deferred — decided 2026-05-21)

Finding 3 cuts both ways: the references avoid our coordination machinery because they actuate ~one fact (session running) and let the OS + frame-flow carry the rest. We can adopt most of that **without surrendering features**, by demoting the GPU gate and the watchdog from *actuated facts* to *derived reads* over authoritative state. **Decision: ship the current additive design's lifecycle surface first; pursue this structural simplification as a separate, measured follow-up** (it reaches into the Metal frame path and the watchdog's arming trigger, so it benefits from landing against a known-good baseline).

**Keystone:** coordination cost scales with the *number of independently-actuated facts*, not the facts themselves. Today we actuate three (gate, watchdog, session) and need reconciliation + latest-intent-wins + the `osOwnsDevice` arm-guard + the third actuation site purely to keep them consistent across `await`s.

**The move:**
- **GPU gate → per-frame read.** The frame path reads a `currentPhase` atomic mirror (`== .active`) instead of the reconciliation *writing* a gate atomic. Today `submissionGate` is read once (`MetalPipeline.swift:589`) but written ~10× across `CameraEngine` lifecycle methods; those writes collapse to the single write in `setLifecyclePhase`. The atomic already has the right shape (`nonisolated … ManagedAtomic<Bool>`, `CameraEngine.swift:93`) — a 1:1 repurpose, not a new mirror. "Gate-first" sequencing becomes "write the phase atomic first" — free.
- **Watchdog → frame-driven.** Arms on the first delivered frame via the existing `nonisolated tickFrame()` (`CameraEngine.swift:599`) plus a startup deadline armed by the session actuator (to catch "started but no first frame ever"); the per-phase arm/disarm sites (`:309 :797 :1854` / `:395 :766 :1824 :1846`) collapse. (Promotes the design's parked review-A S3.)

**What then collapses:** latest-intent-wins → a level-triggered session actuator (reconcile-to-fixpoint over one fact, no generation counter); the `osOwnsDevice` *arm-guard* → gone (a frame-armed watchdog can't arm with no frames; `osOwnsDevice` survives only as a *read* in the actuator); the third actuation site / F4 → no longer special (OS recovery pokes the same actuator, which reads `currentPhase`).

**Irreducible (the ceiling — this simplifies coordination, not capability):** session start/stop is a real ~410 ms actuation (the one reconciled fact); recording-finalize stays a committed sub-action with an ordering precondition before `stop`; the `currentPhase` atomic mirror is still a parallel atomic (1:1 swap of today's gate atomic, not a free move); the cheap-pause `.active`/`.inactive` boolean survives (as a read); `shouldDeferCommandLabel` (+ `.opening` rider) survives untouched (it governs the `SessionState` label FSM, not gate/watchdog). The root reason a gate exists at all is our custom per-frame Metal pipeline — the references get an OS-gated `AVCaptureVideoPreviewLayer` for free.

The "do we even need to `stopRunning` on background?" open question above is naturally reconsidered as part of this deferred work (it revisits teardown ordering regardless).

## Appendix — key evidence

**Apple AVCam** (`AVCam/`):
- `CaptureService.swift:552-554` — `interruptionEnded` body is only `isInterrupted = false`; no restart.
- `CaptureService.swift:68-73` — `actor CaptureService` with a custom `DispatchSerialQueue` executor (off-main session work).
- `CaptureService.swift:108`, `:563` — the only `startRunning` sites: initial `start(with:)` and the `mediaServicesWereReset` runtime-error path.
- `AVCamApp.swift:31-36` — `scenePhase`→`syncState()` only; never start/stop.

**NextLevel** (`Sources/NextLevel.swift`):
- `:3215-3217` — `addApplicationObservers` subscribes only `willEnterForeground` + `didEnterBackground`.
- `:3225-3234` — `didEnterBackground` pauses recording if recording; `willEnterForeground` is a no-op stub.
- `:3310-3331` / `:3325` — `interruptionEnded` resumes recording gated on `isRunning && !recording`; no app-state check.
- `:575-576` — `_sessionQueue` serial, `.userInteractive`, targets global.

**MijickCamera** (`Sources/`):
- `CameraManager+NotificationCenter.swift:22-29` — only `AVCaptureSessionWasInterrupted` observed; handler turns light off + resets video-output timer.
- `CameraManager.swift:128-134` + `CaptureSession+AVCaptureSession.swift:25-28` — `cancel()` → `stopRunningAndReturnNewInstance()` discards the session on view-disappear.
- `CameraManager.swift:89` — sample-buffer delegate on `queue: .main`.
