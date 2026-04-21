# state.md — Stage 05

## Current stage
Stage 05 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 06 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```
Both slugs returned ≥1 hit as of Stage 05. `04:unlocked-uniforms` retired (5 sites removed).

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

## Manual test evidence

| Test ID | Status | Notes |
|---------|--------|-------|
| `04:color-pipeline-golden-frame` | PASS | Stage04Tests/colorPipelineGoldenFrame — identity + brightness +0.2. |
| `04:processing-params-persistence-roundtrip` | PASS | Stage04Tests/processingParamsPersistenceRoundtrip — per-test UUID suite. |
| `04:center-patch-trimmed-mean` | PASS | Stage04Tests/centerPatchTrimmedMean — uniform fill + 10% outliers. |
| `04:set-crop-region-updates-uniform` | PASS | Stage04Tests/setCropRegionUpdatesUniform — happy + out-of-bounds throw. |
| `04:color-slider-visual-correctness` | PASS | `measurements/stage-04/color.md`. Verified Shreeyak's iPad iOS 26.4.1. |
| `04:rapid-slider-stress-sees-occasional-torn-frame` | PASS | `measurements/stage-04/color.md`. 0 glitches observed in ~10s stress. |

## Manual test evidence — Stage 05

| Test ID | Status | Notes |
|---------|--------|-------|
| `05:uniform-lock-no-torn-writes-under-stress` | PASS | Stage05Tests/uniformLockNoTornWritesUnderStress — 1 000 concurrent writes + 10 000 snapshots, 0 torn reads. |
| `05:processing-metadata-snapshot-matches-lock` | PASS | Stage05Tests/processingMetadataSnapshotMatchesLock — brightness 0.3 round-trips. |
| `05:mutex-scope-is-tight` | PASS | Stage05Tests/mutexScopeIsTight — source grep confirms no commit()/encoder inside withLock. |
| `04:color-pipeline-golden-frame` (carried) | PASS | Still green post-migration. |
| `04:processing-params-persistence-roundtrip` (carried) | PASS | Still green post-migration. |
| Device smoke (`04:rapid-slider-stress`) | DEFERRED | Brief §12 says unit tests only; device Instruments run is optional HITL. |

## Decisions taken that weren't in briefs

(Continuing numbering from Stage 03's #15.)

16. **`naturalTex` IOSurface migration ships in Stage 04, not Stage 01.** Stage 01 allocated `naturalTex` as `.private` (`MetalPipeline.swift:94`). Brief §7 + architecture `04-metal-pipeline.md` §D-02 require `.shared` IOSurface-backed from Stage 01. Migration deferred to Stage 04 because no consumer needed CPU readback before now (the `04:color-pipeline-golden-frame` test is the first reader). Task 1 + Task 2 implement the migration cleanly.

17. **Stage-04 contrast formula is linear, not piecewise sigmoid.** `architecture/07-settings.md` §Processing order calls for "piecewise sigmoid around 0.5 midpoint". Stage 04 ships a linear `(c - 0.5) * contrast + 0.5` because (a) brief §7 only requires "identity when all params at defaults" and (b) sigmoid curve choice is unspecified (ramp shape, knee location). Stage 11 polish or a future ADR should pin the curve before swapping in.

18. **`setCropRegion` has no Stage-04 TESTABLE for the device-driven path.** Test 4 verifies the uniform-write contract (the only behavioral assertion the brief §8 names). End-to-end visual verification (cropped preview matches expected rect on a known scene) is brought in Stage 06 with the pool trio and downstream pixel-sink delivery.

19. **`MTKViewRepresentable` parameterized by closure, not generic over KeyPath.** Stage 02 had a single MTKView wrapping `viewModel.naturalTex`; Stage 04 needs a second one for `viewModel.processedTex`. Refactor uses a `textureAccessor: () -> MTLTexture?` closure rather than a `KeyPath<ViewModel, MTLTexture?>`-generic struct. Closure is one extra allocation per drawn frame; negligible at 30 fps.

20. **`04:unlocked-uniforms` slug at TWO sites.** Brief §4 says "around the engine writing shader uniforms directly without `OSAllocatedUnfairLock<UniformStorage>`". Both the host write in `CameraEngine.setProcessingParameters` and the per-frame snapshot read in `MetalPipeline.encode()` are unsynchronised — Stage 05's lock install will protect both sides. Both sites carry the slug so the Stage-05 retirement grep finds them.

## Decisions taken that weren't in briefs — Stage 05

21. **`Mutex<UniformStorage>` (Synchronization framework) instead of `OSAllocatedUnfairLock` per D-17.** User-authorized override. Rationale: Mutex is the preferred primitive for new Swift 6+ code; exposes only `withLock`/`withLockIfAvailable` (no manual `lock()`/`unlock()`), structurally guaranteeing "lock not held across commit" (Inv 6 / ADR-09) without runtime assertions. Flag D-17 upstream for revision to reflect iOS 18+ Mutex availability.

22. **Property named `uniforms` not `uniformsLock`.** Plan specified `uniformsLock`; the previous-session implementation agent used `uniforms`. Tests were written against `uniforms.withLock`, matching the actual property name. Renaming would be a no-op behaviour change; keeping `uniforms` is consistent with usage and avoids churn.

23. **`05:mutex-scope-is-tight` replaces brief §8 "debug counter" test.** Brief asked for "a debug counter in the lock scope is zero at commit time." With `Mutex`, holding the lock across commit is structurally impossible (no manual lock/unlock API). The test instead scans the source text to confirm no `commit()` or encoder call appears inside any `withLock` closure.

24. **`ProcessingMetadata` missing `blackR/G/B` fields vs `ProcessingParameters`.** Skeleton discrepancy carried from `api-skeletons/`. `FrameSet.processing` field name retained as `processing` (not `processingMetadata` per brief §4 wording). Resolve in Stage 06.

25. **`DispatchQueue.concurrentPerform` in stress test.** Brief §8 literally specifies it. The swift-concurrency skill forbids GCD in production; CLAUDE.md §8 gives brief precedence for stage-specific test harness tooling.

## Open questions for next stage

1. **`ProcessingMetadata` missing `blackR/G/B`** — extend or document exclusion when `FrameSet` construction lands in Stage 06.
2. **Sigmoid contrast curve** — pin formula choice via ADR or 07-settings §Processing-order amendment before Stage 11 polish.
3. **Crop visual verification** — Stage 06 (pool trio) provides the device-driven crop rendering test that proves uniform → pixel correspondence end-to-end.
4. **D-17 upstream revision** — update `architecture/02-concurrency.md` §D-17 to reflect `Mutex` (iOS 18+, Synchronization framework) as the preferred lock for this pattern in new Swift 6+ code.
5. **HITL evidence (Stage 04)** — `04:color-slider-visual-correctness`, `04:rapid-slider-stress-sees-occasional-torn-frame`, and persistence verified on Shreeyak's iPad (iOS 26.4.1), 2026-04-21.
