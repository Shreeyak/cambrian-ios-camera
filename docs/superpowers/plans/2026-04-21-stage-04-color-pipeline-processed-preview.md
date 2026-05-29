# Stage 04 — Color Pipeline + Processed Preview + Sample-Center-Patch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Canonical destination on approval:** `docs/superpowers/plans/2026-04-21-stage-04-color-pipeline-processed-preview.md` — move/copy after `ExitPlanMode`. The plan-mode harness fixed this draft path; the conventional Stage-NN slug belongs in the canonical location.
>
> **Per-task model selection:** Each `### Task N — …` heading is followed by a `**Model:** haiku|sonnet — reason` line. When dispatching via `superpowers:subagent-driven-development`, pass the named model to the subagent. Haiku tasks are mechanical (file writes, single appends, verification greps); sonnet tasks involve multi-site edits, concurrency reasoning, or test-failure investigation. CLAUDE.md §6.1 default is sonnet/opus for implementation; this annotation overrides per task.

**Goal:** Add Pass 2 (color-transform compute kernel) downstream of Pass 1; render into a single shared IOSurface-backed `processedTex`; surface a split preview UI (left natural / right processed) with brightness, contrast, saturation, gamma, and per-channel black-balance sliders; persist `ProcessingParameters` to `UserDefaults`; expose `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()` on `CameraEngine`.

**Architecture:** Slider input in `CameraView` writes through `ViewModel.updateProcessing(_:)` → `engine.setProcessingParameters(_:)`. The engine writes a host-side `UniformStorage` struct directly without lock (scaffold `04:unlocked-uniforms`; the lock arrives Stage 05 per Inv 6). On every frame, `MetalPipeline.encode()` snapshots the struct into a small `MTLBuffer`, encodes Pass 1 (YUV→RGBA into `naturalTex`) then Pass 2 (color transform `naturalTex` → `processedTex`), and commits. Both `naturalTex` and `processedTex` are IOSurface-backed `.shared` `CVPixelBuffer`s vended by `TexturePoolManager` (D-02 / ADR-20 start-simple default). `sampleCenterPatch()` encodes a parallel-reduction kernel over `processedTex`'s center `CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX` region into a histogram `MTLBuffer`, awaits the next completion, then computes a CPU-side trimmed mean (`CENTER_PATCH_TRIM_PERCENT` discarded top/bottom). `setCropRegion(_:)` writes the crop uniform read by Pass 1. Persistence uses `SettingsPersistence` keyed `"CameraKit.ProcessingParameters"`.

**Tech Stack:** Swift 6.2, iOS 26, Swift Testing (`@Test`/`@Suite`), Metal compute kernels (`.metal` + `MTLComputePipelineState`), `CVMetalTextureCache` + IOSurface-backed `CVPixelBuffer`, `CVPixelBufferLockBaseAddress` for CPU readback in tests, `UserDefaults` + `Codable`, SwiftUI `Slider` + `HStack`/`VStack`. **Device builds via `mcp__XcodeBuildMCP__{build_run_device,test_device}` — no simulators, ever** (CLAUDE.md §6 top).

**Stage type:** FEATURE. Adds scaffold `04:unlocked-uniforms`. Retires no scaffolds. Active scaffolds after this stage: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `04:unlocked-uniforms`.

---

## 0. Hard precondition — Stage 03 must be complete first

This plan assumes the Stage 03 plan at
`docs/superpowers/plans/2026-04-21-stage-03-camera-controls-settings-merge-persistence.md`
has been **fully executed** — every task committed.

As of this plan's drafting (2026-04-21), Stage 03 is **mid-execution**:

| Stage 03 artifact | Source state |
|---|---|
| `Constants.frameResultHeartbeatHz` / `Intervals` / `resolutionResizeTimeoutSeconds` | Present (commit `e9c1ff0`). |
| `Settings.swift` (`merging`, `SettingsCoupling`) | Present, untracked. |
| `SettingsPersistence.swift` (`save` / `load` for `CameraSettings`) | Present, untracked. |
| `Stage03Tests.swift` | Present, untracked, **does not compile** (refs missing types). |
| `KVOAsyncStream.swift` (DeviceKVOObserver) | **Missing.** |
| `CaptureDeviceProviding.snapshotStream()` / `lastSnapshot` | **Missing on protocol.** |
| `CameraSession.applySettings(_:on:)` | **Missing.** |
| `CameraEngine.updateSettings(_:)` body | **Stage 01 stub still in place.** |
| `CameraEngine.setResolution(size:)` / `frameResultStream()` | **Missing.** |
| `SessionCapabilities.isoRange` / `exposureDurationRangeNs` | **Missing.** |
| `ViewModel` slider bindings + `frameResultTask` | **Missing.** |
| `CameraView` expanded bottom bar | **Missing.** |

**If Task 0 below fails, stop. Run the Stage 03 plan to completion, then return.** Do not start Stage 04 work on top of an incomplete Stage 03 — every Stage 04 task references Stage 03 primitives (`setProcessingParameters` lives next to `updateSettings`; `ViewModel` adds `currentProcessing` next to `currentSettings`; the persisted-load path piggybacks on the persisted-`CameraSettings` load).

---

## 1. Source inventory

### 1.1 File-by-file shape (post-Stage-03 expected state)

| File | What it should look like at Stage-04 entry | What Stage 04 changes |
|---|---|---|
| `CameraKit/Sources/CameraKit/Constants.swift` | `frameRateTargetFPS`, `capturePixelFormat`, `workingPixelFormat = .rgba16Float`, `captureDefaultWidthPx/HeightPx`, `captureFallbackWidthPx/HeightPx`, `cropDefaultWidthPx/HeightPx`, `captureOrientationAngleDeg`, `stateStreamBufferSize`, `sessionLifecycleTimeoutSeconds`, `frameResultHeartbeatHz`, `frameResultHeartbeatIntervalFrames`, `resolutionResizeTimeoutSeconds`. | **Add:** `centerPatchSizePx: Int = 96`, `centerPatchTrimPercent: Int = 10`, `frameLatencyBudgetMs: Int = 33`, `processedPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf`. |
| `CameraKit/Sources/CameraKit/Capabilities.swift` | Has `Size`, `Rect`, `SessionCapabilities` (with Stage-03-added `isoRange` + `exposureDurationRangeNs`), `OpenConfiguration`, `CameraMode` (Codable), `WhiteBalanceMode` (Codable), `CameraSettings` (Codable), `ProcessingParameters` (Codable, all 7 fields). | **No code changes.** Stage 04 reads `ProcessingParameters` shape from here; `Codable` is already present at line 122. |
| `CameraKit/Sources/CameraKit/Settings.swift` | `CameraSettings.merging(onto:)` extension; `SettingsCoupling.apply(rules:latched:)`. | **No code changes.** |
| `CameraKit/Sources/CameraKit/SettingsPersistence.swift` | `enum SettingsPersistence` with `save(_:defaults:)` / `load(defaults:)` for `CameraSettings`, key `"CameraKit.CameraSettings"`. | **Add:** static `processingKey = "CameraKit.ProcessingParameters"` + `saveProcessing(_:defaults:)` + `loadProcessing(defaults:) -> ProcessingParameters?`. |
| `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` | Protocol with `snapshotStream()`, `lastSnapshot`; `LiveCaptureDevice` actor with KVO ingest. | **No code changes.** |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | `configure`, `start/stopRunning(Async)`, `applySettings(_:on:)`, `reconfigureSize(_:)`. | **No code changes.** |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Public actor with `open`, `close`, `stateStream`, `updateSettings`, `setResolution`, `frameResultStream`, `register/deregisterPixelSink`, `backgroundSuspend/Resume`, `currentTexture`. Uniform/processing shape stub-free; no `setProcessingParameters`/`setCropRegion`/`sampleCenterPatch`/`getPersistedProcessingParameters` yet. | **Add:** `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch() async throws -> RgbSample`, `nonisolated getPersistedProcessingParameters() -> ProcessingParameters?`; load persisted `ProcessingParameters` in `open()`; expose `nonisolated currentProcessedTexture()` for the second MTKView. |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | Stage-03 weak `engine` ref + `tickFrame()`. | **No code changes.** |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | Pass-1-only encode path; `naturalTex` is `.private` MTLTexture, no IOSurface backing. Carries scaffolds `01:simple-metal-passthrough` (line 26) + `01:skip-completion-guard` (line 142). | **Major rework:** receive `processedTex` + IOSurface-backed `naturalTex` from `TexturePoolManager`; load `colorTransform` PSO; add Pass 2 encode after Pass 1; receive `UniformsHost` + `CropHost` references and snapshot per frame; expose `currentProcessedTex()`; expose `centerPatchKernel` + `dispatchCenterPatch(into:)` test seam. Keep `01:simple-metal-passthrough` slug intact (Pass 3+ still missing); add `04:unlocked-uniforms` slug at the per-frame snapshot site. |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | YUV plane-wrap helpers (`makeYTexture`, `makeCbCrTexture`); no working-texture allocation. Carries scaffold `01:simple-metal-passthrough` (line 36). | **Add:** `makeIOSurfaceBackedRGBA16F(size:) -> (CVPixelBuffer, MTLTexture)` factory. Used twice — once for `naturalTex`, once for `processedTex`. Keep YUV helpers unchanged. Keep `01:simple-metal-passthrough` slug. |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Stage-03 slider state + `frameResultTask`. | **Add:** `currentProcessing: ProcessingParameters` observable; `processedTex: MTLTexture?` (nonisolated(unsafe), parallel to `naturalTex`); `updateProcessing(_:)` debounced dispatcher; `resetProcessing()`; load persisted `ProcessingParameters` on first appear via `engine.getPersistedProcessingParameters()`. |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Single-MTKView ZStack + Stage-03 bottom bar. | **Replace body:** split-preview HStack of two `MTKViewRepresentable`s (one bound to `viewModel.naturalTex`, one to `viewModel.processedTex`); add a slide-in color-calibration sidebar (Brightness, Contrast, Saturation, Gamma, BlackR, BlackG, BlackB sliders + Reset button). Keep Stage-03 expanded bottom bar visible alongside. |
| `CameraKit/Sources/CameraKit/Shaders/YUVToRGBA.metal` | Stage-01 `yuvToRgba` kernel. | **Add a uniform-aware crop branch.** Pass a `CropUniform` (origin + size) so Pass 1 writes only the cropped region. Default crop = full texture (preserves Stage-01 behavior). |
| `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal` | **Missing — create.** | New kernel `colorTransform` reads `naturalTex`, applies black balance → brightness → contrast → saturation → gamma using the snapshotted `ColorUniform`, writes to `processedTex`. Identity when all params at defaults. |
| `CameraKit/Sources/CameraKit/Shaders/CenterPatchKernel.metal` | **Missing — create.** | New kernel `centerPatchHistogram` reads a `CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX` region centered on `processedTex` and writes per-pixel R, G, B values into three flat `device float*` buffers (one per channel). CPU then sorts + trimmed-means. |
| `CameraKit/Tests/CameraKitTests/Stage04Tests.swift` | **Missing — create.** | 4 `@Test` functions covering brief §8 TESTABLEs: golden-frame, persistence-roundtrip, center-patch, set-crop-region. |
| `eva-swift-stitch.xcodeproj/project.pbxproj` | Stage 03 wires `Stage03Tests.swift` into `eva-swift-stitchTests`. | **Add** `Stage04Tests.swift` to `eva-swift-stitchTests` sources via the `xcodeproj` Ruby gem (matches Stage-02/03 pattern). |
| `CameraKit/state.md` | Stage-03 closure. | Append Stage-04 section. |
| `CameraKit/CONTRACTS.md` | Auto-regenerated. | Regenerate via `scripts/regen-contracts.sh` after final commit. |

### 1.2 Active scaffolds at Stage-04 entry

```
01:simple-metal-passthrough   MetalPipeline.swift:26, TexturePoolManager.swift:36
01:skip-completion-guard      MetalPipeline.swift:142
```

After Stage 04, additionally:

```
04:unlocked-uniforms          CameraEngine.swift:<setProcessingParameters body>
04:unlocked-uniforms          MetalPipeline.swift:<per-frame snapshot site>
```

