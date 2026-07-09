# Migration guide — v1.5.0 → v2.2.0

`v2.0.0` was the first major release after `v1.5.0`; `v2.1.0` and `v2.2.0` are
additive (and, for the Flutter plugin, corrective) on top of it, so this single
guide covers the whole jump. All breaking changes land at the `v1.5.0` →
`v2.0.0` boundary — calibration renames plus two removals. Per the repo's SemVer
policy, a breaking change to *either* the Swift (`CameraKit`) or the Dart
(`cambrian_ios_camera`) API bumps the major.

As of **v2.2.0 the Swift and Dart calibration APIs are aligned** — both use
`calibrateWhite` / `calibrateBlack`. (The Flutter plugin briefly kept the older
`calibrateWhiteBalance` / `calibrateBlackPoint` names in `v2.0.x` / `v2.1.0`;
v2.2.0 renames them to match Swift. See the note below if you already adopted the
Dart plugin at `v2.0.x` / `v2.1.0`.)

> [!NOTE]
> **Already on `v2.0.x` / `v2.1.0` Dart?** Two call sites changed in `v2.2.0` to
> match the Swift API: `calibrateWhiteBalance(...)` → `calibrateWhite(...)` and
> `calibrateBlackPoint()` → `calibrateBlack()`. Arguments and return types are
> unchanged — it's a pure rename.

> [!NOTE]
> `StreamId.processed` → `.primary` (and the dropped `.natural`) is **not** in
> this guide: that landed *within* the 1.x line (before `v1.5.0`, commit
> `8400f25`). Coming from **≤ v1.2.0**? You'll also need `StreamId.processed →
> .primary` and to stop using `StreamId.natural`.

---

## 1. Update the dependency

**SwiftPM**
```swift
.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "2.2.0")
```

**Flutter**
```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter          # the plugin is at flutter/, not the repo root
      ref: v2.2.0
