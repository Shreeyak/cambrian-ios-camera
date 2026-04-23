# state.md — Stage 08

## Current stage
Stage 08 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 09 must run before modifying sources):
```
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Must return ≥1 hit before any Stage 09 edit.

## What's built — Stage 08 (permanent)

- `CameraKitCxx` SPM target (C++20) — `PixelSink.hpp` abstract class; `PixelSinkCallbacks.h` C-ABI struct; `PixelSinkPool.cpp` (`std::mutex`-guarded, `pipeline > stage > consumer` lock order per D-16, thread cap `CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency)`); `CaptureAtomic.cpp` (`std::atomic<bool>` CAS, C-ABI bridge); `CannyStubConsumer.cpp` (real OpenCV v4.13 Canny, 64-entry ring buffer of edge counts per ADR-29).
- `CameraKitInterop` Swift target (`.interoperabilityMode(.Cxx)` per ADR-13) — `CppPixelSinkPool`; `CppCaptureAtomic`; `CppCannyStub` with `edgeCount(at:)`.
- `Frameworks/opencv2.xcframework` — flat arm64-only xcframework (converted from versioned macOS framework via lipo + xcodebuild).
- `PixelSink.swift` — `ConsumerRegistry.registerCallback(stream:callbacks:)` real implementation backed by `CppPixelSinkPool`; dual-dispatch `yield()` to both Swift `AsyncStream` subscribers and C++ pool; `nativePipelinePointer()`.
- `StillCapture.swift` — `captureInFlight: CppCaptureAtomic`; `ManagedAtomic<Bool>` and `import Atomics` removed.
- `MetalPipeline.swift` / `TexturePoolManager.swift` / `Shaders/ColorShaders.metal` — `01:simple-metal-passthrough` scaffold comments removed.
- `CameraEngine.swift` — `getNativePipelineHandle() -> UInt64?` real implementation.
- `Errors.swift` — `InteropError.invalidCallbacks` and `.retainMismatch` added; `.notWired` removed.
- `Constants.swift` — `cppPoolThreadCount` added.
- `Package.swift` — `binaryTarget(opencv2)`, `CameraKitCxx`, `CameraKitInterop` targets; `.interoperabilityMode(.Cxx)` on `CameraKit` + `CameraKitTests` (required by Swift's transitive C++ interop rule, decision 38).
- `eva-swift-stitch.xcodeproj` — `OTHER_SWIFT_FLAGS += -cxx-interoperability-mode=default` on `eva-swift-stitch` + `eva-swift-stitchTests` (both Debug + Release).
- `Stage08Tests.swift` — 7 `@Test` functions.

## Public API exposed — Stage 08

```swift
public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) async throws -> ConsumerToken  // ConsumerRegistry (real)
public func getNativePipelineHandle() -> UInt64?  // CameraEngine
```

## Manual test evidence — Stage 08

| Test ID | Status | Notes |
|---------|--------|-------|
| `08:cpp-pixelsink-registration-roundtrip` | PASS | Stage08Tests |
| `08:canny-stub-consumer-receives-tracker-frames` | PASS | Stage08Tests |
| `08:get-native-pipeline-handle-holds-actor` | PASS | Stage08Tests (nil path) |
| `08:c-abi-callbacks-without-on-frame-rejected` | PASS | Stage08Tests |
| `08:lock-order-pipeline-stage-consumer` | PASS | Stage08Tests (concurrent dispatch, no deadlock) |
| `08:still-capture-uses-cpp-atomic` | PASS | Stage08Tests |
| `08:swift-subscribe-is-facade-over-cpp-pool` | PASS | Stage08Tests |
| `06:frame-set-publication` | PASS | carried forward |
| `06:swift-consumer-drop-on-busy` | PASS | carried forward |
| `07:still-capture-in-flight-guard` | PASS | carried forward |
| `08:external-canny-stub-runs-on-device` | PENDING | `measurements/stage-08/canny.md` — awaiting device run |

## Decisions taken that weren't in briefs — Stage 08

See decisions 35–38 in `CameraKit/DECISIONS.md`.

## Open questions for next stage

1. **HITL `08:external-canny-stub-runs-on-device`** — pending device run; evidence template in `measurements/stage-08/canny.md`.
2. **ADR-13 upstream revision** — C++ interop transitivity requires all importers to enable the flag; upstream should revise ADR-13.
3. **OpenCV xcframework Mac slice** — xcframework contains only `ios-arm64`; Mac "Designed for iPad" fallback build unverified for Stage 08 C++ targets.
4. **Carried open questions from Stage 07** (focalLengthMm, sigmoid curve, D-17 revision).

# state.md — Stage 07

## Current stage
Stage 07 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `06:simple-consumer-swift-only` | `PixelSink.swift` | `registerCallback` throws `notWired` | Stage 08 |
| `07:swift-side-capture-atomic` | `StillCapture.swift` | `captureInFlight: ManagedAtomic<Bool>` | Stage 08 |

Pre-flight grep command (Stage 08 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only\|07:swift-side-capture-atomic' CameraKit/Sources/
```
All four slugs must return ≥1 hit before any Stage 08 edit.

