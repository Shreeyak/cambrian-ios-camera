# Lifecycle

Keeping the camera correct as your app moves between foreground, inactive, and
background.

Assumes you have read [01-overview](01-overview.md).

## The single lifecycle API

The entire lifecycle API is `CameraEngine.setLifecyclePhase(_:)`. The host
observes its own app lifecycle and forwards each transition; the engine
reconciles the GPU gate, session start/stop, watchdogs, and recording finalize.

`CameraEngine.setLifecyclePhase(_:)` never throws and the latest call wins, so
forward on every transition. The target is derived from the current phase alone —
there is no previous-phase tracking, so the `.background → .inactive → .active`
restore that hosts emit needs no special handling.

## Constructing with initialPhase

`CameraEngine` requires an `initialPhase` at construction — there is no default.
Pass the launch phase, or `.background` when unsure. The engine applies it when
`open()` runs, so a launch directly into the background never turns the camera on
without UI.

## What each phase reconciles to

| Phase | GPU gate | Capture session | Stall watchdogs |
| --- | --- | --- | --- |
| `.active` | open | running | armed |
| `.inactive` | closed | running (cheap pause — a gate flip, not a restart) | disarmed |
| `.background` | closed | stopped (recording finalized first) | disarmed |

## Wiring it up — SwiftUI

Observe `@Environment(\.scenePhase)` and forward the matching `AppLifecyclePhase`;
the cases map 1:1.

```swift
@Environment(\.scenePhase) private var scenePhase

// In the view body:
.task(id: scenePhase) {
    switch scenePhase {
    case .active:     await engine.setLifecyclePhase(.active)
    case .inactive:   await engine.setLifecyclePhase(.inactive)
    case .background: await engine.setLifecyclePhase(.background)
    @unknown default: await engine.setLifecyclePhase(.inactive)
    }
}
```

## Wiring it up — UIScene and other hosts

A non-SwiftUI host observes the `UIScene` lifecycle natively and forwards the
phase from the scene callbacks: `sceneDidBecomeActive → .active`,
`sceneWillResignActive → .inactive`, `sceneDidEnterBackground → .background`.
Observe natively rather than round-tripping through application code, so a
backgrounding cannot outrun an in-flight recording's finalize.

## Interruptions are automatic

While the OS owns the device — a phone call, another app taking the camera,
Control Center — CameraKit detects the interruption, recovers when it ends, and
re-arms its watchdogs. The host keeps forwarding its own phase; it does not need
to detect or handle interruptions. Observe the recovery through the state stream
([09-observing-state-and-errors](09-observing-state-and-errors.md)).

## Reference integration

`ios_example_app/ios_example_app/UI/CameraView.swift` forwards `scenePhase` via a
`.task(id:)`; `UI/ViewModel.swift` maps it to `AppLifecyclePhase` and calls
`CameraEngine.setLifecyclePhase(_:)`.
