# CameraKit Documentation

This file is the index into the CameraKit consumer documentation. It
routes you to the guides and the API reference; it contains no API
descriptions itself. Each section below has a grep-able heading of the
form `## SECTION: <name>`.

## SECTION: HOW TO USE THIS INDEX

- **START HERE** — the required reading order for a first integration.
- **GUIDES** — task-oriented guides, in reading order.
- **CAPABILITIES** — what CameraKit can do, each linked to its guide.
- **API REFERENCE** — per-symbol signatures, parameters, and errors.
- **CONVENTIONS** — cross-cutting rules that apply throughout.

## SECTION: START HERE

Read [Overview](guides/01-overview.md) then [Getting started](guides/02-getting-started.md). The order of operations (construct → open → preview → capture → close) lives in the getting-started guide, not here.

## SECTION: GUIDES

- [Overview](guides/01-overview.md) — What CameraKit is; the engine as an actor; the lane model; the lifecycle model.
- [Getting started](guides/02-getting-started.md) — Install, permissions, and the construct → open → preview → capture → close order of operations.
- [Capture format: resolution and frame rate](guides/11-capture-format.md) — Choose resolution and frame rate at open, read the valid space from capabilities, the locked frame rate and fps-bounded exposure, and the always-420f / HDR-off invariants.
- [Lifecycle](guides/03-lifecycle.md) — Forwarding app lifecycle phases to the engine; what each phase reconciles to.
- [Preview](guides/04-preview.md) — The processed and tracker preview lanes and how to render them in any UI framework.
- [Capturing stills and video](guides/05-capturing-stills-and-video.md) — Two ways to capture a graded still, recording, output paths, and saving to Photos.
- [Controlling the camera](guides/06-controlling-the-camera.md) — Exposure, focus, white balance, zoom, resolution, and region-of-interest crop, bounded by capabilities.
- [Image processing](guides/07-image-processing.md) — GPU color adjustments applied to all delivered color output.
- [Calibration](guides/08-calibration.md) — White- and black-balance calibration and reading the result.
- [Observing state and errors](guides/09-observing-state-and-errors.md) — The event streams, session state, errors, and automatic recovery.
- [Advanced: zero-copy consumers](guides/10-advanced-zero-copy-consumers.md) — Opt-in zero-copy frame consumption from Swift or native code.

## SECTION: CAPABILITIES

### CAPABILITY: Lifecycle

#### What it does

Keep the camera correct as the app moves between foreground, inactive, and background by forwarding one phase signal.

#### Where it's documented

[Lifecycle](guides/03-lifecycle.md)

### CAPABILITY: Preview

#### What it does

Display the live camera feed; choose the processed or tracker lane.

#### Where it's documented

[Preview](guides/04-preview.md)

### CAPABILITY: Still capture

#### What it does

Capture a graded photo — either a snapshot of the live stream or a fresh one-shot ISP capture.

#### Where it's documented

[Capturing stills and video](guides/05-capturing-stills-and-video.md)

### CAPABILITY: Video recording

#### What it does

Record video to a file and optionally save it to the Photos library.

#### Where it's documented

[Capturing stills and video](guides/05-capturing-stills-and-video.md)

### CAPABILITY: Capture format (resolution and frame rate)

#### What it does

Choose the capture resolution and frame rate at open from the device's live capabilities; the frame rate is locked and bounds manual exposure. Always full-range 420f, HDR off.

#### Where it's documented

[Capture format: resolution and frame rate](guides/11-capture-format.md)

### CAPABILITY: Camera settings

#### What it does

Set exposure, ISO, focus, white balance, and zoom within the ranges the device reports.

#### Where it's documented

[Controlling the camera](guides/06-controlling-the-camera.md)

### CAPABILITY: Resolution and region-of-interest

#### What it does

Select the capture resolution and apply a true sensor-region crop, expressed in active capture-resolution pixels.

#### Where it's documented

[Controlling the camera](guides/06-controlling-the-camera.md), [Capture format: resolution and frame rate](guides/11-capture-format.md)

### CAPABILITY: Image processing

#### What it does

Adjust brightness, contrast, saturation, black level, and gamma applied to all delivered color output.

#### Where it's documented

[Image processing](guides/07-image-processing.md)

### CAPABILITY: White- and black-balance calibration

#### What it does

Run gray-world white-balance and black-balance calibration and read the result.

#### Where it's documented

[Calibration](guides/08-calibration.md)

### CAPABILITY: State, errors, and recovery

#### What it does

Observe what the camera is doing, handle errors, and rely on automatic interruption recovery.

#### Where it's documented

[Observing state and errors](guides/09-observing-state-and-errors.md)

### CAPABILITY: Zero-copy frame consumers

#### What it does

Consume raw frame sets with zero copy from Swift or native code (advanced).

#### Where it's documented

[Advanced: zero-copy consumers](guides/10-advanced-zero-copy-consumers.md)

## SECTION: API REFERENCE

Per-symbol signatures, parameters, returns, and errors are in the API
reference. Start at [reference/api-index.md](reference/api-index.md).

## SECTION: CONVENTIONS

- The engine is an actor — every call is `async` and must be `await`ed.
- Image processing applies to all delivered color output — the processed stream, the tracker lane, and both still captures.
- Event streams do not replay — subscribe before or around `open()`.
- `SessionCapabilities`, returned by `open()`, bounds every setting and crop.
