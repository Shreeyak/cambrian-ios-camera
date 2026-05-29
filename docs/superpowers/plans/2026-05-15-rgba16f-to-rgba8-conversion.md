# RGBA16F → RGBA8 Lane-Conversion Stage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a default-on session flag (`OpenConfiguration.lanesEightBit`) that
makes `CameraEngine.currentPixelBuffer(stream:)` return BGRA8
(`kCVPixelFormatType_32BGRA`) buffers instead of the internal RGBA16F, while
keeping every internal Metal path (Pass-1/2/4/5/6, calibration, MTKView preview)
end-to-end RGBA16F.

**Architecture:** Option B from the design — a per-lane "bridge tap" Pass-7
compute kernel (`rgba16fToBgra8`) appended to the per-frame command buffer for
natural + processed (NOT tracker) when the flag is on. New 8-bit IOSurface pools
lazily allocated when flag-on. The buffer mailboxes
(`_latestNaturalBuffer` / `_latestProcessedBuffer`) re-route to the converted
buffers; texture mailboxes and the FrameSet (consumers.yield) keep storing
RGBA16F. The asymmetry is load-bearing: textures are for in-process Metal
consumers (precision); buffers are for the Phase-3 bridge handoff (format
parity). Wire format is BGRA8 (Apple's `CVMetalTextureCache`-canonical pair
with `.bgra8Unorm`); Android adapts at its end (D-2P-09).

**Tech Stack:** Swift 6.2 (strict concurrency), Metal compute shaders,
CoreVideo (`CVMetalTextureCache`, `CVPixelBufferPool`, IOSurface), swift-testing.

## Open questions — resolved inline

1. **Wire format.** RESOLVED upstream (D-2P-09, 2026-05-15) — **BGRA8**
   (`kCVPixelFormatType_32BGRA`, `MTLPixelFormat.bgra8Unorm`).
2. **Harness default.** **Default-on, no opt-out.** The harness's only
   `currentPixelBuffer` consumer is the Phase-2 bridge-readiness test
   (asserts nil-before-first-frame — format-agnostic). CannyConsumer reads
   `frameSet.tracker` from the unchanged FrameSet construction (`MetalPipeline`
   line 506: `trackerForSet: CVPixelBuffer = trackerBuf ?? naturalBuf`),
   independent of the buffer mailbox. MTKView preview reads `currentTexture()`
   (texture mailbox, unaffected). Default-on means HITL exercises the new
   path — the right tradeoff. The future iOS-only Swift/C++ stitching app can
   opt out when it lands.
3. **Conversion placement.** **Option B** (separate per-lane bridge tap, RGBA16F
   end-to-end internally). No near-term internal consumer wants 8-bit.
4. **Tracker lane converts?** **No.** Tracker has no Phase-3 Pigeon
   counterpart (`currentTrackerTexture()` is harness-only per
   `2026-05-14-camerakit-flutter-migration-design.md` §2e). Saves one Metal
   pass/frame; avoids touching `CannyConsumer.cpp`. Locked in by a test that
   asserts `currentPixelBuffer(stream: .tracker)` keeps `_64RGBAHalf` even
   with flag-on.
5. **`SessionCapabilities.streamPixelFormat` shape.** **Single string field
   kept.** Doc-comment updated to read: "active *buffer* format reported here;
   texture accessors are always RGBA16F." YAGNI on splitting — Phase-3 only
   cares about the buffer side.
6. **Test naming.** **Per-feature, no stage prefix** — file named
   `RgbaConversionTests.swift`. Matches the most recent precedent
   (`CaptureNaturalPictureTests`, `MailboxTests`, `SessionStateMachineTests`)
   for discrete pre-Phase-3 efforts.

## Behavior summary

| | Flag ON (default) | Flag OFF |
|---|---|---|
| `currentPixelBuffer(stream: .natural)` | BGRA8 buffer (Pass-7 output) | RGBA16F (today) |
| `currentPixelBuffer(stream: .processed)` | BGRA8 buffer (Pass-7 output) | RGBA16F (today) |
| `currentPixelBuffer(stream: .tracker)` | RGBA16F (no Pass-7 on tracker) | RGBA16F |
| `currentTexture()` / `currentProcessedTexture()` / `currentTrackerTexture()` | RGBA16F always | RGBA16F always |
| `SessionCapabilities.streamPixelFormat` | `"BGRA8"` | `"RGBA16F"` |
| FrameSet on `consumers.yield`/AsyncStream/C++ pool | RGBA16F (today) | RGBA16F |
| Still capture (Pass-6 + StillCapture.swift readback) | RGBA16F (today) | RGBA16F |
| Calibration sampling | RGBA16F (today) | RGBA16F |
| Pass-5 NV12 encode | reads RGBA16F (today) | RGBA16F |

## File structure

**New files (2):**
- `CameraKit/Sources/CameraKit/Shaders/Rgba16fToBgra8.metal` — Pass-7 compute kernel.
- `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift` — new test suites
  (multiple `@Suite` structs in one file per repo convention).

**Modified files (7):**
- `CameraKit/Sources/CameraKit/Constants.swift` — BGRA8 OSType + MTLPixelFormat constants.
- `CameraKit/Sources/CameraKit/Capabilities.swift` — `OpenConfiguration.lanesEightBit` field; `streamPixelFormat` doc-comment.
- `CameraKit/Sources/CameraKit/TexturePoolManager.swift` — `makeBgra8LanePool` factory; `dequeueEightBitPoolTexture` helper.
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` — flag stored; lazy 8-bit pools; Pass-7 PSO; per-frame Pass-7 dispatch on natural + processed only; mailbox rewire; convenience-init flag param default `false`.
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — flag plumbed into `MetalPipeline`; `streamPixelFormat` literal becomes computed; doc-comments on the four accessors updated.
- `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift` — existing `laneFormatIsRGBA16F` test renamed + body updated (split into default-on / flag-off cases).
- `CameraKit/state.md` — new pre-Phase-3 section recording what landed.

**Auxiliary (not via Edit/Write — produced by tooling):**
- `CameraKit/CONTRACTS.md` regenerated by pre-commit hook (or manual `scripts/regen-contracts.sh`).
- `CameraKit/DECISIONS.md` — append-only one-liner at the end of implementation (see Task 11).
- `docs/measurements/phase-3-prep/rgba8-conversion.md` — HITL evidence file (Task 10).

**Not changed:**
- All other shaders (`YUVToRGBA.metal`, `ColorShaders.metal`, `NV12Encode.metal`, `TrackerDownsample.metal`, `CenterPatchKernel.metal`).
- `StillCapture.swift`, `CalibrationCompute.swift`.
- `eva-swift-stitch/UI/CameraView.swift`, `eva-swift-stitch/UI/DisplayViewModel.swift`, `eva-swift-stitch/UI/ViewModel.swift` (harness uses default — no `lanesEightBit` override).
- `eva-swift-stitch/AppCxx/CannyConsumer.cpp` (tracker doesn't convert).
- `eva-swift-stitch/eva_swift_stitchApp.swift`.

## Verification path

- **Build:** `mcp__XcodeBuildMCP__build_run_device` (primary); fallback `scripts/build-summary.sh`.
- **Tests:** `mcp__XcodeBuildMCP__test_device` filtered to the new suite structs (or `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStructName>`).
- **Full regression:** Run all tests once before HITL to catch any unintended fallout.
- **swift-format + swiftlint:** Pre-commit hook (do not skip; runs `--strict`).
- **HITL on iPad:** 30 fps sustained at 4K with conversion on; still-capture HDR fidelity unchanged. Evidence path: `docs/measurements/phase-3-prep/rgba8-conversion.md`.

---

## Task 1: Add BGRA8 pixel-format constants

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Constants.swift`
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift` (new file)

- [ ] **Step 1: Create the test file with a failing constants assertion**

Create `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`:

```swift
import CoreVideo
import Metal
import Testing

