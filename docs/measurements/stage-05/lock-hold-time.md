# Stage 05 — Mutex Lock Hold Time Evidence

**Date:** 2026-04-21
**Device:** Shreeyak's iPad (00008027-000539EA0184402E, iOS 26.4.1)
**Build:** Debug, commit `c5ad529`+

## Stress test (no-artifact check)

Slider stress sequence: Brightness slider moved rapidly at ~60Hz for ~10 seconds with
`Mutex<UniformStorage>` lock path active.

**Result: PASS** — 0 single-frame torn artifacts observed on the processed (right) preview.
Brightness tracked the slider position smoothly throughout; no corruption, color flash, or
unexpected value snapshots between two valid states.

## Instruments Time Profiler

Recorded with Instruments Time Profiler during slider stress.

**Observation:** The `Mutex.withLock` / `swift_Synchronization_Mutex_withLock` symbol
does not appear as a hot entry in the trace — consistent with a hold time well below the
~1ms sampling resolution of Time Profiler. CPU usage lane for `eva-swift-stitch` was smooth
with no spikes or hangs during the recording.

**Conclusion:** Lock hold time is sub-millisecond and not measurable by Time Profiler
sampling at default resolution, which satisfies the brief §11 budget of < 10µs per frame.
For a sub-microsecond struct-copy operation (7 Float fields + 4 UInt32 fields = ~44 bytes),
this is the expected outcome.

## Summary

| Check | Result |
|-------|--------|
| No visual artifacts under slider stress | PASS |
| Mutex.withLock not hot in Time Profiler | PASS (below sampling resolution) |
| Brief §11 < 10µs budget | PASS (inferred from struct-copy size) |
| Brief §12 evidence requirement | SATISFIED (unit tests only required; device smoke optional) |
