# CameraKit API Reference — Index

This indexes the per-symbol reference under `reference/`. For
task-oriented learning start at `../index.md` and the guides; use this
layer to look up a specific symbol's signature, parameters, returns, and
errors.

## SECTION: HOW THE REFERENCE IS ORGANIZED

Types are grouped by cohesion, one cluster per file. Grep a symbol name
in the table below to find its file.

## SECTION: SYMBOL → FILE

| Symbol | File |
| --- | --- |
| `AppLifecyclePhase` | [lifecycle.md](lifecycle.md) |
| `CalibrationResult` | [calibration.md](calibration.md) |
| `CameraEngine` | [camera-engine.md](camera-engine.md) |
| `CameraEngineProtocol` | [camera-engine.md](camera-engine.md) |
| `CameraError` | [errors.md](errors.md) |
| `CameraKitLog` | [logging.md](logging.md) |
| `CameraMode` | [camera-settings.md](camera-settings.md) |
| `CameraPermissionStatus` | [permissions.md](permissions.md) |
| `CameraPosition` | [camera-settings.md](camera-settings.md) |
| `CameraSettings` | [camera-settings.md](camera-settings.md) |
| `CaptureMetadata` | [frames.md](frames.md) |
| `ConsumerRegistry` | [consumers.md](consumers.md) |
| `ConsumerToken` | [consumers.md](consumers.md) |
| `EngineError` | [errors.md](errors.md) |
| `ErrorCode` | [errors.md](errors.md) |
| `FrameDeliveryStats` | [frames.md](frames.md) |
| `FrameResult` | [frames.md](frames.md) |
| `FrameSet` | [frames.md](frames.md) |
| `MetalError` | [errors.md](errors.md) |
| `OpenConfiguration` | [configuration.md](configuration.md) |
| `PhotosDestination` | [recording.md](recording.md) |
| `PixelSinkCallbacks` | [consumers.md](consumers.md) |
| `ProcessingMetadata` | [frames.md](frames.md) |
| `ProcessingParameters` | [image-processing.md](image-processing.md) |
| `RecordingError` | [errors.md](errors.md) |
| `RecordingOptions` | [recording.md](recording.md) |
| `RecordingStart` | [recording.md](recording.md) |
| `RecordingState` | [recording.md](recording.md) |
| `Rect` | [configuration.md](configuration.md) |
| `RgbSample` | [calibration.md](calibration.md) |
| `SessionCapabilities` | [configuration.md](configuration.md) |
| `SessionState` | [session-state.md](session-state.md) |
| `Size` | [configuration.md](configuration.md) |
| `StillCaptureError` | [errors.md](errors.md) |
| `StillCaptureOutput` | [stills.md](stills.md) |
| `StreamConfiguration` | [configuration.md](configuration.md) |
| `StreamId` | [session-state.md](session-state.md) |
| `TrackerQuality` | [frames.md](frames.md) |
| `WhiteBalanceGains` | [calibration.md](calibration.md) |
| `WhiteBalanceMode` | [camera-settings.md](camera-settings.md) |
| `WhiteBalancePreset` | [camera-settings.md](camera-settings.md) |

## SECTION: BY CLUSTER

- [Camera Engine](camera-engine.md): `CameraEngine`, `CameraEngineProtocol`
- [Lifecycle](lifecycle.md): `AppLifecyclePhase`
- [Configuration](configuration.md): `OpenConfiguration`, `SessionCapabilities`, `StreamConfiguration`, `Size`, `Rect`
- [Camera Settings](camera-settings.md): `CameraSettings`, `CameraMode`, `WhiteBalanceMode`, `WhiteBalancePreset`, `CameraPosition`
- [Image Processing](image-processing.md): `ProcessingParameters`
- [Calibration](calibration.md): `CalibrationResult`, `RgbSample`, `WhiteBalanceGains`
- [Recording](recording.md): `RecordingOptions`, `RecordingStart`, `RecordingState`, `PhotosDestination`
- [Stills](stills.md): `StillCaptureOutput`
- [Session State](session-state.md): `SessionState`, `StreamId`
- [Frames](frames.md): `FrameResult`, `FrameSet`, `CaptureMetadata`, `ProcessingMetadata`, `FrameDeliveryStats`, `TrackerQuality`
- [Errors](errors.md): `CameraError`, `ErrorCode`, `EngineError`, `MetalError`, `RecordingError`, `StillCaptureError`
- [Permissions](permissions.md): `CameraPermissionStatus`
- [Consumers](consumers.md): `ConsumerRegistry`, `ConsumerToken`, `PixelSinkCallbacks`
- [Logging](logging.md): `CameraKitLog`

## SECTION: NOT IN THIS REFERENCE

These public types are development-internal (dependency-injection seams,
test hooks, recovery/watchdog internals). Consumers never call them:

`AssetWriterFactory`, `AssetWriterPixelBufferAdapting`, `AssetWriting`, `BackgroundTaskProviding`, `CalibrationCompute`, `CameraKitClock`, `CaptureDeviceProviding`, `DefaultAssetWriterFactory`, `DeviceStateSnapshot`, `InteropError`, `Mailbox`, `Recording`, `RecoveryCoordinator`, `SystemClock`, `SystemPressureLevel`, `UIApplicationBackgroundTaskProvider`, `Watchdog`, `WatchdogFire`, `WatchdogKind`, `WatchdogPair`.