@testable import CameraKit

// MARK: - Constants

@Suite("RGBA8 conversion — pixel-format constants")
struct RgbaConversionConstantsTests {

    @Test("eightBitLanePixelFormat is kCVPixelFormatType_32BGRA")
    func eightBitLanePixelFormatIsBGRA() {
        #expect(Constants.eightBitLanePixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test("eightBitLaneMetalFormat is .bgra8Unorm")
    func eightBitLaneMetalFormatIsBgra8Unorm() {
        #expect(Constants.eightBitLaneMetalFormat == MTLPixelFormat.bgra8Unorm)
    }

    @Test("streamPixelFormatStringEightBit is the literal \"BGRA8\"")
    func streamPixelFormatStringEightBitMatches() {
        #expect(Constants.streamPixelFormatStringEightBit == "BGRA8")
    }

    @Test("streamPixelFormatStringSixteenBit is the literal \"RGBA16F\"")
    func streamPixelFormatStringSixteenBitMatches() {
        #expect(Constants.streamPixelFormatStringSixteenBit == "RGBA16F")
    }
}
```

- [ ] **Step 2: Wire the new test file into the Xcode test target**

```bash
scripts/sync-test-target.sh
```

Expected: idempotent; adds `RgbaConversionTests.swift` to the `eva-swift-stitchTests` target.

- [ ] **Step 3: Run the new tests to verify they fail with "Cannot find Constants.eightBitLanePixelFormat in scope"**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionConstantsTests
```

Expected: BUILD FAILED with the four missing-member errors.

- [ ] **Step 4: Add the constants**

Edit `CameraKit/Sources/CameraKit/Constants.swift`. Add a new MARK section before the closing brace of `enum Constants`:

```swift
    // MARK: - Pre-Phase-3 — RGBA8 lane conversion

    /// Wire pixel format emitted on `currentPixelBuffer(stream:)` when
    /// `OpenConfiguration.lanesEightBit` is true (default).
    ///
    /// BGRA8 is Apple's `CVMetalTextureCache`-canonical 32-bit RGBA-family
    /// format on iOS — wraps zero-copy as `.bgra8Unorm`. Android adapts at
    /// its end (D-2P-09). See `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    static let eightBitLanePixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// `MTLPixelFormat` paired with `eightBitLanePixelFormat` for
    /// `CVMetalTextureCache` wraps and Pass-7 kernel output.
    static let eightBitLaneMetalFormat: MTLPixelFormat = .bgra8Unorm

    /// String reported on `SessionCapabilities.streamPixelFormat` when
    /// `lanesEightBit` is true.
    static let streamPixelFormatStringEightBit: String = "BGRA8"

    /// String reported on `SessionCapabilities.streamPixelFormat` when
    /// `lanesEightBit` is false.
    static let streamPixelFormatStringSixteenBit: String = "RGBA16F"
```

- [ ] **Step 5: Run the new tests; expect all 4 to PASS**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionConstantsTests
```

Expected: 4 pass / 0 fail.

---

## Task 2: Add `OpenConfiguration.lanesEightBit` field

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift:91-116`
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Add failing tests for `OpenConfiguration.lanesEightBit`**

Append to `RgbaConversionTests.swift`:

```swift
// MARK: - OpenConfiguration

@Suite("RGBA8 conversion — OpenConfiguration")
struct RgbaConversionOpenConfigurationTests {

    @Test("lanesEightBit defaults to true")
    func lanesEightBitDefaultsToTrue() {
        let cfg = OpenConfiguration()
        #expect(cfg.lanesEightBit == true)
    }

    @Test("Legacy three-arg init still compiles; lanesEightBit defaults to true")
    func legacyThreeArgInitDefaultsLanesEightBitTrue() {
        let legacy = OpenConfiguration(
            cameraId: "back",
            captureResolution: Size(width: 1920, height: 1080),
            cropRegion: nil)
        #expect(legacy.lanesEightBit == true)
        #expect(legacy.cameraId == "back")
    }

    @Test("Legacy four-arg init with initialSettings still compiles")
    func legacyFourArgInitWithInitialSettingsCompiles() {
        var s = CameraSettings()
        s.iso = 400
        let legacy = OpenConfiguration(
            cameraId: "back",
            captureResolution: nil,
            cropRegion: nil,
            initialSettings: s)
        #expect(legacy.initialSettings?.iso == 400)
        #expect(legacy.lanesEightBit == true)
    }

    @Test("lanesEightBit can be opted out to false")
    func lanesEightBitOptOutFalse() {
        let cfg = OpenConfiguration(lanesEightBit: false)
        #expect(cfg.lanesEightBit == false)
    }
}
```

- [ ] **Step 2: Run the new tests; expect 4 failures with "Cannot find lanesEightBit in scope" / "Extra argument 'lanesEightBit' in call"**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionOpenConfigurationTests
```

Expected: BUILD FAILED.

- [ ] **Step 3: Add the `lanesEightBit` field to `OpenConfiguration`**

Edit `CameraKit/Sources/CameraKit/Capabilities.swift`. Replace the `OpenConfiguration` struct (lines 91–116):

```swift
/// Startup arguments for CameraEngine.open(configuration:).
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?
    /// Hardware settings to apply during session setup, before the first frame
    /// is delivered.
    ///
    /// Folds the Pigeon contract's `open(cameraId, settings)` shape into
    /// CameraKit's structural `OpenConfiguration` so the requested settings are
    /// live from frame one (no defaults-then-snap flicker). Phase-2 design
    /// §2a. Applied via the same `updateSettings` merge+coupling+commit path
    /// after `setupSession` returns and before the first `startRunning`.
    public var initialSettings: CameraSettings?
    /// When true, `currentPixelBuffer(stream: .natural)` and
    /// `currentPixelBuffer(stream: .processed)` return BGRA8 buffers
    /// (`kCVPixelFormatType_32BGRA`, `MTLPixelFormat.bgra8Unorm`) — Apple's
    /// `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS.
    ///
    /// When false, those accessors return the internal RGBA16F lane buffers
    /// (`kCVPixelFormatType_64RGBAHalf`). Tracker is RGBA16F either way.
    ///
    /// Default true → matches the Flutter plugin's expected wire format on
    /// the Phase-3 zero-copy bridge. Internal pipeline (Pass-1/2/4/5/6,
    /// calibration sampling, MTKView preview, still capture) stays RGBA16F
    /// regardless. Texture accessors (`currentTexture()` /
    /// `currentProcessedTexture()` / `currentTrackerTexture()`) always return
    /// `.rgba16Float`. See
    /// `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    public var lanesEightBit: Bool

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        cropRegion: Rect? = nil,
        initialSettings: CameraSettings? = nil,
        lanesEightBit: Bool = true
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.cropRegion = cropRegion
        self.initialSettings = initialSettings
        self.lanesEightBit = lanesEightBit
    }
}
```

- [ ] **Step 4: Run the new tests + the Phase-2 OpenConfiguration regression**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionOpenConfigurationTests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage13Phase2OpenConfigurationTests
```

Expected: All pass. The Stage13Phase2 legacy-init test still compiles because the new field has a default value.

---

## Task 3: Add `makeBgra8LanePool` factory and `dequeueEightBitPoolTexture` helper

**Files:**
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Add failing tests for the new factory + dequeue**

Append to `RgbaConversionTests.swift`:

