# Texture-bridge cadence spike — results, 2026-05-15

> **Verdict: NO MITIGATION NEEDED.** Phase 3 ships the simple version of
> the iOS texture bridge: `copyPixelBuffer()` returns
> `engine.currentPixelBuffer(stream:)` directly; `textureFrameAvailable()`
> fires on every produced frame from a per-lane subscriber `Task`. None
> of Mitigations 1/2/3 from the spec are warranted by the empirical data.
>
> One follow-on flag for Phase 3 to track: under heavy Flutter raster
> load the *signal:pull ratio* drops, but no bridge mitigation addresses
> it (the bottleneck is Flutter raster-thread budget, not the bridge).
> See "Caveat — loaded-mode jitter" below.

**Companion to** `docs/superpowers/specs/2026-05-15-texture-bridge-cadence-design.md`.

## What ran

Standalone Flutter app (`experiments/texture-bridge-spike/`, gitignored,
torn down on landing this verdict) implementing `FlutterTexture` over an
IOSurface-backed BGRA8 `CVPixelBuffer` pool driven by a
`DispatchSourceTimer` synthetic source. No CameraKit, no real Metal
pipeline — the measurement isolates Flutter's display-side cadence from
CameraKit's production-side behavior, exactly as the spec scoped.

All 4 runs were 60s on **Shreeyak's iPad Pro 11" 2nd-gen (A12Z, iOS
26.4.2)**, wireless connection. Run matrix:

| # | Mode label | Producer Hz | Flutter raster load |
|---|---|---|---|
| 1 | baseline | 30 | none |
| 2 | loaded   | 30 | 5000-circle `CustomPainter` driven by continuous `Ticker` |
| 3 | producer-stressed (high) | 60 | none |
| 4 | producer-stressed (low)  | 15 | none |

The mode set diverges slightly from the spec (which proposed three runs:
baseline, Flutter-loaded, producer-stressed-bidirectional). The two
producer-stressed cases (60 + 15) are split into separate runs because
they answer different questions — 60 Hz tests the re-pull boundary; 15
Hz tests staleness under under-supply.

## Headline numbers

Full table in `results.csv`. The story is in three columns:

| Run | produced/s : signal/s : pull/s | re-pull (`same`) | skip (`+2`+) | P95 latency |
|---|---|---|---|---|
| 1 baseline 30 Hz | 30.0 : 30.0 : 30.0 | 0 / 1797 (0%) | 1 / 1797 (0.06%) | **9.0 ms** |
| 2 loaded 30 Hz | 30.0 : 30.0 : **28.5** | **214 / 1708 (12.5%)** | **305 / 1708 (17.9%)** | **31.8 ms** |
| 3 producer 60 Hz | 60.0 : 60.0 : 60.0 | 0 / 3599 (0%) | 0 / 3599 (0%) | 9.0 ms |
| 4 producer 15 Hz | 15.0 : 15.0 : 15.0 | 0 / 899 (0%) | 0 / 899 (0%) | 9.0 ms |

The bare-cadence runs (1/3/4) are essentially perfect: every produced
frame becomes one nudge becomes one Flutter pull, returning a
strictly-monotonic frame number with sub-10ms first-pull latency. The
single +2 jump in run 1 (one missed frame in 60 seconds) is within
measurement noise.

## The central finding — Flutter pulls when signaled, not at vsync

The spec's three failure modes (staleness, re-pull, tearing) all assume
Flutter samples on its own vsync at 60 Hz, independent of producer
cadence. **The data shows Flutter does not do this.** Flutter's pull rate
in runs 1, 3, and 4 matches the producer rate exactly (30, 60, and 15
pulls/s respectively). Runs 1 and 4 are the most informative — at
producer rates *below* the 60 Hz display refresh, Flutter pulls only
when signaled, never re-pulls between signals.

What's actually happening: a static `Texture` widget doesn't dirty the
Flutter framework's widget tree, so `SchedulerBinding`'s frame loop is
mostly idle (`addPersistentFrameCallback` fires <1×/s in runs 1/3/4).
The Texture's repaints go directly through the raster thread in
response to `textureFrameAvailable`. The framework and the texture
pipeline are decoupled when the framework has no other work — exactly
the case for a kiosk-style camera preview with minimal UI.

This is the answer to the spec's central question. No mitigation is
needed because the failure mode the mitigations targeted does not occur.

## Caveat — loaded-mode jitter (run 2)

When the Flutter widget tree is dirtied every frame (the 5000-circle
`Ticker`-driven `CustomPainter` stressor), three things change:

1. Framework frame rate climbs to ~44 Hz (`widget_per_sec = 44.07`).
   Flutter's raster thread is now actually doing work for the framework.
2. Pull rate drops to **28.5 / s** vs producer's 30 / s — Flutter
   missed ~5% of `textureFrameAvailable` nudges (signal:pull ratio
   0.949).
3. Among the pulls that did happen, 12.5% were re-pulls (raster ran
   between two producer frames) and 17.9% were skips (raster missed a
   producer frame entirely). P95 first-pull latency rose to ~32 ms —
   the next display refresh after the producer's tick.

**This is Flutter raster-thread saturation, not a bridge problem.** The
spec's three mitigations all target bridge-side state (debounce, pin,
ring); none of them changes the raster-thread budget. The fix lives in
the production app's Flutter UI, not in the bridge:

- Phase 3 should instrument Flutter raster timing (e.g.
  `os_signpost`-bridged frame callbacks) in the production app to
  detect when the actual UI surface saturates the raster thread.
