## 1. Per-lane Frame streams

- [ ] 1.1 Split `PixelSink.swift`: keep the Swift consumer registry, isolate the C-ABI sink for removal (§3)
- [ ] 1.2 Change `subscribe(stream:buffering:)` to return `AsyncThrowingStream<Frame>` for a single lane
- [ ] 1.3 Construct per-lane `Frame` (lane, index, timestampNs ns, `PixelHandle`, metadata) at the MetalPipeline delivery site; stop delivering the bundled `FrameSet`
- [ ] 1.4 Remove the `FrameSet` type (and its `Hashable` conformance)

## 2. Lane rename + Flutter ripple

- [ ] 2.1 Rename `StreamId.processed → .primary` across CameraKit (`SessionState`, `MetalPipeline`, `CameraEngine`, docs)
- [ ] 2.2 Update the Pigeon DSL + regenerate the Swift/Dart/Kotlin `StreamId` mirrors (`processed→primary`)
- [ ] 2.3 Update `TextureBridge` to `.primary`

## 3. Buffering policy + termination

- [ ] 3.1 Thread `BufferingPolicy` through `subscribe`; `.primary` → `latestWins`, `.tracker` → `keepBuffered(depth:)`; remove the hardwired `.bufferingNewest(1)`
- [ ] 3.2 Finish the lane stream by throwing on `CameraError.isFatal`; keep it open across transient/recoverable faults; keep `errorStream()` for observability

## 4. Lease + tracker-absent + tracker size

- [ ] 4.1 Add `lockedPixels() -> PixelHandle` (lease-returning) on the lane buffer
- [ ] 4.2 Remove `trackerForSet = trackerBuf ?? processedForSet`; deliver no tracker frame when unsubscribed/unrendered
- [ ] 4.3 Confirm `OpenConfiguration.trackerHeight` drives the delivered tracker size exactly (no silent re-resize)

## 5. Remove the C-ABI PixelSink path

- [ ] 5.1 Remove `CameraKitCxx` `PixelSink.hpp`/`PixelSinkPool.cpp`/`PixelSinkCallbacks.h`/`PixelSinkMetrics.h`/`CaptureAtomic`
- [ ] 5.2 Remove the `CameraKitInterop` bridge and the C-ABI dispatch wiring in `CameraEngine`
- [ ] 5.3 Leave the AppCxx demos + Flutter demo broken (no repair) — record as accepted breakage

## 6. Verification

- [ ] 6.1 Build CameraKit + Flutter plugin green (demos excluded/broken is acceptable)
- [ ] 6.2 Tests: per-lane delivery yields single-lane `Frame`; tracker absent when unsubscribed; throwing-stream throws on fatal, survives transient
- [ ] 6.3 `openspec validate frame-delivery-rework --strict` passes