```swift
// MARK: - TexturePoolManager — BGRA8 factory

@Suite("RGBA8 conversion — BGRA8 pool factory")
struct RgbaConversionPoolFactoryTests {

    @Test("makeBgra8LanePool vends BGRA8 IOSurface-backed buffers")
    func makeBgra8LanePoolVendsBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        var bufOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &bufOut)
        #expect(status == kCVReturnSuccess)
        guard let buf = bufOut else {
            Issue.record("no buffer")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(buf) == 256)
        #expect(CVPixelBufferGetHeight(buf) == 256)
        // IOSurface-backed.
        #expect(CVPixelBufferGetIOSurface(buf) != nil)
    }

    @Test("dequeueEightBitPoolTexture wraps as MTLPixelFormat.bgra8Unorm")
    func dequeueEightBitPoolTextureWrapsAsBgra8Unorm() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        let pair = try tpm.dequeueEightBitPoolTexture(
            pool: pool, width: 256, height: 256)
        #expect(pair.texture.pixelFormat == .bgra8Unorm)
        #expect(pair.texture.width == 256)
        #expect(pair.texture.height == 256)
        #expect(
            CVPixelBufferGetPixelFormatType(pair.buffer) == kCVPixelFormatType_32BGRA)
    }
}
```

- [ ] **Step 2: Run the new tests; expect failures with "Cannot find member makeBgra8LanePool / dequeueEightBitPoolTexture"**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionPoolFactoryTests
```

Expected: BUILD FAILED.

- [ ] **Step 3: Add the factory and dequeue helper**

Edit `CameraKit/Sources/CameraKit/TexturePoolManager.swift`. After the `makeWorkingFormatPool` function (line 164), add:

```swift
    /// Creates a `CVPixelBufferPool` that vends IOSurface-backed, Metal-compatible
    /// **BGRA8** `CVPixelBuffer`s for the pre-Phase-3 RGBA8 conversion path.
    ///
    /// Parallel to `makeWorkingFormatPool` but emits
    /// `kCVPixelFormatType_32BGRA` instead of `_64RGBAHalf`. Same pool
    /// attributes (`POOL_MIN_BUFFER_COUNT`, `POOL_MAX_BUFFER_AGE_SECONDS`,
    /// IOSurface + Metal compatibility). Used only when
    /// `OpenConfiguration.lanesEightBit == true`.
    func makeBgra8LanePool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: Constants.poolMaxBufferAgeSeconds,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Constants.eightBitLanePixelFormat,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw MetalError.unsupportedFormat
        }
        return pool
    }

    /// Dequeues a BGRA8 buffer and wraps it as a writeable
    /// `MTLPixelFormat.bgra8Unorm` texture through the shared
    /// `CVMetalTextureCache`.
    ///
    /// Parallel to `dequeuePoolTexture` but pairs the 8-bit pool with a
    /// `.bgra8Unorm` texture view. Pass-7 kernel writes through this view.
    /// Zero-copy; the caller retains `buffer` until the GPU completion
    /// handler fires (Apple CoreVideo contract).
    func dequeueEightBitPoolTexture(
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let buffer = buf else {
            throw MetalError.unsupportedFormat
        }
        var cvTexOut: CVMetalTexture?
        let wrap = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            buffer,
            nil,
            Constants.eightBitLaneMetalFormat,
            width,
            height,
            0,
            &cvTexOut
        )
        guard wrap == kCVReturnSuccess, let cvTex = cvTexOut,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrap)
        }
        return (buffer, mtlTex)
    }
```

- [ ] **Step 4: Run the new tests**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionPoolFactoryTests
```

Expected: 2 pass / 0 fail.

---

## Task 4: Write the Pass-7 conversion compute kernel

**Files:**
- Create: `CameraKit/Sources/CameraKit/Shaders/Rgba16fToBgra8.metal`
- Test: deferred to Task 6 end-to-end pipeline test (kernel correctness covered by per-pixel parity in HITL §Step 10.4 and by the mailbox-format test in Task 7).

- [ ] **Step 1: Create the new shader file**

Create `CameraKit/Sources/CameraKit/Shaders/Rgba16fToBgra8.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// Pre-Phase-3 Pass-7 — convert a half-float RGBA texture to an 8-bit BGRA
// IOSurface view. Metal's BGRA8Unorm format handles the byte-order swizzle on
// write; the kernel writes `float4(R, G, B, A)` in source channel order and
// the GPU stores it as B, G, R, A bytes. Clamp to [0, 1] so half-floats above
// nominal range don't wrap into a low 8-bit value.
//
// One dispatch per lane (natural + processed) when
// `OpenConfiguration.lanesEightBit` is true. Tracker lane is not converted.
//
// Reference: docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md.

kernel void rgba16fToBgra8(
    texture2d<float, access::read>   inRGBA  [[texture(0)]],
    texture2d<float, access::write>  outBGRA [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outBGRA.get_width() || gid.y >= outBGRA.get_height()) {
        return;
    }
    float4 c = inRGBA.read(gid);
    c = clamp(c, 0.0, 1.0);
    outBGRA.write(c, gid);
}
```

- [ ] **Step 2: Confirm the shader is discoverable**

Drive a temporary unit test (will be removed by Task 6's test). Append to `RgbaConversionTests.swift`:

```swift
// MARK: - Kernel discoverability (temporary; replaced by Task 6 mailbox test)

@Suite("RGBA8 conversion — kernel discoverability")
struct RgbaConversionKernelDiscoveryTests {

    @Test("rgba16fToBgra8 is discoverable in the SwiftPM Metal library")
    func kernelIsDiscoverable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let library = try device.makeDefaultLibrary(bundle: .module)
        #expect(library.makeFunction(name: "rgba16fToBgra8") != nil)
    }
}
```

- [ ] **Step 3: Run the discovery test**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionKernelDiscoveryTests
```

Expected: 1 pass / 0 fail. (The Metal shader is auto-included by SwiftPM at
build time — no Package.swift edit required for shader files because they
already resolve through the default resource process.)

---

## Task 5: `MetalPipeline` accepts the flag and lazily allocates pools + PSO

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Add a failing test that asserts the flag flows through MetalPipeline**

Append to `RgbaConversionTests.swift`:

```swift
// MARK: - MetalPipeline flag plumbing

@Suite("RGBA8 conversion — MetalPipeline flag plumbing")
struct RgbaConversionPipelineFlagTests {

    @Test("Pipeline with lanesEightBit=true allocates 8-bit pools")
    func pipelineFlagOnAllocatesEightBitPools() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 256),
            gateOpen: true,
            lanesEightBit: true)
        #expect(pipeline.eightBitNaturalPoolForTest != nil)
        #expect(pipeline.eightBitProcessedPoolForTest != nil)
        // Tracker is not converted.
        #expect(pipeline.eightBitTrackerPoolForTest == nil)
    }

    @Test("Pipeline with lanesEightBit=false skips 8-bit pool allocation")
    func pipelineFlagOffSkipsEightBitPools() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 256),
            gateOpen: true,
            lanesEightBit: false)
        #expect(pipeline.eightBitNaturalPoolForTest == nil)
        #expect(pipeline.eightBitProcessedPoolForTest == nil)
        #expect(pipeline.eightBitTrackerPoolForTest == nil)
    }
}
```

- [ ] **Step 2: Run the new tests; expect failures on missing init parameter + missing test seams**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionPipelineFlagTests
```

Expected: BUILD FAILED.

- [ ] **Step 3: Add flag + lazy storage in MetalPipeline**

Edit `CameraKit/Sources/CameraKit/MetalPipeline.swift`. After the
`private let trackerPool: CVPixelBufferPool` declaration (line 76), add:

