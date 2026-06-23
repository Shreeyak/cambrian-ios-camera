# Tasks

> Retroactive record — all work already shipped in v1.5.0.

## 1. Implementation (done)

- [x] 1.1 Set `isVideoMirrored = true` on the `AVCaptureVideoDataOutput` connection (CameraSession.swift), guarded by `isVideoMirroringSupported`.
- [x] 1.2 Leave the `AVCapturePhotoOutput` connection un-mirrored, with an explicit code comment explaining that connection mirroring does not apply to `photo.pixelBuffer`.

## 2. Verification (done)

- [x] 2.1 Verified on device: preview is mirrored (confirmed on the iPad).
- [x] 2.2 Verified `captureNaturalPicture` is not mirrored (photo-output mirror had no effect; reverted).
