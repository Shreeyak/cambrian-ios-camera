# Flutter Plugin Phase B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `cambrian_ios_camera` v1.0.0 — a Flutter plugin wrapping CameraKit, with full Phase 2 surface parity, iOS-only, joint-versioned via a single git tag.

**Architecture:** Four layers — Dart facade (`flutter/lib/`) → Pigeon HostApi + EventChannelApi → Swift adapter (`flutter/ios/cambrian_ios_camera/Sources/`) → CameraKit (unchanged Swift package at repo root). The plugin lives at `flutter/`; the adapter holds a singleton `CameraEngine` and observes UIScene lifecycle natively. Dart has no lifecycle surface.

**Tech Stack:** Flutter (Dart 3.4+), Pigeon ^22.6.0 (DSL → Dart + Swift + Kotlin bindings), Swift 6 / iOS 26, mockito + build_runner for Dart mocks, XCTest for Swift adapter, Flutter integration_test for end-to-end.

**Spec:** `docs/superpowers/specs/2026-05-22-flutter-plugin-phase-b-design.md` — read this first. Every task here implements a part of that spec.

**Working directory:** This worktree at `/Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/flutter-monorepo-restructure/`. All paths below are relative to the repo root inside this worktree.

**Build/test discipline:** Per `CLAUDE.md` — XcodeBuildMCP for device builds/tests; no simulators; `swift-format --strict` is the commit gate; physical iPad UDID via `xcrun xctrace list devices`. Flutter tooling (`flutter`, `dart`) is invoked at the shell.

**Note on TDD ordering:** The Dart facade follows strict TDD (test → fail → impl → pass). The iOS adapter mostly does not — it's a pure-translation layer that XCTest covers only at its stateful seams (scene callbacks, texture map). Pigeon-generated code is never tested directly — we test our use of it.

---

## File structure overview

| Path | Owner | Purpose |
|---|---|---|
| `CameraKit/Sources/CameraKit/CameraEngineProtocol.swift` | Task 1 | Protocol the adapter mocks against |
| `flutter/pubspec.yaml` | Task 2 | Plugin pub spec |
| `flutter/pigeons/cambrian_ios_camera_api.dart` | Task 3, 4 | Pigeon DSL |
| `flutter/lib/src/pigeon/cambrian_ios_camera_api.g.dart` | Task 5 | Generated Dart bindings (committed) |
| `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift` | Task 5 | Generated Swift bindings (committed) |
| `flutter/android/src/main/kotlin/.../cambrian_ios_camera_api.g.kt` | Task 5 | Generated Kotlin bindings (committed) |
| `flutter/ios/cambrian_ios_camera/Package.swift` | Task 2 | SPM manifest, depends on `../../..` |
| `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CambrianIosCameraPlugin.swift` | Task 6 | Plugin registration + scene callbacks |
| `.../Sources/cambrian_ios_camera/ValueTypeMappers.swift` | Task 7 | Pigeon ↔ CameraKit value type conversions |
| `.../Sources/cambrian_ios_camera/CameraEngineHostApiImpl.swift` | Task 8 | HostApi method bodies |
| `.../Sources/cambrian_ios_camera/PermissionsHostApiImpl.swift` | Task 9 | Static permissions bridge |
| `.../Sources/cambrian_ios_camera/TextureBridge.swift` | Task 10 | FlutterTexture lifecycle |
| `.../Sources/cambrian_ios_camera/StreamForwarding.swift` | Task 11 | Engine AsyncStream → EventChannelApi |
| `flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/CambrianIosCameraPlugin.kt` | Task 12 | iOSOnly throwing stub |
| `flutter/lib/src/camera_exception.dart` | Task 13 | Typed exception + code enum |
| `flutter/lib/src/permissions.dart` | Task 14 | Static Permissions class |
| `flutter/lib/testing.dart` | Task 15 | Opt-in mocking export |
| `flutter/lib/src/camera_engine.dart` | Tasks 16-22 | CameraEngine class (built incrementally) |
| `flutter/lib/cambrian_ios_camera.dart` | Task 23 | Public re-exports |
| `flutter/example/ios/RunnerTests/*.swift` | Tasks 24-27 | Swift adapter XCTest |
| `flutter/example/{lib,ios,android,test,integration_test}/*` | Tasks 28-37, 38-41 | Example app + integration tests |
| `flutter/example/scripts/*.sh` | Task 42, 43 | Test wrappers |
| `scripts/test-phase-b.sh` | Task 44 | Consolidated runner |
| `scripts/release-gate.sh` | Task 45 | 7-check gate from spec §8 |
| `README.md` | Task 46 | v1.0.0 consumer recipes |
| `CameraKit/state.md` | Task 47 | Phase B completion entry |
| `docs/release-notes-v1.0.0.md` | Task 48 | GitHub release body |

---

## Phase 1: Foundation

### Task 1: Extract `CameraEngineProtocol` in CameraKit

The adapter's XCTest unit tests need to mock CameraKit's `CameraEngine`. CameraKit currently exposes a concrete `actor CameraEngine`; we add a `Sendable` protocol that mirrors every public method the adapter calls. The actor conforms automatically.

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraEngineProtocol.swift`
- Test: `CameraKit/Tests/CameraKitTests/CameraEngineProtocolConformanceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CameraKit/Tests/CameraKitTests/CameraEngineProtocolConformanceTests.swift`:

```swift
import Testing
@testable import CameraKit

/// Proves `CameraEngine` satisfies `CameraEngineProtocol` for every public
/// method the Flutter adapter calls. If a new method is added to the protocol,
/// this fails to compile until the engine implements it.
@Suite("CameraEngineProtocol conformance")
struct CameraEngineProtocolConformanceTests {
    @Test("CameraEngine conforms to CameraEngineProtocol")
    func conformance() {
        // Compile-time check: assigning a concrete instance to the protocol
        // type fails to build if any required member is missing.
        let _: any CameraEngineProtocol = CameraEngine(initialPhase: .background)
    }
}
```

- [ ] **Step 2: Wire the test into the Xcode test target**

Run: `scripts/sync-test-target.sh`
Expected: prints `Added CameraEngineProtocolConformanceTests.swift to ios_example_appTests`.

- [ ] **Step 3: Run test and verify it fails**

Use XcodeBuildMCP (the wrappers are fallback):
```
mcp__XcodeBuildMCP__test_device with extraArgs: ["-only-testing:ios_example_appTests/CameraEngineProtocolConformanceTests"]
```
Expected: BUILD FAILED — `cannot find type 'CameraEngineProtocol' in scope`.

- [ ] **Step 4: Write the protocol**

Create `CameraKit/Sources/CameraKit/CameraEngineProtocol.swift`:

```swift
import Foundation

/// Public surface of `CameraEngine` that the Flutter iOS adapter consumes.
///
/// Mirrors every public method the adapter calls. `CameraEngine` (an `actor`)
/// conforms automatically via member parity. Adapter unit tests
/// (`flutter/example/ios/RunnerTests/`) mock against this protocol.
///
/// Not for general public consumption — most call sites should hold a concrete
/// `CameraEngine`. The protocol exists for testability.
public protocol CameraEngineProtocol: Actor {
    // Lifecycle
    func setLifecyclePhase(_ phase: AppLifecyclePhase) async
    func open(configuration: OpenConfiguration) async throws -> SessionCapabilities
    func close() async

    // Snapshots
    func currentSettingsSnapshot() -> CameraSettings?
    func currentProcessingParametersSnapshot() -> ProcessingParameters?

    // Streams
    func stateStream() -> AsyncStream<SessionState>
    func errorStream() -> AsyncStream<CameraError>
    func streamConfigurationStream() -> AsyncStream<StreamConfiguration>
    func frameResultStream() -> AsyncStream<FrameResult>
    func recordingStateStream() -> AsyncStream<RecordingState>

    // Control
    func updateSettings(_ settings: CameraSettings) async throws
    func setResolution(size: Size) async throws
    func setProcessingParams(_ params: ProcessingParameters) async
    func setCropRegion(_ rect: Rect) async throws

    // Capture
    func captureImage(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput
    func captureNaturalPicture(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput

    // Recording
    func startRecording(options: RecordingOptions) async throws -> RecordingStart
    func stopRecording() async throws -> String

    // Calibration
    func calibrateWhiteBalance() async throws -> CalibrationResult
    func calibrateBlackBalance() async throws -> CalibrationResult

    // Texture bridge
    nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer?

    // Frame subscription
    nonisolated var consumers: ConsumerRegistry { get }
}

extension CameraEngine: CameraEngineProtocol {}
```

> **Note:** If a method signature in `CameraEngine.swift` differs from what the protocol expects, the `extension CameraEngine: CameraEngineProtocol {}` line fails to compile. Read `CameraKit/CONTRACTS.md` for the canonical public surface before writing this file; cross-check `captureImage` / `captureNaturalPicture` argument labels (they take `outputURL: URL?` and `photosDestination: PhotosDestination` per the source).

- [ ] **Step 5: Run test and verify it passes**

Run the same MCP test_device command from Step 3.
Expected: PASS.

- [ ] **Step 6: Regenerate CONTRACTS.md**

Run: `scripts/regen-contracts.sh`
Expected: `CameraKit/CONTRACTS.md` shows the new `CameraEngineProtocol`.

- [ ] **Step 7: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngineProtocol.swift \
        CameraKit/Tests/CameraKitTests/CameraEngineProtocolConformanceTests.swift \
        CameraKit/CONTRACTS.md \
        ios_example_app/ios_example_app.xcodeproj/project.pbxproj
git commit -m "feat(camerakit): extract CameraEngineProtocol for adapter testability

Adds a Sendable actor protocol that mirrors every public method the
Flutter iOS adapter calls into. CameraEngine conforms automatically via
member parity. The protocol exists so flutter/example/ios/RunnerTests/
can mock the engine for adapter unit tests (Phase B §7).

A new compile-time test in CameraEngineProtocolConformanceTests.swift
asserts the conformance — if a protocol method drifts from the engine's
signature the test fails to build."
```

---

### Task 2: Create plugin skeleton — `flutter/` pubspec + SPM manifests

Scaffolds the plugin directory so subsequent tasks have a real package to add files into. No code yet — just `pubspec.yaml`, the iOS-side `Package.swift`, and empty source directories.

**Files:**
- Modify: `flutter/README.md` (replace placeholder)
- Create: `flutter/pubspec.yaml`
- Create: `flutter/ios/cambrian_ios_camera/Package.swift`
- Create: `flutter/ios/cambrian_ios_camera.podspec`
- Create: `flutter/.gitignore`

- [ ] **Step 1: Write `flutter/pubspec.yaml`**

```yaml
name: cambrian_ios_camera
description: Flutter plugin wrapping CameraKit for iOS-only camera access.
version: 1.0.0
homepage: https://github.com/Shreeyak/cambrian-ios-camera
repository: https://github.com/Shreeyak/cambrian-ios-camera
issue_tracker: https://github.com/Shreeyak/cambrian-ios-camera/issues
publish_to: 'none'

environment:
  sdk: '>=3.4.0 <4.0.0'
  flutter: '>=3.22.0'

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  pigeon: ^22.6.0
  mockito: ^5.4.4
  build_runner: ^2.4.13

flutter:
  plugin:
    platforms:
      ios:
        pluginClass: CambrianIosCameraPlugin
        sharedDarwinSource: false
      android:
        package: com.cambrian.cambrian_ios_camera
        pluginClass: CambrianIosCameraPlugin
```

- [ ] **Step 2: Write `flutter/ios/cambrian_ios_camera/Package.swift`**

The plugin's iOS SPM manifest references the repo-root CameraKit Package at `../../..`. This is a sibling-of-`flutter/` path: from `flutter/ios/cambrian_ios_camera/`, `..` is `flutter/ios/`, `../..` is `flutter/`, `../../..` is the repo root.

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cambrian_ios_camera",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "cambrian-ios-camera", targets: ["cambrian_ios_camera"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .target(
            name: "cambrian_ios_camera",
            dependencies: [
                .product(name: "CameraKit", package: "cambrian-ios-camera"),
            ],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
    ]
)
```

- [ ] **Step 3: Write `flutter/ios/cambrian_ios_camera.podspec`**

Flutter's iOS plugin layer still uses CocoaPods for the build wiring even when the plugin's own source is SPM. The podspec is minimal:

```ruby
Pod::Spec.new do |s|
  s.name             = 'cambrian_ios_camera'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin wrapping CameraKit for iOS-only camera access.'
  s.description      = s.summary
  s.homepage         = 'https://github.com/Shreeyak/cambrian-ios-camera'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Cambrian' => 'noreply@cambrian.dev' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '26.0'
  s.swift_version    = '6.0'
  s.dependency 'Flutter'
  s.source_files     = 'cambrian_ios_camera/Sources/cambrian_ios_camera/**/*.swift'
  s.resource_bundles = { 'cambrian_ios_camera_privacy' => ['cambrian_ios_camera/Sources/cambrian_ios_camera/Resources/PrivacyInfo.xcprivacy'] }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
```

- [ ] **Step 4: Create directory placeholders + `.gitignore`**

```bash
mkdir -p flutter/lib/src/pigeon
mkdir -p flutter/pigeons
mkdir -p flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon
mkdir -p flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Resources
mkdir -p flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera
mkdir -p flutter/test
touch flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Resources/PrivacyInfo.xcprivacy
```

Write `flutter/.gitignore`:

```gitignore
.dart_tool/
.flutter-plugins
.flutter-plugins-dependencies
.packages
.pub-cache/
.pub/
build/
ios/.symlinks/
ios/Flutter/Generated.xcconfig
ios/Flutter/flutter_export_environment.sh
ios/Pods/
example/ios/.symlinks/
example/ios/Pods/
example/ios/Flutter/Generated.xcconfig
example/ios/Flutter/flutter_export_environment.sh
example/.dart_tool/
example/build/
example/.flutter-plugins
example/.flutter-plugins-dependencies

# Do NOT ignore generated Pigeon files — they're committed:
# !lib/src/pigeon/cambrian_ios_camera_api.g.dart

# Mockito generated mocks ARE committed (codegen-on-demand, reviewable):
# !test/**/*.mocks.dart
```

- [ ] **Step 5: Replace `flutter/README.md`**

```markdown
# cambrian_ios_camera

Flutter plugin wrapping CameraKit for iOS-only camera access.

For full design: `docs/superpowers/specs/2026-05-22-flutter-plugin-phase-b-design.md`.
For lifecycle contract: `CameraKit/README.md`.

## Quick start

```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter
      ref: v1.0.0
```

```dart
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

final engine = CameraEngine();
final caps = await engine.open();
final textureId = await engine.createPreviewTexture(stream: StreamId.processed);
// ...build a Texture(textureId: textureId) into your widget tree
await engine.close();
```

Android: every host method throws `PlatformException(code: 'iOSOnly')`.

## Testing

- Dart unit: `flutter test` (from `flutter/`)
- Swift adapter: `example/scripts/test-swift-adapter.sh` (physical iPad)
- Integration: `example/scripts/test-integration.sh` (physical iPad)

Phase B's lifecycle correctness depends on `CameraKit/Tests/CameraKitTests/LifecycleTests.swift`
remaining green.
```

- [ ] **Step 6: Verify `pubspec.yaml` parses**

Run: `cd flutter && flutter pub get`
Expected: succeeds, creates `.dart_tool/` and `pubspec.lock`. The empty `lib/` is fine.

- [ ] **Step 7: Commit**

```bash
git add flutter/
git commit -m "feat(flutter): scaffold cambrian_ios_camera plugin layout

- pubspec.yaml (pigeon ^22.6.0, mockito + build_runner dev deps)
- ios/cambrian_ios_camera/Package.swift depending on repo root CameraKit
- ios podspec (Flutter's iOS plugin build wiring)
- empty directory placeholders for lib/, lib/src/pigeon/, pigeons/,
  ios sources, android sources, test/
- .gitignore preserving generated Pigeon + mock files

Per Phase B spec §1, §5, §8 (consumer recipe)."
```

---

## Phase 2: Pigeon contract

### Task 3: Pigeon DSL — value types and enums

The Pigeon DSL is one file with all HostApi + EventChannelApi + value types. This task writes the value-type half (`@class` mirrors of CameraKit structs, `@enum` mirrors of CameraKit enums); the next task adds the API interfaces.

**Files:**
- Create: `flutter/pigeons/cambrian_ios_camera_api.dart`

- [ ] **Step 1: Write the DSL value-types section**

Create `flutter/pigeons/cambrian_ios_camera_api.dart`:

```dart
// Pigeon DSL for cambrian_ios_camera.
//
// Regenerate with:
//   cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart
//
// Output locations:
//   - Dart:   lib/src/pigeon/cambrian_ios_camera_api.g.dart
//   - Swift:  ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift
//   - Kotlin: android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt
//
// All generated files are committed to git for review on bumps.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/cambrian_ios_camera_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift',
    swiftOptions: SwiftOptions(),
    kotlinOut: 'android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.cambrian.cambrian_ios_camera'),
    dartPackageName: 'cambrian_ios_camera',
  ),
)
// ─── ENUMS ──────────────────────────────────────────────────────────────────

enum SessionState {
  opening,
  streaming,
  recovering,
  paused,
  error,
  closed,
  interrupted,
}

enum StreamId { natural, processed, tracker }

enum CameraPermissionStatus { notDetermined, denied, restricted, authorized }

enum PhotosDestination { none, copy, move }

enum CameraMode { auto, manual, continuous, locked }

enum WhiteBalanceMode { auto, manual, continuous, locked }

enum RecordingStateKind { idle, recording, finalizing }

enum CameraErrorCode {
  cameraNotFound,
  cameraInUse,
  permissionDenied,
  cameraAccessError,
  cameraDisconnected,
  configurationFailed,
  captureFailure,
  recordingStartFailed,
  recordingFailed,
  recordingTruncated,
  frameStall,
  maxRetriesExceeded,
  unknownError,
  settingsConflict,
  invalidFormat,
  fpsDegraded,
  aeConvergenceTimeout,
  invalidState,
  hardwareError,
  notOpen,                // Adapter-injected for pre-open guard.
}

// ─── VALUE TYPES ────────────────────────────────────────────────────────────

class PSize {
  PSize(this.width, this.height);
  final int width;
  final int height;
}

class PRect {
  PRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

class OpenConfiguration {
  OpenConfiguration({
    this.cameraId,
    this.captureResolution,
    this.cropRegion,
    this.initialSettings,
  });
  String? cameraId;
  PSize? captureResolution;
  PRect? cropRegion;
  CameraSettings? initialSettings;
}

class SessionCapabilities {
  SessionCapabilities({
    required this.supportedSizes,
    required this.previewTextureId,
    required this.naturalTextureId,
    required this.activeCaptureResolution,
    required this.activeCropRegion,
    required this.streamPixelFormat,
    required this.isoMin,
    required this.isoMax,
    required this.exposureDurationMinNs,
    required this.exposureDurationMaxNs,
    required this.focusMin,
    required this.focusMax,
    required this.zoomMin,
    required this.zoomMax,
    required this.evMin,
    required this.evMax,
  });
  List<PSize?> supportedSizes;
  int previewTextureId;
  int naturalTextureId;
  PSize activeCaptureResolution;
  PRect activeCropRegion;
  String streamPixelFormat;
  double isoMin;
  double isoMax;
  int exposureDurationMinNs;
  int exposureDurationMaxNs;
  double focusMin;
  double focusMax;
  double zoomMin;
  double zoomMax;
  double evMin;
  double evMax;
}

class CameraSettings {
  CameraSettings({
    this.isoMode,
    this.iso,
    this.exposureMode,
    this.exposureTimeNs,
    this.focusMode,
    this.focusDistance,
    this.wbMode,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
    this.zoomRatio,
    this.evCompensation,
  });
  CameraMode? isoMode;
  int? iso;
  CameraMode? exposureMode;
  int? exposureTimeNs;
  CameraMode? focusMode;
  double? focusDistance;
  WhiteBalanceMode? wbMode;
  double? wbGainR;
  double? wbGainG;
  double? wbGainB;
  double? zoomRatio;
  int? evCompensation;
}

class ProcessingParameters {
  ProcessingParameters({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.blackR,
    required this.blackG,
    required this.blackB,
    required this.gamma,
  });
  double brightness;
  double contrast;
  double saturation;
  double blackR;
  double blackG;
  double blackB;
  double gamma;
}

class StreamConfiguration {
  StreamConfiguration({
    required this.activeCaptureResolution,
    required this.activeCropRegion,
  });
  PSize activeCaptureResolution;
  PRect activeCropRegion;
}

class FrameResult {
  FrameResult({
    this.iso,
    this.exposureTimeNs,
    this.focusDistance,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
  });
  int? iso;
  int? exposureTimeNs;
  double? focusDistance;
  double? wbGainR;
  double? wbGainG;
  double? wbGainB;
}

class RecordingOptions {
  RecordingOptions({
    this.bitrateBps,
    this.fps,
    this.outputPath,
    required this.photosDestination,
  });
  int? bitrateBps;
  int? fps;
  String? outputPath;
  PhotosDestination photosDestination;
}

class RecordingStart {
  RecordingStart({required this.uri, required this.displayName});
  String uri;
  String displayName;
}

class RecordingStateValue {
  RecordingStateValue({required this.kind, this.lastUri});
  RecordingStateKind kind;
  String? lastUri;
}

class RgbSample {
  RgbSample({required this.r, required this.g, required this.b});
  double r;
  double g;
  double b;
}

class CalibrationResult {
  CalibrationResult({
    required this.before,
    required this.after,
    required this.converged,
    required this.iterations,
  });
  RgbSample before;
  RgbSample after;
  bool converged;
  int iterations;
}

class CameraError {
  CameraError({required this.code, required this.message, required this.isFatal});
  CameraErrorCode code;
  String message;
  bool isFatal;
}
```

> **Naming notes:** `PSize`/`PRect` prefix avoids clashing with `dart:ui.Size`/`Rect` and SwiftUI/UIKit `CGSize`/`CGRect`. The Dart facade re-wraps them as `Size`/`Rect` in its public API. `SessionState.error` is exposed 1:1 — Kotlin's `error` is a function name in the standard library, not a reserved word, so the enum case compiles cleanly without a rename.

- [ ] **Step 2: Commit (DSL not yet generated — checkpoint commit)**

```bash
git add flutter/pigeons/cambrian_ios_camera_api.dart
git commit -m "feat(flutter): Pigeon DSL — value types and enums

First half of the Pigeon DSL. Adds @enum + @class definitions mirroring
CameraKit's public value types. The HostApi + EventChannelApi interfaces
land in the next commit.

Per Phase B spec §2 'Value types'."
```

---

### Task 4: Pigeon DSL — HostApi + EventChannelApi

Adds the API interfaces that go on top of Task 3's value types in the same file.

**Files:**
- Modify: `flutter/pigeons/cambrian_ios_camera_api.dart`

- [ ] **Step 1: Append the API interfaces**

Append to `flutter/pigeons/cambrian_ios_camera_api.dart`:

```dart

// ─── HOST APIS ──────────────────────────────────────────────────────────────

@HostApi()
abstract class CameraEngineHostApi {
  // Lifecycle
  @async SessionCapabilities open(OpenConfiguration? configuration);
  @async void close();