```swift
    // Pre-Phase-3 — RGBA8 lane conversion (default-on session flag).
    //
    // When `lanesEightBit` is true, Pass-7 dispatches per-frame for natural +
    // processed (NOT tracker) and writes into these IOSurface-backed BGRA8
    // pools. The buffer mailboxes (`_latestNaturalBuffer` /
    // `_latestProcessedBuffer`) point at the converted buffer, so
    // `CameraEngine.currentPixelBuffer(stream:)` returns BGRA8 for the
    // Phase-3 bridge. See docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md.
    private let lanesEightBit: Bool
    private let eightBitNaturalPool: CVPixelBufferPool?
    private let eightBitProcessedPool: CVPixelBufferPool?
    private let rgba16fToBgra8PSO: MTLComputePipelineState?
```

Edit the designated init signature (line 214–220) — add `lanesEightBit`:

```swift
    init(
        device: MTLDevice,
        captureSize: Size,
        gate: ManagedAtomic<Bool>,
        consumers: ConsumerRegistry,
        engineSessionToken: ManagedAtomic<UInt64>,
        lanesEightBit: Bool
    ) throws {
```

Inside the init, after the existing pool allocations at line 303 (after
`trackerPool = try texturePool.makeWorkingFormatPool(size: trackerSize)`),
store the flag and conditionally allocate 8-bit pools + PSO. Add:

```swift
        // Pre-Phase-3 RGBA8 conversion — flag stored; pools + PSO lazy when on.
        self.lanesEightBit = lanesEightBit
        if lanesEightBit {
            self.eightBitNaturalPool = try texturePool.makeBgra8LanePool(size: captureSize)
            self.eightBitProcessedPool = try texturePool.makeBgra8LanePool(size: captureSize)
            guard let fnConvert = library.makeFunction(name: "rgba16fToBgra8") else {
                throw MetalError.pipelineStateCompilation("rgba16fToBgra8 missing")
            }
            self.rgba16fToBgra8PSO = try device.makeComputePipelineState(function: fnConvert)
        } else {
            self.eightBitNaturalPool = nil
            self.eightBitProcessedPool = nil
            self.rgba16fToBgra8PSO = nil
        }
```

Update the convenience inits (line 855 + line 868). For each, add a `lanesEightBit` parameter with default `false` and forward it:

```swift
    /// Convenience init that creates its own gate and an empty ConsumerRegistry.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to import Atomics.
    /// `lanesEightBit` defaults to `false` so existing pool-count assertions stay valid.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        gateOpen: Bool = true,
        lanesEightBit: Bool = false
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: ConsumerRegistry(),
            engineSessionToken: ManagedAtomic<UInt64>(0),
            lanesEightBit: lanesEightBit
        )
    }

    /// Convenience init that accepts an explicit ConsumerRegistry but hides ManagedAtomic.
    ///
    /// Used by Stage06Tests so tests can inject a specific registry without importing Atomics.
    /// `lanesEightBit` defaults to `false` so existing pool-count assertions stay valid.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        gateOpen: Bool = true,
        consumers: ConsumerRegistry,
        lanesEightBit: Bool = false
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: consumers,
            engineSessionToken: ManagedAtomic<UInt64>(0),
            lanesEightBit: lanesEightBit
        )
    }
```

Add new test seams. Near the end of `MetalPipeline` (after the existing
`naturalPoolForTest` block around line 898), add:

```swift
    // Pre-Phase-3 — RGBA8 conversion test seams.
    var eightBitNaturalPoolForTest: CVPixelBufferPool? { eightBitNaturalPool }
    var eightBitProcessedPoolForTest: CVPixelBufferPool? { eightBitProcessedPool }
    /// Always nil; tracker lane is not converted (Plan §OQ #4).
    var eightBitTrackerPoolForTest: CVPixelBufferPool? { nil }
    var lanesEightBitForTest: Bool { lanesEightBit }
```

- [ ] **Step 4: Update `CameraEngine` to pass the flag through**

Edit `CameraKit/Sources/CameraKit/CameraEngine.swift`. Change the
`MetalPipeline(...)` call (line 212–218):

```swift
        let pipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: captureSize,
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken,
            lanesEightBit: configuration.lanesEightBit
        )
```

Search for any other `MetalPipeline(` designated-init call sites used in
recovery / setResolution paths:

```bash
grep -n "MetalPipeline(" /Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/rgba8/CameraKit/Sources/CameraKit/*.swift
```

For any production call to the **designated init** (one with `gate:` and
`engineSessionToken:`), thread `lanesEightBit:` through. For
`setResolution` (if present), pass the value previously recorded on the
engine actor for the active session — capture it once at open. Add a
private property on `CameraEngine`:

```swift
    /// Cached for setResolution re-init — preserves the session's
    /// lanesEightBit value across pipeline rebuilds (Pre-Phase-3 RGBA8).
    private var lanesEightBitCurrent: Bool = true
```

Set it from `open(configuration:)` right after the pipeline is constructed:

```swift
        self.lanesEightBitCurrent = configuration.lanesEightBit
```

And in any `setResolution`-style pipeline rebuild path, pass
`lanesEightBit: self.lanesEightBitCurrent`.

- [ ] **Step 5: Run the pipeline-flag tests + the full pre-existing pipeline suite**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionPipelineFlagTests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage02Tests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage06Tests
```

Expected: All pass. Pre-existing tests rely on the convenience-init default
of `lanesEightBit: false`, so no pool-count assertions break.

---

## Task 6: Dispatch Pass-7 per frame; rewire buffer mailboxes

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift` (inside `encode(sampleBuffer:)`)
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Replace the kernel-discovery temporary test with the real mailbox-format test**

Open `RgbaConversionTests.swift`. **Remove** the `RgbaConversionKernelDiscoveryTests` suite from Task 4 Step 2 — it's superseded.

Append the real end-to-end test suite. This test drives one frame through
the pipeline using the existing Stage 06 test seam pattern (synthesised
NV12 buffer + `encode(sampleBuffer:)`). The cleanest existing pattern is
`Stage06Tests` — use the test helpers there. Add:

```swift
// MARK: - End-to-end mailbox format (device-only)

@Suite("RGBA8 conversion — mailbox format end-to-end")
struct RgbaConversionMailboxFormatTests {

    @Test("Flag-on: latest*Buffer is BGRA8 for natural and processed; RGBA16F for tracker")
    func flagOnNaturalProcessedAreBgra8TrackerStaysRgba16f() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        // Subscribe to .tracker so Pass-4 runs and the tracker buffer is published.
        let trackerStream = await consumers.subscribe(stream: .tracker)
        var iter = trackerStream.makeAsyncIterator()

        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers,
            lanesEightBit: true)

        // Drive one synthesised frame; helper lives in TestPixelHelpers.
        let sample = try TestPixelHelpers.makeSyntheticNV12SampleBuffer(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)

        // Wait until the AsyncStream surfaces the first tracker frame —
        // confirms the completion handler ran and wrote both mailboxes.
        _ = await iter.next()

        guard let natural = pipeline.latestNaturalBufferForTest,
              let processed = pipeline.latestProcessedBufferForTest,
              let tracker = pipeline.latestTrackerBufferForTest
        else {
            Issue.record("mailboxes not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(natural) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(processed) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(tracker) == kCVPixelFormatType_64RGBAHalf)
    }

    @Test("Flag-off: latest*Buffer is RGBA16F for every lane")
    func flagOffEveryLaneStaysRgba16f() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let trackerStream = await consumers.subscribe(stream: .tracker)
        var iter = trackerStream.makeAsyncIterator()

        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers,
            lanesEightBit: false)

        let sample = try TestPixelHelpers.makeSyntheticNV12SampleBuffer(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        _ = await iter.next()

        guard let natural = pipeline.latestNaturalBufferForTest,
              let processed = pipeline.latestProcessedBufferForTest,
              let tracker = pipeline.latestTrackerBufferForTest
        else {
            Issue.record("mailboxes not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(natural) == kCVPixelFormatType_64RGBAHalf)
        #expect(CVPixelBufferGetPixelFormatType(processed) == kCVPixelFormatType_64RGBAHalf)
        #expect(CVPixelBufferGetPixelFormatType(tracker) == kCVPixelFormatType_64RGBAHalf)
    }

    @Test("Texture mailboxes always return .rgba16Float regardless of flag")
    func textureMailboxesAlwaysRgba16Float() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        for flagOn in [true, false] {
            let consumers = ConsumerRegistry()
            let trackerStream = await consumers.subscribe(stream: .tracker)
            var iter = trackerStream.makeAsyncIterator()

            let pipeline = try MetalPipeline(
                device: device,
                captureSize: Size(width: 256, height: 192),
                gateOpen: true,
                consumers: consumers,
                lanesEightBit: flagOn)
            let sample = try TestPixelHelpers.makeSyntheticNV12SampleBuffer(
                width: 256, height: 192)
            try pipeline.encode(sampleBuffer: sample)
            _ = await iter.next()

            #expect(pipeline.latestNaturalTex?.pixelFormat == .rgba16Float)
            #expect(pipeline.latestProcessedTex?.pixelFormat == .rgba16Float)
            #expect(pipeline.latestTrackerTex?.pixelFormat == .rgba16Float)
        }
    }
}
```

