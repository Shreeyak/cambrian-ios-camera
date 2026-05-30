# cambrian-ios-camera

iOS camera library, shipped as **both a Swift package and a Flutter plugin** from a single repo.

> **Two-personality repo.** The same source ships under two consumer APIs:
> - Swift apps depend on the `CameraKit` Swift package at the repo root (via SPM).
> - Flutter apps depend on the `cambrian_ios_camera` Flutter plugin under `flutter/` (via pub `git: + path: flutter`).
>
> They share underlying code; you don't pick one. If you write Swift, use SPM. If you write Flutter, use the plugin.
> **No Android support** in this repo — for Android camera in Flutter, use [cam2fd's `cambrian_camera`](https://github.com/.../camera2_flutter_demo) as a separate dependency.

## For Swift apps — consume via SPM

Add to your `Package.swift`:

```swift
let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.0.0"),
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

Or in Xcode: File → Add Package Dependencies → paste `https://github.com/Shreeyak/cambrian-ios-camera.git` → choose a version.

Then in your Swift code:

```swift
import CameraKit
let engine = try await CameraEngine(...)
```

> The package's internal name is `CameraKit` for historical reasons. It will be renamed to `CambrianCamera` in a future pass to avoid collision with [Snap's CameraKit SDK](https://docs.snap.com/camera-kit/) — see `docs/archived/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` §"Future cleanup".

## For Flutter apps — consume via pub `git: + path: flutter`

The Flutter plugin lives under the `flutter/` subdirectory, not at the repo root. Pub supports this via the `path:` parameter inside a `git:` dependency:

```yaml
# In your Flutter app's pubspec.yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter        # ← important: plugin is at flutter/, not the repo root
      ref: main            # ← the plugin lives on main, so this always resolves
      # ref: v1.2.0        # ← or pin a fixed version instead. The tag must be cut
      #                       from main (the old v1.0.0/v1.0.1 tags predate the
      #                       Flutter plugin and won't resolve it).
```

Then run `flutter pub get` and import in Dart:

```dart
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

final engine = await CameraEngine.open(...);
```

**For Android camera in the same app:** add `cambrian_camera` (cam2fd's Android-only plugin) as a separate dependency. Both plugins maintain similar API surfaces by convention, so platform-conditional code in Dart is straightforward. Phase B (the plugin implementation itself) is complete and shipped — design docs are archived under `docs/archived/superpowers/specs/`.

## Versioning

A single git tag `vX.Y.Z` drives **both** consumers — the SPM `from:`/`exact:` resolution and the Flutter `ref:` point at the same tag. SemVer applies across the combined surface: a breaking change to either the Swift `CameraKit` API or the Dart `cambrian_ios_camera` API bumps the major. `main` is for development; always pin a tag.

## Two example apps in this repo

| Path | What it is | Use it when |
|---|---|---|
| `ios_example_app/` | Native SwiftUI app. Imports `CameraKit` directly via the local SPM package. Demonstrates camera lanes, processing, and Canny edge detection (via the OpenCV consumer in `ios_example_app/ios_example_app/AppCxx/`). The primary dev harness for CameraKit work. | You're developing CameraKit itself, or want a full-featured iOS-native demo. |
| `flutter/example/` | Standard Flutter plugin example. Lean — shows one preview stream (the processed lane, after CameraKit's Metal shader passes). No OpenCV, no C++ consumer in the Flutter side. | You're developing the `cambrian_ios_camera` plugin, or want a minimal Flutter consumer demo. |

Neither CameraKit (the Swift package) nor `cambrian_ios_camera` (the Flutter plugin) link OpenCV. OpenCV is a consumer-side dep — `ios_example_app/` brings it in for the Canny demo; downstream consumers bring their own if they need it.

## Development

See `CLAUDE.md` for project conventions (build/test commands, scaffold discipline, test-on-iPad invariants, the `xcode-build-server` LSP bridge setup, etc.).
