# Future Work — Port the Android Iterative WB Calibration Loop to iOS

**Status:** Scoped, not scheduled · created 2026-05-15
**Type:** Enhancement (not a migration-blocker)
**Depends on:** CameraKit → Flutter migration **Phase 2** complete — the engine
`calibrateWhiteBalance()` method and its WB primitives must exist first.
**Parent context:** `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` §2b

---

## Why this exists

The migration's Phase 2 creates an engine `calibrateWhiteBalance()` method, but it wraps
CameraKit's **current single-shot** white-balance approach (`grayWorldDeviceWhiteBalanceGains`
→ clamp → lock — one shot, no convergence loop, no patch sampling). Android instead runs an
**iterative converging loop** (sample center patch → compute gains → apply → settle →
re-sample, up to 10 iterations, to a `0.01` tolerance) that is known to work well in the
field. This plan upgrades the iOS engine method from single-shot to that iterative loop.

It was split out as future work because the migration should not block on a calibration
quality improvement, and because one product decision (below) is unresolved.

## What an opus review already established (2026-05-15)

Recommendation: **(B) reuse with one documented swap.** The Android loop is mostly
portable; exactly one function is not.

**Ports verbatim** from `camera2_flutter_demo/.../lib/src/cambrian_camera_controller.dart`
(`calibrateWhiteBalance` :404-468) and `lib/src/calibration.dart`:
- The loop shape: sample-before → iterate{ check error → compute → apply → settle →
  resample } → apply-final → sample-after.
- `wbError` (`calibration.dart:79-83`) — max per-channel deviation from green, normalized.
  It measures *patch neutrality*, agnostic to how gains are produced.
- Constants: 200 ms settle, `kWbTolerance = 0.01`, `kWbMaxIterations = 10`.
- Restore-on-throw + `patchBefore` / `patchAfter` snapshot pattern.

**Does NOT port:** `wbStep` (`calibration.dart:93-97`). It holds green as a fixed pivot and
moves only R and B — valid on Camera2's unfloored `COLOR_CORRECTION_GAINS`, invalid on iOS.
`AVCaptureWhiteBalanceGains` clamps every channel to `[1.0, maxWhiteBalanceGain]` and
renormalizes to the minimum channel on apply; pinning a channel at the 1.0 floor costs the
loop a degree of freedom and it oscillates. The Swift team already hit this — see the
documented rejected-iterative-attempt at `CalibrationCompute.swift:36-54`.

**The swap** — the correct iOS step function already exists and is unit-tested:

| Dart | iOS replacement |
|---|---|
| `wbStep(gains, sample)` | `CalibrationCompute.grayWorldGains(sample:current:maxGain:)` — `CalibrationCompute.swift:55-95`. Symmetric 3-channel, normalize-to-min, per-step log2 cap. |
| `sampleCenterPatch()` | `engine.sampleCenterPatchOnNatural()` — natural lane, correct input for WB. |
| `updateSettings(WhiteBalance.manual(...))` | `engine.applyManualGainsAndAwait(_:)` — PTS-synchronized; stronger than Dart's blind 200 ms delay (the delay becomes belt-and-braces — test whether it's needed at all). |
| seed `initialGainR/G/B` | `engine.freshGrayWorldDeviceWBGains()` as iteration 0. |

## Scope

1. Implement the iterative loop inside the engine's `calibrateWhiteBalance()` (created in
   Phase 2), replacing the single-shot body — or alongside it, pending the decision below.
2. Port `wbError` + the loop constants to Swift.
3. Wire `grayWorldGains` + the engine WB primitives per the table above.
4. Engine-side tests (dual-membered, like the other Stage tests): convergence on a
   synthetic cast, iteration-cap exit, restore-on-throw.
5. On-device HITL: confirm convergence quality vs. the single-shot baseline.
6. Consider a parallel Dart **black-balance** port if it proves better than the established
   iOS BB code (lower priority — the iOS BB code already works).

## Open decision (delegated here from the migration spec)

**Replace vs. alongside.** CameraKit's `CalibrationViewModel.calibrateWB`
(`CalibrationViewModel.swift:97-132`) is single-shot today. Does the iterative loop
*replace* it (one WB-calibrate action, matches Android) or stand *alongside* it (single-shot
as a quick action + iterative as a separate one)? Decide at the start of this work.

## Risk

The `grayWorldGains` per-step log2 cap (`±0.25`, `Constants.wbGrayWorldLogCap`) limits each
channel to ~1.19× per iteration. A strong initial cast may exceed `kWbMaxIterations = 10`
and exit on the iteration cap rather than on convergence. Mitigations: raise the cap, raise
the iteration count, or accept cap-exit on hard scenes. Needs a device measurement on first
run — not a blocker, but size it before committing tolerances.

## Files

- `CameraKit/Sources/CameraKit/CameraEngine.swift` — `calibrateWhiteBalance()` body
- `CameraKit/Sources/CameraKit/CalibrationCompute.swift` — `grayWorldGains` (exists), add
  `wbError` + constants
- `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` — single-shot path (replace or
  keep, per the open decision)
- `CameraKit/Tests/CameraKitTests/` — new convergence tests
- Reference (read-only): `camera2_flutter_demo/.../lib/src/calibration.dart`,
  `lib/src/cambrian_camera_controller.dart:404-468`