Before running, confirm `TestPixelHelpers.makeSyntheticNV12SampleBuffer`
exists; if the helper has a different name in `TestPixelHelpers.swift`,
match its actual signature. If no such helper exists, add a small builder
that produces a CMSampleBuffer wrapping a 256×192 NV12 IOSurface — the
Stage 02 / Stage 04 test files already drive frames through `encode` so
follow whichever helper they call.

- [ ] **Step 2: Run the new tests — expect failure because Pass-7 dispatch + mailbox rewire are not yet added**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionMailboxFormatTests
```

Expected: With `lanesEightBit: true` test FAILS — mailbox still RGBA16F because no Pass-7 dispatch yet. With `lanesEightBit: false` test should already pass.

- [ ] **Step 3: Implement Pass-7 dispatch + mailbox rewire in `encode(sampleBuffer:)`**

Edit `CameraKit/Sources/CameraKit/MetalPipeline.swift`. After the existing
Pass-5 encoder section (line 490) and **before** the gate-check at
line 493, add the Pass-7 dispatches for natural + processed:

```swift
        // Pass 7 (pre-Phase-3): RGBA16F → BGRA8 conversion for the lane-buffer
        // mailboxes when `lanesEightBit` is on. Tracker is not converted
        // (Plan §OQ #4). Runs unconditionally when on — not subscriber-gated
        // in v1, so HITL measures the real cost (Plan §OQ #2). Pass-7 reads
        // the RGBA16F lane texture and writes into a fresh BGRA8 pool buffer's
        // .bgra8Unorm view; the buffer mailbox below points at the new buffer.
        var naturalEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        var processedEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if lanesEightBit,
           let convertPSO = rgba16fToBgra8PSO,
           let natPool = eightBitNaturalPool,
           let procPool = eightBitProcessedPool
        {
            if let pair = try? texturePool.dequeueEightBitPoolTexture(
                pool: natPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass7n = commandBuffer.makeComputeCommandEncoder()!
                pass7n.setComputePipelineState(convertPSO)
                pass7n.setTexture(naturalTexI, index: 0)
                pass7n.setTexture(pair.texture, index: 1)
                pass7n.dispatchThreadgroups(
                    threadGroups, threadsPerThreadgroup: threadGroupSize)
                pass7n.endEncoding()
                naturalEightBitPair = pair
            }
            if let pair = try? texturePool.dequeueEightBitPoolTexture(
                pool: procPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass7p = commandBuffer.makeComputeCommandEncoder()!
                pass7p.setComputePipelineState(convertPSO)
                pass7p.setTexture(processedTexI, index: 0)
                pass7p.setTexture(pair.texture, index: 1)
                pass7p.dispatchThreadgroups(
                    threadGroups, threadsPerThreadgroup: threadGroupSize)
                pass7p.endEncoding()
                processedEightBitPair = pair
            }
        }
```

In the local-variable capture block before the completion handler (after
line 509), add:

```swift
        let naturalEightBitBuf: CVPixelBuffer? = naturalEightBitPair?.buffer
        let processedEightBitBuf: CVPixelBuffer? = processedEightBitPair?.buffer
```

Inside the completion handler (where existing mailbox stores happen — lines
566 and 581), **replace** the existing mailbox writes:

```swift
            self._latestNaturalBuffer.store(naturalBuf)
            self._latestNaturalTex.store(naturalTexI)
```

with:

```swift
            // Pre-Phase-3 — buffer mailbox stores converted BGRA8 buffer when
            // flag is on; texture mailbox always stores RGBA16F.
            self._latestNaturalBuffer.store(naturalEightBitBuf ?? naturalBuf)
            self._latestNaturalTex.store(naturalTexI)
```

And replace:

```swift
            self._latestProcessedBuffer.store(processedBuf)
            self._latestProcessedTex.store(processedTexI)
```

with:

```swift
            self._latestProcessedBuffer.store(processedEightBitBuf ?? processedBuf)
            self._latestProcessedTex.store(processedTexI)
```

The tracker mailbox writes (lines 583–586) are unchanged — tracker is not
converted.

- [ ] **Step 4: Run the new tests + full regression on MetalPipeline test surface**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionMailboxFormatTests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage06Tests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage07Tests
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage10Tests
```

Expected: All pass. Stage 07 / 10 must continue to pass because still
capture (Pass-6) and NV12 encode (Pass-5) read from the unchanged
`processedTexI` texture, not the converted buffer.

---

## Task 7: `CameraEngine.streamPixelFormat` becomes flag-dependent

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:351-359` (the `SessionCapabilities` return)
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift:38-44` (doc-comment)
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Add failing test that `streamPixelFormat` tracks the flag**

Append to `RgbaConversionTests.swift`:

```swift
// MARK: - SessionCapabilities.streamPixelFormat reflects the flag

@Suite("RGBA8 conversion — streamPixelFormat reflects flag")
struct RgbaConversionStreamPixelFormatTests {

    @Test("Capabilities reports 'BGRA8' when lanesEightBit defaults to true (synthetic capability)")
    func capabilityReportsBgra8WhenFlagOn() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringEightBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }

    @Test("Capabilities reports 'RGBA16F' when flag-off string is selected")
    func capabilityReportsRgba16fWhenFlagOff() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringSixteenBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "RGBA16F")
    }
}
```

- [ ] **Step 2: Run; should pass already (Capabilities accepts any string)**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionStreamPixelFormatTests
```

Expected: 2 pass / 0 fail. These pin the constants' shape.

- [ ] **Step 3: Make `CameraEngine.open(...)` produce the right string**

Edit `CameraKit/Sources/CameraKit/CameraEngine.swift`. Replace the literal
`streamPixelFormat: "RGBA16F"` (line 359) with:

```swift
            streamPixelFormat: configuration.lanesEightBit
                ? Constants.streamPixelFormatStringEightBit
                : Constants.streamPixelFormatStringSixteenBit,
```

- [ ] **Step 4: Update the existing Phase-2 PixelFormat regression test**

Edit `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift`. Replace the
`Stage13Phase2PixelFormatTests` suite (lines 38–68) with two tests covering
both flag states:

```swift
// MARK: - §2d.7 — Lane pixel-format regression (updated for pre-Phase-3 RGBA8)

@Suite("Stage 13 Phase 2 — Lane pixel format")
struct Stage13Phase2PixelFormatTests {

