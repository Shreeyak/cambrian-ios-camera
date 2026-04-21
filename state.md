# state.md — Stage 04

## Current stage
Stage 04 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `04:unlocked-uniforms` | `CameraEngine.swift`, `MetalPipeline.swift` | host write + per-frame snapshot | Stage 05 |

Pre-flight grep command (Stage 05 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|04:unlocked-uniforms' CameraKit/Sources/
```
All three slugs returned ≥1 hit as of Stage 04.

## What's built this stage (permanent)

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

## Decisions taken that weren't in briefs

(Continuing numbering from Stage 03's #15.)

16. **`naturalTex` IOSurface migration ships in Stage 04, not Stage 01.** Stage 01 allocated `naturalTex` as `.private` (`MetalPipeline.swift:94`). Brief §7 + architecture `04-metal-pipeline.md` §D-02 require `.shared` IOSurface-backed from Stage 01. Migration deferred to Stage 04 because no consumer needed CPU readback before now (the `04:color-pipeline-golden-frame` test is the first reader). Task 1 + Task 2 implement the migration cleanly.

17. **Stage-04 contrast formula is linear, not piecewise sigmoid.** `architecture/07-settings.md` §Processing order calls for "piecewise sigmoid around 0.5 midpoint". Stage 04 ships a linear `(c - 0.5) * contrast + 0.5` because (a) brief §7 only requires "identity when all params at defaults" and (b) sigmoid curve choice is unspecified (ramp shape, knee location). Stage 11 polish or a future ADR should pin the curve before swapping in.

18. **`setCropRegion` has no Stage-04 TESTABLE for the device-driven path.** Test 4 verifies the uniform-write contract (the only behavioral assertion the brief §8 names). End-to-end visual verification (cropped preview matches expected rect on a known scene) is brought in Stage 06 with the pool trio and downstream pixel-sink delivery.

19. **`MTKViewRepresentable` parameterized by closure, not generic over KeyPath.** Stage 02 had a single MTKView wrapping `viewModel.naturalTex`; Stage 04 needs a second one for `viewModel.processedTex`. Refactor uses a `textureAccessor: () -> MTLTexture?` closure rather than a `KeyPath<ViewModel, MTLTexture?>`-generic struct. Closure is one extra allocation per drawn frame; negligible at 30 fps.

20. **`04:unlocked-uniforms` slug at TWO sites.** Brief §4 says "around the engine writing shader uniforms directly without `OSAllocatedUnfairLock<UniformStorage>`". Both the host write in `CameraEngine.setProcessingParameters` and the per-frame snapshot read in `MetalPipeline.encode()` are unsynchronised — Stage 05's lock install will protect both sides. Both sites carry the slug so the Stage-05 retirement grep finds them.

## Open questions for next stage

1. **Inv 6 lock install (Stage 05)** — wrap `UniformsHost.color` + `UniformsHost.crop` in `OSAllocatedUnfairLock<UniformStorage>`; engine acquires-writes-releases; pipeline acquires-snapshots-releases. Both `04:unlocked-uniforms` sites retire.
2. **Sigmoid contrast curve** — pin formula choice via ADR or 07-settings §Processing-order amendment before Stage 11 polish.
3. **Crop visual verification** — Stage 06 (pool trio) provides the device-driven crop rendering test that proves uniform → pixel correspondence end-to-end.
4. **HITL evidence PASS** — `04:color-slider-visual-correctness`, `04:rapid-slider-stress-sees-occasional-torn-frame`, and persistence all verified on Shreeyak's iPad (iOS 26.4.1), 2026-04-21.