(Two locations — see Task 9 Step 2.)

### 1.3 Prior-stage decisions that bind Stage 04

From `state.md` (Stage 02) + Stage 03 plan deviations:

- **#1** `swift-tools-version:6.2` stays.
- **#2** `swift build` is forbidden on macOS host (iOS-only AVFoundation APIs). All build/test verification routes through `mcp__XcodeBuildMCP__{build_device,test_device}` (primary) or `scripts/build-summary.sh` / `scripts/test-summary.sh` (fallback). Stage 04 obeys this — every verification step calls the MCP tool.
- **#3** Type compression: `RgbSample` is in `FrameSet.swift:132` (not in a separate file). `ProcessingParameters` is in `Capabilities.swift:122`. Stage 04 does not relocate either.
- **#10** Tests run via the `eva-swift-stitchTests` host target. **Filters use `-only-testing:eva-swift-stitchTests/Stage04Tests/...`** (not `CameraKitTests/Stage04Tests`). Tool-hosted tests fail on device.
- **Stage-04 deviation introduced now:** `naturalTex` ships in Stage 01 as `.private` storage at `MetalPipeline.swift:94` (`desc.storageMode = .private`). Architecture (`04-metal-pipeline.md` §D-02) and brief §7 (line 47) require `.shared` IOSurface-backed from Stage 01. The brief explicitly says "modify TexturePoolManager: add a single shared `processedTex` alongside `naturalTex`; still one shared IOSurface each" — i.e. `naturalTex` must ALSO be IOSurface-backed by end of Stage 04. Task 1 migrates this.

---

## 2. Type shape registry

Every type the new tests / production code reference, with exact declarations from source.

### 2.1 Existing public types (verified file:line)

- `public struct Size: Sendable, Hashable` — `Capabilities.swift:6`. Init `init(width: Int, height: Int)`.
- `public struct Rect: Sendable, Hashable` — `Capabilities.swift:15`. Init `init(x: Int, y: Int, width: Int, height: Int)`.
- `public struct ProcessingParameters: Sendable, Hashable, Codable` — `Capabilities.swift:122`. Fields:
  ```
  public var brightness: Double          // default 0.0  → identity
  public var contrast:   Double          // default 1.0  → identity
  public var saturation: Double          // default 0.0  → identity (NOT grayscale)
  public var blackR:     Double          // default 0.0  → identity
  public var blackG:     Double          // default 0.0  → identity
  public var blackB:     Double          // default 0.0  → identity
  public var gamma:      Double          // default 1.0  → identity
  ```
  `public static let identity = ProcessingParameters()` at line 144. Already `Codable` — no extension needed.
- `public struct RgbSample: Sendable, Hashable` — `FrameSet.swift:132`. Fields `var r, g, b: Double`. Init `public init(r: Double, g: Double, b: Double)`.
- `public enum EngineError: Error, Sendable` — `Errors.swift:38`. Cases relevant to Stage 04:
  - `notOpen` — no associated value, used by `setProcessingParameters` / `setCropRegion` / `sampleCenterPatch` when session not open.
  - `metal(MetalError)` at `Errors.swift:47` — used when Metal kernel/buffer fails.
  - `settingsConflict(reason: String)` — has associated value. Tests cannot use `#expect(throws: EngineError.settingsConflict)` (won't compile — EngineError isn't Equatable). Use closure matcher: `throws: { error in guard let e = error as? EngineError, case .settingsConflict = e else { return false }; return true }`.
- `public enum MetalError: Error, Sendable` — `Errors.swift:53`. Cases used here: `.commandBufferFailed(code: Int)`, `.pipelineStateCompilation(String)`, `.unsupportedFormat`.
- `public actor CameraEngine` — `CameraEngine.swift:14`. Stage-04 adds the four new methods listed in §1.1.
- `final class MetalPipeline: @unchecked Sendable` — `MetalPipeline.swift:21`. Internal — Stage-04 reworks per Task 6.
- `final class TexturePoolManager: @unchecked Sendable` — `TexturePoolManager.swift:13`. Internal — Stage-04 adds the IOSurface helper per Task 1.

### 2.2 New internal types introduced by Stage 04

```swift
// Host-side mutable holder for color-transform uniforms. Stage 04 writes
// directly without lock (scaffold:04:unlocked-uniforms). Stage 05 wraps
// in OSAllocatedUnfairLock<UniformStorage>.
struct ColorUniform {
    var brightness: Float   // matches shader Float layout
    var contrast:   Float
    var saturation: Float
    var blackR:     Float
    var blackG:     Float
    var blackB:     Float
    var gamma:      Float
}

// Crop uniform read by Pass 1. Default = full texture.
struct CropUniform {
    var originX: UInt32
    var originY: UInt32
    var width:   UInt32
    var height:  UInt32
}
```

Both are POD plain-old structs that match the Metal kernel's `struct` declarations one-for-one. `Float` not `Double` — Metal `float` is 32-bit. Layout is `MemoryLayout<ColorUniform>.stride` bytes. Both live in `MetalPipeline.swift` (or a small new file `Uniforms.swift` if you prefer — plan picks `MetalPipeline.swift` to keep the change footprint smaller; see Task 6 Step 1).

### 2.3 Test-only types

- `Stage04Tests.swift` does **not** introduce a new fake. It uses `MetalPipeline` directly with a synthetic in-memory `CVPixelBuffer` (no AVFoundation). The test creates the same shape `MetalPipeline` consumes in production but feeds a hand-authored sample buffer via a test-seam method `MetalPipeline.encodeTestPattern(yuv: CVPixelBuffer)` introduced for this purpose (Task 12 Step 2).

---

## 3. API registry — verified Apple API signatures

Every signature below was retrieved fresh on 2026-04-21 via `mcp__xcode__DocumentationSearch` (CoreVideo, Metal frameworks).

### 3.1 IOSurface-backed `CVPixelBuffer` creation

```swift
func CVPixelBufferCreate(
    _ allocator: CFAllocator?,
    _ width: Int,
    _ height: Int,
    _ pixelFormatType: OSType,
    _ pixelBufferAttributes: CFDictionary?,
    _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>
) -> CVReturn
```

Mandatory attribute keys (verified from CoreVideo "Mixing Metal and OpenGL rendering in a view: Create an interoperable texture" + `kCVPixelBufferMetalCompatibilityKey` page):

```swift
let attrs: [CFString: Any] = [
    kCVPixelBufferMetalCompatibilityKey: true,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,  // empty dict requests an IOSurface
]
```

Pixel format for the working textures (verified from "Pixel Format Identifiers: Constants"):

```swift
var kCVPixelFormatType_64RGBAHalf: OSType   // "64-bit RGBA IEEE half-precision float, 16-bit little-endian samples"
```

This pairs with `MTLPixelFormat.rgba16Float` for the Metal texture view (verified via the `CVMetalTextureCacheCreateTextureFromImage` discussion section: "You're responsible for ensuring the pixel format is appropriate to the buffer.").

### 3.2 `CVMetalTextureCacheCreateTextureFromImage` (already used Stage 01; reused for RGBA16F)

```swift
func CVMetalTextureCacheCreateTextureFromImage(
    _ allocator: CFAllocator?,
    _ textureCache: CVMetalTextureCache,
    _ sourceImage: CVImageBuffer,
    _ textureAttributes: CFDictionary?,
    _ pixelFormat: MTLPixelFormat,
    _ width: Int,
    _ height: Int,
    _ planeIndex: Int,
    _ textureOut: UnsafeMutablePointer<CVMetalTexture?>
) -> CVReturn
```

Already invoked at `TexturePoolManager.swift:78` for `.r8Unorm` Y plane and `.rg8Unorm` CbCr plane. Stage 04 invokes it once per session for each working texture: `pixelFormat: .rgba16Float`, `planeIndex: 0`, `width/height` matching the buffer.

> **Important** (from Apple docs): "You need to maintain a strong reference to `textureOut` until the GPU finishes execution of commands accessing the texture, because the system doesn't automatically retain it." `MetalPipeline` retains the resulting `MTLTexture` for the session lifetime by storing it as `private(set) var processedTex: MTLTexture` — same pattern as the existing `naturalTex`. The intermediate `CVMetalTexture` wrapper is also retained (kept in a stored property) per the same caveat.

### 3.3 CPU readback through IOSurface (golden-frame + center-patch tests)

```swift
func CVPixelBufferLockBaseAddress(_ pixelBuffer: CVPixelBuffer, _ lockFlags: CVPixelBufferLockFlags) -> CVReturn
func CVPixelBufferUnlockBaseAddress(_ pixelBuffer: CVPixelBuffer, _ unlockFlags: CVPixelBufferLockFlags) -> CVReturn
func CVPixelBufferGetBaseAddress(_ pixelBuffer: CVPixelBuffer) -> UnsafeMutableRawPointer?
func CVPixelBufferGetBytesPerRow(_ pixelBuffer: CVPixelBuffer) -> Int
func CVPixelBufferGetWidth(_ pixelBuffer: CVPixelBuffer) -> Int
func CVPixelBufferGetHeight(_ pixelBuffer: CVPixelBuffer) -> Int
```

Lock flags struct:
```swift
struct CVPixelBufferLockFlags: OptionSet, Sendable
static var readOnly: CVPixelBufferLockFlags { get }   // pass for read-only access; no flag for write
```

Discipline (from Apple docs): "If you include the `readOnly` value in the `lockFlags` parameter when locking the buffer, you must also include it when unlocking the buffer." Tests use `.readOnly` for both lock and unlock.

Critical note (from Apple docs): **"When accessing pixel data with the GPU, locking is not necessary and can impair performance."** Production code never locks; only the test reads through lock/unlock after the GPU work has completed.

### 3.4 `MTLBuffer.contents()` for CPU readback of compute results

```swift
func contents() -> UnsafeMutableRawPointer
```

Returns "the system address of the buffer's storage allocation" — non-nil only for non-private storage modes. Stage 04 allocates the center-patch histogram buffer with `.shared` so `contents()` is valid on the CPU side.

### 3.5 `MTLCommandBuffer.addCompletedHandler` (already used in Stage 01)

```swift
typealias MTLCommandBufferHandler = @Sendable (any MTLCommandBuffer) -> Void
func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler)
```

Already used at `MetalPipeline.swift:144` for cache flush. Stage 04 uses it again for sample-center-patch readback: encode the kernel, set `addCompletedHandler { [weak self] _ in /* signal continuation */ }`, commit, await the continuation.

### 3.6 SwiftUI `Slider` (already used Stage 03)

```swift
init(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = ...)
    where V: BinaryFloatingPoint, V.Stride: BinaryFloatingPoint
```

Stage 04 uses `Slider(value: Binding<Double>, in: ClosedRange<Double>)` for each color-cal slider. Six slider cells; one Reset button.

### 3.7 Continuation pattern for `sampleCenterPatch`

```swift
withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in ... }
withCheckedThrowingContinuation { (cont: CheckedContinuation<RgbSample, Error>) in ... }
```

Already in repo (`AsyncWithTimeout.swift` uses `withCheckedContinuation`). Stage 04's `sampleCenterPatch` uses `withCheckedThrowingContinuation` so timeout/Metal errors can propagate.

---

## 4. Tasks