    /// Phase-3's zero-copy `FlutterTexture` bridge wraps the lane CVPixelBuffer.
    /// As of pre-Phase-3 RGBA8 conversion, the default-on path emits BGRA8
    /// (`kCVPixelFormatType_32BGRA`) on `currentPixelBuffer(stream:)`; the
    /// flag-off path keeps RGBA16F. Both string values are captured here so
    /// a future format change without updating the constant fails this
    /// regression rather than silently breaking Phase-3.
    @Test("SessionCapabilities reports BGRA8 lane format under default-on flag")
    func defaultLaneFormatIsBgra8() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringEightBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }

    @Test("SessionCapabilities reports RGBA16F when opted out (lanesEightBit=false)")
    func optOutLaneFormatIsRgba16f() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringSixteenBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "RGBA16F")
    }
}
```

- [ ] **Step 5: Update the `streamPixelFormat` doc-comment on `SessionCapabilities`**

Edit `CameraKit/Sources/CameraKit/Capabilities.swift`. Replace the
doc-comment on `streamPixelFormat` (lines 37–44):

```swift
    /// Pixel format string of the *lane buffer* returned by
    /// `currentPixelBuffer(stream:)` — what the Phase-3 zero-copy texture
    /// bridge sees.
    ///
    /// Default (`OpenConfiguration.lanesEightBit == true`): `"BGRA8"`
    /// (`kCVPixelFormatType_32BGRA`, `.bgra8Unorm`) — Apple's
    /// `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS.
    /// Opt-out (`lanesEightBit == false`): `"RGBA16F"`
    /// (`kCVPixelFormatType_64RGBAHalf`, `.rgba16Float`).
    ///
    /// The **texture accessors** — `currentTexture()`,
    /// `currentProcessedTexture()`, `currentTrackerTexture()` — always return
    /// `.rgba16Float` regardless of the flag (Phase-2 §2c + pre-Phase-3 RGBA8
    /// asymmetry). Tracker buffer also stays RGBA16F either way.
    ///
    /// Note this is **not** the camera *source* format (YUV `420f`, converted
    /// by MetalPipeline Pass-1).
```

- [ ] **Step 6: Run the updated test suite**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/Stage13Phase2PixelFormatTests
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionStreamPixelFormatTests
```

Expected: All pass.

---

## Task 8: Update accessor doc-comments to describe the asymmetry

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` — `currentTexture()`, `currentProcessedTexture()`, `currentTrackerTexture()`, `currentPixelBuffer(stream:)`

These are doc-only edits. The texture-accessor asymmetry is load-bearing per
Option B; new readers must see it stated on each accessor without having to
cross-reference the design doc.

- [ ] **Step 1: Update `currentPixelBuffer(stream:)` doc-comment**

Edit `CameraKit/Sources/CameraKit/CameraEngine.swift`. Replace the doc-comment
block on `currentPixelBuffer(stream:)` (lines 755–761):

```swift
    /// Returns the latest IOSurface-backed `CVPixelBuffer` for the requested lane,
    /// or `nil` if no frame has been delivered yet (or post-pause/close).
    ///
    /// `nonisolated` + synchronous — Phase-3's `FlutterTexture.copyPixelBuffer()`
    /// is called on the GPU thread and must not suspend.
    ///
    /// **Format depends on `OpenConfiguration.lanesEightBit`:**
    ///   - default (`true`) — `.natural` / `.processed` return
    ///     `kCVPixelFormatType_32BGRA` (BGRA8, `.bgra8Unorm`). `.tracker`
    ///     stays `kCVPixelFormatType_64RGBAHalf` (RGBA16F).
    ///   - opt-out (`false`) — every lane returns RGBA16F (today's behavior).
    ///
    /// **Asymmetry: this accessor's format can differ from the texture
    /// accessors below.** `currentTexture()` / `currentProcessedTexture()` /
    /// `currentTrackerTexture()` **always** return `.rgba16Float` — internal
    /// in-process Metal consumers (preview MTKView, calibration sampling)
    /// need the precision, while out-of-process Phase-3 bridge consumers want
    /// the 8-bit wire-format parity with Android. Don't refactor this
    /// asymmetry away.
```

- [ ] **Step 2: Update `currentTexture()` doc-comment**

Find the doc-comment on `currentTexture()` (above the `nonisolated public func currentTexture()` declaration in `CameraEngine.swift`). Replace whatever leading lines exist there with:

```swift
    /// Returns the latest natural-lane texture (Pass-1 output) for the MTKView
    /// draw pass.
    ///
    /// Always `.rgba16Float` — the texture path preserves HDR-grade precision
    /// for in-process Metal consumers (calibration sampling, MTKView preview,
    /// the dev harness's `MTKViewRepresentable` configured
    /// `colorPixelFormat = .rgba16Float`). The buffer accessor
    /// `currentPixelBuffer(stream:)` may emit BGRA8 instead, depending on
    /// `OpenConfiguration.lanesEightBit` — see its doc-comment for the
    /// load-bearing texture/buffer asymmetry.
```

- [ ] **Step 3: Update `currentProcessedTexture()` doc-comment**

Replace with:

```swift
    /// Returns the latest processed-lane texture (Pass-2 output, post BCSG +
    /// gamma + BB) for the right-panel MTKView.
    ///
    /// Always `.rgba16Float` — see `currentTexture()` for the rationale.
    ///
    /// Same live-mailbox contract as `currentTexture()` — re-evaluate per draw.
```

- [ ] **Step 4: Update `currentTrackerTexture()` doc-comment**

Replace with:

```swift
    /// Returns the latest tracker-lane texture (Pass-4 output, downsampled to
    /// `Constants.trackerHeightPx`) for external consumers.
    ///
    /// Always `.rgba16Float`. The tracker lane is **not** converted to 8-bit
    /// by `OpenConfiguration.lanesEightBit` — `.tracker` has no Phase-3 Pigeon
    /// counterpart, so the conversion would be unused cost
    /// (Plan §OQ #4).
    ///
    /// nonisolated so callers can access synchronously without an actor hop.
    /// Reads `latestTrackerTex` from the pipeline's `Mailbox<T>` (G-13).
    /// Returns nil if no frame has been encoded yet or the engine is closed.
```

- [ ] **Step 5: Build to confirm doc-comments compile cleanly under swift-format strict**

```bash
mcp__XcodeBuildMCP__build_run_device
# or fallback:
scripts/build-summary.sh
```

Expected: BUILD SUCCEEDED. (swift-format `--strict` rule
`BeginDocumentationCommentWithOneLineSummary` requires a blank `///` line
after the first sentence of multi-sentence doc comments — already followed
in the templates above.)

---

## Task 9: Tracker-stays-RGBA16F regression + full-suite run

**Files:**
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`

- [ ] **Step 1: Add the dedicated tracker-regression test**

Append to `RgbaConversionTests.swift`:

```swift
// MARK: - Tracker lane regression (OQ #4 lock)

@Suite("RGBA8 conversion — tracker lane stays RGBA16F regardless of flag")
struct RgbaConversionTrackerStaysRgba16fTests {