  // Snapshots
  @async CameraSettings? currentSettings();
  @async ProcessingParameters? currentProcessingParameters();

  // Control
  @async void updateSettings(CameraSettings settings);
  @async void setResolution(PSize size);
  @async void setProcessingParams(ProcessingParameters params);
  @async void setCropRegion(PRect rect);

  // Capture
  @async String captureImage(String? outputPath, PhotosDestination photosDestination);
  @async String captureNaturalPicture(String? outputPath, PhotosDestination photosDestination);

  // Recording (no pause/resume — CameraKit has no recording-pause API)
  @async RecordingStart startRecording(RecordingOptions options);
  @async String stopRecording();

  // Calibration
  @async CalibrationResult calibrateWhiteBalance();
  @async CalibrationResult calibrateBlackBalance();

  // Texture bridge
  @async int createPreviewTexture(StreamId stream);
  @async void destroyPreviewTexture(int textureId);
}

@HostApi()
abstract class PermissionsHostApi {
  @async CameraPermissionStatus cameraPermissionStatus();
  @async CameraPermissionStatus requestCameraPermission();
}

// ─── EVENT CHANNEL APIS ─────────────────────────────────────────────────────
// One per stream. Each Stream<T> on the Dart side is fed by the matching
// CameraEngine.<X>Stream() AsyncStream<T> in the adapter via a per-stream
// bridging Task.

@EventChannelApi()
abstract class StateEventApi {
  SessionState streamState();
}

@EventChannelApi()
abstract class ErrorEventApi {
  CameraError streamErrors();
}

@EventChannelApi()
abstract class StreamConfigurationEventApi {
  StreamConfiguration streamStreamConfigurations();
}

@EventChannelApi()
abstract class FrameResultEventApi {
  FrameResult streamFrameResults();
}

@EventChannelApi()
abstract class RecordingStateEventApi {
  RecordingStateValue streamRecordingStates();
}
```

> **EventChannelApi shape note:** Pigeon `^22.6.0` generates Dart-side as `Stream<T> streamX()` and Swift-side as a sink protocol the adapter sends events to. Verify the exact shape after `dart run pigeon` in Task 5 — if signatures differ from this draft (e.g., method names or class names), the *generated* file is authoritative and the next-step code (adapter, facade) follows that shape.

- [ ] **Step 2: Commit (still no generated code)**

```bash
git add flutter/pigeons/cambrian_ios_camera_api.dart
git commit -m "feat(flutter): Pigeon DSL — HostApi and EventChannelApi

Completes the DSL. Two HostApis (CameraEngine + Permissions) and five
EventChannelApis (state, errors, streamConfig, frameResults,
recordingState). All HostApi methods are @async.

Per Phase B spec §2 'Two HostApi interfaces' and 'Five EventChannelApi
instances'."
```

---

### Task 5: Generate Pigeon bindings + commit

Runs Pigeon once to produce the three generated files, verifies them, and commits.

**Files:**
- Create: `flutter/lib/src/pigeon/cambrian_ios_camera_api.g.dart` (generated)
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift` (generated)
- Create: `flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt` (generated)

- [ ] **Step 1: Generate**

Run from `flutter/`:
```bash
cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart
```
Expected: completes silently, writes three `.g.*` files. Any DSL error fails here with a line number; fix in `pigeons/cambrian_ios_camera_api.dart`.

- [ ] **Step 2: Inspect Dart output for the expected shape**

```bash
grep -E "^(abstract class|enum |class )" flutter/lib/src/pigeon/cambrian_ios_camera_api.g.dart
```
Expected: lists `CameraEngineHostApi`, `PermissionsHostApi`, `StateEventApi`, `ErrorEventApi`, `StreamConfigurationEventApi`, `FrameResultEventApi`, `RecordingStateEventApi`, all enums (`SessionState`, `StreamId`, etc.), all `@class` mirrors (`PSize`, `PRect`, `OpenConfiguration`, ...).

- [ ] **Step 3: Inspect Swift output**

```bash
grep -E "^(protocol |class |enum )" flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift | head -30
```
Expected: lists `CameraEngineHostApi` (protocol), `PermissionsHostApi` (protocol), the five EventApi types as `class`, all value-type structs/classes, all enums. The Swift names match the DSL names 1:1.

- [ ] **Step 4: Inspect Kotlin output**

```bash
grep -E "^(interface |class |enum class )" flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt | head -30
```
Expected: same shape as Swift; verifies the Kotlin namespace is `com.cambrian.cambrian_ios_camera`.

- [ ] **Step 5: Verify `flutter pub get` still resolves**

```bash
cd flutter && flutter pub get
```
Expected: no errors.

- [ ] **Step 6: Verify the Dart generated file is analyzer-clean**

```bash
cd flutter && dart analyze lib/src/pigeon/cambrian_ios_camera_api.g.dart
```
Expected: `No issues found!`. If Pigeon emits analyzer-violating lines (rare), the standard fix is to add the file to `analysis_options.yaml`'s `exclude:` — but verify it's only the generated file, not your DSL.

- [ ] **Step 7: Commit**

```bash
git add flutter/lib/src/pigeon/ \
        flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/ \
        flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt
git commit -m "feat(flutter): generate Pigeon bindings (Dart + Swift + Kotlin)

dart run pigeon emits three generated files from
pigeons/cambrian_ios_camera_api.dart. Per Phase B spec §2 they are
committed for review-on-bump. Subsequent Pigeon bumps surface as
git diff of these files."
```

---

## Phase 3: iOS adapter

These tasks land *without* unit tests — the adapter's XCTest suite lives in `flutter/example/ios/RunnerTests/` and runs in Tasks 24-27 once the example app shell exists. The adapter is small enough that compile-time + integration-test coverage is sufficient until then.

### Task 6: Plugin entry point + UIScene lifecycle wiring

Creates the single Swift class that:
1. Implements `FlutterPlugin.register(with:)`
2. Holds the singleton `CameraEngine?`
3. Implements `UIWindowSceneDelegate` scene callback selectors
4. Registers itself via `registrar.addApplicationDelegate(self)`

It does not yet implement any HostApi method body — those live in later tasks. The class is declared as conforming to all the host-api protocols but each method `fatalError("not yet wired")` for now. (Splitting the *file* but not the *type* keeps the compilation unit small while still letting later tasks add methods via extensions.)

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CambrianIosCameraPlugin.swift`

- [ ] **Step 1: Write the plugin class shell**

```swift
import Flutter
import UIKit
import CameraKit

/// The Flutter plugin entry point.
///
/// Owns one CameraEngine, observes UIScene lifecycle natively, and bridges
/// CameraKit ⇄ Pigeon. Per Phase B spec §5, all HostApi protocol method
/// bodies live in extensions in sibling files (HostApi+CameraEngine.swift,
/// HostApi+Permissions.swift, TextureBridge.swift, StreamForwarding.swift).
public final class CambrianIosCameraPlugin: NSObject {

    // MARK: - Plugin registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CambrianIosCameraPlugin(registrar: registrar)
        CameraEngineHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        PermissionsHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        registrar.addApplicationDelegate(instance)
    }

    // MARK: - Stored state

    let registrar: FlutterPluginRegistrar
    var engine: (any CameraEngineProtocol)?
    var textures: [Int64: (FlutterTexture, Task<Void, Never>)] = [:]
    var streamTasks: [Task<Void, Never>] = []

    /// Constructor injection point used by RunnerTests/.
    /// Production code uses `register(with:)`.
    init(registrar: FlutterPluginRegistrar, engine: (any CameraEngineProtocol)? = nil) {
        self.registrar = registrar
        self.engine = engine
        super.init()
    }
}

// MARK: - FlutterPlugin + UIWindowSceneDelegate

extension CambrianIosCameraPlugin: FlutterPlugin, UIWindowSceneDelegate {

    public func sceneDidBecomeActive(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.active) }
    }

    public func sceneWillResignActive(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.inactive) }
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.background) }
    }
    // sceneWillEnterForeground intentionally not implemented — sceneDidBecomeActive
    // carries the .active transition (CameraKit/README.md).
}

// MARK: - Helpers used by other extensions

extension CambrianIosCameraPlugin {

    /// Returns the current scene's `AppLifecyclePhase`, or `.background` if
    /// no scene is connected. Used at engine construction time to seed
    /// `initialPhase`. MainActor-hopped because `UIApplication.shared.connectedScenes`
    /// is MainActor-isolated.
    @MainActor
    static func currentScenePhase() -> AppLifecyclePhase {
        for scene in UIApplication.shared.connectedScenes {
            switch scene.activationState {
            case .foregroundActive:   return .active
            case .foregroundInactive: return .inactive
            case .background:         return .background
            case .unattached:         continue
            @unknown default:         continue
            }
        }
        return .background
    }
}
```

> **Conformance error expected:** This file alone does not satisfy `CameraEngineHostApi` or `PermissionsHostApi`. Tasks 8-11 add the protocol-conforming extensions; until then the build does not link. That is intentional — those tasks have their own compile/test verification.

- [ ] **Step 2: Verify the file alone compiles in isolation (syntax only)**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CambrianIosCameraPlugin.swift
```
Expected: no diagnostics. (If `BeginDocumentationCommentWithOneLineSummary` fires, split the first sentence of doc comments per `CLAUDE.md` §8 "swift-format hook" rule.)

- [ ] **Step 3: Commit**

```bash
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CambrianIosCameraPlugin.swift
git commit -m "feat(adapter): plugin entry point + UIScene lifecycle wiring

Single public class holds the singleton CameraEngine? and implements
the three UIScene callbacks (sceneDidBecomeActive/sceneWillResignActive/
sceneDidEnterBackground) that map to AppLifecyclePhase. Registered via
registrar.addApplicationDelegate(self). HostApi conformance lands in
the next commits.

Per Phase B spec §5."
```

---

### Task 7: Value type mappers — Pigeon ↔ CameraKit

Every Pigeon `@class` needs a `toCameraKit()` going out, and every CameraKit struct returned to Flutter needs a `toPigeon()` going back. Centralizing these in one file keeps the HostApi method bodies a one-liner each.

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/ValueTypeMappers.swift`

- [ ] **Step 1: Write the mappers**

```swift
import CameraKit
import Foundation

// ─── Geometry ───────────────────────────────────────────────────────────────

extension PSize {
    func toCameraKit() -> Size { Size(width: Int(width), height: Int(height)) }
}

extension Size {
    func toPigeon() -> PSize { PSize(width: Int64(width), height: Int64(height)) }
}

extension PRect {
    func toCameraKit() -> Rect {
        Rect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }
}

extension Rect {
    func toPigeon() -> PRect {
        PRect(x: Int64(x), y: Int64(y), width: Int64(width), height: Int64(height))
    }
}

// ─── Settings ───────────────────────────────────────────────────────────────

extension CameraSettings {
    func toCameraKit() -> CameraKit.CameraSettings {
        var s = CameraKit.CameraSettings()
        s.isoMode = isoMode?.toCameraKit()
        s.iso = iso.map { Int($0) }
        s.exposureMode = exposureMode?.toCameraKit()
        s.exposureTimeNs = exposureTimeNs
        s.focusMode = focusMode?.toCameraKit()
        s.focusDistance = focusDistance
        s.wbMode = wbMode?.toCameraKit()
        s.wbGainR = wbGainR
        s.wbGainG = wbGainG
        s.wbGainB = wbGainB
        s.zoomRatio = zoomRatio
        s.evCompensation = evCompensation.map { Int($0) }
        return s
    }
}

extension CameraKit.CameraSettings {
    func toPigeon() -> CameraSettings {
        CameraSettings(
            isoMode: isoMode?.toPigeon(),
            iso: iso.map { Int64($0) },
            exposureMode: exposureMode?.toPigeon(),
            exposureTimeNs: exposureTimeNs,
            focusMode: focusMode?.toPigeon(),
            focusDistance: focusDistance,
            wbMode: wbMode?.toPigeon(),
            wbGainR: wbGainR,
            wbGainG: wbGainG,
            wbGainB: wbGainB,
            zoomRatio: zoomRatio,
            evCompensation: evCompensation.map { Int64($0) }
        )
    }
}

extension CameraMode {
    func toCameraKit() -> CameraKit.CameraMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        case .continuous: return .continuous
        case .locked: return .locked
        }
    }
}

extension CameraKit.CameraMode {
    func toPigeon() -> CameraMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        case .continuous: return .continuous
        case .locked: return .locked
        }
    }
}

extension WhiteBalanceMode {
    func toCameraKit() -> CameraKit.WhiteBalanceMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        case .continuous: return .continuous
        case .locked: return .locked
        }
    }
}

extension CameraKit.WhiteBalanceMode {
    func toPigeon() -> WhiteBalanceMode {
        switch self {
        case .auto: return .auto
        case .manual: return .manual
        case .continuous: return .continuous
        case .locked: return .locked
        }
    }
}

// ─── ProcessingParameters ───────────────────────────────────────────────────

extension ProcessingParameters {
    func toCameraKit() -> CameraKit.ProcessingParameters {
        var p = CameraKit.ProcessingParameters.identity
        p.brightness = brightness
        p.contrast = contrast
        p.saturation = saturation
        p.blackR = blackR
        p.blackG = blackG
        p.blackB = blackB
        p.gamma = gamma
        return p
    }
}

extension CameraKit.ProcessingParameters {
    func toPigeon() -> ProcessingParameters {
        ProcessingParameters(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            blackR: blackR,
            blackG: blackG,
            blackB: blackB,
            gamma: gamma
        )
    }
}

// ─── OpenConfiguration ──────────────────────────────────────────────────────

extension OpenConfiguration {
    func toCameraKit() -> CameraKit.OpenConfiguration {
        var c = CameraKit.OpenConfiguration()
        c.cameraId = cameraId
        c.captureResolution = captureResolution?.toCameraKit()
        c.cropRegion = cropRegion?.toCameraKit()
        c.initialSettings = initialSettings?.toCameraKit()
        return c
    }
}

// ─── SessionCapabilities ────────────────────────────────────────────────────

extension CameraKit.SessionCapabilities {
    func toPigeon() -> SessionCapabilities {
        SessionCapabilities(
            supportedSizes: supportedSizes.map { $0.toPigeon() as PSize? },
            previewTextureId: Int64(previewTextureId),
            naturalTextureId: Int64(naturalTextureId),
            activeCaptureResolution: activeCaptureResolution.toPigeon(),
            activeCropRegion: activeCropRegion.toPigeon(),
            streamPixelFormat: streamPixelFormat,
            isoMin: Double(isoRange.lowerBound),
            isoMax: Double(isoRange.upperBound),
            exposureDurationMinNs: exposureDurationRangeNs.lowerBound,
            exposureDurationMaxNs: exposureDurationRangeNs.upperBound,
            focusMin: focusRange.lowerBound,
            focusMax: focusRange.upperBound,
            zoomMin: zoomRange.lowerBound,
            zoomMax: zoomRange.upperBound,
            evMin: Double(evCompensationRange.lowerBound),
            evMax: Double(evCompensationRange.upperBound)
        )
    }
}

// ─── StreamConfiguration ────────────────────────────────────────────────────

extension CameraKit.StreamConfiguration {
    func toPigeon() -> StreamConfiguration {
        StreamConfiguration(
            activeCaptureResolution: activeCaptureResolution.toPigeon(),
            activeCropRegion: activeCropRegion.toPigeon()
        )
    }
}

// ─── FrameResult ────────────────────────────────────────────────────────────

extension CameraKit.FrameResult {
    func toPigeon() -> FrameResult {
        FrameResult(
            iso: iso.map { Int64($0) },
            exposureTimeNs: exposureTimeNs,
            focusDistance: focusDistance,
            wbGainR: wbGainR,
            wbGainG: wbGainG,
            wbGainB: wbGainB
        )
    }
}

// ─── Recording ──────────────────────────────────────────────────────────────

extension RecordingOptions {
    func toCameraKit() -> CameraKit.RecordingOptions {
        CameraKit.RecordingOptions(
            bitrateBps: bitrateBps.map { Int($0) },
            fps: fps.map { Int($0) },
            outputURL: outputPath.flatMap { URL(fileURLWithPath: $0) },
            photosDestination: photosDestination.toCameraKit()
        )
    }
}

extension CameraKit.RecordingStart {
    func toPigeon() -> RecordingStart {
        RecordingStart(uri: uri, displayName: displayName)
    }
}

extension PhotosDestination {
    func toCameraKit() -> CameraKit.PhotosDestination {
        switch self {
        case .none: return .none
        case .copy: return .copy
        case .move: return .move
        }
    }
}

extension CameraKit.RecordingState {
    func toPigeon() -> RecordingStateValue {
        switch self {
        case .idle(let lastUri):
            return RecordingStateValue(kind: .idle, lastUri: lastUri)
        case .recording:
            return RecordingStateValue(kind: .recording, lastUri: nil)
        case .finalizing:
            return RecordingStateValue(kind: .finalizing, lastUri: nil)
        }
    }
}

// ─── Calibration ────────────────────────────────────────────────────────────

extension CameraKit.RgbSample {
    func toPigeon() -> RgbSample { RgbSample(r: r, g: g, b: b) }
}

extension CameraKit.CalibrationResult {
    func toPigeon() -> CalibrationResult {
        CalibrationResult(
            before: before.toPigeon(),
            after: after.toPigeon(),
            converged: converged,
            iterations: Int64(iterations)
        )
    }
}

// ─── SessionState ───────────────────────────────────────────────────────────

extension CameraKit.SessionState {
    func toPigeon() -> SessionState {
        switch self {
        case .opening:      return .opening
        case .streaming:    return .streaming
        case .recovering:   return .recovering
        case .paused:       return .paused
        case .error:        return .error
        case .closed:       return .closed
        case .interrupted:  return .interrupted
        }
    }
}

// ─── StreamId ───────────────────────────────────────────────────────────────

extension StreamId {
    func toCameraKit() -> CameraKit.StreamId {
        switch self {
        case .natural:   return .natural
        case .processed: return .processed
        case .tracker:   return .tracker
        }
    }
}

// ─── Errors ─────────────────────────────────────────────────────────────────

extension CameraKit.CameraError {
    func toPigeon() -> CameraError {
        CameraError(code: code.toPigeon(), message: message, isFatal: isFatal)
    }
}

extension CameraKit.ErrorCode {
    func toPigeon() -> CameraErrorCode {
        switch self {
        case .cameraNotFound:        return .cameraNotFound
        case .cameraInUse:           return .cameraInUse
        case .permissionDenied:      return .permissionDenied
        case .cameraAccessError:     return .cameraAccessError
        case .cameraDisconnected:    return .cameraDisconnected
        case .configurationFailed:   return .configurationFailed
        case .captureFailure:        return .captureFailure
        case .recordingStartFailed:  return .recordingStartFailed
        case .recordingFailed:       return .recordingFailed
        case .recordingTruncated:    return .recordingTruncated
        case .frameStall:            return .frameStall
        case .maxRetriesExceeded:    return .maxRetriesExceeded
        case .unknownError:          return .unknownError
        case .settingsConflict:      return .settingsConflict
        case .invalidFormat:         return .invalidFormat
        case .fpsDegraded:           return .fpsDegraded
        case .aeConvergenceTimeout:  return .aeConvergenceTimeout
        case .invalidState:          return .invalidState
        case .hardwareError:         return .hardwareError
        }
    }
}

// ─── Permissions ────────────────────────────────────────────────────────────

extension CameraKit.CameraPermissionStatus {
    func toPigeon() -> CameraPermissionStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .authorized:    return .authorized
        }
    }
}

// ─── FlutterError helpers ───────────────────────────────────────────────────

/// Translates any Error thrown from CameraKit into a typed FlutterError
/// whose `code` is the Dart-side CameraErrorCode enum's name. The Dart facade
/// catches PlatformException, parses .code into CameraErrorCode, and rethrows
/// as CameraException.
extension Error {
    func asFlutterError() -> FlutterError {
        if let camErr = self as? CameraKit.CameraError {
            return FlutterError(
                code: camErr.code.toPigeon().rawValue,
                message: camErr.message,
                details: ["isFatal": camErr.isFatal]
            )
        }
        // EngineError / others map to .unknownError unless explicitly recognized.
        return FlutterError(
            code: CameraErrorCode.unknownError.rawValue,
            message: String(describing: self),
            details: ["isFatal": false]
        )
    }
}