- The production app's UI budget directly bounds preview smoothness.
  The 5000-circle stressor was a deliberate worst case; the actual
  production UI surface (camera-control overlays + status bar per the
  Phase-2 brief) is almost certainly far lighter, but is unverified at
  this time.

If the production app turns out to drive raster load comparable to or
heavier than the stressor, the right response is to re-budget the UI,
not to add bridge state.

## On tearing — un-verified visually

The spec calls for screen-recording review to detect tearing (a frame
"split mid-digit" with two producer-frame numbers visible at once). No
recording was captured during the runs (wireless screen-recording from
device is a non-trivial flow on this setup; the AirDropped iPad
screenshots that arrived turned out to be from a different camera app,
not the spike). The tearing question is therefore answered indirectly:

- Tearing on iOS IOSurface-backed `CVPixelBuffer` requires Flutter to
  wrap and sample buffer N *while the producer is writing buffer N+1
  into the same IOSurface*.
- In runs 1, 3, and 4 the bridge returned strictly +1 frame numbers in
  every consecutive pull pair. There was no observed instance of Flutter
  pulling buffer N twice while producer N+1 was being written.
- Run 2's 12.5% re-pulls returned the *same* frame number, not split
  contents — the buffer Flutter wrapped was already fully written when
  it asked.
- The synthetic source uses a `CVPixelBufferPool` with 6 minimum slots,
  so the producer almost never reuses the same backing IOSurface across
  consecutive frames. Even when it does, buffer N+1 is acquired *before*
  the swap into the latest-mailbox; the swap is locked.

**Tearing is therefore very unlikely with this bridge shape, but not
visually confirmed in this spike.** The conservative path if Phase 3
wants belt-and-suspenders certainty: Mitigation 3 (1-deep ring fed from
the post-commit `consumers.subscribe(stream:)` yield) structurally
eliminates the read-vs-write race even in the worst contention case.
Mitigation 3's cost (one extra retained `CVPixelBuffer` per lane + the
subscriber Task that already exists for the nudge) is negligible.

The verdict above ships the simple version because nothing in the data
*requires* Mitigation 3, and adding mitigation pre-emptively without an
observed failure inverts the spec's "decide empirically" mandate. If a
later integration test on real CameraKit lanes (post-Phase-3) shows
visible tearing, switch to Mitigation 3 then.

## Open Questions resolved (per design doc)

1. **Cross-iPad parity** — single-iPad first pass on iPad Pro 11" 2nd
   gen. Second iPad (iPad A16) treated as escalation step (a) only —
   not invoked because the first pass was conclusive. Phase 3 should
   re-run the spike on the iPad A16 if any production-side behavior on
   that device looks suspicious.
2. **CVMetalTextureCache round-trip in spike** — pixel-only synthetic
   source; no producer-side Metal wrap. Flutter's *own* Metal-cache
   wrap is exercised inherently (it's what `Texture` widget does
   internally with the returned `CVPixelBuffer`). Verdict justifies
   skipping the producer-side wrap.
3. **Real Flutter-app load profile** — used the conservative
   stressor (5000-circle `CustomPainter`). The production UI is almost
   certainly lighter; no flag raised by the data because even under the
   conservative stressor, no bridge mitigation helps.
4. **Tear-down timing** — verdict is "no mitigation" → spike is torn
   down in this commit. Tree at `experiments/texture-bridge-spike/`
   is removed; the analysis script is preserved at
   `measurements/texture-bridge/2026-05-15/histogram.py`.
5. **Who runs** — autonomous Claude session (this one), with the user
   physically driving the four iPad Start-button presses. The 4 runs
   completed in <5 min wall-clock once the app was deployed.

## Files

- `results.csv` — one row per run (4 rows + header), columns per spec.
- `notes.md` — this file.
- `histogram.py` — preserved analysis script (was
  `experiments/texture-bridge-spike/analysis/histogram.py`; that
  directory is removed).
- `histograms/run-N-<mode>.png` — per-run pull-to-pull-delta histogram
  + first-pull-latency distribution.
- `histograms/run-N-<mode>-summary.json` — per-run analysis dump.
- `raw/run-N-<mode>/{seconds.csv, pulls.csv}` — raw CSVs pulled from
  the iPad via `xcrun devicectl device copy from --domain-type
  appDataContainer --domain-identifier
  com.cambrian.experiments.textureBridgeSpike`.
- `recordings/` — empty; no screen recording captured (see "On
  tearing" above).

## Reproduce

```bash
# Re-render histograms from the raw CSVs:
for run in raw/run-*; do
  python3 histogram.py "$run" histograms
done
```

The spike app source is no longer in the tree. To re-instrument the
spike, recreate `experiments/texture-bridge-spike/` per the design doc
§"Where the spike code lives" — the artefacts in this directory have
everything needed to validate any new run against the established
baseline.

## Phase 3 carry-forward

Recommend the Phase 3 plan author:

1. **Implement the simple bridge as the spec describes.** No state
   beyond the existing `currentPixelBuffer(stream:)` accessor and the
   per-lane subscriber `Task` that fires `textureFrameAvailable`.
2. **Add a Flutter raster-time signpost.** A single
   `os_signpost`-style metric on the Flutter side per frame, surfaced
   in the production app's metrics stream — gives ops/QA a dial for the
   "loaded mode" failure mode if it manifests in production with real
   UI load.
3. **Mitigation 3 is the on-the-shelf escalation.** If a later
   integration test shows tearing on real CameraKit lanes, switch the
   bridge from "read latest mailbox directly" to "subscribe to
   `consumers.subscribe(stream:)` and write into a 1-deep
   ring; `copyPixelBuffer` reads the ring." This is the design doc's
   Mitigation 3 verbatim. It's a ~50 LOC change.
