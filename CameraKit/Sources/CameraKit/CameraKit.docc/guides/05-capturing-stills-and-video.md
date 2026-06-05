# Capturing stills and video

Producing photo and video files — and which lane each one captures.

Assumes you have read <doc:01-overview>.

## Stills: processed versus natural

Two methods capture a still, differing only in lane:

- ``CameraEngine/captureImage(outputURL:photosDestination:)`` captures the
  **processed** lane (color pipeline applied).
- ``CameraEngine/captureNaturalPicture(outputURL:photosDestination:)`` captures
  the **natural** lane (unprocessed).

Both return a ``StillCaptureOutput`` whose ``StillCaptureOutput/filePath`` is the
written file.

```swift
let output = try await engine.captureImage()        // processed lane
// output.filePath is the saved image.
```

If a color adjustment is missing from a captured image, you called
`captureNaturalPicture` — that lane is intentionally unprocessed.

## Output paths

Pass an `outputURL` to choose the destination; pass `nil` (the default) to write
to a CameraKit-chosen path under the app's Documents directory. The returned
``StillCaptureOutput/filePath`` is always the actual location.

## Recording

Start and stop recording with ``CameraEngine/startRecording(options:)`` and
``CameraEngine/stopRecording()``:

```swift
let options = RecordingOptions(bitrateBps: 10_000_000, fps: 30, outputURL: nil)
let start = try await engine.startRecording(options: options)  // start.uri
// ... later ...
try await engine.stopRecording()
```

``RecordingOptions`` carries ``RecordingOptions/bitrateBps``,
``RecordingOptions/fps``, ``RecordingOptions/outputURL``, and
``RecordingOptions/photosDestination``. ``RecordingStart`` returns the
``RecordingStart/uri`` and ``RecordingStart/displayName`` of the new file.

## Saving to Photos

Set ``RecordingOptions/photosDestination`` (or the `photosDestination:` argument
on a still) to copy or move the output into the Photos library:

- ``PhotosDestination/none`` — leave the file where it is (default).
- ``PhotosDestination/copy`` — also copy it to Photos.
- ``PhotosDestination/move`` — move it to Photos.

Saving to Photos requires `NSPhotoLibraryAddUsageDescription` in `Info.plist`.

## Observing recording state

Subscribe to ``CameraEngine/recordingStateStream()`` to track progress:
``RecordingState/recording``, ``RecordingState/finalizing``, and
``RecordingState/idle(lastUri:)`` after a recording finalizes. See
<doc:09-observing-state-and-errors>.

## Backgrounding while recording

A recording is finalized when you forward ``AppLifecyclePhase`` `.background`
(<doc:03-lifecycle>). Forward lifecycle natively (not over an async hop) so a
backgrounding cannot outrun the finalize and truncate the file.

## Reference integration

`ios_example_app/ios_example_app/UI/RecordingViewModel.swift` drives
`startRecording`/`stopRecording` and observes `recordingStateStream()`.
