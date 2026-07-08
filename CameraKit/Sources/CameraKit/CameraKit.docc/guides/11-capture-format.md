# Capture format: resolution and frame rate

Choose the capture resolution and frame rate at open, read the valid space from capabilities, and understand the fixed format invariants.

Assumes you have read <doc:02-getting-started>.

## Resolution and frame rate are chosen at open

``OpenConfiguration/captureResolution`` and ``OpenConfiguration/targetFps`` are
set once, at ``CameraEngine/open(configuration:)``, and are **independent** — a
resolution does not imply a frame rate, and a frame rate does not imply a
resolution. Both are validated against the device's live capabilities; neither is
silently coerced. To change either afterwards, close and reopen.

```swift
let engine = CameraEngine(initialPhase: .active)

// Open with defaults to discover what the device supports.
let caps = try await engine.open()
```

## Reading the capability space

``SessionCapabilities`` describes exactly what this device supports:

- ``SessionCapabilities/supportedSizes`` — the selectable capture resolutions.
- ``SessionCapabilities/supportedFrameRates`` — a list of ``FrameRateRange``
  values, each pairing a ``FrameRateRange/size`` with its
  ``FrameRateRange/minFps``…``FrameRateRange/maxFps`` range. It is a *list*, not a
  map: one resolution can appear more than once when the device exposes several
  formats at that size (for example a 1–60 fps standard format and a 2–240 fps
  binned slow-motion format at the same dimensions).
- ``SessionCapabilities/activeFrameRate`` — the rate the current session is
  locked to.
- ``SessionCapabilities/exposureDurationRangeNs`` — the manual-exposure range,
  already bounded by the active frame rate (see below).

```swift
for r in caps.supportedFrameRates {
    print("\(r.size.width)×\(r.size.height): \(r.minFps)–\(r.maxFps) fps")
}
```

## Choosing a resolution and frame rate

Pick a `(resolution, fps)` pair that appears in the capabilities, then reopen:

```swift
await engine.close()
let hi = try await engine.open(configuration: OpenConfiguration(
    captureResolution: Size(width: 1920, height: 1440),  // in caps.supportedSizes
    targetFps: 60                                         // valid at that size
))
// hi.activeFrameRate == 60
```

An unsupported pair — a frame rate above what the requested resolution supports —
throws ``EngineError`` (`settingsConflict`) naming the valid rates. It is never
rounded down or snapped to the nearest supported rate.

## The frame rate is locked

The chosen frame rate is locked for the whole session: the same rate drives the
preview lanes, still capture, and recording. CameraKit does not lower the rate in
low light or raise it for a particular mode. `RecordingOptions.fps` is therefore
advisory only — recording runs at ``SessionCapabilities/activeFrameRate``.

## Exposure is bounded by the frame rate

A frame cannot expose for longer than its own duration, so the manual-exposure
ceiling is the smaller of the sensor maximum and one frame period:

```
max exposure = min(sensorMax, 1 / targetFps)
```

That is 1/30 s (≈33 ms) at 30 fps and 1/60 s (≈16.6 ms) at 60 fps.
``SessionCapabilities/exposureDurationRangeNs`` already reflects this bound.
Requesting a longer manual exposure via ``CameraEngine/updateSettings(_:)`` throws
``EngineError`` (`settingsConflict`) naming the ceiling — it is **not** clamped. To
use a long exposure, open at a lower `targetFps` (the lower the rate, the longer
the permitted exposure).

## Fixed format invariants

Two properties of the capture format are not configurable:

- **Always full-range 420f.** CameraKit always selects the full-range
  `420YpCbCr8BiPlanarFullRange` pixel format for maximum tonal range. A device
  that exposes no 420f format at the requested resolution fails the open.
- **HDR is always off.** Video HDR is disabled even on HDR-capable formats, so
  color is deterministic and unaffected by scene-adaptive tone mapping — a
  prerequisite for the calibration pipeline (<doc:08-calibration>). When both an
  HDR-capable and a non-HDR format exist at the chosen resolution and frame rate,
  the non-HDR format is preferred.

## Defaults

Opening with a bare ``OpenConfiguration`` (or no configuration) uses:

- **Resolution:** the largest 4:3 resolution the device supports, computed from
  its formats — not a hard-coded size.
- **Frame rate:** 30 fps.
- **Format:** full-range 420f, HDR off.

## Flutter

The Pigeon surface mirrors this exactly. `OpenConfiguration.targetFps` selects the
frame rate; `SessionCapabilities.activeFrameRate` and
`SessionCapabilities.supportedFrameRates` (a `List<PFrameRateRange>` of
`{ size, minFps, maxFps }`) report the locked rate and the valid space; the
fps-constrained exposure ceiling is carried by the existing
`exposureDurationMaxNs`. Read the capabilities, pick a valid pair, and
`open(OpenConfiguration(captureResolution: …, targetFps: …))`. The unsupported-pair
and exposure-ceiling errors surface as the mapped `CameraException`.

## Migration

Two behaviors changed relative to earlier versions:

- **Manual exposure past `1/targetFps` now throws.** Earlier releases allowed a
  longer exposure (up to the recording floor, ~66 ms) while recording. That
  leniency is gone: the ceiling is `min(sensorMax, 1/targetFps)` in every mode, and
  exceeding it throws ``EngineError`` (`settingsConflict`) rather than being
  silently accepted or clamped. Open at a lower `targetFps` for long exposures.
- **The default resolution is larger.** The default is now the computed largest
  4:3 resolution (for example 4032×3024 on iPad Pro 11″) instead of a fixed
  1920×1440. This maximizes quality but increases per-frame pipeline cost at the
  default — pass an explicit ``OpenConfiguration/captureResolution`` if you want a
  smaller frame.

The package default frame rate is 30 fps.

## Reference integration

`ios_example_app/ios_example_app/UI/CameraView.swift` builds an fps picker
(15/30/60) filtered to what the active resolution supports, and
`ViewModel.swift` reopens the engine with the selected
``OpenConfiguration/targetFps``.
