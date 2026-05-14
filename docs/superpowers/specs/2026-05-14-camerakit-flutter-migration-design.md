# CameraKit → Flutter Migration — Design (Phases 1–2)

**Status:** Approved 2026-05-14 · amended 2026-05-14 (Phase 1 split into 1A/1B — OpenCV consumer decoupling added)
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

1. **Phase 1 — Decouple UI and the OpenCV consumer from the package.** Two independent
   workstreams: **1A** moves SwiftUI out of the package and curates the engine's public
   surface; **1B** moves the OpenCV/Canny C++ consumer + the OpenCV xcframework out of the
   package, leaving only the consumer-join seam.
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

## Target architecture

### Engine layering — two layers, mirroring Android

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

### Consumer seam — OpenCV lives outside the package

CameraKit's C++ side already confines OpenCV (ADR-11) and already exposes a
consumer-registration seam — `pixel_sink_pool_register(handle, stream, callbacks)`
(C-ABI) / `ConsumerRegistry.registerCallback(stream:callbacks:)` (Swift). The *only*
OpenCV user is the Canny edge-detection consumer. So the package is made OpenCV-free by
moving that one consumer out and having external code register it through the existing
seam — the package keeps only the *option to join*.

```
Today:                                  Target:
CameraKit/Package.swift                 CameraKit/Package.swift  (OpenCV-FREE)
├── opencv2 (xcframework)               ├── CameraKitCxx  (no opencv2 dep)
├── CameraKitCxx → opencv2              │   ├── PixelSinkPool.cpp   ← join + fan-out
│   ├── PixelSinkPool.cpp               │   ├── CaptureAtomic.cpp   ← capture guard (stays)
│   ├── CannyStubConsumer.cpp (OpenCV)  │   └── include/ PixelSink.hpp · PixelSinkCallbacks.h
│   ├── CaptureAtomic.cpp               │            · PixelSinkMetrics.h  ← PUBLIC SEAM
│   └── include/ …                      ├── CameraKitInterop  (CppCannyStub removed)
├── CameraKitInterop                    └── CameraKit
│   └── …Pool ·…Callbacks ·…Atomic           └── ConsumerRegistry — vends seam, registers
│       · CppCannyStub                            nothing; exposes pool handle via
└── CameraKit                                     getNativePipelineHandle()
    └── ConsumerRegistry — registers
        Canny INTERNALLY               eva-swift-stitch (app)  ← OpenCV lives here
                                       ├── Frameworks/opencv2.xcframework  (app links it)
                                       └── AppCxx/CannyConsumer.cpp  (#include <opencv2/…>
                                              + #include <PixelSinkCallbacks.h>)
```

Subscriber-joins flow — identical for the dev harness now and the Flutter plugin in
Phase 3:

```
App / Flutter plugin                    CameraKit package
engine.open() ───────────────────────▶  produces natural · processed · TRACKER lanes
h = engine.getNativePipelineHandle() ◀─  opaque pool pointer
pixel_sink_pool_register(h, .tracker, ──▶ PixelSinkPool registers the entry
  {on_frame, on_overwrite, …})
…frames… dispatch(.tracker, …) ────────▶ app's on_frame ─▶ cv::Canny  (OpenCV in the app)
```

`getNativePipelineHandle()` — **already in the Pigeon contract** — is the join point. The
`UInt64` it returns is the `uintptr_t` of the C++ pool (`pixel_sink_pool_raw_pointer` of
the same object `pixel_sink_pool_create` produced) — cast it to `void*` to pass to
`pixel_sink_pool_register`. No contract change is needed for the seam itself.

**Two registration paths, one pool:**
- **Swift API** — `engine.consumers.registerCallback(stream:callbacks:)`. *Canonical path
  for the SwiftUI dev harness* (Phase 1B) — Swift-typed, already present.
- **C-ABI** — `pixel_sink_pool_register(handle, stream, callbacks)` against the
  `getNativePipelineHandle()` pointer. *What Phase 3's Flutter plugin native code will
  use.*

Both land in the same `PixelSinkPool`.

---

## Phase 1 — Decouple UI and the OpenCV consumer from the package

Two independent workstreams (either order). Both make the package contain nothing app- or
consumer-specific.

### 1A — Decouple UI from engine

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

### 1B — Decouple the OpenCV consumer from the package

The package's C++ side splits along the seam that **already exists** (see "Consumer seam"
above). **Stays in the package** (`CameraKitCxx`, now OpenCV-free): `PixelSinkPool.cpp`
(join + fan-out), `PixelSink.hpp` + the pool portion of `PixelSinkCallbacks.h` +
`PixelSinkMetrics.h` (the public subscriber seam), and `CaptureAtomic.cpp/.hpp` (the
capture-in-flight guard — not a consumer, no OpenCV). **Moves to the app target**:
`CannyStubConsumer.cpp` + its `canny_stub_*` C-ABI (into its own header), the
`CppCannyStub` interop wrapper, and the `opencv2.xcframework` link.

- `CameraKit/Package.swift` — drop the `opencv2` `binaryTarget` and the
  `CameraKitCxx → opencv2` dependency; `CameraKitCxx` compiles no OpenCV code.
- `PixelSinkCallbacks.h` + `include/module.modulemap` — remove the `canny_stub_*`
  declarations (they move with the Canny source).