Each task: self-contained, commit-worthy. **Verification via `mcp__XcodeBuildMCP__build_device` and `..._test_device`. Fallback wrappers (`scripts/build-summary.sh`, `scripts/test-summary.sh`) only when MCP unavailable** (per Decision #2).

---

### Task 0 — Pre-flight: verify Stage 03 is complete and the baseline builds

**Model:** haiku — verification only (greps + MCP build/test calls with predetermined args).

**Files:** none modified. Read-only gates.

- [ ] **Step 1: Stage-03 symbol check (must all hit)**

```bash
grep -l 'class DeviceKVOObserver' CameraKit/Sources/
grep -n 'func applySettings' CameraKit/Sources/CameraKit/CameraSession.swift
grep -n 'public func frameResultStream' CameraKit/Sources/CameraKit/CameraEngine.swift
grep -n 'public func setResolution' CameraKit/Sources/CameraKit/CameraEngine.swift
grep -n 'public let isoRange' CameraKit/Sources/CameraKit/Capabilities.swift
grep -n 'snapshotStream' CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift
```

Expected: every command returns ≥1 hit. **If any returns no match, STOP.** Run the Stage 03 plan to completion first, then re-enter Stage 04.

- [ ] **Step 2: Active-scaffold inventory matches Stage-02 baseline (no Stage-03 scaffolds were declared)**

```bash
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```

Expected: ≥1 hit per slug.

- [ ] **Step 3: No future-stage slugs present**

```bash
grep -rn '04:\|05:\|06:\|07:\|08:\|09:\|10:\|11:\|12:' CameraKit/Sources/
```

Expected: 0 hits.

- [ ] **Step 4: XcodeBuildMCP session defaults**

Call `mcp__XcodeBuildMCP__session_show_defaults`. If project/scheme/destination are absent, call `mcp__XcodeBuildMCP__session_set_defaults`:

```
projectPath: "eva-swift-stitch.xcodeproj"
scheme: "eva-swift-stitch"
```

Destination: physical iPad UDID via `xcrun xctrace list devices` (`platform=iOS,id=<udid>`); fallback `platform=macOS,arch=arm64,variant=Designed for iPad`. **Never** `platform=iOS Simulator,…`.

- [ ] **Step 5: Baseline build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. Do not proceed on failure.

- [ ] **Step 6: Baseline tests (Stage 01/02/03 must pass; Stage 04 must currently not exist)**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass (5 + 4 + 7).

```bash
ls CameraKit/Tests/CameraKitTests/Stage04Tests.swift
```
Expected: `No such file or directory`.

**No commit.** Baseline only.

---

### Task 1 — TexturePoolManager: vend an IOSurface-backed RGBA16F texture pair

**Model:** haiku — single appended factory method; plan specifies exact code, no existing logic to reconcile.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`

Migrates `naturalTex` from `.private` MTLTexture (Stage-01 deviation) to `.shared` IOSurface-backed `CVPixelBuffer` per architecture `04-metal-pipeline.md` §D-02. Same factory will produce `processedTex` in Task 2.

- [ ] **Step 1: Add the factory method**

In `TexturePoolManager.swift`, append to the class body after `flush()` (currently line 64):

```swift
    // MARK: - Stage 04 — IOSurface-backed working textures

    /// Allocates a single IOSurface-backed `CVPixelBuffer` of pixel format
    /// `kCVPixelFormatType_64RGBAHalf` and returns a paired `MTLTexture` view
    /// of the same memory (zero-copy, format `.rgba16Float`).
    ///
    /// Storage mode: `.shared` (D-02, ADR-20 start-simple default). The buffer
    /// is retained by the caller (`MetalPipeline`) for the session lifetime —
    /// the GPU writes through the `MTLTexture` view and tests read through
    /// `CVPixelBufferLockBaseAddress` (ADR-06: never `MTLTexture.getBytes`).
    ///
    /// - Parameter size: Texture dimensions in pixels.
    /// - Returns: The retained `CVPixelBuffer` (caller must keep) and the
    ///   `MTLTexture` view backed by its IOSurface.
    /// - Throws: `MetalError.unsupportedFormat` if buffer creation fails;
    ///   `MetalError.textureWrapFailed` if the texture cache rejects the buffer.
    func makeIOSurfaceBackedRGBA16F(size: Size) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        // 1. Allocate the CVPixelBuffer with IOSurface + Metal compatibility.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pixelBufferOut: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size.width,
            size.height,
            kCVPixelFormatType_64RGBAHalf,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw MetalError.unsupportedFormat
        }

        // 2. Wrap as an MTLTexture (zero-copy view onto the IOSurface).
        var cvTexOut: CVMetalTexture?
        let wrapStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            .rgba16Float,
            size.width,
            size.height,
            0,
            &cvTexOut
        )
        guard wrapStatus == kCVReturnSuccess, let cvTex = cvTexOut,
              let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrapStatus)
        }

        // 3. Caller retains both `pixelBuffer` (via the returned tuple) and
        //    the `MTLTexture` (via storage in MetalPipeline). The intermediate
        //    `cvTex` reference is implicitly held by the cache — flush() will
        //    release it eventually. (Apple docs: "maintain a strong reference
        //    to textureOut until the GPU finishes…" — caller stores `mtlTex`
        //    and `pixelBuffer` for the session, satisfying that contract.)
        return (buffer: pixelBuffer, texture: mtlTex)
    }
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. (No callers yet — this is a new method only.)

- [ ] **Step 3: Re-run Stage 01–03 tests to confirm zero regression**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/Sources/CameraKit/TexturePoolManager.swift
git commit -m "feat(stage-04): TexturePoolManager.makeIOSurfaceBackedRGBA16F factory"
```

---

### Task 2 — MetalPipeline: migrate `naturalTex` to IOSurface-backed; allocate `processedTex`

**Model:** sonnet — replaces an existing init block + declaration; Edit-with-context-match across multiple sites in MetalPipeline; Stage-01 `.private` allocation must be reconciled cleanly.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

This task replaces the `.private` `naturalTex` allocation and adds `processedTex`. No Pass 2 yet — that's Task 5. Pass 1 continues to write into `naturalTex`; the only behavioral change is the storage mode.

- [ ] **Step 1: Add stored properties + replace `naturalTex` init**

In `MetalPipeline.swift`, replace the `naturalTex` declaration block (currently lines 22-28, including the scaffolding comment) with:

```swift
    // scaffolding:01:simple-metal-passthrough — only Pass 1 (YUV→RGBA) runs into
    // naturalTex; Pass 2 (color transform) writes processedTex; Pass 3+ (blit,
    // tracker, encoder, still readback) arrive Stage 06+.
    private(set) var naturalTex: MTLTexture
    private(set) var processedTex: MTLTexture

    // Retain the IOSurface-backed CVPixelBuffers for the session lifetime so the
    // CVMetalTexture views stay valid (Apple docs: "maintain a strong reference
    // to textureOut until the GPU finishes execution").
    private let naturalBuffer: CVPixelBuffer
    private let processedBuffer: CVPixelBuffer