## What's built — Stage 07 (permanent)

- `FrameSet.swift` — `extension CVPixelBuffer: @retroactive @unchecked Sendable {}` added (G-13: CVPixelBuffer not yet Sendable on iOS 26; IOSurface + GPU-completion ordering make cross-thread use safe; required for `CheckedContinuation<CVPixelBuffer, Error>` in Stage 07).
- `Errors.swift` — `StillCaptureError.captureInProgress` renamed to `alreadyInFlight`; `EngineError.capture(StillCaptureError)` case added.
- `TexturePoolManager.swift` — `makeStillCapturePool(size:)`: 1-slot, IOSurface-backed, RGBA16F pool for CPU-readable still capture readback.
- `MetalPipeline.swift` — `stillCapturePool` (dedicated 1-slot); `pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?` mailbox (`nonisolated(unsafe)`); `stillBufForCompletion` captured before closure (avoids Swift 6 tuple-send warning); Pass 6 (blit `processedTexI → stillReadbackBuffer` at zero origins, gated on `pendingCaptureContinuation != nil`); completion-handler delivery of readback buffer; `armCapture(continuation:)` method; `stillCapturePoolForTest` + `stillCaptureDequeueCountForTest` test seams.
- `StillCapture.swift` — `captureInFlight: ManagedAtomic<Bool>` CAS guard (scaffolding:07:swift-side-capture-atomic); `captureImage(pipeline:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:)` async throws; vImage RGBA16F→RGBA8 conversion via `vImageConverter_CreateWithCGImageFormat` + `vImageConvert_AnyToAny`; `CGImageDestination` TIFF writer; EXIF dictionary (`ISO`, `ExposureTime`, `FocalLength`, `ApertureValue`, `SubjectDistance`, `ExposureProgram`, `DateTimeOriginal`, `UserComment`); TIFF dictionary (`Orientation`, `DateTime`); `"CamPlugin/v1"` JSON envelope under `UserComment` (D-09); `PHPhotoLibrary.requestAuthorization(for: .addOnly)` + `performChanges`; app-documents fallback on denial; `authorizationProvider` closure injection seam; `encodeToTIFF(readbackBuffer:...)` internal helper for tests.
- `CameraEngine.swift` — `captureImage(outputPath:)` public API; engine state guard (must be open + session running); `StillCapture` instance created at `open()`, cleared at `close()`; `apertureValue` from `LiveCaptureDevice.avDevice.lensAperture`; `focalLengthMm = 0` (placeholder per §4 brief footnote — see open questions); typed-throws wrapping `StillCaptureError` in `EngineError.capture(...)`.
- `eva-swift-stitch.xcodeproj` — `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` build setting added to Debug + Release; `Stage07Tests.swift` wired into `eva-swift-stitchTests` target.
- `ViewModel.swift` — `captureResult: Result<StillCaptureOutput, Error>?`; `captureImage()` action; 3-second auto-dismiss `bannerDismissTask`.
- `CameraView.swift` — capture button (`camera.shutter.button`) in bottom bar; "Image saved: …" / "Capture failed: …" banner with `.safeAreaInset(edge: .bottom)` + 3s auto-dismiss animation.
- `Stage07Tests.swift` — 5 `@Test` functions: `stillCaptureInFlightGuard`, `tiffRoundTripMatchesProcessedPreview`, `exifEnvelopeContainsCamPluginV1`, `photoLibraryAuthorizationDeniedFallsBack`, `exifStandardDictionaryPresent`.

