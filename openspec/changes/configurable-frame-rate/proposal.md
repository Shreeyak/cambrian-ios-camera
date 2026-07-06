## Why

CameraKit hardcodes the capture frame rate (`Constants.frameRateTargetFPS = 60`) and derives
everything else from it implicitly. That is limiting and, until the recent clamp fix, was crash-prone:

- **No caller control over frame rate.** Consumers (microscopy, EvaScan) want to pick 30 fps for
  quality/bandwidth, 60 fps for smoothness, or slow-mo (up to 240 fps on binned formats). None of that
  is selectable today.
- **Frame rate silently drives the default resolution.** Because selection is "largest 4:3 format that
  supports the target fps", the 60 fps default *excludes* the 30-fps-only sensor formats and lands the
  default on 1920×1440 — even though the sensor offers 4032×3024. Frame rate and resolution are
  entangled when they should be independent.
- **The exposure↔fps coupling is invisible and inconsistent.** A locked frame rate caps usable
  exposure at `1/fps` (33 ms @ 30, 16.6 ms @ 60), but nothing surfaces that ceiling, and the
  preview/recording paths disagree: preview locks the rate while recording quietly lets it drop to a
  15 fps floor and clamps exposure — a silent behavior the caller can't see or predict.
- **HDR and pixel-format quality are left to defaults.** The pipeline wants plain SDR 420f (FullRange)
  for the linear-light normalization stage; HDR tone-mapping on HDR-capable formats fights it, and
  nothing guarantees HDR stays off.

We want the capture format and frame rate to be **explicitly configurable, validated against live
device capabilities, deterministic across every mode, and locked to maximum quality (full-range 420f,
no HDR)** by default.

## What Changes

- **Configurable target frame rate.** `OpenConfiguration.targetFps: Int?` (default resolves to 30).
  Accepts any integer, validated live against the selected resolution's
  `videoSupportedFrameRateRanges` (so 240 fps works where a binned format supports it, 60 up to
  3840×2160, 30 at 4K). An unsupported `(resolution, fps)` pair is rejected at `open()` naming the
  valid options. **fps and resolution are independent** — choosing 30 fps no longer moves the
  resolution.
- **Frame rate is locked in every mode.** Preview, still, and recording all pin
  `activeVideoMinFrameDuration == activeVideoMaxFrameDuration == 1/targetFps`. The separate 15 fps
  recording floor (variable-rate low-light window) is removed; low-light auto-rate is explicitly out
  of scope.
- **Exposure is bounded by the frame rate, with an error (never a silent clamp).** Max manual exposure
  is `min(sensorMax, 1/targetFps)`. A manual exposure beyond that is **rejected** with a configuration
  error rather than clamped. `SessionCapabilities` reports the fps-constrained exposure range so
  callers know the ceiling before setting.
- **Computed max-quality default resolution.** When `captureResolution == nil`, the engine selects the
  **largest 4:3 supported capture resolution discovered from the live format list** (4032×3024 on the
  current test iPad) — computed, not hardcoded, and independent of the frame rate.
- **Always full-range 420f, HDR always off.** Selection is a hard invariant: the chosen format is
  `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (throw at `open()` if none exists), a non-HDR
  (`isVideoHDRSupported == false`) format is preferred when one exists at the requested
  `(resolution, fps)`, and video HDR is explicitly disabled
  (`automaticallyAdjustsVideoHDREnabled = false; isVideoHDREnabled = false`) on whatever format is
  selected — so HDR-capable-only resolutions (4K/3K/2.5K) run with HDR toggled off.
- **Capabilities surface the full valid-config space.** `SessionCapabilities` exposes, per supported
  resolution, the supported frame-rate range(s) (including slow-mo), plus the active frame rate and the
  fps-constrained exposure range — everything a caller needs to pick a valid `(resolution, fps)` and a
  legal exposure.
- **Demo**: an fps picker offering 15/30/60 presets (the library API remains permissive — presets are
  a UI convenience).
- **Flutter/Pigeon parity.** `targetFps` is added to the Pigeon `OpenConfiguration`, and the new
  capability fields (active frame rate, per-resolution supported frame rates, fps-constrained exposure)
  are added to the Pigeon `SessionCapabilities` — with a new frame-rate-range message for the
  per-resolution list, since Pigeon has no Range type. These are regenerated into Dart + Swift and
  surfaced on the Dart API, and the `(resolution, fps)` / exposure-ceiling errors map across the Pigeon
  boundary as the existing typed errors — so a Flutter consumer selects fps and reads the valid-config
  space with parity to the native API.

## Capabilities

### New Capabilities
- `capture-format`: how CameraKit selects and constrains the capture stream's pixel format, frame rate,
  and the resolution default — full-range 420f only, HDR always disabled, configurable and
  mode-invariant locked frame rate, exposure bounded by frame rate, and a computed largest-4:3
  resolution default, all validated against live device format capabilities.

### Modified Capabilities
- `camera-crop`: the `nil` `captureResolution` default is redefined — it now selects the largest 4:3
  supported capture resolution (computed from live formats), independent of the target frame rate,
  rather than an fps-entangled "device default".

## Impact

- **Swift package (`CameraKit/Sources/CameraKit`)**:
  - `Capabilities.swift` — `OpenConfiguration.targetFps: Int?`; `SessionCapabilities` gains
    per-resolution supported frame rates, active frame rate, and fps-constrained exposure range.
  - `CameraSession.swift` — format selection resolves `(resolution, fps)` jointly, prefers non-HDR,
    enforces the 420f invariant, disables HDR, and computes the largest-4:3 default; frame rate locked.
  - `CaptureDeviceProviding.swift` — HDR-disable seam; exposure validation against `1/targetFps`.
  - `CameraEngine.swift` — `setRecordingFrameRateRange` collapses to the locked policy (or is removed);
    exposure-set path rejects out-of-range durations.
  - `Constants.swift` — `frameRateTargetFPS` default 60 → 30; `frameRateRecordingMinFps` retired.
- **Exposure/manual controls**: manual exposure beyond `1/targetFps` now throws instead of being
  accepted/clamped — a behavior change for callers relying on the old recording-floor leniency.
- **Flutter plugin** (in scope): `targetFps` added to the Pigeon `OpenConfiguration`; the new capability
  fields added to the Pigeon `SessionCapabilities` (a new frame-rate-range message for the per-resolution
  list, since Pigeon has no Range type); Pigeon regen (Dart + Swift); the Dart API surface; the Swift
  `CameraEngineHostApiImpl` mapping (config in, capabilities out, errors mapped); mocks (RunnerTests
  `MockCameraEngine`) and the example app. `RecordingOptions.fps` is reconciled with the locked-fps model
  (recording runs at `targetFps`).
- **Demo app**: fps picker (15/30/60); resolution picker already exists.
- **Docs**: capture-format consumer guide (frame rate, exposure coupling, HDR-off, 420f, resolution
  default); a **project README** "Setting up the camera" section (read `SessionCapabilities` → choose
  resolution + fps → `open()`, with the defaults explained); and **docstrings** on the new/changed API
  surface (`OpenConfiguration.targetFps`, the new `SessionCapabilities` fields, and the open /
  setResolution / manual-exposure error contracts) so camera setup is self-documenting.
