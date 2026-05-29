# CameraKit → Flutter Migration — Phase 3 Design

**Status:** Draft 2026-05-18
**Companion to:** `2026-05-14-camerakit-flutter-migration-design.md` (Phases 1–2 design, amended);
`2026-05-15-phase3-handoff-notes.md` (carry-forward notes);
`2026-05-15-texture-bridge-cadence-design.md` + `measurements/texture-bridge/2026-05-15/notes.md` (bridge spike + verdict);
`measurements/flutter-spm-spike/2026-05-15.md` (packaging spike + verdict);
`measurements/phase-3-prep/rgba8-conversion.md` (pixel-format closure).

**Scope:** Phase 3 of the CameraKit → Flutter migration. Work in this phase
spans **two repos**: `eva-swift-stitch` (this repo — the CameraKit producer
and its dev harness) and `camera2_flutter_demo` (cam2fd — the Flutter plugin
consumer at `packages/cambrian_camera/`). Phase 3 is the first time cam2fd's
iOS side gets a real implementation; today it ships a no-op `register` stub
(`packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift:9`).

**This spec covers the Phase 3 design. The plan that executes it follows
separately.**

---

## Context

Phases 1–2 left CameraKit cleanly extractable. Specifically:

- The package has zero SwiftUI / app-target code (Phase 1A); the dev harness
  lives in `eva-swift-stitch/UI/`. Imports `CameraKit` as a local SPM dep.
- OpenCV and the Canny consumer live in the app target (Phase 1B); the
  package's `CameraKitCxx` slimmed to the consumer-join seam. External
  consumers attach via `engine.getNativePipelineHandle()` +
  `pixel_sink_pool_register`.
- `CameraEngine`'s public surface is conformed to the (amended) Pigeon
  vocabulary (Phase 2 §2a–§2d): `setProcessingParams`,
  `OpenConfiguration.initialSettings`, capability range fields,
  `streamConfigurationStream()`, `currentPixelBuffer(stream:) -> CVPixelBuffer?`,
  `cameraPermissionStatus()`/`requestCameraPermission()` (and Photos
  equivalents), `SessionState.interrupted`, engine-side
  `calibrateWhiteBalance()` / `calibrateBlackBalance()` returning
  `CalibrationResult { before, after, converged, iterations }`.
- `captureNaturalPicture(outputURL:photosDestination:)` is live engine-side
  (D-2P-10 — taps `currentPixelBuffer(stream: .natural)`; no
  `AVCapturePhotoOutput`).
- Default lane wire-format is BGRA8 (`kCVPixelFormatType_32BGRA`) via the
  Pass-7 conversion; texture mailboxes stay RGBA16F for still capture
  (D-2P-09, D-2P-11; HITL `measurements/phase-3-prep/rgba8-conversion.md`).
- The `camerakit-only` synthetic branch is live on `origin`
  (`https://github.com/Shreeyak/cambrian-ios-camera.git`); the
  `.githooks/pre-push` hook regenerates it on every push to `origin/main`
  that touches `CameraKit/` (CLAUDE.md §10).

Two empirical de-risks were closed before this spec:

- **Packaging (SPM vs. CocoaPods).** `measurements/flutter-spm-spike/2026-05-15.md`
  verified Flutter's SPM integration accepts CameraKit's three-target shape
  verbatim, with `apple/swift-atomics` as a normal `.package(url:)` dep, no
  vendoring, and dual-mode tolerance for any CocoaPods-only sibling plugins.
  **Verdict: SPM.** CocoaPods remains documented as a fallback.
- **Texture-bridge cadence.** `measurements/texture-bridge/2026-05-15/notes.md`
  ran the cadence-spike on iPad Pro 11" 2nd gen. **Verdict: no mitigation
  needed.** The simple bridge — `copyPixelBuffer()` returns
  `currentPixelBuffer(stream:)` directly; per-lane subscriber `Task` fires
  `textureFrameAvailable` — is the production design.

---

## Target architecture

```
camera2_flutter_demo/packages/cambrian_camera/
└── ios/
    ├── CameraKit/                        ← git subtree from camerakit-only @ tag
    │   ├── Package.swift                  (CameraKit/Sources/... at root)
    │   ├── Sources/{CameraKit,CameraKitInterop,CameraKitCxx}/
    │   └── Tests/CameraKitTests/
    └── cambrian_camera/
        ├── Package.swift                  ← SPM Flutter-plugin package
        │   ├── .package(path: "../CameraKit")
        │   ├── product .library(name: "cambrian-camera", targets: ["cambrian_camera"])
        │   └── target cambrian_camera depends on "CameraKit"
        └── Sources/cambrian_camera/
            ├── CambrianCameraPlugin.swift  ← FlutterPlugin registrar + lifecycle observer
            ├── CameraIosHostApiImpl.swift  ← iOS-only HostApi (calibrate*)
            ├── CameraHostApiImpl.swift     ← shared HostApi (all other methods)
            ├── HandleRegistry.swift        ← Int64 handle ↔ CameraEngine map
            ├── FlutterApiPump.swift        ← AsyncStream → FlutterApi bridge
            ├── CameraLaneTexture.swift     ← FlutterTexture (natural, processed)
            ├── PigeonValueMapping.swift    ← Cam* ↔ CameraKit value conversions
            └── Messages.g.swift            ← Pigeon-generated (shared API)
            └── Messages_ios.g.swift        ← Pigeon-generated (iOS-only API)
```

Three layers, no overlap:

1. **`CameraEngine` actor (CameraKit).** Curated public surface (Phase-2
   exit). Engine never sees Pigeon types, never produces `Int64` handles,
   never deals in `Result` completion callbacks. Same surface the
   eva-swift-stitch dev harness consumes.
2. **`Cambrian*HostApiImpl` classes (plugin, this spec).** Implement the
   Pigeon-generated `CameraHostApi` (+ `CameraIosHostApi`). Absorb all wire
   baggage: handle bookkeeping, `Cam*` ↔ native translation,
   `AsyncStream` → `FlutterApi` callback pumping, `Result` completion
   handlers, signed/nullable bridging. Each method is a thin translation
   into a `CameraEngine` call.
3. **`CambrianCameraPlugin` registrar + lifecycle observer (plugin).**
   Standard Flutter plugin shape: `register(with:)` registers HostApi
   impls + the texture bridge + the Flutter→Dart `FlutterApi` proxy.
   Owns the scene-phase and AVF interruption observation that Android
   handles via `ProcessLifecycleObserver` — neither surface appears on
   the Pigeon wire.

---

## §1. Snapshot mechanism — `git subtree` from `camerakit-only`

CameraKit physically lives in `eva-swift-stitch`. cam2fd consumes it as a
**git subtree** of the `camerakit-only` synthetic branch:

```bash
# In cam2fd, one time:
git subtree add \
  --prefix=packages/cambrian_camera/ios/CameraKit \
  https://github.com/Shreeyak/cambrian-ios-camera.git camerakit-only --squash
```

The `camerakit-only` branch has `CameraKit/`'s root contents promoted to
the repo root (`Package.swift` at `/Package.swift`, not
`/CameraKit/Package.swift`); history is `git subtree split` of the
`CameraKit/` prefix. Verified today: `git ls-tree --name-only camerakit-only`
shows `Package.swift`, `Sources/`, `Tests/`, `CONTRACTS.md`,
`DECISIONS.md`, `state.md` at root. No `App/`, no `scripts/`, no broken
`implementation/` symlinks.

### Pin-by-tag, not pin-by-branch

cam2fd's `ios/cambrian_camera/Package.swift` references CameraKit as a
local path: `.package(path: "../CameraKit")`. The *content* in
`ios/CameraKit/` is checked into cam2fd's repo, so cam2fd has its own
commit-pinned snapshot. To update:

```bash
git subtree pull \
  --prefix=packages/cambrian_camera/ios/CameraKit \
  https://github.com/Shreeyak/cambrian-ios-camera.git <tag> --squash
```

**`<tag>` is a CameraKit milestone tag**, not the `camerakit-only` branch
tip. CLAUDE.md §10 ("Version pinning via tags") documents the cut-a-release
flow on the producer side:

```bash
# eva-swift-stitch — at a CameraKit milestone:
git tag -a v1.0.0 -m "..." main
git push origin v1.0.0
git tag -a camerakit-v1.0.0 camerakit-only -m "..."
git push origin camerakit-v1.0.0
```

