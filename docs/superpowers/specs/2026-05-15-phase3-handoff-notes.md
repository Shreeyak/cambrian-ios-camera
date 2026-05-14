# Phase 3 Handoff Notes — CameraKit → Flutter Migration

**Status:** Living document · started 2026-05-15
**Companion to:** `2026-05-14-camerakit-flutter-migration-design.md` (Phases 1–2 design)
**Purpose:** Phase 3 is a separate spec→plan cycle (physical relocation into
`camera2_flutter_demo`, the Pigeon adapter, the texture-registry bridge, applying contract
amendments to the Flutter package + Android). This file accumulates decisions and findings
made *during* Phase 1–2 brainstorming that Phase 3 must not lose. It is not a Phase 3 plan
— it is the briefing material for whoever writes that plan.

---

## 1. Zero-copy texture bridge (iOS)

### Why this matters

The naive iOS texture bridge — Flutter "minting a texture" and the adapter blitting each
frame into it — introduces a per-frame CPU copy at 30 Hz on full-resolution buffers. That
is unacceptable. Android does **not** do this; it is zero-copy. iOS can be zero-copy too,
but only if the bridge is built deliberately. This section is the design constraint Phase 3
inherits.

### How Android does it (for reference — confirmed against the repo)

`TextureRegistry.createSurfaceProducer()` → `producer.getSurface()` hands the **native**
side a Flutter-owned `Surface`. Native does `ANativeWindow_fromSurface` →
`eglCreateWindowSurface` → the GPU renders **directly into Flutter's buffer** via
`eglSwapBuffers`. `producer.id()` is the `Texture` widget id. It is **push** — native owns
the cadence, Flutter just displays whatever is in the shared buffer. There is no readback
on the preview path (the PBO `glReadPixels` is a *separate* path feeding the C++ sinks).

Files: `CambrianCameraPlugin.kt:244-246`, `CameraBridge.cpp:174-199`,
`GpuRenderer.cpp:415-441` (processed) / `:630-641` (raw).

### How iOS must do it — `FlutterTexture` + `CVPixelBuffer` + IOSurface

iOS Flutter's texture path is `FlutterTexture.copyPixelBuffer() -> CVPixelBuffer`. The name
is misleading: **`copyPixelBuffer` does not copy pixels** — the implementation returns a
*retained reference* to an existing `CVPixelBuffer`. Flutter's iOS embedder then wraps that
buffer as a Metal texture via `CVMetalTextureCacheCreateTextureFromImage`, which is
**genuinely zero-copy when the `CVPixelBuffer` is IOSurface-backed**: the IOSurface is
shared GPU memory; Flutter's Metal texture and CameraKit's are two *views* onto the same
IOSurface. No pixel copy.

CameraKit's lane buffers are *already* IOSurface-backed — a standing CLAUDE.md invariant
(`naturalTex` / `processedTex` are CVPixelBuffer/IOSurface-backed; the `MTLTexture`
accessors are views onto those same surfaces). So the shared-memory primitive is in place.

| | Android | iOS |
|---|---|---|
| Shared primitive | `ANativeWindow` buffer queue | **IOSurface** |
| Direction | **push** — native renders into Flutter's `Surface` | **pull** — adapter returns the latest `CVPixelBuffer` when Flutter asks; `textureFrameAvailable()` nudges it |
| Texture id | `SurfaceProducer.id()` | id returned by `registerTexture(FlutterTexture)` |
| Per-frame copy | none | none (IOSurface-backed `CVPixelBuffer`) |

The one real asymmetry is push-vs-pull cadence — both are genuinely zero-copy.

### What Phase 2 leaves in place for Phase 3

- Lane buffers are IOSurface-backed `CVPixelBuffer`s (pre-existing invariant).
- **`currentPixelBuffer(stream:) -> CVPixelBuffer?`** — a synchronous `nonisolated`
  accessor added in Phase 2 (§2c), mirroring `currentTexture()`. This is the cheap "latest
  buffer for this lane" pull the bridge needs.
- **`streamPixelFormat`** on `SessionCapabilities` (and the §2d.7 contract field) — Phase 2
  also verifies the lane format is texture-cache-compatible (see constraint below).

### What Phase 3 must build

- One `FlutterTexture` implementation per surfaced lane (natural, processed). Its
  `copyPixelBuffer()` returns a retained reference to `engine.currentPixelBuffer(stream:)`
  for that lane.
