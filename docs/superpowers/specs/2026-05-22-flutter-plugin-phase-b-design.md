# Flutter plugin — Phase B v1 implementation design

**Status:** 2026-05-22 — design approved, ready for implementation plan.
**Branch:** `flutter-monorepo-restructure`
**Predecessor:** `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` (Phase A — repo restructure)

**Supersedes (Phase 3 work only):** the four archived Phase 3 plans
(`docs/superpowers/plans/archive/2026-05-18-phase-3-plan-{1,2,3,4}-*.md`) and the archived
`docs/superpowers/specs/archive/2026-05-18-phase-3-design.md`. Phase B is fresh design — it
does **not** continue the cam2fd-subtree-consumption model of Phase 3.

**Builds on:**
- The lifecycle ownership rework that landed on `main` 2026-05-21 (`CameraKit/README.md`
  is the lifecycle source of truth).
- The 2026-05-15 texture-bridge spike (`docs/measurements/texture-bridge/2026-05-15/notes.md`)
  which validated the simple pull-cadence implementation needs no mitigations.
- The 2026-05-14 CameraKit→Flutter migration design's Phase 2 vocabulary (the Pigeon
  surface inherits from there).

---

## Goal

Ship `cambrian_ios_camera` — a Flutter plugin wrapping CameraKit — at version **v1.0.0**, with
full Phase 2 surface parity, iOS-only, joint-versioned with CameraKit via a single git tag.
The plugin consumes the Swift package at the repo root via a relative-path SPM dependency;
the Flutter plugin lives under `flutter/`.

## Scope

In scope for v1.0.0:

- Single Dart-facing `CameraEngine` class mirroring CameraKit's Swift public surface 1:1
- Pigeon-bridged HostApi for engine + permissions + texture lifecycle
- Per-stream `EventChannelApi` for state / error / streamConfig / frameResult / recordingState
- Zero-copy preview via `FlutterTexture` + `Texture(textureId:)`
- Plugin-owned native lifecycle (UIScene callbacks → `engine.setLifecyclePhase`)
- Calibration (white-balance + black-balance)
- Recording (start, stop, pause, resume)
- Still capture (processed lane + natural lane API surface; example app demos processed only)
- Settings (read/write), capabilities, processing parameters, crop region
- Typed Dart `CameraException` with code enum mirroring CameraKit's `CameraError.code`
- Static Dart `Permissions` class
- Android Kotlin no-op stub throwing `PlatformException(code: "iOSOnly")`
- Lean Flutter example app demonstrating most of the surface, processed-lane preview only
- ~40 Dart unit tests, ~5 Swift adapter XCTest, 3 integration tests on iPad

Explicitly out of scope for v1:

- pub.dev publication (stays `git: + path:` referenced)
- Swift Package Index registration
- Real Android implementation (stub only)
- `CameraKit → CambrianCamera` rename (deferred per Phase A spec §"Future cleanup")
- Automated CI (manual local testing only — single-developer project)
- `CHANGELOG.md` (GitHub release notes cover v1.0.0; CHANGELOG appears in v1.1.0)
- Multi-engine support (singleton engine per plugin instance)

---

## Locked design decisions

| Decision | Value | Rationale |
|---|---|---|
| v1 scope | Full Phase 2 parity (every locked Pigeon vocabulary item) | First real release; matches the spec's locked vocabulary |
| Build order | Top-down — Pigeon DSL first, then Swift adapter, then Dart facade, then example app | Locks the contract before implementation |
| Calibration in v1 | Yes (both WB + black) | Already implemented Swift-side; bridging is mechanical |
| Dart API shape | Single `CameraEngine` class, 1:1 with Swift | Familiar mental model; refactor cost low |
| Stream model | Pigeon `EventChannelApi`, one channel per stream, `.asBroadcastStream()` cached in facade | Idiomatic; multi-subscriber-safe |
| Preview model | `Texture(textureId:)` per stream; explicit `createPreviewTexture` / `destroyPreviewTexture` | Consumer manages widget lifecycle; supports multi-lane (v1 example uses processed only) |
| Errors | Typed Dart `CameraException` with code enum; HostApi `PlatformException` caught and rethrown as `CameraException` | Discoverable in IDE autocomplete; idiomatic Dart |
| Permissions | Static `Permissions` class with two methods (`status()` + `request()`) | No engine instance required; check before opening |
| Lifecycle | Plugin-owned native; Dart has **no** lifecycle surface; consumers drive UI from `engine.stateStream()` | Avoids Dart-round-trip latency that can corrupt recordings on background |
| Lifecycle mechanism | Plugin's main class implements UIScene callback selectors and registers via `registrar.addApplicationDelegate(self)` | The standard Flutter API; routes scene events through the application delegate |
| `WidgetsBindingObserver` | **Don't use it for camera lifecycle.** Allowed for the consumer's own app concerns (analytics, draft-save, etc.) | Tight phrasing — not a blanket ban |
| Engine instantiation | Singleton — one CameraEngine per plugin instance; HostApi methods don't take an engineId | Differs from official `camera` plugin (which keys by ID for front/back); CameraKit doesn't have that pattern |
| Versioning | Single git tag `vX.Y.Z` drives both Swift + Flutter consumers | Joint version family; SemVer applied across combined surface |
| Pigeon version pin | `pigeon: ^22.6.0` (minimum with `EventChannelApi` baked) | Generated files committed for review |

---

## §1 — Architecture overview

Four layers, top to bottom:

```
┌─────────────────────────────────────────────────────────┐
│ Dart consumer code (in their Flutter app)               │
│   • Texture(textureId) widget for preview               │
│   • CameraEngine instance + await methods + subscribe   │
│   • UI driven off engine.stateStream() (NOT             │
│     WidgetsBindingObserver)                             │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│ flutter/lib/    — Dart facade (cambrian_ios_camera)     │
│   • CameraEngine class (1:1 mirror of Swift)            │
│   • Permissions (static)                                │
│   • CameraException typed errors                        │
│   • Stream<T> wrappers over EventChannelApi             │
│   • Generated Pigeon Dart bindings (lib/src/pigeon/)    │
└─────────────────────────┬───────────────────────────────┘
                          │  Pigeon HostApi + EventChannelApi
                          │  + FlutterTextureRegistry
                          ▼
┌─────────────────────────────────────────────────────────┐
│ flutter/ios/cambrian_ios_camera/Sources/                │
│   • Pigeon HostApi impl (Swift adapter, THIN)           │
│   • UIScene callback selectors — implement              │
│     sceneDidBecomeActive: / sceneWillResignActive: /    │
│     sceneDidEnterBackground:, route to                  │
│     engine.setLifecyclePhase                            │
│   • Registered via registrar.addApplicationDelegate(    │
│     self)                                               │
│   • One FlutterTexture per active stream                │
│   • copyPixelBuffer → CameraEngine.currentPixelBuffer   │
│   • Forwards each CameraEngine AsyncStream to its       │
│     dedicated EventChannel                              │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│ CameraKit (Swift package at repo root, unchanged)       │
│   • public actor CameraEngine                           │
│   • engine.setLifecyclePhase(_:) is the lifecycle API   │
│   • Full Phase 2 surface already implemented            │
│   • currentPixelBuffer(stream:) for texture readback    │
└─────────────────────────────────────────────────────────┘

flutter/android/   (separate, no shared code path)
   • Kotlin stub — every HostApi method throws
     PlatformException(code: "iOSOnly", message: "...")
   • EventChannels emit one error and close
```