cam2fd then `subtree pull`s `camerakit-v1.0.0`. **Phase 3's first adoption
uses `camerakit-v1.0.0`** (or whatever tag is cut at the moment Phase 3
lands); branch-tip pulls are reserved for explicit "track latest" dev
flows.

### Editing CameraKit while iterating Phase 3 — eva-swift-stitch remains canonical

CameraKit source edits stay in eva-swift-stitch (the upstream). For
Phase 3 development that needs an unreleased CameraKit change, the
canonical flow is:

1. Edit + verify in eva-swift-stitch on `main` (or a branch); push.
2. Pre-push hook regenerates `camerakit-only` and force-pushes.
3. Cut an interim tag if the cam2fd-side work needs to pin to it.
4. `subtree pull` the tag in cam2fd; rebuild the example app.

**Do not edit `packages/cambrian_camera/ios/CameraKit/` directly in cam2fd.**
The subtree contents are a snapshot; local edits there would be silently
overwritten by the next `subtree pull`. If a CameraKit bug surfaces during
Phase 3 wiring, fix it in eva-swift-stitch.

### Why not `swift package edit` or a Swift-package git source

`swift package edit` requires a local checkout sibling and breaks the
plugin's repo-self-contained property. A git-source dep (`.package(url:
"https://github.com/Shreeyak/cambrian-ios-camera.git", branch:
"camerakit-only")`) would let Flutter consumers transitively fetch from a
remote at every `flutter pub get` — a UX hit on top of subtree's existing
"content is in the repo" guarantee, and one that breaks for any consumer
without GitHub access to the producer repo. Subtree wins.

---

## §2. Plugin packaging — SPM, per the spike verdict

The cam2fd plugin's `ios/cambrian_camera/Package.swift` mirrors the SPM
spike's verified shape verbatim, adapted to consume the subtreed CameraKit:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cambrian_camera",
    platforms: [.iOS("26.0")],
    products: [
        // Kebab-case name — Flutter's auto-generated FlutterGeneratedPluginSwiftPackage
        // umbrella references it as .product(name: "cambrian-camera", ...).
        .library(name: "cambrian-camera", targets: ["cambrian_camera"]),
    ],
    dependencies: [
        // Local sibling — checked-in via git subtree from camerakit-only.
        .package(path: "../CameraKit"),
    ],
    targets: [
        .target(
            name: "cambrian_camera",
            dependencies: [
                .product(name: "CameraKit", package: "CameraKit"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                // Plugin layer stays at Swift 5 to dodge the FlutterMethodNotImplemented
                // Sendable warning. CameraKit's three internal targets stay Swift 6.
                .swiftLanguageMode(.v5),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
```

Operational facts pinned by the spike, repeated here so the plan doesn't
have to discover them:

- **Snake-case target name, kebab-case product name** — Flutter's
  plugin-discovery code derives the umbrella's `.product(name: ...)` from
  the `pubspec.yaml` name (`cambrian_camera`); the umbrella entry is
  `cambrian-camera`. Mismatch breaks discovery silently.
- **Plugin-class name** — `<PascalCase(name)> + "Plugin"` unless the
  snake_case name already ends in `_plugin`. `cambrian_camera` →
  `CambrianCameraPlugin`. Today's iOS stub already uses this — keep it.
  Mismatch causes `Use of undeclared identifier 'CambrianCameraPlugin'`
  in `Runner/GeneratedPluginRegistrant.m`.
- **`flutter build` (not `flutter pub get`) migrates the umbrella iOS
  platform.** With iOS 26 in this `Package.swift` and the umbrella's
  default at iOS 13, `xcodebuild` fails with "requires minimum platform
  version 26.0 ... but this target supports 13.0". `flutter build ios
  --debug --no-codesign` runs the migration. Document this in the
  plugin's `README.md`.
- **`.interoperabilityMode(.Cxx)` is mandatory on the plugin target.**
  `CameraKit`'s emitted `.swiftmodule` references C++-shaped types in
  its interface; the consumer must enable cxx-interop to deserialize the
  interface. Verified in both spikes.
- **`apple/swift-atomics` is pulled transitively from CameraKit's
  `Package.swift`.** No need to declare it again in the plugin package.

### Brownfield directory migration — pre-SPM layout to SPM-resident layout

The existing cam2fd plugin is **pre-SPM**: source lives at
`ios/Classes/CambrianCameraPlugin.swift` (a no-op stub) and the
`ios/cambrian_camera.podspec` globs `s.source_files = 'Classes/**/*'`.
Phase 3's target layout puts the source at
`ios/cambrian_camera/Sources/cambrian_camera/*.swift` (next to the new
`Package.swift`), per §2's tree. The SPM spike scaffolded from a fresh
`flutter create` (greenfield); brownfield migration paths:

- **(Recommended) Hand-build the SPM scaffold.** Create
  `ios/cambrian_camera/Package.swift` + `Sources/cambrian_camera/`
  manually; move the source files. Avoids the destructive `flutter
  create --template=plugin --platforms=ios .` over the existing
  directory, which would clobber the existing Dart side and the
  Android implementation.
- **(Not chosen) `flutter create` over the existing tree** — its
  greenfield scaffold would overwrite `lib/`, `pigeons/`, `android/`.
  Off-limits.

The plan executes the recommended path step-by-step (move, not
overwrite).

### Existing `cambrian_camera.podspec` stays in place — `source_files` repointed

`flutter create -t plugin` ships both a `Package.swift` and a `.podspec`
by default (dual-mode). The existing
`packages/cambrian_camera/ios/cambrian_camera.podspec` stays as the
CocoaPods fallback for consumers that haven't enabled
`flutter config --enable-swift-package-manager`. Phase 3 updates the
podspec in two ways:

- `s.platform = :ios, '26.0'` (currently `'12.0'`).
- `s.source_files` is repointed from `'Classes/**/*'` (no longer real)
  to the new SPM-resident location:
  `'cambrian_camera/Sources/cambrian_camera/**/*.swift'`. This lets the
  podspec compile the same Swift sources as the SPM target without
  duplicating them. The Pigeon-generated `Messages.g.swift` /
  `Messages_ios.g.swift` either live alongside under
  `cambrian_camera/Sources/cambrian_camera/` (the SPM-canonical path) or
  remain at `Classes/` and get matched by an additional glob entry — the
  plan picks one path and uses it consistently.

The CocoaPods-spike documentation
(`measurements/cocoapods-cxx-spike/2026-05-15.md`) is the reference for
the four-pod shape if the SPM path ever needs to be retired — Phase 3
does **not** build the four-pod shape; SPM is the production path and
the podspec exists only to compile the *plugin* layer's Swift sources
as a single CocoaPods unit that depends on CameraKit (via the subtreed
sources directly, since CocoaPods cannot consume a sibling SPM
package). The fallback-mode dependency graph is out of scope for this
spec; it is acceptable for the podspec build to fail in that
configuration until the four-pod path is re-instated, because the SPM
path is what every consumer will use.

### `Package.resolved` and binary artifacts

The subtreed CameraKit brings its own `Package.resolved` (pinning
`apple/swift-atomics`). cam2fd's example app has its own
`Package.resolved` once Flutter resolves. Both are checked in.
CameraKit's `.build/` is gitignored on both sides — never committed.

---

## §3. Pigeon adapter — handles, mapping, dispatch

### Handle ownership

Pigeon types all camera handles as `Int64`. CameraKit has no notion of a
handle — there is one `CameraEngine` per open session. The plugin owns
the handle ↔ engine map:

```swift
actor HandleRegistry {
    private var nextHandle: Int64 = 1
    private var engines: [Int64: CameraEngine] = [:]

    func register(_ engine: CameraEngine) -> Int64 { ... }
    func resolve(_ handle: Int64) throws -> CameraEngine { ... }
    func unregister(_ handle: Int64) { ... }
}
```

- **One engine per `open(...)` call.** `open` constructs a new
  `CameraEngine`, registers it, returns the new handle. Multi-camera is
  out of scope — the same shape supports it if needed later.
