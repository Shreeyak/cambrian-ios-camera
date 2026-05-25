# v1.0.0 — first release

## What this is

A Swift package (`CameraKit`) for iOS-only camera access — dual-lane capture
(natural + processed), Metal preview, recording, calibration — and a Flutter
plugin (`cambrian_ios_camera`) that wraps it. Joint-versioned: a single git
tag drives both consumers.

## Consume

**Swift (SPM):**
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
  observes `UIScene` natively (`FlutterSceneLifeCycleDelegate` →
  `engine.setLifecyclePhase`). A Dart-side `WidgetsBindingObserver` lifecycle
  added platform-channel latency that could corrupt in-flight recordings; this
  design eliminates that class of bug. The engine reacts to what the camera
  device is actually doing, not a stale Dart event.

- **Non-replaying state streams.** The five `@EventChannelApi` streams are
  plain broadcast streams — no replay/BehaviorSubject. Replay would mask a
  stalled pipeline (you'd see the last good value, not the stall). Consumers
  that need an initial value read a fresh `currentState()` snapshot on
  subscribe, then observe the live stream.

- **Singleton engine.** One `CameraEngine` per Flutter plugin instance. The
  official `camera` plugin keys by ID for front/back switching; CameraKit
  doesn't have that pattern.

- **Zero-copy preview.** `Texture(textureId:)` backed by `FlutterTexture`
  reading CameraKit's mailbox on the raster thread. The 2026-05-15 spike
  validated this needs no mitigations.

- **Pigeon-bridged contract.** Every Dart ↔ Swift call goes through the Pigeon
  DSL at `flutter/pigeons/cambrian_ios_camera_api.dart`. Generated files are
  committed for review on bumps.

## What's not in v1.0.0

- Android — the Kotlin stub throws `PlatformException(code: 'iOSOnly')` on
  every HostApi call. A real Android implementation is a separate spec.
- pub.dev publication. Stays `git: + path:` referenced.
- `CHANGELOG.md` — adds in v1.1.0 with v1.0.0 as the bottom anchor.
- CI. Testing is manual + local.
- XCUIDevice automation of the lifecycle integration test (Test 2 is skipped
  in v1.0; arrives in v1.1).

## Verification before tagging

`scripts/release-gate.sh` runs all 7 gates: Dart unit + example smoke, Swift
adapter XCTest (iPad), 3 integration tests (iPad), the full CameraKit suite,
`ios_example_app` smoke build, flutter example release build, and
`swift-format lint --strict`.