extension CameraErrorCode {
    /// The string the Dart facade parses to reconstruct a CameraErrorCode.
    /// `Pigeon` generates `rawValue` for non-string enums via index; we want
    /// the case name so the Dart facade can use `CameraErrorCode.values.byName(...)`.
    var rawValue: String {
        switch self {
        case .cameraNotFound:        return "cameraNotFound"
        case .cameraInUse:           return "cameraInUse"
        case .permissionDenied:      return "permissionDenied"
        case .cameraAccessError:     return "cameraAccessError"
        case .cameraDisconnected:    return "cameraDisconnected"
        case .configurationFailed:   return "configurationFailed"
        case .captureFailure:        return "captureFailure"
        case .recordingStartFailed:  return "recordingStartFailed"
        case .recordingFailed:       return "recordingFailed"
        case .recordingTruncated:    return "recordingTruncated"
        case .frameStall:            return "frameStall"
        case .maxRetriesExceeded:    return "maxRetriesExceeded"
        case .unknownError:          return "unknownError"
        case .settingsConflict:      return "settingsConflict"
        case .invalidFormat:         return "invalidFormat"
        case .fpsDegraded:           return "fpsDegraded"
        case .aeConvergenceTimeout:  return "aeConvergenceTimeout"
        case .invalidState:          return "invalidState"
        case .hardwareError:         return "hardwareError"
        case .notOpen:               return "notOpen"
        }
    }
}
```

- [ ] **Step 2: Lint**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/ValueTypeMappers.swift
```
Expected: no diagnostics.

- [ ] **Step 3: Commit**

```bash
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/ValueTypeMappers.swift
git commit -m "feat(adapter): Pigeon ↔ CameraKit value type mappers

Centralizes every type conversion the adapter needs into one file —
each HostApi method body becomes a 1-3 line translation. Includes
Error.asFlutterError() that propagates CameraKit.CameraError code +
message + isFatal so the Dart facade can rebuild CameraException.

Per Phase B spec §5 'Pigeon HostApi method translation pattern'."
```

---

### Task 8: `CameraEngineHostApi` — implementation

Implements every method of the `CameraEngineHostApi` protocol on `CambrianIosCameraPlugin` via an extension, except the texture-bridge two (those are Task 10).

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CameraEngineHostApiImpl.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Flutter
import CameraKit
import Foundation

extension CambrianIosCameraPlugin: CameraEngineHostApi {

    // MARK: - Lifecycle

    public func open(
        configuration: OpenConfiguration?,
        completion: @escaping (Result<SessionCapabilities, any Error>) -> Void
    ) {
        if engine != nil {
            // Idempotent on already-open: re-publish current capabilities? No —
            // the contract says open() returns capabilities for a fresh session.
            // Second open without close throws so the Dart facade can surface it.
            completion(.failure(FlutterError(
                code: CameraErrorCode.invalidState.rawValue,
                message: "engine already open; call close() before reopening",
                details: ["isFatal": false]
            )))
            return
        }
        Task {
            let phase = await Self.currentScenePhase()
            let cfg = configuration?.toCameraKit() ?? CameraKit.OpenConfiguration()
            let engine = CameraKit.CameraEngine(initialPhase: phase)
            do {
                let caps = try await engine.open(configuration: cfg)
                self.engine = engine
                self.subscribeAllStreams()
                self.armPendingTextures()      // Per spec §3: pre-open textures get subscribers wired now
                completion(.success(caps.toPigeon()))
            } catch {
                completion(.failure(error.asFlutterError()))
            }
        }
    }

    public func close(completion: @escaping (Result<Void, any Error>) -> Void) {
        let engine = self.engine
        let oldStreamTasks = self.streamTasks
        let oldTextures = self.textures
        self.engine = nil
        self.streamTasks = []
        self.textures = [:]
        Task {
            for t in oldStreamTasks { t.cancel() }
            for (id, entry) in oldTextures {
                entry.1.cancel()
                self.registrar.textures().unregisterTexture(id)
            }
            await engine?.close()
            completion(.success(()))
        }
    }

    // MARK: - Snapshots

    public func currentSettings(
        completion: @escaping (Result<CameraSettings?, any Error>) -> Void
    ) {
        let engine = self.engine
        Task {
            let snap = await engine?.currentSettingsSnapshot()
            completion(.success(snap?.toPigeon()))
        }
    }

    public func currentProcessingParameters(
        completion: @escaping (Result<ProcessingParameters?, any Error>) -> Void
    ) {
        let engine = self.engine
        Task {
            let snap = await engine?.currentProcessingParametersSnapshot()
            completion(.success(snap?.toPigeon()))
        }
    }

    // MARK: - Control

    public func updateSettings(
        settings: CameraSettings,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.updateSettings(settings.toCameraKit())
        }
    }

    public func setResolution(
        size: PSize,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.setResolution(size: size.toCameraKit())
        }
    }

    public func setProcessingParams(
        params: ProcessingParameters,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            await engine.setProcessingParams(params.toCameraKit())
        }
    }

    public func setCropRegion(
        rect: PRect,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.setCropRegion(rect.toCameraKit())
        }
    }

    // MARK: - Capture

    public func captureImage(
        outputPath: String?,
        photosDestination: PhotosDestination,
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let url = outputPath.flatMap { URL(fileURLWithPath: $0) }
            let result = try await engine.captureImage(
                outputURL: url,
                photosDestination: photosDestination.toCameraKit()
            )
            return result.filePath
        }
    }

    public func captureNaturalPicture(
        outputPath: String?,
        photosDestination: PhotosDestination,
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let url = outputPath.flatMap { URL(fileURLWithPath: $0) }
            let result = try await engine.captureNaturalPicture(
                outputURL: url,
                photosDestination: photosDestination.toCameraKit()
            )
            return result.filePath
        }
    }

    // MARK: - Recording

    public func startRecording(
        options: RecordingOptions,
        completion: @escaping (Result<RecordingStart, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let s = try await engine.startRecording(options: options.toCameraKit())
            return s.toPigeon()
        }
    }

    public func stopRecording(
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            try await engine.stopRecording()
        }
    }

    // MARK: - Calibration

    public func calibrateWhiteBalance(
        completion: @escaping (Result<CalibrationResult, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let r = try await engine.calibrateWhiteBalance()
            return r.toPigeon()
        }
    }

    public func calibrateBlackBalance(
        completion: @escaping (Result<CalibrationResult, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let r = try await engine.calibrateBlackBalance()
            return r.toPigeon()
        }
    }

    // MARK: - Texture bridge (implemented in TextureBridge.swift)

    // public func createPreviewTexture(...) — in TextureBridge.swift
    // public func destroyPreviewTexture(...) — in TextureBridge.swift

    // MARK: - Private helpers

    /// Calls `body` on the singleton engine; if absent, fails with `.notOpen`.
    private func guardOpen(
        _ completion: @escaping (Result<Void, any Error>) -> Void,
        body: @escaping (any CameraEngineProtocol) async throws -> Void
    ) {
        guard let engine = self.engine else {
            completion(.failure(FlutterError(
                code: CameraErrorCode.notOpen.rawValue,
                message: "engine not open; call open() first",
                details: ["isFatal": false]
            )))
            return
        }
        Task {
            do {
                try await body(engine)
                completion(.success(()))
            } catch {
                completion(.failure(error.asFlutterError()))
            }
        }
    }

    /// Same as `guardOpen` but for methods that return a non-Void result.
    private func guardOpenReturning<T>(
        _ completion: @escaping (Result<T, any Error>) -> Void,
        body: @escaping (any CameraEngineProtocol) async throws -> T
    ) {
        guard let engine = self.engine else {
            completion(.failure(FlutterError(
                code: CameraErrorCode.notOpen.rawValue,
                message: "engine not open; call open() first",
                details: ["isFatal": false]
            )))
            return
        }
        Task {
            do {
                let result = try await body(engine)
                completion(.success(result))
            } catch {
                completion(.failure(error.asFlutterError()))
            }
        }
    }
}
```

- [ ] **Step 2: Lint**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CameraEngineHostApiImpl.swift
```

- [ ] **Step 3: Commit**

```bash
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/CameraEngineHostApiImpl.swift
git commit -m "feat(adapter): CameraEngineHostApi method bodies

Implements every CameraEngineHostApi method (except the two texture-bridge
methods in Task 10) as a thin Pigeon↔CameraKit translation. The
guardOpen/guardOpenReturning helpers compress the repeated open-guard +
try/catch boilerplate.

Per Phase B spec §5 'Pigeon HostApi method translation pattern'."
```

---

### Task 9: `PermissionsHostApi` — implementation

CameraKit exposes static `Permissions.cameraPermissionStatus()` and `requestCameraPermission()`. No engine instance needed.

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/PermissionsHostApiImpl.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Flutter
import CameraKit

extension CambrianIosCameraPlugin: PermissionsHostApi {

    public func cameraPermissionStatus(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        let status = CameraKit.Permissions.cameraPermissionStatus().toPigeon()
        completion(.success(status))
    }

    public func requestCameraPermission(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        Task {
            let status = await CameraKit.Permissions.requestCameraPermission().toPigeon()
            completion(.success(status))
        }
    }
}
```

> **Note:** CameraKit's `Permissions` is a caseless `enum` with `nonisolated static` methods. `cameraPermissionStatus()` returns synchronously; `requestCameraPermission()` is async.

- [ ] **Step 2: Lint + commit**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/PermissionsHostApiImpl.swift
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/PermissionsHostApiImpl.swift
git commit -m "feat(adapter): PermissionsHostApi method bodies

Two methods, each one line of CameraKit + one .toPigeon() hop.
Per Phase B spec §2 'PermissionsHostApi' and §5."
```

---

### Task 10: Texture bridge — `createPreviewTexture` / `destroyPreviewTexture`

Implements the two HostApi methods that vend a `FlutterTexture` ID. The texture instance reads `engine.currentPixelBuffer(stream:)` on the raster thread; a per-stream subscriber Task fires `textureFrameAvailable` on each frame.

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/TextureBridge.swift`

- [ ] **Step 1: Write the FlutterTexture subclass + HostApi methods**

```swift
import Flutter
import CameraKit
import CoreVideo
import Foundation

/// One FlutterTexture instance per active preview stream.
///
/// `copyPixelBuffer` is called on Flutter's raster thread; it looks up the
/// current pixel buffer for this stream from the plugin's engine (mailbox
/// lookup — cheap, no copy) and returns it +1 retained. Flutter releases
/// after rendering. Per Phase B spec §3 "Open-state coupling": pre-open this
/// returns `nil` and the texture shows black until the first frame.
final class EnginePixelBufferTexture: NSObject, FlutterTexture {
    weak var plugin: CambrianIosCameraPlugin?
    let stream: StreamId

    init(plugin: CambrianIosCameraPlugin, stream: StreamId) {
        self.plugin = plugin
        self.stream = stream
        super.init()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let engine = plugin?.engine else { return nil }
        guard let buf = engine.currentPixelBuffer(stream: stream.toCameraKit()) else {
            return nil
        }
        return Unmanaged.passRetained(buf)
    }
}

extension CambrianIosCameraPlugin {

    /// Per Phase B spec §3 "Open-state coupling": calling before `open()`
    /// returns a valid texture id; `copyPixelBuffer` returns `nil` until the
    /// engine is open and the first frame lands. Subscriber tasks are only
    /// spawned once the engine exists — `open()` calls `armPendingTextures()`
    /// to start subscribers for any textures created pre-open.
    public func createPreviewTexture(
        stream: StreamId,
        completion: @escaping (Result<Int64, any Error>) -> Void
    ) {
        let texture = EnginePixelBufferTexture(plugin: self, stream: stream)
        let textureId = registrar.textures().register(texture)
        let task = makeTextureSubscriberTask(textureId: textureId, stream: stream)
        textures[textureId] = (texture, task)
        completion(.success(textureId))
    }

    public func destroyPreviewTexture(
        textureId: Int64,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard let entry = textures.removeValue(forKey: textureId) else {
            // Idempotent: destroy on an unknown ID is a no-op (covered by
            // RunnerTests/TextureMapTests/destroy-twice).
            completion(.success(()))
            return
        }
        entry.1.cancel()
        registrar.textures().unregisterTexture(textureId)
        completion(.success(()))
    }

    /// Spawns subscriber tasks for any textures that were registered before
    /// the engine existed. Called from `open()` after `self.engine` is set.
    func armPendingTextures() {
        for (textureId, entry) in textures {
            entry.1.cancel()                          // belt-and-braces; pending task is no-op
            let stream = entry.0.stream
            let newTask = makeTextureSubscriberTask(textureId: textureId, stream: stream)
            textures[textureId] = (entry.0, newTask)
        }
    }

    /// Builds the subscriber task that fires `textureFrameAvailable` per
    /// delivered frame. If `self.engine` is nil at call time, the task exits
    /// immediately; `armPendingTextures()` re-spawns it later.
    private func makeTextureSubscriberTask(
        textureId: Int64, stream: StreamId
    ) -> Task<Void, Never> {
        let registry = registrar.textures()
        let kitStream = stream.toCameraKit()
        return Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            let token = await engine.consumers.subscribe(stream: kitStream)
            do {
                for try await _ in token.stream {
                    if Task.isCancelled { break }
                    registry.textureFrameAvailable(textureId)
                }
            } catch {
                // Subscription closed; texture stays registered until destroy.
            }
            await engine.consumers.unsubscribe(token)
        }
    }
}
```

> **`consumers.subscribe(stream:)` shape note:** CameraKit's `ConsumerRegistry.subscribe(stream:)` returns an opaque token bundle. Read `CameraKit/Sources/CameraKit/PixelSink.swift` for the exact `subscribe`/`unsubscribe` signature — if it returns `(token, AsyncStream<FrameSet>)` instead of `Subscription` (or whatever the current name is), adjust the destructuring above to match. The intent is: get a stream that fires on each delivered frame for `stream`, iterate it, call `textureFrameAvailable(textureId)` per fire, drop the subscription on cancellation.

- [ ] **Step 2: Lint + commit**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/TextureBridge.swift
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/TextureBridge.swift
git commit -m "feat(adapter): texture bridge — FlutterTexture + create/destroy

EnginePixelBufferTexture reads engine.currentPixelBuffer(stream:) on the
raster thread and returns a retained CVPixelBuffer (Flutter framework
releases after rendering). createPreviewTexture also spawns a subscriber
Task that fires textureFrameAvailable per frame.

Per Phase B spec §3 'Mechanism' and §5 'Texture lifecycle'."
```

---

### Task 11: Stream forwarding — `subscribeAllStreams`

The five engine `AsyncStream`s feed five `EventChannelApi` instances. This task implements the `subscribeAllStreams()` method that `open()` calls and the per-stream forwarders.

**Files:**
- Create: `flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/StreamForwarding.swift`

- [ ] **Step 1: Write the forwarders**

```swift
import Flutter
import CameraKit

extension CambrianIosCameraPlugin {

    /// Spawns the five per-stream forwarder tasks. Called from `open()` once
    /// the engine has been constructed. `close()` cancels each.
    func subscribeAllStreams() {
        guard let engine = self.engine else { return }
        let messenger = registrar.messenger()
        let stateApi = StateEventApi(binaryMessenger: messenger)
        let errorApi = ErrorEventApi(binaryMessenger: messenger)
        let cfgApi = StreamConfigurationEventApi(binaryMessenger: messenger)
        let frameApi = FrameResultEventApi(binaryMessenger: messenger)
        let recApi = RecordingStateEventApi(binaryMessenger: messenger)

        streamTasks.append(Task { [engine] in
            for await state in engine.stateStream() {
                if Task.isCancelled { break }
                stateApi.streamState(state.toPigeon())
            }
        })

        streamTasks.append(Task { [engine] in
            for await err in engine.errorStream() {
                if Task.isCancelled { break }
                errorApi.streamErrors(err.toPigeon())
            }
        })

        streamTasks.append(Task { [engine] in
            for await cfg in engine.streamConfigurationStream() {
                if Task.isCancelled { break }
                cfgApi.streamStreamConfigurations(cfg.toPigeon())
            }
        })

        streamTasks.append(Task { [engine] in
            for await fr in engine.frameResultStream() {
                if Task.isCancelled { break }
                frameApi.streamFrameResults(fr.toPigeon())
            }
        })

        streamTasks.append(Task { [engine] in
            for await rs in engine.recordingStateStream() {
                if Task.isCancelled { break }
                recApi.streamRecordingStates(rs.toPigeon())
            }
        })
    }
}
```

> **EventChannelApi send-method note:** Pigeon `^22.6.0` generates each `@EventChannelApi` as a Dart-side `Stream<T> streamX()` and a Swift-side class with a `streamX(_ value: T)` send method (or similar). After generating in Task 5, look at the Swift `*.g.swift` to confirm the exact method names; if they differ from `streamState` / `streamErrors` / `streamStreamConfigurations` / `streamFrameResults` / `streamRecordingStates`, adjust the calls above to match the generated signatures.

- [ ] **Step 2: Lint**

```bash
swift-format lint --strict flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/StreamForwarding.swift
```

- [ ] **Step 3: First end-to-end iOS compile check**

The adapter now declares conformance to both HostApi protocols across multiple files; only here is the source set complete. Build the SPM package's iOS target via XcodeBuildMCP using the example app's project once that exists; for now, the standalone Swift package check is:

```bash
cd flutter/ios/cambrian_ios_camera && swift build --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -Xswiftc -target -Xswiftc arm64-apple-ios26.0 2>&1 | tail -40
```

> Expected: a Flutter-headers-not-found build error if Flutter isn't on the system search path. That's fine — the real build happens in Task 28 once the example app's Runner.xcodeproj exists. This step is only checking *Swift syntax*. If you see "expected declaration" or "ambiguous reference" errors, fix them first; "no such module 'Flutter'" is acceptable here.

- [ ] **Step 4: Commit**

```bash
git add flutter/ios/cambrian_ios_camera/Sources/cambrian_ios_camera/StreamForwarding.swift
git commit -m "feat(adapter): forward CameraEngine AsyncStreams to EventChannelApi

Spawns five per-stream forwarder Tasks at engine open(); each iterates
the corresponding CameraEngine.<X>Stream() and pushes via the matching
EventChannelApi send method. All tasks stored in streamTasks for
cancellation on close().

Per Phase B spec §5 'Stream forwarding pattern'.

iOS adapter is now feature-complete in code; first real compile happens
in Task 28 once the example app's Runner.xcodeproj exists."
```

---

## Phase 4: Android no-op stub

### Task 12: Kotlin stub throwing `PlatformException(code: "iOSOnly")`

The Android side exists only so `flutter pub get` accepts the multi-platform plugin and `flutter run` doesn't error out on a missing Android implementation. Every HostApi method throws.

**Files:**
- Create: `flutter/android/build.gradle`
- Create: `flutter/android/src/main/AndroidManifest.xml`
- Create: `flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/CambrianIosCameraPlugin.kt`

- [ ] **Step 1: Write `flutter/android/build.gradle`**

```gradle
group 'com.cambrian.cambrian_ios_camera'
version '1.0.0'

buildscript {
    ext.kotlin_version = '1.9.22'
    repositories { google(); mavenCentral() }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.1.0'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"
    }
}

rootProject.allprojects {
    repositories { google(); mavenCentral() }
}

apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace = 'com.cambrian.cambrian_ios_camera'
    compileSdk = 34

    sourceSets { main.java.srcDirs += 'src/main/kotlin' }

    defaultConfig { minSdk = 21 }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
```

- [ ] **Step 2: Write the manifest**

`flutter/android/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="com.cambrian.cambrian_ios_camera" />
```

- [ ] **Step 3: Write the Kotlin stub**

`flutter/android/src/main/kotlin/com/cambrian/cambrian_ios_camera/CambrianIosCameraPlugin.kt`:

```kotlin
package com.cambrian.cambrian_ios_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin

/// iOS-only plugin. The Android side registers the Pigeon HostApis but
/// every method throws PlatformException(code: "iOSOnly"). EventChannels
/// emit one error event and close.
class CambrianIosCameraPlugin :
    FlutterPlugin,
    CameraEngineHostApi,
    PermissionsHostApi {

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraEngineHostApi.setUp(binding.binaryMessenger, this)
        PermissionsHostApi.setUp(binding.binaryMessenger, this)
        // EventChannelApis: emit one error and close.
        StateEventApi.register(binding.binaryMessenger, IosOnlyErrorStream("state"))
        ErrorEventApi.register(binding.binaryMessenger, IosOnlyErrorStream("errors"))
        StreamConfigurationEventApi.register(binding.binaryMessenger, IosOnlyErrorStream("streamConfigurations"))
        FrameResultEventApi.register(binding.binaryMessenger, IosOnlyErrorStream("frameResults"))
        RecordingStateEventApi.register(binding.binaryMessenger, IosOnlyErrorStream("recordingStates"))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraEngineHostApi.setUp(binding.binaryMessenger, null)
        PermissionsHostApi.setUp(binding.binaryMessenger, null)
    }

    // CameraEngineHostApi — every method throws.

    override fun open(configuration: OpenConfiguration?, callback: (Result<SessionCapabilities>) -> Unit) {
        callback(Result.failure(iosOnly("open")))
    }
    override fun close(callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("close")))
    }
    override fun currentSettings(callback: (Result<CameraSettings?>) -> Unit) {
        callback(Result.failure(iosOnly("currentSettings")))
    }
    override fun currentProcessingParameters(callback: (Result<ProcessingParameters?>) -> Unit) {
        callback(Result.failure(iosOnly("currentProcessingParameters")))
    }
    override fun updateSettings(settings: CameraSettings, callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("updateSettings")))
    }
    override fun setResolution(size: PSize, callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("setResolution")))
    }
    override fun setProcessingParams(params: ProcessingParameters, callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("setProcessingParams")))
    }
    override fun setCropRegion(rect: PRect, callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("setCropRegion")))
    }
    override fun captureImage(outputPath: String?, photosDestination: PhotosDestination, callback: (Result<String>) -> Unit) {
        callback(Result.failure(iosOnly("captureImage")))
    }
    override fun captureNaturalPicture(outputPath: String?, photosDestination: PhotosDestination, callback: (Result<String>) -> Unit) {
        callback(Result.failure(iosOnly("captureNaturalPicture")))
    }
    override fun startRecording(options: RecordingOptions, callback: (Result<RecordingStart>) -> Unit) {
        callback(Result.failure(iosOnly("startRecording")))
    }
    override fun stopRecording(callback: (Result<String>) -> Unit) {
        callback(Result.failure(iosOnly("stopRecording")))
    }
    override fun calibrateWhiteBalance(callback: (Result<CalibrationResult>) -> Unit) {
        callback(Result.failure(iosOnly("calibrateWhiteBalance")))
    }
    override fun calibrateBlackBalance(callback: (Result<CalibrationResult>) -> Unit) {
        callback(Result.failure(iosOnly("calibrateBlackBalance")))
    }
    override fun createPreviewTexture(stream: StreamId, callback: (Result<Long>) -> Unit) {
        callback(Result.failure(iosOnly("createPreviewTexture")))
    }
    override fun destroyPreviewTexture(textureId: Long, callback: (Result<Unit>) -> Unit) {
        callback(Result.failure(iosOnly("destroyPreviewTexture")))
    }

    override fun cameraPermissionStatus(callback: (Result<CameraPermissionStatus>) -> Unit) {
        callback(Result.failure(iosOnly("cameraPermissionStatus")))
    }
    override fun requestCameraPermission(callback: (Result<CameraPermissionStatus>) -> Unit) {
        callback(Result.failure(iosOnly("requestCameraPermission")))
    }

    private fun iosOnly(method: String): Throwable =
        FlutterError(
            code = "iOSOnly",
            message = "cambrian_ios_camera is iOS-only; $method has no Android implementation",
            details = null
        )
}

private class IosOnlyErrorStream(private val streamName: String) : EventChannel.StreamHandler {
    // Pigeon-generated EventChannelApi.register takes a StreamHandler-style
    // adapter. Verify the exact signature/type name after Task 5 generation;
    // if different, adapt.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        events?.error("iOSOnly",
            "cambrian_ios_camera is iOS-only; $streamName stream has no Android implementation",
            null)
        events?.endOfStream()
    }
    override fun onCancel(arguments: Any?) {}
}
```

