# Texture-bridge pull-cadence — empirical de-risk design

## Problem

Phase 3 of the CameraKit→Flutter migration must implement a zero-copy
`FlutterTexture` bridge on iOS. The Phase-2 handoff notes
(`2026-05-15-phase3-handoff-notes.md` §1) settled that:

- iOS Flutter's texture path is **pull**, not push (Android is push via
  `SurfaceProducer`). Flutter calls `FlutterTexture.copyPixelBuffer()` on its
  own vsync; the adapter returns a retained reference to the latest
  IOSurface-backed `CVPixelBuffer` for the lane.
- The seam already exists: `CameraEngine.currentPixelBuffer(stream:)`
  (`CameraEngine.swift:761`) is `nonisolated`, synchronous, and reads the live
  `Mailbox<CVPixelBuffer>` written by `MetalPipeline` on the delivery queue
  (`MetalPipeline.swift:566–585`).
- A frame-availability nudge: a one-Task-per-lane consumer subscribed to
  `consumers.subscribe(stream:)` calls `registry.textureFrameAvailable(id)` so
  Flutter knows to pull.

The pull-cadence model is the right *primitive* (Apple's iOS embedder offers
no push equivalent for arbitrary plugin-owned textures), but it has three
known failure modes that must be empirically characterized **before** Phase 3
commits to an implementation shape:

1. **Staleness — Flutter samples slower than CameraKit produces.** A slow
   Flutter frame (laid-out widget tree, GC pause, an off-thread blit on the
   raster thread) means a freshly-arrived buffer is skipped at one display
   refresh and only shown one vsync later. Visible as a "jerky" cadence even
   though the underlying capture frames arrived on time.
2. **Re-pull — Flutter samples faster than CameraKit produces.** Flutter's
   raster thread runs at 60 Hz on iPad; CameraKit produces at 30 Hz.
   Without gating, Flutter can pull the same `CVPixelBuffer` twice on
   consecutive vsyncs. Generally invisible on a static scene; if the camera
   is panning fast, the doubled vsync becomes the floor for perceived
   smoothness.
3. **Tearing — concurrent IOSurface read while GPU is writing.**
   `copyPixelBuffer()` returns a `CVPixelBuffer` whose IOSurface is being
   written by `MetalPipeline`'s Pass-1 / Pass-2 at the same instant Flutter's
   `CVMetalTextureCache` wraps it for sampling on the raster thread. CameraKit's
   own previews never observe tearing — but they sample inside the Metal
   command buffer that just rendered the lane, so synchronization is implicit.
   Flutter's wrap happens on a different command queue. Whether IOSurface
   read-vs-write across queues produces visible tearing on iPad GPUs is a
   question this experiment must answer; Apple's docs do not promise either
   way for the cross-process / cross-queue read-on-shared-IOSurface case.

The handoff notes' summary: *"Decide empirically on device; do not
over-engineer pre-emptively."* This spec scopes the experiment that decides.

## Goal

Empirically determine whether the naive pull-cadence path
(`copyPixelBuffer` returns `currentPixelBuffer(stream:)` directly,
`textureFrameAvailable` fires on every produced frame) is acceptable for the
production use case (camera preview at 30 fps, iPad). If acceptable, Phase 3
ships the simple version and records the experiment as evidence. If not,
Phase 3 spec includes the specific mitigation that was empirically necessary.

Time-box: **1 day**. If the experiment is inconclusive in 1 day, that itself
is a signal — see "Exit criteria" below.

Non-goals:

- Implementing the production bridge. This is a throwaway spike. Production
  bridge code lands in Phase 3 proper with the experiment's results as input.
- Deciding the RGBA16F → RGBA8 conversion question. A separate design doc
  covers that. The experiment can use whichever format is convenient (BGRA8
  is the path of least resistance for a synthetic source); the cadence
  question is format-independent.
