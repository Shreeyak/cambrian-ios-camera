# CameraKit

A Swift 6 / iOS 26 camera library: dual-lane capture (natural + processed),
Metal preview, recording, and calibration, behind a single declarative lifecycle
API. The package is UI-framework-agnostic — it imports no SwiftUI — and is
consumed both by this repo's native dev harness and by the `cambrian_camera`
Flutter plugin.

## Lifecycle

> **Driving the lifecycle.** The host tells CameraKit its visibility by calling
> `engine.setLifecyclePhase(_:)` on every transition — that is the entire
> lifecycle API. CameraKit owns everything downstream (GPU gate, session
> start/stop, stall watchdogs, recording finalize) plus the device-interruption
> lifecycle; the host owns only *observing* its own app lifecycle and forwarding
> the phase.
>
> - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward `.active` /
>   `.inactive` / `.background` (1:1 — they share names with `AppLifecyclePhase`).
> - **Flutter:** observe the iOS app lifecycle in the **plugin's native Swift
>   layer** (`FlutterSceneLifeCycleDelegate`), **not** in Dart, and call
>   `setLifecyclePhase`: `resumed → .active`, `inactive → .inactive`, `hidden` /
>   `paused → .background`, `detached →` skip. Forwarding from Dart over the
>   method channel adds round-trip latency that can let a backgrounding outrun an
>   in-flight recording's finalize and corrupt the `.mp4` — observe natively
>   instead.
>
> Call it freely on every transition: it never throws, and the latest call wins
> (a superseded in-flight transition is abandoned). Construct the engine with
> your current phase (`initialPhase`) — there is no default.

### Dart-side guidance (Flutter consumers)

> The Dart side still sees the lifecycle changes, it just doesn't need to act on
> them for camera purposes. The only thing the Dart layer should use its own
> lifecycle awareness for is managing its own rendering — like whether to paint
> the Texture widget or show a placeholder. And even that is better driven by the
> stateStream coming up from CameraKit through the EventChannel, since that
> reflects what the camera is actually doing rather than what the OS said a few
> milliseconds ago.

### What each phase reconciles to

| Phase | GPU gate | capture session | stall watchdogs |
|---|---|---|---|
| `.active` | open | running | armed |
| `.inactive` | closed | running (cheap pause — ~4 ms gate flip, not a ~410 ms restart) | disarmed |
| `.background` | closed | stopped (recording finalized first) | disarmed |

The target is derived from the *current* phase alone — there is no
previous-phase tracking, so the intermediate `.background → .inactive → .active`
restore that both SwiftUI and Flutter emit needs no special-casing. While an OS
interruption owns the device (`.interrupted` / `.recovering` / `.error`) the host
phase does not fight it: no `startRunning`, no watchdog re-arm, and the OS
event's label is not overwritten.

### Construction

`CameraEngine` requires an `initialPhase` — there is **no default**. Pass the
launch phase; pass `.background` when unsure. A default of `.active` would be a
privacy trap: if `open()` ran before the host's first phase forward (prewarm or a
direct-into-background launch) the engine would turn the camera on with no
foreground UI.

```swift
// SwiftUI host
let engine = CameraEngine(initialPhase: .background)   // state the launch phase
let caps = try await engine.open()

// Forward every scenePhase transition (1:1 mapping):
.task(id: scenePhase) {
    switch scenePhase {
    case .active:     await engine.setLifecyclePhase(.active)
    case .inactive:   await engine.setLifecyclePhase(.inactive)
    case .background: await engine.setLifecyclePhase(.background)
    @unknown default: await engine.setLifecyclePhase(.inactive)
    }
}
```