> **Pigeon-Kotlin shape note:** Pigeon generates a different EventChannelApi registration pattern across Pigeon versions — `register(binaryMessenger, handler)` where the handler has its own protocol shape. After generating in Task 5, inspect the `*.g.kt` and adapt this stub's `EventChannelApi.register(...)` calls and the `IosOnlyErrorStream` shape to match the generated signatures. The intent is: every stream channel emits one error event and closes, every host method throws `iOSOnly`. The `FlutterError` referenced is the Pigeon-generated exception class.

- [ ] **Step 4: Commit**

```bash
git add flutter/android/
git commit -m "feat(flutter): Android no-op stub — every method throws iOSOnly

The Android side exists so flutter pub get accepts the multi-platform
plugin and consumers can target both Dart 'package:cambrian_ios_camera/...'
imports. At runtime, every HostApi method throws
PlatformException(code: 'iOSOnly'); every EventChannel emits one error
and closes.

Per Phase B spec scope: 'Android Kotlin no-op stub throwing
PlatformException(code: \"iOSOnly\")'."
```

---

## Phase 5: Dart facade

The Dart facade is built TDD. Each task writes a failing test, runs it red, implements minimal code to make it green, then commits. Tests live in `flutter/test/`, all loadable via `flutter test` (no device required).

### Task 13: `CameraException` + `CameraErrorCode`

The typed Dart exception. Mirrors the Pigeon-generated `CameraErrorCode` enum but adds error-handling utilities (parsing from `PlatformException.code`).

**Files:**
- Create: `flutter/lib/src/camera_exception.dart`
- Create: `flutter/test/camera_exception_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_exception_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

void main() {
  group('CameraException', () {
    test('constructs with code, message, isFatal', () {
      final e = CameraException(
        code: CameraErrorCode.frameStall,
        message: 'no frame in 800ms',
        isFatal: false,
      );
      expect(e.code, CameraErrorCode.frameStall);
      expect(e.message, 'no frame in 800ms');
      expect(e.isFatal, false);
    });

    test('toString includes code name and message', () {
      final e = CameraException(
        code: CameraErrorCode.cameraInUse,
        message: 'busy',
        isFatal: false,
      );
      expect(e.toString(), contains('cameraInUse'));
      expect(e.toString(), contains('busy'));
    });

    test('toString flags fatal', () {
      final e = CameraException(
        code: CameraErrorCode.hardwareError,
        message: 'oops',
        isFatal: true,
      );
      expect(e.toString(), contains('FATAL'));
    });
  });

  group('CameraException.fromPlatformException', () {
    test('parses known code string', () {
      final pe = PlatformException(
        code: 'frameStall',
        message: 'watchdog fired',
        details: {'isFatal': false},
      );
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.code, CameraErrorCode.frameStall);
      expect(ce.message, 'watchdog fired');
      expect(ce.isFatal, false);
    });

    test('unknown code maps to .unknownError, preserves original code in message', () {
      final pe = PlatformException(
        code: 'someNewCodeFromFutureVersion',
        message: 'thing happened',
      );
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.code, CameraErrorCode.unknownError);
      expect(ce.message, contains('someNewCodeFromFutureVersion'));
      expect(ce.message, contains('thing happened'));
      expect(ce.isFatal, false);
    });

    test('missing details maps isFatal to false', () {
      final pe = PlatformException(code: 'frameStall', message: 'x');
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.isFatal, false);
    });

    test('details with isFatal true', () {
      final pe = PlatformException(
        code: 'hardwareError',
        message: 'x',
        details: {'isFatal': true},
      );
      expect(CameraException.fromPlatformException(pe).isFatal, true);
    });
  });

  group('CameraErrorCode parsing', () {
    test('parses each known case via byName', () {
      for (final c in CameraErrorCode.values) {
        expect(parseCameraErrorCode(c.name), c);
      }
    });
    test('unknown string returns unknownError', () {
      expect(parseCameraErrorCode('garbage'), CameraErrorCode.unknownError);
    });
  });
}
```

- [ ] **Step 2: Verify the test file fails to compile**

```bash
cd flutter && flutter test test/camera_exception_test.dart
```
Expected: `Target of URI doesn't exist 'package:cambrian_ios_camera/cambrian_ios_camera.dart'` or compile errors referencing missing `CameraException`, `CameraErrorCode`, `parseCameraErrorCode`. That's expected; the next steps create them.

- [ ] **Step 3: Write `flutter/lib/src/camera_exception.dart`**

```dart
import 'package:flutter/services.dart';

import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

/// Mirror of the Pigeon-generated `CameraErrorCode` re-exported for ergonomic
/// imports. The enum cases must match `flutter/pigeons/cambrian_ios_camera_api.dart`
/// 1:1; any addition there requires a matching addition here. (Re-exported as
/// a typedef so consumers don't see the `g.` prefix.)
typedef CameraErrorCode = g.CameraErrorCode;

/// Typed exception thrown by every `CameraEngine` and `Permissions` method.
///
/// Caught from raw `PlatformException`s at the Dart facade boundary and
/// re-thrown so consumers never see an untyped exception. The `code` enum is
/// matched against the Swift adapter's `CameraErrorCode.rawValue` (the case
/// name string).
class CameraException implements Exception {
  final CameraErrorCode code;
  final String message;
  final bool isFatal;

  const CameraException({
    required this.code,
    required this.message,
    required this.isFatal,
  });

  /// Wraps a raw `PlatformException` (the form Pigeon's `@async` methods
  /// throw on the Dart side). Unknown `code` strings map to
  /// `CameraErrorCode.unknownError` and the original string is preserved in
  /// `message` for forward-compat.
  factory CameraException.fromPlatformException(PlatformException e) {
    final parsed = parseCameraErrorCode(e.code);
    final message = parsed == CameraErrorCode.unknownError
        ? 'unknown adapter code "${e.code}": ${e.message ?? ""}'
        : (e.message ?? '');
    final details = e.details;
    final isFatal = details is Map && details['isFatal'] == true;
    return CameraException(code: parsed, message: message, isFatal: isFatal);
  }

  @override
  String toString() =>
      'CameraException(${code.name}): $message${isFatal ? " [FATAL]" : ""}';
}

/// Resolves a code-string to a `CameraErrorCode`, returning `.unknownError`
/// if no enum case matches (forward-compat with newer CameraKit versions
/// adding codes).
CameraErrorCode parseCameraErrorCode(String name) {
  for (final c in CameraErrorCode.values) {
    if (c.name == name) return c;
  }
  return CameraErrorCode.unknownError;
}
```

- [ ] **Step 4: Add a transitional `flutter/lib/cambrian_ios_camera.dart` exporting just this much**

The full public library export comes in Task 23; for now the test needs *something* to import.

```dart
// flutter/lib/cambrian_ios_camera.dart
export 'src/camera_exception.dart';
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
cd flutter && flutter test test/camera_exception_test.dart
```
Expected: all tests pass (5 in `CameraException.fromPlatformException`, 3 in `CameraException`, 2 in `CameraErrorCode parsing` = 10 tests).

- [ ] **Step 6: Commit**

```bash
git add flutter/lib/src/camera_exception.dart flutter/lib/cambrian_ios_camera.dart flutter/test/camera_exception_test.dart
git commit -m "feat(flutter): typed CameraException + CameraErrorCode parsing

Typed Dart exception that the facade re-throws from raw PlatformException
caught at the Pigeon boundary. CameraErrorCode is re-exported from the
Pigeon-generated enum as a typedef. parseCameraErrorCode forwards-compats
unknown codes to .unknownError, preserving the original string in message.

10 unit tests cover: construction, toString, fatal-flag formatting,
known-code parsing, unknown-code fallback, missing isFatal details, all
cases via byName, garbage string fallback.

Per Phase B spec §4 'CameraException — typed error'."
```

---

### Task 14: `Permissions` static class

Two static methods that delegate to the Pigeon-generated `PermissionsHostApi`. The tests use mockito to mock the HostApi.

**Files:**
- Create: `flutter/lib/src/permissions.dart`
- Create: `flutter/test/permissions_test.dart`
- Create: `flutter/test/mocks/mocks.dart` (mockito annotation file)

- [ ] **Step 1: Write the mockito spec file**

`flutter/test/mocks/mocks.dart` — single source-of-truth that mockito generates from. Every HostApi the tests mock is annotated here.

```dart
import 'package:mockito/annotations.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart';

@GenerateMocks([CameraEngineHostApi, PermissionsHostApi])
void main() {}
```

- [ ] **Step 2: Run codegen**

```bash
cd flutter && dart run build_runner build --delete-conflicting-outputs
```
Expected: writes `flutter/test/mocks/mocks.mocks.dart`.

- [ ] **Step 3: Write the failing tests**

`flutter/test/permissions_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockPermissionsHostApi api;
  setUp(() {
    api = MockPermissionsHostApi();
    PermissionsTesting.setHostApi(api);
  });
  tearDown(PermissionsTesting.reset);

  group('Permissions.cameraPermissionStatus()', () {
    for (final s in g.CameraPermissionStatus.values) {
      test('returns $s', () async {
        when(api.cameraPermissionStatus()).thenAnswer((_) async => s);
        expect(await Permissions.cameraPermissionStatus(), s);
      });
    }
  });

  group('Permissions.requestCameraPermission()', () {
    for (final s in g.CameraPermissionStatus.values) {
      test('returns $s', () async {
        when(api.requestCameraPermission()).thenAnswer((_) async => s);
        expect(await Permissions.requestCameraPermission(), s);
      });
    }
  });
}
```

- [ ] **Step 4: Verify test fails (Permissions / PermissionsTesting / CameraPermissionStatus unknown)**

```bash
cd flutter && flutter test test/permissions_test.dart
```
Expected: compile error referencing missing `Permissions`, `PermissionsTesting`, etc.

- [ ] **Step 5: Write `flutter/lib/src/permissions.dart`**

```dart
import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

typedef CameraPermissionStatus = g.CameraPermissionStatus;

/// Static permissions API — no engine instance required. Use before opening
/// the engine; if `cameraPermissionStatus()` returns `.notDetermined`, call
/// `requestCameraPermission()` to surface the iOS system prompt.
class Permissions {
  Permissions._();

  static g.PermissionsHostApi _api = g.PermissionsHostApi();

  static Future<CameraPermissionStatus> cameraPermissionStatus() =>
      _api.cameraPermissionStatus();

  static Future<CameraPermissionStatus> requestCameraPermission() =>
      _api.requestCameraPermission();
}

/// Internal test seam — accessed only from lib/testing.dart's
/// `PermissionsTesting.setHostApi(...)`.
void permissionsSetHostApiForTest(g.PermissionsHostApi api) {
  Permissions._api = api;
}

g.PermissionsHostApi permissionsDefaultHostApiForTest() => g.PermissionsHostApi();
```

- [ ] **Step 6: Update the `cambrian_ios_camera.dart` umbrella to export Permissions too**

```dart
// flutter/lib/cambrian_ios_camera.dart
export 'src/camera_exception.dart';
export 'src/permissions.dart' show Permissions, CameraPermissionStatus;
```

- [ ] **Step 7: Run the test and verify it still fails (PermissionsTesting missing)**

```bash
cd flutter && flutter test test/permissions_test.dart
```
Expected: error referencing missing `PermissionsTesting`. We deliberately defined the test seam internally; the public mocking helper lives in `lib/testing.dart` which is built in Task 15.

- [ ] **Step 8: Write minimal `flutter/lib/testing.dart` for Permissions only**

(The full testing.dart adds the CameraEngine factory in Task 15 — for now, just enough to make this test pass.)

```dart
import 'src/permissions.dart' show permissionsSetHostApiForTest, permissionsDefaultHostApiForTest;
import 'src/pigeon/cambrian_ios_camera_api.g.dart' as g;

/// Test seam for `Permissions`. Production code never imports `lib/testing.dart`.
abstract final class PermissionsTesting {
  PermissionsTesting._();
  static void setHostApi(g.PermissionsHostApi api) => permissionsSetHostApiForTest(api);
  static void reset() => permissionsSetHostApiForTest(permissionsDefaultHostApiForTest());
}
```

- [ ] **Step 9: Run the test and verify it passes**

```bash
cd flutter && flutter test test/permissions_test.dart
```
Expected: 8 tests pass (4 status × 2 methods).

- [ ] **Step 10: Commit**

```bash
git add flutter/lib/src/permissions.dart flutter/lib/cambrian_ios_camera.dart \
        flutter/lib/testing.dart flutter/test/mocks/mocks.dart \
        flutter/test/mocks/mocks.mocks.dart flutter/test/permissions_test.dart
git commit -m "feat(flutter): Permissions static class + mockito test seam

Two static methods (cameraPermissionStatus, requestCameraPermission)
delegating to the Pigeon-generated PermissionsHostApi. A separate
lib/testing.dart provides a PermissionsTesting.setHostApi(...) factory
for tests; main library does not expose it.

Includes mockito setup (test/mocks/mocks.dart + generated
mocks.mocks.dart). 8 unit tests cover every CameraPermissionStatus
case × both methods.

Per Phase B spec §4 'Permissions — static class' and §7 'Test seam in
a separate library'."
```

---

### Task 15: Extend `lib/testing.dart` with `CameraEngineTesting`

Adds the `CameraEngineTesting.create(api: ...)` factory the next tasks will use to mock the engine HostApi. Empty test for now (just verifies the factory compiles); real CameraEngine tests come in Tasks 16-22.

**Files:**
- Modify: `flutter/lib/testing.dart`

- [ ] **Step 1: Append to `flutter/lib/testing.dart`**

```dart
// (existing imports + PermissionsTesting from Task 14 stay above)

import 'src/camera_engine.dart' show CameraEngine, cameraEngineMakeForTest;

/// Test seam for `CameraEngine`. Production code never imports
/// `lib/testing.dart`. The factory builds a CameraEngine wired against
/// `api` instead of the default `CameraEngineHostApi()`.
abstract final class CameraEngineTesting {
  CameraEngineTesting._();
  static CameraEngine create({required g.CameraEngineHostApi api}) =>
      cameraEngineMakeForTest(api: api);
}
```

> The `cameraEngineMakeForTest` symbol is implemented by Task 16 (the CameraEngine constructor work). For now, this addition does not yet compile — that's fine, Task 16 lands both the engine internals and this call site together.

- [ ] **Step 2: Hold the commit until Task 16**

This file change is staged but not committed in isolation — it can't compile yet. The commit at the end of Task 16 includes both files.

---

### Task 16: `CameraEngine` — constructor, `open()`, `close()`, snapshots

Lays down the class shell and the simplest methods. Streams come in Task 17; remaining methods in Tasks 18-22.

**Files:**
- Create: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_open_close_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_open_close_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

g.SessionCapabilities _fakeCaps() => g.SessionCapabilities(
      supportedSizes: [g.PSize(width: 1920, height: 1080)],
      previewTextureId: 1,
      naturalTextureId: 2,
      activeCaptureResolution: g.PSize(width: 1920, height: 1080),
      activeCropRegion: g.PRect(x: 0, y: 0, width: 1920, height: 1080),
      streamPixelFormat: 'BGRA8',
      isoMin: 50, isoMax: 3200,
      exposureDurationMinNs: 100000, exposureDurationMaxNs: 33000000,
      focusMin: 0, focusMax: 1,
      zoomMin: 1, zoomMax: 8,
      evMin: -8, evMax: 8,
    );

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;

  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  group('open()', () {
    test('returns capabilities on success', () async {
      when(api.open(any)).thenAnswer((_) async => _fakeCaps());
      final caps = await engine.open();
      expect(caps.streamPixelFormat, 'BGRA8');
      verify(api.open(null)).called(1);
    });

    test('passes OpenConfiguration through', () async {
      when(api.open(any)).thenAnswer((_) async => _fakeCaps());
      final cfg = g.OpenConfiguration(cameraId: 'back');
      await engine.open(cfg);
      verify(api.open(cfg)).called(1);
    });

    test('rethrows PlatformException as CameraException', () async {
      when(api.open(any)).thenThrow(
        PlatformException(code: 'invalidState', message: 'busy'),
      );
      expect(
        () => engine.open(),
        throwsA(isA<CameraException>().having((e) => e.code, 'code',
            CameraErrorCode.invalidState)),
      );
    });
  });

  group('close()', () {
    test('delegates to HostApi', () async {
      when(api.close()).thenAnswer((_) async {});
      await engine.close();
      verify(api.close()).called(1);
    });

    test('dispose() calls close() exactly once', () async {
      when(api.close()).thenAnswer((_) async {});
      await engine.dispose();
      verify(api.close()).called(1);
    });
  });

  group('Snapshots', () {
    test('currentSettings returns null when host returns null', () async {
      when(api.currentSettings()).thenAnswer((_) async => null);
      expect(await engine.currentSettings(), isNull);
    });

    test('currentSettings rethrows PlatformException', () async {
      when(api.currentSettings()).thenThrow(
        PlatformException(code: 'notOpen', message: 'engine not open'),
      );
      expect(
        () => engine.currentSettings(),
        throwsA(isA<CameraException>().having((e) => e.code, 'code',
            CameraErrorCode.notOpen)),
      );
    });

    test('currentProcessingParameters returns value on success', () async {
      final p = g.ProcessingParameters(
        brightness: 0, contrast: 1, saturation: 1,
        blackR: 0, blackG: 0, blackB: 0, gamma: 1,
      );
      when(api.currentProcessingParameters()).thenAnswer((_) async => p);
      expect(await engine.currentProcessingParameters(), same(p));
    });
  });
}
```

- [ ] **Step 2: Verify the test fails to compile**

```bash
cd flutter && flutter test test/camera_engine_open_close_test.dart
```
Expected: missing `CameraEngine`, `CameraEngineTesting`, `cameraEngineMakeForTest`.

- [ ] **Step 3: Write `flutter/lib/src/camera_engine.dart` shell**

```dart
import 'package:flutter/services.dart';
import 'camera_exception.dart';
import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

/// The Dart-side CameraEngine facade. Mirrors CameraKit's public Swift
/// surface 1:1; methods delegate to the Pigeon HostApi.
///
/// Caught `PlatformException`s are re-thrown as `CameraException`.
class CameraEngine {
  final g.CameraEngineHostApi _api;

  /// Production constructor — wires the default Pigeon HostApi.
  CameraEngine() : _api = g.CameraEngineHostApi();

  /// Internal constructor used by `CameraEngineTesting.create`.
  CameraEngine._testing({required g.CameraEngineHostApi api}) : _api = api;

  // MARK: - Lifecycle

  Future<g.SessionCapabilities> open([g.OpenConfiguration? config]) =>
      _guard(() => _api.open(config));

  Future<void> close() => _guard(_api.close);

  /// Dart convention alias for `close()` — symmetric with most Dart classes
  /// that hold platform resources.
  Future<void> dispose() => close();

  // MARK: - Snapshots

  Future<g.CameraSettings?> currentSettings() =>
      _guard(_api.currentSettings);

  Future<g.ProcessingParameters?> currentProcessingParameters() =>
      _guard(_api.currentProcessingParameters);

  // (More methods land in Tasks 17-22.)

  // MARK: - Internal guard helper

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (pe) {
      throw CameraException.fromPlatformException(pe);
    }
  }
}

/// Internal: factory for the testing seam. Returns a CameraEngine wired
/// against the given api. Not exposed via the main library.
CameraEngine cameraEngineMakeForTest({required g.CameraEngineHostApi api}) =>
    CameraEngine._testing(api: api);
```

- [ ] **Step 4: Update the `cambrian_ios_camera.dart` umbrella**

```dart
// flutter/lib/cambrian_ios_camera.dart
export 'src/camera_exception.dart';
export 'src/permissions.dart' show Permissions, CameraPermissionStatus;
export 'src/camera_engine.dart' show CameraEngine;

// Re-export Pigeon-generated value types so consumers can construct
// e.g. OpenConfiguration without an explicit src/pigeon/ import.
export 'src/pigeon/cambrian_ios_camera_api.g.dart' show
    OpenConfiguration,
    SessionCapabilities,
    CameraSettings,
    ProcessingParameters,
    StreamConfiguration,
    FrameResult,
    RecordingOptions,
    RecordingStart,
    RecordingStateValue,
    RecordingStateKind,
    CalibrationResult,
    RgbSample,
    CameraError,
    PSize,
    PRect,
    StreamId,
    SessionState,
    PhotosDestination,
    CameraMode,
    WhiteBalanceMode;
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
cd flutter && flutter test test/camera_engine_open_close_test.dart
```
Expected: all 9 tests pass.

- [ ] **Step 6: Commit (rolls in the staged testing.dart from Task 15)**

```bash
git add flutter/lib/src/camera_engine.dart flutter/lib/cambrian_ios_camera.dart \
        flutter/lib/testing.dart flutter/test/camera_engine_open_close_test.dart
