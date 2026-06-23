## Why

The camera image is horizontally flipped (left-right mirrored) for display, shipped in v1.5.0.
This change is a **retroactive record** of that already-implemented behavior so the
mirrored-vs-un-mirrored contract is captured in `openspec/specs/` and cannot be silently
regressed. There is a deliberate, non-obvious asymmetry worth specifying: the streamed outputs are
mirrored, but the natural still is not.

## What Changes

- The streaming path is horizontally mirrored at the `AVCaptureVideoDataOutput` connection
  (`isVideoMirrored = true`), so **preview, `captureImage`, the tracker lane, and recording** are
  all mirrored.
- **`captureNaturalPicture` is NOT mirrored** — it is sourced from a separate `AVCapturePhotoOutput`
  one-shot, which does not apply connection mirroring to the raw `photo.pixelBuffer`. It therefore
  reflects the native (un-mirrored) ISP geometry. This asymmetry is intentional.
- The mirror is applied at the capture-connection level (AVFoundation), not in the Metal shaders.

(No new code — this records behavior already present in `CameraSession.swift`.)

## Capabilities

### New Capabilities
- `image-orientation`: The horizontal-mirror contract for delivered images — which outputs are
  mirrored, which are not, and where the mirror is applied.

### Modified Capabilities
<!-- None. -->

## Impact

- `CameraKit/Sources/CameraKit/CameraSession.swift` — `isVideoMirrored` on the video-data-output
  connection; explicit note that the photo-output connection is intentionally not mirrored.
- Behavioral contract for consumers of preview, `captureImage`, `captureNaturalPicture`, tracker,
  and recording.