- `ConsumerRegistry` / engine setup — delete the *internal* Canny registration call site;
  the package registers no consumer of its own — it vends the seam and exposes the pool
  handle via `getNativePipelineHandle()`. The engine still *produces* the tracker stream;
  it exists precisely for external consumers.
- App target — link `Frameworks/opencv2.xcframework`; add the moved Canny C++ under an
  app-side `AppCxx/` group. The harness registers the Canny consumer via the **Swift API**
  — `engine.consumers.registerCallback(stream: .tracker, callbacks:)` — the canonical path
  for 1B (the C-ABI path is reserved for Phase 3's Flutter plugin native code).
- **Consumer lifecycle is now the app's responsibility** (it was implicit when Canny lived
  in-package): register after each `engine.open()`; treat the handle as dead after
  `engine.close()` and re-register on the next `open()`; the handle stays valid across
  `pause` / `resume` (the pool is kept, only the drain pauses).
- App-side Swift↔C++ interop stays minimal — the Canny consumer is pure C++ exposing a
  single C entry point, so the app needs no package-style `.interoperabilityMode(.Cxx)`
  target.
- Any tests exercising the Canny consumer relocate to the app target alongside it
  (mirroring 1A's test relocation).

**Build gotchas to validate on device:** the app's own `.cpp` files need a header search
path to `CameraKitCxx/include` so `#include <PixelSinkCallbacks.h>` resolves; the app C++
target must match `cxxLanguageStandard: .cxx20`, the `CPP_POOL_THREAD_COUNT` define, and
`CoreVideo` / `IOSurface` linkage.

### Phase 1 critical files

**1A — UI:**
- Move out of `CameraKit/Sources/CameraKit/`: `CameraView.swift`, `ViewModel.swift`,
  `DisplayViewModel.swift`, `RecordingViewModel.swift`, `HardwareControlsViewModel.swift`,
  `ProcessingViewModel.swift`, `CalibrationViewModel.swift` (carries
  `CalibrationEngineProtocol`), `ErrorPresenterViewModel.swift`, `ControlEnablement.swift`,
  `SliderDebouncer.swift`
- `eva-swift-stitch/` app target — destination for the above
- `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`, `Stage10Tests.swift` — relocate / split

**1B — OpenCV consumer:**
- Move out of `CameraKit/Sources/CameraKitCxx/`: `CannyStubConsumer.cpp`; the `canny_stub_*`
  C-ABI split into its own header
- Move out of `CameraKit/Sources/CameraKitInterop/`: `CppCannyStub`
- `CameraKit/Package.swift` — remove the `opencv2` binaryTarget + the `CameraKitCxx`
  dependency on it
- `CameraKit/Sources/CameraKitCxx/include/PixelSinkCallbacks.h`, `include/module.modulemap`
  — remove `canny_stub_*`
- `CameraKit/Sources/CameraKit/PixelSink.swift` + engine setup — delete the internal Canny
  registration
- `eva-swift-stitch/` app target + `eva-swift-stitch.xcodeproj` — new `AppCxx/` group, the
  `opencv2.xcframework` link, the app-side registration call

**Shared:**
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
  call it cross-module. The harness-only surface, **verified against the UI code**:
  - `currentTrackerTexture()` + `consumers.subscribe(stream: .tracker)` +
    `consumers.registerCallback(stream: .tracker, …)` / `unregister()` —
    `DisplayViewModel`'s debug tracker texture + overlay
  - `consumers.metricsStream()` — `ViewModel`'s `FrameDeliveryStats` long-press overlay
  - `currentSettingsSnapshot()` — `HardwareControlsViewModel`'s slider seeding (a Flutter
    UI derives live values from `onFrameResult` instead)
  - `dumpDeviceFormats()` — debug capabilities dump
  Phase 3 must know these are harness-only (no Pigeon counterpart) vs. contract-backed.
- `CameraKitCxx` slimmed to the consumer-join seam (`PixelSinkPool` + `PixelSink.hpp` +
  the pool C-ABI + `CaptureAtomic`); the OpenCV xcframework and the Canny consumer are
  **no longer package targets** — they live in the app (Phase 1B).
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
- Phase 1B does **not** redesign the consumer seam — `pixel_sink_pool_register` /
  `ConsumerRegistry.registerCallback` already exist; 1B only relocates the OpenCV consumer
  that uses them, and removes OpenCV from the package's build graph.
- No changes to the brief pipeline; this runs after Stage 12.

---

## Verification

**Phase 1A — UI**
- CameraKit builds headless via XcodeBuildMCP (`build_run_device`) — no SwiftUI import in
  the package.
- App builds and presents `CameraView()` from the app target on a physical iPad.
- All non-UI Stage01–Stage10 tests pass unchanged.
- Relocated `Stage11Tests` (+ the split `Stage10Tests` case) pass in the app target,
  including `CalibrationEngineStub`-backed calibration tests.

**Phase 1B — OpenCV consumer**
- `CameraKit/Package.swift` has no `opencv2` target; `CameraKitCxx` compiles with zero
  OpenCV includes; the `CameraKit` library builds with no OpenCV in its graph.
- The app links `opencv2.xcframework`, registers its Canny consumer through the seam after
  `engine.open()`, and edge counts flow on device — the Stage 08 Canny behaviour is
  preserved, just app-side.
- Relocated Canny-consumer tests pass in the app target.

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