- Real CameraKit integration. The experiment uses a synthetic frame source
  to keep the variable count low. Bringing in a full CameraKit session adds
  rendering load that can mask or amplify the very effects being measured.
- Android comparison. Side-by-side Android perf is a fallback escalation
  step, not part of the time-boxed first pass.

---

## Experiment shape

### The smallest possible Flutter+iOS app

A standalone Flutter app (not the production app, not `eva-swift-stitch`)
with a single screen showing one full-screen `Texture` widget. The native
side registers one `FlutterTexture` whose `copyPixelBuffer()` returns the
latest CVPixelBuffer from a synthetic source.

**Synthetic frame source:** a `CADisplayLink`-driven loop on a background
queue producing one IOSurface-backed `CVPixelBuffer` per tick at 30 Hz. Each
frame is a solid-color background + a large frame-counter number rasterized
into the buffer (text via `CGContext` is fine; perf doesn't matter for the
producer). The counter advances by exactly 1 per produced frame.

**Why a counter, not a gradient:** the counter is unambiguous in screen
recordings and per-frame logs. A gradient + clock works too, but a counter
collapses re-pull / skip detection to integer arithmetic.

**Why IOSurface-backed:** the experiment must exercise the same primitive
the production bridge will use. `CVPixelBufferCreate` with
`kCVPixelBufferIOSurfacePropertiesKey: [:]` produces an IOSurface-backed
buffer; pool the buffers to keep allocator noise out of the measurement.

**Why standalone:** wiring CameraKit into the experiment adds a moving part
(real capture cadence jitter, real Metal pipeline contention) that
contaminates the measurement. The question is *Flutter's display-side
behavior*, not CameraKit's production-side behavior. Decoupling matters.

### What the experiment runs