git commit -m "feat(flutter): CameraEngine — open/close/dispose + snapshots

First slice of the Dart facade. Constructor + open() + close() + dispose
+ currentSettings + currentProcessingParameters. CameraException-rewrap
helper _guard wraps every method body.

lib/testing.dart now exposes CameraEngineTesting.create(api:) for unit
tests; production consumers only see CameraEngine() (zero-arg).

9 unit tests cover happy paths, error rewrapping, and dispose aliasing.

Per Phase B spec §4 'CameraEngine — public Dart API'."
```

---

### Task 17: `CameraEngine` — broadcast-cached streams

Five `Stream<T>` getters that wrap Pigeon `EventChannelApi` instances and cache the broadcast version. Re-subscribers see the same broadcast Stream.

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_streams_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_streams_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late CameraEngine engine;

  setUp(() {
    final api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  group('stateStream()', () {
    test('returns a broadcast Stream', () {
      final s = engine.stateStream();
      expect(s.isBroadcast, isTrue);
    });

    test('subsequent calls return the same Stream instance', () {
      expect(identical(engine.stateStream(), engine.stateStream()), isTrue);
    });

    test('SessionState.error passes through 1:1', () async {
      // We hand-pump the underlying broadcast controller via the testing seam:
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final values = <g.SessionState>[];
      final sub = engine.stateStream().listen(values.add);
      ctrl.add(g.SessionState.error);
      await pumpEventQueue();
      expect(values, [g.SessionState.error]);
      await sub.cancel();
    });

    test('two subscribers both receive events', () async {
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final a = <g.SessionState>[];
      final b = <g.SessionState>[];
      final subA = engine.stateStream().listen(a.add);
      final subB = engine.stateStream().listen(b.add);
      ctrl.add(g.SessionState.streaming);
      await pumpEventQueue();
      expect(a, [g.SessionState.streaming]);
      expect(b, [g.SessionState.streaming]);
      await subA.cancel();
      await subB.cancel();
    });

    test('error on subscriber A does not terminate subscriber B', () async {
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final b = <g.SessionState>[];
      final subA = engine.stateStream().listen(
        (_) => throw StateError('A throws'),
        onError: (_) {},
      );
      final subB = engine.stateStream().listen(b.add);
      ctrl.add(g.SessionState.streaming);
      await pumpEventQueue();
      expect(b, [g.SessionState.streaming]);
      await subA.cancel();
      await subB.cancel();
    });
  });

  group('errorStream()', () {
    test('emits CameraException, not Pigeon CameraError', () async {
      final ctrl = CameraEngineStreamsTesting.errorSource(engine);
      final values = <CameraException>[];
      final sub = engine.errorStream().listen(values.add);
      ctrl.add(g.CameraError(
        code: g.CameraErrorCode.frameStall,
        message: 'watchdog fired',
        isFatal: false,
      ));
      await pumpEventQueue();
      expect(values, hasLength(1));
      expect(values.first.code, CameraErrorCode.frameStall);
      expect(values.first.message, 'watchdog fired');
      await sub.cancel();
    });
  });

  group('recordingStateStream()', () {
    test('decodes idle / recording / finalizing', () async {
      final ctrl = CameraEngineStreamsTesting.recordingSource(engine);
      final values = <g.RecordingStateValue>[];
      final sub = engine.recordingStateStream().listen(values.add);
      ctrl.add(g.RecordingStateValue(kind: g.RecordingStateKind.idle, lastUri: '/tmp/x.mp4'));
      ctrl.add(g.RecordingStateValue(kind: g.RecordingStateKind.recording));
      ctrl.add(g.RecordingStateValue(kind: g.RecordingStateKind.finalizing));
      await pumpEventQueue();
      expect(values.map((v) => v.kind), [
        g.RecordingStateKind.idle,
        g.RecordingStateKind.recording,
        g.RecordingStateKind.finalizing,
      ]);
      expect(values.first.lastUri, '/tmp/x.mp4');
      await sub.cancel();
    });
  });
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd flutter && flutter test test/camera_engine_streams_test.dart
```
Expected: errors about missing methods `stateStream`, `errorStream`, `recordingStateStream`, and missing `CameraEngineStreamsTesting`.

- [ ] **Step 3: Add stream support to `camera_engine.dart`**

The Pigeon-generated `*EventApi` classes produce a `Stream<T>` from their `streamX()` method. We need to make the *source* mockable for tests, so the engine accepts injectable sources via the testing seam.

Append to `flutter/lib/src/camera_engine.dart`:

```dart
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart';
// (kept inline above — illustrative; the actual file imports are dedup'd)

// Inside class CameraEngine — augment existing fields:
//
//   final StreamController<g.SessionState> _stateSource = StreamController.broadcast();
//   final StreamController<g.CameraError> _errorSource = StreamController.broadcast();
//   final StreamController<g.StreamConfiguration> _streamCfgSource = StreamController.broadcast();
//   final StreamController<g.FrameResult> _frameSource = StreamController.broadcast();
//   final StreamController<g.RecordingStateValue> _recordingSource = StreamController.broadcast();
//
//   late final Stream<g.SessionState> _stateStream = _stateSource.stream.asBroadcastStream();
//   ... etc.
```

Replace the existing file contents with:

```dart
import 'dart:async';

import 'package:flutter/services.dart';

import 'camera_exception.dart';
import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

class CameraEngine {
  final g.CameraEngineHostApi _api;

  // Per-stream broadcast controllers; in production these are fed by
  // listening to the Pigeon EventChannelApi streams. In tests, the
  // CameraEngineStreamsTesting seam exposes them directly.
  final StreamController<g.SessionState> _stateSource =
      StreamController<g.SessionState>.broadcast();
  final StreamController<g.CameraError> _errorSource =
      StreamController<g.CameraError>.broadcast();
  final StreamController<g.StreamConfiguration> _cfgSource =
      StreamController<g.StreamConfiguration>.broadcast();
  final StreamController<g.FrameResult> _frameSource =
      StreamController<g.FrameResult>.broadcast();
  final StreamController<g.RecordingStateValue> _recordingSource =
      StreamController<g.RecordingStateValue>.broadcast();

  late final Stream<g.SessionState> _stateStream = _stateSource.stream;
  late final Stream<CameraException> _exceptionStream =
      _errorSource.stream.map(_cameraErrorToException);
  late final Stream<g.StreamConfiguration> _cfgStream = _cfgSource.stream;
  late final Stream<g.FrameResult> _frameStream = _frameSource.stream;
  late final Stream<g.RecordingStateValue> _recordingStream =
      _recordingSource.stream;

  StreamSubscription<g.SessionState>? _stateBridge;
  StreamSubscription<g.CameraError>? _errorBridge;
  StreamSubscription<g.StreamConfiguration>? _cfgBridge;
  StreamSubscription<g.FrameResult>? _frameBridge;
  StreamSubscription<g.RecordingStateValue>? _recordingBridge;

  CameraEngine() : _api = g.CameraEngineHostApi() {
    _wireProductionStreams();
  }
  CameraEngine._testing({required g.CameraEngineHostApi api}) : _api = api;

  void _wireProductionStreams() {
    _stateBridge = g.StateEventApi().streamState().listen(_stateSource.add);
    _errorBridge = g.ErrorEventApi().streamErrors().listen(_errorSource.add);
    _cfgBridge = g.StreamConfigurationEventApi()
        .streamStreamConfigurations()
        .listen(_cfgSource.add);
    _frameBridge =
        g.FrameResultEventApi().streamFrameResults().listen(_frameSource.add);
    _recordingBridge = g.RecordingStateEventApi()
        .streamRecordingStates()
        .listen(_recordingSource.add);
  }

  Future<g.SessionCapabilities> open([g.OpenConfiguration? config]) =>
      _guard(() => _api.open(config));

  Future<void> close() async {
    await _stateBridge?.cancel();
    await _errorBridge?.cancel();
    await _cfgBridge?.cancel();
    await _frameBridge?.cancel();
    await _recordingBridge?.cancel();
    _stateBridge = null;
    _errorBridge = null;
    _cfgBridge = null;
    _frameBridge = null;
    _recordingBridge = null;
    await _guard(_api.close);
  }

  Future<void> dispose() => close();

  Future<g.CameraSettings?> currentSettings() => _guard(_api.currentSettings);
  Future<g.ProcessingParameters?> currentProcessingParameters() =>
      _guard(_api.currentProcessingParameters);

  Stream<g.SessionState> stateStream() => _stateStream;
  Stream<CameraException> errorStream() => _exceptionStream;
  Stream<g.StreamConfiguration> streamConfigurationStream() => _cfgStream;
  Stream<g.FrameResult> frameResultStream() => _frameStream;
  Stream<g.RecordingStateValue> recordingStateStream() => _recordingStream;

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (pe) {
      throw CameraException.fromPlatformException(pe);
    }
  }

  static CameraException _cameraErrorToException(g.CameraError e) =>
      CameraException(
        code: parseCameraErrorCode(e.code.name),
        message: e.message,
        isFatal: e.isFatal,
      );

  // Test seam — used by lib/testing.dart's CameraEngineStreamsTesting helpers.
  StreamController<g.SessionState> get _stateSourceForTest => _stateSource;
  StreamController<g.CameraError> get _errorSourceForTest => _errorSource;
  StreamController<g.StreamConfiguration> get _cfgSourceForTest => _cfgSource;
  StreamController<g.FrameResult> get _frameSourceForTest => _frameSource;
  StreamController<g.RecordingStateValue> get _recordingSourceForTest =>
      _recordingSource;
}

CameraEngine cameraEngineMakeForTest({required g.CameraEngineHostApi api}) =>
    CameraEngine._testing(api: api);

StreamController<g.SessionState> cameraEngineStateSourceForTest(
        CameraEngine e) =>
    e._stateSourceForTest;
StreamController<g.CameraError> cameraEngineErrorSourceForTest(
        CameraEngine e) =>
    e._errorSourceForTest;
StreamController<g.StreamConfiguration> cameraEngineCfgSourceForTest(
        CameraEngine e) =>
    e._cfgSourceForTest;
StreamController<g.FrameResult> cameraEngineFrameSourceForTest(
        CameraEngine e) =>
    e._frameSourceForTest;
StreamController<g.RecordingStateValue> cameraEngineRecordingSourceForTest(
        CameraEngine e) =>
    e._recordingSourceForTest;
```

- [ ] **Step 4: Expand `lib/testing.dart`**

Add to `flutter/lib/testing.dart`:

```dart
import 'dart:async';
import 'src/camera_engine.dart' show
    CameraEngine,
    cameraEngineMakeForTest,
    cameraEngineStateSourceForTest,
    cameraEngineErrorSourceForTest,
    cameraEngineCfgSourceForTest,
    cameraEngineFrameSourceForTest,
    cameraEngineRecordingSourceForTest;
// (existing imports + PermissionsTesting stay)

abstract final class CameraEngineStreamsTesting {
  CameraEngineStreamsTesting._();
  static StreamController<g.SessionState> stateSource(CameraEngine e) =>
      cameraEngineStateSourceForTest(e);
  static StreamController<g.CameraError> errorSource(CameraEngine e) =>
      cameraEngineErrorSourceForTest(e);
  static StreamController<g.StreamConfiguration> cfgSource(CameraEngine e) =>
      cameraEngineCfgSourceForTest(e);
  static StreamController<g.FrameResult> frameSource(CameraEngine e) =>
      cameraEngineFrameSourceForTest(e);
  static StreamController<g.RecordingStateValue> recordingSource(
          CameraEngine e) =>
      cameraEngineRecordingSourceForTest(e);
}
```

- [ ] **Step 5: Run the streams test and verify it passes**

```bash
cd flutter && flutter test test/camera_engine_streams_test.dart
```
Expected: all tests pass.

- [ ] **Step 6: Verify the open/close test still passes after the refactor**

```bash
cd flutter && flutter test test/camera_engine_open_close_test.dart
```
Expected: still green.

- [ ] **Step 7: Commit**

```bash
git add flutter/lib/src/camera_engine.dart flutter/lib/testing.dart \
        flutter/test/camera_engine_streams_test.dart
git commit -m "feat(flutter): CameraEngine streams (broadcast cached)

Five Stream getters (stateStream, errorStream, streamConfigurationStream,
frameResultStream, recordingStateStream) each backed by a single
broadcast StreamController. Production constructor wires each controller
to the matching Pigeon EventChannelApi; close() cancels each bridge.

errorStream() emits CameraException (re-thrown from raw Pigeon
CameraError). Test seam CameraEngineStreamsTesting exposes the
underlying controllers for hand-pumping in unit tests.

Per Phase B spec §4 'Streams' and §7 'Stream broadcast caching'/'Stream
error propagation'."
```

---

### Task 18: `CameraEngine` — control methods

Adds `updateSettings`, `setResolution`, `setProcessingParams`, `setCropRegion`. All Pigeon-thin.

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_control_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_control_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('updateSettings delegates', () async {
    final s = g.CameraSettings(iso: 200);
    when(api.updateSettings(s)).thenAnswer((_) async {});
    await engine.updateSettings(s);
    verify(api.updateSettings(s)).called(1);
  });

  test('setResolution delegates', () async {
    when(api.setResolution(any)).thenAnswer((_) async {});
    await engine.setResolution(g.PSize(width: 1280, height: 720));
    verify(api.setResolution(any)).called(1);
  });

  test('setProcessingParams delegates', () async {
    final p = g.ProcessingParameters(
      brightness: 0, contrast: 1, saturation: 1,
      blackR: 0, blackG: 0, blackB: 0, gamma: 1,
    );
    when(api.setProcessingParams(p)).thenAnswer((_) async {});
    await engine.setProcessingParams(p);
    verify(api.setProcessingParams(p)).called(1);
  });

  test('setCropRegion delegates', () async {
    when(api.setCropRegion(any)).thenAnswer((_) async {});
    await engine.setCropRegion(g.PRect(x: 0, y: 0, width: 100, height: 100));
    verify(api.setCropRegion(any)).called(1);
  });

  test('per-method PlatformException rewraps to CameraException', () async {
    when(api.updateSettings(any)).thenThrow(
      PlatformException(code: 'settingsConflict', message: 'iso vs manual'),
    );
    expect(
      () => engine.updateSettings(g.CameraSettings()),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.settingsConflict)),
    );
  });

  test('engine stays usable after PlatformException', () async {
    when(api.setCropRegion(any)).thenThrow(
      PlatformException(code: 'invalidState', message: 'no'),
    );
    when(api.setResolution(any)).thenAnswer((_) async {});
    try {
      await engine.setCropRegion(g.PRect(x: 0, y: 0, width: 1, height: 1));
    } catch (_) {}
    await engine.setResolution(g.PSize(width: 1280, height: 720)); // must not throw
  });
}
```

- [ ] **Step 2: Verify the test fails**

Expected: methods missing.

- [ ] **Step 3: Add the methods to `camera_engine.dart`**

```dart
  Future<void> updateSettings(g.CameraSettings settings) =>
      _guard(() => _api.updateSettings(settings));

  Future<void> setResolution(g.PSize size) =>
      _guard(() => _api.setResolution(size));

  Future<void> setProcessingParams(g.ProcessingParameters params) =>
      _guard(() => _api.setProcessingParams(params));

  Future<void> setCropRegion(g.PRect rect) =>
      _guard(() => _api.setCropRegion(rect));
```

- [ ] **Step 4: Run + commit**

```bash
cd flutter && flutter test test/camera_engine_control_test.dart
git add flutter/lib/src/camera_engine.dart flutter/test/camera_engine_control_test.dart
git commit -m "feat(flutter): CameraEngine control methods + error-resilience tests

Four delegating methods: updateSettings, setResolution, setProcessingParams,
setCropRegion. Includes a regression test asserting an engine remains usable
after a per-method PlatformException (Phase B spec §7 'Engine resilience').

Per Phase B spec §4 'Control'."
```

---

### Task 19: `CameraEngine` — capture

`captureImage` + `captureNaturalPicture`. Returns a filesystem path string.

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_capture_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_capture_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('captureImage returns the path, defaults photosDestination to none',
      () async {
    when(api.captureImage(null, g.PhotosDestination.none))
        .thenAnswer((_) async => '/var/mobile/.../img-001.heic');
    final path = await engine.captureImage();
    expect(path, '/var/mobile/.../img-001.heic');
    verify(api.captureImage(null, g.PhotosDestination.none)).called(1);
  });

  test('captureImage passes outputPath through', () async {
    when(api.captureImage('/tmp/x.heic', g.PhotosDestination.copy))
        .thenAnswer((_) async => '/tmp/x.heic');
    await engine.captureImage(
      outputPath: '/tmp/x.heic',
      photosDestination: g.PhotosDestination.copy,
    );
    verify(api.captureImage('/tmp/x.heic', g.PhotosDestination.copy)).called(1);
  });

  test('captureNaturalPicture delegates', () async {
    when(api.captureNaturalPicture(null, g.PhotosDestination.none))
        .thenAnswer((_) async => '/var/mobile/natural.heic');
    expect(await engine.captureNaturalPicture(), '/var/mobile/natural.heic');
  });

  test('captureImage rewraps PlatformException', () async {
    when(api.captureImage(any, any)).thenThrow(
      PlatformException(code: 'captureFailure', message: 'shutter glitch'),
    );
    expect(
      () => engine.captureImage(),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.captureFailure)),
    );
  });
}
```

- [ ] **Step 2: Verify it fails, then add methods to `camera_engine.dart`**

```dart
  Future<String> captureImage({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureImage(outputPath, photosDestination));

  Future<String> captureNaturalPicture({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureNaturalPicture(outputPath, photosDestination));
```

- [ ] **Step 3: Run + commit**

```bash
cd flutter && flutter test test/camera_engine_capture_test.dart
git add flutter/lib/src/camera_engine.dart flutter/test/camera_engine_capture_test.dart
git commit -m "feat(flutter): CameraEngine capture (captureImage + captureNaturalPicture)

Returns an absolute filesystem path inside the app sandbox.
photosDestination defaults to .none (the recording lives only on disk
unless the consumer opts into Photos publishing).

Per Phase B spec §4 'Capture'."
```

---

### Task 20: `CameraEngine` — recording

`startRecording` + `stopRecording`. No pause/resume (CameraKit doesn't have them — Phase B spec §4).

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_recording_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_recording_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('startRecording returns RecordingStart on success', () async {
    final start = g.RecordingStart(uri: 'file:///tmp/x.mp4', displayName: 'x.mp4');
    when(api.startRecording(any)).thenAnswer((_) async => start);
    final s = await engine.startRecording(g.RecordingOptions(
      photosDestination: g.PhotosDestination.none,
    ));
    expect(s.uri, 'file:///tmp/x.mp4');
    expect(s.displayName, 'x.mp4');
  });

  test('stopRecording returns the uri string', () async {
    when(api.stopRecording()).thenAnswer((_) async => 'file:///tmp/x.mp4');
    expect(await engine.stopRecording(), 'file:///tmp/x.mp4');
  });

  test('startRecording rewraps PlatformException', () async {
    when(api.startRecording(any)).thenThrow(
      PlatformException(code: 'recordingStartFailed', message: 'asset writer err'),
    );
    expect(
      () => engine.startRecording(g.RecordingOptions(
        photosDestination: g.PhotosDestination.none,
      )),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.recordingStartFailed)),
    );
  });
}
```

- [ ] **Step 2: Verify failure, add methods, run + commit**

```dart
  Future<g.RecordingStart> startRecording(g.RecordingOptions options) =>
      _guard(() => _api.startRecording(options));

  Future<String> stopRecording() => _guard(_api.stopRecording);
```

```bash
cd flutter && flutter test test/camera_engine_recording_test.dart
git add flutter/lib/src/camera_engine.dart flutter/test/camera_engine_recording_test.dart
git commit -m "feat(flutter): CameraEngine recording (start/stop only)

No pause/resume — CameraKit has no recording-pause API (production-dead
.pause path removed 2026-05-22). To pause filming, the consumer calls
stopRecording() and starts a fresh recording on resume.

Per Phase B spec §4 'Recording'."
```

---

### Task 21: `CameraEngine` — calibration

Two thin delegations.

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_calibration_test.dart`

- [ ] **Step 1: Test + impl + commit**

```dart
// flutter/test/camera_engine_calibration_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

g.CalibrationResult _fakeResult() => g.CalibrationResult(
      before: g.RgbSample(r: 0.5, g: 0.5, b: 0.5),
      after: g.RgbSample(r: 0.5, g: 0.5, b: 0.5),
      converged: true,
      iterations: 1,
    );

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('calibrateWhiteBalance returns CalibrationResult', () async {
    final r = _fakeResult();
    when(api.calibrateWhiteBalance()).thenAnswer((_) async => r);
    expect(await engine.calibrateWhiteBalance(), r);
  });
  test('calibrateBlackBalance returns CalibrationResult', () async {
    final r = _fakeResult();
    when(api.calibrateBlackBalance()).thenAnswer((_) async => r);
    expect(await engine.calibrateBlackBalance(), r);
  });
}
```

Append to `camera_engine.dart`:

```dart
  Future<g.CalibrationResult> calibrateWhiteBalance() =>
      _guard(_api.calibrateWhiteBalance);

  Future<g.CalibrationResult> calibrateBlackBalance() =>
      _guard(_api.calibrateBlackBalance);
```

```bash
cd flutter && flutter test test/camera_engine_calibration_test.dart
git add flutter/lib/src/camera_engine.dart flutter/test/camera_engine_calibration_test.dart
git commit -m "feat(flutter): CameraEngine calibration (white + black balance)

Per Phase B spec §4 'Calibration'."
```

---

### Task 22: `CameraEngine` — texture bridge

`createPreviewTexture(stream:)` + `destroyPreviewTexture(id)`. Tests cover the texture-map race + lifecycle bookkeeping.

