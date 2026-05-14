# CameraKit → Flutter Migration — Design (Phases 1–2)

**Status:** Approved 2026-05-14
**Date:** 2026-05-14
**Scope:** Phases 1–2 only (all work stays inside `eva-swift-stitch`). Phase 3 is a separate spec→plan cycle.

---

## Context

CameraKit is *capable* of being headless but currently ships its SwiftUI UI **inside**
the package — `CameraView.swift` + 7 view models, ~1,800 lines under
`CameraKit/Sources/CameraKit/`.

The goal is to get CameraKit into a state where it can be lifted into the
`cambrian_camera` Flutter plugin (`/Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera/`)
— replacing that plugin's no-op iOS stub — and wrapped by Pigeon, **while remaining a
clean standalone Swift package** consumable by native SwiftUI apps.

The Flutter package is the same one `implementation/domain-revised/` was derived from;
its Android side already implements the camera via Camera2. Adding the iOS side this way
gives the Flutter package an iOS camera implementation.

The migration is three phases:

1. **Phase 1 — Decouple UI from engine.** Move SwiftUI out of the package; curate the
   engine's public surface into a clean facade.
2. **Phase 2 — Conform the facade vocabulary to the (amended) Flutter contract**, add the
   in-scope additive capabilities, update the dev harness, leave the package cleanly
   extractable.
3. **Phase 3 — Relocate** the package into the Flutter plugin, wire the Pigeon adapter +
   texture-registry bridge, apply the contract amendments to the Flutter package +
   its Android side. *(Separate spec — out of scope here.)*

**This spec covers Phases 1–2.**

**Sequencing:** This work runs **after Stage 12** of the brief pipeline. Stage 12 (a
MIGRATION stage retiring `10:synchronous-drain-pause`) edits `CameraView.swift` and
`ViewModel.swift` to wire the `FrameDeliveryStats` overlay — the exact files Phase 1
relocates. Stage 12 must finish its UI wiring against those files in place; the migration
then relocates them. Stage 12's changes are otherwise localized and minor relative to
this migration.

---

## Target architecture — two layers, mirroring Android

Android's structure, which we now match:

```
  CambrianCameraPlugin.kt   ──calls──▶   CameraController.kt
  (adapter: implements                  (CONCRETE class — engine AND facade
   Pigeon CameraHostApi,                 in one; no separate interface)
   owns handles + textures)
```

Ours:

```
   SwiftUI dev harness              CambrianCameraPlugin.swift (iOS, Phase 3)
   (native consumer, NO Pigeon)     + CameraHostApi impl
   lives in eva-swift-stitch        Flutter consumer, via Pigeon
          │                                 │
          │  calls directly                 │  calls directly
          ▼                                 ▼
   ┌──────────────────────────────────────────────────┐
   │  actor CameraEngine        ENGINE = FACADE        │
   │  public surface = contract ops + a small harness- │
   │  only debug surface; other helpers → internal     │
   │  CameraSession · MetalPipeline · Recording ·      │
   │  StillCapture · PixelSink · Watchdog · Recovery   │
   └──────────────────────────────────────────────────┘
```

| Layer | Android equivalent | Our version |
|---|---|---|
| Engine + facade | `CameraController.kt` (concrete class) | **`CameraEngine` actor** — curated public surface IS the facade; no separate protocol |
| Consumers | `CambrianCameraPlugin.kt` (Pigeon) | (a) SwiftUI dev harness — native, no Pigeon, in `eva-swift-stitch`; (b) iOS `CambrianCameraPlugin` + `CameraHostApi` impl — via Pigeon, in `camera2_flutter_demo/ios`, **built in Phase 3** |

### Why no facade protocol

An earlier draft proposed a `CameraController` protocol. It was dropped after checking the
existing test suite:

