## 1. Typed per-frame metadata

- [x] 1.1 Define `CameraFrameMetadata: FrameMetadata` with `settled`, `focusState`, `wbState`, `exposureState` (+ the supporting state enums)
- [x] 1.2 Thread `DeviceStateSnapshot` (`device.lastSnapshot`) into the MetalPipeline completion handler, replacing the zero-valued `CaptureMetadata` placeholder
- [x] 1.3 Compute `settled = AE-converged && WB-settled && focus-converged`; populate the individual state fields
- [x] 1.4 Attach `CameraFrameMetadata` to each delivered `Frame`

## 2. 3 Hz JSON debug channel

- [x] 2.1 Add a JSON diagnostics payload field to `FrameResult` and populate it from the forwarded camera-library state (AF status, WB settling, AE state)
- [x] 2.2 Route the former `ProcessingMetadata` grade params (brightness/contrast/saturation/gamma/cropRegion/wbGains) into the JSON payload; stop delivering them as per-frame metadata

## 3. Remove fabricated signals

- [x] 3.1 Remove the hardcoded `blurScore = 0.0` / `trackerQuality = .good` assignments
- [x] 3.2 Remove the `blurScore`/`trackerQuality` fields and the `TrackerQuality` enum

## 4. Verification

- [x] 4.1 Test: a mid-autofocus frame has `settled == false` and `focusState` adjusting; a converged frame has `settled == true`
- [x] 4.2 Test: grade params appear only in the 3 Hz JSON, not on per-frame metadata
- [x] 4.3 Confirm no `blurScore`/`trackerQuality` symbols remain
- [x] 4.4 `openspec validate frame-metadata-signals --strict` passes