**Files:**
- Modify: `flutter/lib/src/camera_engine.dart`
- Create: `flutter/test/camera_engine_texture_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// flutter/test/camera_engine_texture_test.dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart' as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('createPreviewTexture returns the textureId from HostApi', () async {
    when(api.createPreviewTexture(g.StreamId.processed))
        .thenAnswer((_) async => 42);
    expect(await engine.createPreviewTexture(stream: g.StreamId.processed), 42);
  });

  test('createPreviewTexture for natural lane returns its own id', () async {
    when(api.createPreviewTexture(g.StreamId.processed))
        .thenAnswer((_) async => 42);
    when(api.createPreviewTexture(g.StreamId.natural))
        .thenAnswer((_) async => 43);
    final a = await engine.createPreviewTexture(stream: g.StreamId.processed);
    final b = await engine.createPreviewTexture(stream: g.StreamId.natural);
    expect(a, isNot(b));
  });

  test('destroyPreviewTexture delegates', () async {
    when(api.destroyPreviewTexture(7)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(7);
    verify(api.destroyPreviewTexture(7)).called(1);
  });

  test('destroy before create completes — destroy with -1 sentinel is allowed',
      () async {
    when(api.destroyPreviewTexture(-1)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(-1);
    verify(api.destroyPreviewTexture(-1)).called(1);
  });

  test('destroy twice with the same id is idempotent from Dart POV', () async {
    when(api.destroyPreviewTexture(7)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(7);
    await engine.destroyPreviewTexture(7);
    verify(api.destroyPreviewTexture(7)).called(2); // adapter no-ops the second
  });

  // Note: per Phase B spec §3 "Open-state coupling", createPreviewTexture
  // pre-open returns a valid texture id (no notOpen error). The Dart facade
  // delegates 1:1; this is verified at the adapter layer in
  // flutter/example/ios/RunnerTests/TextureMapTests.swift.

  test('createPreviewTexture rewraps unrelated PlatformException', () async {
    // E.g. an unexpected hardware error during registration; the Dart facade
    // still has to surface it as CameraException.
    when(api.createPreviewTexture(any))
        .thenThrow(PlatformException(code: 'hardwareError', message: 'metal device init failed'));
    expect(
      () => engine.createPreviewTexture(stream: g.StreamId.processed),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.hardwareError)),
    );
  });
}
```

- [ ] **Step 2: Verify failure, add methods**

```dart
  Future<int> createPreviewTexture({required g.StreamId stream}) =>
      _guard(() => _api.createPreviewTexture(stream));

  Future<void> destroyPreviewTexture(int textureId) =>
      _guard(() => _api.destroyPreviewTexture(textureId));
```

- [ ] **Step 3: Run + commit**

```bash
cd flutter && flutter test test/camera_engine_texture_test.dart
git add flutter/lib/src/camera_engine.dart flutter/test/camera_engine_texture_test.dart
git commit -m "feat(flutter): CameraEngine texture bridge (create/destroy)

Returns an int textureId for the consumer to feed into a Flutter
Texture widget. Destroy is idempotent from the Dart POV — the adapter
no-ops unknown ids. Idiomatic consumer pattern: create after open(),
destroy before close() (covered in example app, Task 31).

Per Phase B spec §4 'Texture bridge' and §3 'Lifecycle'."
```

---

### Task 23: Public library export — `cambrian_ios_camera.dart`

Final polish — re-export everything consumers need, hide everything they shouldn't see. Most of this already exists incrementally; this task adds anything missing and runs a full test sweep.

**Files:**
- Modify: `flutter/lib/cambrian_ios_camera.dart`

- [ ] **Step 1: Lock the public surface**

The umbrella from Tasks 14-16 is mostly complete. Confirm the final state matches:

```dart
// flutter/lib/cambrian_ios_camera.dart

// Public exception type + code enum.
export 'src/camera_exception.dart';

// Static permissions API.
export 'src/permissions.dart' show Permissions, CameraPermissionStatus;

// Engine.
export 'src/camera_engine.dart' show CameraEngine;

// Pigeon-generated value types consumers construct or destructure directly.
// Generated enums kept; testing seam (_testing) hidden because internal.
export 'src/pigeon/cambrian_ios_camera_api.g.dart' show
    OpenConfiguration,
    SessionCapabilities,
    CameraSettings,
    ProcessingParameters,
    StreamConfiguration,
    FrameResult,
    RecordingOptions,
    RecordingStart,
    RecordingStateValue,
    RecordingStateKind,
    CalibrationResult,
    RgbSample,
    CameraError,
    PSize,
    PRect,
    StreamId,
    SessionState,
    PhotosDestination,
    CameraMode,
    WhiteBalanceMode;
```

- [ ] **Step 2: Run the entire Dart test suite**

```bash
cd flutter && flutter test
```
Expected: every test from Tasks 13-22 passes. (~35-40 tests total. Exact count depends on parameterized loops.)

- [ ] **Step 3: Verify analyzer**

```bash
cd flutter && dart analyze
```
Expected: `No issues found!`. If the Pigeon-generated file flags warnings, add it to `analysis_options.yaml`:

```yaml
analyzer:
  exclude:
    - lib/src/pigeon/cambrian_ios_camera_api.g.dart
    - test/mocks/*.mocks.dart
```

- [ ] **Step 4: Commit**

```bash
git add flutter/lib/cambrian_ios_camera.dart flutter/analysis_options.yaml
git commit -m "chore(flutter): finalize public library exports

Locks the public surface: CameraEngine, Permissions, CameraException,
CameraErrorCode, all relevant Pigeon-generated value types. Internal
test seams in lib/testing.dart remain importable only via the explicit
'package:cambrian_ios_camera/testing.dart' path.

flutter test green; dart analyze clean.

Per Phase B spec §4 'Library structure'."
```

---

## Phase 6: Swift adapter XCTest

These tests run on the iPad against the example app's host. Until the example app scaffold lands (Task 28), the `RunnerTests/` target doesn't exist. **Order requirement:** Phase 7's Task 28 (example scaffold) must run *before* this phase's Task 24.

> The plan presents Phase 6 before Phase 7 because the tests *conceptually* cover the iOS adapter from Phase 3. In execution, do Task 28 first, then return here for Tasks 24-27, then continue with Tasks 29-37 in Phase 7.

### Task 24: Set up `flutter/example/ios/RunnerTests/` target

Adds the XCTest target to the example's `Runner.xcodeproj` and creates a `MockCameraEngine` test double.

**Prereq:** Task 28 has been run.

**Files:**
- Modify: `flutter/example/ios/Runner.xcodeproj/project.pbxproj` (via xcodeproj gem)
- Create: `flutter/example/ios/RunnerTests/Info.plist`
- Create: `flutter/example/ios/RunnerTests/MockCameraEngine.swift`

- [ ] **Step 1: Add the XCTest target via xcodeproj**

`flutter/example/ios/add-runner-tests-target.rb`:

```ruby
require 'xcodeproj'

PROJECT_PATH = 'Runner.xcodeproj'
proj = Xcodeproj::Project.open(PROJECT_PATH)

# Idempotent: skip if RunnerTests already exists.
if proj.targets.any? { |t| t.name == 'RunnerTests' }
  puts 'RunnerTests target already exists; skipping.'
  exit 0
end

runner = proj.targets.find { |t| t.name == 'Runner' } or
  abort 'Runner target not found'

tests = proj.new_target(:unit_test_bundle, 'RunnerTests', :ios, '26.0', nil, :swift)
tests.build_configurations.each do |bc|
  bc.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Runner.app/Runner'
  bc.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  bc.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  bc.build_settings['SWIFT_VERSION'] = '6.0'
  bc.build_settings['INFOPLIST_FILE'] = 'RunnerTests/Info.plist'
  bc.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    'com.cambrian.cambrianCameraExample.RunnerTests'
end

# Link against Runner so we can @testable import Runner — and against the
# plugin's iOS framework so we can address its types directly.
tests.add_dependency(runner)

group = proj.main_group.find_subpath('RunnerTests', true)
group.set_source_tree('<group>')
Dir.glob('RunnerTests/*.swift').each do |f|
  ref = group.new_file(File.basename(f))
  tests.add_file_references([ref])
end

# Add the test scheme.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(runner)
scheme.add_test_target(tests)
scheme.save_as(PROJECT_PATH, 'RunnerTests')

proj.save
puts 'RunnerTests target added.'
```

Run:
```bash
cd flutter/example/ios && ruby add-runner-tests-target.rb
```
Expected: prints `RunnerTests target added.`

- [ ] **Step 2: Write `RunnerTests/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
```

- [ ] **Step 3: Write the `MockCameraEngine`**

`flutter/example/ios/RunnerTests/MockCameraEngine.swift`:

```swift
import Foundation
@testable import cambrian_ios_camera
import CameraKit

/// In-memory mock that records calls and produces canned responses.
/// Conforms to CameraEngineProtocol via member parity — adding a new
/// protocol method here fails to compile until the mock implements it.
actor MockCameraEngine: CameraEngineProtocol {
    var phaseHistory: [AppLifecyclePhase] = []
    var lastConfig: OpenConfiguration?
    var openCalls = 0
    var closeCalls = 0
    var pixelBufferProvider: ((StreamId) -> CVPixelBuffer?) = { _ in nil }
    var openResult: SessionCapabilities = MockCameraEngine.placeholderCaps()
    var startResult: RecordingStart = RecordingStart(uri: "file:///tmp/r.mp4", displayName: "r.mp4")
    var stopResult: String = "file:///tmp/r.mp4"

    static func placeholderCaps() -> SessionCapabilities {
        SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 1,
            naturalTextureId: 2,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: "BGRA8",
            isoRange: 50.0...3200.0,
            exposureDurationRangeNs: 100_000...33_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...8.0,
            evCompensationRange: -8.0...8.0
        )
    }

    func setLifecyclePhase(_ phase: AppLifecyclePhase) async { phaseHistory.append(phase) }
    func open(configuration: OpenConfiguration) async throws -> SessionCapabilities {
        openCalls += 1
        lastConfig = configuration
        return openResult
    }
    func close() async { closeCalls += 1 }
    func currentSettingsSnapshot() -> CameraSettings? { nil }
    func currentProcessingParametersSnapshot() -> ProcessingParameters? { nil }
    func stateStream() -> AsyncStream<SessionState> { AsyncStream { _ in } }
    func errorStream() -> AsyncStream<CameraError> { AsyncStream { _ in } }
    func streamConfigurationStream() -> AsyncStream<StreamConfiguration> { AsyncStream { _ in } }
    func frameResultStream() -> AsyncStream<FrameResult> { AsyncStream { _ in } }
    func recordingStateStream() -> AsyncStream<RecordingState> { AsyncStream { _ in } }
    func updateSettings(_ settings: CameraSettings) async throws {}
    func setResolution(size: Size) async throws {}
    func setProcessingParams(_ params: ProcessingParameters) async {}
    func setCropRegion(_ rect: Rect) async throws {}
    func captureImage(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput {
        StillCaptureOutput(filePath: outputURL?.path ?? "/tmp/x.heic")
    }
    func captureNaturalPicture(outputURL: URL?, photosDestination: PhotosDestination) async throws -> StillCaptureOutput {
        StillCaptureOutput(filePath: outputURL?.path ?? "/tmp/n.heic")
    }
    func startRecording(options: RecordingOptions) async throws -> RecordingStart { startResult }
    func stopRecording() async throws -> String { stopResult }
    func calibrateWhiteBalance() async throws -> CalibrationResult {
        let s = RgbSample(r: 0.5, g: 0.5, b: 0.5)
        return CalibrationResult(before: s, after: s, converged: true, iterations: 1)
    }
    func calibrateBlackBalance() async throws -> CalibrationResult {
        let s = RgbSample(r: 0.0, g: 0.0, b: 0.0)
        return CalibrationResult(before: s, after: s, converged: true, iterations: 1)
    }
    nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer? { nil }
    nonisolated var consumers: ConsumerRegistry { ConsumerRegistry() }
}
```

- [ ] **Step 4: Build to verify target compiles**

Via XcodeBuildMCP:
```
mcp__XcodeBuildMCP__session_set_defaults { projectPath: "flutter/example/ios/Runner.xcodeproj", scheme: "RunnerTests", deviceId: "<your iPad UDID>" }
mcp__XcodeBuildMCP__build_device
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add flutter/example/ios/Runner.xcodeproj/project.pbxproj \
        flutter/example/ios/RunnerTests/Info.plist \
        flutter/example/ios/RunnerTests/MockCameraEngine.swift \
        flutter/example/ios/add-runner-tests-target.rb
git commit -m "test(adapter): scaffold RunnerTests XCTest target + MockCameraEngine

XCTest target wired via xcodeproj gem (idempotent script); MockCameraEngine
actor conforms to CameraEngineProtocol via member parity. The four
adapter tests (scene-callback dispatch, texture map create/destroy,
destroy-twice, engine-not-open guard) land in the next commits.

Per Phase B spec §7 'Swift adapter tests'."
```

---

### Task 25: Scene-callback dispatch test

Each UIScene callback selector must call `engine.setLifecyclePhase(.<phase>)` exactly once.

**Files:**
- Create: `flutter/example/ios/RunnerTests/SceneLifecycleTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import cambrian_ios_camera
@testable import Runner
import Flutter
import CameraKit

final class SceneLifecycleTests: XCTestCase {
    final class StubRegistrar: NSObject, FlutterPluginRegistrar {
        // Minimal stub — only `messenger()` and `textures()` are touched
        // during this test.
        func messenger() -> any FlutterBinaryMessenger { StubBinaryMessenger() }
        func textures() -> any FlutterTextureRegistry { StubTextureRegistry() }
        func publish(_ value: NSObjectProtocol) {}
        func addMethodCallDelegate(_ delegate: any FlutterPlugin, channel: FlutterMethodChannel) {}
        func addApplicationDelegate(_ delegate: any FlutterPlugin) {}
        func lookupKey(forAsset asset: String) -> String { asset }
        func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
        func register(_ factory: any FlutterPlatformViewFactory, withId factoryId: String) {}
    }
    final class StubBinaryMessenger: NSObject, FlutterBinaryMessenger {
        func send(onChannel channel: String, message: Data?) {}
        func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil) {}
        func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil) -> FlutterBinaryMessengerConnection { 0 }
        func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
    }
    final class StubTextureRegistry: NSObject, FlutterTextureRegistry {
        func register(_ texture: any FlutterTexture) -> Int64 { 1 }
        func textureFrameAvailable(_ textureId: Int64) {}
        func unregisterTexture(_ textureId: Int64) {}
    }

    func test_sceneDidBecomeActive_setsPhaseActive() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        let scene = UIScene() // bare UIScene; the callback ignores `scene`.
        plugin.sceneDidBecomeActive(scene)
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.active])
    }

    func test_sceneWillResignActive_setsPhaseInactive() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        plugin.sceneWillResignActive(UIScene())
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.inactive])
    }

    func test_sceneDidEnterBackground_setsPhaseBackground() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        plugin.sceneDidEnterBackground(UIScene())
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.background])
    }
}
```

- [ ] **Step 2: Wire the file into the RunnerTests target**

```bash
cd flutter/example/ios && ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('Runner.xcodeproj')
t = p.targets.find { |t| t.name == 'RunnerTests' }
g = p.main_group.find_subpath('RunnerTests', false)
ref = g.new_file('SceneLifecycleTests.swift')
t.add_file_references([ref])
p.save"
```

- [ ] **Step 3: Run the test via XcodeBuildMCP**

```
mcp__XcodeBuildMCP__test_device with extraArgs: ["-only-testing:RunnerTests/SceneLifecycleTests"]
```
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add flutter/example/ios/RunnerTests/SceneLifecycleTests.swift \
        flutter/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "test(adapter): scene-callback dispatch tests (3)

Asserts sceneDidBecomeActive / sceneWillResignActive / sceneDidEnterBackground
each invoke engine.setLifecyclePhase with the correct AppLifecyclePhase.

Per Phase B spec §7 'Scene-callback dispatch'."
```

---

### Task 26: Texture map tests

Three tests: create+lookup, destroy, destroy-twice.

**Files:**
- Create: `flutter/example/ios/RunnerTests/TextureMapTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import XCTest
@testable import cambrian_ios_camera
import Flutter

final class TextureMapTests: XCTestCase {
    final class RecordingTextureRegistry: NSObject, FlutterTextureRegistry {
        var nextId: Int64 = 100
        var registered: [Int64: any FlutterTexture] = [:]
        var unregistered: [Int64] = []

        func register(_ texture: any FlutterTexture) -> Int64 {
            let id = nextId
            nextId += 1
            registered[id] = texture
            return id
        }
        func textureFrameAvailable(_ textureId: Int64) {}
        func unregisterTexture(_ textureId: Int64) {
            unregistered.append(textureId)
            registered.removeValue(forKey: textureId)
        }
    }
    final class StubRegistrar: NSObject, FlutterPluginRegistrar {
        let textureRegistry = RecordingTextureRegistry()
        func messenger() -> any FlutterBinaryMessenger { SceneLifecycleTests.StubBinaryMessenger() }
        func textures() -> any FlutterTextureRegistry { textureRegistry }
        func publish(_ value: NSObjectProtocol) {}
        func addMethodCallDelegate(_ d: any FlutterPlugin, channel: FlutterMethodChannel) {}
        func addApplicationDelegate(_ d: any FlutterPlugin) {}
        func lookupKey(forAsset asset: String) -> String { asset }
        func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
        func register(_ f: any FlutterPlatformViewFactory, withId id: String) {}
    }

    func test_createPreviewTexture_registers_and_stores() async throws {
        let registrar = StubRegistrar()
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: registrar, engine: mock)
        let exp = expectation(description: "create completes")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { result in
            if case .success(let value) = result { id = value }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertGreaterThan(id, 0)
        XCTAssertNotNil(registrar.textureRegistry.registered[id])
        XCTAssertNotNil(plugin.textures[id])
    }

    /// Per Phase B spec §3 "Open-state coupling": createPreviewTexture
    /// before open() returns a texture id without error. The texture's
    /// copyPixelBuffer returns nil until the engine is wired.
    func test_createPreviewTexture_before_open_succeeds() async throws {
        let registrar = StubRegistrar()
        let plugin = CambrianIosCameraPlugin(registrar: registrar, engine: nil)
        let exp = expectation(description: "create completes")
        var id: Int64 = -1
        var failure: Error?
        plugin.createPreviewTexture(stream: .processed) { result in
            switch result {
            case .success(let value): id = value
            case .failure(let e):     failure = e
            }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertNil(failure, "expected success; got \(String(describing: failure))")
        XCTAssertGreaterThan(id, 0)
        // copyPixelBuffer at this point must return nil — no crash.
        let tex = registrar.textureRegistry.registered[id]
        XCTAssertNotNil(tex)
        XCTAssertNil(tex?.copyPixelBuffer())
    }

    func test_destroyPreviewTexture_unregisters_and_clears_map() async throws {
        let registrar = StubRegistrar()
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: registrar, engine: mock)
        let createExp = expectation(description: "create")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { r in
            if case .success(let v) = r { id = v }
            createExp.fulfill()
        }
        await fulfillment(of: [createExp], timeout: 1.0)
        let destroyExp = expectation(description: "destroy")
        plugin.destroyPreviewTexture(textureId: id) { _ in destroyExp.fulfill() }
        await fulfillment(of: [destroyExp], timeout: 1.0)
        XCTAssertNil(plugin.textures[id])
        XCTAssertTrue(registrar.textureRegistry.unregistered.contains(id))
    }

