# Preview

Displaying the live camera feed, and choosing which lane to show.

Assumes you have read [01-overview](01-overview.md).

## The preview lanes

CameraKit streams the current frame in two lanes (see the lane model in
[01-overview](01-overview.md)):

- **Processed** — the camera image after the GPU color pipeline
  ([07-image-processing](07-image-processing.md)). This is the lane most previews show.
- **Tracker** — a downscaled processed image for lightweight analysis.

Choose the lane that matches what the user should see. A camera UI that applies
live color adjustments shows the processed lane.

## Choosing an output type

The accessors are `nonisolated`, so you may call them directly from a render
loop without `await`:

| You render with | Use | Returns |
| --- | --- | --- |
| Metal | `CameraEngine.currentProcessedTexture()` / `CameraEngine.currentTrackerTexture()` | `MTLTexture?` |
| Core Video | `CameraEngine.currentPixelBuffer(stream:)` | `CVPixelBuffer?` |

`StreamId` selects the lane for the pixel-buffer path: `StreamId.primary`
(the processed lane) or `StreamId.tracker`. (The streaming natural lane was
removed; `CameraEngine.captureNaturalPicture(outputURL:photosDestination:)`
still captures a one-shot still on demand — graded like `captureImage`; see
[05-capturing-stills-and-video](05-capturing-stills-and-video.md).)

## Rendering with Metal

Read the lane's texture each frame and blit it into your drawable:

```swift
// In your MTKView draw loop (nonisolated — no await needed):
guard let tex = engine.currentProcessedTexture() else { return }
// blit `tex` into view.currentDrawable, then present.
```

Acquire the drawable, clear it, do the blit conditionally, and always present —
never return between acquiring a drawable and presenting it.

## Rendering elsewhere

For a non-Metal host, read the pixel buffer for the chosen lane:

```swift
guard let pb = engine.currentPixelBuffer(stream: .primary) else { return }
// draw `pb` (e.g. via Core Image or a CVMetalTextureCache).
```

A native or Flutter host instead obtains the pipeline handle from
`CameraEngine.getNativePipelineHandle()` and binds it to its own texture
bridge.

## Frame freshness

Each accessor returns the latest available frame; reads are non-blocking and the
newest frame wins. There is no queue to drain — call the accessor every frame
and render whatever it returns.

## Reference integration

`ios_example_app/ios_example_app/UI/DisplayViewModel.swift` exposes
`engine.currentProcessedTexture()` as a `nonisolated` property; `UI/CameraView.swift`
blits it in a Metal view.
