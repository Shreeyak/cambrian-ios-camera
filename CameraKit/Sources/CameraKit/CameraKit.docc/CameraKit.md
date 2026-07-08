# ``CameraKit``

A Swift 6 / iOS 26 camera library: dual-lane capture (natural and processed),
Metal preview, recording, still capture, GPU image processing, white-balance
calibration, and sensor-region crop, behind a single declarative lifecycle API.

## Overview

The engine is an actor (``CameraEngine``); every call is `async`. The host
forwards app lifecycle phases and the engine reconciles capture, GPU, and
recording state. CameraKit imports no UI framework.

New integrators should read the guides in order, starting with
<doc:01-overview> and <doc:02-getting-started>.

## Topics

### Guides

- <doc:01-overview>
- <doc:02-getting-started>
- <doc:11-capture-format>
- <doc:03-lifecycle>
- <doc:04-preview>
- <doc:05-capturing-stills-and-video>
- <doc:06-controlling-the-camera>
- <doc:07-image-processing>
- <doc:08-calibration>
- <doc:09-observing-state-and-errors>
- <doc:10-advanced-zero-copy-consumers>