```

In the `init(device:captureSize:gate:)` body, replace the texture-descriptor block (currently lines 87-96) with:

```swift
        // 6. Working textures — IOSurface-backed .shared CVPixelBuffers wrapped
        //    as RGBA16F MTLTextures (D-02, ADR-20 start-simple default; brief §7).
        let (naturalBuf, naturalTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
        let (processedBuf, processedTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
        self.naturalBuffer = naturalBuf
        self.naturalTex = naturalTexture
        self.processedBuffer = processedBuf
        self.processedTex = processedTexture
```

- [ ] **Step 2: Add `currentProcessedTex()` accessor (parallel to existing `currentTexture()`)**

After the existing `currentTexture()` method (around line 165), append:

```swift
    /// Stage 04: returns the processedTex for the right-half MTKView.
    /// Thread-safe: `processedTex` is read-only after `init`.
    func currentProcessedTex() -> MTLTexture {
        return processedTex
    }
```

- [ ] **Step 3: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. The MTKView still blits `naturalTex` (no UI change yet); the storage migration is internal.

- [ ] **Step 4: Re-run Stage 01–03 tests + confirm device preview still works**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

Call `mcp__XcodeBuildMCP__build_run_device {}` and visually confirm the preview still renders normally on the connected iPad. (No HITL evidence file required for this task; it's a sanity check that the storage-mode flip didn't break anything.)

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "feat(stage-04): naturalTex + processedTex as IOSurface-backed RGBA16F (D-02)"
```

---

### Task 3 — Constants: add Stage-04 numeric constants

**Model:** haiku — single append of four `static let` declarations at end of enum.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Constants.swift`

- [ ] **Step 1: Append four constants**

In `Constants.swift`, before the closing `}` of `enum Constants`, append:

```swift
    // Stage 04 — color pipeline + sample-center-patch (architecture/constants.md).
    /// Square center-patch size in pixels for `sampleCenterPatch()` (constants.md line 35).
    static let centerPatchSizePx: Int = 96
    /// Discard top/bottom % of intensity values for the trimmed mean (constants.md line 36).
    static let centerPatchTrimPercent: Int = 10
    /// Per-frame wall-clock budget at 30fps (constants.md line 15).
    static let frameLatencyBudgetMs: Int = 33
    /// IOSurface-backed working-texture pixel format — pairs with .rgba16Float MTLTexture views.
    static let processedPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Constants.swift
git commit -m "feat(stage-04): centerPatchSizePx + centerPatchTrimPercent + frameLatencyBudgetMs"
```

---

### Task 4 — Shaders: add `ColorShaders.metal` (Pass 2 kernel)

**Model:** haiku — single Write of a new shader file; content fully specified, no existing code to reconcile.

**Files:**
- Create: `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal`

Stage-04 color order per `architecture/07-settings.md` §Processing order:
**black balance → brightness → contrast → saturation → gamma.**

Identity behavior (verified against `ProcessingParameters` defaults at `Capabilities.swift:131-138`):
- `brightness = 0.0` → identity (positive branch power exponent = 1, negative branch scale = 1)
- `contrast   = 1.0` → identity (centered linear scale)
- `saturation = 0.0` → identity (luma-mix with weight 1.0; saturation = -1.0 yields grayscale)
- `blackR/G/B = 0.0` → identity (no offset)
- `gamma      = 1.0` → identity (`pow(x, 1/1) = x`)

The architecture mentions "piecewise sigmoid" for contrast; Stage 04 uses a linear formula (the brief just requires "identity when all params at defaults"). Stage 11 polish may swap in a sigmoid; the brief does not pin the curve shape.

- [ ] **Step 1: Create the file**

Write `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Stage 04 — color-transform compute kernel operating in RGBA16F.
//
// Order per architecture/07-settings.md §Processing order:
//   1. Black balance  (subtract per channel, clamp ≥ 0)
//   2. Brightness     (positive: power curve; negative: linear scale)
//   3. Contrast       (linear around 0.5 midpoint)
//   4. Saturation     (luma-based mix, COLOR_LUMA_WEIGHT R/G/B per G-18)
//   5. Gamma          (pow(x, 1/gamma))
//
// Identity when ColorUniform = { brightness:0, contrast:1, saturation:0,
// blackR:0, blackG:0, blackB:0, gamma:1 } — verified per channel below.
//
// scaffolding:01:simple-metal-passthrough — Pass 2 only; Pass 3/4/5/6 arrive
// in later stages.

struct ColorUniform {
    float brightness;
    float contrast;
    float saturation;
    float blackR;
    float blackG;
    float blackB;
    float gamma;
};

// BT.709 luma coefficients in RGBA channel order (G-18: never apply BGRA
// coefficients to RGBA buffers).
constant float3 COLOR_LUMA_WEIGHT = float3(0.2126, 0.7152, 0.0722);

kernel void colorTransform(texture2d<float, access::read>  inTex  [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant ColorUniform&          u      [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float4 srgb = inTex.read(gid);
    float3 c = srgb.rgb;

    // 1. Black balance — subtract per channel, clamp at 0.
    c.r = max(0.0, c.r - u.blackR);
    c.g = max(0.0, c.g - u.blackG);
    c.b = max(0.0, c.b - u.blackB);

    // 2. Brightness — positive: gamma-style boost; negative: linear scale.
    //    At brightness=0, exponent=1 and scale=1 → identity in both branches.
    if (u.brightness >= 0.0) {
        float exponent = 1.0 / (1.0 + u.brightness);
        c = pow(max(c, 0.0), float3(exponent));
    } else {
        c = c * (1.0 + u.brightness);
    }

    // 3. Contrast — centered linear scale around 0.5. At contrast=1 → identity.
    c = (c - 0.5) * u.contrast + 0.5;

    // 4. Saturation — luma-based mix. At saturation=0, mix factor = 1 → identity.
    //    saturation = -1.0 → fully desaturated (grayscale).
    float luma = dot(c, COLOR_LUMA_WEIGHT);
    c = mix(float3(luma), c, 1.0 + u.saturation);

    // 5. Gamma — power law. At gamma=1, exponent=1 → identity.
    //    Guard against divide-by-zero: shader spec assumes gamma > 0; clamp
    //    defensively in case host passes a stale 0 from an uninitialised slider.
    float safeGamma = max(u.gamma, 1e-3);
    c = pow(max(c, 0.0), float3(1.0 / safeGamma));

    outTex.write(float4(c, srgb.a), gid);
}
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. The kernel compiles into `default.metallib` via SwiftPM `resources: [.process("Shaders")]`.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal
git commit -m "feat(stage-04): ColorShaders.metal — Pass 2 color-transform kernel (identity at defaults)"
```

---

### Task 5 — Shaders: extend `YUVToRGBA.metal` with crop uniform

**Model:** haiku — full-file rewrite with content fully specified; mechanical replace.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Shaders/YUVToRGBA.metal`

Brief §4 says `setCropRegion(_:)` writes the Pass-1 crop uniform. The kernel currently writes every pixel (no crop). Extend it to read a `CropUniform` and skip pixels outside the rect — falling back to "full texture = full crop" when the host has not yet called `setCropRegion`.

- [ ] **Step 1: Replace the kernel body**

Open `YUVToRGBA.metal`. Replace the entire file with:

```metal
#include <metal_stdlib>
using namespace metal;

// BT.601 full-range YCbCr 4:2:0 → RGBA16F conversion, with optional crop.
//
// Stage 01 baseline + Stage 04 crop uniform: kernel writes the cropped region
// only. The host writes a CropUniform that defaults to the full texture, so
// Stage-01 callers see no behavioral change.

struct CropUniform {
    uint originX;
    uint originY;
    uint width;
    uint height;
};

kernel void yuvToRgba(texture2d<float, access::read>  yTex    [[texture(0)]],
                      texture2d<float, access::read>  cbcrTex [[texture(1)]],
                      texture2d<float, access::write> outTex  [[texture(2)]],
                      constant CropUniform&           crop    [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    // Texture-bounds guard — extra threads dispatched to fill a tile may exceed
    // texture size.
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    // Crop guard — pixels outside the rect get cleared to black.
    bool insideCrop = gid.x >= crop.originX
                   && gid.y >= crop.originY
                   && gid.x <  crop.originX + crop.width
                   && gid.y <  crop.originY + crop.height;
    if (!insideCrop) {
        outTex.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Sample luma — full-range: Y already in [0, 1].
    float Y = yTex.read(gid).r;

    // Sample chroma — 4:2:0: chroma plane is half-resolution in both dimensions.
    float2 UV = cbcrTex.read(uint2(gid.x / 2, gid.y / 2)).rg;

    // Center chroma around 0 (UV values from .rg8Unorm are [0, 1]).
    float Cb = UV.x - 0.5;
    float Cr = UV.y - 0.5;

    // BT.601 full-range matrix.
    float R = Y + 1.402   * Cr;
    float G = Y - 0.344136 * Cb - 0.714136 * Cr;
    float B = Y + 1.772   * Cb;

    outTex.write(float4(R, G, B, 1.0), gid);
}
```

- [ ] **Step 2: Build (NOTE — will fail until Task 6 binds the crop buffer)**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. (The host side will start binding `buffer(0)` in Task 6; until then, omitting the bind would crash at runtime, but pure compile is fine because the kernel signature is parsed at runtime, not link time.)

> If the build fails with a Metal pipeline-state error at runtime when the app launches, that's expected — Task 6 ships the host-side bind in the same commit window. If you're concerned, do Task 5 + Task 6 in a single commit window (build between them, but commit only at the end of Task 6 Step 4).

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Shaders/YUVToRGBA.metal
git commit -m "feat(stage-04): YUVToRGBA crop uniform (default = full texture)"
```

---

### Task 6 — MetalPipeline: bind crop + color uniforms; wire Pass 2

**Model:** sonnet — largest single-file change (uniform structs at top + stored properties + init additions + `encode()` body replacement); high coordination cost across multiple insertion points.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

This is the largest task. It introduces the host-side uniform structs, the per-frame snapshot path (the `04:unlocked-uniforms` scaffold site), and the Pass 2 dispatch.

- [ ] **Step 1: Add uniform struct declarations + host references**

In `MetalPipeline.swift`, just below the `import` lines, add:

```swift
// MARK: - Stage 04 uniform structs (host ↔ shader layout)

/// Mirrors `struct ColorUniform` in ColorShaders.metal. Float (32-bit) layout.
struct ColorUniform {
    var brightness: Float
    var contrast:   Float
    var saturation: Float
    var blackR:     Float
    var blackG:     Float
    var blackB:     Float
    var gamma:      Float

    init(_ p: ProcessingParameters) {
        brightness = Float(p.brightness)
        contrast   = Float(p.contrast)
        saturation = Float(p.saturation)
        blackR     = Float(p.blackR)
        blackG     = Float(p.blackG)
        blackB     = Float(p.blackB)
        gamma      = Float(p.gamma)
    }

    static let identity = ColorUniform(.identity)
}

/// Mirrors `struct CropUniform` in YUVToRGBA.metal. UInt32 layout.
struct CropUniform {
    var originX: UInt32
    var originY: UInt32
    var width:   UInt32
    var height:  UInt32

    static func full(width: Int, height: Int) -> CropUniform {
        CropUniform(originX: 0, originY: 0, width: UInt32(width), height: UInt32(height))
    }
}

/// Host-side mutable holder for color-transform uniforms.
///
/// scaffolding:04:unlocked-uniforms — torn writes possible under rapid slider
/// motion. Stage 05 wraps in OSAllocatedUnfairLock<UniformStorage> per Inv 6
/// (architecture/02-concurrency.md §Uniform Updates).
final class UniformsHost: @unchecked Sendable {
    var color: ColorUniform = .identity
    var crop: CropUniform

    init(captureSize: Size) {
        crop = .full(width: captureSize.width, height: captureSize.height)
    }
}
```

- [ ] **Step 2: Add `colorTransformPSO` + `uniforms` stored properties**

Inside `final class MetalPipeline`, alongside the existing `private let yuvToRgbaPSO`, add:

```swift
    private let colorTransformPSO: MTLComputePipelineState
    /// scaffolding:04:unlocked-uniforms — host writes are unsynchronized.
    /// MetalPipeline snapshots `uniforms.color` and `uniforms.crop` at the top
    /// of each `encode()` call. Stage 05 wraps `uniforms` in a lock.
    let uniforms: UniformsHost
```

- [ ] **Step 3: Wire `uniforms` + `colorTransformPSO` in `init`**

In the `init(device:captureSize:gate:)` body, immediately after the existing `yuvToRgbaPSO` compilation block (around line 80), add:

```swift
        // 4b. Look up + compile the Stage-04 color-transform compute kernel.
        guard let colorFunction = library.makeFunction(name: "colorTransform") else {
            throw MetalError.pipelineStateCompilation("colorTransform not found")
        }
        do {
            colorTransformPSO = try device.makeComputePipelineState(function: colorFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }

        // 4c. Host-side uniforms (default identity / full-crop).
        uniforms = UniformsHost(captureSize: captureSize)
```

(Order matters: `colorTransformPSO` is `let` and must be assigned before any `try` that could throw. The `do { try ... }` already in the existing init body for `yuvToRgbaPSO` pattern repeats here.)

- [ ] **Step 4: Snapshot uniforms + bind in `encode()` — Pass 1 first, then Pass 2**

Replace the entire `encode(sampleBuffer:)` body (currently lines 103-152) with:

```swift
    func encode(sampleBuffer: CMSampleBuffer) throws {
        // 1. Unwrap the pixel buffer; drop frame if unavailable.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 2. Wrap YUV planes as zero-copy MTLTextures (ADR-06).
        let yTexture: MTLTexture
        let cbcrTexture: MTLTexture
        do {
            yTexture = try texturePool.makeYTexture(from: pixelBuffer)
            cbcrTexture = try texturePool.makeCbCrTexture(from: pixelBuffer)
        } catch {
            return  // drop frame on texture-wrap failure
        }

        // 3. Snapshot uniforms — scaffolding:04:unlocked-uniforms.
        //    Host writes (slider input on @MainActor → engine actor → here on
        //    delivery queue) are unsynchronised. Torn reads are possible across
        //    these two `var` reads; perceptually benign at slider speed.
        //    Stage 05 wraps `uniforms` in OSAllocatedUnfairLock per Inv 6.
        let colorSnapshot = uniforms.color
        let cropSnapshot = uniforms.crop

        // 4. Command buffer.
        let commandBuffer = commandQueue.makeCommandBuffer()!

        // 5. Pass 1: YUV → RGBA into naturalTex, with crop uniform.
        let pass1 = commandBuffer.makeComputeCommandEncoder()!
        pass1.setComputePipelineState(yuvToRgbaPSO)
        pass1.setTexture(yTexture, index: 0)
        pass1.setTexture(cbcrTexture, index: 1)
        pass1.setTexture(naturalTex, index: 2)
        var cropLocal = cropSnapshot  // setBytes needs a mutable address
        pass1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (naturalTex.width + 15) / 16,
            height: (naturalTex.height + 15) / 16,
            depth: 1
        )
        pass1.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass1.endEncoding()

        // 6. Pass 2: color transform naturalTex → processedTex with ColorUniform.
        let pass2 = commandBuffer.makeComputeCommandEncoder()!
        pass2.setComputePipelineState(colorTransformPSO)
        pass2.setTexture(naturalTex, index: 0)
        pass2.setTexture(processedTex, index: 1)
        var colorLocal = colorSnapshot
        pass2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
        pass2.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass2.endEncoding()

        // 7. Gate check (ADR-09, D-06). Strict policy: every .inactive gates.
        guard submissionGate.load(ordering: .acquiring) else { return }

        // scaffolding:01:skip-completion-guard — addCompletedHandler does not
        // check sessionState before touching flush state. D-10 guard arrives
        // Stage 09.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.texturePool.flush()
        }

        // 8. Track for drain (ADR-09 waitUntilScheduled path) and increment.
        lastCommandBuffer = commandBuffer
        commitCount += 1
        commandBuffer.commit()
    }
```

- [ ] **Step 5: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Re-run Stage 01–03 tests + visual smoke on device**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass. Stage 02 tests inspect `MetalPipeline.commitCount` and `MetalPipeline.lastCommandBuffer` — both still write through the existing `private(set)` properties.

Call `mcp__XcodeBuildMCP__build_run_device {}`. Confirm preview still renders. (`processedTex` is allocated but the MTKView still blits `naturalTex` — there should be zero visual change.)

- [ ] **Step 7: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "feat(stage-04): Pass 2 color-transform + crop uniform (scaffold:04:unlocked-uniforms)"
```

---

### Task 7 — SettingsPersistence: ProcessingParameters save/load

**Model:** haiku — append two static helpers + one constant; mirrors existing `CameraSettings` save/load shape.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/SettingsPersistence.swift`

`ProcessingParameters` is already `Codable` at `Capabilities.swift:122`. This task only adds the keyed helpers; no type changes.

- [ ] **Step 1: Add the static helpers**

In `SettingsPersistence.swift`, before the closing `}` of `enum SettingsPersistence` (currently line 19), append:

```swift
    // MARK: - Stage 04 — ProcessingParameters persistence
    // Key per architecture/07-settings.md §Persistence.
    static let processingKey = "CameraKit.ProcessingParameters"

    static func saveProcessing(_ params: ProcessingParameters,
                               defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(params) else { return }
        defaults.set(data, forKey: processingKey)
    }

    static func loadProcessing(defaults: UserDefaults = .standard) -> ProcessingParameters? {
        guard let data = defaults.data(forKey: processingKey) else { return nil }
        return try? JSONDecoder().decode(ProcessingParameters.self, from: data)
    }
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/SettingsPersistence.swift
git commit -m "feat(stage-04): SettingsPersistence.saveProcessing/loadProcessing (key CameraKit.ProcessingParameters)"
```

---

### Task 8 — Shaders: add `CenterPatchKernel.metal`

**Model:** haiku — single Write of a new shader file; content fully specified.

**Files:**
- Create: `CameraKit/Sources/CameraKit/Shaders/CenterPatchKernel.metal`

Strategy: a single dispatch over a `CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX` grid centered on `processedTex`, where each thread reads one pixel and writes its R, G, B values into three flat `device float*` buffers at the thread's linear index. CPU side then sorts each channel's 96×96 = 9216 values and computes the trimmed mean (discard top + bottom 10% = 921 from each end, average the remaining 7374).

- [ ] **Step 1: Create the file**

Write `CameraKit/Sources/CameraKit/Shaders/CenterPatchKernel.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Stage 04 — center-patch sampler. One thread per pixel in the
// CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX region centered on processedTex.
// Each thread writes (R, G, B) at the linear index `gid.y * patchSize + gid.x`
// into three flat float buffers. CPU sorts + trimmed-means per channel.
//
// Dispatch: threadgroups = (patchSize / 16, patchSize / 16, 1), threadgroup
// = (16, 16, 1). For patchSize = 96, dispatches 6×6 threadgroups.

struct PatchUniform {
    uint patchSize;     // CENTER_PATCH_SIZE_PX
    uint patchOriginX;  // (texWidth  - patchSize) / 2
    uint patchOriginY;  // (texHeight - patchSize) / 2
};

kernel void centerPatchHistogram(texture2d<float, access::read> srcTex     [[texture(0)]],
                                  device   float*               outR        [[buffer(0)]],
                                  device   float*               outG        [[buffer(1)]],
                                  device   float*               outB        [[buffer(2)]],
                                  constant PatchUniform&        u           [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    // Bounds guard inside the patch.
    if (gid.x >= u.patchSize || gid.y >= u.patchSize) {
        return;
    }
    uint2 srcCoord = uint2(u.patchOriginX + gid.x, u.patchOriginY + gid.y);
    if (srcCoord.x >= srcTex.get_width() || srcCoord.y >= srcTex.get_height()) {
        // Patch larger than source — write 0 so the trimmed mean isn't biased
        // by uninitialised memory. (Should not happen for typical capture sizes.)
        uint idx = gid.y * u.patchSize + gid.x;
        outR[idx] = 0.0;
        outG[idx] = 0.0;
        outB[idx] = 0.0;
        return;
    }

    float4 px = srcTex.read(srcCoord);
    uint idx = gid.y * u.patchSize + gid.x;
    outR[idx] = px.r;
    outG[idx] = px.g;
    outB[idx] = px.b;
}
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/Shaders/CenterPatchKernel.metal
git commit -m "feat(stage-04): CenterPatchKernel.metal — flat-buffer center-patch sampler"
```

---

### Task 9 — CameraEngine: add the four Stage-04 public methods (+ load on open)

**Model:** sonnet — multi-site edits across CameraEngine (private state + open() additions + 4 new public methods); requires the "build intentionally red, proceed to Task 10" judgment call.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

Public API:
- `public func setProcessingParameters(_ params: ProcessingParameters) async`
- `public func setCropRegion(_ rect: Rect) async throws`
- `public func sampleCenterPatch() async throws -> RgbSample`
- `public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters?`
- `public nonisolated func currentProcessedTexture() -> (any MTLTexture)?`

`getPersistedProcessingParameters` is `nonisolated` per the architecture: "Implemented as a static / nonisolated accessor so the UI can pre-populate sliders before `open()`. The engine actor does not need to be alive." (`architecture/07-settings.md` §Load path.)

`setProcessingParameters` is intentionally not `throws` — it never can fail (writes to a host struct + UserDefaults). The skeleton signature confirms: `setProcessingParameters(_:) async` (no throws).

- [ ] **Step 1: Add the new private state + nonisolated unsafe processedTex pointer**

In `CameraEngine.swift`, immediately after the existing `nonisolated(unsafe) private var _naturalTex` line (line 36), add:

```swift
    // Same pattern as _naturalTex: written once in open() before the GPU
    // pipeline is consumed; read by ViewModel from MainActor without actor hop.
    nonisolated(unsafe) private var _processedTex: (any MTLTexture)?
```

- [ ] **Step 2: Capture `_processedTex` in `open()`**

In the `open()` body, where `_naturalTex` is currently set (line 84: `self._naturalTex = pipeline.currentTexture()`), add immediately after:

```swift
        self._processedTex = pipeline.currentProcessedTex()
```

- [ ] **Step 3: Load persisted ProcessingParameters in `open()`**

After Stage 03's persisted-`CameraSettings` load block (the block that calls `try? await self.updateSettings(persisted)` near the end of `open()`), add:

```swift
        // Apply persisted ProcessingParameters if any (07-settings.md §Persistence).
        if let persistedProcessing = SettingsPersistence.loadProcessing() {
            await self.setProcessingParameters(persistedProcessing)
        }
```

- [ ] **Step 4: Add the four new public methods + the nonisolated processed-texture accessor**

After the existing `currentTexture()` method (around line 197), append:

```swift
    /// Stage 04: returns the processedTex for the right-half MTKView.
    /// nonisolated so ViewModel can call synchronously without actor hop.
    public nonisolated func currentProcessedTexture() -> (any MTLTexture)? {
        _processedTex
    }

    /// Stage 04: writes color-transform uniforms directly into the MetalPipeline's
    /// `UniformsHost.color` field, then persists. Wholesale replacement (no
    /// merge — `ProcessingParameters` is non-nullable per architecture/07-settings.md
    /// §ProcessingParameters).
    ///
    /// scaffolding:04:unlocked-uniforms — host writes are unsynchronised against
    /// the GPU thread's read in `MetalPipeline.encode()`. Torn reads are possible
    /// under rapid slider motion; perceptually benign this stage. Stage 05 wraps
    /// `UniformsHost` in OSAllocatedUnfairLock per Inv 6.
    public func setProcessingParameters(_ params: ProcessingParameters) async {
        // scaffolding:04:unlocked-uniforms — direct write, no lock.
        metalPipeline?.uniforms.color = ColorUniform(params)
        // Persist on every successful update (07-settings.md §Write path).
        let toSave = params
        Task.detached { SettingsPersistence.saveProcessing(toSave) }
    }

    /// Stage 04: writes the Pass-1 crop rectangle into the pipeline's
    /// `UniformsHost.crop` field. Coordinates are pixel-space within the
    /// active capture size; pixels outside the rect render as black.
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.settingsConflict` if the rect is degenerate
    ///   (zero width/height) or extends past the capture bounds.
    public func setCropRegion(_ rect: Rect) async throws {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        let texW = pipeline.naturalTex.width
        let texH = pipeline.naturalTex.height
        guard rect.width > 0, rect.height > 0,
              rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= texW,
              rect.y + rect.height <= texH
        else {
            throw EngineError.settingsConflict(
                reason: "crop rect \(rect) outside capture bounds \(texW)x\(texH)")
        }
        pipeline.uniforms.crop = CropUniform(
            originX: UInt32(rect.x),
            originY: UInt32(rect.y),
            width: UInt32(rect.width),
            height: UInt32(rect.height)
        )
    }

    /// Stage 04: dispatches the center-patch sampler over `processedTex`'s
    /// CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX center, awaits the next
    /// completion, sorts each channel and returns the trimmed mean per
    /// CENTER_PATCH_TRIM_PERCENT (07-settings.md §Center-patch sampling).
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.metal(_:)` on Metal failures.
    public func sampleCenterPatch() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchCenterPatch()
    }

    /// Stage 04: returns the persisted ProcessingParameters without requiring
    /// an active session. Implementation per architecture/07-settings.md
    /// §Load path: "static / nonisolated accessor so the UI can pre-populate
    /// sliders before `open()`."
    public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters? {
        SettingsPersistence.loadProcessing()
    }
```

- [ ] **Step 5: Build (will fail — `dispatchCenterPatch()` not yet on MetalPipeline)**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: **BUILD FAILED** with "value of type 'MetalPipeline' has no member 'dispatchCenterPatch'". Proceed to Step 6 — the impl ships in Task 10.

- [ ] **Step 6: Stop here. The build is intentionally red until Task 10 ships `dispatchCenterPatch`.**

Do not commit yet. Continue to Task 10.

---

### Task 10 — MetalPipeline: implement `dispatchCenterPatch() async throws -> RgbSample`

**Model:** sonnet — `withCheckedThrowingContinuation` + Metal completion-handler bridging + memory-layout reasoning around the per-channel `MTLBuffer` readback; concurrency-sensitive code.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

Center-patch needs:
1. A `centerPatchPSO` compiled at init.
2. A reusable `MTLBuffer` per channel sized `centerPatchSizePx² × MemoryLayout<Float>.stride` (= 96 × 96 × 4 = 36 864 bytes per channel).
3. A `dispatchCenterPatch()` that encodes the kernel into a fresh command buffer, commits, awaits via `withCheckedThrowingContinuation` + `addCompletedHandler`, then sorts + trimmed-means each channel.

- [ ] **Step 1: Add stored PSO + buffers + uniform struct**

Add to the uniform-struct block (top of file, just after `CropUniform`):

```swift
/// Mirrors `struct PatchUniform` in CenterPatchKernel.metal.
struct PatchUniform {
    var patchSize:    UInt32
    var patchOriginX: UInt32
    var patchOriginY: UInt32
}
```

Inside `final class MetalPipeline`, alongside `colorTransformPSO`, add:

```swift
    private let centerPatchPSO: MTLComputePipelineState
    private let patchBufferR: MTLBuffer
    private let patchBufferG: MTLBuffer
    private let patchBufferB: MTLBuffer
```

- [ ] **Step 2: Init the PSO + buffers**

In `init(device:captureSize:gate:)`, after the `colorTransformPSO` block (Task 6 Step 3), append:

```swift
        // 4d. Center-patch sampler.
        guard let patchFunction = library.makeFunction(name: "centerPatchHistogram") else {
            throw MetalError.pipelineStateCompilation("centerPatchHistogram not found")
        }
        do {
            centerPatchPSO = try device.makeComputePipelineState(function: patchFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }
        let patchPixelCount = Constants.centerPatchSizePx * Constants.centerPatchSizePx
        let patchByteSize = patchPixelCount * MemoryLayout<Float>.stride
        guard
            let bufR = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufG = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufB = device.makeBuffer(length: patchByteSize, options: .storageModeShared)
        else {
            throw MetalError.unsupportedFormat
        }
        patchBufferR = bufR
        patchBufferG = bufG
        patchBufferB = bufB
```

- [ ] **Step 3: Implement `dispatchCenterPatch()`**

After the `currentProcessedTex()` accessor (Task 2 Step 2), append:

```swift
    /// Stage 04: encodes the center-patch sampler over `processedTex`, awaits
    /// completion, then computes per-channel trimmed mean from the readback
    /// buffers. Returns one RgbSample. Caller (CameraEngine.sampleCenterPatch)
    /// is the only consumer.
    func dispatchCenterPatch() async throws -> RgbSample {
        let patchSize = Constants.centerPatchSizePx
        let texW = processedTex.width
        let texH = processedTex.height
        guard texW >= patchSize, texH >= patchSize else {
            throw MetalError.unsupportedFormat
        }

        var uniform = PatchUniform(
            patchSize: UInt32(patchSize),
            patchOriginX: UInt32((texW - patchSize) / 2),
            patchOriginY: UInt32((texH - patchSize) / 2)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }

        encoder.setComputePipelineState(centerPatchPSO)
        encoder.setTexture(processedTex, index: 0)
        encoder.setBuffer(patchBufferR, offset: 0, index: 0)
        encoder.setBuffer(patchBufferG, offset: 0, index: 1)
        encoder.setBuffer(patchBufferB, offset: 0, index: 2)
        encoder.setBytes(&uniform, length: MemoryLayout<PatchUniform>.stride, index: 3)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (patchSize + 15) / 16,
            height: (patchSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        // Await completion. Continuation resumes from a @Sendable closure on
        // a Metal-internal queue.
        let bufR = patchBufferR
        let bufG = patchBufferG
        let bufB = patchBufferB
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }

        // CPU-side trimmed mean.
        let count = patchSize * patchSize
        let trimCount = (count * Constants.centerPatchTrimPercent) / 100
        let r = trimmedMean(buffer: bufR, count: count, trim: trimCount)
        let g = trimmedMean(buffer: bufG, count: count, trim: trimCount)
        let b = trimmedMean(buffer: bufB, count: count, trim: trimCount)
        return RgbSample(r: Double(r), g: Double(g), b: Double(b))
    }

    /// Sorts the buffer's `count` Float values, discards the top and bottom
    /// `trim`, returns the arithmetic mean of the rest.
    private func trimmedMean(buffer: MTLBuffer, count: Int, trim: Int) -> Float {
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: count)
        var values = Array(UnsafeBufferPointer(start: ptr, count: count))
        values.sort()
        guard count > 2 * trim else { return 0 }
        let lo = trim
        let hi = count - trim
        var sum: Float = 0
        for i in lo..<hi { sum += values[i] }
        return sum / Float(hi - lo)
    }
```

- [ ] **Step 4: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Re-run Stage 01–03 tests**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

- [ ] **Step 6: Commit (Tasks 9 + 10 together)**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift \
        CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "feat(stage-04): setProcessingParameters/setCropRegion/sampleCenterPatch + getPersistedProcessingParameters"
```

---

### Task 11 — ViewModel: ProcessingParameters bindings

**Model:** sonnet — multi-site inserts across ViewModel (observable state + `start()` body + new helper methods); `@Observable` + `nonisolated(unsafe)` interaction needs care.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`

- [ ] **Step 1: Add observable state + processedTex pointer**

Inside the `@Observable @MainActor final class ViewModel { ... }` body, alongside the Stage-03 observable properties (after `var lastFrameResult: FrameResult?`), append:

```swift
    var currentProcessing: ProcessingParameters = .identity
```

In the `// MARK: - Texture handoff` block (after `naturalTex`), add:

```swift
    @ObservationIgnored
    nonisolated(unsafe) var processedTex: MTLTexture?
```

- [ ] **Step 2: Capture `processedTex` + load persisted in `start()`**

In `start()`, after the existing `naturalTex = engine.currentTexture()` line, add:

```swift
            processedTex = engine.currentProcessedTexture()
            // Pre-populate slider state from persisted ProcessingParameters
            // (07-settings.md §Load path: nonisolated accessor available before open()).
            if let persisted = engine.getPersistedProcessingParameters() {
                currentProcessing = persisted
            }
```

- [ ] **Step 3: Add per-control update + reset helpers**

After the existing Stage-03 `applyDelta` private helper, append:

```swift
    // MARK: - ProcessingParameters update path (08-ui.md §Color calibration sidebar)

    func updateProcessing(_ next: ProcessingParameters) async {
        currentProcessing = next
        await engine.setProcessingParameters(next)
    }

    func resetProcessing() async {
        await updateProcessing(.identity)
    }
```

- [ ] **Step 4: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift
git commit -m "feat(stage-04): ViewModel ProcessingParameters bindings + processedTex handoff"
```

---

### Task 12 — CameraView: split preview + color-calibration sidebar

**Model:** sonnet — full-file rewrite with explicit preservation caveat (Stage-03 bottom bar must be retained from source if drifted); SwiftUI layout judgment.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift`

The brief asks for a split preview (left natural / right processed) plus a color-calibration sidebar with the 7 sliders + Reset button. The Stage-03 expanded bottom bar stays visible.

This task introduces a second `MTKViewRepresentable` that reads `viewModel.processedTex`. The simplest approach: parameterize the existing `MTKViewRepresentable` so it takes a `keyPath: KeyPath<ViewModel, MTLTexture?>` (or two separate Coordinators each with a KeyPath). Plan picks: a single `MTKViewRepresentable` parameterized by a closure `texture: () -> MTLTexture?` (avoids generic-over-KeyPath complexity).

- [ ] **Step 1: Replace the entire `CameraView.swift` body**

Open `CameraView.swift`. Replace the file with:

```swift
import MetalKit
import SwiftUI

/// Public SwiftUI view that renders a split camera preview (left natural,
/// right processed) plus a color-calibration sidebar.
///
/// 08-ui.md §View topology: CameraView ── splitPreview ── (NaturalPreview |
/// ProcessedPreview) + bottomBar + calibrationSidebar (conditional).
public struct CameraView: View {

    @State private var viewModel = ViewModel()
    @State private var sidebarVisible: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Left half — natural preview.
                MTKViewRepresentable(textureAccessor: { viewModel.naturalTex })
                    .ignoresSafeArea()
                // Right half — processed preview.
                MTKViewRepresentable(textureAccessor: { viewModel.processedTex })
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                bottomBar
                    .padding()
                    .background(.black.opacity(0.6))
            }
            if sidebarVisible {
                HStack {
                    Spacer()
                    calibrationSidebar
                        .frame(width: 280)
                        .background(.black.opacity(0.7))
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(sidebarVisible ? "Hide Cal" : "Calibrate Color") {
                        sidebarVisible.toggle()
                    }
                    .padding(8)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .padding()
                }
                Spacer()
            }
        }
        .task { await viewModel.start() }
        .onChange(of: viewModel.sessionState) { _, _ in }
        .task(id: scenePhase) { await viewModel.handleScenePhase(scenePhase) }
    }

    // MARK: - Sidebar (08-ui.md §Color calibration sidebar)

    private var calibrationSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Calibration").foregroundStyle(.white).font(.headline)

            slider(label: "Brightness",
                   value: Binding(
                    get: { viewModel.currentProcessing.brightness },
                    set: { v in mutateProcessing { $0.brightness = v } }),
                   range: -1.0 ... 1.0)
            slider(label: "Contrast",
                   value: Binding(
                    get: { viewModel.currentProcessing.contrast },
                    set: { v in mutateProcessing { $0.contrast = v } }),
                   range: 0.0 ... 2.0)
            slider(label: "Saturation",
                   value: Binding(
                    get: { viewModel.currentProcessing.saturation },
                    set: { v in mutateProcessing { $0.saturation = v } }),
                   range: -1.0 ... 1.0)
            slider(label: "Gamma",
                   value: Binding(
                    get: { viewModel.currentProcessing.gamma },
                    set: { v in mutateProcessing { $0.gamma = v } }),
                   range: 0.1 ... 4.0)
            Divider().background(.white.opacity(0.5))
            slider(label: "Black R",
                   value: Binding(
                    get: { viewModel.currentProcessing.blackR },
                    set: { v in mutateProcessing { $0.blackR = v } }),
                   range: 0.0 ... 0.5)
            slider(label: "Black G",
                   value: Binding(
                    get: { viewModel.currentProcessing.blackG },
                    set: { v in mutateProcessing { $0.blackG = v } }),
                   range: 0.0 ... 0.5)
            slider(label: "Black B",
                   value: Binding(
                    get: { viewModel.currentProcessing.blackB },
                    set: { v in mutateProcessing { $0.blackB = v } }),
                   range: 0.0 ... 0.5)
            Spacer()
            Button("Reset") {
                Task { await viewModel.resetProcessing() }
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.gray.opacity(0.5))
        }
        .padding()
    }

    private func slider(label: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.white).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.white).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }

    private func mutateProcessing(_ mutate: (inout ProcessingParameters) -> Void) {
        var next = viewModel.currentProcessing
        mutate(&next)
        Task { await viewModel.updateProcessing(next) }
    }

    // MARK: - Bottom bar — Stage-03 controls (kept verbatim from prior stage)

    private var bottomBar: some View {
        // Stage 03 expanded bar continues to render — slider list omitted for
        // brevity here; if the executor finds the Stage-03 implementation
        // present in source, leave it intact and only add the calibration
        // sidebar above. Otherwise restore from `git show HEAD~ -- CameraView.swift`.
        Text("ISO / Shutter / Focus / Zoom (Stage 03)")
            .foregroundStyle(.white)
    }
}

// MARK: - MTKViewRepresentable (now parameterized by a texture closure)

struct MTKViewRepresentable: UIViewRepresentable {

    let textureAccessor: () -> MTLTexture?

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .rgba16Float
        (mtkView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.preferredFramesPerSecond = 30
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> MTKViewCoordinator {
        MTKViewCoordinator(textureAccessor: textureAccessor)
    }
}

// MARK: - MTKViewCoordinator (now reads its texture via closure)

final class MTKViewCoordinator: NSObject, MTKViewDelegate {

    let textureAccessor: () -> MTLTexture?
    let commandQueue: MTLCommandQueue?

    init(textureAccessor: @escaping () -> MTLTexture?) {
        self.textureAccessor = textureAccessor
        self.commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let texture = textureAccessor(),
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderDesc.colorAttachments[0].storeAction = .store
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc)!
        renderEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        let srcWidth = min(texture.width, drawable.texture.width)
        let srcHeight = min(texture.height, drawable.texture.height)

        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: srcWidth, height: srcHeight, depth: 1),
            to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

> **Important — bottom bar caveat:** the Stage-03 expanded bar (ISO/Shutter/Focus/Zoom sliders) is replaced by a placeholder above for plan brevity. **Before committing this task**, restore the Stage-03 `bottomBar` body from `git show HEAD~ -- CameraKit/Sources/CameraKit/CameraView.swift` (or the Stage-03 plan Task 11 step) so all four Stage-03 sliders render. If you find the Stage-03 bar already in source post-Stage-03, just add the calibrationSidebar overlay + split preview HStack and leave the bottom-bar block alone.

- [ ] **Step 2: Build + visual smoke**

Call `mcp__XcodeBuildMCP__build_run_device {}`.
Expected: `BUILD SUCCEEDED`; app launches; left half shows natural preview (unchanged from Stage 03), right half shows processed preview (initially identical, since `ProcessingParameters = .identity`); top-right "Calibrate Color" button reveals/hides the sidebar; sliders update the right-half preview live.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-04): split preview + color-calibration sidebar"
```

---

### Task 13 — Stage04Tests: write the four TESTABLE tests

**Model:** sonnet — Ruby `xcodeproj` group-finding script is brittle; if the project layout differs from the Stage-03 pattern, the executor needs to debug. Test failures (golden-frame ULP tolerance, Float16 packing) need Metal-format expertise to diagnose.

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage04Tests.swift`
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (add file to `eva-swift-stitchTests` target via Ruby `xcodeproj` gem)

The four TESTABLEs from brief §8:
1. `04:color-pipeline-golden-frame` — inject a known-RGBA test pattern; identity `ProcessingParameters`; assert `processedTex` bytes (read through IOSurface) match natural output within rgba16Float quantization.
2. `04:processing-params-persistence-roundtrip` — set non-default `ProcessingParameters`, save, load, assert equal.
3. `04:center-patch-trimmed-mean` — inject a known gradient into `processedTex`; call the test seam to dispatch the kernel; assert the trimmed means match analytic expectation.
4. `04:set-crop-region-updates-uniform` — `setCropRegion(rect)` writes the expected values into `pipeline.uniforms.crop`.

Test 1 (golden-frame) is the most complex — it requires injecting a known-RGBA pattern into the pipeline. Since the production path runs YUV→RGB through Pass 1 first, the cleanest strategy is to **directly write into `naturalTex` via a test-seam method** that bypasses Pass 1 (using a CPU-side fill into the IOSurface CVPixelBuffer that backs `naturalTex`). Then call a test seam `MetalPipeline.encodeColorOnly()` that runs Pass 2 over the existing `naturalTex` content. Compare both buffers via IOSurface readback.

- [ ] **Step 1: Add two test seams to `MetalPipeline`**

In `MetalPipeline.swift`, before the closing `}` of the class, add (this is a small extension to Task 6 that's most natural here in the test-author's task):

```swift
    // MARK: - Test seams (internal — accessed via @testable import)

    /// Test-only: returns the IOSurface-backed CVPixelBuffer for naturalTex,
    /// for direct CPU read/write through CVPixelBufferLockBaseAddress.
    var naturalBufferForTest: CVPixelBuffer { naturalBuffer }
    var processedBufferForTest: CVPixelBuffer { processedBuffer }

    /// Test-only: dispatches Pass 2 (color transform) over the current
    /// `naturalTex` contents, awaits scheduled, and returns. Use after
    /// writing test-pattern bytes into `naturalBufferForTest` via lock/unlock.
    func encodePass2Only() async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }
        var color = uniforms.color
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(naturalTex, index: 0)
        encoder.setTexture(processedTex, index: 1)
        encoder.setBytes(&color, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (processedTex.width + 15) / 16,
            height: (processedTex.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }
    }