    @Test("Pipeline init with flag-on does NOT allocate a tracker 8-bit pool")
    func noTrackerEightBitPoolWhenFlagOn() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 256),
            gateOpen: true,
            lanesEightBit: true)
        #expect(pipeline.eightBitTrackerPoolForTest == nil)
    }
}
```

The end-to-end check that `latestTrackerBuffer` is `_64RGBAHalf` with
`lanesEightBit: true` is already covered by Task 6 Step 1.

- [ ] **Step 2: Run the regression test**

```bash
scripts/test-summary.sh --filter eva-swift-stitchTests/RgbaConversionTrackerStaysRgba16fTests
```

Expected: 1 pass / 0 fail.

- [ ] **Step 3: Run the full test suite to catch any unintended regressions**

```bash
scripts/test-summary.sh
```

Expected: All tests pass. Particular suites to confirm:
- `Stage07Tests` — still capture path uses Pass-6 + RGBA16F readback.
- `Stage10Tests` — recording uses Pass-5 NV12 encode (reads RGBA16F).
- `Stage13PhotosTests` / `CaptureNaturalPictureTests` — natural capture
  reads `latestNaturalBuffer` from the mailbox, which is now BGRA8 in the
  default path. **Watch this closely** — `captureNaturalPicture` calls
  `StillCapture.encode(buffer:...)` which goes through
  `convertRGBA16FtoRGBA8` (StillCapture.swift:75). If the buffer is already
  BGRA8 that conversion will throw or produce garbage. Two viable
  resolutions if this regresses:
    1. **Captures explicitly use RGBA16F:** in `captureNaturalPicture` (and
       `captureImage`), source the buffer from the underlying pool rather
       than the mailbox. Or:
    2. **`StillCapture.encode` becomes format-aware:** detect the input
       pixel format and skip the vImage RGBA16F→RGBA8 conversion when the
       buffer is already BGRA8.

If `Stage13PhotosTests` / `CaptureNaturalPictureTests` fails, pick (2) —
it's the smaller change and the still capture path can use either format
as input. Add a branch in `StillCapture.swift:convertRGBA16FtoRGBA8` (rename
to `extractRGBA8Bytes` or similar): if `CVPixelBufferGetPixelFormatType ==
kCVPixelFormatType_32BGRA`, lock + copy directly with a B/R swap; otherwise
run the existing vImage path. Surface this change as a new task only if
the test fails — do not pre-emptively refactor.

If everything passes, proceed.

---

## Task 10: HITL on physical iPad

**Files:**
- Create: `docs/measurements/phase-3-prep/rgba8-conversion.md`

This is the evidence-gathering step the user asked for. No code changes
unless something regresses.

- [ ] **Step 1: Verify the connected iPad's UDIDs and build for device**

```bash
xcrun xctrace list devices
xcrun devicectl list devices
```

Then build & install via XcodeBuildMCP:

```bash
mcp__XcodeBuildMCP__session_show_defaults
# Confirm scheme=eva-swift-stitch, deviceId=<connected iPad's xctrace UDID>
mcp__XcodeBuildMCP__build_run_device
```

- [ ] **Step 2: Tail device logs**

```bash
scripts/device-log-live.sh > /tmp/rgba8-hitl.log &
# Or via the ipad-logs skill if the script's hardcoded UDID is wrong.
```

- [ ] **Step 3: Visual smoke — both MTKView panels look unchanged**

Open the app on the iPad. The MTKView preview reads texture accessors
(`.rgba16Float`), so the visible output must be byte-identical to before
this PR. Compare against a screenshot from the prior commit if available;
otherwise look for color cast, banding, or quantization artifacts at
high-contrast edges. Default-on is the HITL config because the conversion
pass is active.

- [ ] **Step 4: Sustained 30 fps at 4K with conversion on**

In the running app, exercise the camera for ≥ 60 seconds with default
capture resolution (4160×3120). The metricsStream emits one
`FrameDeliveryStats` per `FPS_MEASUREMENT_WINDOW_FRAMES` (30 frames @ 30
fps = 1 s); reads stream into the device log.

Slice the log to the latest session and grep for fps-degraded events:

```bash
LN=$(grep -n 'session started' /tmp/rgba8-hitl.log | tail -1 | cut -d: -f1)
SESSION=$(tail -n "+$LN" /tmp/rgba8-hitl.log)
echo "$SESSION" | grep -iE 'fps[-_]?degraded|fpsLow|drop'
```

Expected: zero or near-zero fps-degraded events. Sustained 30 fps means
the conversion pass cost fits within the 33 ms per-frame budget at 4K on
the device's GPU. If degraded events appear:
- Confirm by recording a 30 s sim_video via XcodeBuildMCP and counting
  frames in QuickTime (or `ffprobe`).
- If genuinely degraded, escalate as a Plan blocker — the design assumes
  Pass-7 cost is sub-budget at 4K. Either downsample before the
  conversion (kills HDR precision) or gate Pass-7 on bridge-subscriber
  presence (defer dispatch until Phase 3 wires a subscriber). Record the
  decision in `DECISIONS.md`.

- [ ] **Step 5: Still-capture HDR fidelity unchanged**

In the app, trigger `captureImage()` (processed-lane capture) and
`captureNaturalPicture` (natural-lane capture) of the same scene. Save the
TIFF / JPEG outputs to Photos or pull via devicectl. Compare against
captures from the prior commit (or, if no priors exist, take two
back-to-back captures with `lanesEightBit: true` then toggle off via a
debug build with the harness explicitly setting `lanesEightBit: false`
and re-capture).

Expected: byte-identical TIFFs / JPEGs across flag states for both capture
paths. Rationale:
- `captureImage` (processed lane) goes through Pass-6 blit from
  `processedTexI` (RGBA16F texture) → still capture pool (RGBA16F) →
  vImage convert in `StillCapture.swift`. Pass-7 doesn't touch this path.
- `captureNaturalPicture` reads `latestNaturalBuffer` from the mailbox.
  If Task 9 Step 3 surfaced a regression and the still capture path is
  now format-aware, both formats must yield bit-identical 8-bit output
  (8-bit is 8-bit; conversion happens via either Pass-7 GPU or the
  pre-existing vImage path).

If outputs differ, escalate. The natural-capture path may need to source
from the underlying RGBA16F pool buffer rather than the mailbox to
guarantee parity.

- [ ] **Step 6: Write the measurement file**

Create `docs/measurements/phase-3-prep/rgba8-conversion.md` capturing:
- Date, iPad model + iOS version, capture resolution.
- Sustained-fps observation (e.g. "60 s @ 30.0 fps, 0 degraded windows").
- Visual smoke result.
- Still-capture parity result (both `captureImage` and `captureNaturalPicture`).
- Any anomalies + resolutions.

Template:

```markdown
# Pre-Phase-3 RGBA8 conversion — HITL evidence

**Date:** 2026-05-15
**Device:** Shreeyak's iPad Pro 11" 2nd-gen (iPad8,9), iOS <version>
**Capture resolution:** 4160 × 3120, default crop 1600 × 1200

## Default-on (lanesEightBit = true) — Pass-7 active

### Sustained 30 fps at 4K
- 60 s exercise window, AsyncStream frameResult measurement.
- Average fps: 30.0
- fps-degraded windows: 0
- Verdict: pass.

### Visual smoke — MTKView preview
- Both panels visually identical to flag-off comparison.
- No color cast, no banding, no edge quantization.
- Verdict: pass. (Texture accessors return RGBA16F regardless of flag —
  expected.)

### Still capture — `captureImage`
- TIFF output saved. Compared to flag-off TIFF: bit-identical.
- Verdict: pass.

### Still capture — `captureNaturalPicture`
- JPEG output saved. Compared to flag-off JPEG: bit-identical.
- Verdict: pass.

## Anomalies + resolutions

None.
```

- [ ] **Step 7: Send the measurement file to the user**

```
# Use the SendUserFile tool with status=normal
SendUserFile docs/measurements/phase-3-prep/rgba8-conversion.md
```

---

## Task 11: state.md + DECISIONS.md entries

**Files:**
- Modify: `CameraKit/state.md`
- Modify: `CameraKit/DECISIONS.md`

- [ ] **Step 1: Prepend a new section to `CameraKit/state.md`**

Edit `CameraKit/state.md`. **Prepend** (the file is reverse-chronological)
the following section above the existing top entry:

```markdown
# state.md — Pre-Phase-3 RGBA8 lane conversion (2026-05-15)

