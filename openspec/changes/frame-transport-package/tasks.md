## 1. Package scaffolding

- [x] 1.1 Add a `FrameTransport` SPM target + product in `Package.swift` with no AVFoundation dependency (CoreVideo/IOSurface/Foundation only)
- [x] 1.2 Confirm the target builds for both an iOS and a macOS (Designed-for-iPad / native) destination
- [x] 1.3 Add the `CameraKit → FrameTransport` dependency edge

## 2. Core types

- [x] 2.1 Define `Lane { primary, tracker }`, `PixelFormat { bgra8 }`, `BufferingPolicy { blocking, latestWins, keepBuffered(depth:) }`
- [x] 2.2 Define `FrameMetadata` marker protocol (`Sendable`)
- [x] 2.3 Define `PixelHandle` as a `final class @unchecked Sendable` with `baseAddress/width/height/bytesPerRow/format` and a `deinit` that unlocks + releases the IOSurface/CVPixelBuffer
- [x] 2.4 Define `Frame { lane, index, timestampNs, pixels, metadata }` (`Sendable`)

## 3. Verification

- [x] 3.1 Add a unit test asserting `FrameTransport` exposes the types without importing CameraKit
- [x] 3.2 Add a `PixelHandle` test: `bytesPerRow` reflects a padded stride (not `width*4`) and the lock releases on deinit
- [x] 3.3 Add a `BufferingPolicy` semantics test (keepBuffered drops oldest; latestWins keeps newest)
- [x] 3.4 `openspec validate frame-transport-package --strict` passes
