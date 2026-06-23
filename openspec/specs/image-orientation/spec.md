# image-orientation Specification

## Purpose
TBD - created by archiving change image-orientation. Update Purpose after archive.
## Requirements
### Requirement: Streamed outputs are horizontally mirrored

The streaming color path SHALL be horizontally mirrored (left-right). The mirror MUST be applied at
the `AVCaptureVideoDataOutput` connection (`isVideoMirrored`), which physically flips the delivered
pixel buffers before the Metal pipeline, so that **preview, `captureImage`, the tracker lane, and
recording** are all mirrored consistently. The mirror MUST NOT be implemented as a Metal shader
operation.

#### Scenario: Preview and captureImage are mirrored

- **WHEN** the camera is streaming
- **THEN** the preview and a `captureImage` still are horizontally mirrored (left-right)
- **AND** the tracker lane and any recording produced from the streaming path are mirrored the same way

### Requirement: Natural still is not mirrored

`captureNaturalPicture` SHALL reflect the native, un-mirrored ISP geometry. Because it is sourced
from a separate `AVCapturePhotoOutput` one-shot whose connection mirroring is not applied to the raw
`photo.pixelBuffer`, the photo-output connection MUST NOT be relied upon for mirroring, and the
natural still MUST remain un-mirrored — an intentional asymmetry with the streamed outputs.

#### Scenario: captureNaturalPicture is un-mirrored

- **WHEN** `captureNaturalPicture` is called while preview and `captureImage` are mirrored
- **THEN** the resulting still is NOT horizontally mirrored (native ISP geometry)

#### Scenario: Mirror affects orientation only, not grading

- **WHEN** comparing a `captureImage` still to a `captureNaturalPicture` still of the same scene
- **THEN** they differ in horizontal orientation only; both are still color-graded by the pipeline

