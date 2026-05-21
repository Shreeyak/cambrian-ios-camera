# Lifecycle ownership — device HITL evidence (2026-05-21)

Device: Shreeyak's iPad Pro 11" (2nd gen, iPad8,9), iOS 26.4.2.
Build: worktree `lifecycle-analysis` @ `deb98c8` (host migrated to
`setLifecyclePhase`), deployed via `build_run_device`.
Logs: `Documents/camerakit.log` via `CameraKitLog.enableFileLogging()`, pulled
with `scripts/device-log-live.sh` (the `ipad-logs` skill). Sessions
`2026-05-21 15:34/15:37/16:05 UTC`.

## Scenarios & results

| # | Scenario | Result |
|---|---|---|
| 1 | Cold launch, foregrounded | ✅ Preview live (sub-second; exact ≤1s to re-confirm) |
| 2 | Foreground → background → foreground (short and >5 s) | ✅ Preview returns; resumes very quickly; camera LED off while backgrounded |
| 3 | Start recording → background mid-recording → foreground | ✅ `.mp4` lands in Files, **uncorrupted** (finalize-before-stop) |
| 4 | Control Center pull-down → dismiss | ⚠️ Preview resumes, no error dialog, but user reports a **prominent >500 ms (up to ~1000 ms) preview freeze** on every dismiss. Pipeline delivery→mailbox of the *first* frame is fast (43–92 ms, instrumented), but on-screen frame arrival / steady delivery after resume is **not yet measured** — host-side cadence instrumentation added; re-measure pending (see below). |
| F4 | Camera-off on background **launch** | Not separately reproduced (needs launch-into-background); structurally guaranteed by `initialPhase: .background` + reconcile-against-`.background`, the same mechanism verified in #2/#3. Defer observable check to natural occurrence. |

No off-map transitions, no spurious recovery, no crashes, no errors in any
`2026-05-21` HITL session (the only recovery/error log lines are from an earlier
`12:04` unit-test session with deliberate `error=boom`/`hw` injection).

## Control Center resume — measured (instrumented build)

Resume-latency instrumentation added across the pipeline (all greppable on
`[resume]`): `updateUIView isPaused→false` (≈true t0, synchronous on the SwiftUI
update pass), `gate opened (t0b)`, `draw loop resumed gap=Nms`, `first frame
(t1)`, `first commit after gate (t1b)`, `first texture stored (t1c)` — plus the
pre-existing `startSessionIfNeeded` marker (absent ⇒ no session restart) and
`[ae] converged (t2)`.

### Measured: 3 pure-`.inactive` CC cycles (session `22:13:37`)

t0 = `updateUIView isPaused→false`, the synchronous moment CC begins dismissing.
Offsets in ms from t0:

| Marker | Cycle 1 | Cycle 2 | Cycle 3 |
|---|---|---|---|
| t0 — updateUIView un-pause (abs) | 22:21:58.694 | 22:22:00.717 | 22:22:03.598 |
| scenePhase→active (`.task` ran) | +7 | +7 | +7 |
| gate opened (t0b) | +7 | +7 | +13 |
| draw loop resumed | +18 | +26 | +16 |
| first frame delivered (t1) | +62 | +32 | +14 |
| first commit (t1b) | +64 | +32 | +15 |
| **texture live (t1c)** | **+92** | **+53** | **+43** |

**The camera-pipeline resume is 43–92 ms to pixels-live. No 500 ms delay exists
in the measured `.inactive` path.** Ruled out by these traces:

- **No `[interruption]`** — all 3 cycles were pure `.inactive`
  (active→inactive→active); CC did **not** fire an AVF interruption this run.
- **No `startSessionIfNeeded`** — session never stopped; no ~400 ms restart.
- **No `[ae] converged`** — AE did not re-search; exposure stayed stable.
- `.task(id:)` latency ~7 ms; draw-loop restart 16–26 ms; AVF delivery-resume
  (t0b→t1) 1–55 ms.
- `draw loop resumed gap=1504/1534/1705ms` is the **CC-open duration** (draw loop
  paused while occluded), NOT a resume delay.

### Update — on-screen arrival NOT measured; pipeline NOT exonerated