    func test_destroyTwice_is_idempotent() async throws {
        let registrar = StubRegistrar()
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: registrar, engine: mock)
        let exp1 = expectation(description: "create")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { r in
            if case .success(let v) = r { id = v }; exp1.fulfill()
        }
        await fulfillment(of: [exp1], timeout: 1.0)
        let exp2 = expectation(description: "destroy 1")
        plugin.destroyPreviewTexture(textureId: id) { _ in exp2.fulfill() }
        await fulfillment(of: [exp2], timeout: 1.0)
        let exp3 = expectation(description: "destroy 2")
        plugin.destroyPreviewTexture(textureId: id) { result in
            XCTAssertNotNil(try? result.get()) // success
            exp3.fulfill()
        }
        await fulfillment(of: [exp3], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Wire + run + commit**

```bash
cd flutter/example/ios && ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('Runner.xcodeproj')
t = p.targets.find { |t| t.name == 'RunnerTests' }
g = p.main_group.find_subpath('RunnerTests', false)
[g.new_file('TextureMapTests.swift')].each { |r| t.add_file_references([r]) }
p.save"
```

Run via `mcp__XcodeBuildMCP__test_device` with `extraArgs: ["-only-testing:RunnerTests/TextureMapTests"]`.

```bash
git add flutter/example/ios/RunnerTests/TextureMapTests.swift \
        flutter/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "test(adapter): texture map lifecycle (4)

createPreviewTexture registers a FlutterTexture and stores (id, Task)
in the textures map. destroyPreviewTexture cancels the task, unregisters
the texture, removes the entry. destroy-twice is idempotent.

Adds coverage for the spec §3 'Open-state coupling' clause: pre-open
createPreviewTexture returns a valid id without error; copyPixelBuffer
returns nil until the engine is wired.

Per Phase B spec §7 'Texture map' and §3 'Open-state coupling'."
```

---

### Task 27: Engine-not-open guard test

Asserts an HostApi method called pre-`open()` fails with `.notOpen`.

**Files:**
- Create: `flutter/example/ios/RunnerTests/NotOpenGuardTests.swift`

- [ ] **Step 1: Test + wire + run + commit**

```swift
import XCTest
@testable import cambrian_ios_camera
import Flutter

final class NotOpenGuardTests: XCTestCase {
    final class StubRegistrar: NSObject, FlutterPluginRegistrar {
        func messenger() -> any FlutterBinaryMessenger { SceneLifecycleTests.StubBinaryMessenger() }
        func textures() -> any FlutterTextureRegistry { SceneLifecycleTests.StubTextureRegistry() }
        func publish(_ value: NSObjectProtocol) {}
        func addMethodCallDelegate(_ d: any FlutterPlugin, channel: FlutterMethodChannel) {}
        func addApplicationDelegate(_ d: any FlutterPlugin) {}
        func lookupKey(forAsset asset: String) -> String { asset }
        func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
        func register(_ f: any FlutterPlatformViewFactory, withId id: String) {}
    }

    func test_updateSettings_before_open_returns_notOpen_FlutterError() {
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: nil)
        let exp = expectation(description: "completion")
        plugin.updateSettings(settings: CameraSettings()) { result in
            if case .failure(let err) = result, let fe = err as? FlutterError {
                XCTAssertEqual(fe.code, "notOpen")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }

    func test_captureImage_before_open_returns_notOpen() {
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: nil)
        let exp = expectation(description: "completion")
        plugin.captureImage(outputPath: nil, photosDestination: .none) { result in
            if case .failure(let err) = result, let fe = err as? FlutterError {
                XCTAssertEqual(fe.code, "notOpen")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
}
```

```bash
cd flutter/example/ios && ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('Runner.xcodeproj')
t = p.targets.find { |t| t.name == 'RunnerTests' }
g = p.main_group.find_subpath('RunnerTests', false)
[g.new_file('NotOpenGuardTests.swift')].each { |r| t.add_file_references([r]) }
p.save"
```

Run `mcp__XcodeBuildMCP__test_device` with `extraArgs: ["-only-testing:RunnerTests"]` (full RunnerTests suite). Expected: 9 tests pass total (3 SceneLifecycle + 4 TextureMap + 2 NotOpenGuard).

```bash
git add flutter/example/ios/RunnerTests/NotOpenGuardTests.swift \
        flutter/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "test(adapter): engine-not-open guard (2)

Pre-open HostApi method calls return FlutterError(code: 'notOpen').
Tests updateSettings + captureImage as representative guard sites.

Full RunnerTests suite is now 9 tests.

Per Phase B spec §7 'Engine-not-open guard'."
```

---

## Phase 7: Example app

### Task 28: Generate the Flutter example scaffold + reshape

Use `flutter create` to generate the standard plugin example structure, then trim/customize. This task lands the bare bones (pubspec, AppDelegate, Info.plist, an empty `main.dart`); widgets come in later tasks.

**Files:**
- Create: entire `flutter/example/` directory tree via `flutter create`

- [ ] **Step 1: Generate the example scaffold**

From the repo root:
```bash
cd flutter && flutter create --template=app --platforms=ios,android \
    --org com.cambrian --project-name cambrianCameraExample \
    --no-pub example
```

This creates `flutter/example/` with the standard Flutter app layout.

- [ ] **Step 2: Replace `flutter/example/pubspec.yaml`**

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
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter

flutter:
  uses-material-design: true
```

- [ ] **Step 3: Customize `flutter/example/ios/Runner/Info.plist`**

Add two camera-related keys. Find the `<dict>` and insert:

```xml
<key>NSCameraUsageDescription</key>
<string>Example app uses the camera to demonstrate cambrian_ios_camera.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Example app saves captures to your Photos library.</string>
<key>UIApplicationSceneManifest</key>
<dict>
  <key>UIApplicationSupportsMultipleScenes</key>
  <false/>
  <key>UISceneConfigurations</key>
  <dict>
    <key>UIWindowSceneSessionRoleApplication</key>
    <array>
      <dict>
        <key>UISceneConfigurationName</key>
        <string>Default Configuration</string>
        <key>UISceneDelegateClassName</key>
        <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
      </dict>
    </array>
  </dict>
</dict>
```

> The `UISceneDelegateClassName` is set to `Runner.SceneDelegate` (defined in the next step). The plugin's `addApplicationDelegate(self)` registration ensures its scene callback selectors are forwarded by the SceneDelegate.

- [ ] **Step 4: Write `flutter/example/ios/Runner/AppDelegate.swift`**

```swift
import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
```

- [ ] **Step 5: Write the SceneDelegate**

`flutter/example/ios/Runner/SceneDelegate.swift`:

```swift
import UIKit
import Flutter

class SceneDelegate: FlutterSceneDelegate {
    // Empty. The plugin's `register(with:)` adds itself as a UIWindowSceneDelegate
    // via registrar.addApplicationDelegate(self); FlutterSceneDelegate (Flutter's
    // own base class) forwards scene callbacks to registered delegates.
}
```

> **Flutter version note:** `FlutterSceneDelegate` is available in Flutter 3.22+. If your version doesn't have it, fall back to `UIResponder, UIWindowSceneDelegate` and forward callbacks manually to `(application as? FlutterAppDelegate)?.pluginRegistry().registrar(...)` — but the standard Flutter scene-delegate path is preferred.

- [ ] **Step 6: Wire SceneDelegate.swift into Runner.xcodeproj**

```bash
cd flutter/example/ios && ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('Runner.xcodeproj')
t = p.targets.find { |t| t.name == 'Runner' }
g = p.main_group.find_subpath('Runner', false)
ref = g.new_file('SceneDelegate.swift')
t.add_file_references([ref])
p.save"
```

- [ ] **Step 7: Replace `flutter/example/lib/main.dart` with placeholder**

```dart
import 'package:flutter/material.dart';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'cambrian_ios_camera example',
        home: const Scaffold(body: Center(child: Text('TODO: CameraScreen'))),
      );
}
```

This placeholder lets us run `flutter test`/`flutter run` immediately; the real CameraScreen lands in Task 36.

- [ ] **Step 8: Replace `flutter/example/test/widget_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('placeholder mounts', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const Scaffold()));
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
```

- [ ] **Step 9: Get Pods + smoke `flutter pub get`**

```bash
cd flutter/example && flutter pub get
cd ios && pod install
```
Expected: succeeds. Now Task 24's `xcodeproj` script can locate `Runner.xcodeproj`.

- [ ] **Step 10: Commit**

```bash
git add flutter/example/
git commit -m "feat(example): scaffold Flutter example app

Standard 'flutter create' template, customized to depend on the plugin
via path: ../. Adds NSCameraUsageDescription, NSPhotoLibraryAddUsageDescription,
UIApplicationSceneManifest with a SceneDelegate. Placeholder main.dart;
CameraScreen lands in Task 36.

This commit unblocks Phase 6's RunnerTests target setup."
```

---

### Task 29: `PermissionGate` widget

A widget that gates the rest of the screen behind camera permission.

**Files:**
- Create: `flutter/example/lib/widgets/permission_gate.dart`
- Create: `flutter/example/test/widgets/permission_gate_test.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/permission_gate.dart
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Shows `granted` when camera permission is `.authorized`. Otherwise shows
/// a Grant button that requests permission and (if granted) re-renders into
/// the granted state.
class PermissionGate extends StatefulWidget {
  final Widget granted;
  const PermissionGate({super.key, required this.granted});
  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  CameraPermissionStatus? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await Permissions.cameraPermissionStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _request() async {
    final s = await Permissions.requestCameraPermission();
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (s == null) return const Center(child: CircularProgressIndicator());
    if (s == CameraPermissionStatus.authorized) return widget.granted;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s == CameraPermissionStatus.denied
              ? 'Camera permission denied. Enable in Settings.'
              : 'Camera permission required.'),
          const SizedBox(height: 16),
          if (s == CameraPermissionStatus.notDetermined)
            ElevatedButton(onPressed: _request, child: const Text('Grant')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Widget test**

```dart
// flutter/example/test/widgets/permission_gate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_ios_camera_example/widgets/permission_gate.dart';

void main() {
  testWidgets('renders progress while status unknown', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PermissionGate(granted: const Text('GRANTED'))),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run + commit**

```bash
cd flutter/example && flutter test test/widgets/permission_gate_test.dart
git add flutter/example/lib/widgets/permission_gate.dart \
        flutter/example/test/widgets/permission_gate_test.dart
git commit -m "feat(example): PermissionGate widget

Gates the rest of the screen behind CameraPermissionStatus.authorized.
Shows a Grant button on .notDetermined; on .denied shows the
Settings-required message. Per Phase B spec §6 'PermissionGate'."
```

---

### Task 30: `PreviewWidget`

Texture + state-driven placeholder per Phase B spec §6.

**Files:**
- Create: `flutter/example/lib/widgets/preview_widget.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/preview_widget.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

class PreviewWidget extends StatefulWidget {
  final CameraEngine engine;
  const PreviewWidget({super.key, required this.engine});
  @override
  State<PreviewWidget> createState() => _PreviewWidgetState();
}

class _PreviewWidgetState extends State<PreviewWidget> {
  int? _textureId;
  StreamSubscription<SessionState>? _stateSub;
  SessionState _lastState = SessionState.closed;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.engine.stateStream().listen((s) {
      if (mounted) setState(() => _lastState = s);
    });
    widget.engine
        .createPreviewTexture(stream: StreamId.processed)
        .then((id) {
      if (mounted) setState(() => _textureId = id);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    final id = _textureId;
    if (id != null) widget.engine.destroyPreviewTexture(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    if (id == null) return const Center(child: CircularProgressIndicator());
    final isRendering = _lastState == SessionState.streaming ||
        _lastState == SessionState.paused;
    return isRendering ? Texture(textureId: id) : const _NoSignal();
  }
}

class _NoSignal extends StatelessWidget {
  const _NoSignal();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text('No signal',
              style: TextStyle(color: Colors.white60, fontSize: 16)),
        ),
      );
}
```

- [ ] **Step 2: Commit (no test — visual / device-only)**

```bash
git add flutter/example/lib/widgets/preview_widget.dart
git commit -m "feat(example): PreviewWidget — Texture + state-driven placeholder

Per Phase B spec §6 'PreviewWidget — processed lane only'. Hard-codes
StreamId.processed; the natural lane API is still in the public Dart
surface but not demonstrated."
```

---

### Task 31: `StatusBar` widget

Top bar: SessionState dot, REC + duration, fps.

**Files:**
- Create: `flutter/example/lib/widgets/status_bar.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/status_bar.dart
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

class StatusBar extends StatelessWidget {
  final SessionState state;
  final bool isRecording;
  final Duration recordingDuration;
  final int? frameIsoCurrent;
  const StatusBar({
    super.key,
    required this.state,
    required this.isRecording,
    required this.recordingDuration,
    required this.frameIsoCurrent,
  });

  Color _stateColor() => switch (state) {
        SessionState.streaming => Colors.green,
        SessionState.paused => Colors.yellow,
        SessionState.interrupted => Colors.orange,
        SessionState.recovering => Colors.orange,
        SessionState.error => Colors.red,
        SessionState.opening => Colors.blue,
        SessionState.closed => Colors.grey,
      };

  String _fmtDur() {
    final s = recordingDuration.inSeconds;
    return '${(s ~/ 60).toString().padLeft(1, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        color: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(color: _stateColor(), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(state.name, style: const TextStyle(color: Colors.white)),
          const Spacer(),
          if (isRecording) ...[
            const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
            const SizedBox(width: 4),
            Text(_fmtDur(), style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 16),
          ],
          if (frameIsoCurrent != null)
            Text('ISO $frameIsoCurrent', style: const TextStyle(color: Colors.white70)),
        ]),
      );
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/lib/widgets/status_bar.dart
git commit -m "feat(example): StatusBar widget

Top bar: SessionState colored dot + name, REC + mm:ss when recording,
current ISO from FrameResult. Per Phase B spec §6 'StatusBar'."
```

---

### Task 32: `SettingsSheet` widget

Bottom sheet with four sliders.

**Files:**
- Create: `flutter/example/lib/widgets/settings_sheet.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/settings_sheet.dart
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

class SettingsSheet extends StatefulWidget {
  final CameraEngine engine;
  final SessionCapabilities caps;
  const SettingsSheet({super.key, required this.engine, required this.caps});

  static Future<void> show(BuildContext context, CameraEngine engine, SessionCapabilities caps) =>
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SettingsSheet(engine: engine, caps: caps),
      );

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  double? _iso;
  double? _expNs;
  double? _focus;
  double? _evComp;

  @override
  void initState() {
    super.initState();
    widget.engine.currentSettings().then((s) {
      if (!mounted || s == null) return;
      setState(() {
        _iso = s.iso?.toDouble() ?? widget.caps.isoMin;
        _expNs = s.exposureTimeNs?.toDouble() ?? widget.caps.exposureDurationMinNs.toDouble();
        _focus = s.focusDistance ?? widget.caps.focusMin;
        _evComp = s.evCompensation?.toDouble() ?? 0;
      });
    });
  }

  Future<void> _apply() async {
    final s = CameraSettings(
      iso: _iso?.round(),
      exposureTimeNs: _expNs?.round(),
      focusDistance: _focus,
      evCompensation: _evComp?.round(),
    );
    await widget.engine.updateSettings(s);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_iso == null) return const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row('ISO', _iso!, widget.caps.isoMin, widget.caps.isoMax, (v) => setState(() => _iso = v)),
        _row('Exposure (ns)', _expNs!, widget.caps.exposureDurationMinNs.toDouble(), widget.caps.exposureDurationMaxNs.toDouble(), (v) => setState(() => _expNs = v)),
        _row('Focus', _focus!, widget.caps.focusMin, widget.caps.focusMax, (v) => setState(() => _focus = v)),
        _row('EV', _evComp!, widget.caps.evMin, widget.caps.evMax, (v) => setState(() => _evComp = v)),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _apply, child: const Text('Apply')),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget _row(String label, double value, double min, double max, ValueChanged<double> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          SizedBox(width: 100, child: Text(label)),
          Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
          SizedBox(width: 80, child: Text(value.toStringAsFixed(1))),
        ]),
      );
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/lib/widgets/settings_sheet.dart
git commit -m "feat(example): SettingsSheet — ISO/exposure/focus/EV sliders

Modal bottom sheet that reads currentSettings, presents 4 sliders within
the SessionCapabilities ranges, and writes via engine.updateSettings.
Per Phase B spec §6 'SettingsSheet'."
```

---

### Task 33: `CalibrationDialog` widget

Two buttons + result display.

**Files:**
- Create: `flutter/example/lib/widgets/calibration_dialog.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/calibration_dialog.dart
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

class CalibrationDialog extends StatefulWidget {
  final CameraEngine engine;
  const CalibrationDialog({super.key, required this.engine});

  static Future<void> show(BuildContext context, CameraEngine engine) =>
      showDialog(context: context, builder: (_) => CalibrationDialog(engine: engine));

  @override
  State<CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<CalibrationDialog> {
  CalibrationResult? _last;
  String? _lastKind;
  bool _busy = false;

  Future<void> _doWB() async {
    setState(() => _busy = true);
    final r = await widget.engine.calibrateWhiteBalance();
    if (mounted) setState(() { _last = r; _lastKind = 'White balance'; _busy = false; });
  }

  Future<void> _doBlack() async {
    setState(() => _busy = true);
    final r = await widget.engine.calibrateBlackBalance();
    if (mounted) setState(() { _last = r; _lastKind = 'Black balance'; _busy = false; });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Calibration'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_busy) const CircularProgressIndicator(),
          if (!_busy && _last != null) _ResultView(kind: _lastKind!, r: _last!),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            FilledButton(onPressed: _busy ? null : _doWB, child: const Text('White balance')),
            FilledButton(onPressed: _busy ? null : _doBlack, child: const Text('Black balance')),
          ]),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      );
}

class _ResultView extends StatelessWidget {
  final String kind;
  final CalibrationResult r;
  const _ResultView({required this.kind, required this.r});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$kind — ${r.converged ? "converged" : "did not converge"} in ${r.iterations} iter'),
        Text('Before: R=${r.before.r.toStringAsFixed(3)} G=${r.before.g.toStringAsFixed(3)} B=${r.before.b.toStringAsFixed(3)}'),
        Text('After:  R=${r.after.r.toStringAsFixed(3)} G=${r.after.g.toStringAsFixed(3)} B=${r.after.b.toStringAsFixed(3)}'),
      ]);
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/lib/widgets/calibration_dialog.dart
git commit -m "feat(example): CalibrationDialog — WB + black calibrate

Modal dialog with two buttons; displays the most-recent
CalibrationResult (before/after RGB samples + converged + iterations).
Per Phase B spec §6 'CalibrationDialog'."
```

---

### Task 34: `ControlBar` widget

Bottom bar: 4 buttons.

**Files:**
- Create: `flutter/example/lib/widgets/control_bar.dart`

- [ ] **Step 1: Write the widget**

```dart
// flutter/example/lib/widgets/control_bar.dart
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'settings_sheet.dart';
import 'calibration_dialog.dart';

class ControlBar extends StatelessWidget {
  final CameraEngine engine;
  final SessionCapabilities caps;
  final bool isRecording;
  final VoidCallback onToggleRecording;
  final VoidCallback onCaptureImage;
  const ControlBar({
    super.key,
    required this.engine,
    required this.caps,
    required this.isRecording,
    required this.onToggleRecording,
    required this.onCaptureImage,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 80,
        color: Colors.black87,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.camera, color: Colors.white, size: 32),
              tooltip: 'Capture',
              onPressed: onCaptureImage,
            ),
            IconButton(
              icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record,
                  color: isRecording ? Colors.white : Colors.red, size: 36),
              tooltip: isRecording ? 'Stop recording' : 'Record',
              onPressed: onToggleRecording,
            ),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white, size: 28),
              tooltip: 'Settings',
              onPressed: () => SettingsSheet.show(context, engine, caps),
            ),
            IconButton(
              icon: const Icon(Icons.build, color: Colors.white, size: 28),
              tooltip: 'Calibrate',
              onPressed: () => CalibrationDialog.show(context, engine),
            ),
          ],
        ),
      );
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/lib/widgets/control_bar.dart
git commit -m "feat(example): ControlBar — capture / record / settings / calibrate

Bottom toolbar with 4 IconButtons. Per Phase B spec §6 'ControlBar'."
```

---

### Task 35: `CameraScreen` — wire everything

The single screen.

**Files:**
- Create: `flutter/example/lib/camera_screen.dart`

- [ ] **Step 1: Write the screen**

```dart
// flutter/example/lib/camera_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'widgets/control_bar.dart';
import 'widgets/permission_gate.dart';
import 'widgets/preview_widget.dart';
import 'widgets/status_bar.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final CameraEngine _engine = CameraEngine();
  SessionCapabilities? _caps;
  SessionState _state = SessionState.closed;
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Timer? _ticker;
  int? _isoCurrent;
  StreamSubscription<SessionState>? _stateSub;
  StreamSubscription<FrameResult>? _frameSub;
  StreamSubscription<RecordingStateValue>? _recSub;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final caps = await _engine.open();
      if (!mounted) return;
      setState(() => _caps = caps);
      _stateSub = _engine.stateStream().listen((s) {
        if (mounted) setState(() => _state = s);
      });
      _frameSub = _engine.frameResultStream().listen((f) {
        if (mounted) setState(() => _isoCurrent = f.iso);
      });
      _recSub = _engine.recordingStateStream().listen((r) {
        if (!mounted) return;
        setState(() => _isRecording = r.kind == RecordingStateKind.recording);
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('open failed: $e')));
    }
  }

  Future<void> _capture() async {
    try {
      final path = await _engine.captureImage(photosDestination: PhotosDestination.copy);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $path')));
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        await _engine.stopRecording();
      } else {
        final s = await _engine.startRecording(RecordingOptions(
          fps: 30,
          photosDestination: PhotosDestination.copy,
        ));
        _recordingStartedAt = DateTime.now();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Recording → ${s.displayName}')));
      }
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Recording failed: $e')));
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stateSub?.cancel();
    _frameSub?.cancel();
    _recSub?.cancel();
    _engine.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    return Scaffold(
      body: PermissionGate(
        granted: caps == null
            ? const Center(child: CircularProgressIndicator())
            : Stack(children: [
                Positioned.fill(child: PreviewWidget(engine: _engine)),
                Positioned(top: 0, left: 0, right: 0,
                  child: SafeArea(child: StatusBar(
                    state: _state,
                    isRecording: _isRecording,
                    recordingDuration: _isRecording && _recordingStartedAt != null
                        ? DateTime.now().difference(_recordingStartedAt!)
                        : Duration.zero,
                    frameIsoCurrent: _isoCurrent,
                  )),
                ),
                Positioned(bottom: 0, left: 0, right: 0,
                  child: SafeArea(child: ControlBar(
                    engine: _engine,
                    caps: caps,
                    isRecording: _isRecording,
                    onCaptureImage: _capture,
                    onToggleRecording: _toggleRecording,
                  )),
                ),
              ]),
      ),
    );
  }
}
```

- [ ] **Step 2: Update `main.dart`**

```dart
// flutter/example/lib/main.dart
import 'package:flutter/material.dart';
import 'camera_screen.dart';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'cambrian_ios_camera example',
        theme: ThemeData.dark(),
        home: const CameraScreen(),
      );
}
```

- [ ] **Step 3: Commit**

```bash
git add flutter/example/lib/camera_screen.dart flutter/example/lib/main.dart
git commit -m "feat(example): CameraScreen — single-screen wiring

Stack of PermissionGate over PreviewWidget with StatusBar (top) and
ControlBar (bottom). Subscribes to stateStream, frameResultStream,
recordingStateStream and refreshes timer at 500ms while recording.

Per Phase B spec §6 'main.dart + camera_screen.dart'."
```

---

### Task 36: Smoke build + run the example on iPad

The full plugin + adapter + example app now exists; this is the first real device build.

- [ ] **Step 1: Identify connected iPad UDID**

```bash
xcrun xctrace list devices 2>&1 | grep -i iPad
```
Note the xctrace UDID (format `00008027-...`).

- [ ] **Step 2: Configure XcodeBuildMCP session defaults**

```
mcp__XcodeBuildMCP__session_set_defaults {
  projectPath: "flutter/example/ios/Runner.xcodeproj",
  scheme: "Runner",
  deviceId: "<xctrace UDID>"
}
```

- [ ] **Step 3: Build + run**

```bash
cd flutter/example && flutter run --device-id=<xctrace-UDID>
```
Expected: app launches on iPad, asks for camera permission. After granting, the preview lane appears. Capture and Record buttons function; settings sheet opens; calibration dialog runs.

If it fails to launch with "maximum apps installed using a free developer profile": uninstall a stale CameraKit dev app from the iPad (long-press → Remove App).

- [ ] **Step 4: Commit any necessary fixes**

If the build fails, fix in-place; if it succeeds first try, no new commit. Either way the next step verifies the integration test target compiles.

```bash
git add -p   # any incidental fixes
git commit -m "fix(example): adjustments from first device smoke (if needed)"
```

---

### Task 37: `widget_test.dart` smoke

A one-line smoke ensuring the placeholder scaffold mounts (this is sufficient — the real coverage is integration tests).

**Files:**
- Modify: `flutter/example/test/widget_test.dart`

- [ ] **Step 1: Replace with the real smoke**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds without crashing under MaterialApp', (tester) async {
    // The real CameraScreen depends on platform channels we don't mock here;
    // we wrap a Scaffold instead to verify the example's pubspec wiring is sane.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run + commit**

```bash
cd flutter/example && flutter test
git add flutter/example/test/widget_test.dart
git commit -m "test(example): widget_test smoke — MaterialApp + Scaffold mounts

