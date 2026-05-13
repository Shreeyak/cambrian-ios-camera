# Error-surfacing follow-ups (post Piece 2)

**Status:** noted by Shreeyak during 2026-05-13 HITL of Piece 2; deferred.

## Context

Piece 2 (`feat(stage-11): unified outputURL + PhotosDestination for stills + video`)
landed two error contracts:

1. **Photos publish failures (non-fatal)** — both `engine.captureImage(...)` and
   `engine.stopRecording()` now emit a `CameraError(.unknownError, isFatal:false)`
   on the public `errorStream()` when `PhotosLibraryClient.publish` throws.
   The on-disk file is preserved either way. See `CameraEngine.swift`
   §captureImage and §stopRecording.
2. **Sandbox-escape (fatal-to-the-call)** — `RecordingOptions.outputURL` resolving
   outside `NSHomeDirectory()` makes `engine.startRecording(...)` throw
   `EngineError.invalidOutputPath(URL)`. Same for `engine.captureImage(...)`.

## Two gaps observed in HITL

### Gap 1 — Recording sandbox-escape never reaches the UI

`RecordingViewModel.toggleRecording` catches `engine.startRecording(...)`
errors and only `CameraKitLog.error(...)`s them — no UI surface. Result:
when `outputURL` is invalid (HITL step 10), the user taps REC, nothing
happens, and there is no on-screen indication of what went wrong.

```swift
// RecordingViewModel.swift:67–69 — current behaviour
} catch {
    CameraKitLog.error(.engine, "[recording] startRecording threw: \(error)")
}
```

Fix: route the caught error into the same UI path the parent uses for
capture errors (`ViewModel.captureResult` banner pattern, or a sibling
`recordingError` published on the view model). Apply consistently to
`stopRecording()`'s catch as well.

### Gap 2 — `errorStream()` has no subscriber in the host app

Photos publish failures now publish on `engine.errorStream()` (Piece 2's
addition). No code in `eva-swift-stitch/`, `ViewModel.swift`,
`RecordingViewModel.swift`, or `CameraView.swift` consumes that stream.
Failures appear in the device log only — invisible to the user.

The contract is intentional: **non-fatal library errors flow on
`errorStream()`; the host app decides how loud to be.** But the host app
needs to actually subscribe. Today nothing does.

Fix sketch: a single `Task` in `ViewModel.init` (parent VM, owns the engine
lifecycle) that consumes `engine.errorStream()` and routes entries to the
existing banner UI. Severity-aware — `isFatal:false` → toast, `isFatal:true`
→ persistent error sheet.

## Suggested ordering when picked up

1. Wire `engine.errorStream()` consumer in the parent view model (Gap 2).
2. Update `RecordingViewModel.toggleRecording`'s catch to publish to the
   same error UI path (Gap 1).
3. Add a UI smoke test: deny Photos in Settings, record, expect a banner.
4. Add a UI smoke test: pass an invalid `outputURL`, tap REC, expect a banner.

Both gaps are self-contained host-app work; no further changes needed in
`CameraKit/`.
