# Startup UI lag / jitter investigation — 2026-05-28

**Status:** Localized, root cause NOT yet identified. Parked for a dedicated drill-down.
**Severity:** UX — visible jank for the first ~15s after launch. No crash, no data loss.
**Build:** Release config, physical iPad (Shreeyak's iPad Pro 11", iOS 26.4.2),
bundle `com.cambrian.eva-swift-stitch`.
**Run analyzed:** session started `2026-05-28 13:07:54 +0000` (the only run today).
**Raw log:** `docs/startup-ui-lag-2026-05-28-camerakit.log` (full snapshot, 7 sessions;
the relevant one is the last, embedded below).

---

## 1. Symptom (as reported)

App feels laggy for the initial ~30s after launch; camera preview frames are
**jittery**. Reporter explicitly noted it did **not** look like the standard
degraded-fps-from-high-exposure-time behavior they're already familiar with.

## 2. Headline finding — two *separate* mechanisms overlap

The "laggy first ~30s" is actually **two distinct problems** running concurrently
during startup (measured window is ~15s, not 30s):

| # | Mechanism | Observable | Likely user-perceived effect |
|---|-----------|-----------|------------------------------|
| 1 | **Main-thread hitches** | 30fps display-link `MTKView` misses callbacks; draw gaps of 0.5–1.8s while `isPaused=false` | The **jitter / lag** (random freezes) |
| 2 | **Camera AE hunting** | Auto-exposure hunts for ~13s; frame delivery averages ~18.7fps then snaps to 30fps | The **fps reduction** (partly the known exposure effect, but prolonged) |

Mechanism **#1 is the new/interesting one** and the most likely cause of the
"jitter that isn't just low fps." Mechanism #2 is real camera behaviour and
overlaps the exposure effect the reporter already knows about.

---

## 3. Evidence

### 3a. Frame delivery rate (from `[consumers] yield: frame=N` markers, logged every 300 frames)

```
frame 0   @ 18:37:58.852
frame 300 @ 18:38:14.883   →  300 frames in 16.03s  =  ~18.7 fps
frame 600 @ 18:38:24.895   →  300 frames in 10.01s  =  ~30.0 fps
```

First ~16s ran at ~18.7fps, then snapped to a clean 30fps. The recovery to 30fps
lands ~2s after AE stops hunting (see 3c).

### 3b. Main-thread hitches (from `[metal] [resume] draw loop resumed … gap=Xms`)

The preview `MTKView` is configured for **continuous** rendering:
`isPaused=false`, `enableSetNeedsDisplay` unset (defaults `false`),
`preferredFramesPerSecond = 30` → its internal `CADisplayLink` calls
`draw(in:)` every ~33ms on the **main thread**. The log line fires only when two
consecutive `draw(in:)` calls are >200ms apart.

During the active streaming window (`isPaused` was `false` the whole time — last
toggle to `false` at `:58.543`, next toggle at `:38:25` for backgrounding), the
draw loop stalled five times:

```
gap=526ms  @ :59.092
gap=1844ms @ 18:38:02.812   ← ~1.8s freeze
gap=268ms  @ :05.204
gap=307ms  @ :08.177
gap=360ms  @ :08.538         ← last hitch; main thread smooth after ~10s
```

A 1844ms gap at 30fps = ~55 missed display-link callbacks.

**Why this is certainly main-thread starvation (not GPU/drawable exhaustion):**
in `eva-swift-stitch/UI/CameraView.swift`, `draw(in:)` updates `lastDrawMs = nowMs`
at **line 735**, which is **before** the `guard let drawable = view.currentDrawable
else { return }` at **line 736**. So `lastDrawMs` advances on *every* CADisplayLink
tick regardless of drawable availability. A >200ms gap therefore means the
callback *did not fire at all* for that duration — i.e. the main run loop /
display link was blocked — not that it fired but found no drawable.

> Note: the first logged `gap=3435ms` (@ `:58.566`) is **not** a hitch — it is a
> paused-window artifact. The view was `isPaused=true` from `:55.154` to `:58.545`
> (scenePhase inactive during the permission dialogs); `lastDrawMs` is stale from
> before the pause, so the first draw after un-pausing reports the paused duration.
> It is excluded from the hitch list above.

### 3c. Camera AE hunting (from `[engine] [ae] converged (t2) after Xms searching`)

Eleven AE convergence cycles between `:59.094` and `:38:12.958`, several
"searching" for 1.3–1.9s:

```
:59.094  after 12ms
:38:03.662 after 854ms
:38:04.720 after 1018ms
:38:05.468 after 264ms
:38:06.033 after 529ms
:38:07.490 after 1340ms
:38:09.558 after 1938ms
:38:10.290 after 497ms
:38:10.850 after 335ms
:38:12.257 after 679ms
:38:12.958 after 321ms   ← last AE event; fps recovers to 30 shortly after
```

This is the camera's own auto-exposure genuinely hunting (the `startAEMonitor`
KVO observer at `CameraEngine.swift:1800` is a passive logger — it does **not**
cause the lag; it just records when `isAdjustingExposure` flips). Variable
exposure during hunting can vary frame duration → contributes to the ~18.7fps.