A first read of these timings suggested the pipeline was exonerated (texture live
in 43–92 ms) and the perceived lag was the CC dismiss animation. **That was
premature.** `t1c` measures only when the pipeline stores the texture into its
mailbox (`_latestNaturalBgra8Tex`); the host draw loop reads that mailbox live
(`DisplayViewModel.naturalTex:36` is a computed forwarder to
`engine.currentTexture()`), but **when a fresh frame actually reaches the screen —
and whether AVF delivery stays continuous after the first frame — was never
measured.** On 2026-05-21 the user reported the preview freeze is real, prominent,
and **>500 ms (sometimes ~1000 ms)** on every CC dismiss. That is primary evidence
the lag lives downstream of `t1c` (mailbox→screen) and/or that AVF delivers one
frame then stalls — neither of which the current markers capture. The 43–92 ms
figures stand for what they measure (delivery→mailbox of the *first* frame); they
do not characterize steady on-screen resumption.

Next instrumentation (host-side, per user request): a draw-loop **on-screen
cadence** probe (logs each fresh on-screen frame for ~20 frames after a resume —
the true "preview visible" time vs t0) + a CaptureDelegate **delivery cadence**
probe (logs the first ~20 delivered frames — is AVF continuous, or one-frame-then-
stall?). Overlaying delivery vs on-screen timestamps localizes the stall:
delivery-stall ⇒ AVF throttle; delivery-continuous-but-on-screen-stall ⇒
draw/present; both-continuous ⇒ compositor/animation. Re-measure pending.

The interruption path remains a separate, heavier path (earlier trace below).

Earlier interruption-path trace (a separate, heavier path, for reference):

```
21:30:50.928 [scenePhase] scenePhase: active → inactive          # CC down
21:30:50.941 [consumers] yield: frame=21300 ...                  # frames still flowing
21:30:52.023 [engine] [interruption] ended=false rawReason=1     # AVF interrupts (camera unavailable)
21:30:52.025 [engine] [interruption] entering .interrupted
21:30:52.202 [scenePhase] scenePhase: inactive → active          # CC dismissed
21:30:52.203 [engine] [lifecycle] skipping command label from=interrupted to=streaming
             caller=reconcile() (deferring to OS-owned state)    # F2 guard fires — don't fight the OS
21:30:52.255 [engine] [interruption] ended=true rawReason=-1
21:30:52.257 [engine] [interruption] ended — reconciling against currentPhase   # Task 8 OS→phase
21:30:52.683 [consumers] [metrics] window emit ... natural=0/0   # metrics tick: ZERO frames — NOT resume (frame log is sampled ~every 300 frames; next sampled frame ~20s later)
```

## Background-during-use (representative)

```
21:31:20.367 scenePhase: active → inactive
21:31:21.656 scenePhase: inactive → background
21:31:21.927 [interruption] ended=false rawReason=1              # OS interrupts on background
21:31:21.928 [interruption] entering .interrupted
21:31:21.928 [interruption] ended=true                           # ends immediately while backgrounded
21:31:21.928 [interruption] ended — reconciling against currentPhase   # currentPhase=.background → stays stopped
21:31:29.800 scenePhase: background → inactive                   # resume: session restarts at .inactive
21:31:30.006 scenePhase: inactive → active                       # gate opens at .active
```

Rapid scenePhase bounces (e.g. `21:33:20–28`, repeated `active↔inactive`)
produced no off-map / recovery — latest-intent-wins (F1) holds on device.

## On-device confirmations of the new model

- New reconcile path is live (no legacy `[bgsuspend]`/`[bgresume]` logs; the host
  forwards via `setLifecyclePhase` — `scenePhase: prev → next`).
- F2 `osOwnsDevice` deferral fires during the CC interruption (log above).
- Task 8 OS→phase reconcile runs on every `interruption ended`.
- Recording across a background produced a playable `.mp4` (user-confirmed).

## CC resume — on-screen cadence measured (session `22:34:33`, 2 cycles)

Added host-side probes: `[resume] on-screen new frame` (a *fresh* texture, by
identity, blitted in `MTKViewCoordinator.draw(in:)`), `[resume] on-screen frame
presented (GPU done)` (the host draw command buffer's completion handler, first 3
frames), and a per-frame `[resume] delivery frame` cadence (first 20). t0 =
`updateUIView isPaused→false`.