Pre-Phase-3 additive capabilities stage outside brief discipline. Spec:
`docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
Plan: `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md`.
Rationale: `DECISIONS.md` D-2P-09 (BGRA8 wire format), D-2P-11
(default-on, Option B placement, tracker non-conversion).

## What's built — Pre-Phase-3 RGBA8 (permanent)

- **`OpenConfiguration.lanesEightBit: Bool = true`** — session-scoped flag.
  Default on. Drives a Pass-7 compute pass + mailbox rewire on natural +
  processed lanes only (tracker stays RGBA16F).
- **Pass-7 (`rgba16fToBgra8`)** at
  `CameraKit/Sources/CameraKit/Shaders/Rgba16fToBgra8.metal` — compute
  kernel; reads RGBA16F, writes `.bgra8Unorm` (Metal handles byte-order
  swizzle on write).
- **`TexturePoolManager.makeBgra8LanePool` + `dequeueEightBitPoolTexture`**
  — IOSurface-backed BGRA8 pools, parallel to the RGBA16F pool factory.
- **`SessionCapabilities.streamPixelFormat`** is now flag-dependent —
  `"BGRA8"` by default, `"RGBA16F"` when opted out. Doc-comment updated.
- **Texture/buffer asymmetry doc-comments** on
  `CameraEngine.currentTexture()`, `currentProcessedTexture()`,
  `currentTrackerTexture()`, `currentPixelBuffer(stream:)` — state the
  load-bearing invariant explicitly.

## Scaffolding still live

None added; none retired.

## Public API exposed — Pre-Phase-3 RGBA8 additions

- `OpenConfiguration.lanesEightBit: Bool` (with default `true`).
- `SessionCapabilities.streamPixelFormat` semantics extended (string
  values `"BGRA8"` / `"RGBA16F"`).

## Manual test evidence — Pre-Phase-3 RGBA8

- New suite `RgbaConversionTests` — pass on device.
- `Stage13Phase2PixelFormatTests` updated to cover both flag states —
  pass.
- Full regression: <N> tests pass / 0 fail.
- **HITL on iPad — completed.** 30 fps sustained at 4K with conversion
  pass on; still-capture HDR fidelity unchanged. Evidence at
  `docs/measurements/phase-3-prep/rgba8-conversion.md`.

## Decisions taken — Pre-Phase-3 RGBA8

- D-2P-09 (already logged 2026-05-15) — BGRA8 wire format.
- D-2P-11 (this PR) — default-on, Option B placement (per-lane bridge
  tap), tracker lane does not convert, single `streamPixelFormat` field
  preserved.
- Plan §Open Questions 2–6 — resolved inline in
  `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md`.

---

```

- [ ] **Step 2: Append a one-liner to `CameraKit/DECISIONS.md`**

Edit `CameraKit/DECISIONS.md`. Append (preserve append-only invariant —
add to the bottom of the chronological section that matches today's
date):

```markdown
2026-05-15 [migration-2 D-2P-11] coordinator — Pre-Phase-3 RGBA8 lane-conversion design Open Q's #2–#6 resolved: default-on flag (`OpenConfiguration.lanesEightBit = true`), Option B placement (per-lane Pass-7 bridge tap, RGBA16F end-to-end internally), tracker lane does not convert (no Pigeon counterpart, saves one Metal pass/frame), `SessionCapabilities.streamPixelFormat` kept as a single string field with extended semantics ("BGRA8" vs "RGBA16F"), per-feature test naming (`RgbaConversionTests.swift`). Texture/buffer asymmetry — `currentTexture()` / `currentProcessedTexture()` / `currentTrackerTexture()` always `.rgba16Float`; `currentPixelBuffer(stream:)` is BGRA8 on natural + processed when default-on. Documented in `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md`.
```

- [ ] **Step 3: Manually regenerate CONTRACTS.md so the diff is reviewable pre-commit**

```bash
scripts/regen-contracts.sh
```

Expected: `CameraKit/CONTRACTS.md` updated to include
`OpenConfiguration.lanesEightBit` field + updated `streamPixelFormat`
doc-comment.

- [ ] **Step 4: Stop**

Per CLAUDE.md §7: do not run `git add`, `git commit`, `git push`, or any
other git operation without explicit user approval. Summarise the state
to the user:

- What's built (the 6 task surfaces).
- What's tested (suite list + HITL evidence path).
- What's pending (user-approved git commit + PR).

---

## Self-review

**Spec coverage** (against `2026-05-15-rgba16f-to-rgba8-conversion-design.md`):

| Spec section | Plan task |
|---|---|
| §Goal — `lanesEightBit` flag default-on | Task 2 |
| §Sequencing 1 (wire format) | Resolved upstream (D-2P-09); locked by Task 1 constants |
| §Sequencing 2 (add flag) | Task 2 |
| §Sequencing 3 (bridge tap pool + pass) | Tasks 3, 4, 5, 6 |
| §Sequencing 4 (re-route mailboxes) | Task 6 Step 3 |
| §Sequencing 5 (update `streamPixelFormat`) | Task 7 |
| §Sequencing 6 (tests) | Tasks 1, 2, 3, 5, 6, 7, 9 |
| §Where the conversion lives — Option B | Task 6 (texture mailboxes untouched; buffer mailboxes rewire) |
| §What format we convert TO | Task 1 + 4 (BGRA8, `.bgra8Unorm`) |
| §Carve-outs (still cap, calibration, NV12, MTKView, tracker) | Task 6 leaves Pass-5/6 inputs untouched; Task 9 Step 3 regression watches |
| §Blast radius walk-through | Constants (Task 1), Capabilities (Tasks 2 + 7), MetalPipeline (Tasks 5 + 6), CameraEngine (Tasks 5 + 7 + 8), TexturePoolManager (Task 3), Shaders/ (Task 4) |
| §Testing — format / buffer / asymmetry / still capture | Tasks 1, 6, 7, 9, plus Task 10 still-capture HITL |
| §Verification & integration | Task 10 HITL + Task 11 state.md/DECISIONS.md |
| §Open questions 1–6 | All resolved in plan §Open questions |

**Placeholder scan**: searched for "TBD", "TODO", "implement later", "fill in details", "handle edge cases", "similar to Task N" — none found.

**Type consistency**:
- Constants names: `eightBitLanePixelFormat`, `eightBitLaneMetalFormat`,
  `streamPixelFormatStringEightBit`, `streamPixelFormatStringSixteenBit`
  — used consistently across Tasks 1, 3, 5, 7.
- `OpenConfiguration.lanesEightBit` — consistent across Tasks 2, 5, 6, 7, 8.
- Test seam names: `eightBitNaturalPoolForTest`,
  `eightBitProcessedPoolForTest`, `eightBitTrackerPoolForTest`,
  `lanesEightBitForTest` — consistent across Tasks 5, 6, 9.
- Pool factory + dequeue names: `makeBgra8LanePool`,
  `dequeueEightBitPoolTexture` — consistent across Tasks 3, 5, 6.
- Kernel name: `rgba16fToBgra8` — consistent across Tasks 4, 5.
- PSO field name on MetalPipeline: `rgba16fToBgra8PSO` — consistent
  Tasks 5, 6.
- Pool field names: `eightBitNaturalPool`, `eightBitProcessedPool` —
  consistent Tasks 5, 6 (no tracker variant, deliberate per OQ #4).
- Test suite names: `RgbaConversionConstantsTests`,
  `RgbaConversionOpenConfigurationTests`,
  `RgbaConversionPoolFactoryTests`,
  `RgbaConversionPipelineFlagTests`,
  `RgbaConversionMailboxFormatTests`,
  `RgbaConversionStreamPixelFormatTests`,
  `RgbaConversionTrackerStaysRgba16fTests` — distinct per `@Suite`
  struct (matches CLAUDE.md §8 filter invariant).

All clear.