- **Single-engine guard at the impl edge.** `CameraHostApiImpl.open(...)`
  serializes against a `var openInFlight: Bool` flag (or an
  `AsyncSemaphore(value: 1)`); a second `open` while one is in flight
  throws `PigeonError(code: "open_in_flight", ...)`. The HandleRegistry
  actor serializes the register/resolve/unregister steps but does not
  itself guard "two opens before either finishes" — that's an impl-edge
  concern.
- **`close(handle)` unregisters before awaiting `engine.close()`** so a
  concurrent `getCapabilities(handle)` after close fails fast with
  `notFound`, never deadlocks waiting for the closing engine.
- **Unknown handle → `FlutterError(code: "not_found", ...)`** at the impl
  edge; never crash.

### `Cam*` ↔ CameraKit value mapping

The table below pins every wire type to its CameraKit counterpart. Where
the names diverge, the adapter does the rename — neither the engine nor
the Pigeon contract bends to match the other.

| Pigeon (`Cam*`) | CameraKit | Adapter notes |
|---|---|---|
| `CamSize { width, height }` | `Size` (Int, Int) | Direct field copy |
| `CamSettings { isoMode, iso, exposureMode, exposureTimeNs, focusMode, focusDistanceDiopters, wbMode, wbGainR/G/B, zoomRatio, noiseReductionMode, edgeMode, evCompensation, enableNaturalStream, naturalStreamHeight, cropOutputSize }` | `CameraSettings` (post-Phase-2 vocabulary) | `focusDistanceDiopters` (wire) ↔ `focusDistance` (engine) per **D-2P-01** — iOS `lensPosition` is normalized `[0, 1]`, not real diopters; the field name stays accurate on each side. Adapter does the rename, never multiplies units. `enableNaturalStream` / `naturalStreamHeight` ↔ Phase 2 natural-stream toggles (§7.1). `noiseReductionMode` / `edgeMode` are Android-only — adapter ignores on read, passes through unchanged on write (CameraEngine ignores them silently per §2d.3). |
| `CamProcessingParams { blackR/G/B, gamma, brightness, contrast, saturation }` | `ProcessingParameters` | Direct field copy; engine field names already aligned per Phase 2 §2a |
| `CamCapabilities { supportedSizes, iso/exposure/focus/zoom/evComp ranges, naturalStreamTextureId, naturalStreamWidth/Height, streamWidth/Height, sensorStreamWidth/Height, streamPixelFormat }` | `SessionCapabilities` | `naturalStreamTextureId` minted by §4 — texture bridge. `streamPixelFormat` is `"BGRA8"` by default (D-2P-09, D-2P-11). `evCompensationStep` keeps its `double` typing on the wire. |
| `CamStateUpdate { state: String }` | `SessionState` enum | Map enum to lowercase string: `closed`/`opening`/`streaming`/`recovering`/`paused`/`error`/`interrupted`. `.interrupted` is the Phase-2 addition (§2d.5). |
| `CamErrorCode` enum | `CameraError.Code` | iOS-relevant codes map 1:1 (`permissionDenied`, `cameraInUse`, `cameraDisconnected`, `configurationFailed`, `captureFailure`, `fpsDegraded`, `aeConvergenceTimeout`, `recordingTruncated`, `unknown`). Android-only codes (`cameraDevice`, `cameraService`, `cameraDisabled`, `maxCamerasInUse`, `previewSurfaceLost`, `pipelineError`) are **never emitted** by the iOS adapter (§2d.3). `settingsConflict` is mapped from CameraKit's `EngineError.calibrationInProgress` + any future settings validation. |
| `CamError { code, message, isFatal }` | `CameraError` | `isFatal` comes from the engine's classification; the adapter does not re-classify. |
| `CamFrameResult { iso, exposureTimeNs, focusDistanceDiopters, wbGainR/G/B }` | `FrameResult` | Same `focusDistanceDiopters` rename as `CamSettings`. ~3 Hz emit cadence is engine-side (already implemented). |
| `CamRgbSample { r, g, b }` | `RgbSample` | Direct field copy. |
| `CamCalibrationResult { before, after, converged, iterations }` (iOS-only contract — §8) | `CalibrationResult` | Phase-2 single-shot path returns `converged: true, iterations: 1`; the future iterative Dart port populates them meaningfully without a contract bump (D-2P-02). |
| `CamStreamConfiguration` *(new — replaces heavy `CamCapabilities` on the change callback, §7.2)* | `StreamConfiguration` (Phase 2 §2c) | `naturalTextureId` + `previewTextureId` fields minted by §4. Phase 2 emits the resolution + crop portion; Phase 3 adds the texture-ID portion on the Pigeon type and at the adapter's emit site. |

### `AsyncStream` → `FlutterApi` pump

Each engine stream gets a single per-handle `Task`:

```swift
final class FlutterApiPump {
    let api: CameraFlutterApi
    var tasks: [Task<Void, Never>] = []

    func start(handle: Int64, engine: CameraEngine) {
        tasks.append(Task { [api] in
            for await state in engine.stateStream() {
                let update = CamStateUpdate(state: state.wireString)
                await MainActor.run {
                    api.onStateChanged(handle: handle, state: update) { _ in }
                }
            }
        })
        // ... onError, onFrameResult, onStreamConfigurationChanged, onRecordingStateChanged
    }

    func stop() { tasks.forEach { $0.cancel() } }
}
```