| Marker | Cycle A (22:36:19) | Cycle B (22:36:23) |
|---|---|---|
| t0 — updateUIView un-pause | 19.046 | 23.478 |
| gate opened (t0b) | +8 ms | +7 ms |
| **first fresh on-screen frame** | **+13 ms** | **+19 ms** |
| first GPU-present done | +19 ms | +24 ms |
| on-screen cadence after | ~33 ms (30 fps), continuous ~740 ms | ~33 ms, continuous |

**Measured app-side result: fresh frames reach the drawable and GPU-present
completes within ~13–19 ms of CC dismiss, then flow continuously at 30 fps.** No
app-side >500 ms gap in delivery, blit, or present.

**CONFLICT (resolved below — see Resolution):** the user is confident the visible
preview freeze is prominent and **>500 ms (sometimes ~1000 ms)** on every CC
dismiss. The app-side measurement says the opposite. Two things must be resolved
before concluding:

1. **Probe-validity caveat (the `as AnyObject` trap):** the "on-screen new frame"
   probe distinguishes a fresh texture from a re-blit via
   `ObjectIdentifier(texture as AnyObject)`. If that boxes a *new* identity each
   call, EVERY draw would falsely log as "new," faking continuous output. In this
   run delivery and draw were both ~30 fps, so the data **cannot** distinguish a
   correct probe from a boxed one. Must validate — e.g. a low-light reproduction
   where delivery (~15 fps, exposure-bound) ≠ draw (~30 fps): if on-screen cadence
   tracks delivery → probe correct; if it tracks draw → boxed/false.
2. If the probe is valid, the only remaining locus is the system compositor /
   Control Center dismiss animation (WindowServer), which app code can neither
   observe nor control — but that must be **shown**, not asserted (a frame-counter
   overlay rendered into the same drawable, or a screen recording, would be
   decisive). Do NOT assert the compositor conclusion until (1) is closed.

## Resolution — platform behavior (confirmed against Apple's Camera app)