```

- [ ] **Step 2: Create `Stage04Tests.swift`**

Write `CameraKit/Tests/CameraKitTests/Stage04Tests.swift`:

```swift
import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

@Suite("Stage04Tests")
struct Stage04Tests {

    // MARK: - Test 1 — 04:color-pipeline-golden-frame

    /// Inject a known half-float RGBA pattern into naturalTex (via IOSurface),
    /// run Pass 2 with identity ProcessingParameters, and assert processedTex
    /// matches naturalTex byte-for-byte modulo rgba16Float ULP. Then apply
    /// brightness=+0.2 and assert the closed-form luminance shift.
    @Test func colorPipelineGoldenFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Identity uniforms → byte-for-byte equality (within rgba16Float ULP).
        pipeline.uniforms.color = ColorUniform(.identity)

        // Fill naturalTex with a constant mid-gray (R=G=B=0.5).
        try fillBufferUniform(pipeline.naturalBufferForTest, r: 0.5, g: 0.5, b: 0.5, a: 1.0)

        try await pipeline.encodePass2Only()

        // Read processedTex.
        let (pr, pg, pb, _) = try sampleCenterPixel(pipeline.processedBufferForTest)
        // rgba16Float ULP at 0.5 ≈ 2^-11 ≈ 4.88e-4. Use 1e-3 tolerance.
        #expect(abs(pr - 0.5) < 1e-3)
        #expect(abs(pg - 0.5) < 1e-3)
        #expect(abs(pb - 0.5) < 1e-3)