`FlutterApi` callbacks marshal to the main thread (Flutter's plugin
contract). The `Result` completion handler from Flutter side is ignored
on fire-and-forget callbacks (Flutter's API design — the completion
exists for back-pressure surfaces we don't use). One pump instance per
open handle; torn down at `close`.

### `getNativePipelineHandle` — sign + nullability bridge

Pigeon: `@async int? getNativePipelineHandle(int handle)` (returns `Int64?`
on Swift). CameraKit: `func getNativePipelineHandle() -> UInt64?` returning
the C++ pool's `uintptr_t` cast. Adapter:

```swift
func getNativePipelineHandle(handle: Int64, completion: @escaping (Result<Int64?, Error>) -> Void) {
    Task {
        guard let engine = try? await registry.resolve(handle) else {
            completion(.failure(PigeonError(code: "not_found", message: ..., details: nil)))
            return
        }
        let unsignedHandle = await engine.getNativePipelineHandle()
        // UInt64 → Int64 reinterpret cast — pointer values fit; we are not
        // arithmetic-comparing the result, only round-tripping to native
        // code via pixel_sink_pool_register's `void*` cast.
        let signed = unsignedHandle.map { Int64(bitPattern: $0) }
        completion(.success(signed))
    }
}
```

Caller-side: Dart Flutter code does **not** dereference this value — it
only passes it to a native consumer registered via the cam2fd plugin's
own consumer-registration affordance (out of scope here; the consumer
side ships as Flutter-side application code that calls
`pixel_sink_pool_register` directly via FFI).

### Lifecycle is plugin-internal — does not appear on Pigeon

Mirrors Android's `ProcessLifecycleObserver`:

- **`CambrianCameraPlugin` registers as `UIApplicationDelegate`** for
  scene-phase events; on background, calls `engine.notifyScenePhasePaused(true)`
  for every open handle; on foreground, `notifyScenePhasePaused(false)`.
  This is the SwiftUI-ScenePhase route the eva-swift-stitch harness wires
  via `.onChange(of: scenePhase)`; the plugin owns it in the Flutter
  context. Per **D-2P-07**, this routes through `SessionState.paused` /
  `.streaming` (not `.interrupted`).
- **AVF `wasInterruptedNotification` / `interruptionEndedNotification`
  observation** lives on `CameraEngine` (Phase 2 already wires this);
  the plugin does nothing extra. The engine emits `SessionState.interrupted`
  on the existing route per D-2P-04.
- **Pigeon `pause(handle)` / `resume(handle)`** map to `engine.pause()` /
  `engine.resume()` — the semantic ones (Stage-10 gate). Distinct from
  the scene-phase route above; the Flutter caller may want explicit
  pause/resume independent of app lifecycle.

`backgroundSuspend` / `backgroundResume` from CameraKit's public surface
are **not exposed on Pigeon**. They are the lower-level UIKit
background-task primitives the harness uses; the plugin's lifecycle
observer wraps them as a higher-level concern.

---

## §4. FlutterTexture bridge — simple pull, per spike verdict

The `measurements/texture-bridge/2026-05-15/notes.md` spike concluded
**no mitigation needed.** Phase 3 ships the simple version.

### Per-lane `FlutterTexture` implementation

```swift
final class CameraLaneTexture: NSObject, FlutterTexture {
    let engine: CameraEngine
    let stream: StreamId  // .natural | .processed (NOT .tracker — see below)

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buffer = engine.currentPixelBuffer(stream: stream) else { return nil }
        return Unmanaged.passRetained(buffer)
    }
}
```

`engine.currentPixelBuffer(stream:)` is the `nonisolated` synchronous
accessor added in Phase 2 §2c — reads the live `Mailbox<CVPixelBuffer>`
written by `MetalPipeline`'s delivery queue. No actor hop, no copy.

Buffers are IOSurface-backed `kCVPixelFormatType_32BGRA` (per
**D-2P-09** + **D-2P-11** + `measurements/phase-3-prep/rgba8-conversion.md`).
Flutter's iOS embedder wraps via `CVMetalTextureCacheCreateTextureFromImage`
as `.bgra8Unorm` — genuinely zero-copy. The Phase-3 handoff notes'
three-option deliberation on RGBA16F (BGRA vs. RGBA16F vs. compute
convert) is **closed**: Phase 2 chose BGRA8 as the bridge-facing wire
format; the bridge does not wrap anything other than BGRA8.

### Frame-availability nudge — per-lane subscriber Task

```swift
final class CameraLaneBridge {
    let registry: FlutterTextureRegistry
    let textureId: Int64
    let engine: CameraEngine
    let stream: StreamId
    var nudgeTask: Task<Void, Never>?

    func start() {
        nudgeTask = Task { [registry, textureId] in
            for await _ in engine.consumers.subscribe(stream: stream) {
                // The yielded FrameSet itself is unused — only the signal.
                // Marshalling to main thread per Flutter's textureFrameAvailable
                // contract is handled by the FlutterTextureRegistry impl.
                await MainActor.run {
                    registry.textureFrameAvailable(textureId)
                }
            }
        }
    }

    func stop() { nudgeTask?.cancel() }
}
```

The yielded `FrameSet` is discarded — the bridge does not consume frames
itself; it consumes the *signal* that a new frame exists and trusts
`copyPixelBuffer()` to read the latest one when Flutter pulls.
`consumers.subscribe(stream:)` already uses `.bufferingNewest(1)` per
ADR-22 so the Task can never lag.

### Lane wiring at `open` / `close`

The plugin registers one `CameraLaneTexture` per surfaced lane
(`.natural`, `.processed`) on first `open`, captures the
`registry.register(...)` IDs, populates `CamCapabilities.naturalStreamTextureId`
and the new `CamStreamConfiguration.previewTextureId` (the field carries
the *processed* preview texture id; the name on the wire mirrors
Android's existing `previewTextureId`). On `close`, unregister both
textures and cancel both nudge tasks.

`StreamId.tracker` is **not** bridged. The tracker lane has no Pigeon
counterpart (it's the C++ consumer feed registered via
`getNativePipelineHandle`); the harness still consumes its texture for
the debug overlay. D-2P-11 already removed the tracker from the Pass-7
BGRA8 conversion for exactly this reason — it stays RGBA16F end-to-end.

### `CamStreamConfiguration` — the texture-ID field is minted here

Phase 2 emits `StreamConfiguration { captureResolution, cropRegion }` on
`streamConfigurationStream()`. Phase 3:

- Adds `naturalTextureId: Int` and `previewTextureId: Int` fields to the
  Pigeon `CamStreamConfiguration` type (per §2d.2 — texture-ID slot
  reserved for Phase 3).
- The adapter populates both fields from the texture-registry IDs at
  emit time; they are stable across the open session, so the emitted
  values are constants once a session is open.
- The contract type carries them so a Flutter caller that re-reads the
  configuration on `onStreamConfigurationChanged` always gets the
  current ID set without a separate `getCapabilities` round-trip.

### Loaded-mode jitter follow-up

The spike's notes.md flagged: under a 5000-circle stressor, raster-thread
saturation drops `signal:pull` to 0.949 and pushes P95 first-pull latency
to ~32 ms — *not* a bridge problem (none of the mitigations help).
Phase 3 carries forward:

- **Add a Flutter raster-time signpost.** A single `os_signpost`-style
  metric on the Flutter side per widget frame, exposed via the existing
  metrics surface, so ops can detect raster-thread saturation in
  production with real UI load. Wiring this lives in cam2fd, not in
  CameraKit. The exact surface (Dart-side `Timeline.timeSync` →
  `os_signpost` round-trip) is sketched in the plan that follows this
  spec; the design choice here is that **the production app's Flutter UI
  budget bounds preview smoothness**, and if it saturates the right
  response is to re-budget the UI, not to add bridge state.
- **Mitigation 3 is the on-the-shelf escalation.** If a later
  integration test on real CameraKit lanes (post-Phase-3) shows visible
  tearing, switch the bridge from "read latest mailbox directly" to
  "subscribe to `consumers.subscribe(stream:)` and write into a 1-deep
  ring; `copyPixelBuffer` reads the ring." Spec'd verbatim in
  `2026-05-15-texture-bridge-cadence-design.md` §Mitigation 3, ~50 LOC.

### Pixel format is closed — do not re-open in implementation

Per `measurements/phase-3-prep/rgba8-conversion.md` and **D-2P-11**: BGRA8
wire format is the production setting; opt-out (`lanesEightBit: false`)
returns the bridge to RGBA16F but is **not** a path the Flutter consumer
exercises. Phase 3 does not implement an RGBA16F bridge variant.

---

## §5. Pigeon contract amendments — applied in Phase 3

Phases 1–2 §2d decided every amendment; Phase 3 **applies** them to
`packages/cambrian_camera/pigeons/camera_api.dart` (plus a new sibling
file per §8), the regenerated Android Kotlin (`android/src/main/kotlin/.../Messages.g.kt`),
and the existing Android implementation (`CambrianCameraPlugin.kt` +
`CameraController.kt` + the Dart layer). Each amendment below names the
cross-platform inventory.

### §5.1 `rawStream*` → `naturalStream*` (§2d.1)

**Pigeon (`pigeons/camera_api.dart`):**
- `CamSettings.enableRawStream` → `enableNaturalStream`
- `CamSettings.rawStreamHeight` → `naturalStreamHeight`
- `CamCapabilities.rawStreamTextureId` → `naturalStreamTextureId`
- `CamCapabilities.rawStreamWidth` → `naturalStreamWidth`
- `CamCapabilities.rawStreamHeight` → `naturalStreamHeight`

**Regenerated outputs:** `lib/src/messages.g.dart`,
`ios/Classes/Messages.g.swift`,
`android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`.

**Android Kotlin** (`CameraController.kt` + `CambrianCameraPlugin.kt` +
`GpuRenderer.cpp`): every reader/writer using `rawStream*` renames in
lockstep. No semantic change — it is a pure rename across the codebase.
**Dart UI** (`cambrian_camera_controller.dart` and any public field
exposure): rename to match.

**iOS adapter:** new code; uses the renamed Pigeon types directly.

### §5.2 `onCapabilitiesChanged` → `onStreamConfigurationChanged` + `CamStreamConfiguration` (§2d.2)

**Pigeon:**
- Remove `CameraFlutterApi.onCapabilitiesChanged(int handle, CamCapabilities)`.
- Add `CameraFlutterApi.onStreamConfigurationChanged(int handle, CamStreamConfiguration)`.
- Add new type:
  ```dart
  class CamStreamConfiguration {
    CamStreamConfiguration({
      required this.captureWidth,
      required this.captureHeight,
      this.cropWidth,
      this.cropHeight,
      required this.naturalTextureId,
      required this.previewTextureId,
    });
    int captureWidth;
    int captureHeight;
    int? cropWidth;  // null = no crop
    int? cropHeight;
    int naturalTextureId;
    int previewTextureId;
  }
  ```

**Android:** previously emitted `onCapabilitiesChanged` from `CameraController.kt`'s
crop/resolution apply sites. Phase 3 rewires those emit points to build a
`CamStreamConfiguration` and call `onStreamConfigurationChanged` instead.
The full `CamCapabilities` is still served on demand via
`getCapabilities(handle)` — only the change callback narrows.

**iOS adapter:** wires `engine.streamConfigurationStream()` (already
Phase 2) → `onStreamConfigurationChanged` via the §3 pump, populating the
texture-ID fields per §4.

**Dart:** any cache of "last-known stream configuration" replaces from
`CamStreamConfiguration` instead of `CamCapabilities`. The
`getCapabilities` call remains for one-time bootstrap reads.

### §5.3 Android-only fields and error codes (§2d.3) — kept; iOS no-ops

**Pigeon:** no change. Fields stay (`CamSettings.noiseReductionMode`,
`CamSettings.edgeMode`; error codes `cameraDevice`, `cameraService`,
`cameraDisabled`, `maxCamerasInUse`, `previewSurfaceLost`, `pipelineError`).
The shared cross-platform contract intentionally carries them.

**iOS adapter:** reads of `CamSettings.noiseReductionMode` / `edgeMode`
are dropped on the floor (engine ignores; the Android values are
Camera2 enum ints with no AVF equivalent). Writes never set these
fields back. The six Android-only error codes are **never produced** by
the iOS error pump.

**Dart:** documentation only — note that these surfaces are no-ops on
iOS so callers that branch on them know the platform behavior.

### §5.4 `photosDestination` + PHAsset return shape (§2d.4)

**Pigeon:** broaden `captureImage` and `captureNaturalPicture`:

```dart
class CamPhotosDestination {
  CamPhotosDestination({this.albumName, required this.saveToLibrary});
  String? albumName;       // optional iOS Photos album
  bool saveToLibrary;       // true = Photos; false = file path only
}

class CamCaptureResult {
  CamCaptureResult({this.filePath, this.phAssetLocalId});
  String? filePath;          // present when saveToLibrary == false, OR fallback
  String? phAssetLocalId;    // present when saveToLibrary == true on iOS
}

@async CamCaptureResult captureImage(
  int handle, String? outputDirectory, String? fileName,
  CamPhotosDestination? destination,
);

@async CamCaptureResult captureNaturalPicture(
  int handle, String? outputDirectory, String? fileName,
  CamPhotosDestination? destination,
);
```

**iOS adapter:** routes through `engine.captureImage(..., photosDestination:)`
/ `engine.captureNaturalPicture(..., photosDestination:)` (already
implemented in CameraKit). Maps the result based on what the engine
returned (file URL ↔ filePath, PHAsset identifier ↔ phAssetLocalId).

**Android:** `MediaStore`-based gallery write continues to yield a file
path (no PHAsset equivalent). On Android, `CamCaptureResult.filePath` is
always populated, `phAssetLocalId` always null. No Android-Kotlin
breaking change beyond the signature broadening; the destination
parameter is honored by toggling whether the file goes through MediaStore
(`saveToLibrary == true`, `albumName` ignored) vs. raw filesystem
(`saveToLibrary == false`).

**Dart:** `CambrianCamera.captureImage(...)` signature gains an optional
destination + returns the new shape. **This is a return-type breaking
change**, not a backward-compat parameter addition: the existing wire
contract returns non-null `String` (path); the new contract returns
`CamCaptureResult` whose `filePath` and `phAssetLocalId` are both
nullable. Every Dart caller (`then((path) => ...)` chains, await-assigned
variables) adapts to read `result.filePath ?? throw ...` (or
`result.phAssetLocalId`); every Android Kotlin caller adapts similarly.
The destination parameter being optional + defaulting to `null` only
preserves *callsite ergonomics* on the input side. Plan accounts for the
sweep of callers on both Dart and Android sides.

### §5.5 `SessionState.interrupted` (§2d.5)

**Pigeon:** `CamStateUpdate.state` continues to be a string. Add
`"interrupted"` to the documented set; do not turn it into an enum on
the wire (the existing shape is stringly-typed by deliberate choice —
not a Phase 3 reshape). Update the doc comment to list all 7 states.

**Android:** doc comment only — Android never emits `"interrupted"`
(it has no equivalent AVF route; lifecycle pauses are surfaced as the
existing `"paused"`).

**iOS adapter:** maps `SessionState.interrupted` → `"interrupted"` per
the §3 mapping table. The engine emits this on AVF `wasInterruptedNotification`
per D-2P-04.

### §5.6 Permission query/request host methods (§2d.6)

**Pigeon:** add:

```dart
abstract class CameraHostApi {
  // ... existing methods ...

  @async String cameraPermissionStatus();
  @async String requestCameraPermission();
  @async String photosAddPermissionStatus();
  @async String requestPhotosAddPermission();
}
```

Permission status as a string in the cross-platform contract:
`"notDetermined"`, `"denied"`, `"restricted"`, `"authorized"`. iOS's
`AVAuthorizationStatus` maps directly; Android's runtime permission
result maps `granted` → `"authorized"`, `denied` (with `shouldShowRequestPermissionRationale`)
→ `"denied"`, `denied` (don't ask again) → `"restricted"`.

**iOS adapter:** routes to `CameraEngine.cameraPermissionStatus()` /
`requestCameraPermission()` (`nonisolated static`; no engine required —
D-2P-06). Same for Photos add-only.

**Android:** new wiring in `CambrianCameraPlugin.kt` against
`ContextCompat.checkSelfPermission` + the runtime permission request
flow (the plugin already brokers this for the Camera permission inside
`open()` today; the new host methods make it explicit).

**Dart:** new optional API surface; existing `open()` continues to
implicit-request as it does today.

### §5.7 `streamPixelFormat` on `CamCapabilities` (§2d.7)

**Pigeon:** add `String streamPixelFormat;` to `CamCapabilities`. Document
the values: `"BGRA8"` (iOS default), `"RGBA16F"` (iOS opt-out via
`OpenConfiguration.lanesEightBit: false`), `"RGBA8"` (Android post-D-2P-09
swizzle).

**iOS adapter:** reads `SessionCapabilities.streamPixelFormat` (Phase 2
already exposes this; default `"BGRA8"` per D-2P-11) and passes through.

**Android:** populates the field at capability-build time. Per **D-2P-09**,
Android adapts its `GpuRenderer.cpp` output channel order to BGRA at the
`eglSwapBuffers` boundary so the wire format is **byte-identical** to iOS.
Android emits `"BGRA8"` after this change. (If a future Android build
choose to keep RGBA, the field becomes `"RGBA8"` and a Dart-side branch
unswizzles. Phase 3 design recommends Android matches iOS to make the
field a documentation surface rather than a runtime branch.)

**Dart:** no API change; the field is informational for any future
non-Texture-widget consumer that reads the buffer raw.

---

## §6. iOS-only calibration host methods — Option C, via separate Pigeon file

**D-2P-08** decided Option C: `calibrateWhiteBalance` / `calibrateBlackBalance`
appear on the Pigeon contract for **iOS only**; Android plugin does not
declare them; the existing Android Dart loop in
`cambrian_camera_controller.dart` continues to own the iterative
algorithm unchanged. D-2P-08's text appeals to "Pigeon supports
per-platform `@HostApi` method availability." Pigeon does not have a
*per-method* `@SwiftOnly` annotation — but it supports the same outcome
via **separate input files with per-file `@ConfigurePigeon` outputs**.

The canonical pattern lives in the Flutter Packages monorepo: the
`interactive_media_ads` plugin uses `pigeons/interactive_media_ads_ios.dart`
+ `pigeons/interactive_media_ads_android.dart` to emit fully-independent
per-platform Pigeon outputs. Phase 3 adopts the same pattern.

### §6.1 New file: `pigeons/camera_api_ios.dart`

```dart
import 'package:pigeon/pigeon.dart' show
    ConfigurePigeon, PigeonOptions, DartOptions, SwiftOptions,
    HostApi, async;

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages_ios.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Classes/Messages_ios.g.swift',
    swiftOptions: SwiftOptions(),
    // No kotlinOut — Android does not get this API at all.
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
@HostApi()
abstract class CameraIosHostApi {
  /// Runs the iOS engine's gray-world white-balance calibration to convergence.
  /// Wraps CameraEngine.calibrateWhiteBalance() — see DECISIONS D-2P-03/05/08.
  @async
  CamCalibrationResult calibrateWhiteBalance(int handle);

  /// Runs the iOS engine's black-balance calibration.
  /// Wraps CameraEngine.calibrateBlackBalance().
  @async
  CamCalibrationResult calibrateBlackBalance(int handle);
}

class CamCalibrationResult {
  CamCalibrationResult({
    required this.before,
    required this.after,
    required this.converged,
    required this.iterations,
  });
  CamRgbSample before;
  CamRgbSample after;
  bool converged;
  int iterations;
}
```

`CamRgbSample` already exists in `pigeons/camera_api.dart` — the iOS-only
file imports the shared Dart type from the generated `messages.g.dart`
in its `_ios` companion code path. Pigeon's per-file generation
duplicates the type's serialization code into `messages_ios.g.dart`, but
the public Dart class name aliases via re-export from
`lib/src/messages.g.dart` to keep callers using a single import surface.

### §6.2 Build command

The existing pubspec already declares `pigeon: ^22.0.0`. The Pigeon CLI
runs per input file:

```bash
dart run pigeon --input pigeons/camera_api.dart       # shared (Dart/iOS/Android)
dart run pigeon --input pigeons/camera_api_ios.dart   # iOS + Dart only
```

cam2fd's `CONTRIBUTING.md` (or equivalent build doc) gets both commands;
the plan that follows this spec wires them into whatever script the repo
uses for "regenerate pigeon" (today: manual invocation per file).

### §6.3 Plugin registration — `CameraIosHostApi`

`CambrianCameraPlugin.swift`'s `register(with registrar:)` registers
**both** host APIs:

```swift
CameraHostApiSetup.setUp(binaryMessenger: registrar.messenger(),
                        api: CameraHostApiImpl(...))
CameraIosHostApiSetup.setUp(binaryMessenger: registrar.messenger(),
                            api: CameraIosHostApiImpl(...))
```

`CameraIosHostApiImpl` is the thinnest possible adapter:

```swift
final class CameraIosHostApiImpl: CameraIosHostApi {
    let registry: HandleRegistry

    func calibrateWhiteBalance(handle: Int64,
                               completion: @escaping (Result<CamCalibrationResult, Error>) -> Void) {
        Task {
            do {
                let engine = try await registry.resolve(handle)
                let result = try await engine.calibrateWhiteBalance()
                completion(.success(.init(
                    before: .init(r: result.before.r, g: result.before.g, b: result.before.b),
                    after:  .init(r: result.after.r,  g: result.after.g,  b: result.after.b),
                    converged: result.converged,
                    iterations: Int64(result.iterations))))
            } catch {
                completion(.failure(PigeonError.fromSwiftError(error)))
            }
        }
    }
    // calibrateBlackBalance: structurally identical.
}
```

Concurrency contract per **D-2P-05**: the engine throws
`EngineError.calibrationInProgress` on `updateSettings`/`setResolution`
during calibration; the adapter forwards as `PigeonError(code:
"calibration_in_progress", ...)`. `Task.cancel()` aborts.

### §6.4 Android plugin — unchanged

`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`:
**no change.** The generated `Messages.g.kt` from
`pigeons/camera_api.dart` does not declare `calibrateWhiteBalance` /
`calibrateBlackBalance`; the Kotlin plugin therefore cannot accidentally
implement (or break) them.

`cambrian_camera_controller.dart`'s existing iterative
`calibrateWhiteBalance({...})` / `calibrateBlackBalance({...})` Dart
methods on the public `CambrianCamera` controller class continue to call
`sampleCenterPatch` + `updateSettings` in the Dart loop and gate on
`Platform.isAndroid`. **On iOS, the public Dart controller methods
dispatch to `CameraIosHostApi().calibrateWhiteBalance(handle)` instead.**
The public Dart surface remains a single
`controller.calibrateWhiteBalance()` call; the platform branch is
internal.

### §6.5 Why not the fallback shape

The advisor-suggested fallback ("declare on both, Android Kotlin throws
`FlutterError("not_implemented", ...)`") works and is conventional, but
violates D-2P-08's intent ("Android plugin does **NOT** declare the
methods"). The separate-pigeon-file path costs one extra `dart run
pigeon` invocation per regeneration and one extra Swift file in the
plugin; in exchange Android's `Messages.g.kt` is completely free of
iOS-only surface, the contract amendment is structural rather than
documented, and a future reviewer cannot accidentally invoke a stub.
Worth the trade.

If during implementation Pigeon's per-file output produces unexpected
Dart-side type collisions (e.g. duplicate `CamRgbSample` deserializers
between `messages.g.dart` and `messages_ios.g.dart`), the plan falls back
to **shared file + Android throws**:

```kotlin
// CambrianCameraPlugin.kt — added stubs:
override fun calibrateWhiteBalance(handle: Long,
                                   callback: (Result<CamCalibrationResult>) -> Unit) {
    callback(Result.failure(
        FlutterError("not_implemented",
                     "calibrateWhiteBalance is iOS-only; use the Dart loop on Android.",
                     null)))
}
```

The fallback adds ~4 lines of Kotlin. If invoked, the failure surfaces
to the Dart caller — but the public Dart API gates on `Platform.isIOS`
before calling, so the throw is unreachable in normal use. Choose the
fallback in implementation only if separate-file generation actually
mis-behaves on Pigeon 22.

---

## §7. Out of scope / non-goals

- **No CocoaPods build path for Phase 3 production.** The four-pod
  fallback documented at `measurements/cocoapods-cxx-spike/2026-05-15.md`
  stays available; Phase 3 ships SPM.
- **No multi-camera support.** One `CameraEngine` per `open(...)`. The
  handle abstraction is multi-engine-ready but the plan does not exercise
  it.
- **No Android calibration move-down.** Per D-2P-08, the Dart loop in
  `cambrian_camera_controller.dart` stays. Phase 3 does not touch
  Android calibration code beyond surfacing the iOS-only Dart branch
  (§6.4).
- **No Flutter raster-time signpost instrumentation.** §4's loaded-mode
  follow-up is recommended; the actual wiring lives in cam2fd's plan,
  not in this design.
- **No Mitigation-3 ring buffer pre-emptively.** Per the texture-bridge
  spike verdict.
- **No Mitigation-2 RGBA16F bridge path.** Pixel format is closed at
  BGRA8 wire.
- **No engine API surface change in cam2fd.** All Phase-3-mandated
  CameraEngine work happened in Phase 2. If anything is missing it is
  a Phase 2 bug to retro-fix in eva-swift-stitch, not a Phase 3 patch
  in cam2fd's `ios/CameraKit/` snapshot.
- **No removal of the `CocoaPods .podspec` from cam2fd.** Dual-mode
  tolerance per the SPM spike addendum 3 — leaving the podspec means
  consumers who haven't enabled SPM are still served.
- **No `captureNaturalPicture` algorithm change.** Phase 2 already
  shipped it (D-2P-10); Phase 3 only wires the Pigeon plumbing.
- **No `eva-swift-stitch` harness changes.** The harness keeps consuming
  CameraKit as a local SPM dep, unchanged. The Phase-3 work happens
  entirely in cam2fd, with at most a tag cut + push on the
  eva-swift-stitch side.
- **No bypass of the `pre-push` hook.** Every `eva-swift-stitch` push
  that touches `CameraKit/` regenerates `camerakit-only` automatically;
  the Phase-3 plan does not call `git push --no-verify`.

---

## §8. Verification

### §8.1 Build / packaging — cam2fd-side

- `flutter config --enable-swift-package-manager` once per developer
  workstation.
- `cd packages/cambrian_camera/example && flutter pub get` succeeds.
- `flutter build ios --debug --no-codesign` succeeds — runs the umbrella
  iOS-26 platform migration; subsequent builds skip it.
- DerivedData contains the expected per-target outputs (per the SPM
  spike's "Build-output receipts" section): `CameraKitCxx.o`,
  `CameraKitInterop.{o,swiftmodule}`, `CameraKit.{o,swiftmodule}`,
  `cambrian_camera.{o,swiftmodule}`,
  `cambrian_camera_CameraKit.bundle/default.metallib`,
  `FlutterGeneratedPluginSwiftPackage.{o,swiftmodule}`.
- `nm Runner.app/Runner.debug.dylib | grep CameraEngine` shows
  `CameraEngine` symbols linked into the final binary.

### §8.2 Pigeon contract — regenerated, no diff drift

- `dart run pigeon --input pigeons/camera_api.dart` produces the
  expected `lib/src/messages.g.dart`, `ios/Classes/Messages.g.swift`,
  `android/src/main/kotlin/.../Messages.g.kt` — no manual edits.
- `dart run pigeon --input pigeons/camera_api_ios.dart` produces
  `lib/src/messages_ios.g.dart` + `ios/Classes/Messages_ios.g.swift`
  only.
- A CI guard (or a `make pigeon-check` helper) regenerates both and
  asserts `git diff --exit-code` clean.

### §8.3 Unit tests — adapter layer

Phase 3 tests live in cam2fd's plugin test target
(`packages/cambrian_camera/example/ios/RunnerTests/` for iOS-native
adapter tests, `packages/cambrian_camera/test/` for Dart-side tests).
CLAUDE.md §8's dual-membership rule **does not apply** — these are
plugin tests, not CameraKit tests.

- **`HandleRegistry`** — register / resolve / unregister / not-found
  paths.
- **`PigeonValueMapping`** — every entry of the §3 mapping table has a
  round-trip test (Cam* → CameraKit → Cam* yields identity for valid
  inputs).
- **`FlutterApiPump`** — feeds a synthetic `AsyncStream` into the pump
  and asserts the matching `FlutterApi` callback fires on the main
  thread with the expected payload. One test per stream.
- **`CameraLaneBridge`** — synthetic IOSurface-backed `CVPixelBuffer`
  source + a stub `FlutterTextureRegistry` that records
  `textureFrameAvailable` calls; assert 1:1 frame ↔ nudge.
- **`CameraIosHostApiImpl` calibration adapter** — stub `CameraEngine`-shaped
  protocol; assert the result is shaped per `CamCalibrationResult` and
  errors propagate as `PigeonError(code: "calibration_in_progress",
  ...)`.

The full CameraKit test suite (141 tests pass as of Phase 2
verification, per `measurements/phase-2/verification.md`) continues to
run in **eva-swift-stitch**, not in cam2fd. cam2fd does not re-run
CameraKit tests against the subtreed snapshot — by design, the snapshot
is treated as a tagged release.

### §8.4 HITL — physical iPad, Phase 3 capture-list

Run a host app (the cam2fd `example/` Flutter app, with a Phase-3 demo
screen wired to every host method) on a connected iPad and verify each
of the following on device. Per CLAUDE.md §6 the device order is
**physical iPad → Mac "Designed for iPad" → error**; simulators are
disallowed.

| # | Scenario | Acceptance |
|---|---|---|
| 1 | `flutter run -d <udid>` cold launch | app starts, `cameraPermissionStatus()` returns `"notDetermined"`, `requestCameraPermission()` triggers prompt, status returns `"authorized"` |
| 2 | `open(null, settings)` with non-null `initialSettings` | first 2 frames already at requested ISO/exposure (no defaults-then-snap), `getCapabilities` populated, `streamPixelFormat == "BGRA8"`, both `naturalStreamTextureId` + `previewTextureId` non-zero |
| 3 | `Texture(textureId: previewTextureId)` widget displays processed lane | preview renders at 30 fps no tearing under bare load (run-1 baseline in the texture-bridge spike already verified this) |
| 4 | `updateSettings(...)` with manual ISO / exposure / WB | `onFrameResult` reports requested values within ~3 frames |
| 5 | `setResolution(handle, w, h)` for 4 sizes | each apply produces an `onStreamConfigurationChanged` with the new dims; preview swaps cleanly |
| 6 | `setCropRegion` set + clear | `onStreamConfigurationChanged` fires both times with the new `cropWidth/cropHeight` (or null on clear) |
| 7 | `captureImage(handle, dir, name, destination)` with `saveToLibrary: true` | result returns `phAssetLocalId`; image visible in Photos |
| 8 | `captureImage(handle, dir, name, destination)` with `saveToLibrary: false` | result returns `filePath`; file exists on disk |
| 9 | `captureNaturalPicture(...)` same matrix | same shape; HDR fidelity unchanged per `measurements/phase-3-prep/rgba8-conversion.md` precedent |
| 10 | `calibrateWhiteBalance(handle)` (iOS-only Pigeon path) | returns `CamCalibrationResult` with `before`/`after`, `converged: true`, `iterations: 1`; preview WB visibly adjusts |
| 11 | `calibrateBlackBalance(handle)` | returns shape; preview pedestal visibly adjusts |
| 12 | App background ↔ foreground | `onStateChanged` emits `"paused"` then `"streaming"`; preview resumes without rebuild |
| 13 | Control Center pull-down + restore | per Phase 2 verification, scenePhase route produces `"paused"`/`"streaming"`; AVF interruption path produces `"interrupted"` if a Stage-Manager peer claims the camera (deferred to opportunistic test) |
| 14 | `startRecording` / `stopRecording` | file path returned, file is valid HEVC MP4 |
| 15 | `getNativePipelineHandle(handle)` | returns non-null `Int64`; a Flutter-side FFI consumer registered against it observes the same frame sequence as the engine's tracker stream (mirror of Phase-1B's C-ABI parity probe — but Flutter-side rather than app-target) |
| 16 | `close(handle)` then `open(...)` | second open returns a different handle; texture IDs reissued; no leaks (`malloc_history` clean across two cycles) |
| 17 | Two concurrent `open(...)` from Dart | second call throws `open_in_flight`; first completes; subsequent `open` (after a `close`) succeeds |
| 18 | Hot restart (`r`) while preview is live | example app cleanly disposes texture IDs in Dart on hot-restart; first frame after restart shows new texture IDs (the old IDs are stale references — Flutter's iOS texture registry persists across hot restart, but the example app's Dart side must `unregister` + `registerTexture` on restart for the IDs to round-trip) |

### §8.5 Failure-mode rehearsal

- **Camera permission denied** in iOS Settings before `open` →
  `cameraPermissionStatus()` returns `"denied"`; `open` throws
  `permissionDenied`.
- **Camera in use by another app** → `open` (or the existing self-heal
  loop per Stage 9) emits the appropriate error code.
- **`updateSettings` during `calibrateWhiteBalance`** → throws
  `calibration_in_progress` per D-2P-05.
- **`setResolution` during calibration** → throws unconditionally per
  D-2P-05.
- **`close` during calibration** → calibration task cancels, WB
  restored to `.auto` per D-2P-05.

### §8.6 Loaded-mode regression check

Re-run the `measurements/texture-bridge/2026-05-15/` run-2 stressor
(continuous 5000-circle `CustomPainter`) inside the cam2fd example app
with the **real** CameraKit pipeline (not the synthetic source the
spike used) to confirm the loaded-mode jitter signature observed in the
spike is the floor (not amplified by real-pipeline contention).
Acceptance: `signal:pull` ratio ≥ 0.9 under the stressor on the iPad
Pro 11" 2nd-gen; if lower, raise the Flutter raster-time signpost work
to "must implement," not "recommended."

---

## §9. File inventory

### §9.1 In `eva-swift-stitch` (upstream — CameraKit producer)

**No source changes.** Phase 3 consumes Phase-2 artifacts as-is.

**Permanent additions:**
- A milestone tag at the moment Phase 3 cuts its first cam2fd snapshot:
  `vX.Y.Z` on `main` + `camerakit-vX.Y.Z` on `camerakit-only`. CLAUDE.md
  §10 documents the exact commands.

**No changes to:**
- `CameraKit/Sources/`, `CameraKit/Tests/`, `CameraKit/Package.swift`,
  `CameraKit/CONTRACTS.md`, `CameraKit/DECISIONS.md`, `CameraKit/state.md`,
  `CLAUDE.md`, `.githooks/pre-push`.

### §9.2 In `camera2_flutter_demo` (the Flutter consumer — Phase 3 happens here)

**New:**

- `packages/cambrian_camera/ios/CameraKit/` — git subtree from
  `camerakit-only` at `camerakit-vX.Y.Z`. Entire directory; ~50 source
  files. Not hand-edited.
- `packages/cambrian_camera/ios/cambrian_camera/Package.swift` — SPM
  Flutter-plugin package per §2.
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift`
  — registrar + lifecycle observer. **Replaces** the existing no-op
  stub at `packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift`.
- `…/Sources/cambrian_camera/CameraHostApiImpl.swift` — shared host API
  impl.
- `…/Sources/cambrian_camera/CameraIosHostApiImpl.swift` — iOS-only host
  API impl (calibration).
- `…/Sources/cambrian_camera/HandleRegistry.swift`
- `…/Sources/cambrian_camera/FlutterApiPump.swift`
- `…/Sources/cambrian_camera/CameraLaneTexture.swift` +
  `CameraLaneBridge.swift`
- `…/Sources/cambrian_camera/PigeonValueMapping.swift`
- `packages/cambrian_camera/pigeons/camera_api_ios.dart` — new iOS-only
  Pigeon input file per §6.
- `packages/cambrian_camera/ios/Classes/Messages_ios.g.swift` —
  Pigeon-generated; lives under the existing `Classes/` directory so the
  `.podspec` fallback path picks it up too. (The SPM build references it
  via `cambrian_camera`'s target sources; the podspec's
  `s.source_files = 'Classes/**/*'` glob covers it.)
- `packages/cambrian_camera/lib/src/messages_ios.g.dart` —
  Pigeon-generated Dart side.
- `packages/cambrian_camera/example/ios/RunnerTests/*.swift` — adapter
  unit tests per §8.3.
- `packages/cambrian_camera/test/*` — Dart-side adapter tests.

**Modified:**

- `packages/cambrian_camera/pigeons/camera_api.dart` — applies the §5
  amendments (rename rawStream*, replace `onCapabilitiesChanged`, add
  permission methods, add `streamPixelFormat`, broaden capture
  signatures + return shape, add `"interrupted"` to the doc set).
- `packages/cambrian_camera/lib/src/messages.g.dart`,
  `packages/cambrian_camera/ios/Classes/Messages.g.swift`,
  `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`
  — regenerated by `dart run pigeon`.
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`
  — applies §5 amendments on the Android side: renames `rawStream*`
  fields, rewires `onCapabilitiesChanged` emit sites to
  `onStreamConfigurationChanged`, adds the new permission methods, adds
  `streamPixelFormat` to capability build. **Does not** declare
  calibration methods (§6.4).
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`
  + `GpuRenderer.cpp` — same renames, BGRA8 swizzle per D-2P-09.
- `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` —
  uses renamed types; the public Dart `calibrateWhiteBalance` /
  `calibrateBlackBalance` methods branch on `Platform.isIOS` → dispatch
  to `CameraIosHostApi()`; Android path unchanged. Handles the new
  capture-result shape.
- `packages/cambrian_camera/lib/src/camera_settings.dart` and adjacent
  Dart value types — Dart-side mirror of the renamed Pigeon fields.
- `packages/cambrian_camera/ios/cambrian_camera.podspec` — `platform`
  bumped to `:ios, '26.0'`; doc comment updated to point at the SPM
  path as canonical.
- `packages/cambrian_camera/example/ios/Runner.xcodeproj` / Podfile /
  `Package.resolved` — SPM enablement + iOS-26 deployment-target bump.
- `packages/cambrian_camera/README.md` — adoption section: SPM
  enablement, `flutter build` migration step, subtree update flow.

**Deleted:**

- `packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift` —
  the no-op stub. Replaced by the SPM-package-resident plugin per §2.
  (The podspec fallback path serves the same file from the new SPM
  location via `s.source_files` if needed.)

---

## §10. Open questions — pinned for the plan

1. **Single Pigeon-input file vs. separate-files for iOS-only.** §6's
   primary path is the separate-file pattern (canonical per
   `interactive_media_ads`). If Pigeon 22's per-file output produces
   duplicate-symbol issues for shared types (`CamRgbSample`), the plan
   falls back to single-file + Android Kotlin stub-throws (§6.5). The
   spec commits to separate-files; the plan exercises the first
   regenerate and confirms before writing the impl.
2. **PHAsset identifier flow back through Pigeon — null vs. empty
   string.** Pigeon's nullable strings serialize cleanly across both
   Swift and Kotlin runtimes; the plan double-checks generated code on
   both sides because the existing contract uses non-null `String`
   returns for capture paths and the rewrite introduces nullable.
3. **`previewTextureId` field on `CamStreamConfiguration` vs. on
   `CamCapabilities` alone.** §4 puts both `naturalTextureId` and
   `previewTextureId` on `CamStreamConfiguration` so a callback consumer
   never needs a `getCapabilities` round-trip. The plan may discover
   that one of the two is sufficient (Android's design carries only
   `previewTextureId` historically). If so, drop `naturalTextureId`
   from `CamStreamConfiguration` and keep it only on `CamCapabilities`.
4. **Tag granularity for the first subtree pull.** Phase 3's plan picks
   between (a) the current `main` tip tagged as `v1.0.0` at the moment
   Phase 3 starts, or (b) waiting for the Phase-3 spec → plan → code
   loop to settle on the producer side and tagging the loop's
   stabilization point as `v1.0.0`. Recommendation: (a) — Phase 2 is
   stable as of `measurements/phase-2/verification.md` 2026-05-15; tag
   now, iterate cam2fd separately.
5. **Loaded-mode regression threshold.** §8.6 picks `signal:pull ≥ 0.9`
   as the on-device floor under the synthetic stressor. The plan
   verifies this against the real cam2fd UI surface; if real UI
   produces materially different raster load, adjust the threshold or
   the stressor.
6. **`flutter run -d <udid>` device-only invariant.** CLAUDE.md §6
   forbids iOS simulators on this machine. `flutter run -d <udid>`
   honors that as long as the user picks the iPad UDID; the plan
   should call out the "two iPads, two UDID schemes" rule (CLAUDE.md
   §8) explicitly so the developer running the HITL doesn't
   misidentify.
7. **What to do when an existing pub.dev plugin in the cam2fd app drags
   in a CocoaPods-only plugin.** The SPM spike Caveat 3 verified
   dual-mode works automatically; the plan should still inventory the
   dep tree before adoption so any surprising plugin is surfaced before
   `flutter build` discovers it for us.
8. **Example app `Info.plist` privacy strings.** The cam2fd example app
   (`packages/cambrian_camera/example/ios/Runner/Info.plist`) needs
   `NSCameraUsageDescription` (already required for the existing stub,
   may already be present) and **`NSPhotoLibraryAddUsageDescription`**
   (new requirement from §5.4's `saveToLibrary` path). eva-swift-stitch
   carries these as `INFOPLIST_KEY_*` build settings (CLAUDE.md §5);
   cam2fd's example may use a source `Info.plist`. Note: Xcode silently
   drops some `INFOPLIST_KEY_*` keys (e.g. `UIFileSharingEnabled` does
   not synthesize) — for `NSPhotoLibraryAddUsageDescription` the plan
   should `PlistBuddy`-verify the value lands in the built `.app`'s
   `Info.plist` whichever route it takes, especially if the build
   setting route is chosen.
9. **Hot-restart texture-id staleness.** Flutter's iOS texture registry
   persists across hot-restart; the Dart-side `textureId` values
   captured by the example app's widget tree do not. HITL case 18
   exercises this. The plan should confirm whether the cam2fd example
   needs an explicit `if (kDebugMode) reregister()` flow on hot
   restart, or whether the plugin itself should `unregister` all
   textures in `detachFromEngine(for:)` so the Dart side rebuilds
   cleanly. Default position: plugin's `detachFromEngine` releases the
   registry IDs; example app's controller seam re-opens on first frame
   request.

---

## §11. Working principles

- **Engine surface is contractually closed for Phase 3.** Any
  "I need one more thing from `CameraEngine`" discovery routes back
  through an eva-swift-stitch source change + tag bump, not a cam2fd-side
  patch. The subtreed snapshot is a release artifact.
- **The Pigeon contract is closed for Phase 3 after the §5 + §6
  amendments land.** Anything else surfaces as an open question for a
  future phase, not a mid-implementation contract bump.
- **Adapter code is mechanical translation, not semantic invention.**
  When a Pigeon field's meaning is unclear, the answer is in the Pigeon
  doc comment or in the engine method's doc comment — not in adapter
  improv. If both are unclear, escalate to a contract amendment.
- **Verify, do not assume, Pigeon's per-platform behavior.** §6's
  separate-file path is documented in the Flutter Packages monorepo's
  `interactive_media_ads` plugin, but Pigeon 22's exact behavior under
  this pattern is not in the public README. The plan's first
  regeneration step is a load-bearing check; treat its output as
  ground truth.
