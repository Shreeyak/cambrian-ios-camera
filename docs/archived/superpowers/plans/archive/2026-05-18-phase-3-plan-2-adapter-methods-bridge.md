> **SUPERSEDED 2026-05-20** by `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. This plan targeted cam2fd integration which is no longer the architecture. Phase B's plan will be written fresh.

# Phase 3 — Plan 2: Adapter + Host Methods + Texture Bridge

> **For agentic workers (opus or similar):** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. This plan is **lean by design** — task boundaries + acceptance metrics, not exhaustive code blocks. Read the spec for design context; read the engine surface (`packages/cambrian_camera/ios/CameraKit/CONTRACTS.md` + `Sources/CameraKit/CameraEngine.swift`) for API shapes; write the code yourself.

**Goal:** Replace every `not_implemented` HostApi stub from Plan 1 with a real `CameraEngine` call. Wire the per-stream `AsyncStream → FlutterApi` pump. Implement the per-lane `FlutterTexture` bridge for `.natural` and `.processed`. Add the scene-phase lifecycle observer. Exit state: preview renders in Dart `Texture(textureId:)` widgets; every spec contract method works end-to-end on device; calibration host methods are the only remaining stubs (Plan 3).

**Architecture:** Per spec §3 — `HandleRegistry` actor maps `Int64` ↔ `CameraEngine`; `PigeonValueMapping` translates per spec §3 mapping table (including D-2P-01 `focusDistance` ↔ `focusDistanceDiopters` rename); `CameraHostApiImpl` is mechanical translation, never invents semantics; `FlutterApiPump` runs one Task per AsyncStream per handle; `CameraLaneBridge` runs a per-lane subscriber Task firing `textureFrameAvailable`; lifecycle observer routes scene-phase to `engine.notifyScenePhasePaused`. iOS-side §5.3 silent-ignore of Android-only fields. iOS-side §5.4 Photos library impl. iOS-side §5.6 permission impls routing to `CameraEngine`'s `nonisolated static` helpers.

**Tech Stack:** Swift 5 (plugin) + Swift 6 (CameraKit, consumed). Flutter `FlutterTextureRegistry`, `FlutterTexture`. AVFoundation lifecycle observers (already on the engine; plugin owns scene-phase only). Photos framework (`PHPhotoLibrary`) for §5.4 — already wired in `CameraEngine.captureImage`/`captureNaturalPicture`, so the iOS plugin side is pass-through.

**Spec source:** `docs/superpowers/specs/2026-05-18-phase-3-design.md` §3 (Pigeon adapter), §4 (FlutterTexture bridge), §5.3/§5.4/§5.6 (iOS-side amendments), §11 (working principles).

**Prerequisite:** Plan 1 merged in cam2fd; `ios/CameraKit/` subtree present; SPM scaffold builds clean; HostApi stubs throw `not_implemented`.

**Working branch (cam2fd):** `phase-3-plan-2-adapter-methods-bridge`, off cam2fd main after Plan 1 merge.

**Reference reads (do these before starting):**
- Spec §3 mapping table — every Cam* ↔ CameraKit conversion
- `ios/CameraKit/CONTRACTS.md` — engine public surface (always fresh)
- `ios/CameraKit/Sources/CameraKit/CameraEngine.swift` — exact method signatures
- `ios/CameraKit/Sources/CameraKit/Settings.swift`, `Capabilities.swift`, `FrameSet.swift`, `SessionState.swift`, `Errors.swift` — value types

---

## Decisions taken (per spec; do not relitigate)

- **D-2P-01 — `focusDistance` rename happens in the adapter, not the engine.** Engine field stays `focusDistance` (iOS `lensPosition` is `[0, 1]`, not diopters). Wire field is `focusDistanceDiopters`. `PigeonValueMapping` does the rename only.
- **Single-engine impl-edge guard.** `CameraHostApiImpl.open(...)` serializes against a `var openInFlight: Bool` (or `AsyncSemaphore`); second concurrent open throws `PigeonError(code: "open_in_flight", ...)`. `HandleRegistry` only tracks the post-construct state.
- **Lifecycle is plugin-internal.** Scene-phase observer routes through `engine.notifyScenePhasePaused(_:)` (Phase 2 added this). AVF interruption observation stays inside `CameraEngine`. Pigeon `pause`/`resume` map to `engine.pause()`/`engine.resume()` (the semantic ones — Stage 10 gate).
- **Tracker lane is not bridged.** No FlutterTexture for `.tracker`. C++ consumers use `getNativePipelineHandle()` + `pixel_sink_pool_register` directly.
- **BGRA8 wire format.** `streamPixelFormat = "BGRA8"` (Phase 2 default per D-2P-11). Texture bridge wraps as `.bgra8Unorm` via Flutter's iOS embedder; zero-copy guaranteed.
- **§5.3 iOS-side ignore.** `PigeonValueMapping.toCameraSettings(_ cam: CamSettings)` reads `noiseReductionMode` / `edgeMode` and silently drops them. The reverse direction (CameraKit → Cam*) does not populate them.
- **`captureNaturalPicture` already engine-side** (D-2P-10). iOS impl is one-line dispatch.
- **`getNativePipelineHandle` sign+nullability bridge** — `UInt64?` → `Int64?` via `Int64(bitPattern:)`. Per spec §3.
- **Texture bridge is "simple pull"** (texture-bridge spike verdict). No mitigations. `CameraLaneTexture.copyPixelBuffer()` returns `Unmanaged.passRetained(engine.currentPixelBuffer(stream:))`.
- **CamStreamConfiguration texture-IDs are stable across an open session.** Minted once at `open()`, carried on every `onStreamConfigurationChanged` emission.

---

## File Inventory (cam2fd, all under `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/`)

### Created

- `HandleRegistry.swift` — actor; Int64 ↔ CameraEngine map
- `PigeonValueMapping.swift` — every conversion from spec §3 table; pure functions
- `FlutterApiPump.swift` — per-handle Task set bridging engine AsyncStreams to FlutterApi callbacks
- `CameraLaneTexture.swift` — `FlutterTexture` implementation
- `CameraLaneBridge.swift` — per-lane subscriber Task firing `textureFrameAvailable`
- `LifecycleObserver.swift` — scene-phase observer (UIScene notifications) routing to engine

### Modified (existing from Plan 1)

- `CambrianCameraPlugin.swift` — instantiate registry + texture-registry handle + lifecycle observer at `register(with:)`; wire to HostApi impl
- `CameraHostApiImpl.swift` — every method body replaced with real engine call via registry

### Not touched

- `ios/CameraKit/**` — subtreed snapshot, treated as a release artifact
- Pigeon inputs / generated files — Plan 1 owned the contract; Plan 2 only consumes
- Android side — Plan 2 is iOS-only

---

## Pre-flight

### Task 0: Verify Plan 1 state intact + branch

- [ ] cam2fd is on main; Plan 1 commits present; `flutter analyze` clean
- [ ] `ls packages/cambrian_camera/ios/CameraKit/Package.swift` — exists
- [ ] `grep -r "not_implemented" packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift` — every method body is a stub
- [ ] Branch: `git checkout -b phase-3-plan-2-adapter-methods-bridge`
- [ ] iPad UDID recorded (xctrace + devicectl); both reachable

**Acceptance:** baseline `flutter build ios --debug --no-codesign` succeeds (the post-Plan-1 build).

---

## Cluster D — Adapter foundation

### Task D1: `HandleRegistry` actor

**File:** `HandleRegistry.swift`

**Goal:** Thread-safe `Int64 ↔ CameraEngine` map. Monotonic handle counter starting at 1. `register(_:) -> Int64`, `resolve(_:) throws -> CameraEngine` (throws `notFound`), `unregister(_:)`. Open-in-flight serialization belongs in `CameraHostApiImpl.open`, NOT here.

**Acceptance:**
- Unit test (`example/ios/RunnerTests/HandleRegistryTests.swift`): register N engines → resolve each → unregister → resolve throws `notFound`. Concurrent registers from 10 Tasks all return distinct handles.
- Plan 2 cluster F build smoke (after `open` is wired) shows the registry yielding `handle == 1` on first open.

**Reference:** Spec §3 "Handle ownership".

### Task D2: `PigeonValueMapping`

**File:** `PigeonValueMapping.swift`

**Goal:** Pure conversion functions per spec §3 table. One function per type pair, both directions where relevant:

- `func toCameraSettings(_ cam: CamSettings) -> CameraSettings` — drops `noiseReductionMode`/`edgeMode` (§5.3 ignore); renames `focusDistanceDiopters` → `focusDistance` (D-2P-01)
- `func toCamSettings(_ s: CameraSettings) -> CamSettings` — inverse; `noiseReductionMode`/`edgeMode` always null on iOS; rename inverse
- `func toCamCapabilities(_ caps: SessionCapabilities, naturalTextureId: Int, previewTextureId: Int) -> CamCapabilities` — populates texture-ID fields from arguments (the texture bridge passes them in)
- `func toCamStreamConfiguration(_ cfg: StreamConfiguration, naturalTextureId: Int, previewTextureId: Int) -> CamStreamConfiguration`
- `func toCamStateUpdate(_ state: SessionState) -> CamStateUpdate` — lowercase string per spec §3
- `func toCamError(_ err: CameraError) -> CamError` — code mapping per spec §3; Android-only codes never produced
- `func toCamFrameResult(_ r: FrameResult) -> CamFrameResult` — same D-2P-01 rename
- `func toCamRgbSample(_ s: RgbSample) -> CamRgbSample`
- `func toCamProcessingParams(_ p: ProcessingParameters) -> CamProcessingParams` / inverse
- `func toCamPhotosDestination(_ dest: CamPhotosDestination?) -> CameraKit.PhotosDestination?` — adapt to whatever shape the engine's `captureImage` already accepts
- `func toCamCaptureResult(filePath: String?, phAssetLocalId: String?) -> CamCaptureResult`

**Acceptance:**
- Unit tests (`example/ios/RunnerTests/PigeonValueMappingTests.swift`): one round-trip test per pair (`Cam* → CameraKit → Cam*` yields identity for valid inputs). 12+ tests total.
- `focusDistanceDiopters` rename: assert `toCameraSettings(CamSettings(focusDistanceDiopters: 0.5)).focusDistance == 0.5` and inverse populates `focusDistanceDiopters`.
- `noiseReductionMode`/`edgeMode` drop: assert `toCameraSettings(CamSettings(noiseReductionMode: 3, edgeMode: 2))` yields a `CameraSettings` with no equivalent fields set.
- Android-only error codes never round-trip: assert `toCamError` never emits `cameraDevice`/`cameraService`/etc. from any `CameraError` input.

**Reference:** Spec §3 mapping table, spec §5.3.

### Task D3: `LifecycleObserver`

**File:** `LifecycleObserver.swift`

**Goal:** UIScene-based observer. On `UIScene.didEnterBackgroundNotification`, call `engine.notifyScenePhasePaused(true)` for every open handle in the registry. On `UIScene.willEnterForegroundNotification`, call `notifyScenePhasePaused(false)`. Plugin registers this once at `register(with:)`; observer holds a weak reference to the `HandleRegistry`.

**Acceptance:**
- Background the example app on iPad with a session open; observe `[scenePhase]` log lines in CameraKit's device log file (per CameraKit's `Logger.notice` plumbing).
- Foreground → preview resumes; `SessionState` stream emits `"paused"` → `"streaming"` (via `FlutterApiPump`, once that's wired in D4).

**Reference:** Spec §3 "Lifecycle is plugin-internal — does not appear on Pigeon"; D-2P-07.

### Task D4: `FlutterApiPump`

**File:** `FlutterApiPump.swift`

**Goal:** One pump per open handle. Owns N Tasks (one per engine stream). Each Task `for await`s the engine stream, maps the value via `PigeonValueMapping`, dispatches the matching `FlutterApi` callback on the main thread. Streams covered:
- `engine.stateStream()` → `onStateChanged(handle, CamStateUpdate)`
- `engine.errorStream()` → `onError(handle, CamError)`
- `engine.frameResultStream()` → `onFrameResult(handle, CamFrameResult)`
- `engine.streamConfigurationStream()` → `onStreamConfigurationChanged(handle, CamStreamConfiguration)` (uses texture-IDs from the bridge — see Task F4)
- `engine.recordingStateStream()` → `onRecordingStateChanged(handle, String)`

Pump lifecycle: created in `CameraHostApiImpl.open` after engine construction; `stop()` cancels all Tasks; called from `CameraHostApiImpl.close` before `engine.close()`.

**Acceptance:**
- After open, on-device flutter app sees `onStateChanged` fire with `"opening"` then `"streaming"`.
- `onFrameResult` fires at ~3 Hz with non-null sensor values once streaming.
- `onStreamConfigurationChanged` fires after `setResolution`.
- After close, no callbacks fire (Tasks cancelled).

**Reference:** Spec §3 "AsyncStream → FlutterApi pump".

---

## Cluster E — Host methods (real impls)

Replace every `not_implemented` stub in `CameraHostApiImpl.swift`. Each method follows the same shape:

```
1. Resolve handle from registry → throw not_found on miss
2. Convert input via PigeonValueMapping
3. Call engine method
4. Convert output via PigeonValueMapping
5. Return / complete success; map errors to PigeonError(code:, message:, details:)
```

The list of error codes to use is documented inline below; pick one per method. Never invent new error codes — every error maps to a documented Pigeon error code or `unknown`.

### Task E1: `open` + impl-edge open-in-flight guard

**Methods:** `open(cameraId:, settings:, completion:)`

**Goal:**
- Serialize concurrent opens via `var openInFlight: Bool` + a small lock or `AsyncSemaphore(value: 1)`. Second concurrent open → `PigeonError(code: "open_in_flight", ...)`.
- Construct `CameraEngine()`; call `engine.open(OpenConfiguration(cameraId:, captureResolution: Size(4032, 3024), cropRegion: settings?.cropOutputSize, initialSettings: settings))` per spec §2a.
- On success: register engine in `HandleRegistry`; instantiate `CameraLaneBridge` for `.natural` + `.processed` (Cluster F); start `FlutterApiPump`; return handle.
- On engine throw: clean up partial state (no engine to close — it threw); map error.

**Acceptance:** Two concurrent `open()` calls from Dart → second throws `open_in_flight`. Successful open → handle returned, registry size = 1.

**Reference:** Spec §3 (single-engine guard), spec §3 "Cam* ↔ CameraKit value mapping" row for CamSettings (initialSettings flow).

### Task E2: `close` + `pause` + `resume`

**Methods:** `close(handle:, completion:)`, `pause(handle:, completion:)`, `resume(handle:, completion:)`

**Goal:**
- `close`: unregister handle FIRST (so concurrent `getCapabilities` fails fast), tear down `FlutterApiPump`, tear down `CameraLaneBridge`s, then `await engine.close()`. Return success.
- `pause` / `resume`: thin dispatch to `engine.pause()` / `engine.resume()`.

**Acceptance:** `close` → `open` cycle returns a different handle. `pause` → `SessionState` emits `"paused"`; `resume` → `"streaming"`.

### Task E3: `getCapabilities`

**Method:** `getCapabilities(handle:, completion:)`

**Goal:** Resolve engine; call `engine.currentSettingsSnapshot()` / `engine.dumpDeviceFormats()` (or whatever the engine method actually is — `engine.getCapabilities()` if Phase 2 added it; check `CONTRACTS.md`); map via `toCamCapabilities` passing the texture-IDs from the `CameraLaneBridge`. Return.

**Acceptance:** First call after open returns populated `CamCapabilities` with non-zero `naturalStreamTextureId` and `previewTextureId`, `streamPixelFormat == "BGRA8"`, populated range fields (focus/zoom/EV).

### Task E4: `updateSettings`

**Method:** `updateSettings(handle:, settings:)` (sync throws)

**Goal:** Resolve; convert via `toCameraSettings`; call `engine.updateSettings(...)`. On `EngineError.calibrationInProgress`, throw `PigeonError(code: "calibration_in_progress", ...)`.

**Acceptance:** Setting `iso`/`exposureTimeNs` → `onFrameResult` reports requested values within ~3 frames (HITL case in Plan 4).

### Task E5: `setProcessingParams`

**Method:** `setProcessingParams(handle:, params:)` (sync)

**Goal:** Trivial dispatch. Resolve; convert via `toProcessingParameters`; `engine.setProcessingParams(...)`. No errors expected.

**Acceptance:** Calling sets values; `engine.currentProcessingParametersSnapshot()` round-trips.

### Task E6: `setResolution`

**Method:** `setResolution(handle:, width:, height:, completion:)`

**Goal:** Resolve; call `engine.setResolution(size: Size(Int(width), Int(height)))`. On `EngineError.calibrationInProgress`, throw `calibration_in_progress`.

**Acceptance:** Each apply triggers `onStreamConfigurationChanged` with the new dims. (Plan 4 HITL exercises 4 sizes.)

### Task E7: `captureImage` + `captureNaturalPicture`

**Methods:** `captureImage(handle:, outputDirectory:, fileName:, destination:, completion:)`, `captureNaturalPicture(...)`

**Goal:**
- Build `outputURL` from `outputDirectory` + `fileName` (defaults: app-documents + `IMG_<timestamp>.jpg`); engine already handles `outputURL == nil` cases.
- Convert `CamPhotosDestination?` to whatever shape the engine method accepts (Phase 2's `engine.captureImage`/`captureNaturalPicture` already have `photosDestination:` parameter; spec §5.4 broadens that).
- Call engine method; result yields either a file URL or PHAsset identifier (engine returns whichever applies).
- Build `CamCaptureResult { filePath:, phAssetLocalId: }` accordingly.

**Acceptance:**
- `saveToLibrary: true` → returned `phAssetLocalId` is non-null; image visible in Photos.
- `saveToLibrary: false` or null destination → returned `filePath` is non-null; file exists at that path.

**Reference:** Spec §5.4. Note: this is the iOS impl of §5.4's Photos library branch. Android's branch is the Plan-1 TODO that Plan 4 polish can address (or leave for a separate Android-polish plan).

### Task E8: `startRecording` + `stopRecording`

**Methods:** `startRecording(handle:, outputDirectory:, fileName:, bitrate:, fps:, completion:)`, `stopRecording(handle:, completion:)`

**Goal:** Build `RecordingOptions` from args (defaults match engine's existing defaults). Dispatch. Convert returned `RecordingStart` to absolute file path string. Stop returns final path.

**Acceptance:** A start → stop cycle yields a valid HEVC MP4 at the returned path; file size > 0; QuickTime plays it.

### Task E9: `getNativePipelineHandle`

**Method:** `getNativePipelineHandle(handle:, completion:)`

**Goal:** Resolve engine; `let h: UInt64? = await engine.getNativePipelineHandle()`; return `h.map { Int64(bitPattern: $0) }`.

**Acceptance:** Returns non-null `Int64` once streaming; round-tripping that value to native FFI consumer via `pixel_sink_pool_register` succeeds (verified in Plan 4 HITL).

**Reference:** Spec §3 "getNativePipelineHandle — sign + nullability bridge".

### Task E10: `sampleCenterPatch` + `getPersistedProcessingParams`

**Methods:** `sampleCenterPatch(handle:, completion:)`, `getPersistedProcessingParams(handle:)` (sync)

**Goal:** Thin dispatch. `sampleCenterPatch` returns `RgbSample` → `toCamRgbSample`. `getPersistedProcessingParams` returns optional `ProcessingParameters` → `toCamProcessingParams`.

**Acceptance:** `sampleCenterPatch` after streaming returns r/g/b in `[0, 1]`. `getPersistedProcessingParams` returns null on first launch, populated after a save cycle.

### Task E11: §5.6 permission methods

**Methods:** `cameraPermissionStatus(completion:)`, `requestCameraPermission(completion:)`, `photosAddPermissionStatus(completion:)`, `requestPhotosAddPermission(completion:)`

**Goal:** Each routes to the corresponding `CameraEngine` static helper (per D-2P-06, these are `nonisolated static`, no engine instance required). Map returned `CameraPermissionStatus` enum to string per spec §5.6 (lowercase: `"notDetermined"` / `"denied"` / `"restricted"` / `"authorized"`).

**Acceptance:**
- Fresh install: `cameraPermissionStatus` → `"notDetermined"`; `requestCameraPermission` triggers iOS prompt; result → `"authorized"` after approval.
- Photos: same shape via `photosAdd*` helpers.

**Reference:** Spec §5.6; D-2P-06.

---

## Cluster F — Texture bridge

### Task F1: `CameraLaneTexture` (FlutterTexture impl)

**File:** `CameraLaneTexture.swift`

**Goal:** Per spec §4. `final class CameraLaneTexture: NSObject, FlutterTexture` holding a weak `CameraEngine` reference + `StreamId`. `copyPixelBuffer()` returns `Unmanaged.passRetained(engine.currentPixelBuffer(stream: stream))` (or `nil` if engine is gone or no frame yet).

**Acceptance:** Unit test: feed a synthetic engine returning a known `CVPixelBuffer`; assert `copyPixelBuffer` returns a retained reference (retainCount > original).

### Task F2: `CameraLaneBridge` (per-lane subscriber Task)

**File:** `CameraLaneBridge.swift`

**Goal:** Per spec §4. Holds a `FlutterTextureRegistry`, `Int64 textureId`, `StreamId stream`, `Task? nudgeTask`. `start()`: subscribes via `for await _ in engine.consumers.subscribe(stream:)`, discards yielded `FrameSet` (only the signal matters), calls `registry.textureFrameAvailable(textureId)` on main thread. `stop()`: cancels Task + unregisters texture.

**Acceptance:** Synthetic engine yielding 100 frames → bridge fires 100 `textureFrameAvailable` calls (verified via stub `FlutterTextureRegistry`).

### Task F3: Wire bridge at `open` / teardown at `close` + populate texture-ID fields

**Files:** `CameraHostApiImpl.swift` (extend Task E1), `FlutterApiPump.swift` (extend Task D4)

**Goal:**
- On successful `open`: instantiate `CameraLaneTexture(engine, stream: .natural)` and `(.processed)`; register both with `FlutterTextureRegistry`; capture both `Int64` IDs; start `CameraLaneBridge`s for both. Stash the IDs on the per-handle state so `getCapabilities` + `FlutterApiPump`'s `streamConfigurationStream` Task can read them.
- On `close`: stop bridges, unregister both textures.
- `getCapabilities` (Task E3) reads the stashed IDs and passes them to `toCamCapabilities`.
- `FlutterApiPump`'s `streamConfigurationStream` Task reads the stashed IDs and passes them to `toCamStreamConfiguration` on every emission.

**Acceptance:**
- Dart `Texture(textureId: capabilities.previewTextureId)` widget shows the processed preview on iPad.
- Dart `Texture(textureId: capabilities.naturalStreamTextureId)` shows the natural preview.
- `onStreamConfigurationChanged` payload's `previewTextureId` matches the value from `getCapabilities`.
- `close` then `open` yields different texture IDs.

**Reference:** Spec §4 "Lane wiring at open / close", "CamStreamConfiguration — the texture-ID field is minted here".

---

## Cluster G — Plugin registrar updates

### Task G1: `CambrianCameraPlugin.register(with:)` final shape

**File:** `CambrianCameraPlugin.swift`

**Goal:**
- Instantiate `HandleRegistry`, capture `registrar.textures()`, instantiate `LifecycleObserver(registry:)`.
- Construct `CameraHostApiImpl(registry:, textureRegistry:, lifecycleObserver:)`.
- `CameraHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: impl)`.
- Hold the impl + observer in a `static let shared` if needed to keep them alive past `register` returning (FlutterPlugin convention: plugins are deallocated otherwise).

**Acceptance:** App launches; plugin registers; first `open()` from Dart returns a handle (vs. Plan 1's `not_implemented`).

---

## Cluster H — Cluster integration smoke

### Task H1: On-device end-to-end smoke

Run the example app on iPad. Exercise (in order):
- `cameraPermissionStatus` → `"notDetermined"` (fresh install) / `"authorized"` (subsequent)
- `requestCameraPermission` → triggers prompt, returns `"authorized"`
- `open(null, CamSettings(iso: ...))` → returns handle
- `getCapabilities(handle)` → returns populated capabilities
- `Texture(textureId: capabilities.previewTextureId)` renders 30 fps preview
- `updateSettings`, `setResolution`, `setCropRegion`, `setProcessingParams` — observable changes in preview
- `captureImage` (file path), `captureImage` (Photos), `captureNaturalPicture` (both) — files / PHAssets appear
- `startRecording` → `stopRecording` → file written
- `pause` → `resume` → preview pauses/resumes; state stream emits `"paused"`/`"streaming"`
- App backgrounds → state emits `"paused"`; foregrounds → `"streaming"` (via LifecycleObserver)
- `close` → no errors; second `open` works

**Acceptance:** All above behave as expected. Calibration host methods (calibrateWB / calibrateBB) still return `not_implemented` — that's Plan 3.

**No regression of:** the Plan 1 smoke (plugin registers, Dart can call HostApi without `MissingPluginException`).

---

## Cluster I — Plan 2 wrap

### Task I1: Status doc in eva-swift-stitch

Append "Status — completed YYYY-MM-DD" section to this plan file (mirror Plan 1's wrap pattern). List the cam2fd commit SHAs for D/E/F/G/H clusters.

### Task I2: Push cam2fd branch (user approval gate)

Confirm with user. On approval: `git push -u origin phase-3-plan-2-adapter-methods-bridge`. PR/merge per cam2fd convention.

---

## Self-review checklist (engineer runs before declaring done)

- [ ] No `not_implemented` remains in `CameraHostApiImpl.swift` except the two calibration methods (Plan 3).
- [ ] Every method in `CameraHostApi` (per regenerated `Messages.g.swift`) has a real body.
- [ ] `PigeonValueMapping` round-trips every type pair (12+ unit tests pass).
- [ ] `HandleRegistry` concurrent-register test passes.
- [ ] `FlutterApiPump` fires every callback at expected rates on device.
- [ ] `CameraLaneBridge` fires 1 `textureFrameAvailable` per yielded frame.
- [ ] Lifecycle observer routes scene-phase to engine for every open handle.
- [ ] Cluster H end-to-end smoke: all listed scenarios pass on iPad.
- [ ] Engine snapshot at `ios/CameraKit/` is unmodified (`git diff` shows nothing under that path).
- [ ] `flutter analyze` clean; `flutter build ios --debug` + `flutter build apk --debug` both pass.

---

## Carry-forward to Plan 3

Plan 3 (iOS-only calibration via separate Pigeon file) starts from Plan 2's working scaffold. Plan 3 doesn't touch anything Plan 2 owns — it adds the new `pigeons/camera_api_ios.dart` input, a `CameraIosHostApiImpl.swift`, a Dart-side `Platform.isIOS` branch in `cambrian_camera_controller.dart`. Plan 4 (HITL + polish) follows.

---

## Plan 2 — execution notes

- **Cluster D before E:** the foundation has to exist before host methods can use it.
- **Cluster F can happen in parallel with E** once D is done (texture bridge doesn't depend on most host methods; it does depend on `open` plumbing in E1).
- **One commit per Task is the right granularity.** Plan 2 is ~15 commits total (D1-D4, E1-E11, F1-F3, G1, H1, I1). The H1 smoke commit is the gate.
- **Read the engine surface before writing each method.** `CONTRACTS.md` is fresh; trust it.
- **If a method needs an engine surface that isn't there:** stop, escalate, fix in eva-swift-stitch, cut a new tag, re-subtree-pull. Do not edit the snapshot.
- **The Plan 1 smoke (HostApi calls return errors to Dart) is the regression test for the wire** — if Plan 2 work breaks Dart's ability to even reach the iOS side, the regression is in the plugin registrar.