### 3d. Phase timeline

| Phase | Window (approx) | Main-thread hitches | AE | Delivery fps |
|-------|-----------------|---------------------|-----|--------------|
| 1 | `:58.5`–`:08.5` (~10s) | Yes (526/1844/268/307/360ms) | hunting | ~19 |
| 2 | `:08.5`–`:12.9` (~4.5s) | None | still hunting | ~19 |
| 3 | after `:12.9` | None | settled | 30 (smooth) |

The permission-dialog scenePhase chatter (active↔inactive at
`:54.802 / :54.861 / :55.156 / :58.545`, driven by the camera-permission prompt
at `:54.799` and the photos prompt at `:58.116`) all lands **before** `:58.545`,
so it does **not** explain the post-`:58.5` hitches. The hitches are intrinsic to
the **streaming-startup path**.

---

## 4. Open question (the actual root cause)

The log can **localize** the problem — "main thread blocked 0.5–1.8s repeatedly
during the first ~10s of streaming" — but it **cannot identify what is blocking
it**. That requires profiling (see §6).

### Candidate causes (unranked hypotheses — any pick from here is a guess)

- SwiftUI view-body churn from the scenePhase + camera-state cascade at startup.
- Lazy first-use Metal pipeline-state (PSO) compilation on a main-actor path.
- The SwiftUI `.task(id:)` scheduler under load during resume.
- `Bundle.module` resource loads on first access.
- OpenCV / C++ first-call initialization (Release links the real OpenCV xcframework).

---

## 5. Key code references

- `eva-swift-stitch/UI/CameraView.swift:659` — `makeUIView` (MTKView config:
  `isPaused`, `preferredFramesPerSecond = 30`, no `enableSetNeedsDisplay`).
- `eva-swift-stitch/UI/CameraView.swift:727` — `draw(in:)`; `lastDrawMs` at :735
  precedes the drawable guard at :736 (the starvation-vs-exhaustion discriminator).
- `eva-swift-stitch/UI/CameraView.swift:731` — `draw loop resumed … gap=` log.
- `CameraKit/Sources/CameraKit/CameraEngine.swift:1800` — `startAEMonitor`
  (passive AE KVO observer; emits the `[ae] converged … searching` line at :1817).
- `CameraKit/Sources/CameraKit/CaptureDelegate.swift:84` — `delivery frame (t1)` log.
- `CameraKit/Sources/CameraKit/CameraEngine+Lifecycle.swift:108,186` — resume
  cascade (`gate opened`, `startSessionIfNeeded`).

---

## 6. Suggested next steps (pick one when drilling in)

1. **Add `os_signpost` timing + re-run (cheapest code-side path).**
   Wrap `os_signpost` intervals around the prime suspects on the main-actor
   startup path (SwiftUI view body, `CameraView` creation, the resume cascade in
   `CameraEngine+Lifecycle`). Re-run once; the next file log (or Instruments
   points-of-interest) shows which interval contains the 1844ms gap. No
   Instruments session required.

2. **Instruments Time Profiler / Hangs trace over USB (definitive).**
   Capture the first ~20s after launch. The Hangs template overlays main-thread
   blocks ≥250ms automatically — every logged gap above would appear as a
   labeled hang with a call stack. USB capture is **unaffected** by the iOS 26.4
   WiFi-logging breakage that forces the file-sink workaround for normal logs.
   This is the single most discriminating evidence.

3. **Narrow candidates from code first (no re-run).**
   Read the startup paths (app `init`, `CameraView` body/`updateUIView`,
   `CameraEngine+Lifecycle` resume) to shortlist the likely main-thread blockers
   before instrumenting. Cheaper, but not definitive on its own.

Recommended order: **#2 if a USB Instruments session is convenient** (definitive,
no code change); otherwise **#1** (autonomous, answers via the next file log).

---

## 7. Relevant log section (verbatim — session `2026-05-28 13:07:54 +0000`)