## Public API exposed so far (Stage 07 additions)

```swift
public func captureImage(outputPath: String? = nil) async throws -> StillCaptureOutput   // on CameraEngine
```

## Manual test evidence — Stage 07

| Test ID | Status | Notes |
|---------|--------|-------|
| `07:still-capture-in-flight-guard` | PASS | Stage07Tests/stillCaptureInFlightGuard |
| `07:tiff-round-trip-matches-processed-preview` | PASS | Stage07Tests/tiffRoundTripMatchesProcessedPreview |
| `07:exif-envelope-contains-camplugin-v1` | PASS | Stage07Tests/exifEnvelopeContainsCamPluginV1 |
| `07:photo-library-authorization-denied-falls-back` | PASS | Stage07Tests/photoLibraryAuthorizationDeniedFallsBack |
| `07:exif-standard-dictionary-present` | PASS | Stage07Tests/exifStandardDictionaryPresent |
| `07:tiff-opens-in-preview-and-photos` | DEFERRED | HITL — `measurements/stage-07/capture.md` |
| `07:saved-banner-appears-three-seconds` | DEFERRED | HITL — `measurements/stage-07/capture.md` |
| `07:authorization-dialog-first-capture` | DEFERRED | HITL — `measurements/stage-07/capture.md` |

## Decisions taken that weren't in briefs — Stage 07

31. **`vImageConverter_CreateWithCGImageFormat` + `vImageConvert_AnyToAny` instead of `vImageConvert_RGBA16FtoARGB8888`.** `vImageConvert_RGBA16FtoARGB8888` is not available in the SDK (no such symbol). Used the generic vImage converter pipeline with explicit `vImageCVImageFormat` source (RGBA16F) and `vImageCGImageFormat` destination (RGBA8) instead. Channel ordering is handled by the converter's format specification.

32. **`kCGImagePropertyTIFFImageWidth` / `kCGImagePropertyTIFFImageLength` don't exist as constants.** Plan referenced these keys; they are not in ImageIO's SDK headers. TIFF dimensions are derived from the CGImage itself by `CGImageDestinationAddImage`. Removed from the TIFF metadata dict.

33. **`CVPixelBuffer: @retroactive @unchecked Sendable` added to FrameSet.swift.** Swift 6 strict concurrency requires `Sendable` for values passed to `CheckedContinuation.resume(returning:)`. CVPixelBuffer is not formally Sendable on iOS 26. Adding a module-level retroactive conformance (matching the existing `FrameSet: @unchecked Sendable` rationale in G-13) resolves the error cleanly without changing the continuation type.

34. **`stillBufForCompletion: CVPixelBuffer?` captured as named let before closure.** Swift 6 flags accessing `stillPair.0` (tuple member) inside a `@Sendable` closure as a data race. Extracting the buffer to a named let binding before the closure (same pattern as `naturalBuf`/`processedBuf`) eliminates the diagnostic.

## Open questions for next stage