2026-05-21: the user observed the **identical** delay in Apple's first-party
**Camera app** on the same iPad — the preview stays blurred/held for ~500–1000 ms
after dismissing Control Center before the live stream visibly resumes. An
independent reference implementation with the deepest camera-stack integration
showing the same latency closes the conflict: **the visible 500–1000 ms
preview-resume delay is iOS/iPadOS platform behavior, not a defect in CameraKit or
the host app, and not app-fixable** (Apple's own privileged app is subject to it).

This *reconciles* with the instrumentation rather than contradicting it. Three
independent signals show the app resumes fast underneath:
- **Delivery** (CaptureDelegate — counts delegate calls, no identity trap): AVF
  delivers from **+10 ms**, continuous at the exposure-bound rate. The session is
  never stopped on `.inactive` (gate-closed-but-running, ADR-09), so delivery
  never actually paused — it resumes instantly on gate reopen.
- **Mailbox** (completion handler, unambiguous): fresh preview textures stored
  from **+38 ms** (`t1c`).
- **On-screen** (draw loop): fresh textures blitted + GPU-presented from
  **+13–19 ms** — corroborated by the two unambiguous signals above, so the
  `as AnyObject` identity probe was *not* boxed after all.

The residual gap — fresh frames rendered at ~+20 ms but the last frame visibly
held ~500 ms (user: "frozen on last frame, then jumps"; **screen recording
ground truth: ~600 ms on both cycles** — CC dismissed 0.96 s → preview moved
1.56 s; and 4.8 s → 5.4 s, device shaking so motion was unambiguous) — is
**platform-level, downstream of the app's GPU-present** — specifically a **system
compositor snapshot** of the app during the CC transition (confirmed by the PTS
test in "Web corroboration" below: AVF delivers fresh frames 1:1 with wall-clock
throughout, ruling out stale content). Apple's Camera app shows the same hold; the
only app-level difference is cosmetic (Apple blurs; we hold the last frame).

**Optional follow-up (cosmetic, not a timing fix):** match Apple by
blurring/dimming the preview while `.inactive` (privacy + intentional look)
instead of holding the last frame. Does not change the system timing. Separate
small UI task if desired.

## Web corroboration + refined hypotheses (2026-05-21)

Web search confirms preview-resume latency after camera interruptions is a known,
widely-reported iOS phenomenon, not unique to this app:
- **Apple Developer Forums 811759** ("AVCaptureSession preview briefly goes
  empty"): preview blanks/holds for **~0.5–2 s** after interruptions (lock/unlock,
  camera switch); `AVCaptureSession.isRunning` stays `true` throughout —
  "isRunning == true does NOT guarantee frames are flowing." An
  AVCaptureVideoDataOutput probe in that thread showed **no sample buffers
  delivered** during the blank period; frames resume after ~1–2 s with no explicit
  restart. `AVCaptureVideoPreviewLayer` holds the last frame across the gap (which
  is what Apple's Camera app — the user's reference — visibly does).
- Related: forums 660034, 747978, 123812 — AVCaptureVideoDataOutput stalls /
  preview freezes after interruptions across iOS versions.

**Mismatch with our data (important — do not gloss):** our CaptureDelegate
delivery probe shows sample buffers delivered *continuously* at ~30 fps from
+25 ms through the whole ~600 ms window (our session is never stopped on
`.inactive`, ADR-09, so delivery never paused). The forum's exact mechanism
(delivery STOPS) therefore does not directly apply to us. Two hypotheses remain,
and the current logs cannot distinguish them because they only prove buffers
*arrive*, not that their *content* is fresh:
- **(A) Compositor snapshot:** AVF delivers *fresh* frames, the app blits +
  GPU-presents them, but the system shows a snapshot of the app over the live
  view for ~600 ms.
- **(B) Stale delivered content:** AVF delivers buffers at 30 fps but with
  *stale* content (steady interval, non-advancing capture), so the app faithfully
  blits a frozen image until real content resumes at ~600 ms (the forum's family
  of issues, but with buffers still arriving).

**RESOLVED — PTS measured (CC dismiss cycle `23:02:21.838`):** with PTS logged in
the delivery probe, the capture timestamp advances **1:1 with wall-clock** through
the whole window — pts `206988.770 → 206989.404`s (Δ 634 ms) over wall-clock
`21.844 → 22.486` (642 ms), ~33 ms/frame in lockstep. AVF delivers genuinely
**fresh** content the entire time. **(B) stale content is RULED OUT; (A) compositor
snapshot is confirmed by elimination:** fresh frames are delivered (PTS advancing),
rendered, and GPU-presented continuously from ~+6 ms, yet the recorded display
holds the last frame ~600 ms — the only remaining locus is the system compositor
showing a snapshot of the app during the Control Center transition. Consistent with
Apple's Camera app showing the identical hold and the forum reports above.
**Conclusion: iOS/iPadOS platform behavior, not an app defect, not app-fixable**
(only the cosmetic blur-vs-frozen treatment is within app control).

**Snapshot mechanism corroboration (web):** the system-snapshot path is
officially documented — Apple Technical Q&A **QA1838** ("Preventing Sensitive
Information From Appearing In The Task Switcher"): iOS captures a snapshot of the
app's window when it resigns active / backgrounds (taken immediately after
`applicationDidEnterBackground:` returns — hence Apple's warning not to start
animations there). Developer writeups on the privacy-window technique note this
snapshot/privacy view "appears as soon as you begin to open Notification Center or
Control Center" — i.e. the snapshot path engages on the CC transition itself.
*Directly sourced:* snapshot is captured on resign-active and shown during the
task-switcher / NC / CC transitions. *Inferred (well-supported, not a direct
Apple statement):* on dismiss (becoming-active) the snapshot is held ~600 ms until
the live view is restored — corroborated here by the app rendering fresh frames
underneath (PTS + on-screen logs) while the recording shows the held frame, plus
Apple's own Camera app exhibiting the same hold. WindowServer itself is not
observable from app code, so elimination + the documented mechanism is the
available standard of proof.

Sources: Apple Developer Forums threads
https://developer.apple.com/forums/thread/811759 ,
https://developer.apple.com/forums/thread/660034 ,
https://developer.apple.com/forums/thread/747978 ; Apple Technical Q&A QA1838
https://developer.apple.com/library/archive/qa/qa1838/_index.html ; app-switcher
snapshot writeup
https://hacknicity.medium.com/hide-sensitive-information-in-the-ios-app-switcher-snapshot-image-25ddc9b8ef5f .