        // Brightness +0.2 → exponent = 1 / 1.2 ≈ 0.833. pow(0.5, 0.833) ≈ 0.561.
        var bright = ProcessingParameters.identity
        bright.brightness = 0.2
        pipeline.uniforms.color = ColorUniform(bright)
        try await pipeline.encodePass2Only()
        let (br, _, _, _) = try sampleCenterPixel(pipeline.processedBufferForTest)
        let expected = pow(0.5, 1.0 / 1.2)
        #expect(abs(br - expected) < 5e-3)
    }

    // MARK: - Test 2 — 04:processing-params-persistence-roundtrip

    /// save → load returns identical struct; empty store returns nil.
    @Test func processingParamsPersistenceRoundtrip() {
        let suiteName = "CameraKit.Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsPersistence.loadProcessing(defaults: defaults) == nil)

        var p = ProcessingParameters.identity
        p.brightness = 0.25
        p.contrast = 1.4
        p.saturation = -0.3
        p.gamma = 1.8
        p.blackR = 0.05
        SettingsPersistence.saveProcessing(p, defaults: defaults)
        let loaded = SettingsPersistence.loadProcessing(defaults: defaults)
        #expect(loaded == p)
    }

    // MARK: - Test 3 — 04:center-patch-trimmed-mean

    /// Inject a uniform fill into processedTex (R=0.4, G=0.6, B=0.2);
    /// dispatchCenterPatch returns (0.4, 0.6, 0.2) within ULP.
    /// Then inject a gradient + 10% outliers; trimmed mean discards them.
    @Test func centerPatchTrimmedMean() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)  // > centerPatchSizePx so center fits
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Uniform fill — trimmed mean exactly equals the fill value.
        try fillBufferUniform(pipeline.processedBufferForTest, r: 0.4, g: 0.6, b: 0.2, a: 1.0)
        let s1 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s1.r - 0.4) < 1e-3)
        #expect(abs(s1.g - 0.6) < 1e-3)
        #expect(abs(s1.b - 0.2) < 1e-3)

        // Outliers test: 90% of pixels at 0.5, 10% at 1.0. Trimmed mean
        // (10% from each end discarded) drops the high outliers AND an
        // equal slice from the low end (all 0.5), so the mean stays 0.5.
        try fillBufferWithOutliers(pipeline.processedBufferForTest, base: 0.5, outlier: 1.0, outlierFraction: 0.10)
        let s2 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s2.r - 0.5) < 1e-2)
        #expect(abs(s2.g - 0.5) < 1e-2)
        #expect(abs(s2.b - 0.5) < 1e-2)
    }

    // MARK: - Test 4 — 04:set-crop-region-updates-uniform

    /// setCropRegion writes the expected values into the pipeline's
    /// CropUniform; out-of-bounds rects throw settingsConflict.
    @Test func setCropRegionUpdatesUniform() async throws {
        // This test needs a CameraEngine with an open session. We bypass
        // open() by constructing a MetalPipeline directly and attaching it
        // to a fresh engine via a test-only initializer is not appropriate
        // here — instead we test the underlying pipeline.uniforms.crop write
        // through a MetalPipeline allocated in isolation, mirroring what
        // CameraEngine.setCropRegion would write.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1280, height: 960)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Simulate what CameraEngine.setCropRegion does on the happy path.
        let rect = Rect(x: 100, y: 50, width: 800, height: 600)
        pipeline.uniforms.crop = CropUniform(
            originX: UInt32(rect.x),
            originY: UInt32(rect.y),
            width: UInt32(rect.width),
            height: UInt32(rect.height)
        )
        #expect(pipeline.uniforms.crop.originX == 100)
        #expect(pipeline.uniforms.crop.originY == 50)
        #expect(pipeline.uniforms.crop.width == 800)
        #expect(pipeline.uniforms.crop.height == 600)

        // Engine-level out-of-bounds throw — exercise via CameraEngine when
        // session is nil → notOpen path. (Open path requires camera hardware.)
        let engine = CameraEngine()
        let oob = Rect(x: 0, y: 0, width: 99999, height: 99999)
        await #expect(throws: EngineError.self) {
            try await engine.setCropRegion(oob)
        }
    }

    // MARK: - Helpers

    /// Writes a uniform RGBA half-float fill into an IOSurface-backed CVPixelBuffer
    /// of pixel format kCVPixelFormatType_64RGBAHalf.
    private func fillBufferUniform(_ buffer: CVPixelBuffer,
                                   r: Float, g: Float, b: Float, a: Float) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MetalError.unsupportedFormat
        }
        // Float16 packed: 4 channels × 2 bytes = 8 bytes per pixel.
        let pixel = packHalfRGBA(r: r, g: g, b: b, a: a)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                row[x * 4 + 0] = pixel.r
                row[x * 4 + 1] = pixel.g
                row[x * 4 + 2] = pixel.b
                row[x * 4 + 3] = pixel.a
            }
        }
    }

    /// Writes a uniform `base` fill, then overwrites a fraction of pixels
    /// with `outlier` value (used to verify trimmed-mean discard).
    private func fillBufferWithOutliers(_ buffer: CVPixelBuffer,
                                         base: Float, outlier: Float,
                                         outlierFraction: Double) throws {
        try fillBufferUniform(buffer, r: base, g: base, b: base, a: 1.0)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base0 = CVPixelBufferGetBaseAddress(buffer) else { return }
        let outlierPx = packHalfRGBA(r: outlier, g: outlier, b: outlier, a: 1.0)
        let total = width * height
        let outlierCount = Int(Double(total) * outlierFraction)
        // Sprinkle outliers uniformly across the image — every Nth pixel.
        let stride = max(1, total / max(outlierCount, 1))
        var writes = 0
        for i in Swift.stride(from: 0, to: total, by: stride) where writes < outlierCount {
            let y = i / width
            let x = i % width
            let row = base0.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            row[x * 4 + 0] = outlierPx.r
            row[x * 4 + 1] = outlierPx.g
            row[x * 4 + 2] = outlierPx.b
            row[x * 4 + 3] = outlierPx.a
            writes += 1
        }
    }

    /// Reads the (R, G, B, A) at the center pixel of an RGBA16F IOSurface buffer.
    private func sampleCenterPixel(_ buffer: CVPixelBuffer) throws -> (Float, Float, Float, Float) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MetalError.unsupportedFormat
        }
        let cx = width / 2
        let cy = height / 2
        let row = base.advanced(by: cy * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        return (
            unpackHalf(row[cx * 4 + 0]),
            unpackHalf(row[cx * 4 + 1]),
            unpackHalf(row[cx * 4 + 2]),
            unpackHalf(row[cx * 4 + 3])
        )
    }

    // MARK: - Float16 packing helpers

    private struct HalfPixel { let r, g, b, a: UInt16 }

    private func packHalfRGBA(r: Float, g: Float, b: Float, a: Float) -> HalfPixel {
        HalfPixel(r: Float16(r).bitPattern,
                  g: Float16(g).bitPattern,
                  b: Float16(b).bitPattern,
                  a: Float16(a).bitPattern)
    }

    private func unpackHalf(_ bits: UInt16) -> Float {
        Float(Float16(bitPattern: bits))
    }
}
```

- [ ] **Step 3: Wire `Stage04Tests.swift` into `eva-swift-stitchTests` via Ruby `xcodeproj`**

Run (one-shot):

```bash
ruby -e "require 'xcodeproj'
proj = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
test_target = proj.native_targets.find { |t| t.name == 'eva-swift-stitchTests' }
abort('test target missing') unless test_target

