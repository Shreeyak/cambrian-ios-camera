# Observing state and errors

The event streams, session state, errors, and automatic recovery.

Assumes you have read [02-getting-started](02-getting-started.md).

## The five streams

`CameraEngine` publishes five `AsyncStream`s:

| Stream | Element | Reports |
| --- | --- | --- |
| `CameraEngine.stateStream()` | `SessionState` | session lifecycle |
| `CameraEngine.errorStream()` | `CameraError` | runtime errors |
| `CameraEngine.frameResultStream()` | `FrameResult` | per-frame metadata |
| `CameraEngine.recordingStateStream()` | `RecordingState` | recording progress |
| `CameraEngine.streamConfigurationStream()` | `StreamConfiguration` | resolution/crop changes |

```swift
for await state in await engine.stateStream() {
    // react to state transitions
}
```

## Streams do not replay

The streams buffer only the newest value(s) and do not replay history.
**Subscribe before or around `CameraEngine.open(configuration:)`** — a
subscription started afterwards misses earlier events. Start your `for await`
loops as part of your open sequence.

## Session state

`SessionState` describes what the session itself is doing:
`SessionState.opening`, `SessionState.streaming`, `SessionState.paused`,
`SessionState.interrupted`, `SessionState.recovering`,
`SessionState.error`, and `SessionState.closed`. Drive UI (for example, paint
the preview versus a placeholder) from this stream rather than from your app's
own lifecycle, because it reflects what the camera is actually doing.

## Errors

There are two error surfaces:

- **Commands throw `EngineError`.** A failed `await` on a command — `open`,
  `updateSettings`, `setCropRegion`, `captureImage` — throws synchronously (for
  example `EngineError` `notOpen` or `settingsConflict`). Handle it at the call
  site.
- **Runtime errors arrive on `CameraEngine.errorStream()`.** A `CameraError`
  carries a `CameraError.code` (`ErrorCode`), a `CameraError.message`, and
  `CameraError.isFatal`. Non-fatal errors are informational (for example
  `fpsDegraded`); a fatal error means the session cannot continue.

## Automatic recovery

When the OS interrupts the camera, the engine reports
`SessionState.interrupted`, then `SessionState.recovering`, then
`SessionState.streaming` once it recovers — no host action required
([03-lifecycle](03-lifecycle.md)). Treat `SessionState.recovering` as transient; only a
fatal `CameraError` warrants tearing down.

## FrameResult versus FrameSet

`CameraEngine.frameResultStream()` emits a lightweight `FrameResult`
(`FrameResult.iso`, `FrameResult.exposureTimeNs`,
`FrameResult.focusDistance`, white-balance gains) suitable for live UI
readback. The full per-frame payload — both lanes plus metadata — is the
`FrameSet` delivered to zero-copy consumers ([10-advanced-zero-copy-consumers](10-advanced-zero-copy-consumers.md)).

## Reference integration

`ios_example_app/ios_example_app/UI/ViewModel.swift` consumes `stateStream()` and
`frameResultStream()`; `UI/ErrorPresenterViewModel.swift` consumes
`errorStream()`.
