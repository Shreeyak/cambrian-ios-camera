## Context

Capture format selection lives in `CameraSession.configure(...)` (`CameraSession.swift`). Today it:

1. Filters device formats to 420f FullRange (already), sorts by pixel count.
2. Picks the largest 4:3 format that supports `Constants.frameRateTargetFPS` (hardcoded 60) — which
   *entangles* the resolution default with the frame rate.
3. Sets `activeVideoMinFrameDuration == activeVideoMaxFrameDuration == 1/targetFps` (now clamped to the
   format's supported range by the recent crash fix).

Frame-rate ranges come live from `format.videoSupportedFrameRateRanges`; HDR-capability from
`format.isVideoHDRSupported`; both are already read by `dumpAllFormats()`. Real device data (iPad Pro
11", iPad8,9) that grounds this design:

- fps is a **continuous range per format** (`minFrameRate…maxFrameRate`), min ≈ 1–2, max 30 / 60 / 240.
- 60 fps is offered up to 3840×2160; **4032×3024 / 3264×2448 / 2592×1944 are 30-fps HDR-capable only**.
- Several mid sizes expose both a non-HDR `[full]` (e.g. 1–60) and an HDR-capable `[full hdr]` (1–30).
- Binned low-res formats reach 240 fps (slow-mo).
- `minFrameRate ≈ 1` ⇒ `1/minFrameRate ≈ 1 s`, matching the sensor's 1000 ms max exposure: **frame rate
  and max exposure are the same knob.**

## Goals / Non-Goals

**Goals**
- Caller-selectable `targetFps`, validated live; independent of resolution.
- Deterministic, mode-invariant locked frame rate.
- Exposure bounded by frame rate with an explicit error (no silent clamp).
- Max-quality format guaranteed: 420f FullRange, HDR off; computed largest-4:3 default resolution.
- Capabilities that fully describe the valid `(resolution, fps, exposure)` space.

**Non-Goals**
- Low-light automatic frame-rate reduction (variable-rate recording window) — explicitly removed.
- Runtime `setFrameRate(_:)` — fps is open-time only; change fps by close + reopen (per decision D2).
- Changing the crop machinery, lanes, or the grade.
- Routing the raw IOSurface across Pigeon (unrelated); this change only surfaces `targetFps` + the
  capability fields, which are value types.

## Decisions

### D1. Frame rate and resolution are selected independently
Split today's coupled selection into two steps: (a) resolve the **resolution** (requested, or the
computed largest-4:3 default) with no fps filter; (b) among the 420f formats at that resolution, pick
one whose `videoSupportedFrameRateRanges` contains `targetFps`. A lower fps no longer enlarges the
default resolution, and vice versa. The largest-4:3 default is computed by scanning the live 420f
formats for `w*3 == h*4` and taking the max pixel count — not hardcoded (on the test iPad this is
4032×3024).

### D2. `targetFps` is open-time only (`OpenConfiguration.targetFps: Int?`)
Mirrors how the change was scoped: no live `setFrameRate`. Default `nil → 30`. The API accepts **any
integer**, validated against the resolution's live ranges — not restricted to a preset list. The demo
offers 15/30/60 as a UI convenience only.

### D3. Frame rate locked in all modes; the recording floor is removed
Set `activeVideoMinFrameDuration == activeVideoMaxFrameDuration == 1/targetFps` everywhere. Collapse
`setRecordingFrameRateRange` into the same locked policy as `setPreviewFrameRateRange` (or remove it and
have both paths call one `setLockedFrameRate`). Retire `Constants.frameRateRecordingMinFps` (15). This
removes the silent variable-rate low-light behavior; re-introducing it later would be an explicit
opt-in "auto-rate" mode, out of scope here.

### D4. Exposure bounded by frame rate — reject, never clamp
Max manual exposure ceiling `= min(sensorMaxExposureNs, 1e9 / targetFps)`. The manual-exposure entry
point (`setIsoExposureManual` and its engine caller) validates the requested duration against this
ceiling and throws a configuration error when exceeded, instead of calling `setExposureModeCustom` with
an out-of-range duration (which AVFoundation would clamp). `SessionCapabilities.exposureDurationRangeNs`
is reported with this fps-constrained upper bound so the caller sees the ceiling up front. Longer
exposures require opening at a lower `targetFps`.

### D5. Always 420f FullRange, HDR always disabled; prefer non-HDR
Keep the existing 420f FullRange filter as a **hard invariant** — throw at `open()` if the filtered set
is empty (rather than the current nearest-dimension fallback that could pick something unintended). On
the chosen device, set `automaticallyAdjustsVideoHDREnabled = false` and `isVideoHDREnabled = false`.
When multiple 420f formats match `(resolution, fps)`, prefer `isVideoHDRSupported == false`; if the only
match is HDR-capable (the largest sensor sizes), use it with HDR disabled. "No HDR" is thus an enforced
runtime state, not a format-exclusion rule — which is what lets the largest-4:3 default (an HDR-capable
format) coexist with the no-HDR requirement.

### D6. Capabilities describe the full valid space
`SessionCapabilities` gains: per-resolution supported frame rates (from the union of the 420f formats'
ranges at each size — a range or a small set of ranges, including slow-mo), the active frame rate, and
the fps-constrained exposure range. Sourced live from `videoSupportedFrameRateRanges`, never the static
`capabilities-*.txt` snapshot (that file is a saved artifact, not an input).

### D7. Flutter/Pigeon surface — value-typed parity, a new frame-rate-range message
`targetFps: int?` is added to the Pigeon `OpenConfiguration` (alongside `captureResolution`). The Pigeon
`SessionCapabilities` is a flattened min/max mirror (Pigeon has no Range type), so the new fields are:
`activeFrameRate: int`; the fps-constrained exposure carried by the existing `exposureDurationMaxNs`
(now `min(sensorMax, 1/activeFrameRate)`); and a **new `PFrameRateRange { PSize size; int minFps; int
maxFps }` class** exposed as a `List<PFrameRateRange?>` — a *list*, not a map, so a resolution can carry
multiple ranges (e.g. a 1–60 full format and a 2–240 binned slow-mo at the same size). The Swift
`CameraEngineHostApiImpl` forwards `targetFps` into the native `OpenConfiguration` and maps the native
capabilities into the Pigeon message; the unsupported-`(resolution, fps)` and exposure-ceiling errors
map to the existing typed Pigeon error path (`asPigeonError()` / `notOpen`-style injection). Pigeon is
regenerated (Dart + Swift) and the Dart API surfaces the new arg + fields. `RecordingOptions.fps` is
reconciled with the locked model — recording runs at `targetFps`, so the field is deprecated/ignored (or
removed) rather than driving a separate recording rate.

## Risks / Trade-offs

- **Behavior change: exposure now throws past `1/targetFps`.** Callers relying on the old recording-floor
  leniency (exposure up to ~66 ms while recording) get an error instead. Accepted and intended
  (determinism + explicitness); documented in the migration notes.
- **Default resolution jumps 1920×1440 → 4032×3024.** The computed largest-4:3 default is much larger,
  which increases per-frame pipeline cost at the default. This is intended (max quality) and interacts
  with the separate "efficient GPU usage" thread (crop-first, smaller processed region) — noted, not
  solved here.
- **HDR-off on an HDR-capable format** relies on `isVideoHDREnabled = false` fully suppressing
  tone-mapping on these 8-bit formats. To be verified on device (a calibration-tap check), since the
  behavior is what justifies Rec A.
- **Removing the recording floor** removes low-light video graceful degradation. Acceptable per the
  explicit "no low-light imaging for now" scope.

## Migration Plan

1. Add `OpenConfiguration.targetFps`; default resolution becomes computed largest-4:3 (decoupled).
2. Split resolution/fps selection; enforce 420f invariant; prefer non-HDR + disable HDR.
3. Collapse frame-rate setters to one locked policy; retire the recording floor + its constant;
   `frameRateTargetFPS` default 60 → 30.
4. Add exposure validation (reject > `1/targetFps`); report fps-constrained exposure range.
5. Extend `SessionCapabilities` (per-resolution fps, active fps, constrained exposure) from live data.
6. Demo fps picker (15/30/60). Docs: capture-format guide. Device HITL: 30/60 lock, 4K default,
   HDR-off calibration-tap, exposure-ceiling error, slow-mo where supported.

## Open Questions

- **Shape of the per-resolution fps capability**: a single `ClosedRange<Int>` per size (min…max of the
  union) vs. a list of ranges (to distinguish e.g. a 1–60 full format from a 2–240 binned one at the
  same size). Leaning: expose the ranges as a small list so slow-mo is discoverable; confirm during
  implementation against the `SessionCapabilities` `Hashable`/Pigeon-shape constraints.
- **`setResolution` (runtime) + fps**: `setResolution` exists at runtime while `targetFps` is open-time.
  If a runtime resolution change lands on a size that doesn't support the current locked fps, does it
  throw (consistent with open) or is fps re-validated? Leaning: throw, same error as open.