Local-time prefixes in the file are device wall-clock; the UTC marker on the
`session started` line is authoritative. Full file:
`docs/startup-ui-lag-2026-05-28-camerakit.log`.

```
18:37:54.221 === CameraKit session started 2026-05-28 13:07:54 +0000 ===
18:37:54.799 [engine] open: requesting camera permission
18:37:54.802 [scenePhase] scenePhase: active → inactive
18:37:54.858 [metal] [resume] updateUIView isPaused true→false lane=natural
18:37:54.861 [scenePhase] scenePhase: inactive → active
18:37:55.154 [metal] [resume] updateUIView isPaused false→true lane=natural
18:37:55.156 [scenePhase] scenePhase: active → inactive
18:37:58.116 [engine] open: photos auth status=3
18:37:58.352 [engine] [resume] startSessionIfNeeded — issuing startRunning
18:37:58.352 [engine] open: pipeline ready — 4032×3024 pool=0x107ed8180
18:37:58.543 [metal] [resume] updateUIView isPaused true→false lane=natural
18:37:58.545 [scenePhase] scenePhase: inactive → active
18:37:58.545 [engine] [resume] gate opened (t0b)
18:37:58.566 [metal] [resume] draw loop resumed lane=natural gap=3435ms
18:37:58.567 [metal] [resume] on-screen new frame lane=natural
18:37:58.801 [engine] [resume] delivery frame (t1) pts=3196.871s actual=4032x3024 pf='420f'
18:37:58.823 [metal] [resume] first commit after gate (t1b)
18:37:58.852 [consumers] yield: frame=0 stream=0 surface=true cppConsumers=0
18:37:58.852 [consumers] yield: frame=0 stream=1 surface=true cppConsumers=0
18:37:58.852 [metal] [resume] first texture stored (t1c) — preview texture live
18:37:59.092 [metal] [resume] draw loop resumed lane=natural gap=526ms
18:37:59.093 [metal] [resume] on-screen new frame lane=natural
18:37:59.094 [engine] [ae] converged (t2) after 12ms searching
18:38:02.812 [metal] [resume] draw loop resumed lane=natural gap=1844ms
18:38:02.885 [metal] [resume] on-screen new frame lane=natural
18:38:03.662 [engine] [ae] converged (t2) after 854ms searching
18:38:04.720 [engine] [ae] converged (t2) after 1018ms searching
18:38:05.204 [metal] [resume] draw loop resumed lane=natural gap=268ms
18:38:05.402 [metal] [resume] on-screen new frame lane=natural
18:38:05.468 [engine] [ae] converged (t2) after 264ms searching
18:38:06.033 [engine] [ae] converged (t2) after 529ms searching
18:38:07.490 [engine] [ae] converged (t2) after 1340ms searching
18:38:08.177 [metal] [resume] draw loop resumed lane=natural gap=307ms
18:38:08.178 [metal] [resume] on-screen new frame lane=natural
18:38:08.538 [metal] [resume] draw loop resumed lane=natural gap=360ms
18:38:08.570 [metal] [resume] on-screen new frame lane=natural
18:38:09.558 [engine] [ae] converged (t2) after 1938ms searching
18:38:10.290 [engine] [ae] converged (t2) after 497ms searching
18:38:10.850 [engine] [ae] converged (t2) after 335ms searching
18:38:12.257 [engine] [ae] converged (t2) after 679ms searching
18:38:12.958 [engine] [ae] converged (t2) after 321ms searching
18:38:14.883 [consumers] yield: frame=300 stream=0 surface=true cppConsumers=0
18:38:14.884 [consumers] yield: frame=300 stream=1 surface=true cppConsumers=0
18:38:24.895 [consumers] yield: frame=600 stream=0 surface=true cppConsumers=0
18:38:24.896 [consumers] yield: frame=600 stream=1 surface=true cppConsumers=0
18:38:25.403 [metal] [resume] updateUIView isPaused false→true lane=natural
18:38:25.415 [scenePhase] scenePhase: active → inactive
18:38:26.754 [scenePhase] scenePhase: inactive → background
18:38:26.987 [engine] [interruption] ended=false reason=videoDeviceNotAvailableInBackground rawReason=1 keys=["AVCaptureSessionInterruptionReasonKey"]
18:38:26.987 [engine] [interruption] entering .interrupted (raw=1)
18:38:26.987 [engine] [interruption] ended=true reason=unknown(-1) rawReason=-1 keys=[]
18:38:26.988 [engine] [resume] interruption ended (t0) — reconciling against currentPhase
```