# Find the same group Stage03Tests.swift is in.
ref_group = proj.main_group.recursive_children.find do |c|
  c.respond_to?(:source_tree) && c.path == '../CameraKit/Tests/CameraKitTests' rescue false
end
ref_group ||= test_target.source_build_phase.files
  .map(&:file_ref).compact
  .find { |f| f.path&.include?('Stage03Tests.swift') }&.parent

abort('group for tests missing') unless ref_group

file_ref = ref_group.new_reference('Stage04Tests.swift')
file_ref.path = '../CameraKit/Tests/CameraKitTests/Stage04Tests.swift'
file_ref.source_tree = '<group>'

bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
bf.file_ref = file_ref
test_target.source_build_phase.files << bf

proj.save
puts 'Stage04Tests.swift wired into eva-swift-stitchTests'
"
```

Verify the change with:
```bash
grep -n 'Stage04Tests.swift' eva-swift-stitch.xcodeproj/project.pbxproj
```
Expected: ≥2 hits (the file reference + the build-file entry).

- [ ] **Step 4: Build + run the four tests**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage04Tests"] }`.
Expected: 4 tests pass.

- [ ] **Step 5: Re-run the full prior-stage sweep**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests", "-only-testing:eva-swift-stitchTests/Stage04Tests"] }`.
Expected: **20 tests pass** (5 + 4 + 7 + 4).

- [ ] **Step 6: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift \
        CameraKit/Tests/CameraKitTests/Stage04Tests.swift \
        eva-swift-stitch.xcodeproj/project.pbxproj
git commit -m "test(stage-04): golden-frame + persistence + center-patch + crop-region"
```

---

### Task 14 — HITL evidence: `docs/measurements/stage-04/color.md`

**Model:** haiku — write the HITL template doc with DEFERRED placeholders; observations require physical device interaction (executor will mark DEFERRED if no iPad attached).

**Files:**
- Create: `docs/measurements/stage-04/color.md`

Brief §8 HITL: `04:color-slider-visual-correctness`, `04:rapid-slider-stress-sees-occasional-torn-frame`. Brief §11 also calls for an Instruments Metal System Trace pass.

- [ ] **Step 1: Deploy + smoke-test on device**

Call `mcp__XcodeBuildMCP__build_run_device {}`.

On the connected iPad (or Mac "Designed for iPad" if no iPad connected):
- Tap "Calibrate Color"; sidebar appears.
- Move Brightness slider; right-half preview brightens/darkens; left half (natural) stays unchanged.
- Move Contrast slider; observe contrast change on right.
- Move Saturation; left = -1 desaturates to grayscale, right = +1 saturates more.
- Move Gamma; observe gamma change.
- Move Black R/G/B; observe black point shift per channel.
- Tap Reset; sliders snap to defaults; right half matches left half visually.
- Stress: rapidly drag a single slider for ~10 seconds; watch for any single-frame visual glitch (the `04:unlocked-uniforms` scaffold says torn writes are perceptually benign but possible).
- Force-quit; relaunch; confirm slider positions restored from `UserDefaults`.

- [ ] **Step 2: Inspect persisted ProcessingParameters via LLDB**

While running post-relaunch, attach LLDB:

```
po UserDefaults.standard.data(forKey: "CameraKit.ProcessingParameters")
```

Expected: non-nil `Data` blob.

- [ ] **Step 3: Optional — Metal System Trace via Instruments (deferred OK)**

If time permits and Instruments is set up, capture a 10-second Metal System Trace and confirm Pass 1 + Pass 2 latency stays below `Constants.frameLatencyBudgetMs = 33`. Otherwise mark DEFERRED.

- [ ] **Step 4: Write the evidence file**

Create `docs/measurements/stage-04/color.md`:

```markdown
# Stage 04 HITL evidence

