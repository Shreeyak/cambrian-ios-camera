## ADDED Requirements

### Requirement: In-memory natural-still delivery

CameraKit SHALL provide a `captureNaturalPictureBuffer()` method that returns the graded natural still
as an **IOSurface-backed `CVPixelBuffer` in the processed-lane format (BGRA8)** and SHALL NOT write a
file, encode to any image format, or publish to Photos. It SHALL apply the same crop and grade as the
file-based path (identical `renderStill` output). The existing `captureNaturalPicture` file-based method
SHALL be unchanged. Both methods SHALL share their capture code (guard, ISP one-shot, crop+grade) so
they differ only in delivery.

#### Scenario: Buffer method returns an IOSurface-backed BGRA8 buffer without a file

- **WHEN** `captureNaturalPictureBuffer()` is called on a running session
- **THEN** it returns an IOSurface-backed `CVPixelBuffer` in the processed-lane BGRA8 format
- **AND** no file is written to disk and nothing is published to Photos

#### Scenario: File-based capture is unchanged

- **WHEN** `captureNaturalPicture(outputURL:photosDestination:)` is called
- **THEN** the graded still is encoded to the resolved output file and a `StillCaptureOutput` file result is returned, exactly as before this change (same signature and behavior)

#### Scenario: Returned buffer has an explicit lifetime contract

- **WHEN** the caller receives the in-memory buffer
- **THEN** it is delivered as a leased handle the caller owns and must release
- **AND** the underlying IOSurface remains valid until the caller releases the lease (it is not recycled underneath the caller)

#### Scenario: Buffer capture still requires a running session

- **WHEN** `captureNaturalPictureBuffer()` is called while the engine is not open or the session is not running
- **THEN** it throws the same `notOpen` / capture-`bufferUnavailable` errors as the file method (both entry points share the capture guards)
