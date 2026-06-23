# Image processing

GPU color adjustments, applied to the processed lane.

Assumes you have read [01-overview](01-overview.md).

## ProcessingParameters

`ProcessingParameters` carries the color controls applied by the GPU
pipeline: `ProcessingParameters.brightness`, `ProcessingParameters.contrast`,
`ProcessingParameters.saturation`, the per-channel black levels
`ProcessingParameters.blackR` / `ProcessingParameters.blackG` /
`ProcessingParameters.blackB`, and `ProcessingParameters.gamma`.

Apply them with `CameraEngine.setProcessingParams(_:)`:

```swift
var params = await engine.currentProcessingParametersSnapshot()
params.brightness = 0.1
params.contrast = 1.2
await engine.setProcessingParams(params)
```

## What these adjustments apply to

Processing applies to all delivered color output: the processed (preview)
stream, the tracker lane, and **both** still-capture methods.
`CameraEngine.captureImage(outputURL:photosDestination:)` and
`CameraEngine.captureNaturalPicture(outputURL:photosDestination:)` run the
same color pipeline (see [05-capturing-stills-and-video](05-capturing-stills-and-video.md)), so both reflect
the current parameters. There is no un-graded delivery path — the pre-grade
image exists only internally, to seed white- and black-balance calibration.

## The identity baseline

`ProcessingParameters.identity` is the no-op configuration: brightness 0,
contrast 1, saturation 1, zero black levels, gamma 1. Start from it for a clean
baseline, or from the current snapshot to adjust a single field.

## Applying and persisting

Processing parameters persist across launches. Read the persisted value with
`CameraEngine.getPersistedProcessingParameters()` and the live value with
`CameraEngine.currentProcessingParametersSnapshot()`. Set a new value with
`CameraEngine.setProcessingParams(_:)`, which takes effect on the next
processed frame.

## Reference integration

`ios_example_app/ios_example_app/UI/ProcessingViewModel.swift` builds
`ProcessingParameters` and calls `CameraEngine.setProcessingParams(_:)`.