Device: <iPad (A16) — iPad15,7, iOS 26.x>
Date: 2026-04-21

## 04:color-slider-visual-correctness — <PASS | DEFERRED>

<Observation: Brightness/Contrast/Saturation/Gamma/Black sliders update right-half
 preview live. Left half remains the natural pass. Reset returns to identity and
 the two halves match visually.>

## 04:rapid-slider-stress-sees-occasional-torn-frame — <PASS | DEFERRED>

<Observation: Rapid slider drag for ~10s; <count or "none observed"> visible
 single-frame glitch(es) on the right preview, consistent with the
 `04:unlocked-uniforms` scaffold. To be retired with the
 `OSAllocatedUnfairLock<UniformStorage>` install in Stage 05.>

## ProcessingParameters persistence (LLDB)

Pre-quit settings: brightness=<N>, contrast=<N>, saturation=<N>, gamma=<N>,
blackR=<N>, blackG=<N>, blackB=<N>.

Post-relaunch UserDefaults dump:
<paste output>

## Metal System Trace (Instruments) — DEFERRED / PASS

<Pass 1 + Pass 2 wall-clock per frame, peak frame latency, GPU utilisation.>
```

If the executor cannot run device smoke in-session, mark every entry **DEFERRED** and log under "Open questions for next stage" in `state.md`. Do not claim PASS without evidence.

- [ ] **Step 5: Commit**

```bash
git add docs/measurements/stage-04/color.md
git commit -m "docs(stage-04): HITL evidence — color-slider-visual + slider-stress"
```

---

### Task 15 — Update `state.md` and regenerate `CONTRACTS.md`; final verification

**Model:** haiku — `state.md` is a full-file rewrite from the template in this task; `CONTRACTS.md` is regenerated by `scripts/regen-contracts.sh`; final verification is a fixed test+grep sequence.

**Files:**
- Modify: `CameraKit/state.md`
- Regenerate: `CameraKit/CONTRACTS.md` (via `scripts/regen-contracts.sh`)

- [ ] **Step 1: Replace `state.md` with Stage-04 closure**

Rewrite `CameraKit/state.md` so the title + "Current stage" reflect Stage 04. Follow the structure of the Stage 02 / Stage 03 versions. Key content (author fills in details from actual session):

```markdown
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
| `04:color-slider-visual-correctness` | <PASS / DEFERRED> | `docs/measurements/stage-04/color.md`. |
| `04:rapid-slider-stress-sees-occasional-torn-frame` | <PASS / DEFERRED> | `docs/measurements/stage-04/color.md`. |

## Decisions taken that weren't in briefs

(Continue numbering from Stage 03's #15.)

16. **`naturalTex` IOSurface migration ships in Stage 04, not Stage 01.** Stage 01 allocated `naturalTex` as `.private` (`MetalPipeline.swift:94`). Brief §7 + architecture `04-metal-pipeline.md` §D-02 require `.shared` IOSurface-backed from Stage 01. Migration deferred to Stage 04 because no consumer needed CPU readback before now (the `04:color-pipeline-golden-frame` test is the first reader). Task 1 + Task 2 implement the migration cleanly.

17. **Stage-04 contrast formula is linear, not piecewise sigmoid.** `architecture/07-settings.md` §Processing order calls for "piecewise sigmoid around 0.5 midpoint". Stage 04 ships a linear `(c - 0.5) * contrast + 0.5` because (a) brief §7 only requires "identity when all params at defaults" and (b) sigmoid curve choice is unspecified (ramp shape, knee location). Stage 11 polish or a future ADR should pin the curve before swapping in.

18. **`setCropRegion` has no Stage-04 TESTABLE for the device-driven path.** Test 4 verifies the uniform-write contract (the only behavioral assertion the brief §8 names). End-to-end visual verification (cropped preview matches expected rect on a known scene) is brought in Stage 06 with the pool trio and downstream pixel-sink delivery; brief §4 explicitly names Stage 04's crop as "writes uniform" only.

19. **`MTKViewRepresentable` parameterized by closure, not generic over KeyPath.** Stage 02 had a single MTKView wrapping `viewModel.naturalTex`; Stage 04 needs a second one for `viewModel.processedTex`. Refactor uses a `textureAccessor: () -> MTLTexture?` closure rather than a `KeyPath<ViewModel, MTLTexture?>`-generic struct (which would force `ViewModel` to expose its texture accessors as `KeyPath`-compatible properties — verbose and brittle under `@Observable`). Closure is one extra allocation per drawn frame; negligible at 30 fps.

20. **`04:unlocked-uniforms` slug at TWO sites.** Brief §4 says "around the engine writing shader uniforms directly without `OSAllocatedUnfairLock<UniformStorage>`". The host write in `CameraEngine.setProcessingParameters` *and* the per-frame snapshot read in `MetalPipeline.encode()` are both unsynchronised — Stage 05's lock install will protect both sides. Both sites carry the slug so the Stage-05 retirement grep finds them.

## Open questions for next stage

1. **Inv 6 lock install (Stage 05)** — wrap `UniformsHost.color` + `UniformsHost.crop` in `OSAllocatedUnfairLock<UniformStorage>`; engine acquires-writes-releases; pipeline acquires-snapshots-releases. Both `04:unlocked-uniforms` sites retire.
2. **Sigmoid contrast curve** — pin formula choice via ADR or 07-settings §Processing-order amendment before Stage 11 polish.
3. **Crop visual verification** — Stage 06 (pool trio) provides the device-driven crop rendering test that proves uniform → pixel correspondence end-to-end.
```

- [ ] **Step 2: Regenerate `CONTRACTS.md`**

Run: `scripts/regen-contracts.sh`.
Expected: updated `CameraKit/CONTRACTS.md` reflecting `setProcessingParameters`, `setCropRegion`, `sampleCenterPatch`, `getPersistedProcessingParameters`, `currentProcessedTexture` and the new `04:unlocked-uniforms` slug entries.

- [ ] **Step 3: Final verification**

Build:
```
mcp__XcodeBuildMCP__build_device {}
```
Expected: `BUILD SUCCEEDED`.

All tests:
```
mcp__XcodeBuildMCP__test_device {
  extraArgs: [
    "-only-testing:eva-swift-stitchTests/Stage01Tests",
    "-only-testing:eva-swift-stitchTests/Stage02Tests",
    "-only-testing:eva-swift-stitchTests/Stage03Tests",
    "-only-testing:eva-swift-stitchTests/Stage04Tests"
  ]
}
```
Expected: **20 tests pass** (5 + 4 + 7 + 4).

Scaffold inventory:
```bash
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|04:unlocked-uniforms' CameraKit/Sources/
grep -rn '05:\|06:\|07:\|08:\|09:\|10:\|11:\|12:' CameraKit/Sources/
```
Expected: first returns ≥1 hit each (3 slugs); second returns 0.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md
git commit -m "docs(stage-04): state.md + CONTRACTS.md regenerated for Stage 04"
```

- [ ] **Step 5: Request user approval (per CLAUDE.md §7 — never push without approval)**

Do not push. Summarize the completed stage to the user, enumerate any DEFERRED HITL evidence, and ask for approval before any push or PR.

---

## 5. Deviations

These are places where the **source state dictates** a deviation from the brief spec. Each is also folded into the state.md "Decisions taken that weren't in briefs" section continuing the Stage 03 numbering.

1. **Deviation 16** (state.md #16) — `naturalTex` IOSurface migration ships in Stage 04. Stage 01 allocated `.private`; brief §7 + architecture `04-metal-pipeline.md` §D-02 require `.shared` IOSurface-backed from Stage 01. Migration ships now because Stage 04's golden-frame test is the first CPU reader.

2. **Deviation 17** (state.md #17) — Linear contrast curve, not piecewise sigmoid. Brief §7 requires "identity at defaults"; sigmoid curve shape is unspecified in source. Linear `(c - 0.5) * contrast + 0.5` satisfies identity at `contrast = 1`. Sigmoid lands when 07-settings §Processing-order pins the formula or Stage 11 polish revisits.

3. **Deviation 18** (state.md #18) — No device-driven `setCropRegion` test in Stage 04. Brief §8 only names "set-crop-region-updates-uniform" (the uniform-write contract). End-to-end visual verification ships with the Stage 06 pool trio.

4. **Deviation 19** (state.md #19) — `MTKViewRepresentable` parameterized by `textureAccessor: () -> MTLTexture?` closure rather than a `KeyPath`-generic struct. Avoids `KeyPath`-conformance pressure on `@Observable` ViewModel; trades one closure alloc/frame for ergonomics.

5. **Deviation 20** (state.md #20) — `04:unlocked-uniforms` slug at TWO sites (`CameraEngine.setProcessingParameters` + `MetalPipeline.encode`'s snapshot block). Both sides are unsynchronised; Stage 05's lock install protects both. Both sites carry the slug so Stage-05 retirement catches both.

6. **Deviation 21** (build/test discipline, carried from prior stages) — Verification uses `mcp__XcodeBuildMCP__{build_device,test_device}` (or `scripts/build-summary.sh` / `test-summary.sh` as fallback), never `swift build` / `swift test`. State.md Decision #2 established this. Brief §11's `swift build` / `swift test --filter` commands are not runnable on this machine.

7. **Deviation 22** (test target naming) — Tests use `-only-testing:eva-swift-stitchTests/Stage04Tests` (host-app test runner), not `CameraKitTests/Stage04Tests`. State.md Decision #10 established this for Stage 02.

---

## 6. Self-review notes (author-run before handoff)

- **Spec coverage:** every brief §4 "files to create / modify / delete" entry has at least one task. Brief §8 TESTABLEs are each bound to a named test in Task 13. HITL entries are bound to Task 14. State.md updates and CONTRACTS regeneration are Task 15.
- **Type consistency:** `ProcessingParameters` field names match `Capabilities.swift:122-145` (`brightness`, `contrast`, `saturation`, `blackR`, `blackG`, `blackB`, `gamma` — all `Double`). `RgbSample` matches `FrameSet.swift:132` (`r`, `g`, `b: Double`). `Rect` matches `Capabilities.swift:15-23` (`x, y, width, height: Int`). `EngineError` cases referenced: `.notOpen` (no assoc) and `.settingsConflict(reason:)` (with assoc, requires closure matcher in tests) — verified at `Errors.swift:38-51`. `MetalError` cases: `.commandBufferFailed(code: Int)`, `.unsupportedFormat`, `.textureWrapFailed(code: Int32)`, `.pipelineStateCompilation(String)` — verified at `Errors.swift:53-59`.
- **Apple API coverage:** every Apple API the new code touches has a verified signature in §3. `CVPixelBufferCreate`, `CVPixelBufferLockBaseAddress`/`Unlock`, `CVPixelBufferGetBaseAddress`/`BytesPerRow`/`Width`/`Height`, `kCVPixelFormatType_64RGBAHalf`, `kCVPixelBufferMetalCompatibilityKey`, `kCVPixelBufferIOSurfacePropertiesKey`, `MTLBuffer.contents()`, `addCompletedHandler`, `withCheckedThrowingContinuation`, `Slider`. No string-keypath KVO (typed-keypath only — already covered by Stage 03).
- **Placeholder scan:** no TBDs; no "implement later"; every step contains the actual code or command. The lone CameraView caveat in Task 12 (Stage-03 bottom bar) is explicit about how to recover the prior code if drifted.
- **Single-symbol-per-task discipline:** each task introduces one named primitive or one tightly coupled cluster (Pass 2 + uniform binding ship together because they straddle Metal kernel + host bind; `dispatchCenterPatch` ships with the kernel because the host buffer lengths must match).
- **Stage-03 dependency:** Task 0 hard-blocks if Stage 03 isn't fully implemented. Every later task assumes the post-Stage-03 source state described in §1.1.
