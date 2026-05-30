# v1.2.0 — Packaged with example apps  *(draft)*

## What this is

This release turns the repo into a clean, consumable **package with example
apps**. It ships:

- **`CameraKit`** — a Swift package (at the repo root) for iOS-only camera
  access: dual-lane capture (natural + processed), Metal preview, recording,
  calibration.
- **`cambrian_ios_camera`** — a Flutter plugin (under `flutter/`) that wraps
  CameraKit over a Pigeon bridge + EventChannel streams.
- **Example apps** — `ios_example_app/` (native SwiftUI dev harness) and
  `flutter/example/` (standard Flutter plugin example).

Both consumers are joint-versioned: a single git tag drives the Swift package
and the Flutter plugin.

## What's new in v1.2.0

- **Repo is now a first-class distributable.** Root `Package.swift` + the
  `flutter/` plugin + two runnable example apps. Verified end-to-end by fresh
  external consumers: a Flutter app importing via `git: + path: flutter` and a
  Swift app importing CameraKit via a remote SPM dependency, both building and
  exercising the package on-device.
- **In-repo platform reference.** The iOS platform guide (the `ADR-##` / `G-##`
  registry that the Swift sources cite) now lives in-repo at
  `docs/reference/ios-platform-guide/`, so the citations resolve on any clone
  rather than depending on a machine-local symlink.
- **Docs cleanup.** Historical stage plans, design specs, and per-stage HITL
  evidence moved under `docs/archived/`; the upstream clean-room symlink corpus
  was removed from the repo (it remains read-only upstream).

## Consume

**Swift (SPM)** — root `Package.swift` lives on `main` (and on this tag):
```swift
// Track a release:
.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.2.0")
// …or track main during development:
.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", branch: "main")
```
The importing target must enable C++ interop
(`-cxx-interoperability-mode=default`) — CameraKit is built with it (ADR-13),
though no C++ type crosses its public API.

**Flutter** — the plugin is in the `flutter/` subdirectory:
```yaml
cambrian_ios_camera:
  git:
    url: https://github.com/Shreeyak/cambrian-ios-camera.git
    path: flutter
    ref: main        # the plugin lives on main, so this always resolves
    # ref: v1.2.0    # …or pin a fixed version (tag must be cut from main;
    #                  v1.0.0/v1.0.1 predate the Flutter plugin)
```

## Key design properties (unchanged from v1.0)

- **Lifecycle is plugin-owned**, native. Dart has no `pause()`/`resume()`; the
  plugin observes `UIScene` natively (`FlutterSceneLifeCycleDelegate` →
  `engine.setLifecyclePhase`). Avoids platform-channel latency that could
  corrupt in-flight recordings.
- **Non-replaying state streams.** The five `@EventChannelApi` streams are plain
  broadcast streams; consumers read a fresh `currentState()` snapshot on
  subscribe, then observe live. Replay would mask a stalled pipeline.
- **Singleton engine.** One `CameraEngine` per Flutter plugin instance.
- **Zero-copy preview.** `Texture(textureId:)` backed by `FlutterTexture`
  reading CameraKit's mailbox on the raster thread.
- **Pigeon-bridged contract.** Every Dart ↔ Swift call goes through the Pigeon
  DSL at `flutter/pigeons/cambrian_ios_camera_api.dart`.

## What's not in v1.2.0

- **Android** — the Kotlin stub throws `PlatformException(code: 'iOSOnly')` on
  every HostApi call. A real Android implementation is a separate effort.
- **pub.dev publication** — stays `git: + path:` referenced.
- **CI** — testing is manual + local (see `scripts/release-gate.sh`).
- **The `CameraKit` → `CambrianCamera` rename** (to avoid collision with Snap's
  CameraKit SDK) — deferred to a future pass.
