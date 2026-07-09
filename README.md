# cambrian-ios-camera

iOS camera library, shipped as **both a Swift package and a Flutter plugin** from a single repo.

> **Two-personality repo.** The same source ships under two consumer APIs:
> - Swift apps depend on the `CameraKit` Swift package at the repo root (via SPM).
> - Flutter apps depend on the `cambrian_ios_camera` Flutter plugin under `flutter/` (via pub `git: + path: flutter`).
>
> They share underlying code; you don't pick one. If you write Swift, use SPM. If you write Flutter, use the plugin.
> **No Android support** in this repo — for Android camera in Flutter, use [cam2fd's `cambrian_camera`](https://github.com/.../camera2_flutter_demo) as a separate dependency.

📖 **Swift / CameraKit API documentation:** [`Documentation/index.md`](Documentation/index.md) — guides plus a generated per-symbol API reference.

## For Swift apps — consume via SPM

Add to your `Package.swift`:

```swift
let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        // `from:` is a floor that floats up within the major — see Releases for the latest.
        .package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "CameraKit", package: "cambrian-ios-camera"),
            ]
        ),
    ]
)
```

Or in Xcode: File → Add Package Dependencies → paste `https://github.com/Shreeyak/cambrian-ios-camera.git` → choose **Up to Next Major Version**.

The [Releases page](https://github.com/Shreeyak/cambrian-ios-camera/releases) is the source of truth for the current `vX.Y.Z`; you don't need to hardcode it here — `from:` above resolves to the newest compatible version within the same major.

Then in your Swift code:

```swift
import CameraKit

let engine = CameraEngine(initialPhase: .background)
let caps = try await engine.open()
```

### Setting up the camera (resolution + frame rate)

`open()` returns a `SessionCapabilities` describing exactly what the device supports.
Read it to choose a valid `(resolution, frame rate)`, then reopen with an
`OpenConfiguration` — resolution and frame rate are **independent**:

```swift
import CameraKit

let engine = CameraEngine(initialPhase: .active)

// 1. Open with defaults to discover capabilities.
//    Defaults: the largest 4:3 capture resolution, 30 fps, always full-range 420f,
//    HDR off. `activeFrameRate` is the rate the session is locked to.
let caps = try await engine.open()

// 2. Inspect the valid config space (all live device data, including slow-mo).
for r in caps.supportedFrameRates {
    print("\(r.size.width)×\(r.size.height): \(r.minFps)–\(r.maxFps) fps")
}
// caps.exposureDurationRangeNs is already bounded by the active frame rate:
// max exposure = min(sensorMax, 1/activeFrameRate) — 33 ms at 30 fps, 16.6 ms at 60.

// 3. Reopen at a chosen resolution + frame rate. An unsupported (resolution, fps)
//    pair throws EngineError.settingsConflict naming the valid rates — it is never
//    silently coerced. A longer exposure than 1/targetFps also throws; open at a
//    lower targetFps for long exposures.
await engine.close()
let hi = try await engine.open(configuration: OpenConfiguration(
    captureResolution: Size(width: 1920, height: 1440),  // must be in caps.supportedSizes
    targetFps: 60                                         // must be valid at that size
))
```

The frame rate is **locked** in every mode (preview, still, recording); the demo app's
bottom bar exposes a resolution picker and an fps picker (15/30/60, filtered to what the
active resolution supports).

**Flutter:** the same fields are on the Pigeon `OpenConfiguration.targetFps` and
`SessionCapabilities` (`activeFrameRate`, `supportedFrameRates`) — read the capabilities,
pick a valid pair, and `open(OpenConfiguration(captureResolution: …, targetFps: …))`.

See [`Documentation/index.md`](Documentation/index.md) for the full API, the lifecycle contract, and end-to-end guides.

### Frame streams survive automatic recovery

When CameraKit hits a recoverable fault it restarts the capture session
internally (bounded, escalating: quick reopens → full restarts → a terminal
fatal). **These restarts are transparent to frame consumers.** A subscribed lane
(`subscribe(stream:)`, the Flutter texture preview, EvaScan) is *not* finished or
thrown during a restart — the subscriber simply sees a brief frame gap and then
resumes from the rebuilt pipeline. A lane stream ends **only** when you call
`close()` (clean finish) or when recovery is exhausted and CameraKit gives up
(the stream throws the terminal fatal). Internally this holds because a restart
skips `ConsumerRegistry.release()` / `failAllLanes()`; the registry is
engine-owned and re-wired to each rebuilt pipeline. So a consumer's
`for try await frame in engine.subscribe(...)` loop keeps running across restarts
and only exits on `close()` or an unrecoverable fault.

> The package's internal name is `CameraKit` for historical reasons. It will be renamed to `CambrianCamera` in a future pass to avoid collision with [Snap's CameraKit SDK](https://docs.snap.com/camera-kit/) — see `docs/archived/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` §"Future cleanup".

## Documentation (Swift / CameraKit)

The consumer documentation lives in **[`Documentation/`](Documentation/index.md)** — guides
(getting started, lifecycle, preview, capture, controlling the camera, processing, calibration,
state/errors, advanced consumers) plus a generated per-symbol API reference. Start at
[`Documentation/index.md`](Documentation/index.md).

> `Documentation/` is for consumers of the package. The lowercase `docs/` tree is
> development-internal (design notes, ADRs) and is not consumer documentation.

## For Flutter apps — consume via pub `git: + path: flutter`

The Flutter plugin lives under the `flutter/` subdirectory, not at the repo root. Pub supports this via the `path:` parameter inside a `git:` dependency:

```yaml
# In your Flutter app's pubspec.yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter        # ← important: plugin is at flutter/, not the repo root
      ref: main            # ← the plugin lives on main, so this always tracks the latest
      # ref: vX.Y.Z        # ← or pin a specific release instead — see the Releases page
      #                       for the current tag (any tag from v1.2.0 onward resolves
      #                       the Flutter plugin; the older v1.0.x tags predate it).
```

Then run `flutter pub get` and import in Dart:

```dart
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

final engine = CameraEngine();
await engine.open();
```

**For Android camera in the same app:** add `cambrian_camera` (cam2fd's Android-only plugin) as a separate dependency. Both plugins maintain similar API surfaces by convention, so platform-conditional code in Dart is straightforward. Phase B (the plugin implementation itself) is complete and shipped — design docs are archived under `docs/archived/superpowers/specs/`.

## Versioning

A single git tag `vX.Y.Z` drives **both** consumers — the SPM `from:`/`exact:` resolution and the Flutter `ref:` point at the same tag. SemVer applies across the combined surface: a breaking change to either the Swift `CameraKit` API or the Dart `cambrian_ios_camera` API bumps the major. `main` is for development; always pin a tag. The [Releases page](https://github.com/Shreeyak/cambrian-ios-camera/releases) lists every `vX.Y.Z` and is the source of truth for the latest — this README deliberately avoids hardcoding a current version number so it can't go stale.

## Two example apps in this repo

| Path | What it is | Use it when |
|---|---|---|
| `ios_example_app/` | Native SwiftUI app. Imports `CameraKit` directly via the local SPM package. Demonstrates camera lanes, processing, and Canny edge detection (via the OpenCV consumer in `ios_example_app/ios_example_app/AppCxx/`). The primary dev harness for CameraKit work. | You're developing CameraKit itself, or want a full-featured iOS-native demo. |
| `flutter/example/` | Standard Flutter plugin example. Lean — shows one preview stream (the processed lane, after CameraKit's Metal shader passes). No OpenCV, no C++ consumer in the Flutter side. | You're developing the `cambrian_ios_camera` plugin, or want a minimal Flutter consumer demo. |

Neither CameraKit (the Swift package) nor `cambrian_ios_camera` (the Flutter plugin) link OpenCV. OpenCV is a consumer-side dep — `ios_example_app/` brings it in for the Canny demo; downstream consumers bring their own if they need it.

## Development

See `CLAUDE.md` for project conventions (build/test commands, scaffold discipline, test-on-iPad invariants, the `xcode-build-server` LSP bridge setup, etc.).
