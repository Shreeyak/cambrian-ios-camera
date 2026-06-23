## Context

Retroactive record of the horizontal-mirror behavior shipped in v1.5.0. The implementation already
exists in `CameraSession.swift`; this document captures the rationale behind the design so the
contract is durable. No new work is implied.

## Goals / Non-Goals

**Goals:**
- Record where and why the horizontal mirror is applied, and why the natural still is exempt.

**Non-Goals:**
- Changing the behavior, making the mirror configurable, or mirroring `captureNaturalPicture`.

## Decisions

### Apply the mirror at the video-data-output connection, not in Metal
`isVideoMirrored = true` on the `AVCaptureVideoDataOutput` connection physically flips the delivered
`CVPixelBuffer`s before they reach the Metal pipeline. This is one setting, zero GPU cost, and every
streamed consumer (preview, `captureImage`, tracker, recording) inherits it from a single source.
*Alternative:* flip in a Metal kernel — unnecessary for the current spec (more code, and the
connection setting already covers all streamed outputs).

### Leave `captureNaturalPicture` un-mirrored (intentional asymmetry)
The natural still comes from a separate `AVCapturePhotoOutput` one-shot. Setting `isVideoMirrored`
on the photo connection had no effect — `AVCapturePhotoOutput` does not apply it to the raw
`photo.pixelBuffer` (at most it tags orientation metadata, which the code ignores). Rather than work
around this, the natural still is left reflecting native ISP geometry, which is acceptable for its
use. The photo-output mirror attempt was removed.

## Risks / Trade-offs

- [Consumers may assume all outputs share orientation] → Mitigation: this spec documents the
  asymmetry explicitly; code comments in `CameraSession.swift` state the photo connection is
  intentionally not mirrored.
