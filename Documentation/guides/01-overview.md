# Overview

What CameraKit is, and the two ideas you must hold before writing any code.

## What CameraKit is

CameraKit is a Swift 6 / iOS 26 camera library. It provides dual-lane capture, a
Metal preview, still capture, video recording, GPU image processing, white- and
black-balance calibration, and a sensor-region crop, behind one type:
`CameraEngine`. CameraKit imports no UI framework, so it works with SwiftUI,
UIKit, or a Flutter host.

Two concepts govern everything else. Hold both before reading further.

## The engine is an actor

`CameraEngine` is an `actor`. Every method is `async` and must be `await`ed,
and one engine instance owns one camera session. Construct it once, hold it, and
drive the camera through its methods; observe results through its streams
([09-observing-state-and-errors](09-observing-state-and-errors.md)).

The engine has no `start()` or `stop()`. You declare the host's visibility with
`CameraEngine.setLifecyclePhase(_:)` and the engine reconciles the hardware —
see [03-lifecycle](03-lifecycle.md).

## The lane model

Every streamed frame is produced in two lanes:

- **Processed lane** — the camera image after CameraKit's GPU color pipeline
  (brightness, contrast, saturation, black level, gamma). This is what the
  preview shows.
- **Tracker lane** — the same processed image for lightweight analysis, optionally
  downscaled. Its height is consumer-configurable via
  `OpenConfiguration.trackerHeight` (the width follows the processed lane's
  aspect ratio). When the tracker height equals the primary output height,
  no resampling is performed (1:1 copy). Otherwise CameraKit uses an
  anti-aliased MPS Lanczos downscale. See [06-controlling-the-camera](06-controlling-the-camera.md).

(There is no streamed "natural" lane. An earlier un-graded streaming lane was
removed; the pre-grade image now exists only internally, to seed white- and
black-balance calibration.)

This distinction recurs across the API:

- Preview: `CameraEngine.currentProcessedTexture()` is the processed lane;
  `CameraEngine.currentTrackerTexture()` is the tracker lane.
- Still capture: both `CameraEngine.captureImage(outputURL:photosDestination:)`
  and `CameraEngine.captureNaturalPicture(outputURL:photosDestination:)` return
  a **graded** still; they differ only in source — `captureImage` snapshots the
  live processed stream, `captureNaturalPicture` takes a fresh one-shot ISP
  capture. See [05-capturing-stills-and-video](05-capturing-stills-and-video.md).
- Processing: `CameraEngine.setProcessingParams(_:)` affects all delivered
  color output — the processed stream, the tracker lane, and both stills.

## The lifecycle model

The host observes its own app lifecycle and forwards each phase to the engine
with `CameraEngine.setLifecyclePhase(_:)`. The engine owns everything
downstream: the GPU gate, session start/stop, stall watchdogs, recording
finalize, and OS interruption recovery. You forward a phase; CameraKit does the
rest. Full detail in [03-lifecycle](03-lifecycle.md).

## What you own versus what CameraKit owns

| You own | CameraKit owns |
| --- | --- |
| Observing your app's lifecycle and forwarding the phase | Session start/stop, GPU gate, watchdogs |
| Issuing commands (capture, record, settings, processing) | OS interruption detection and recovery |
| Rendering the preview surface into your UI | Frame production, the dual-lane pipeline |

## Next

Read [02-getting-started](02-getting-started.md) for a first working integration.