- **Mockability is barely used.** 6 of the 7 view models are tested against a *real but
  un-opened* `CameraEngine` (`CameraEngine()` with no `open()` call — hardware never
  runs). Only `CalibrationViewModel` uses a true engine double — `CalibrationEngineStub`
  conforming to the existing `CalibrationEngineProtocol` (`CalibrationViewModel.swift:8`,
  `Stage11Tests.swift:249`). A package-wide facade protocol would not be earning its keep.
- **Android proves the 2-layer shape works.** Its plugin calls the concrete
  `CameraController` directly; no interface.
- **Less ceremony.** The facade is simply `CameraEngine`'s curated public surface.

`CalibrationEngineProtocol` + `CalibrationEngineStub` are **kept as-is** — that one real
mock seam keeps working and moves to the app target alongside `CalibrationViewModel`.

The Pigeon wire baggage — handle/`Int64` addressing, `Cam*` ↔ native translation,
`AsyncStream` → `FlutterApi` callback pumping, `Result` completion handlers — is **not**
in `CameraEngine`. It is absorbed entirely by the Phase 3 Pigeon adapter.

---

## Phase 1 — Decouple UI from engine

**Relocate SwiftUI out of the package** into the `eva-swift-stitch` app target:
`CameraView.swift`, `ViewModel.swift`, the 6 child view models
(`DisplayViewModel`, `RecordingViewModel`, `HardwareControlsViewModel`,
`ProcessingViewModel`, `CalibrationViewModel`, `ErrorPresenterViewModel`),
`ControlEnablement.swift`, `SliderDebouncer.swift`. `CalibrationEngineProtocol` (defined
in `CalibrationViewModel.swift`) and the `extension CameraEngine: CalibrationEngineProtocol`
move with them; the app target adds the retroactive conformance.

The relocation inventory is the **post-Stage-12 versions** of these files. Stage 12 edits
`CameraView.swift` and `ViewModel.swift` to wire the `FrameDeliveryStats` long-press
overlay (`for await stats in consumers.metricsStream()`); that overlay wiring relocates
with the files.

**The view models keep depending on `CameraEngine` concretely** (as they do today) — it is
now imported from the CameraKit package as a public type. No protocol indirection is
introduced.

**Relocate UI-coupled tests:** `Stage11Tests.swift` (19 UI references, including
`CalibrationEngineStub`) moves to the app-target test location; the single UI reference in
`Stage10Tests.swift` is split out or moved. **These tests exit dual-membership** — once
the UI types leave the package they can no longer compile in the SwiftPM `.testTarget`,
so they live *only* under the Xcode `eva-swift-stitchTests` target (single-target, not
dual-membered — a deliberate exception to the CLAUDE.md §8 default). Re-wire via
`scripts/sync-test-target.sh`. All other Stage01–Stage10 tests have zero UI references,
stay put, and remain dual-membered.

**Public-surface note:** anything a relocated view model still calls on `CameraEngine`
*must remain `public`* (cross-module). So surface *curation* (marking helpers `internal`)
is largely deferred to Phase 2 — it is gated on the calibration-move-down removing the
last fine-grained-helper calls from the UI (see §2b).

**Result:** CameraKit builds with zero SwiftUI import; `eva_swift_stitchApp.swift`
presents `CameraView()` now sourced from the app target.

### Phase 1 critical files

- Move out of `CameraKit/Sources/CameraKit/`: `CameraView.swift`, `ViewModel.swift`,
  `DisplayViewModel.swift`, `RecordingViewModel.swift`, `HardwareControlsViewModel.swift`,
  `ProcessingViewModel.swift`, `CalibrationViewModel.swift` (carries
  `CalibrationEngineProtocol`), `ErrorPresenterViewModel.swift`, `ControlEnablement.swift`,
  `SliderDebouncer.swift`
- `eva-swift-stitch/` app target — destination for the above
- `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`, `Stage10Tests.swift` — relocate / split
- `CameraKit/Package.swift`, `eva-swift-stitch.xcodeproj` — target membership updates
- `CameraKit/CONTRACTS.md`, `CameraKit/state.md`, `CameraKit/DECISIONS.md` — regen / update

