# Controlling the camera

Exposure, focus, white balance, zoom, resolution, and region-of-interest crop.

Assumes you have read <doc:02-getting-started>.

## Capabilities define valid ranges

Every setting is bounded by the ``SessionCapabilities`` returned from
``CameraEngine/open(configuration:)``: ``SessionCapabilities/isoRange``,
``SessionCapabilities/exposureDurationRangeNs``,
``SessionCapabilities/focusRange``, ``SessionCapabilities/zoomRange``,
``SessionCapabilities/evCompensationRange``, and
``SessionCapabilities/supportedSizes``. Read capabilities first and clamp values
to these ranges.

## Applying settings

Camera settings are applied as a whole with
``CameraEngine/updateSettings(_:)``, taking a ``CameraSettings`` value. Read the
current settings with ``CameraEngine/currentSettingsSnapshot()``, and apply a
partial change onto them with ``CameraSettings/merging(onto:)``.

```swift
var settings = await engine.currentSettingsSnapshot()
settings.zoomRatio = 2.0
try await engine.updateSettings(settings)
```

## Auto versus manual

Exposure, ISO, focus, and white balance each have their own mode
(``CameraSettings/isoMode``, ``CameraSettings/exposureMode``,
``CameraSettings/focusMode``, ``CameraSettings/wbMode``). To pin a value, set
both the value and its mode to manual; leave the mode `.auto` to let the device
drive it. ``CameraMode`` is ``CameraMode/auto`` or ``CameraMode/manual``. Setting
a manual value without also setting its mode leaves the device in automatic
control — set them together.

## White balance

``CameraSettings/wbMode`` is ``WhiteBalanceMode/auto``,
``WhiteBalanceMode/locked``, or ``WhiteBalanceMode/manual``. In manual mode, set
the per-channel gains ``CameraSettings/wbGainR``, ``CameraSettings/wbGainG``, and
``CameraSettings/wbGainB``. For calibration-derived gains, see <doc:08-calibration>.

## Zoom and exposure compensation

Set ``CameraSettings/zoomRatio`` within ``SessionCapabilities/zoomRange`` and
``CameraSettings/evCompensation`` within
``SessionCapabilities/evCompensationRange``.

## Resolution

Select the capture resolution by passing a ``Size`` from
``SessionCapabilities/supportedSizes`` — at open via
``OpenConfiguration/captureResolution``, or live via
``CameraEngine/setResolution(size:)``. The size is validated against the device's
supported formats: an unsupported size throws ``EngineError`` (`settingsConflict`)
naming the request and the supported set, and a supported size is applied (it is
not silently snapped). `nil` (the default) selects the device default format. The
active value is reported as ``SessionCapabilities/activeCaptureResolution``.

## Region-of-interest crop

Crop is a **true 1:1 crop** — the output resolution becomes the crop size (no
zoom, no scaling) — and is **disabled by default** (full-frame output). The crop
``Rect`` is expressed in **active capture-resolution pixels**
(``SessionCapabilities/activeCaptureResolution``), not the physical sensor. Every
applied crop, from any entry point, satisfies the same invariants:

- The rect must lie within the active capture resolution.
- All four fields (`x`, `y`, `width`, `height`) must be even (4:2:0 chroma
  alignment).
- The rect must be non-degenerate (non-zero width and height).

A violation throws ``EngineError`` (`settingsConflict`). Apply a pixel-exact
rect directly with ``CameraEngine/setCropRegion(_:)``.

### Center-relative crop

``CameraEngine/setCenterCrop(width:height:offsetX:offsetY:)`` specifies a crop by
output size plus an optional center displacement. `offsetX`/`offsetY` are ratios
of the active resolution (default `0`, centered): the requested center is
`evenNearest(resW/2 + offsetX*resW)` (and likewise for Y), extents snap down to
even and are each capped at the resolution dimension, and the origin is clamped
fully in-bounds.

```swift
// Centered 1440×1440 crop on a 1920×1440 frame → origin (240, 0).
try await engine.setCenterCrop(width: 1440, height: 1440)

// Shift the center right by 10% of the width: center 1152 → origin (432, 0).
try await engine.setCenterCrop(width: 1440, height: 1440, offsetX: 0.1)
```

> Note: the clamp is applied *after* the offset, so an offset on a crop sized to
> fill a dimension is a no-op in that axis — e.g. a 100×100 crop on a 100×100
> frame has only the one legal origin `(0, 0)`, whatever the offset.

### Enable, disable, and the default crop

``CameraEngine/setCropEnabled(_:)`` toggles crop without re-specifying geometry.
Enabling when no geometry was ever configured applies a centered **1440×1440**
package default, clamped to the active resolution (never upscaled). Disabling
returns to full-frame; enabling again restores the most recently configured crop.

Setting a crop — ``CameraEngine/setCropRegion(_:)`` or
``CameraEngine/setCenterCrop(width:height:offsetX:offsetY:)`` — implies crop is
enabled and remembers the geometry. To start cropped at open, pass
``OpenConfiguration/cropEnabled``: `true` applies the default crop when
``OpenConfiguration/cropRegion`` is `nil`, so the first delivered frame is already
cropped (no full-frame-then-crop transition).

> Important: the crop bound moves with the capture resolution. A
> ``CameraEngine/setResolution(size:)`` change rebuilds full-frame and clears the
> remembered crop; re-enable or re-apply afterward.

## Tracker lane resolution

The tracker lane (<doc:01-overview>) is a GPU downscale of the processed image,
sized for lightweight per-frame analysis such as motion tracking. Set its target
height at open via ``OpenConfiguration/trackerHeight``:

```swift
let caps = try await engine.open(
    configuration: OpenConfiguration(trackerHeight: 512))
```

The width is derived to preserve the processed lane's aspect ratio — the two
lanes share an aspect so a measurement on the tracker scales linearly to the
processed frame. The height is clamped to `2 ... outputHeight` (the lane is a
downscale, never an upscale) and rounded down to even. `nil` (the default) uses
the package default height. The value persists across
``CameraEngine/setResolution(size:)`` and ``CameraEngine/setCropRegion(_:)``
rebuilds; read the live tracker buffer's dimensions from
``CameraEngine/currentTrackerTexture()`` or the delivered ``FrameSet/tracker``.

## Settings persistence

Processing parameters persist across launches (<doc:07-image-processing>);
camera settings are applied per session — set them after each
``CameraEngine/open(configuration:)``, or pass
``OpenConfiguration/initialSettings``.

## Reference integration

`ios_example_app/ios_example_app/UI/HardwareControlsViewModel.swift` builds
``CameraSettings`` and calls ``CameraEngine/updateSettings(_:)``,
``CameraEngine/setResolution(size:)``, and ``CameraEngine/setCropRegion(_:)``.
