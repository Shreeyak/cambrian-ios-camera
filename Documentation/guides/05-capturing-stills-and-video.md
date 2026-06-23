# Capturing stills and video

Producing photo and video files — and which lane each one captures.

Assumes you have read [01-overview](01-overview.md).

## Stills: captureImage vs captureNaturalPicture

Two methods capture a still. **Both apply the current `ProcessingParameters`**
(brightness, contrast, saturation, black level, gamma) — they differ in the
*source* frame, not in whether processing is applied:

- `CameraEngine.captureImage(outputURL:photosDestination:)` snapshots the
  latest **processed streaming frame** — the same pixels the preview shows. It
  works even while the session is paused (it returns the last delivered frame).
- `CameraEngine.captureNaturalPicture(outputURL:photosDestination:)` triggers a
  **fresh one-shot capture from the camera's image sensor/ISP** — a dedicated
  photo, not a grab of the live stream — then runs it through the same crop and
  color pipeline. It requires a **running session** and throws if the session is
  paused.

> The name `captureNaturalPicture` is historical: "natural" means it takes a
> dedicated ISP capture, **not** that it skips processing. Its output is graded
> exactly like `captureImage`. Set `CameraEngine.setProcessingParams(_:)`
> before capturing to control the look of either one.

Both return a `StillCaptureOutput` whose `StillCaptureOutput.filePath` is the
written file.

```swift
let output = try await engine.captureImage()        // snapshot of the live preview
// output.filePath is the saved image.
```

## Output paths

Pass an `outputURL` to choose the destination; pass `nil` (the default) to write
to a CameraKit-chosen path under the app's Documents directory. The returned
`StillCaptureOutput.filePath` is always the actual location.

## Recording

Start and stop recording with `CameraEngine.startRecording(options:)` and
`CameraEngine.stopRecording()`:

```swift
let options = RecordingOptions(bitrateBps: 10_000_000, fps: 30, outputURL: nil)
let start = try await engine.startRecording(options: options)  // start.uri
// ... later ...
try await engine.stopRecording()
```

`RecordingOptions` carries `RecordingOptions.bitrateBps`,
`RecordingOptions.fps`, `RecordingOptions.outputURL`, and
`RecordingOptions.photosDestination`. `RecordingStart` returns the
`RecordingStart.uri` and `RecordingStart.displayName` of the new file.

## Saving to Photos

Set `RecordingOptions.photosDestination` (or the `photosDestination:` argument
on a still) to copy or move the output into the Photos library:

- `PhotosDestination.none` — leave the file where it is (default).
- `PhotosDestination.copy` — also copy it to Photos.
- `PhotosDestination.move` — move it to Photos.

Saving to Photos requires `NSPhotoLibraryAddUsageDescription` in `Info.plist`.

## Observing recording state

Subscribe to `CameraEngine.recordingStateStream()` to track progress:
`RecordingState.recording`, `RecordingState.finalizing`, and
`RecordingState.idle(lastUri:)` after a recording finalizes. See
[09-observing-state-and-errors](09-observing-state-and-errors.md).

## Backgrounding while recording

A recording is finalized when you forward `AppLifecyclePhase` `.background`
([03-lifecycle](03-lifecycle.md)). Forward lifecycle natively (not over an async hop) so a
backgrounding cannot outrun the finalize and truncate the file.

## Reference integration

`ios_example_app/ios_example_app/UI/RecordingViewModel.swift` drives
`startRecording`/`stopRecording` and observes `recordingStateStream()`.