---

## Phase 2 — Conform vocabulary + additive capabilities + contract amendments

### 2a. Vocabulary alignment

Rename `CameraEngine`'s public methods/types to the contract's vocabulary **where the
contract and CameraKit already mean the same thing** (gap-analysis EXACT / PARTIAL rows).
Examples:

- `setProcessingParameters` → `setProcessingParams`
- `focusDistance` → `focusDistanceDiopters`
- `RgbSample` / `ProcessingParameters` field names aligned to `CamRgbSample` / `CamProcessingParams`

**Rules** (per user direction):
- Align only where there's a real semantic match.
- **CameraKit-only capabilities stay as-is** — `backgroundSuspend` / `backgroundResume`,
  `setCropRegion`, `currentTexture` / `currentProcessedTexture` / `currentTrackerTexture`,
  the rich WB helpers. The contract doesn't have these; we keep them.
- Contract operations iOS genuinely **cannot** provide → documented "not applicable on
  iOS," not implemented. (See §2d.)
- Anything **ambiguous** → surfaced to the user for a decision, not decided unilaterally.

### 2b. Calibration orchestration moves down

The contract's calibration surface is just `sampleCenterPatch`. Today the multi-step
WB/BB algorithms (sample patch → compute gains → apply → await convergence) live in
`CalibrationViewModel` — camera-control logic that leaked into the UI.

Add `calibrateWhiteBalance()` / `calibrateBlackBalance()` to `CameraEngine`.
`CalibrationViewModel` becomes a thin caller. Once the VM stops calling the fine-grained
helpers (`applyManualGainsAndAwait`, `awaitWBSettled`, `sampleCenterPatchForBBCalibration`,
`setWBPreset`, `awaitAESettled`, …), **those helpers can be marked `internal`** — this is
the surface-curation step that Phase 1 had to defer.

`CalibrationEngineProtocol` shrinks accordingly (it now needs only the high-level
`calibrate*` operations + whatever the thinned VM still touches); `CalibrationEngineStub`
is updated to match.

> **Note:** This partially reverses Stage-11's ADR-21 decomposition (where
> `CalibrationViewModel` owns `calibrateWB()` / `calibrateBB()` / `resetToAutoWB()` /
> `lockCurrentWB()` / `resetBlackBalance()`). A `CameraKit/DECISIONS.md` entry records the
> rationale: the orchestration is camera-control logic, the contract expects it
> engine-side, Phase 3's Pigeon adapter needs it there, and it is what unlocks shrinking
> the public surface.

### 2c. Additive capabilities (in scope)

- **Capability range fields** — populate focus / zoom / EV-comp min-max on
  `SessionCapabilities`. The contract's `CamCapabilities` already has these slots; CameraKit
  just needs to expose them. **No contract change needed.**
- **Active-config-changed stream** — CameraKit emits a stream when the active resolution /
  crop / texture-ID changes (the correctly-conceived version of `onCapabilitiesChanged`;
  see §2d.2).
- **Natural-stream vocabulary** — CameraKit's surface uses "natural stream" terminology
  consistently; the raw↔natural mapping is documented (see §2d.1).

**Deferred to Phase 3:** `captureNaturalPicture` (raw hardware JPEG via
`AVCapturePhotoOutput`) — a genuinely new capture path, not vocabulary work.

### 2d. Proposed contract amendments

Decisions are made here; **applied** to `pigeons/camera_api.dart` and the Flutter
package's Android side in **Phase 3**. CameraKit's Phase-2 conformance targets the
*amended* vocabulary.

1. **`rawStream*` → `naturalStream*`.** Rename `enableRawStream` / `rawStreamHeight` on
   `CamSettings` and `rawStreamTextureId` / `rawStreamWidth` / `rawStreamHeight` on
   `CamCapabilities`. CameraKit's model is a *natural* (unprocessed/hardware) stream + a
   *processed* (color-transformed) stream — and `domain-revised` already uses "natural."
   "Raw stream" is just the Android name. Renaming aligns the contract with the domain doc
   and CameraKit instead of importing an Android-ism.