```

---

## 2. Breaking changes (must fix)

At a glance (Swift and Dart names are identical as of v2.2.0):

| # | v1.5.0 | v2.2.0 | Notes |
|---|--------|--------|-------|
| 1 | `calibrateBlackBalance()` | `calibrateBlack()` | Swift returns `BlackPointDebug`; Dart returns `void` |
| 2 | `calibrateWhiteBalance()` | `calibrateWhite(whitePoint:)` | default `whitePoint: true` **also** levels the white point |
| 3 | gray-world WB (chroma only) | `calibrateWhite(whitePoint: false)` | pass `false` for chroma-only (~v1.5.0 behavior) |
| 4 | `SessionCapabilities.previewTextureId` | **removed** | Swift: read the frame directly. Dart: `createPreviewTexture(stream:)` |
| 5 | `ProcessingParameters.blackR/G/B` (Swift) | **removed** | now computed **and** applied by `calibrateBlack()` |

### 2.1 Black-point calibration renamed

The old black-*balance* API (a fixed per-channel offset) was replaced by a
statistical linear **black point** (`mean + k·σ` measured from a dark field).

**Swift** — renamed to `calibrateBlack()`, and it now returns `BlackPointDebug`
(kept/total sample counts + per-channel stats) instead of `CalibrationResult`:
```swift
// v1.5.0
let result = try await engine.calibrateBlackBalance()
// v2.2.0
let debug = try await engine.calibrateBlack()   // -> BlackPointDebug
```

**Dart** — renamed to `calibrateBlack()`, returns `void` (was `CalibrationResult`):
```dart
// v1.5.0
final result = await engine.calibrateBlackBalance();
// v2.2.0
await engine.calibrateBlack();
```

Also removed (Swift only): the direct fields `ProcessingParameters.blackR/G/B`.
If you set those by hand, drop them — the black point is now computed **and
applied** by `calibrateBlack()` (toggle it later with `enableBlackPoint()` /
`disableBlackPoint()` — see §3).

### 2.2 White-balance calibration → two-layer model

Calibration is now two independent layers: a **WB chroma residual** and an
optional **white-point level**.

**Swift** — renamed to `calibrateWhite(whitePoint:)`:
```swift
// v1.5.0
let result = try await engine.calibrateWhiteBalance()
// v2.2.0 — whitePoint defaults to true (applies chroma + white-point level)
let result = try await engine.calibrateWhite(whitePoint: true)  // -> CalibrationResult
```

**Dart** — renamed to `calibrateWhite({whitePoint})`:
```dart
// v1.5.0
final result = await engine.calibrateWhiteBalance();
// v2.2.0
final result = await engine.calibrateWhite(whitePoint: true);
```

### 2.3 Behavioral change: `calibrateWhite` levels the white point by default

`calibrate*` still **applies** immediately — you do **not** need to call
`enable…()` after calibrating (the procedure is sample → compute → enable).
What changed is *what* `calibrateWhite` applies: v1.5.0's gray-world WB only
neutralized the color cast (chroma), whereas v2.x `calibrateWhite(whitePoint:)`
defaults to `true` and **also** applies a white-point level (brightfield — the
white field is pushed to solid white). For behavior closest to v1.5.0 WB (chroma
only, grey preserved — e.g. phase contrast), pass `whitePoint: false`.

```swift
// v2.2.0 (Swift) — applies on its own; no enable* needed
_ = try await engine.calibrateWhite(whitePoint: false)  // chroma only (~v1.5.0)
_ = try await engine.calibrateWhite()                   // chroma + white-point level (default)
_ = try await engine.calibrateBlack()                   // computes AND enables the black point
```
```dart
// v2.2.0 (Dart)
await engine.calibrateWhite(whitePoint: false);  // chroma only (~v1.5.0)
await engine.calibrateBlack();
```

The new `enable…()` / `disable…()` / `clear…()` toggles are **optional** — they
turn a *stored* calibration on/off without re-shooting the reference field (see
§3). They are not a required post-calibration step.

### 2.4 `SessionCapabilities.previewTextureId` removed

The eager preview-texture id is gone from `SessionCapabilities`.

**Flutter** — allocate the texture on demand:
```dart
// v1.5.0
final textureId = caps.previewTextureId;
// v2.2.0
final textureId = await engine.createPreviewTexture(stream: StreamId.primary);
```

**Swift** — the field was a Flutter texture-registry id and has no meaning for a
direct CameraKit consumer. Render the preview from the frame itself:
`currentPixelBuffer(stream: .primary)` or `lockedPixels(stream: .primary)`.

---

## 3. New in v2.x you may want to adopt (optional)

None of these are required to migrate, but they arrived in this window:

- **Near-focus autofocus** (v2.2.0) — CameraKit now sets
  `autoFocusRangeRestriction = .near` (where supported) so continuous AF is
  faster, lower-power, and less prone to hunting on close subjects (scanning).
  It's a priority hint, not a hard limit, and has no effect once focus is locked.
- **Awaited focus settle** (v2.2.0) — `updateSettings` with a manual
  `focusDistance` now awaits the lens physically settling (AVFoundation
  completion handler, 1 s timeout fallback) before returning, so a follow-up
  capture sees the intended focus. No API change — the call was already `async`.
- **Linear-light normalization** — per-channel affine (black point + WB chroma
  residual + optional white-point level) applied in linear light before the
  gamma grade. This is what the two-layer calibration above drives.
- **Independent calibration toggles** — `enableWhiteBalance()`/`disableWhiteBalance()`,
  `enableWhitePoint()`/`disableWhitePoint()`, `enableBlackPoint()`/`disableBlackPoint()`,
  and `clearWhiteBalance()`/`clearBlackPoint()`. These flip a *stored* calibration
  on/off (or discard it) without re-shooting the reference field. `enable*` throws
  if that layer was never calibrated. White point is a child of chroma — it can't
  be enabled without chroma, and disabling chroma disables it too.
- **Configurable + locked frame rate** — any integer fps, validated against each
  resolution's live ranges; frame rate is decoupled from max-quality format
  selection.
- **Bounded, escalating fault recovery** — quick reopen → full restart → terminal
  fatal, and **subscribed frame streams survive restarts** (consumers see a frame
  gap, not a terminated stream). Only a user `close()` or the terminal fatal ends
  a lane.
- **`captureNaturalPictureBuffer()`** — the graded natural still as an in-memory,
  IOSurface-backed BGRA8 `PixelHandle` (Swift) — no disk write. Exposed on
  `CameraEngineProtocol` in v2.1.0.
- **`photoQualityPrioritization`** on `OpenConfiguration` — `.speed` / `.balanced`
  / `.quality` (default `.balanced`). See the note below before relying on it.
- **Full `LocalizedError` conformance** across all error types.

---

## 4. Notes

- **`photoQualityPrioritization` is a no-op on iPad (measured).** Whether
  `.speed` / `.balanced` / `.quality` change anything depends on the active
  format's `isHighPhotoQualitySupported`. On the iPad A16 rear camera **no format**
  reports `true` for that flag (measured across all ~40 formats), so all three
  levels produce the **same** image — the natural still is already at the format's
  top quality tier (only the 4032×3024 format is `isHighestPhotoQualitySupported`,
  and that's the one CameraKit selects). The knob is safe to set and honored on
  hardware that supports it (e.g. iPhone Pro); just don't expect a visible change
  on iPad.
- **Capture orientation is now owned in Metal.** Preview, tracker, recording,
  `captureImage`, and the natural still share one mirror, and the ISP one-shot is
  compensated for its 180° source rotation — so the natural still matches the
  preview exactly. If you previously worked around an orientation mismatch on the
  still, remove that workaround.