Per Phase B spec §7 'Example widget smoke'."
```

---

## Phase 8: Integration tests

### Task 38: `integration_test/README.md` — pre-test procedure

The integration tests run on a real iPad. They need camera permission pre-granted and the second test needs a manual home-button press. The README documents both.

**Files:**
- Create: `flutter/example/integration_test/README.md`

- [ ] **Step 1: Write the README**

```markdown
# Integration tests — manual prerequisites

These tests run on a physical iPad. Three setup steps must be done *before*
running:

## 1. Pre-grant camera permission

iOS asks for camera permission on first use and the prompt blocks the
integration test runner. Trigger it once manually:

1. Build + run the example app on the iPad (Task 36).
2. Tap "Grant" when the permission gate appears.
3. Verify the preview lane shows live frames.
4. Background the app (home button) and close it.

Future test runs inherit the granted permission.

## 2. Disable auto-lock

```
Settings → Display & Brightness → Auto-Lock → Never
```

The Recording test holds the camera open for 2+ seconds while frames are
written; an auto-lock during that window faults the AVCaptureSession.

## 3. Manual home-button press for Test 2

Test 2 (Lifecycle transitions) emits a `print()` line:

```
INTEGRATION_PROMPT: press the home button now, then bring the app back
```

When you see that, **physically press the home button** on the iPad, wait
2 seconds, then re-open the app from the home screen. The test resumes
once `stateStream` reports `.streaming` again.

This is a v1 limitation — v1.1 will automate the press via XCUIDevice.

## Running

From the repo root:

```bash
flutter/example/scripts/test-integration.sh
```

Or directly:

```bash
cd flutter/example
flutter test integration_test --device-id=<xctrace UDID>
```
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/integration_test/README.md
git commit -m "docs(integration): pre-test procedure for permissions + lifecycle

Per Phase B spec §7 'Test 2 — Lifecycle transitions' caveat."
```

---

### Task 39: Integration Test 1 — Smoke

**Files:**
- Create: `flutter/example/integration_test/plugin_test.dart`

- [ ] **Step 1: Write the test**

```dart
// flutter/example/integration_test/plugin_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Test 1 — Smoke: open → frame → capture → close', () async {
    final engine = CameraEngine();
    final caps = await engine.open();
    expect(caps.streamPixelFormat, 'BGRA8');

    final stateLog = <SessionState>[];
    final stateSub = engine.stateStream().listen(stateLog.add);

    final textureId = await engine.createPreviewTexture(stream: StreamId.processed);
    expect(textureId, greaterThan(0));

    // Wait up to 5s for .streaming
    final streamingDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (!stateLog.contains(SessionState.streaming) &&
        DateTime.now().isBefore(streamingDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(stateLog.contains(SessionState.streaming), isTrue,
        reason: 'engine did not reach .streaming within 5s');

    // Wait up to 5s for first FrameResult.
    final firstFrame =
        await engine.frameResultStream().first.timeout(const Duration(seconds: 5));
    expect(firstFrame, isNotNull);

    final tempPath = '${Directory.systemTemp.path}/integration-capture.heic';
    final path = await engine.captureImage(outputPath: tempPath);
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), greaterThan(0));

    await engine.destroyPreviewTexture(textureId);
    await stateSub.cancel();
    await engine.close();
  });
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/integration_test/plugin_test.dart
git commit -m "test(integration): Test 1 — Smoke (open → frame → capture → close)

Per Phase B spec §7 'Test 1 — Smoke'."
```

---

### Task 40: Integration Test 2 — Lifecycle (manual home-button)

**Files:**
- Modify: `flutter/example/integration_test/plugin_test.dart`

- [ ] **Step 1: Append Test 2**

```dart
  test('Test 2 — Lifecycle: foreground → background → foreground', () async {
    final engine = CameraEngine();
    await engine.open();
    final stateLog = <SessionState>[];
    final stateSub = engine.stateStream().listen(stateLog.add);

    // Wait for .streaming
    while (!stateLog.contains(SessionState.streaming)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Manual prompt — see integration_test/README.md.
    // ignore: avoid_print
    print('INTEGRATION_PROMPT: press the home button now, then bring the app back');

    // Wait up to 30s for .paused or .interrupted.
    final paused = DateTime.now().add(const Duration(seconds: 30));
    while (!stateLog.any((s) =>
            s == SessionState.paused || s == SessionState.interrupted) &&
        DateTime.now().isBefore(paused)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(
        stateLog.any((s) => s == SessionState.paused || s == SessionState.interrupted),
        isTrue,
        reason: 'engine did not pause when app was backgrounded');

    // Wait for return-to-streaming.
    final returned = DateTime.now().add(const Duration(seconds: 30));
    var streamingAfter = false;
    while (DateTime.now().isBefore(returned)) {
      final last = stateLog.last;
      if (last == SessionState.streaming) { streamingAfter = true; break; }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(streamingAfter, isTrue,
        reason: 'engine did not resume to .streaming after foreground');

    await stateSub.cancel();
    await engine.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/integration_test/plugin_test.dart
git commit -m "test(integration): Test 2 — Lifecycle (manual home-button)

Watches stateStream for .paused/.interrupted after the manual home-button
press, then for return to .streaming on foregrounding. v1.1 will replace
the manual step with XCUIDevice automation.

Per Phase B spec §7 'Test 2'."
```

---

### Task 41: Integration Test 3 — Recording cycle

**Files:**
- Modify: `flutter/example/integration_test/plugin_test.dart`

- [ ] **Step 1: Append Test 3**

```dart
  test('Test 3 — Recording cycle (2 seconds @ 30fps)', () async {
    final engine = CameraEngine();
    await engine.open();
    final stateLog = <SessionState>[];
    final stateSub = engine.stateStream().listen(stateLog.add);
    while (!stateLog.contains(SessionState.streaming)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final start = await engine.startRecording(RecordingOptions(
      fps: 30,
      photosDestination: PhotosDestination.none,
    ));
    expect(start.displayName, isNotEmpty);

    await Future<void>.delayed(const Duration(seconds: 2));

    final mp4Uri = await engine.stopRecording();
    expect(mp4Uri, isNotEmpty);

    // mp4Uri is a file:// URL; convert to filesystem path.
    final path = Uri.parse(mp4Uri).toFilePath();
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), greaterThan(10_000),
        reason: 'mp4 should have substantial bytes for a 2s recording');

    await stateSub.cancel();
    await engine.close();
  });
```

- [ ] **Step 2: Commit**

```bash
git add flutter/example/integration_test/plugin_test.dart
git commit -m "test(integration): Test 3 — Recording cycle (2s @ 30fps)

startRecording → 2s wait → stopRecording → assert mp4 exists and is >10KB.

Per Phase B spec §7 'Test 3 — Recording cycle'."
```

---

## Phase 9: Scripts and verification

### Task 42: `test-swift-adapter.sh`

**Files:**
- Create: `flutter/example/scripts/test-swift-adapter.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Runs the RunnerTests XCTest suite on the connected iPad.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

UDID="${IPAD_UDID:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun xctrace list devices 2>&1 | grep -iE 'iPad' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
fi
[ -z "$UDID" ] && { echo "No connected iPad found; export IPAD_UDID=<UDID>"; exit 1; }

xcodebuild test \
  -project flutter/example/ios/Runner.xcodeproj \
  -scheme RunnerTests \
  -destination "platform=iOS,id=$UDID" \
  -only-testing:RunnerTests \
  2>&1 | tee .build-logs/$(date +%Y%m%d-%H%M%S)-swift-adapter.log | grep -E '(Test (Suite|Case)|FAIL|PASS|error:)'
```

- [ ] **Step 2: Chmod + commit**

```bash
chmod +x flutter/example/scripts/test-swift-adapter.sh
git add flutter/example/scripts/test-swift-adapter.sh
git commit -m "chore(scripts): test-swift-adapter.sh — RunnerTests on iPad

Per Phase B spec §7 'Run via flutter/example/scripts/test-swift-adapter.sh'."
```

---

### Task 43: `test-integration.sh`

**Files:**
- Create: `flutter/example/scripts/test-integration.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Runs the integration_test suite on the connected iPad.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/flutter/example"

UDID="${IPAD_UDID:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun xctrace list devices 2>&1 | grep -iE 'iPad' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
fi
[ -z "$UDID" ] && { echo "No connected iPad found; export IPAD_UDID=<UDID>"; exit 1; }

echo "===> Running integration tests on iPad $UDID"
echo "===> See integration_test/README.md for the manual-step procedure for Test 2"

flutter test integration_test --device-id="$UDID"
```

- [ ] **Step 2: Chmod + commit**

```bash
chmod +x flutter/example/scripts/test-integration.sh
git add flutter/example/scripts/test-integration.sh
git commit -m "chore(scripts): test-integration.sh — 3 integration tests on iPad

Per Phase B spec §7 'Run command'."
```

---

### Task 44: `scripts/test-phase-b.sh` — consolidated runner

**Files:**
- Create: `scripts/test-phase-b.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Runs all four Phase B test layers in order, fail-fast.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "==> [1/4] Dart unit tests (flutter/test/)"
(cd flutter && flutter test)

echo "==> [2/4] Example widget smoke (flutter/example/test/)"
(cd flutter/example && flutter test)

echo "==> [3/4] Swift adapter (flutter/example/ios/RunnerTests, iPad)"
flutter/example/scripts/test-swift-adapter.sh

echo "==> [4/4] Integration tests (iPad — requires manual home-button on Test 2)"
flutter/example/scripts/test-integration.sh

echo "==> All four Phase B test layers green."
```

- [ ] **Step 2: Chmod + commit**

```bash
chmod +x scripts/test-phase-b.sh
git add scripts/test-phase-b.sh
git commit -m "chore(scripts): test-phase-b.sh — consolidated 4-layer test runner

Per Phase B spec §7 'CI / Tests run locally on the dev machine'."
```

---

### Task 45: `scripts/release-gate.sh` — 7-check release gate

**Files:**
- Create: `scripts/release-gate.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Phase B v1.0.0 release gate — 7 checks per the spec §8.
# All must pass before tagging.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

step () { echo; echo "==> $1"; }

step "[1/7] Dart unit + example smoke"
(cd flutter && flutter test)
(cd flutter/example && flutter test)

step "[2/7] Swift adapter XCTest (iPad)"
flutter/example/scripts/test-swift-adapter.sh

step "[3/7] Integration tests (iPad — manual step on Test 2)"
flutter/example/scripts/test-integration.sh

step "[4/7] CameraKit suite (iPad)"
# Uses the existing wrapper; defaults to scheme ios_example_app.
scripts/test-summary.sh

step "[5/7] ios_example_app smoke build (iPad)"
scripts/build-summary.sh

step "[6/7] flutter example standalone smoke launch"
UDID="${IPAD_UDID:-$(xcrun xctrace list devices 2>&1 | grep -iE 'iPad' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
[ -z "$UDID" ] && { echo "No iPad — manually verify 'flutter run' in flutter/example/"; exit 1; }
# Build only — don't try to keep the app running headless.
(cd flutter/example && flutter build ios --device-id="$UDID" --release)

step "[7/7] swift-format lint --strict on CameraKit sources"
swift-format lint --strict CameraKit/Sources/CameraKit/*.swift

echo
echo "==> Release gate: all 7 checks passed."
```

- [ ] **Step 2: Chmod + commit**

```bash
chmod +x scripts/release-gate.sh
git add scripts/release-gate.sh
git commit -m "chore(scripts): release-gate.sh — 7-check release gate

Per Phase B spec §8 'Verification gate'. Runs:
1. Dart unit + example smoke
2. Swift adapter XCTest
3. 3 integration tests
4. CameraKit suite (203 existing tests)
5. ios_example_app smoke build
6. flutter example standalone build
7. swift-format --strict
"
```

---

## Phase 10: Docs and release prep

### Task 46: Update root `README.md` for v1.0.0

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Consuming v1.0.0" section**

Append (after the existing "Two personalities" intro), or replace the consumer-recipe section if one exists:

```markdown
## Consuming v1.0.0

**Swift Package Manager (CameraKit):**

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

**Flutter (cambrian_ios_camera):**

```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter
      ref: v1.0.0
```

A single git tag `vX.Y.Z` drives both consumers. SemVer applies across the combined surface.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): v1.0.0 consumer recipes — SPM + Flutter

Per Phase B spec §8 'Consumer recipe'."
```

---

### Task 47: Update `CameraKit/state.md` with Phase B completion entry

**Files:**
- Modify: `CameraKit/state.md`

- [ ] **Step 1: Append a Phase B section**

Add a section near the top documenting:

```markdown
## Phase B — Flutter plugin v1.0.0 (2026-05-22 → tag-date)

**Spec:** `docs/superpowers/specs/2026-05-22-flutter-plugin-phase-b-design.md`
**Plan:** `docs/superpowers/plans/2026-05-22-flutter-plugin-phase-b.md`

Phase B is post-pipeline (no stage briefs, no preflight). It adds:

- `cambrian_ios_camera` Flutter plugin at `flutter/`
- Singleton `CameraEngine` exposed via Pigeon HostApi + 5 EventChannelApi streams
- Plugin-owned native lifecycle (UIScene callbacks → `engine.setLifecyclePhase`)
- Zero-copy preview via `FlutterTexture` + `Texture(textureId:)`
- One-time CameraKit addition: `CameraEngineProtocol` for adapter test
  mockability
- ~40 Dart unit tests, ~5 Swift adapter XCTest, 3 integration tests on iPad
- Android stub throwing `PlatformException(code: 'iOSOnly')`
- Joint git-tag versioning — `vX.Y.Z` drives both SPM + Flutter consumers
- Example app at `flutter/example/` — lean, processed-lane only

CameraKit tests (203) untouched. Adapter is a thin translation layer
(per Phase B spec §1 load-bearing property #2 — "if the adapter is doing
real work, the work belongs in CameraKit").
```

- [ ] **Step 2: Commit**

```bash
git add CameraKit/state.md
git commit -m "docs(state): record Phase B completion

Per Phase B spec §B15 in implementation order summary."
```

---

### Task 48: Write `docs/release-notes-v1.0.0.md`

**Files:**
- Create: `docs/release-notes-v1.0.0.md`

- [ ] **Step 1: Draft release notes**

```markdown
# v1.0.0 — first release

## What this is

A Swift package (`CameraKit`) for iOS-only camera access — dual-lane capture
(natural + processed), Metal preview, recording, calibration — and a Flutter
plugin (`cambrian_ios_camera`) that wraps it. Joint-versioned: a single git
tag drives both consumers.

## Consume

**Swift:**
```swift
.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.0.0")
```

**Flutter:**
```yaml
cambrian_ios_camera:
  git:
    url: https://github.com/Shreeyak/cambrian-ios-camera.git
    path: flutter
    ref: v1.0.0
```

## Key design properties

- **Lifecycle is plugin-owned**, native. Dart has no lifecycle surface — there
  is no `engine.pause()` / `engine.resume()` on the Dart class. The plugin
  observes `UIScene` natively. A `WidgetsBindingObserver`-driven lifecycle
  added platform-channel latency that could corrupt in-flight recordings;
  this design eliminates that class of bug.

- **Singleton engine.** One `CameraEngine` per Flutter plugin instance, keyed
  by nothing. The official `camera` plugin keys by ID for front/back
  switching; CameraKit doesn't have that pattern.

- **Zero-copy preview.** `Texture(textureId:)` backed by
  `currentPixelBuffer(stream:)` reading from CameraKit's mailbox on the raster
  thread. The 2026-05-15 spike validated this needs no mitigations.

- **Pigeon-bridged contract.** Every Dart ↔ Swift call goes through the
  Pigeon DSL at `flutter/pigeons/cambrian_ios_camera_api.dart`. Generated
  files committed for review on bumps.

## What's not in v1.0.0

- Android — Kotlin stub throws `PlatformException(code: 'iOSOnly')` on every
  HostApi call. Real Android implementation is a separate spec.
- pub.dev publication. Stays `git: + path:` referenced.
- Multi-engine support (engineId-keyed HostApi).
- CHANGELOG.md — adds in v1.1.0 with v1.0.0 as anchor.
- CI. Manual local testing.

## Verification before tagging

`scripts/release-gate.sh` runs all 7 gates: Dart unit, example smoke, Swift
adapter XCTest, 3 integration tests, CameraKit (203 tests), ios_example_app
smoke, flutter example smoke, swift-format strict.
```

- [ ] **Step 2: Commit**

```bash
git add docs/release-notes-v1.0.0.md
git commit -m "docs(release): v1.0.0 release notes (GitHub release body)

To be published with 'gh release create v1.0.0 --notes-file ...' at
tag-time. Per Phase B spec §8 'GitHub Release notes'."
```

---

## Phase 11: Release

### Task 49: Run `scripts/release-gate.sh` and fix any failures

**Files:** N/A (verification + fixes)

- [ ] **Step 1: Run the gate**

```bash
scripts/release-gate.sh
```

Expected: all 7 gates pass. If any fails:

| Failure | Diagnosis path |
|---|---|
| Dart unit | `cd flutter && flutter test --reporter=expanded` to see which test, fix code or test |
| Example smoke | Likely import or scaffold issue; `cd flutter/example && flutter test --reporter=expanded` |
| Swift adapter | Read `.build-logs/*.log`; the JSON via xcsift has file:line per error |
| Integration | Permission-not-granted (Task 38 README) or stale install — uninstall + retry |
| CameraKit | Existing 203 tests; if they fail, the regression is in CameraKit unrelated to Phase B — diagnose separately |
| ios_example_app | Same as Swift adapter — read the log |
| flutter example build | `flutter build ios` errors usually come from Pods or signing |
| swift-format | Run `swift-format -i CameraKit/Sources/**/*.swift` to auto-fix; if rule is `BeginDocumentationCommentWithOneLineSummary`, split the doc comment manually |

- [ ] **Step 2: Commit any fixes**

```bash
git add -p
git commit -m "fix: release-gate.sh polishes for v1.0.0"
```

Re-run the gate until green. The gate must report `==> Release gate: all 7 checks passed.` before proceeding.

---

### Task 50: Tag-time process (user-approved at each git operation)

**Per `CLAUDE.md` §7:** every git operation in this task waits for explicit user approval before running.

**Files:**
- Modify: `flutter/pubspec.yaml` (bump if needed)
- Modify: `flutter/example/pubspec.yaml` (bump if needed)

- [ ] **Step 1: Confirm versions are at 1.0.0**

```bash
grep "^version:" flutter/pubspec.yaml flutter/example/pubspec.yaml
```
Expected: both show `1.0.0` or `1.0.0+1`. If a bump is needed:

```bash
sed -i '' 's/^version: .*/version: 1.0.0+1/' flutter/pubspec.yaml
sed -i '' 's/^version: .*/version: 1.0.0+1/' flutter/example/pubspec.yaml
```

- [ ] **Step 2: Request approval, then commit the version bump (if any)**

Wait for user "yes". Then:

```bash
git add flutter/pubspec.yaml flutter/example/pubspec.yaml
git commit -m "release: v1.0.0"
```

- [ ] **Step 3: Request approval, then create the annotated tag**

Wait for user "yes". Then:

```bash
git tag -a -s v1.0.0 -m "v1.0.0 — first release of CameraKit + cambrian_ios_camera"
```

- [ ] **Step 4: Local verification of the tag**

```bash
git tag -v v1.0.0           # signature check
swift package describe       # SPM accepts the tag
(cd flutter && dart pub get) # Flutter consumer side
```

- [ ] **Step 5: Request approval, then push**

Wait for user "yes". Then:

```bash
git push origin main
git push origin v1.0.0
```

- [ ] **Step 6: Create the GitHub release**

```bash
gh release create v1.0.0 --title "v1.0.0 — first release" --notes-file docs/release-notes-v1.0.0.md
```

- [ ] **Step 7: Verify a fresh checkout consumes**

In a scratch directory:

```bash
mkdir -p /tmp/cambrian-verify && cd /tmp/cambrian-verify
cat > Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Verify",
    platforms: [.iOS(.v26)],
    dependencies: [.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.0.0")],
    targets: [.target(name: "Verify", dependencies: [.product(name: "CameraKit", package: "cambrian-ios-camera")])]
)
EOF
mkdir -p Sources/Verify && echo 'import CameraKit' > Sources/Verify/Verify.swift
swift package resolve
```
Expected: resolves `cambrian-ios-camera 1.0.0`.

- [ ] **Step 8: Done**

The plan is complete. The repo at tag `v1.0.0` is:

- CameraKit Swift package at the repo root, SPM-resolvable from `v1.0.0`
- `flutter/` plugin importable from `pub.dev`-style git+path consumers
- Example app at `flutter/example/`
- 4 test layers green (~40 Dart unit, ~8 Swift adapter, 3 integration, 203 CameraKit)
- Release notes published on GitHub

---

## After v1.0.0 — out of scope for this plan

These items are tracked in the spec §"Future cleanup — deferred work":

- `CameraKit → CambrianCamera` rename (Snap SDK naming collision)
- pub.dev publication for the Flutter plugin
- Swift Package Index registration
- Real Android implementation
- XCUIDevice automation of the lifecycle integration-test home-button press (v1.1)
- Independent tag families (only if joint versioning becomes painful)
- Multi-engine support (engineId-keyed HostApi) — non-breaking v1.x addition
- `CHANGELOG.md` (added in v1.1.0 with v1.0.0 as bottom anchor)
- CI (GitHub Actions running `flutter test`)