2. **`onCapabilitiesChanged` → `onStreamConfigurationChanged`.** A **rename + payload
   reshape of the existing callback**, not a new one. The current callback's own doc
   comment says it fires when "the effective post-GPU output dimensions change … after
   `cropOutputSize` is set or cleared, or after `setResolution` resolves to a new camera
   stream size." That's an *active-selection* event, not a *capabilities* event.
   - Method: `onCapabilitiesChanged` → `onStreamConfigurationChanged`
   - Payload: **decided** — a new lean `CamStreamConfiguration` carrying only what
     actually changed (active resolution + active crop + texture IDs), replacing the heavy
     `CamCapabilities`. Phase 3 adds the new Pigeon type and updates the Android side to
     build/send it.

3. **Android-only fields** — `noiseReductionMode`, `edgeMode` on `CamSettings`; error
   codes `cameraDevice`, `cameraService`, `cameraDisabled`, `maxCamerasInUse`,
   `previewSurfaceLost`, `pipelineError`. **Decided** — kept in the contract (one shared
   cross-platform shape); the iOS implementation no-ops these fields and never emits these
   error codes. No contract removal.

**iOS-specific additions.** Just as the contract carries Android-isms, a faithful iOS
implementation needs surface the Android-derived contract lacks. Decided now; applied to
`pigeons/camera_api.dart` + the Android side in Phase 3. Lifecycle
(`backgroundSuspend` / `backgroundResume`, `AVCaptureSession` interruption *observation*)
stays inside the iOS plugin — as Android does via `ProcessLifecycleObserver` — and needs
no contract surface.