**Three load-bearing properties:**

1. **CameraKit stays consumer-agnostic.** The Swift package at the repo root has zero Pigeon/Flutter
   imports. The plugin's adapter layer is the *only* place that knows about Pigeon. Matches CLAUDE.md
   §5's "CameraKit is consumer-agnostic; the Canny consumer lives in the app" — same principle,
   different consumer.

2. **The adapter is thin by design.** No business logic, no state machine, no error transformation
   policy. It translates Pigeon shapes ↔ CameraKit shapes and routes to/from the actor. If the
   adapter is doing real work, the work belongs in CameraKit.

3. **No OpenCV anywhere on the Flutter path** (locked Phase A constraint). The plugin's Swift
   package and `flutter/example/ios/Runner/` both omit the OpenCV link. Only `ios_example_app/`
   (the unrelated native dev harness) links OpenCV for its Canny consumer.

---

## §2 — Pigeon API contract

### File organization

Single Pigeon DSL: `flutter/pigeons/cambrian_ios_camera_api.dart`, sectioned by concern. Generated
outputs:

- Dart → `flutter/lib/src/pigeon/cambrian_ios_camera_api.g.dart` (hidden from public API)
- Swift → `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift`
- Kotlin → `flutter/android/src/main/kotlin/.../cambrian_ios_camera_api.g.kt` (Android impl layer throws `PlatformException` for every method)

Generated files **committed to git** per Pigeon convention. Regen via:

```bash
cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart
```

### Two HostApi interfaces

**`CameraEngineHostApi`** — singleton-backed; one `CameraEngine?` held in the adapter. All async
methods marked `@async`:

- Lifecycle: `open(OpenConfiguration) → SessionCapabilities`, `close()`
- Snapshots: `currentSettings() → CameraSettings?`, `currentProcessingParameters() → ProcessingParameters?`
- Control: `updateSettings`, `setResolution`, `setProcessingParams`, `setCropRegion`
- Capture: `captureImage(outputPath: String?, photosDestination: PhotosDestination) → String`, `captureNaturalPicture(...) → String`
- Recording: `startRecording(RecordingOptions) → RecordingStart`, `stopRecording() → String` (no pause/resume — CameraKit has no recording-pause API)
- Calibration: `calibrateWhiteBalance() → CalibrationResult`, `calibrateBlackBalance() → CalibrationResult`
- Texture bridge: `createPreviewTexture(StreamId) → Int64`, `destroyPreviewTexture(Int64)`

**`PermissionsHostApi`** — no engine instance required:

- `cameraPermissionStatus() → CameraPermissionStatus`
- `requestCameraPermission() → CameraPermissionStatus`

### Five EventChannelApi instances

One per stream; each is `Stream<T>` on the Dart side, fed from the corresponding
`CameraEngine.<X>Stream()` `AsyncStream<T>` via a per-stream bridging Task in the adapter:

| Channel | Stream type |
|---|---|
| `StateEventApi` | `SessionState` |
| `ErrorEventApi` | `CameraError` |
| `StreamConfigurationEventApi` | `StreamConfiguration` |
| `FrameResultEventApi` | `FrameResult` |
| `RecordingStateEventApi` | `RecordingState` |

### Value types — 1:1 mirror of CameraKit

Pigeon `@class` for each: `OpenConfiguration`, `SessionCapabilities`, `CameraSettings`,
`ProcessingParameters`, `StreamConfiguration`, `FrameResult`, `RecordingOptions`,
`RecordingStart`, `CalibrationResult`, `CameraError`, `Size`, `Rect`.

Pigeon `@enum` for: `SessionState`, `StreamId`, `CameraPermissionStatus`, `PhotosDestination`.

**`RecordingState` is a Swift enum-with-associated-value** (`.idle(lastUri: String?)`,
`.recording`, `.finalizing`) — Pigeon doesn't natively support associated values, so it gets
mirrored as a Pigeon `@class` with a discriminator field + optional `lastUri`. Exact shape:
`class RecordingStateValue { RecordingStateKind kind; String? lastUri; }` where
`RecordingStateKind` is a Pigeon `@enum` of `{ idle, recording, finalizing }`. The Dart facade
re-wraps as an idiomatic sealed class for ergonomics. `.paused` is **not** a case — removed on
2026-05-22 (commit `4038fe4`) when the production-dead recording-pause path was deleted.

Exact field shapes derived from `CameraKit/CONTRACTS.md` at implementation time. If any other
type can't flatten safely (recursive, contains CV types, contains closures), the plan flags it.

### Not bridged

Internal test seams + native dev-harness debug methods — `setGate`, `drainSubmittedFrame`,
`getNativePipelineHandle`, `dumpDeviceFormats`, `sampleCenterPatch`. No Flutter consumer needs
them; available again in v1.x if a real use case appears.

**Lifecycle is plugin-internal Swift, not Pigeon-bridged.** `AppLifecyclePhase` (Swift enum:
`.active`/`.inactive`/`.background`) and `CameraEngine.setLifecyclePhase(_:)` are used by the
plugin's iOS adapter inside the UIScene callback selectors — they never cross the Pigeon
boundary, never appear in Dart, never appear in the generated bindings.
`CameraEngine.init(initialPhase:)` is also Swift-only; the plugin's adapter constructs the engine
with the connected `UIScene`'s `activationState` (defaulting to `.background` when no scene is
yet attached). Dart's `CameraEngine.open()` is unchanged from the consumer's POV.

### Singleton engine — v1 design

One CameraEngine per plugin instance. HostApi methods don't take an engineId — the adapter holds
a single `CameraEngine?` and rejects ops when nil (`"notOpen"`). Differs from the official
`flutter/plugins/camera` plugin (which keys controllers by ID for front/back switching);
CameraKit doesn't have that pattern. Multi-engine support is a non-breaking v1.x addition if
needed.

---

## §3 — Texture bridge

The 2026-05-15 texture-bridge spike (`docs/measurements/texture-bridge/2026-05-15/notes.md`)
verdict: **NO MITIGATION NEEDED**. Ship the naive pull-cadence implementation.

### Mechanism

```
Dart                       Plugin (Swift)                    CameraKit
────                       ──────────────                    ─────────
createPreviewTexture(   ─► FlutterTexture instance
  stream: .processed)        registry.register(texture)  ─►  Int64 texId
                             Task { for await _ in
                               engine.consumers
                                 .subscribe(stream:) {
                                 registry.textureFrame
                                   Available(texId)      }
◄─────  Int64 texId  ──────  return texId

Texture(textureId: id)  ─►  copyPixelBuffer()           ─►  currentPixelBuffer(stream:)
                              (raster thread)                (nonisolated, sync)
                                                              ──► CVPixelBuffer? from mailbox
                             CFRetain returned buffer   ◄──
                             return Unmanaged
                             .passRetained(...).toOpaque()
◄─── Metal-rendered ──────
```

