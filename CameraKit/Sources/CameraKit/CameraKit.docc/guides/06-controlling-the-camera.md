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

Change the capture resolution with ``CameraEngine/setResolution(size:)``, passing
a ``Size`` from ``SessionCapabilities/supportedSizes``. The active value is
reported as ``SessionCapabilities/activeCaptureResolution``.

## Region-of-interest crop

``CameraEngine/setCropRegion(_:)`` applies a true 1:1 crop: the output resolution
becomes the crop-region size. The ``Rect`` is expressed in **active
capture-resolution pixels** — ``SessionCapabilities/activeCaptureResolution`` —
not the physical sensor. Constraints:

- The rect must lie within the active capture resolution.
- All four fields (`x`, `y`, `width`, `height`) must be even (4:2:0 chroma
  alignment).
- The rect must be non-degenerate (non-zero width and height).

A violation throws ``EngineError`` (`settingsConflict`). You may also set an
initial crop at open via ``OpenConfiguration/cropRegion``.

> Important: the crop bound moves with the capture resolution. Because the rect
> is validated against ``SessionCapabilities/activeCaptureResolution``, a crop
> that is valid at one resolution may be out of bounds after
> ``CameraEngine/setResolution(size:)`` selects a smaller format. Re-apply the
> crop after changing resolution.

## Settings persistence

Processing parameters persist across launches (<doc:07-image-processing>);
camera settings are applied per session — set them after each
``CameraEngine/open(configuration:)``, or pass
``OpenConfiguration/initialSettings``.

## Reference integration

`ios_example_app/ios_example_app/UI/HardwareControlsViewModel.swift` builds
``CameraSettings`` and calls ``CameraEngine/updateSettings(_:)``,
``CameraEngine/setResolution(size:)``, and ``CameraEngine/setCropRegion(_:)``.