4. **Photos-library capture destination.** Add a `photosDestination` option to
   `captureImage` / `captureNaturalPicture` and a return shape that can carry a `PHAsset`
   local identifier, not just a filesystem path — iOS photo-library saves go through the
   Photos framework and yield no file path. CameraKit already models this
   (`captureImage`'s `photosDestination` parameter) → no Phase-2 CameraKit surface change.

5. **`interrupted` `SessionState`.** Add `interrupted` (distinct from `recovering` /
   `error`) for routine iOS/iPad `AVCaptureSession` interruptions — Control Center, phone
   call, Split View / Stage Manager, another app taking the camera. Expected,
   auto-resuming, not an error. **Requires a Phase-2 CameraKit surface change:**
   `SessionState` today has `.closed/.opening/.streaming/.recovering/.paused/.error` —
   add `.interrupted`.

6. **Permission query/request methods.** Add `cameraPermissionStatus()` /
   `requestCameraPermission()` host methods (+ Photos add-permission). iOS has
   `notDetermined` / `denied` / `restricted` / `authorized`; Flutter must query + prompt
   before `open()` rather than discovering denial as an open failure. **Requires a Phase-2
   CameraKit surface change:** expose these on `CameraEngine` —
   `AVCaptureDevice.authorizationStatus` for camera, the existing `PhotosLibraryClient`
   wrapper for Photos.

7. **`streamPixelFormat` on `CamCapabilities`.** Add a pixel-format field so the Flutter
   side can interpret the iOS `CVPixelBuffer` textures. CameraKit's `SessionCapabilities`
   already exposes `streamPixelFormat` → no Phase-2 CameraKit surface change. (Leans
   Phase-3 texture-bridge, but the contract decision belongs here.)

### 2e. "Cleanly extractable" — Phase 2 exit criteria

- CameraKit package contains **zero** SwiftUI / app-target code.
- Public surface = `CameraEngine`'s curated surface + value types. "Curated" is **not**
  literally "= the contract": it is *contract operations + a small harness-only debug
  surface* that has no Pigeon counterpart and stays `public` because relocated view models
  call it cross-module:
  - `consumers.registerCallback(stream: .tracker, …)` — `DisplayViewModel`'s debug tracker overlay
  - `deviceSnapshotStream()` — `ViewModel`'s KVO-fed device-state subscription
  Phase 3 must know these are harness-only (no Pigeon counterpart) vs. contract-backed.
- `CameraKitCxx` + the OpenCV xcframework untouched, still package targets.
- The package still builds **only via the xcodeproj / XcodeBuildMCP** — standalone
  `swift build` still does not work (iOS-only AVFoundation); unchanged and acceptable.
- Phase 3's packaging choice (Flutter SPM-plugin support vs. CocoaPods vendoring) is left
  **unconstrained**.

### Phase 2 critical files

- `CameraKit/Sources/CameraKit/CameraEngine.swift` — renamed methods, `calibrate*` added,
  fine-grained helpers demoted to `internal`, `cameraPermissionStatus()` /
  `requestCameraPermission()` added (§2d.6)
- `CameraKit/Sources/CameraKit/Settings.swift`, `Capabilities.swift`, `FrameSet.swift`,
  `SessionState.swift`, `Errors.swift` — field/type vocabulary alignment; capability
  range fields; `SessionState.interrupted` added (§2d.5)
- `eva-swift-stitch/…` — relocated harness updated to conformed vocabulary;
  `CalibrationViewModel` thinned to a caller; `CalibrationEngineProtocol` / `…Stub` shrunk
- `CameraKit/Tests/CameraKitTests/` — **new engine-side tests** for `calibrateWhiteBalance()`
  / `calibrateBlackBalance()`: the algorithm moved engine-side, so its tests belong in
  CameraKit's test target (dual-membered, like the other Stage tests)
- relocated `CalibrationViewModel` tests (app target) — **thinned to wiring-only**
  assertions now that orchestration is engine-side
- `CameraKit/DECISIONS.md` — ADR-21 calibration-move-down rationale
- `CameraKit/CONTRACTS.md`, `CameraKit/state.md` — regen / update

---

## Out of scope / non-goals

- **Phase 3:** physical relocation into `camera2_flutter_demo`, the Pigeon adapter
  (`CambrianCameraPlugin.swift` iOS + `CameraHostApi` impl), the texture-registry bridge,
  applying the contract amendments to the Flutter package + Android, `captureNaturalPicture`.
- **Not** collapsing the 7 view models into a unified mediator — ADR-21 decomposition is
  preserved (except the deliberate calibration-orchestration move-down in §2b).
- No facade protocol — `CameraEngine`'s curated public surface is the facade.
- No changes to the brief pipeline; this runs after Stage 12.

---

## Verification

**Phase 1**
- CameraKit builds headless via XcodeBuildMCP (`build_run_device`) — no SwiftUI import in
  the package.
- App builds and presents `CameraView()` from the app target on a physical iPad.
- All non-UI Stage01–Stage10 tests pass unchanged.
- Relocated `Stage11Tests` (+ the split `Stage10Tests` case) pass in the app target,
  including `CalibrationEngineStub`-backed calibration tests.

**Phase 2**
- `CameraEngine`'s curated surface compiles clean under Swift 6 strict concurrency
  (`SWIFT_STRICT_CONCURRENCY = complete`); demoted helpers are `internal`.
- The harness runs on a physical iPad with the conformed vocabulary.
- WB / BB calibration still works on-device (HITL) after the orchestration move-down.
- New capability range fields (focus / zoom / EV-comp) are populated and non-zero.
- The active-config stream fires on `setResolution` and `setCropRegion`.
- `SessionState.interrupted` is emitted on an `AVCaptureSession` interruption and clears
  on resume.
- `cameraPermissionStatus()` reports the correct status; `requestCameraPermission()`
  triggers the system prompt.
- `CONTRACTS.md` regenerates clean; scaffold inventory unchanged.

---

## Working principles

- Any per-method vocabulary rename that turns out ambiguous during implementation is
  surfaced to the user rather than decided unilaterally (§2a).

*(All design decisions flagged during brainstorming are resolved — see §2d.)*