### Lifecycle

| Event | Adapter action |
|---|---|
| `createPreviewTexture(stream:)` | Instantiates `FlutterTexture`, calls `registry.register(...)`, spawns a `Task` subscribing to `engine.consumers.subscribe(stream:)`. Stores `(textureId, task)` in adapter-side map. Returns `textureId`. |
| `destroyPreviewTexture(textureId:)` | Cancels the subscription task, calls `registry.unregisterTexture(textureId)`, drops the map entry. |
| Engine `close()` | Adapter iterates all active textures, unregisters each. Dart-side: `Texture` widget continues showing its last frame until the consumer unmounts it. |
| Engine `open()` | New textures created via `createPreviewTexture`; texture IDs from a prior session are stale (best practice: create after `open`, destroy before `close`). |

### Retention

`copyPixelBuffer()` returns a **retained** reference (Flutter framework calls `CFRelease` after
rendering). CameraKit's `currentPixelBuffer(stream:)` returns the mailbox's buffer without
taking a new reference. Adapter wraps:

```swift
func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let buf = engine.currentPixelBuffer(stream: stream) else { return nil }
    return Unmanaged.passRetained(buf)
}
```

`nil` returns are fine — Flutter shows the last successfully-rendered frame.

### Concurrent textures for the same stream

Allowed. Two `Texture` widgets showing the same lane = two `FlutterTexture` instances, two
subscriber tasks, two `currentPixelBuffer` reads per frame. Reads are cheap (mailbox lookup, no
copy).

### Open-state coupling

`createPreviewTexture` before `open()` returns a texture ID; `copyPixelBuffer` returns `nil`
until the first frame lands. No error condition — texture shows black until the first frame.

### AVF interruption / scene pause

Engine state goes `.interrupted` or `.paused`; `currentPixelBuffer` continues returning the
last successfully-rendered buffer. Flutter shows a frozen frame until the session resumes.
Matches user expectation.

### What's NOT in the texture bridge

- No per-frame metadata channel from texture → Dart. Metadata flows through the separate
  `FrameResultEventApi` EventChannel.
- No video-output texture (recording artifacts go through `recordingStateStream` + the
  recorded file path).
- No texture-side cropping or transform.

---

## §4 — Dart facade

### Library structure

```
flutter/
├── pubspec.yaml
├── lib/
│   ├── cambrian_ios_camera.dart          # public export — only this is imported
│   ├── testing.dart                      # separate export, opt-in mocking factory
│   └── src/
│       ├── camera_engine.dart            # CameraEngine class
│       ├── permissions.dart              # static Permissions class
│       ├── camera_exception.dart         # typed CameraException + code enum
│       └── pigeon/
│           └── cambrian_ios_camera_api.g.dart   # generated, committed
```

Public import surface: `import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';`. Test-only
mocking factory: `import 'package:cambrian_ios_camera/testing.dart';`. Consumers never touch
`lib/src/`.

### `CameraEngine` — public Dart API

```dart
class CameraEngine {
  CameraEngine();
  // Test-only factory lives in lib/testing.dart, not exposed via the main library:
  //   CameraEngine.testing({required CameraEngineHostApi api, ...})

  Future<SessionCapabilities> open([OpenConfiguration? config]);
  Future<void> close();
  Future<void> dispose() => close();                               // Dart convention alias

  // Snapshots
  Future<CameraSettings?> currentSettings();
  Future<ProcessingParameters?> currentProcessingParameters();

  // Streams (cached .asBroadcastStream())
  Stream<SessionState> stateStream();
  Stream<CameraException> errorStream();
  Stream<StreamConfiguration> streamConfigurationStream();
  Stream<FrameResult> frameResultStream();
  Stream<RecordingState> recordingStateStream();

  // Control
  Future<void> updateSettings(CameraSettings settings);
  Future<void> setResolution(Size size);
  Future<void> setProcessingParams(ProcessingParameters params);
  Future<void> setCropRegion(Rect rect);

  // Capture
  Future<String> captureImage({String? outputPath, PhotosDestination photosDestination = PhotosDestination.none});
  Future<String> captureNaturalPicture({String? outputPath, PhotosDestination photosDestination = PhotosDestination.none});

  // Recording (no pause/resume — CameraKit has no recording-pause API)
  Future<RecordingStart> startRecording(RecordingOptions options);
  Future<String> stopRecording();

  // Calibration
  Future<CalibrationResult> calibrateWhiteBalance();
  Future<CalibrationResult> calibrateBlackBalance();

  // Texture bridge
  Future<int> createPreviewTexture({required StreamId stream});
  Future<void> destroyPreviewTexture(int textureId);
}
```

**No `pause()` / `resume()` on the Dart class.** Lifecycle is entirely plugin-owned (native side).
The Dart consumer has no lifecycle surface from Dart. **There is also no recording-pause API** —
CameraKit's recording is start/stop only (the production-dead `Recording.StopReason.pause` path
was removed on 2026-05-22). To pause filming, the consumer calls `stopRecording()` and starts
a new recording on resume.

**Constructor docstring contract:**

> `CameraEngine()` is a zero-arg Dart constructor. On the iOS side the plugin's adapter
> constructs the underlying CameraKit `CameraEngine(initialPhase:)` with the connected
> `UIScene`'s current `activationState` — Dart doesn't see this. `await engine.open()` returns
> once the engine has reconciled to that initial phase.

### `Permissions` — static class

```dart
class Permissions {
  Permissions._();
  static Future<CameraPermissionStatus> cameraPermissionStatus();
  static Future<CameraPermissionStatus> requestCameraPermission();
}
```

### `CameraException` — typed error

```dart
class CameraException implements Exception {
  final CameraErrorCode code;
  final String message;
  final bool isFatal;
  CameraException({required this.code, required this.message, required this.isFatal});
  @override String toString() => 'CameraException(${code.name}): $message${isFatal ? " [FATAL]" : ""}';
}

enum CameraErrorCode {
  cameraAccessError, frameStall, aeConvergenceTimeout, cameraInUse,
  invalidOutputPath, settingsConflict, calibrationInProgress, notOpen,
  permissionDenied, recordingFailed, recordingTruncated,
  // ...mirror of every CameraError.code variant from CameraKit
  unknown,                                                          // catch-all for forward-compat
}
```