1. **`focalLengthMm`** — `AVCaptureDevice.activeFormat` doesn't expose focal length directly; used 0 as placeholder per brief §4 footnote. Upstream should clarify which metadata field to use.
2. **HITL evidence** (`07:tiff-opens-in-preview-and-photos`, `07:saved-banner-appears-three-seconds`, `07:authorization-dialog-first-capture`) deferred to device-on-hand session.
3. **`"CamPlugin/v1"` JSON schema** (U-09) remains deferred.
4. **Sigmoid contrast curve** (carried from Stage 06) — pin formula before Stage 11.
5. **D-17 upstream revision** (carried from Stage 06).

# state.md — Stage 06

## Current stage
Stage 06 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `06:simple-consumer-swift-only` | `PixelSink.swift` | `registerCallback` throws `notWired` | Stage 08 |

Pre-flight grep command (Stage 07 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only' CameraKit/Sources/
```
All three slugs returned ≥1 hit as of Stage 06.

## What's built — Stage 06 (permanent)

- `Constants.swift` — adds `trackerHeightPx: Int = 480`, `poolMinBufferCount: Int = 3`, `poolMaxBufferAgeSeconds: Double = 1.0`.
- `Errors.swift` — adds `InteropError.notWired`; C-ABI real variants arrive Stage 08.
- `TexturePoolManager.swift` — adds `makeWorkingFormatPool(size:) throws -> CVPixelBufferPool` (IOSurface-backed, Metal-compatible, RGBA16Half, 3-buffer minimum); adds `dequeuePoolTexture(pool:width:height:) throws -> (buffer: CVPixelBuffer, texture: MTLTexture)` (zero-copy CVMetalTextureCache wrap per ADR-06).
- `Shaders/TrackerDownsample.metal` — `trackerDownsample` compute kernel; bilinear sampling (`access::sample` + `MTLSamplerState`, clampToEdge) from natural texture into aspect-preserved even-pixel-rounded tracker texture; bounds check via `outTex.get_width()/get_height()`.
- `PixelSink.swift` — `ConsumerRegistry` rewritten as `public actor`; hot paths (`yield`, `hasSubscriber`) are `nonisolated` backed by `Mutex<InnerState>` (no actor hop on frame clock, ADR-02); `subscribe(stream:) -> AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22; `registerCallback(stream:callbacks:)` throws `InteropError.notWired` (scaffolding:06:simple-consumer-swift-only); `release()` terminates all streams; test-visible `dropCount(for:)` and `subscriberCount(for:)` metrics; `PixelSinkCallbacks` gains `@unchecked Sendable`.
- `MetalPipeline.swift` — promotes single `naturalTex`/`processedTex` to `CVPixelBufferPool` trio (`naturalPool`, `processedPool`, `trackerPool`); `nonisolated(unsafe)` mailboxes `latestNaturalTex`/`latestProcessedTex`/`latestTrackerTex` for MTKView draw pass (G-13, Stage 06 trade-off: single writer on delivery queue); Pass 4 (`trackerDownsample`) dispatched when `.tracker` has a subscriber; `FrameSet` constructed in `addCompletedHandler` from delivery-queue-local captures only (CMSampleBuffer not Sendable — timestamp + metadata extracted before closure); publishes to all three `StreamId`s; convenience `init(device:captureSize:gateOpen:consumers:)` for tests; test seams `naturalPoolForTest`, `processedPoolForTest`, `trackerPoolForTest`, `trackerSizeForTest`, `texturePoolForTest`, `setLatestNaturalForTest`, `setLatestProcessedForTest`.
- `CaptureDelegate.swift` — removed `weak var pipeline`; `captureOutput` delegates to `onSampleBuffer?` + `engine?.tickFrame()` (no direct pipeline coupling).
- `CameraEngine.swift` — `public nonisolated let consumers: ConsumerRegistry`; `open()` and `setResolution()` pass `consumers:` to `MetalPipeline`; `await consumers.release()` in `close()`; `public nonisolated func currentTrackerTexture() -> (any MTLTexture)?`.
- `FrameSet.swift` — adds `extension CaptureMetadata { static func placeholder() -> CaptureMetadata }` (zeroed fields, neutral white balance gains, used by completion handler until Stage 09 wires real metadata).
- `ViewModel.swift` — adds `DebugOverlay` struct (`frameNumber`, `captureTimeMs`); `var debugOverlay: DebugOverlay?`; `var debugTrackerSubscribed: Bool`; `nonisolated(unsafe) var trackerTex: MTLTexture?`; `startDebugOverlay()` subscribes to `.natural` and updates overlay every 10th frame (~3 fps — throttled to eliminate 30 SwiftUI re-renders/sec; MTKView preview is GPU-direct via mailboxes); `toggleDebugTrackerSubscription()` wires/unwires `.tracker` subscriber; `stop()` cancels all subscriber tasks.
- `CameraView.swift` (`#if DEBUG`) — yellow `#N  t=…ms` text overlay top-left from `debugOverlay`; `MTKViewRepresentable` tracker thumbnail (160×120 pt, yellow border, bottom-left) when `debugTrackerSubscribed`; "Show/Hide Tracker" toggle button.
- `Stage06Tests.swift` — 7 `@Test` functions: `frameSetPublication`, `swiftConsumerDropOnBusy`, `poolTrioAllocationOnOpen`, `trackerDownsampleHeightMatchesConstant`, `subscribeThenCancelReleasesSubscriber`, `registerCallbackThrowsNotWired`, `naturalStreamIsSubscribable`.
- `eva_swift_stitchApp.swift` — `UIApplicationDelegateAdaptor(AppDelegate.self)` with `supportedInterfaceOrientationsFor → .landscapeRight`; enforces landscape at UIKit level so SwiftUI `WindowGroup` never appears in portrait.
- `eva-swift-stitch/Info.plist` — `UISupportedInterfaceOrientations~ipad = [UIInterfaceOrientationLandscapeRight]`; `UIRequiresFullScreen = true` (disables Split View / Slide Over).

## What's built — Stage 05 (permanent)

- `UniformStorage.swift` — `struct UniformStorage: Sendable, Hashable` (color + crop fields); static `identity(captureSize:)` factory.
- `ProcessingMetadata.swift` — extracted from `FrameSet.swift`; public shape unchanged; internal `init(color:crop:)` used by `MetalPipeline.encode()` to construct the per-frame snapshot.
- `MetalPipeline` — `UniformsHost` class removed; replaced by `let uniforms: Mutex<UniformStorage>` (Synchronization framework, iOS 18+). `encode()` snapshots via `uniforms.withLock { $0 }` before any Metal command, satisfying Inv 6. `lastProcessingMetadata: ProcessingMetadata?` written per frame (Stage 06 consumer path). `ColorUniform` and `CropUniform` now `Hashable`.
- `CameraEngine` — `setProcessingParameters(_:)` and `setCropRegion(_:)` write through `pipeline.uniforms.withLock { ... }`.
- `CaptureDelegate.onProcessingMetadata` — `((ProcessingMetadata) -> Void)?` stub callback; no-op in Stage 05 (nil default); Stage 06 wires consumer dispatch.
- Inv 6 (no torn writes on uniform buffer) now enforced in code. Architecture prose unchanged (brief §4 literal).
- `Tests/CameraKitTests/Stage05Tests.swift` — 3 `@Test` functions: torn-write stress, snapshot-matches-lock, mutex-scope-is-tight.

## What's built — Stage 04 (permanent)

- `Constants.swift` adds `centerPatchSizePx`, `centerPatchTrimPercent`, `frameLatencyBudgetMs`, `processedPixelFormat`.
- `TexturePoolManager.makeIOSurfaceBackedRGBA16F(size:)` — vends `(CVPixelBuffer, MTLTexture)` pair (.shared / IOSurface, kCVPixelFormatType_64RGBAHalf / .rgba16Float).
- `MetalPipeline` — `naturalTex` migrated from `.private` to IOSurface-backed `.shared`; new IOSurface-backed `processedTex`; Pass 2 (`colorTransform`) compiled + dispatched after Pass 1; `UniformsHost` (color + crop) snapshotted per frame; `dispatchCenterPatch()` async sampler; test seams `naturalBufferForTest`, `processedBufferForTest`, `encodePass2Only()`.
- `Shaders/ColorShaders.metal` — `colorTransform` kernel (black balance → brightness → contrast → saturation → gamma; identity at defaults).
- `Shaders/CenterPatchKernel.metal` — `centerPatchHistogram` flat-buffer sampler.
- `Shaders/YUVToRGBA.metal` — extended with `CropUniform` (default = full texture).
- `SettingsPersistence.saveProcessing` / `loadProcessing` keyed `"CameraKit.ProcessingParameters"`.
- `CameraEngine` — `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `nonisolated getPersistedProcessingParameters()`, `nonisolated currentProcessedTexture()`; persisted-`ProcessingParameters` load in `open()`.
- `ViewModel` — `currentProcessing: ProcessingParameters` observable; `processedTex`; `updateProcessing(_:)` / `resetProcessing()`; persisted load on first appear.
- `CameraView` — split preview (left natural / right processed) HStack; "Calibrate Color" toggle; color-calibration sidebar (Brightness, Contrast, Saturation, Gamma, BlackR/G/B sliders + Reset).
- `Tests/CameraKitTests/Stage04Tests.swift` — 4 `@Test` functions covering brief §8 TESTABLEs.
- `eva-swift-stitchTests` — Stage04Tests.swift wired into the host-app test runner.

## Public API exposed so far (Stage 06 additions)

```swift
public actor ConsumerRegistry {
    public func subscribe(stream: StreamId) async -> AsyncStream<FrameSet>
    public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) async throws -> ConsumerToken
    public func unregister(token: ConsumerToken) async
    public func release() async
    public nonisolated func yield(_ frameSet: FrameSet, stream: StreamId)
    public nonisolated func hasSubscriber(_ stream: StreamId) -> Bool
}
public nonisolated func currentTrackerTexture() -> (any MTLTexture)?  // on CameraEngine
```

## Public API exposed so far (Stage 05 additions)

(None — Stage 05 is a MIGRATION. `ProcessingMetadata` was already public from the Stage 04 stub; no new public API surface.)

## Public API exposed so far (Stage 04 additions)

```swift
public func setProcessingParameters(_ params: ProcessingParameters) async
public func setCropRegion(_ rect: Rect) async throws
public func sampleCenterPatch() async throws -> RgbSample
public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters?
public nonisolated func currentProcessedTexture() -> (any MTLTexture)?
```

## Manual test evidence — Stage 06

| Test ID | Status | Notes |
|---------|--------|-------|
| `06:frame-set-publication` | PASS | Stage06Tests/frameSetPublication — synthetic YUV buffer; all 3 streams receive frameNumber==1; IOSurface-backed. |
| `06:swift-consumer-drop-on-busy` | PASS | Stage06Tests/swiftConsumerDropOnBusy — 30-frame producer at ~100fps vs 30fps consumer; ≥1 drop recorded. |
| `06:pool-trio-allocation-on-open` | PASS | Stage06Tests/poolTrioAllocationOnOpen — dequeue from each pool; IOSurface-backed confirmed. |
| `06:tracker-downsample-height-matches-constant` | PASS | Stage06Tests/trackerDownsampleHeightMatchesConstant — height==480, width even, aspect-preserved. |
| `06:subscribe-then-cancel-releases-subscriber` | PASS | Stage06Tests/subscribeThenCancelReleasesSubscriber — count drops to 0 after task cancel + yield. |
| `06:register-callback-throws-not-wired` | PASS | Stage06Tests/registerCallbackThrowsNotWired — InteropError.notWired thrown. |
| `06:natural-stream-is-subscribable` | PASS | Stage06Tests/naturalStreamIsSubscribable — .natural lane delivers FrameSet. |
| `06:tracker-thumbnail-appears-on-subscribe` | PASS | HITL — `measurements/stage-06/consumers.md`. Device: iPad 00008027-000539EA0184402E, iOS 26. |
| `06:debug-overlay-shows-frame-number-capture-time` | PASS | HITL — `measurements/stage-06/consumers.md`. N increments monotonically; t non-decreasing. |

## Manual test evidence — Stage 05

| Test ID | Status | Notes |
|---------|--------|-------|
| `05:uniform-lock-no-torn-writes-under-stress` | PASS | Stage05Tests/uniformLockNoTornWritesUnderStress — 1 000 concurrent writes + 10 000 snapshots, 0 torn reads. |
| `05:processing-metadata-snapshot-matches-lock` | PASS | Stage05Tests/processingMetadataSnapshotMatchesLock — brightness 0.3 round-trips. |
| `05:mutex-scope-is-tight` | PASS | Stage05Tests/mutexScopeIsTight — source grep confirms no commit()/encoder inside withLock. |
| `04:color-pipeline-golden-frame` (carried) | PASS | Still green post-migration. |
| `04:processing-params-persistence-roundtrip` (carried) | PASS | Still green post-migration. |
| Device smoke (`04:rapid-slider-stress`) | DEFERRED | Brief §12 says unit tests only; device Instruments run is optional HITL. |

## Manual test evidence — Stage 04

| Test ID | Status | Notes |
|---------|--------|-------|
| `04:color-pipeline-golden-frame` | PASS | Stage04Tests/colorPipelineGoldenFrame — identity + brightness +0.2. |
| `04:processing-params-persistence-roundtrip` | PASS | Stage04Tests/processingParamsPersistenceRoundtrip — per-test UUID suite. |
| `04:center-patch-trimmed-mean` | PASS | Stage04Tests/centerPatchTrimmedMean — uniform fill + 10% outliers. |
| `04:set-crop-region-updates-uniform` | PASS | Stage04Tests/setCropRegionUpdatesUniform — happy + out-of-bounds throw. |
| `04:color-slider-visual-correctness` | PASS | `measurements/stage-04/color.md`. Verified Shreeyak's iPad iOS 26.4.1. |
| `04:rapid-slider-stress-sees-occasional-torn-frame` | PASS | `measurements/stage-04/color.md`. 0 glitches observed in ~10s stress. |

## Decisions taken that weren't in briefs — Stage 06

26. **`captureOrientationAngleDeg` corrected from 90° to 0°.** Brief ADR-17 specified a rotation angle for landscape-right delivery. On iPad's horizontal-sensor back camera, `videoRotationAngle = 90` delivered portrait-rotated buffers (width < height) while `captureSize` remained landscape (from format description before rotation). YUV shader out-of-bounds reads at `gid.x ≥ delivered_width` returned `(Y=0, Cb=0, Cr=0)` which the YCbCr→RGB formula maps to `RGB(0,154,0)` = green. Fixed to 0° (native sensor orientation = landscape). ADR-17 should be updated upstream to note this is device-class-dependent.

27. **`UIApplicationDelegateAdaptor` required to enforce landscape lock.** `UISupportedInterfaceOrientations~ipad` + `UIRequiresFullScreen` in Info.plist alone did not prevent portrait startup with SwiftUI `WindowGroup`. Adding a `UIApplicationDelegate` adapter returning `.landscapeRight` from `supportedInterfaceOrientationsFor(_:)` is the reliable mechanism for SwiftUI apps on iPadOS.

28. **Debug overlay throttled to every 10th frame (~3 fps).** Subscribing to `.natural` and calling `await MainActor.run { self.debugOverlay = overlay }` at 30 fps caused 30 full SwiftUI `CameraView.body` re-renders per second, visibly degrading preview smoothness. The MTKView preview is GPU-direct via `nonisolated(unsafe)` texture mailboxes and needs no SwiftUI involvement; only the text overlay requires MainActor. Throttling to 3 fps restores perceived 30 fps preview while keeping the overlay useful.

29. **`ProcessingMetadata` blackR/G/B resolved via `ColorUniform`.** Stage 05 open question: skeleton had `ProcessingMetadata` missing black-balance fields. Stage 06 constructs `ProcessingMetadata(color: ColorUniform, crop: CropUniform)` where `ColorUniform` includes `blackR/G/B/gamma` — fields are now present in every published `FrameSet.processing`. No separate field addition needed.

30. **Pass 4 input is `naturalTexI` (not `processedTexI`).** Brief §4 was ambiguous; tracker downsample runs after Pass 1 (YUV→RGBA) and uses the unprocessed natural frame as input, keeping the tracker stream independent of color-calibration sliders. This matches domain intent (tracker should see the raw scene, not a stylized version).

## Decisions taken that weren't in briefs — Stage 05

21. **`Mutex<UniformStorage>` (Synchronization framework) instead of `OSAllocatedUnfairLock` per D-17.** User-authorized override. Rationale: Mutex is the preferred primitive for new Swift 6+ code; exposes only `withLock`/`withLockIfAvailable` (no manual `lock()`/`unlock()`), structurally guaranteeing "lock not held across commit" (Inv 6 / ADR-09) without runtime assertions. Flag D-17 upstream for revision to reflect iOS 18+ Mutex availability.

22. **Property named `uniforms` not `uniformsLock`.** Plan specified `uniformsLock`; the previous-session implementation agent used `uniforms`. Tests were written against `uniforms.withLock`, matching the actual property name. Renaming would be a no-op behaviour change; keeping `uniforms` is consistent with usage and avoids churn.

23. **`05:mutex-scope-is-tight` replaces brief §8 "debug counter" test.** Brief asked for "a debug counter in the lock scope is zero at commit time." With `Mutex`, holding the lock across commit is structurally impossible (no manual lock/unlock API). The test instead scans the source text to confirm no `commit()` or encoder call appears inside any `withLock` closure.

24. **`ProcessingMetadata` missing `blackR/G/B` fields vs `ProcessingParameters`.** Skeleton discrepancy carried from `api-skeletons/`. `FrameSet.processing` field name retained as `processing` (not `processingMetadata` per brief §4 wording). Resolved in Stage 06 — see decision 29.

25. **`DispatchQueue.concurrentPerform` in stress test.** Brief §8 literally specifies it. The swift-concurrency skill forbids GCD in production; CLAUDE.md §8 gives brief precedence for stage-specific test harness tooling.

## Open questions for next stage

1. **Sigmoid contrast curve** — pin formula choice via ADR or 07-settings §Processing-order amendment before Stage 11 polish.
2. **D-17 upstream revision** — update `architecture/02-concurrency.md` §D-17 to reflect `Mutex` (iOS 18+, Synchronization framework) as the preferred lock for this pattern in new Swift 6+ code. Also note ADR-17 camera rotation is device-class-dependent (see decision 26).
3. **Crop visual verification** — Stage 06 pool trio is live; end-to-end crop→pixel correspondence test deferred to a future HITL pass or Stage 07.
4. **`UIRequiresFullScreen` deprecated in iOS 26** — Apple docs note this key will be ignored in a future release; no replacement API documented yet. Monitor for a replacement.
5. **Instruments pool high-water-mark** — brief §11 asks for Allocations evidence that pool per-lane equals `POOL_CAP_RULE` and ages out after `POOL_MAX_BUFFER_AGE_SECONDS`. Deferred; not a blocker for Stage 07.