- iPad's display refresh is 60 Hz. Synthetic source produces at 30 Hz.
- Each produced frame triggers `registry.textureFrameAvailable(id)` on the
  main thread (Flutter's contract; the call itself is cheap).
- Flutter renders the `Texture` widget on every vsync (60 Hz) when the
  widget is on-screen.
- The raster thread eventually calls `copyPixelBuffer()` on the
  `FlutterTexture`; that call returns the latest synthetic buffer.

### What we instrument

Six counters, all incremented from the side that observes the event:

| Counter | Where incremented | What it measures |
|---|---|---|
| `producedCount` | synthetic-source tick | frames produced (target: 30/s) |
| `signalCount` | right after `textureFrameAvailable(id)` | nudges sent (target: 30/s, 1:1 with `producedCount`) |
| `pullCount` | inside `copyPixelBuffer()` | pulls received from Flutter |
| `pulledStamp` | inside `copyPixelBuffer()` (write to ring log) | which producer-frame number was returned, per pull |
| `widgetFrameCount` | Flutter Dart side, via `SchedulerBinding.addPostFrameCallback` | Flutter frames rendered (target: 60/s) |
| `firstPullLatencyNs` | producer→pull mailbox, computed per pull | wall-clock from frame produced to first pull that returned it (-1 if never) |

The native counters are flushed to a CSV in the app's Documents directory
once per second (cheap, off the hot path). Flutter side writes its widget
frame count to the same destination via a method-channel. The pulled-stamp
ring log is dumped at the end of the run.

### What we visually capture

A single 60-second screen recording on iPad of the running experiment app.
The counter is large, monospace, and contrasts the background. Manual review
of the recording at frame-by-frame in QuickTime answers two human-eye
questions the counters can't:

- Is there visible tearing? (a number "split" mid-digit — top half shows N,
  bottom half N+1)
- Is the cadence visibly jerky? (the counter visibly stalls then jumps,
  rather than incrementing smoothly twice per second)

### Run matrix

Three runs, ~60 seconds each:

1. **Baseline.** Just the texture widget, nothing else on screen. Measures
   the floor.
2. **Flutter-loaded.** Add a busy Flutter widget elsewhere on screen — an
   `AnimatedBuilder` driving a continuously-rebuilding subtree, or
   `ListView` with several thousand items being scrolled programmatically.
   Goal: starve the raster thread enough to force missed pulls and
   characterize what staleness looks like under realistic Flutter UI load.
3. **Producer-stressed.** Bump synthetic source to 60 Hz (matches display
   refresh; tests the re-pull-vs-fresh-pull boundary), then drop to 15 Hz
   (severe under-supply; tests staleness under the worst plausible camera
   case).

Each run on a single iPad is enough for the time-box. Cross-iPad parity is
an open question — see end of doc.

---

## Empirical signals to capture

Per run, record:

- **`producedCount` vs. `signalCount` ratio.** Target 1:1. Anything else
  means the signal path is dropping nudges before they reach Flutter, which
  is its own bug.
- **`signalCount` vs. `pullCount` ratio.** Target 1:1 in the happy path; a
  Flutter frame that received a nudge but did not pull is a missed display
  opportunity (staleness vector). Ratio < 1 quantifies the staleness rate.
- **`pullCount` vs. `widgetFrameCount` ratio.** Target ≤ 1 (Flutter pulls
  at most once per widget frame). Ratio significantly < 1 means Flutter is
  rendering frames that *don't* re-sample the texture, which is an embedder
  optimization but also a staleness vector if it persists across produced
  frames.
- **Pulled-stamp histogram.** For every consecutive pair `(pull[i],
  pull[i+1])`, classify as `same` (re-pull) / `+1` (clean delivery) / `+N`
  (skip; a producer frame was passed over). Tabulate counts. Target: roughly
  `same:fresh:skip ≈ 1:1:0` at 60 Hz display vs. 30 Hz produce, with the
  exact ratio set by Flutter's own raster-thread schedule.
- **`firstPullLatencyNs` distribution.** P50, P95, P99 wall-clock from
  producer frame N stored to the first pull that returns N. Above ~33 ms
  (one display refresh at 30 Hz) implies the frame was visible at least one
  refresh later than its sibling produced frames; cumulative this *is*
  the staleness experience.
- **Visual review.** Tearing observed? (yes / no / suspected — provide
  timestamp). Cadence visually jerky? (yes / no / borderline).

All numbers go into one row of `measurements/texture-bridge/<date>/results.csv`
and are commented in plain text in `measurements/texture-bridge/<date>/notes.md`.

---

## Exit criteria

The experiment ends in one of three states:

1. **No mitigation needed.** All three runs show clean delivery (no tearing
   in the recording; staleness rate small enough to be invisible — concretely:
   in run 1 baseline, signal:pull ratio ≥ 0.95 and skip count near zero).
   Phase 3 spec records this run's `results.csv` as evidence and ships the
   simple version: `copyPixelBuffer` returns `currentPixelBuffer(stream:)`
   directly, `textureFrameAvailable` fires from a per-lane subscriber Task.
2. **Specific mitigation needed.** One of runs 2 or 3 (or run 1 in worse
   cases) shows a measurable failure mode — tearing on the recording, or
   sustained staleness gaps. The result names which mitigation (1, 2, or 3
   below) addresses what was observed; Phase 3 spec includes that
   mitigation's design as inline content, not a follow-up.
3. **Inconclusive after 1 day.** The experiment did not converge — the
   measurement was noisy, or the failure mode was visible but its cause
   ambiguous between cadence and a Flutter raster-thread bug. Escalation
   steps, in order: (a) re-run on the second iPad model
   (CLAUDE.md "two iPads" note); (b) instrument Flutter raster-thread
   `os_signpost` to disambiguate cadence vs. raster scheduling; (c) build a
   side-by-side comparison against the Android push path on the same scene.
   Each escalation is itself a time-boxed half-day.

---

## Mitigations to design IF tearing/staleness observed

Each mitigation is sketched in design-shape so Phase 3 can pick one off the
shelf without further architecture work. None of them is built unless the
experiment surfaces the failure mode they address.

### Mitigation 1 — Producer-side debounce of `textureFrameAvailable`

**What it changes.** The bridge's per-lane subscriber Task currently calls
`registry.textureFrameAvailable(id)` on every yielded frame from
`consumers.subscribe(stream:)`. With debounce, it tracks
`lastSignaledFrameNumber` and skips signals whose frame number it has
already nudged. A monotonic frame counter is needed (it already exists —
`FrameSet.frameNumber` per repo conventions).

**Bridge state added.** One `Int64` per lane (`lastSignaledFrame`).
**Mutated from.** The per-lane subscriber Task (single writer per lane).

**Cost.** Negligible. One integer compare per frame per lane.

**Sufficient when.** The signal-vs-pull rate is the problem — Flutter
receives more nudges than it can act on, and the pull cycle gets behind.
Debounce reduces the signal rate to match production rate and lets
Flutter's own scheduler pace from there.

**Insufficient when.** Tearing is the problem — debouncing the *signal* does
not change the underlying read-vs-write race. Or staleness from Flutter's
side (raster thread oversubscribed) is the problem — debouncing the signal
does not give Flutter more raster cycles.

### Mitigation 2 — Stable-reference pin for the duration of a pull

**What it changes.** `copyPixelBuffer()` currently returns
`currentPixelBuffer(stream:)` directly. With pinning, the bridge holds a
strong reference to the *returned* `CVPixelBuffer` for the duration of
Flutter's wrap-and-sample cycle. Practically this means the
`FlutterTexture` retains the last-returned buffer in an instance field and
releases it only when the next `copyPixelBuffer()` returns a different one
(or when the texture is unregistered).

**Bridge state added.** One `CVPixelBuffer?` per lane (`lastReturnedBuffer`).
**Mutated from.** The Flutter raster thread inside `copyPixelBuffer()`
(single writer — Flutter serializes calls per `FlutterTexture`).

**Cost.** One extra `CVPixelBuffer` retained per lane (~1 frame's worth of
IOSurface memory). Increases lane-buffer pool pressure on `MetalPipeline`'s
ring by one slot — POOL_CAP_RULE consumers must include this.

**Sufficient when.** The race is *concurrent re-issue* — Flutter wraps
buffer N for sampling while CameraKit moves on to buffer N+1, and the wrap
ends up sampling N+1's contents because the IOSurface was shared at the
mailbox level rather than per-pull. Pinning ensures the buffer Flutter sees
has stable contents for the duration of its wrap.

**Insufficient when.** The race is *intra-buffer* — the GPU writes into
IOSurface N *while* Flutter samples it, even though both sides agree
they're operating on N. Pinning the reference doesn't pin the contents.
Mitigation 3 addresses this case by ensuring N is fully written before it
becomes pullable.

### Mitigation 3 — 1-deep ring buffer at the bridge (effectively Android's model)

**What it changes.** The bridge no longer pulls directly from
`MetalPipeline.latest*Buffer`. Instead, the bridge maintains its own
1-deep ring per lane, fed from the `consumers.subscribe(stream:)` Task:

- The subscriber Task receives frame N, swaps it into the ring atomically
  *only after* CameraKit has signaled the frame is fully composited (the
  frame yielded on `subscribe(stream:)` already has this property —
  `MetalPipeline` yields after committing the command buffer for that
  frame).
- `copyPixelBuffer()` reads the ring's current slot, retains, returns. No
  contention with the Metal write path because the ring is filled from a
  yielded (post-commit) buffer.

**Bridge state added.** One `Mailbox<CVPixelBuffer>` per lane (the same
primitive `MetalPipeline` already uses internally), single-written by the
subscriber Task, single-read by Flutter raster thread inside
`copyPixelBuffer()`.

**Cost.** One extra retained `CVPixelBuffer` per lane held by the bridge,
plus the per-lane subscriber Task's overhead. The Task already exists for
the `textureFrameAvailable` signal in the simple-version design — the
mitigation just gives it a second responsibility (write to the ring).
Crucially, this *also* breaks the link between Flutter's pull cadence and
the live `MetalPipeline` mailbox: Flutter sees only frames that have already
been fully GPU-committed and yielded, which structurally precludes the
intra-buffer race in mitigation-2's "insufficient when" case.

**Sufficient when.** Tearing or intra-buffer race is the problem. The
yielded-frames-only contract is the iOS analog of Android's push model:
both ensure Flutter sees only post-commit buffers.

**Insufficient when.** N/A. This is the strongest mitigation; if it doesn't
fix the observed problem, the problem is not in the bridge — it's in
Flutter's iOS embedder or in the underlying IOSurface synchronization, and
the question becomes whether to file an Apple Feedback or accept the
behavior as a platform limitation.

### Stacking

The mitigations are independent and stackable. Mitigation 1 alone is the
cheapest fix; Mitigation 3 alone is the most thorough. Mitigation 2 is a
middle option useful only when 1 isn't enough but the failure pattern
doesn't justify 3's per-lane subscriber-Task ring overhead. Phase 3 picks
the smallest set that addresses the empirical findings.

---

## Where the spike code lives

A sibling directory under this repo:

```
experiments/texture-bridge-spike/
├── README.md          # what the experiment is, how to run, what to look for
├── flutter_app/       # the standalone Flutter app
│   ├── pubspec.yaml
│   ├── lib/main.dart
│   └── ios/
│       └── Runner/    # FlutterTexture impl + synthetic source
└── analysis/          # Jupyter / Python script that turns results.csv into a histogram
```

It is **not** added to the Xcode project, **not** linked into the app
target, **not** depended-on by `CameraKit`. It is a `.gitignore`-level
sibling — once results are recorded under
`measurements/texture-bridge/<date>/`, the spike directory is removed in
the same commit that records the Phase-3 decision. Tear-down is part of
the experiment; the directory does not become a permanent fixture.

The experiment app's bundle ID is throwaway
(`com.cambrian.experiments.texture-bridge`) so it does not collide with
production signing in fastlane.

## Verification & integration

- **Device-only.** iPad physical device per CLAUDE.md §6. No simulator —
  IOSurface, CVMetalTextureCache, and 60 Hz vsync behavior are all
  hardware-dependent and the simulator's behavior is not representative.
- **Build path.** The experiment's iOS project is built by `flutter run -d
  <udid>`, which CLAUDE.md does not forbid (the device-only rule applies
  irrespective of which build tool drives Xcode underneath). For the
  underlying iOS Xcode project Flutter generates, `mcp__XcodeBuildMCP__*`
  tools work but are not the primary path; `flutter run` includes the
  hot-restart loop that's useful for iterating on the synthetic source.
- **Two-iPad UDID rule (CLAUDE.md §8).** The experiment runs on whichever
  iPad is connected; the device's `xctrace` UDID is passed to `flutter run
  -d <udid>`. If escalation step (a) — second iPad — is invoked, both
  results.csv files are kept side-by-side under
  `measurements/texture-bridge/<date>/{ipad-pro-11/,ipad-a16/}`.
- **Output location.** `measurements/texture-bridge/<date>/`:
  - `results.csv` — one row per run, columns per "Empirical signals" above.
  - `notes.md` — the human-eye observations + the Phase-3 verdict
    (no-mitigation / mitigation-N / inconclusive).
  - `recordings/run-{1,2,3}.mov` — the iPad screen recordings.
  - `histograms/run-{1,2,3}.png` — the pulled-stamp histogram per run.
- **No PR until results are in.** This is a spec; the spike's deliverable
  is the measurements directory, not a code change to `CameraKit` or
  `eva-swift-stitch`. The Phase-3 plan that follows cites
  `measurements/texture-bridge/<date>/notes.md` as input.

## File inventory

**New (under `experiments/`, removed at tear-down):**

- `experiments/texture-bridge-spike/` — entire tree per "Where the spike
  code lives" above.

**New (permanent):**

- `measurements/texture-bridge/<date>/results.csv`
- `measurements/texture-bridge/<date>/notes.md`
- `measurements/texture-bridge/<date>/recordings/run-{1,2,3}.mov`
- `measurements/texture-bridge/<date>/histograms/run-{1,2,3}.png`

**Not changed:**

- `CameraKit/Sources/CameraKit/CameraEngine.swift` — the
  `currentPixelBuffer(stream:)` accessor is the seam under test; the
  experiment does not depend on or modify it (uses a synthetic source).
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — the latest-buffer
  mailboxes are the production-side counterpart to what the experiment
  exercises; out of scope for the experiment.
- `CameraKit/Sources/CameraKit/PixelSink.swift` — consumer registration
  shape is the production reference for the per-lane subscriber Task in
  mitigations 1 and 3; not modified.
- `eva-swift-stitch.xcodeproj` — no targets added; experiment is standalone.
- Phase 3 design doc — *not yet written.* This spec produces input for it,
  not a change to it.

## Open questions — pinned for the plan

1. **Cross-iPad parity.** The two-iPad CLAUDE.md note exists because the
   project has both an iPad Pro 11" 2nd-gen (A12Z, 120 Hz capable) and an
   iPad A16 (A16 Bionic, 60 Hz). The experiment runs on whichever is
   connected; the question is whether to *require* both as part of the
   first pass, or treat the second iPad as escalation step (a) only. Cost:
   a half-day extra. Risk if skipped: a result that holds on iPad A16
   doesn't hold on the older iPad Pro (or vice versa) and Phase 3 ships a
   bridge that regresses on hardware the team owns.
2. **CVMetalTextureCache round-trip in the experiment.** Flutter's iOS
   embedder uses `CVMetalTextureCacheCreateTextureFromImage` internally to
   wrap returned `CVPixelBuffer`s as `MTLTexture`s. The synthetic
   experiment doesn't exercise this — the buffers are pixel-only, no Metal
   wrap. Does this matter? Two views: (a) it doesn't, because the failure
   modes are about cadence and IOSurface lifecycle, both of which are
   format-independent; (b) it does, because tearing specifically can be
   produced by Metal-side cache aliasing, which only manifests when the
   wrap is in play. If (b), the experiment needs to add a Metal-render
   pass on the synthetic side that mimics what `MetalPipeline` does, which
   is non-trivial within the 1-day budget.
3. **Real Flutter-app load profile.** Run 2 ("Flutter-loaded") uses an
   `AnimatedBuilder` or scrolling `ListView` as a generic raster-thread
   stressor. The production app's actual Flutter UI surface is unknown at
   this time (the migration's Flutter side hasn't been built). Should the
   experiment instead use a placeholder for the *expected* production UI
   (one or two camera-control overlays + a status bar)? That's lower load
   than the stressor — probably fine, but the conservative answer is to
   use the stressor and treat any "fails under stressor, passes under
   placeholder" as a flag for mitigation.
4. **Tear-down timing.** The spike directory is removed once
   `measurements/texture-bridge/<date>/notes.md` records the verdict. But
   if the verdict is "inconclusive after 1 day" and escalation is needed,
   the spike should persist through escalation. Resolution: tear-down only
   happens on a "no-mitigation needed" or "mitigation X needed" outcome;
   "inconclusive" keeps the spike alive until escalation resolves.
5. **Who runs the experiment.** This spec documents the *what*; the *who*
   is open. The experiment is not subagent-friendly (manual screen
   recording + human-eye review of recordings is a load-bearing signal).
   Default assumption: one engineer, one day, with the spec in hand.