- **HostApi throws** (Pigeon's `PlatformException` from `@async` methods) are caught in the
  facade and rethrown as `CameraException` with parsed code + message.
- **`errorStream()`** emits `CameraException` directly (translated from the raw Pigeon
  `CameraError` value type at the facade layer).
- Unknown error codes (forward-compat with newer CameraKit versions) map to
  `CameraErrorCode.unknown` with the raw string preserved in `message`.

### README-contract on lifecycle

> **Don't drive camera lifecycle from Dart.** There is no lifecycle surface on the Dart
> `CameraEngine` — no `pause()`, no `resume()`, no `notifyScenePhasePaused`. The plugin observes
> iOS scene lifecycle natively. A Dart-side hook would add platform-channel latency that could
> let a backgrounding outrun an in-flight recording's finalize and corrupt the `.mp4`.
> `WidgetsBindingObserver` is fine for your *own app's* concerns — saving a draft on background,
> dispatching analytics, etc. — just don't route it into any `engine.<method>` call. If you want
> your UI to swap the preview for a placeholder when the camera isn't running, listen to
> `engine.stateStream()` — it's the authoritative signal.

### Idiomatic consumer pattern

Subscribe to `engine.stateStream()` and switch between `Texture(textureId: id)` and a placeholder
widget based on whether the latest `SessionState` is `.streaming`/`.paused` vs
`.interrupted`/`.recovering`/`.error`/`.closed`. Don't drive this off `AppLifecycleState` — the
engine's state stream is the authoritative signal.

### Internal-only — NOT exposed in Dart

Per locked decisions, all OS-lifecycle methods are plugin-internal Swift, called only from the
iOS adapter's UIScene callback selectors:

- `notifyScenePhasePaused(_:)` — NOT on `CameraEngine` Dart class
- `backgroundSuspend()` / `backgroundResume()` — NOT exposed
- `setGate(_:)` / `drainSubmittedFrame()` — NOT exposed
- `setLifecyclePhase(_:)` — NOT exposed; called only by the adapter's scene callbacks

---

## §5 — iOS adapter

A thin Swift class in `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/` that:

1. Owns a single `CameraEngine` instance (constructed with `initialPhase` derived from the
   connected `UIScene`'s `activationState`)
2. Implements the Pigeon-generated `CameraEngineHostApi` Swift protocol — every method body is
   a 1–3 line translation calling into `engine.<X>(...)` and translating Swift value types ↔
   Pigeon value types
3. Implements UIScene callback selectors (`sceneDidBecomeActive:`, `sceneWillResignActive:`,
   `sceneDidEnterBackground:`) directly on the plugin's main class, registered via
   `registrar.addApplicationDelegate(self)`
4. Owns the per-stream `FlutterTexture` instances + their subscriber Tasks (per §3)
5. Forwards engine `AsyncStream`s onto Pigeon `EventChannelApi` instances

### Plugin registration

```swift
import Flutter
import CameraKit

public class CambrianIosCameraPlugin: NSObject, FlutterPlugin, UIWindowSceneDelegate {
    private let registrar: FlutterPluginRegistrar
    private var engine: CameraEngine?            // nil until first open()
    private var textures: [Int64: (FlutterTexture, Task<Void, Never>)] = [:]
    private var streamTasks: [Task<Void, Never>] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CambrianIosCameraPlugin(registrar: registrar)
        CameraEngineHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        PermissionsHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        registrar.addApplicationDelegate(instance)                        // routes scene callbacks too
    }
    // ...
}
```

### UIScene → `AppLifecyclePhase` mapping

Per `CameraKit/README.md`:

```swift
public func sceneDidBecomeActive(_ scene: UIScene) {
    Task { await engine?.setLifecyclePhase(.active) }
}
public func sceneWillResignActive(_ scene: UIScene) {
    Task { await engine?.setLifecyclePhase(.inactive) }
}
public func sceneDidEnterBackground(_ scene: UIScene) {
    Task { await engine?.setLifecyclePhase(.background) }
}
// sceneWillEnterForeground intentionally not implemented — sceneDidBecomeActive
// carries the .active transition.
```

`engine?.setLifecyclePhase(...)` is a no-op when `engine == nil` (pre-open). Once Dart calls
`open()`, the engine is constructed with `initialPhase: <scene's current state>` and from that
point all scene callbacks reach it.

### Computing `initialPhase` at engine construction

When Dart calls `engine.open()`:

```swift
public func open(config: OpenConfiguration?, completion: @escaping (Result<SessionCapabilities, Error>) -> Void) {
    Task {
        let phase: AppLifecyclePhase = await Self.currentScenePhase() ?? .background

        let e = CameraEngine(initialPhase: phase)
        do {
            let caps = try await e.open(configuration: config?.toCameraKit() ?? OpenConfiguration())
            self.engine = e
            self.subscribeAllStreams()
            completion(.success(caps.toPigeon()))
        } catch {
            completion(.failure(error.asCameraException()))
        }
    }
}

private static func currentScenePhase() async -> AppLifecyclePhase? {
    await MainActor.run {
        for scene in UIApplication.shared.connectedScenes {
            switch scene.activationState {
            case .foregroundActive:   return .active
            case .foregroundInactive: return .inactive
            case .background:         return .background
            case .unattached:         continue
            @unknown default:         continue
            }
        }
        return nil
    }
}
```

### Pigeon HostApi method translation pattern

Every Pigeon `@async` HostApi method follows this shape:

```swift
public func updateSettings(settings: CameraSettings, completion: @escaping (Result<Void, Error>) -> Void) {
    Task {
        guard let engine = self.engine else {
            completion(.failure(CameraException(code: .notOpen, message: "engine not open", isFatal: false)))
            return
        }
        do {
            try await engine.updateSettings(settings.toCameraKit())
            completion(.success(()))
        } catch {
            completion(.failure(error.asCameraException()))
        }
    }
}
```

1. Guard `engine != nil`; else throw `notOpen`.
2. Translate Pigeon value type → CameraKit value type.
3. `await` the CameraKit method.
4. Translate result back to Pigeon shape.
5. Wrap thrown errors as `CameraException`.

### Stream forwarding pattern

```swift
private func subscribeStateStream() {
    let task = Task { [weak self, engine] in
        guard let engine else { return }
        for await state in engine.stateStream() {
            await StateEventApi(binaryMessenger: self?.registrar.messenger()).onState(state.toPigeon())
        }
    }
    streamTasks.append(task)
}
```

Repeat for `errorStream`, `streamConfigurationStream`, `frameResultStream`,
`recordingStateStream`. All tasks store handles in the adapter and are cancelled in `close()`.

### Texture lifecycle — per §3

```swift
public func createPreviewTexture(stream: StreamId, completion: @escaping (Result<Int64, Error>) -> Void) {
    // Instantiate FlutterTexture, register with registry, spawn subscriber task that fires
    // textureFrameAvailable on each frame. Store (textureId, task) in textures map.
}

public func destroyPreviewTexture(textureId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    // Cancel the subscriber task, unregister the texture, remove map entry.
}
```

### What the adapter does NOT do

- Doesn't observe `UIApplication` notifications directly. The standard Flutter
  `addApplicationDelegate(self)` registration routes scene callbacks through this single delegate.
- Doesn't hold any CameraKit-side business logic. No state machine, no settings merging, no
  error transformation policy. Pure translation.
- Doesn't link OpenCV. (Locked Phase A constraint.)

---

## §6 — Example app (`flutter/example/`)

### Goals + constraints

Per locked Phase A spec:

- **Lean.** ONE preview stream — the processed lane only.
- **No C++ consumer.** No `AppCxx/`-equivalent.
- **No OpenCV.** No `opencv2.xcframework` link.

Within those constraints, the example demonstrates most of the plugin surface (capture,
recording, settings, calibration) so consumers can read the source to learn the API.

### File layout

```
flutter/example/
├── pubspec.yaml                          # depends on cambrian_ios_camera via path: ../
├── lib/
│   ├── main.dart                         # MaterialApp + CameraScreen
│   ├── camera_screen.dart                # the single screen: preview + control bar
│   └── widgets/
│       ├── preview_widget.dart           # Texture wrapper, drives placeholder from stateStream
│       ├── status_bar.dart               # top — SessionState dot, recording indicator, frame stats
│       ├── control_bar.dart              # bottom — capture / record / settings / calibrate
│       ├── permission_gate.dart          # blocks the screen with a Grant button if not authorized
│       ├── settings_sheet.dart           # bottom sheet — ISO / exposure / focus / WB sliders
│       └── calibration_dialog.dart       # WB + black calibrate buttons + result display
├── ios/
│   ├── Runner.xcodeproj                  # standard Flutter example scaffold
│   ├── Runner/
│   │   ├── AppDelegate.swift             # standard GeneratedPluginRegistrant.register
│   │   ├── Info.plist                    # NSCameraUsageDescription + NSPhotoLibraryAddUsageDescription
│   │   └── Assets.xcassets / etc.
│   ├── RunnerTests/                      # NEW: 5 Swift adapter unit tests (per §7)
│   └── Podfile                           # standard Flutter plugin example template
├── android/                              # standard scaffold; iOS-only at runtime
├── test/
│   └── widget_test.dart                  # one-line smoke: CameraScreen mounts
└── integration_test/
    ├── README.md                         # permission pre-grant procedure, etc.
    └── plugin_test.dart                  # 3 tests (per §7)
```

### `main.dart` + `camera_screen.dart` — single screen

`MaterialApp` with one route to `CameraScreen`. Layout:

```
┌──────────────────────────────────────────┐
│  ● streaming    REC ● 0:14    30 fps     │ ← StatusBar
├──────────────────────────────────────────┤
│                                          │
│         [ Texture(textureId) ]           │ ← PreviewWidget (or placeholder)
│           (or placeholder)               │
│                                          │
├──────────────────────────────────────────┤
│   ⊙     ●     ⚙     🔧                   │ ← ControlBar (4 buttons)
└──────────────────────────────────────────┘
```

If `Permissions.cameraPermissionStatus()` is not `.authorized`, the entire screen is replaced
by `PermissionGate`.

### `ControlBar` — 4 buttons

| Icon | Action | Plugin method |
|---|---|---|
| ⊙ Photo | tap → still capture (processed lane), save to Photos | `engine.captureImage(photosDestination: .photosLibrary)` |
| ●/■ Record | toggle recording | `engine.startRecording(...)` / `engine.stopRecording()` |
| ⚙ Settings | bottom sheet — ISO / exposure / focus / WB | `engine.updateSettings(...)`, `engine.currentSettings()` |
| 🔧 Calibrate | dialog — WB / black calibrate | `engine.calibrateWhiteBalance()`, `engine.calibrateBlackBalance()` |

`engine.captureNaturalPicture(...)` is still in the API surface but NOT demonstrated by the
example (locked decision — example stays lean).

### `PreviewWidget` — processed lane only

```dart
class PreviewWidget extends StatefulWidget {
  final CameraEngine engine;
  const PreviewWidget({super.key, required this.engine});
  // ...
}

class _PreviewWidgetState extends State<PreviewWidget> {
  int? _textureId;
  StreamSubscription<SessionState>? _stateSub;
  SessionState _lastState = SessionState.closed;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.engine.stateStream().listen((s) => setState(() => _lastState = s));
    widget.engine.createPreviewTexture(stream: StreamId.processed)              // hard-coded; processed only
        .then((id) { if (mounted) setState(() => _textureId = id); });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    if (_textureId != null) widget.engine.destroyPreviewTexture(_textureId!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    if (id == null) return const Center(child: CircularProgressIndicator());
    final isRendering = _lastState == SessionState.streaming || _lastState == SessionState.paused;
    return isRendering ? Texture(textureId: id) : const _NoSignalPlaceholder();
  }
}
```

### Lifecycle wiring — none

Per the locked contract: no Dart `WidgetsBindingObserver` for camera. The example uses none.
Per-widget state changes come from `engine.stateStream()`.

### `SettingsSheet` + `CalibrationDialog` — minimal demonstrations

Bottom sheet (settings): ISO/exposure/focus/WB sliders + Apply/Cancel. Reads current via
`engine.currentSettings()`; writes via `engine.updateSettings(...)`.

Modal dialog (calibration): two buttons, one per method. Shows `CalibrationResult` (before /
after / converged / iterations) below.

### iOS Runner setup

- `Info.plist` keys: `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`
- `Podfile`: standard Flutter plugin example
- `AppDelegate.swift`: `GeneratedPluginRegistrant.register(with: self)`. The plugin's
  `register(with:)` method auto-registers the application delegate which routes scene
  callbacks.
- iOS deployment target: matches CameraKit's iOS 26 floor
- No bridging header, no `.cpp` files, no OpenCV framework

### Android — exists but unused

`flutter/example/android/` exists as a standard scaffold so `flutter run` doesn't error on
missing config; at runtime the plugin's Kotlin stub throws `PlatformException(code: "iOSOnly")`
on every method call. The example doesn't dress this up.

Document in `flutter/example/README.md`:

> *This example is iOS-only. The plugin's Android side throws
> `PlatformException(code: 'iOSOnly')` for every host method call. Run on a physical iPad.*

### `pubspec.yaml`

```yaml
name: cambrian_ios_camera_example
description: Example app for cambrian_ios_camera plugin.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.4.0 <4.0.0'
  flutter: '>=3.22.0'

dependencies:
  cambrian_ios_camera:
    path: ../
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter

flutter:
  uses-material-design: true
```

### What the example does NOT do

- No state-management library (Provider/Riverpod/Bloc) — plain `StatefulWidget`
- No navigation — single screen
- No theming — Material default
- No Canny / OpenCV / image processing in Dart side
- No multi-window iPad layout
- No `WidgetsBindingObserver` (for camera)

---

## §7 — Testing strategy

### Testing pyramid

```
                  ╱╲
                 ╱  ╲          Integration tests  (3, on iPad)
                ╱    ╲         flutter/example/integration_test/
               ╱      ╲        full bridge: CameraKit + Pigeon + UIScene + Metal + FlutterTexture
              ╱────────╲
             ╱          ╲      Swift adapter tests  (~5, host-app XCTest)
            ╱            ╲     flutter/example/ios/RunnerTests/
           ╱              ╲    delegate callback mapping + texture map lifecycle
          ╱────────────────╲
         ╱                  ╲  Dart unit tests  (~40)
        ╱                    ╲ flutter/test/
       ╱                      ╲ mockito-mocked Pigeon HostApi, test the Dart facade
      ╱────────────────────────╲
     ╱                          ╲ CameraKit tests  (existing 203, untouched)
    ╱                            ╲ CameraKit/Tests/CameraKitTests/
   ╱______________________________╲ via mcp__XcodeBuildMCP__test_device
```

### Dart unit tests — `flutter/test/`

**Mocking via mockito + build_runner.** `@GenerateMocks([CameraEngineHostApi, PermissionsHostApi])`
annotation in the test file — single source-of-truth, regenerates on Pigeon bump.

**Test seam in a separate library.** `CameraEngine.testing(api: ...)` lives in
`flutter/lib/testing.dart` — exported only via
`import 'package:cambrian_ios_camera/testing.dart'`. The main library
`import 'package:cambrian_ios_camera/cambrian_ios_camera.dart'` does NOT expose it. Production
consumers can't reach it.

**Test categories (~40 tests):**

| Category | Coverage |
|---|---|
| Error mapping | `PlatformException` codes → `CameraException` codes (one per code); preservation of message + isFatal; unknown code → `unknown` enum case; non-`PlatformException` wrapping |
| Stream broadcast caching | Repeated subscriptions reuse the broadcast Stream; multiple subscribers receive same events |
| Stream error propagation | EventChannel `error` event → typed `CameraException` on Dart Stream; broadcast wrapper preserves typed errors across subscribers; error on subscriber A does not terminate subscriber B |
| Concurrent `open()` calls | Two simultaneous `open()` either return same caps or second throws `alreadyOpen`; state isn't poisoned |
| `destroyPreviewTexture` before `createPreviewTexture` completes | Texture-map race — destroy with pending-create ID either no-ops or queues; no orphan entries |
| Texture lifecycle bookkeeping | `createPreviewTexture` returns distinct IDs; map entries removed on destroy; `engine.close()` destroys all outstanding textures |
| `Permissions` static class | Delegates to `PermissionsHostApi`; mock returns each `CameraPermissionStatus` variant |
| Lifecycle aliases | `dispose()` calls `close()` exactly once |
| Snapshot methods | `currentSettings()` returns `null` pre-open vs settings post-open; survives `PlatformException` |
| `errorStream()` typing | Emits `CameraException`, not raw `CameraError` Pigeon shapes |
| Engine resilience | Per-method `PlatformException` doesn't break subsequent calls |

Run: `cd flutter && flutter test`. No device. Fast (~5–8s including mockito codegen).

### Swift adapter tests — `flutter/example/ios/RunnerTests/`

**Scope:** stateful or asynchronous parts of the iOS adapter — not the pure-translation methods.

| Test | Coverage |
|---|---|
| Scene-callback dispatch | Each UIScene-callback selector calls `engine.setLifecyclePhase(.<correct phase>)` exactly once |
| Texture map: create + lookup | `createPreviewTexture` registers a `FlutterTexture`, stores `(id, subscriber-Task)` in the map |
| Texture map: destroy | `destroyPreviewTexture` cancels the subscriber task, unregisters the `FlutterTexture`, removes the map entry |
| Texture map: destroy-twice | Second destroy is idempotent (doesn't crash) |
| Engine-not-open guard | HostApi method called pre-`open()` throws `CameraException(code: notOpen)` |

Five tests total. Requires a one-time `CameraEngineProtocol` extraction in CameraKit (a Swift
protocol the adapter mocks against). Lands as part of Phase B.

Run via `flutter/example/scripts/test-swift-adapter.sh` (wraps `xcodebuild test` for the
`RunnerTests` scheme).

### Integration tests — `flutter/example/integration_test/`

**Three tests** — end-to-end on iPad through the full bridge.

**Test 1 — Smoke (open → frame → capture → close):**

- Pre-grant permission on iPad (documented in `integration_test/README.md`)
- `engine.open()` → assert `caps.streamPixelFormat == 'BGRA8'`
- Subscribe to `stateStream` BEFORE creating texture so we don't miss `.streaming`
- `createPreviewTexture(stream: StreamId.processed)` → assert `> 0`
- Wait for `stateStream` first `.streaming` (5s timeout)
- Wait for `frameResultStream().first` (5s timeout)
- `captureImage()` → assert `File(path).existsSync()` AND `lengthSync() > 0`
- `destroyPreviewTexture` → `close()`

**Test 2 — Lifecycle transitions:**

- Open + reach `.streaming`
- `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` — caveat documented:
  this does NOT fire native UIScene callbacks, so v1 ships with a manual-step procedure
  documented in `integration_test/README.md` where the developer presses the home button when
  prompted by the test; v1.1 automates via `XCUIDevice`. Without the manual step the test
  validates only the Dart-side state propagation, not the full native chain.
- Assert state transitions visible on `stateStream` (`.paused` and back to `.streaming`)
- `destroyPreviewTexture` → `close()`

**Test 3 — Recording cycle:**

- Open + reach `.streaming`
- `startRecording(RecordingOptions(fps: 30))` → assert `RecordingStart.displayName` non-empty
- Wait 2 seconds (60 frames at 30fps)
- `stopRecording()` → assert `File(mp4Path).existsSync()` AND `lengthSync() > 10_000`
- `close()`

Run command (per CLAUDE.md §6 — physical iPad only):

```bash
cd flutter/example
flutter test integration_test --device-id=<iPad-UDID>
```

Wrapped in `flutter/example/scripts/test-integration.sh`.

### CameraKit tests — unchanged

Existing 203 passing tests under `CameraKit/Tests/CameraKitTests/`, run via the
`ios_example_app` Xcode scheme. Phase B doesn't add tests here.

**Cited load-bearing dependencies:** Phase B's lifecycle correctness relies on CameraKit tests:
- `LifecycleTests.Flutter resume: duplicate .background is idempotent and converges to active`
- The four scene-phase guard tests from `5b0717f` (`from .interrupted, notifyScenePhasePaused
  (false) does not force streaming (command)`, etc.)
- `interruption-ended re-arms the stall watchdog and returns to streaming`

If any of these regress, Phase B's lifecycle behavior breaks even if the plugin code is intact.
`flutter/README.md`'s testing section notes this dependency.

### Pigeon-generated code

- Pin: `pigeon: ^22.6.0` in `dev_dependencies` (the plan author may bump to a newer stable at
  implementation time; verify `EventChannelApi` shape after any bump)
- Generated files: `flutter/lib/src/pigeon/cambrian_ios_camera_api.g.dart` and
  `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift`
  — **committed to git**, not gitignored
- Bumps reviewable as `git diff` of generated files
- Trusted (Pigeon's own test suite covers correctness); we test our *use* of it

### Example app smoke

`flutter/example/test/widget_test.dart` — one-liner that asserts the `CameraScreen` widget
mounts without crashing. Runs as part of `flutter test` inside `flutter/example/`.

### CI

Not in v1 (per design decision). Tests run locally on the dev machine via:

```bash
# Dart unit + example smoke (no device)
(cd flutter && flutter test)
(cd flutter/example && flutter test)

# Swift adapter (iPad)
flutter/example/scripts/test-swift-adapter.sh

# Integration (iPad)
flutter/example/scripts/test-integration.sh

# CameraKit (iPad) — existing
mcp__XcodeBuildMCP__test_device
```

A consolidated `scripts/test-phase-b.sh` runs all four in order; fail-fast.

### Summary

| Layer | Where | Count |
|---|---|---|
| Dart unit (facade) | `flutter/test/` | ~40 |
| Example widget smoke | `flutter/example/test/widget_test.dart` | 1 |
| Swift adapter (XCTest) | `flutter/example/ios/RunnerTests/` | ~5 |
| Integration (end-to-end) | `flutter/example/integration_test/` | 3 |
| CameraKit (unchanged) | `CameraKit/Tests/CameraKitTests/` | 203 (existing) |

---

## §8 — Versioning, tagging, release

### Versioning model

Single git tag `vX.Y.Z` drives both consumers:

- **Swift:** `.package(url: ..., from: "1.0.0")` resolves to the `v1.0.0` tag, parses
  `Package.swift` at the repo root
- **Flutter:** `git: { url: ..., path: 'flutter', ref: 'v1.0.0' }` clones, checks out the tag,
  uses `flutter/` as the package dir

SemVer applied across the **combined surface**: any breaking change to either side bumps the
major.

### v1.0.0 — going-live

No pre-release tags (v0.x, v1.0.0-rc.*). Direct to v1.0.0.

**Verification gate** (all must pass before tagging):

1. `(cd flutter && flutter test)` — Dart unit + example smoke
2. `flutter/example/scripts/test-swift-adapter.sh` — Swift adapter XCTest
3. `flutter/example/scripts/test-integration.sh` — 3 integration tests on iPad
4. `mcp__XcodeBuildMCP__test_device` — CameraKit (203 tests)
5. `mcp__XcodeBuildMCP__build_run_device` — smoke `ios_example_app` (native harness)
6. `flutter run --device-id=<iPad-UDID>` from `flutter/example/` — smoke standalone-launch
7. `swift-format lint --strict CameraKit/Sources/**/*.swift` — pre-commit gate clean

Bundled via `scripts/release-gate.sh`. Fail-fast on first failure.

### Tag-time process

```bash
# 1. Bump pubspec versions
sed -i '' 's/^version: .*/version: 1.0.0+1/' flutter/pubspec.yaml
sed -i '' 's/^version: .*/version: 1.0.0+1/' flutter/example/pubspec.yaml

# 2. Commit version bump
git add flutter/pubspec.yaml flutter/example/pubspec.yaml
git commit -m "release: v1.0.0"

# 3. Tag — annotated, signed
git tag -a -s v1.0.0 -m "v1.0.0 — first release"

# 4. Verify locally
swift package describe
(cd flutter && dart pub get)

# 5. Push (user-approved per CLAUDE.md §7)
git push origin main
git push origin v1.0.0
```

`Package.swift` files (root + `flutter/ios/...`) have no version field — SPM uses the git tag.
Only `pubspec.yaml`s carry `version:` (informational for `git:` deps; pub doesn't enforce it).
The git tag is the source of truth.

### CHANGELOG strategy

- **No `CHANGELOG.md` for v1.0.0.** First release; nothing to compare against. `git log` between
  `pre-restructure-2026-05-20` and `v1.0.0` documents the changes.
- **GitHub Release notes** at tag time, hand-written, ~300 words. `gh release create v1.0.0
  --notes-file docs/release-notes-v1.0.0.md`.
- **`CHANGELOG.md` added in v1.1.0** with v1.0.0 as the bottom anchor.

### Hotfix policy

1. Cherry-pick / apply the fix on main (or branch from the tag if main has diverged)
2. Bump to v1.0.1 — repeat the tag-time process
3. **Never re-tag v1.0.0** to point at a different SHA. SPM and pub cache resolved tags; force-
   pushing breaks consumer caches

### Branching strategy

Single rolling `main`. After v1.0.0:

- All work continues on `main`
- v1.1.0 ships from `main` when its scope is ready
- If a v1.0.1 hotfix is needed and `main` has diverged with v1.1-scope changes, branch from the
  v1.0.0 tag: `git checkout -b hotfix/v1.0.1 v1.0.0`, fix, tag, push, delete branch

### Repo state at v1.0.0

- `Package.swift` (CameraKit) at repo root — SPM-resolvable
- `flutter/pubspec.yaml` with `version: 1.0.0+1`
- `flutter/lib/` Dart facade
- `flutter/ios/cambrian_ios_camera/Package.swift` with `.package(path: "../../..")`
- `flutter/android/` Kotlin no-op stub
- `flutter/example/` working example
- `flutter/test/` (~40 tests passing)
- `flutter/example/integration_test/` (3 tests passing on iPad)
- `flutter/example/ios/RunnerTests/` (5 Swift adapter tests passing on iPad)
- `CameraKit/Tests/CameraKitTests/` (203 tests passing on iPad, untouched)
- `ios_example_app/` (Phase A native harness) — internal dev tool; not part of the public
  shipped surface (the tag still includes it but consumers don't see it)
- Generated Pigeon files committed
- `README.md` (two-personality intro) updated for v1.0.0
- `CameraKit/README.md` (lifecycle field guide) — canonical lifecycle docs

### Consumer recipe

**Swift:**

```swift
let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "MyApp", dependencies: [
            .product(name: "CameraKit", package: "cambrian-ios-camera"),
        ]),
    ]
)
```

**Flutter:**

```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter
      ref: v1.0.0
```

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Pigeon `EventChannelApi` shape changes between Pigeon versions | Medium | Pinned `pigeon: ^22.6.0`; generated files committed for diff-review on any bump |
| `WidgetsBinding.instance.handleAppLifecycleStateChanged` in integration tests does NOT fire native UIScene callbacks | High | Documented limitation in Test 2; v1 ships with manual-step procedure in `integration_test/README.md`; v1.1 automates via XCUIDevice helper |
| Texture-map race: destroy called before create's HostApi round-trip completes | Low | Unit test covers; adapter no-ops on unknown textureId in destroy |
| Cold-start Metal shader compile slows first-frame past timeout | Low | CameraKit's existing `Stage06Tests.frameSetPublication` already exposes this at 200ms scale; 5s timeout is well above |
| Pigeon-generated method signatures change between Pigeon bumps | Medium | Tests run on the generated code; build catches signature drift |
| Consumer wires `WidgetsBindingObserver` for camera lifecycle anyway, ignoring README | Medium | README contract is loud; engine.stateStream() is documented as the right path |
| iOS permission resets between integration test runs | Low | `integration_test/README.md` documents the pre-grant procedure |
| Plugin's iOS adapter doesn't retain `self` for scene-callback receipt | High if forgotten | Flutter's `addApplicationDelegate(self)` retains strongly internally (`NSHashTable`-backed); no manual retain needed |
| `FlutterTextureRegistry.registerTexture()` returns 0 | None | `0` is documented as invalid; registration starts at 1 |
| `captureImage()` returns path in unexpected directory (Photos URI vs filesystem) | Low | Pigeon contract is `Future<String>` = absolute filesystem path inside the app sandbox; integration test asserts `File(path).existsSync()` |

---

## Implementation order summary

For the implementation plan (writing-plans skill):

| Step | Action | Owner |
|---|---|---|
| B0 | Verify Pigeon `EventChannelApi` shape on the current stable Pigeon version; pick the pin | Plan author |
| B1 | Extract `CameraEngineProtocol` in CameraKit so the iOS adapter can mock it (one-time CameraKit addition) | Plan author |
| B2 | Write `flutter/pigeons/cambrian_ios_camera_api.dart` — Pigeon DSL with all HostApi + EventChannelApi + value types | Plan author |
| B3 | Run pigeon, generate Dart + Swift + Kotlin bindings; commit | Plan author |
| B4 | Implement `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/*.swift` — adapter (per §5) | Plan author |
| B5 | Implement `flutter/android/src/main/kotlin/.../CambrianIosCameraPlugin.kt` — no-op stub | Plan author |
| B6 | Implement `flutter/lib/cambrian_ios_camera.dart` + `lib/src/*` — Dart facade (per §4) | Plan author |
| B7 | Implement `flutter/lib/testing.dart` — opt-in mocking export | Plan author |
| B8 | Implement `flutter/example/` — single-screen app (per §6) | Plan author |
| B9 | Write `flutter/test/*` — ~40 Dart unit tests with mockito (per §7) | Plan author |
| B10 | Write `flutter/example/ios/RunnerTests/*` — 5 Swift adapter XCTest (per §7) | Plan author |
| B11 | Write `flutter/example/integration_test/plugin_test.dart` — 3 integration tests (per §7) | Plan author |
| B12 | Write `flutter/example/integration_test/README.md` — permission pre-grant + manual lifecycle step procedure | Plan author |
| B13 | Write `flutter/example/scripts/` — test-swift-adapter.sh, test-integration.sh; root `scripts/test-phase-b.sh`, `scripts/release-gate.sh` | Plan author |
| B14 | Update root `README.md` to reference v1.0.0 in the Swift + Flutter consumer recipes | Plan author |
| B15 | Update `CameraKit/state.md` with Phase B completion entry | Plan author |
| B16 | Write `docs/release-notes-v1.0.0.md` for the GitHub release body (not committed until tag-time) | Plan author |
| B17 | Run `scripts/release-gate.sh` — all 7 checks pass | Plan author |
| B18 | Tag-time process (per §8) — user-approved at each git operation | User + Plan author |

---

## Future cleanup — deferred work

| Item | Tracking |
|---|---|
| `CameraKit → CambrianCamera` rename (Snap CameraKit SDK naming collision) | Per Phase A spec §"Future cleanup"; major-bump work; out of v1 |
| pub.dev publication for the Flutter plugin | Requires: remove relative SPM paths, license file cleanup, Android impl, `flutter pub publish --dry-run` checklist. Not in v1. |
| Swift Package Index registration | Only if Swift-only consumption demand emerges. Not in v1. |
| Real Android implementation | Separate spec; v1 ships Kotlin stub only |
| XCUIDevice automation for the lifecycle integration test | v1.1 — replaces the manual-step procedure |
| Independent tag families (`camerakit-vX.Y` / `flutter-vX.Y`) | Only if joint versioning becomes painful in practice; not in v1 |
| Multi-engine support (engineId-keyed HostApi) | Non-breaking v1.x addition if demand emerges |
| `CHANGELOG.md` | Added in v1.1.0 with v1.0.0 as bottom anchor |
| CI (GitHub Actions running `flutter test`) | Mentioned but explicitly skipped for v1 |

---

## Open questions resolved during brainstorming

1. **Plugin-owned vs Dart-driven lifecycle** — plugin-owned via UIScene callbacks (with the
   `addApplicationDelegate(self)` registration). Initially the design had `engine.pause()`/`resume()`
   on the Dart side for "user-intent pauses"; cam2fd's primary-source evidence (FSM crashes
   from Dart-driven lifecycle on iOS) + the merged CameraKit work removing user-intent
   `pause()`/`resume()` together settled this as Dart-has-no-lifecycle-surface.
2. **Dart facade shape** — single `CameraEngine` class mirroring Swift, not layered roles, not
   pure-Pigeon-generated bindings. Refactor cost is low; mental model maps to Swift docs.
3. **Stream model** — Pigeon `EventChannelApi` (one per stream), not a single multiplexed
   channel and not polling. Matches the Swift `AsyncStream` model one-to-one.
4. **Preview model** — `Texture(textureId:)` per stream with explicit create/destroy, not an
   implicit single texture, not a purpose-built `PreviewWidget` (one is provided as a
   reference *value type* — not a widget — for convenience).
5. **`@visibleForTesting` injection seam** — moved to a separate `lib/testing.dart` library
   export rather than `@visibleForTesting` in the main library. `@visibleForTesting` is a
   linter annotation, not access control; consumers would reach for it and freeze a surface
   we can't remove.
6. **Hand-rolled stubs vs mockito** — mockito + build_runner from day one. 25+ HostApi methods
   × every Pigeon bump = real maintenance cost for hand-rolled stubs; mockito generates from
   annotations.
7. **Swift adapter unit tests** — added (~5 tests), not skipped. Thin-translation argument
   doesn't apply to the scene-callback delegate or the texture map — those are stateful.
8. **Integration test count** — 3, not 1. Lifecycle and recording are too risky to leave
   uncovered.
9. **CHANGELOG vs release notes** — release notes for v1.0.0; CHANGELOG starts at v1.1.0.
10. **Pre-release tags (v0.x, rc.*)** — none. Direct to v1.0.0.

---

## Self-review notes

**Placeholder scan:** No TBDs, no TODOs, no "fill in later" sections. Every test category has
specific coverage. Every Pigeon method is enumerated. Every file path is concrete.

**Internal consistency:** Section 5's adapter pattern (`addApplicationDelegate(self)` +
UIScene callback selectors implemented directly) is consistent with §1's architecture diagram
and §4's "no Dart lifecycle surface" claim. Section 3's texture-bridge create/destroy pattern is
referenced consistently in §4 (Dart API) and §5 (adapter map). §7's test counts add up across
the pyramid.

**Scope check:** This is one cohesive feature (ship the Flutter plugin) with layered sub-areas.
Single implementation plan is appropriate — no decomposition needed.

**Ambiguity check:** The `FlutterSceneLifeCycleDelegate` terminology from `CameraKit/README.md`
was clarified — there is no public Flutter protocol by that name; the plugin's main class
implements UIScene callback selectors directly and registers via
`addApplicationDelegate(self)`. `captureImage()` return is locked to "absolute filesystem path
in the app's sandbox." Texture ID `> 0` assertion is locked. Pigeon version pin (`^22.6.0`) is
explicit.

---

**End of design spec.** Next step: writing-plans skill produces the implementation plan from
this spec.
