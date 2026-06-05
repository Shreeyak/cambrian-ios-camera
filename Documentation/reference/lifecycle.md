# Lifecycle

## AppLifecyclePhase

*Enum*

```swift
enum AppLifecyclePhase
```

The host's current visibility. The only lifecycle vocabulary a host needs — nothing about gates, drains, or sessions. The host forwards it via `CameraEngine.setLifecyclePhase(_:)`; the engine reconciles hardware to the target each phase implies.

### AppLifecyclePhase.active

```swift
case active
```

### AppLifecyclePhase.background

```swift
case background
```

### AppLifecyclePhase.inactive

```swift
case inactive
```