- A frame-availability signal: on each new frame for a lane, call
  `registry.textureFrameAvailable(textureId)` so Flutter pulls. The trigger can be the
  `consumers.subscribe(stream:)` AsyncStream (one lightweight `Task` per lane that only
  signals — it does *not* carry pixels) or a lighter per-frame hook.
- `registerTexture(...)` for each lane at open; populate `naturalTextureId` /
  `previewTextureId` (the `Int` placeholders on `SessionCapabilities`) with the registry
  ids; tear down on close.
- The `CamStreamConfiguration` texture-ID field (deferred from §2d.2) is minted here.

### Pixel-format constraint

`CVMetalTextureCacheCreateTextureFromImage` is zero-copy **only** for a cache-compatible
format — `kCVPixelFormatType_32BGRA` is the safe one. Phase 2 (§2d.7) confirms CameraKit's
lane buffers are emitted in a cache-compatible format. If they are not, the Phase-3 bridge
is forced into a per-frame CPU copy — which is the exact failure this section exists to
prevent. Treat a format mismatch surfaced in Phase 2 as a blocker, not a Phase-3 problem.

### Open question for the Phase 3 plan

Pull cadence vs. staleness: the pull model means Flutter samples on its own vsync, so a
slow Flutter frame can re-display the previous buffer, and a fast one can pull the same
buffer twice. This is normally fine for preview, but if Phase 3 finds tearing or visible
staleness, the mitigation is to gate `textureFrameAvailable()` to one signal per produced
frame and ensure `copyPixelBuffer` returns a *stable* reference for the duration of a pull.
Decide empirically on device; do not over-engineer pre-emptively.

---

## 2. Other Phase 3 carry-forward items

These are decided or flagged in the Phases 1–2 design; collected here so Phase 3 has them
in one place. The authoritative text is in `2026-05-14-camerakit-flutter-migration-design.md`.

- **Pigeon adapter absorbs all wire baggage** — handle/`Int64` addressing, `Cam*` ↔ native
  translation, `AsyncStream` → `FlutterApi` callback pumping (`Task { for await … }` per
  stream), `Result` completion handlers. None of this is in `CameraEngine`.
- **`open()` mapping** — Pigeon `open(cameraId, settings)` →
  `engine.open(OpenConfiguration(cameraId:, captureResolution:, cropRegion:, initialSettings:))`.
  Pigeon carries no explicit resolution, so the adapter opens at the default highest native
  resolution `Size(4032, 3024)`; `cropRegion` comes from `CamSettings.cropOutputSize`;
  the rest of `CamSettings` becomes `initialSettings`. (`OpenConfiguration.initialSettings`
  is added in Phase 2 §2a.)
- **`getNativePipelineHandle()` sign/nullability bridge** — Pigeon types the handle
  `Int64?`; CameraKit's Swift surface is `UInt64`. The adapter bridges sign + nullability.
- **Contract amendments to apply** — all of §2d: `rawStream*` → `naturalStream*`;
  `onCapabilitiesChanged` → `onStreamConfigurationChanged` + the new lean
  `CamStreamConfiguration` (texture-ID field minted here); Android-only fields kept and
  no-op'd on iOS; `photosDestination` + `PHAsset`-id return shape; `interrupted` state;
  permission query/request host methods; `streamPixelFormat`.
- **`captureNaturalPicture`** — deferred to Phase 3; a genuinely new capture path
  (`AVCapturePhotoOutput`), not vocabulary work.
- **Calibration host methods — pending** — *if* the §2b WB-calibration review concludes a
  contract amendment is warranted, Phase 3 adds `calibrateWhiteBalance` /
  `calibrateBlackBalance` host methods to the Pigeon contract **and** moves Android's
  calibration loop down from Dart (`cambrian_camera_controller.dart`) into
  `CameraController.kt`. This item is **not yet confirmed** — see §2b of the design doc.
- **Lifecycle stays plugin-internal** — `backgroundSuspend` / `backgroundResume` and
  `AVCaptureSession` interruption observation are owned by the iOS plugin (mirroring
  Android's `ProcessLifecycleObserver`); they are not contract surface. Pigeon
  `pause` / `resume` map to `engine.pause()` / `engine.resume()` (the semantic ones).
- **Packaging choice is unconstrained** — Flutter SPM-plugin support vs. CocoaPods
  vendoring is a Phase 3 decision; Phases 1–2 do not constrain it.
- **Harness-only surface has no Pigeon counterpart** — `currentTrackerTexture()` + tracker
  stream/registration, `consumers.metricsStream()`, `currentSettingsSnapshot()`,
  `dumpDeviceFormats()`. Phase 3 must know these are deliberately not contract-backed.
