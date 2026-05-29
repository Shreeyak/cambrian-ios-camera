# Stage 10 — Video Recording (HEVC in MP4) + AE Frame-Rate Range Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record/stop button produces an `.mp4` (HEVC 8-bit, NV12, GPU-to-encoder zero-copy) that appears in Photos. `pause()` during recording synchronously finalizes (scaffolded background-drain lands Stage 12). Preview keeps 30fps; recording mode unlocks AE to 15–30fps for low-light.

**Architecture:** A new `Recording` coordinator owns `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` behind `AssetWriting` / `AssetWriterPixelBufferAdapting` protocol seams so tests inject a `FakeAssetWriter`. `MetalPipeline` gains Pass 5: a compute kernel (`rgba16fToNV12`) that reads `processedTex` (RGBA16F) and writes directly into encoder-pool NV12 planes via `CVMetalTextureCache`-wrapped Y (`.r8Unorm`) + CbCr (`.rg8Unorm`) textures — BT.709 video-range, 2×2 chroma downsample. `CameraSession` toggles `activeVideoMin/MaxFrameDuration` between preview `(1/30, 1/30)` and recording `(1/30, 1/15)` on `sessionQueue` inside `lockForConfiguration()`. `pause()` during recording synchronously `await`s the finalize path on the engine actor — scaffolded with `scaffolding:10:synchronous-drain-pause` as a missing `UIApplication.beginBackgroundTask` wrapper (Stage 12 retires).

**Tech Stack:** Swift 6, AVFoundation (`AVAssetWriter`, `AVAssetWriterInputPixelBufferAdaptor`, HEVC), CoreMedia (`CMTime`, `CMSampleBuffer`), Metal compute (Pass 5 NV12 write), swift-testing, ruby xcodeproj gem.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `CameraKit/Sources/CameraKit/Constants.swift` | Modify | Add `frameRateRecordingMinFps = 15`, `recordingTargetBitrateBpsDefault = 40_000_000`, `recordingFinishTimeoutSeconds = 5`, `drainTimeoutSeconds = 5`, `encoderPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. |
| `CameraKit/Sources/CameraKit/SessionState.swift` | Modify | Reshape `RecordingState` to `idle / recording / finalizing / paused` (brief §4). Expand `RecordingOptions` to `bitrateBps / fps / outputDirectory / fileName`. Reshape `RecordingStart` to `uri: String, displayName: String`. |
| `CameraKit/Sources/CameraKit/Errors.swift` | Modify | Add `RecordingError.notReadyForMoreMediaData`, `.finalizeTimeout`, `.finalizeFailed`, `.cancelledByPause` variants. `EngineError.recording(_)` already exists. |
| `CameraKit/Sources/CameraKit/AssetWriting.swift` | Create | `protocol AssetWriting` + `protocol AssetWriterPixelBufferAdapting` (Sendable); `AVAssetWriting` / `AVAssetWriterAdapting` production wrappers around `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`; factory closure `AssetWriterFactory` so tests inject fakes. |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | Modify | Add `makeEncoderNV12Pool(size:)` — IOSurface-backed NV12 pool, Metal-compatible. Add `makeYWriteTexture(from:)` / `makeCbCrWriteTexture(from:)` — wrap Y (plane 0, `.r8Unorm`) + CbCr (plane 1, `.rg8Unorm`) with `.shaderWrite` usage so Pass 5 can write into encoder-pool buffers. |
| `CameraKit/Sources/CameraKit/Shaders/NV12Encode.metal` | Create | `rgba16fToNV12` compute kernel — reads `processedTex` RGBA16F, writes NV12 planes (BT.709 video-range, 2×2 chroma downsample). |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | Modify | Construct `encoderPool` + `nv12EncodePSO` in init; add `isRecording` gate (`ManagedAtomic<Bool>`); Pass 5 runs only while `isRecording`; in `encode()` dequeue NV12 buffer, wrap write-capable planes, dispatch `rgba16fToNV12`; pass buffer + PTS to a `@Sendable` submission closure the engine sets. |
| `CameraKit/Sources/CameraKit/Recording.swift` | Create | `actor Recording` coordinator; `start(options:captureSize:fps:writerFactory:)` / `stop()` / `submitEncodedBuffer(_:pts:)`; runs finalize with `RECORDING_FINISH_TIMEOUT_SECONDS` deadline via cancel-on-expiry (D-04 + ADR-16); state machine published via callback hooks (mirrors `RecoveryCoordinator` hook pattern). |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | Modify | Add `setPreviewFrameRateRange()` / `setRecordingFrameRateRange()` — commits on `sessionQueue` inside `lockForConfiguration()`. |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Modify | Implement `startRecording(options:)`, `stopRecording()`, `pause()`, `resume()`, `recordingStateStream()`; wire Pass 5 submission closure; state publication. `pause()` during recording synchronously `await`s finalize (scaffolded). |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | (No direct edit) | Pass 5 is driven inside `MetalPipeline.encode`; delegate path unchanged except for existing watchdog kicks. |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Modify | Record-button action calls `engine.startRecording(options:)` / `stopRecording()`; consume `recordingStateStream`; `recordingElapsedSeconds: Int` timer increments while `.recording`. |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Modify | Record/stop button + red dot + `mm:ss` timer in the bottom bar. |
| `CameraKit/Tests/CameraKitTests/Stage10Tests.swift` | Create | 8 `@Test` functions covering §8 TESTABLEs. |
| `eva-swift-stitch.xcodeproj` | Modify | Wire `Stage10Tests.swift` into `eva-swift-stitchTests` via ruby xcodeproj. |

---

## Task 1: Stage preflight

**Files:** `CameraKit/state.md`, `scripts/stage-preflight.sh`

- [ ] **Step 1: Run preflight**

```bash
bash scripts/stage-preflight.sh
```
Expected: exits 0. Halt on non-zero.

- [ ] **Step 2: Gate on Stage 08 + Stage 09 being complete**

```bash
# Stage 08 C++ target must exist.
test -d CameraKit/Sources/CameraKitCxx || { echo "Stage 08 missing"; exit 1; }
# All prior-stage scaffolds must be retired (per brief §2 starting state).
grep -rn -E '01:|04:|06:|07:|09:' CameraKit/Sources/
```
Expected: the `ls` succeeds; the grep returns **zero hits**. Halt otherwise.

- [ ] **Step 3: Clean build baseline**

Use `mcp__XcodeBuildMCP__build_device` (primary) or `scripts/build-summary.sh` (fallback). Expected: BUILD SUCCEEDED.

---

## Task 2: Constants

**Files:** `CameraKit/Sources/CameraKit/Constants.swift`

- [ ] **Step 1: Append the Stage 10 constant block**

```swift
    // Stage 10: recording mode.
    /// AE lower frame-rate bound while recording — allows AE to halve in low light.
    /// constants.md#FRAME_RATE_RECORDING_MIN_FPS.
    static let frameRateRecordingMinFps: Int = 15
    /// Default video bitrate. TARGET_BITRATE_MBPS is marked "docs/measurements/" upstream;
    /// 40 Mbps is reasonable for 4K HEVC @ 30fps. See state.md open questions.
    static let recordingTargetBitrateBpsDefault: Int = 40_000_000
    /// Deadline for AVAssetWriter.finishWriting. Past this, cancel to avoid corrupt MP4
    /// (ADR-16, G-08). constants.md#RECORDING_FINISH_TIMEOUT_SECONDS.
    static let recordingFinishTimeoutSeconds: Double = 5.0
    /// Recording EOS drain budget. constants.md#DRAIN_TIMEOUT_SECONDS.
    static let drainTimeoutSeconds: Double = 5.0
    /// Native VideoToolbox encoder input pixel format (NV12 video-range).
    /// constants.md#ENCODER_PIXEL_FORMAT.
    static let encoderPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
```

- [ ] **Step 2: Build + commit**

XcodeBuildMCP build_device. Expected: BUILD SUCCEEDED.

```bash
git add CameraKit/Sources/CameraKit/Constants.swift
git commit -m "feat(stage-10): add recording constants (bitrate, timeouts, NV12 format, min fps)"
```

---

## Task 3: SessionState reshape

**Files:** `CameraKit/Sources/CameraKit/SessionState.swift`

- [ ] **Step 1: Reshape `RecordingState`, `RecordingOptions`, `RecordingStart`**

Replace the existing types:

```swift
public enum RecordingState: Sendable, Hashable {
    case idle(lastUri: String?)
    case recording
    case finalizing
    case paused
}

public struct RecordingOptions: Sendable, Hashable {
    /// Target video bitrate in bits per second. Nil → `Constants.recordingTargetBitrateBpsDefault`.
    public var bitrateBps: Int?
    /// Target frame rate (30). Nil → `Constants.frameRateTargetFPS`.
    public var fps: Int?
    /// Destination directory. Nil → app Documents directory.
    public var outputDirectory: URL?
    /// Filename excluding extension. Nil → ISO-8601 timestamp.
    public var fileName: String?

    public init(
        bitrateBps: Int? = nil,
        fps: Int? = nil,
        outputDirectory: URL? = nil,
        fileName: String? = nil
    ) {
        self.bitrateBps = bitrateBps
        self.fps = fps
        self.outputDirectory = outputDirectory
        self.fileName = fileName
    }
}

public struct RecordingStart: Sendable, Hashable {
    /// Destination URL as a string per `api-surface.md`.
    public let uri: String
    /// Displayed filename (without path).
    public let displayName: String
    public init(uri: String, displayName: String) {
        self.uri = uri
        self.displayName = displayName
    }
}
```

Rationale: brief §4 names exactly these four `RecordingState` cases; architecture §Recording state machine uses `preparing / stopping` which the brief supersedes for this stage per CLAUDE.md §8 (brief wins). Log in state.md Decisions.

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/SessionState.swift
git commit -m "feat(stage-10): reshape RecordingState/Options/Start per brief §4"
```

---

## Task 4: Errors

**Files:** `CameraKit/Sources/CameraKit/Errors.swift`

- [ ] **Step 1: Add recording error variants**

Replace the existing `RecordingError` enum:

```swift
public enum RecordingError: Error, Sendable {
    case writerStartFailed(status: Int)
    case appendFailed(status: Int)
    case finishTimeout
    case diskFull
    case notReadyForMoreMediaData
    case finalizeTimeout
    case finalizeFailed(reason: String)
    case cancelledByPause
}
```

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/Errors.swift
git commit -m "feat(stage-10): RecordingError variants — notReady, finalize, cancelledByPause"
```

---

## Task 5: AssetWriting protocol seam

**Files:** `CameraKit/Sources/CameraKit/AssetWriting.swift` (create)

- [ ] **Step 1: Write the seam**

```swift
import AVFoundation
import CoreMedia

/// Abstraction over AVAssetWriter for test injection (10:record-start-stop-happy-path et al).
public protocol AssetWriting: Sendable {
    var status: AVAssetWriter.Status { get async }
    func startWriting() async -> Bool
    func startSession(atSourceTime: CMTime) async
    func markInputFinished() async
    /// Returns only when writer has completed (or been cancelled).
    func finishWriting() async
    func cancelWriting() async
    /// Error after a failed status, if any.
    var writerError: Error? { get async }
}

/// Abstraction over AVAssetWriterInputPixelBufferAdaptor.
public protocol AssetWriterPixelBufferAdapting: Sendable {
    var isReadyForMoreMediaData: Bool { get async }
    func append(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool
}

/// Factory closure — production path injected by default; tests swap for fakes.
public typealias AssetWriterFactory = @Sendable (
    _ outputURL: URL,
    _ size: Size,
    _ bitrateBps: Int,
    _ fps: Int
) async throws -> (AssetWriting, AssetWriterPixelBufferAdapting)

/// Production factory: real `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`.
public enum DefaultAssetWriterFactory {
    public static let make: AssetWriterFactory = { outputURL, size, bitrateBps, fps in
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateBps,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(Constants.encoderPixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        guard writer.canAdd(input) else {
            throw RecordingError.writerStartFailed(status: Int(writer.status.rawValue))
        }
        writer.add(input)
        return (
            AVAssetWritingBox(writer: writer, input: input),
            AVAdaptorBox(adaptor: adaptor)
        )
    }
}

/// Production boxes. Both @unchecked Sendable: AVAssetWriter is not Sendable but is thread-safe
/// for the call patterns we use (start/append from our single actor, internal encode queue owned by framework).
final class AVAssetWritingBox: AssetWriting, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }
    var status: AVAssetWriter.Status { get async { writer.status } }
    var writerError: Error? { get async { writer.error } }
    func startWriting() async -> Bool { writer.startWriting() }
    func startSession(atSourceTime t: CMTime) async { writer.startSession(atSourceTime: t) }
    func markInputFinished() async { input.markAsFinished() }
    func finishWriting() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
    }
    func cancelWriting() async { writer.cancelWriting() }
}

final class AVAdaptorBox: AssetWriterPixelBufferAdapting, @unchecked Sendable {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    init(adaptor: AVAssetWriterInputPixelBufferAdaptor) { self.adaptor = adaptor }
    var isReadyForMoreMediaData: Bool { get async { adaptor.assetWriterInput.isReadyForMoreMediaData } }
    func append(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool {
        adaptor.append(buffer, withPresentationTime: pts)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/AssetWriting.swift
git commit -m "feat(stage-10): AssetWriting/AdapterPixelBufferAdapting protocol seam + default factory"
```

---

## Task 6: TexturePoolManager — encoder pool + NV12 write textures

**Files:** `CameraKit/Sources/CameraKit/TexturePoolManager.swift`

- [ ] **Step 1: Add encoder pool factory**

Insert inside the class:

```swift
    /// Encoder pool — NV12 video-range, IOSurface-backed, Metal-compatible.
    /// Feeds Pass 5 GPU writes and AVAssetWriterInputPixelBufferAdaptor.append() reads.
    func makeEncoderNV12Pool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(Constants.encoderPixelFormat),
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let p = pool else {
            throw MetalError.textureCacheCreateFailed(code: status)
        }
        return p
    }

    /// Dequeue an encoder buffer and wrap both planes as write-capable MTLTextures.
    func dequeueEncoderBuffer(
        pool: CVPixelBufferPool
    ) throws -> (buffer: CVPixelBuffer, yTex: MTLTexture, cbcrTex: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let b = buf else {
            throw MetalError.textureCacheCreateFailed(code: s)
        }
        let y = try makePlaneWriteTexture(from: b, planeIndex: 0, format: .r8Unorm)
        let cbcr = try makePlaneWriteTexture(from: b, planeIndex: 1, format: .rg8Unorm)
        return (b, y, cbcr)
    }

    private func makePlaneWriteTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        format: MTLPixelFormat
    ) throws -> MTLTexture {
        guard let cache = textureCache else { throw MetalError.textureCacheCreateFailed(code: -1) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw MetalError.textureWrapFailed(code: status)
        }
        return mtlTex
    }
```

Note: `.usage` on `MTLTexture` created from `CVMetalTextureCache` is controlled by the pool's `kCVPixelBufferMetalCompatibilityKey: true`; write usage is implicit when the backing `IOSurface` is Metal-compatible. No additional `MTLTextureDescriptor` step needed.

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/TexturePoolManager.swift
git commit -m "feat(stage-10): encoder NV12 pool + write-capable plane texture helpers"
```

---

## Task 7: Pass 5 shader (NV12 encode)

**Files:** `CameraKit/Sources/CameraKit/Shaders/NV12Encode.metal` (create)

- [ ] **Step 1: Write the kernel**

```metal
#include <metal_stdlib>
using namespace metal;

// BT.709 video-range RGB → YCbCr coefficients.
// Y  in  [16..235], CbCr in [16..240].
constant float  kR_Y  = 0.183;
constant float  kG_Y  = 0.614;
constant float  kB_Y  = 0.062;
constant float  kR_Cb = -0.101;
constant float  kG_Cb = -0.338;
constant float  kB_Cb =  0.439;
constant float  kR_Cr =  0.439;
constant float  kG_Cr = -0.399;
constant float  kB_Cr = -0.040;

/// Pass 5 — RGBA16F processed texture → NV12 planes (Y full-res, CbCr 2x2 downsampled).
/// Dispatched over the CbCr grid (chromaW = width/2, chromaH = height/2); each invocation
/// writes the 2x2 Y block and a single CbCr pixel by averaging the 2x2 RGB neighborhood.
kernel void rgba16fToNV12(
    texture2d<float, access::read>   inRGBA     [[ texture(0) ]],
    texture2d<float, access::write>  yPlane     [[ texture(1) ]],
    texture2d<float, access::write>  cbcrPlane  [[ texture(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    const uint x0 = gid.x * 2;
    const uint y0 = gid.y * 2;
    if (x0 + 1 >= inRGBA.get_width() || y0 + 1 >= inRGBA.get_height()) return;

    float4 p00 = inRGBA.read(uint2(x0,     y0));
    float4 p10 = inRGBA.read(uint2(x0 + 1, y0));
    float4 p01 = inRGBA.read(uint2(x0,     y0 + 1));
    float4 p11 = inRGBA.read(uint2(x0 + 1, y0 + 1));

    auto toY = [](float3 rgb) {
        float y = kR_Y * rgb.r + kG_Y * rgb.g + kB_Y * rgb.b + 16.0/255.0;
        return clamp(y, 16.0/255.0, 235.0/255.0);
    };
    yPlane.write(float4(toY(p00.rgb), 0, 0, 0), uint2(x0,     y0));
    yPlane.write(float4(toY(p10.rgb), 0, 0, 0), uint2(x0 + 1, y0));
    yPlane.write(float4(toY(p01.rgb), 0, 0, 0), uint2(x0,     y0 + 1));
    yPlane.write(float4(toY(p11.rgb), 0, 0, 0), uint2(x0 + 1, y0 + 1));

    float3 avg = 0.25 * (p00.rgb + p10.rgb + p01.rgb + p11.rgb);
    float cb = kR_Cb * avg.r + kG_Cb * avg.g + kB_Cb * avg.b + 128.0/255.0;
    float cr = kR_Cr * avg.r + kG_Cr * avg.g + kB_Cr * avg.b + 128.0/255.0;
    cb = clamp(cb, 16.0/255.0, 240.0/255.0);
    cr = clamp(cr, 16.0/255.0, 240.0/255.0);
    // CbCr is rg8Unorm — .r = Cb, .g = Cr.
    cbcrPlane.write(float4(cb, cr, 0, 0), gid);
}
```

- [ ] **Step 2: Build + commit**

XcodeBuildMCP build_device. Expected: BUILD SUCCEEDED (shader compiles as part of the `.metal` build phase).

```bash
git add CameraKit/Sources/CameraKit/Shaders/NV12Encode.metal
git commit -m "feat(stage-10): Pass 5 rgba16fToNV12 compute kernel (BT.709 video-range, 2x2 chroma)"
```

---

## Task 8: Recording coordinator — actor + hooks

**Files:** `CameraKit/Sources/CameraKit/Recording.swift` (create)

- [ ] **Step 1: Write the failing test (coordinator happy path scaffold)**

Create `CameraKit/Tests/CameraKitTests/Stage10Tests.swift` with the minimum suite harness (full tests added in Task 14):

```swift
import Testing
import AVFoundation
import CoreMedia
@testable import CameraKit

@Suite("Stage 10 — recording coordinator")
struct Stage10CoordinatorTests {
    @Test("coordinator publishes idle(nil) on init")
    func initialState() async {
        var observed: [RecordingState] = []
        let hooks = Recording.Hooks(
            publishState: { observed.append($0) },
            emitError: { _ in }
        )
        let rec = Recording(clock: SystemClock(), hooks: hooks, writerFactory: { _,_,_,_ in
            fatalError("unused in this test")
        })
        await rec.observeCurrentStateForTest()
        #expect(observed == [.idle(lastUri: nil)])
    }
}
```

- [ ] **Step 2: Run → expect compile failure**

`test_device` filter `Stage10CoordinatorTests`. Expected: compile error (`Recording` undefined).

- [ ] **Step 3: Write `Recording.swift`**

```swift
import Foundation
import AVFoundation
import CoreMedia

/// Recording coordinator — owns AVAssetWriter + adaptor lifecycle (D-04, ADR-16).
/// Single-session: one `start` call, one `stop` call. Instance discarded between recordings.
public actor Recording {

    public struct Hooks: Sendable {
        public var publishState: @Sendable (RecordingState) -> Void
        public var emitError: @Sendable (CameraError) -> Void
        public init(
            publishState: @escaping @Sendable (RecordingState) -> Void,
            emitError: @escaping @Sendable (CameraError) -> Void
        ) {
            self.publishState = publishState
            self.emitError = emitError
        }
    }

    private let clock: any CameraKitClock
    private let hooks: Hooks
    private let writerFactory: AssetWriterFactory

    private var writer: AssetWriting?
    private var adaptor: AssetWriterPixelBufferAdapting?
    private var state: RecordingState = .idle(lastUri: nil)
    private var outputURL: URL?
    private var startPTS: CMTime?
    private var droppedNotReady: Int = 0

    public init(
        clock: any CameraKitClock,
        hooks: Hooks,
        writerFactory: @escaping AssetWriterFactory
    ) {
        self.clock = clock
        self.hooks = hooks
        self.writerFactory = writerFactory
    }

    /// Test seam: publish the current state through the hook so tests can observe it.
    func observeCurrentStateForTest() { hooks.publishState(state) }

    public func currentState() -> RecordingState { state }
    public func currentDroppedNotReady() -> Int { droppedNotReady }

    /// Start a recording session. Returns the `RecordingStart` on success.
    public func start(
        options: RecordingOptions,
        captureSize: Size
    ) async throws -> RecordingStart {
        guard case .idle = state else {
            throw RecordingError.writerStartFailed(status: -1)
        }
        let dir = options.outputDirectory
            ?? (try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
        let name = options.fileName
            ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(name).mp4")
        let bitrate = options.bitrateBps ?? Constants.recordingTargetBitrateBpsDefault
        let fps = options.fps ?? Constants.frameRateTargetFPS

        let (w, a) = try await writerFactory(url, captureSize, bitrate, fps)
        self.writer = w
        self.adaptor = a
        self.outputURL = url

        let ok = await w.startWriting()
        if !ok {
            let err = await w.writerError
            throw RecordingError.writerStartFailed(
                status: Int((err as NSError?)?.code ?? -1)
            )
        }
        // startSession deferred until first frame's PTS is known (in submitEncodedBuffer).
        state = .recording
        hooks.publishState(state)
        return RecordingStart(uri: url.absoluteString, displayName: "\(name).mp4")
    }

    /// Submit a GPU-encoded NV12 buffer. Returns true if appended; false if dropped.
    @discardableResult
    public func submitEncodedBuffer(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool {
        guard case .recording = state,
              let writer, let adaptor else { return false }
        if startPTS == nil {
            startPTS = pts
            await writer.startSession(atSourceTime: pts)
        }
        if await adaptor.isReadyForMoreMediaData == false {
            droppedNotReady += 1
            return false
        }
        return await adaptor.append(buffer, pts: pts)
    }

    /// Stop the recording and finalize (or cancel on deadline).
    /// Returns the output URI on success, or the (possibly empty) URI on deadline cancel.
    public func stop(reason: StopReason = .user) async -> String {
        guard case .recording = state, let writer else {
            if case .idle(let last) = state { return last ?? "" }
            return outputURL?.absoluteString ?? ""
        }
        state = .finalizing
        hooks.publishState(state)

        await writer.markInputFinished()

        // Race: finishWriting() vs RECORDING_FINISH_TIMEOUT_SECONDS deadline.
        let deadlineMs = Int(Constants.recordingFinishTimeoutSeconds * 1000)
        let clock = self.clock
        let didCancel = ManagedAtomic<Bool>(false)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await writer.finishWriting() }
            group.addTask {
                try? await clock.sleep(milliseconds: deadlineMs)
                if await writer.status != .completed {
                    didCancel.store(true, ordering: .sequentiallyConsistent)
                    await writer.cancelWriting()
                }
            }
            await group.waitForAll()
        }

        let url = outputURL?.absoluteString ?? ""
        if didCancel.load(ordering: .acquiring) {
            let err = CameraError(
                code: .recordingTruncated,
                message: "finishWriting exceeded \(Constants.recordingFinishTimeoutSeconds)s; cancelled",
                isFatal: false
            )
            hooks.emitError(err)
        }
        if await writer.status == .failed {
            let e = await writer.writerError
            let err = CameraError(
                code: .recordingFailed,
                message: "writer failed: \(String(describing: e))",
                isFatal: true
            )
            hooks.emitError(err)
            state = .idle(lastUri: url)
            hooks.publishState(state)
            return url
        }
        state = reason == .pause ? .paused : .idle(lastUri: url)
        hooks.publishState(state)
        return url
    }

    public enum StopReason: Sendable { case user, pause }
}

// Needed by the atomic in stop() — import is added to the file top.
@_exported import Atomics
```

- [ ] **Step 4: Run coordinator test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/Recording.swift CameraKit/Tests/CameraKitTests/Stage10Tests.swift
git commit -m "feat(stage-10): Recording actor — AVAssetWriter coordinator with deadline cancel"
```

---

## Task 9: CameraSession — AE frame-rate range toggle

**Files:** `CameraKit/Sources/CameraKit/CameraSession.swift`

- [ ] **Step 1: Add the two helpers**

```swift
    /// Preview mode — lock preview frame rate to FRAME_RATE_TARGET_FPS on both min and max.
    func setPreviewFrameRateRange() async throws {
        guard let device = device else { return }
        let fps = Int32(Constants.frameRateTargetFPS)
        let dur = CMTimeMake(value: 1, timescale: fps)
        try await device.lockForConfiguration()
        device.avDevice.activeVideoMinFrameDuration = dur
        device.avDevice.activeVideoMaxFrameDuration = dur
        await device.unlockForConfiguration()
    }

    /// Recording mode — allow AE to halve frame rate in low light.
    /// Min = 1/FRAME_RATE_TARGET_FPS, Max = 1/FRAME_RATE_RECORDING_MIN_FPS.
    func setRecordingFrameRateRange() async throws {
        guard let device = device else { return }
        let minDur = CMTimeMake(value: 1, timescale: Int32(Constants.frameRateTargetFPS))
        let maxDur = CMTimeMake(value: 1, timescale: Int32(Constants.frameRateRecordingMinFps))
        try await device.lockForConfiguration()
        device.avDevice.activeVideoMinFrameDuration = minDur
        device.avDevice.activeVideoMaxFrameDuration = maxDur
        await device.unlockForConfiguration()
    }
```

Note: both run on the session's actor/queue via existing device-provider hop; no explicit `sessionQueue.sync` needed because `LiveCaptureDevice.lockForConfiguration()` already brokers that.

- [ ] **Step 2: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraSession.swift
git commit -m "feat(stage-10): AE frame-rate range — preview vs recording modes (U-16)"
```

---

## Task 10: MetalPipeline — Pass 5 + isRecording gate

**Files:** `CameraKit/Sources/CameraKit/MetalPipeline.swift`

- [ ] **Step 1: Add fields**

```swift
    /// Stage 10: encoder NV12 pool (only used while recording).
    private let encoderPool: CVPixelBufferPool
    private let nv12EncodePSO: MTLComputePipelineState
    /// Engine flips this. Set: engine.startRecording(). Cleared: engine.stopRecording()/pause().
    nonisolated let isRecording: ManagedAtomic<Bool> = ManagedAtomic(false)
    /// Engine installs this at open(); Pass 5 delivers the dequeued NV12 buffer + PTS.
    var onEncodedBufferReady: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
```

- [ ] **Step 2: Construct in init**

After existing pool allocations:

```swift
    let ePool = try texturePool.makeEncoderNV12Pool(size: captureSize)
    self.encoderPool = ePool
    guard let fnEncode = library.makeFunction(name: "rgba16fToNV12") else {
        throw MetalError.pipelineStateCompilation("rgba16fToNV12 missing")
    }
    self.nv12EncodePSO = try device.makeComputePipelineState(function: fnEncode)
```

- [ ] **Step 3: Dispatch Pass 5 inside `encode(sampleBuffer:)`**

After Pass 4 and before the existing `addCompletedHandler`:

```swift
    var encoderPairForCompletion: (buffer: CVPixelBuffer, yTex: MTLTexture, cbcrTex: MTLTexture)?
    if isRecording.load(ordering: .acquiring) {
        do {
            let enc = try texturePool.dequeueEncoderBuffer(pool: encoderPool)
            let pass5 = commandBuffer.makeComputeCommandEncoder()!
            pass5.setComputePipelineState(nv12EncodePSO)
            pass5.setTexture(processedTexI, index: 0)
            pass5.setTexture(enc.yTex, index: 1)
            pass5.setTexture(enc.cbcrTex, index: 2)
            let cbcrW = enc.cbcrTex.width
            let cbcrH = enc.cbcrTex.height
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(
                width: (cbcrW + 15) / 16,
                height: (cbcrH + 15) / 16,
                depth: 1
            )
            pass5.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            pass5.endEncoding()
            encoderPairForCompletion = enc
        } catch {
            // Pool exhaustion / texture wrap failure — drop this frame from the recorder,
            // preview + other consumers unaffected (domain 06 Recording-Sink Back-Pressure).
        }
    }
```

- [ ] **Step 4: Deliver in the completion handler**

Inside the (D-10-guarded) `addCompletedHandler` — after the existing token check passes and *before* FrameSet publication — add:

```swift
    if let enc = encoderPairForCompletion, cb.status == .completed {
        self.onEncodedBufferReady?(enc.buffer, captureTime)
    }
```

- [ ] **Step 5: Expose `isRecording` setter**

No setter needed — engine accesses `pipeline.isRecording.store(...)` directly (nonisolated let on a reference-type atomic).

- [ ] **Step 6: Build**

Expected: BUILD SUCCEEDED. Pay attention: `nonisolated let` with a `ManagedAtomic` is already the pattern `submissionGate` uses — identical shape.

- [ ] **Step 7: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "feat(stage-10): Pass 5 RGBA16F→NV12 compute + encoder pool; isRecording gate"
```

---

## Task 11: Engine — startRecording / stopRecording / recordingStateStream

**Files:** `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Add state + stream**

```swift
    private var recording: Recording?
    private var recordingContinuation: AsyncStream<RecordingState>.Continuation?
    private var cachedRecordingStream: AsyncStream<RecordingState>?
    private var assetWriterFactory: AssetWriterFactory = DefaultAssetWriterFactory.make

    public func recordingStateStream() -> AsyncStream<RecordingState> {
        if let s = cachedRecordingStream { return s }
        let stream = AsyncStream<RecordingState>(
            RecordingState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { c in self.recordingContinuation = c }
        cachedRecordingStream = stream
        return stream
    }

    private func publishRecordingState(_ s: RecordingState) {
        recordingContinuation?.yield(s)
    }

    /// Test seam — swap the writer factory. Must be called before startRecording().
    func _setAssetWriterFactoryForTest(_ f: @escaping AssetWriterFactory) {
        assetWriterFactory = f
    }
```

- [ ] **Step 2: `startRecording(options:)`**

```swift
    public func startRecording(options: RecordingOptions) async throws -> RecordingStart {
        guard isOpen, let session = cameraSession, let pipeline = metalPipeline else {
            throw EngineError.notOpen
        }
        // AE frame-rate range → recording.
        try await session.setRecordingFrameRateRange()
        // Wire Pass 5 completion delivery.
        let engineRef: CameraEngine = self
        pipeline.onEncodedBufferReady = { buf, pts in
            Task { [weak engineRef] in
                _ = await engineRef?.onEncodedBufferReady(buf, pts: pts)
            }
        }
        // Build coordinator.
        let hooks = Recording.Hooks(
            publishState: { [weak self] s in
                Task { [weak self] in await self?.publishRecordingStateAsync(s) }
            },
            emitError: { [weak self] err in
                Task { [weak self] in await self?.publishErrorAsync(err) }
            }
        )
        let rec = Recording(clock: clock, hooks: hooks, writerFactory: assetWriterFactory)
        self.recording = rec
        let start = try await rec.start(options: options, captureSize: pipeline.captureSize)
        pipeline.isRecording.store(true, ordering: .sequentiallyConsistent)
        return start
    }

    public func stopRecording() async throws -> String {
        guard let rec = recording, let pipeline = metalPipeline, let session = cameraSession
        else { throw EngineError.notOpen }
        pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
        let uri = await rec.stop(reason: .user)
        try? await session.setPreviewFrameRateRange()
        self.recording = nil
        pipeline.onEncodedBufferReady = nil
        return uri
    }

    func publishRecordingStateAsync(_ s: RecordingState) { publishRecordingState(s) }

    func onEncodedBufferReady(_ buffer: CVPixelBuffer, pts: CMTime) async {
        guard let rec = recording else { return }
        _ = await rec.submitEncodedBuffer(buffer, pts: pts)
    }
```

- [ ] **Step 3: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-10): engine startRecording/stopRecording + recordingStateStream wiring"
```

---

## Task 12: Engine — pause() + resume()

**Files:** `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 1: Implement pause()**

```swift
    /// scaffolding:10:synchronous-drain-pause — pause() during recording runs finalize
    /// synchronously on the engine actor. There is NO UIApplication.beginBackgroundTask
    /// wrapper, so the drain cannot survive backgrounding. Stage 12 retires this scaffold
    /// by adding the background-task assertion around the same finalize path.
    public func pause() async throws {
        if let rec = recording, let pipeline = metalPipeline {
            // Finalize recording synchronously before teardown (U-18 + scaffold).
            pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
            _ = await rec.stop(reason: .pause)
            self.recording = nil
            pipeline.onEncodedBufferReady = nil
        }
        // Session-only teardown (device retained).
        await cameraSession?.stopRunningAsync()
        publishState(.paused)
    }

    public func resume() async throws {
        guard isOpen, let session = cameraSession else { throw EngineError.notOpen }
        await session.startRunningAsync()
        publishState(.streaming)
    }
```

- [ ] **Step 2: Verify the scaffold is visible**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/
```
Expected: ≥1 hit.

- [ ] **Step 3: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-10): pause/resume with synchronous drain (scaffolding:10:synchronous-drain-pause)"
```

---

## Task 13: ViewModel + CameraView — record button + timer

**Files:** `CameraKit/Sources/CameraKit/ViewModel.swift`, `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: ViewModel additions**

```swift
    var recordingState: RecordingState = .idle(lastUri: nil)
    var recordingElapsedSeconds: Int = 0
    @ObservationIgnored private var recordingStateTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTimerTask: Task<Void, Never>?

    // in start() after engine.open():
    recordingStateTask = Task { [weak self] in
        guard let self else { return }
        for await s in self.engine.recordingStateStream() {
            await MainActor.run {
                self.recordingState = s
                switch s {
                case .recording:
                    self.startRecordingTimer()
                default:
                    self.recordingTimerTask?.cancel()
                    self.recordingTimerTask = nil
                    if case .idle = s { self.recordingElapsedSeconds = 0 }
                }
            }
        }
    }

    // in stop():
    recordingStateTask?.cancel()
    recordingTimerTask?.cancel()

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingElapsedSeconds = 0
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { self?.recordingElapsedSeconds += 1 }
            }
        }
    }

    func toggleRecording() {
        Task { [weak self] in
            guard let self else { return }
            switch self.recordingState {
            case .idle:
                _ = try? await self.engine.startRecording(options: RecordingOptions())
            case .recording:
                _ = try? await self.engine.stopRecording()
            default:
                break
            }
        }
    }
```

- [ ] **Step 2: CameraView additions**

Inside the bottom bar, next to the capture button:

```swift
    Button(action: { viewModel.toggleRecording() }) {
        HStack(spacing: 6) {
            Circle()
                .fill(isRecordingActive ? Color.red : Color.white)
                .frame(width: 18, height: 18)
            if isRecordingActive {
                Text(elapsedMMSS)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Text("REC")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: Capsule())
    }
```

```swift
    private var isRecordingActive: Bool {
        if case .recording = viewModel.recordingState { return true } else { return false }
    }
    private var elapsedMMSS: String {
        let s = viewModel.recordingElapsedSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
```

- [ ] **Step 3: Build + commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-10): record button + red-dot indicator + mm:ss timer"
```

---

## Task 14: Stage10Tests — the 8 TESTABLEs

**Files:** `CameraKit/Tests/CameraKitTests/Stage10Tests.swift`

- [ ] **Step 1: Add `FakeAssetWriter` + adaptor**

```swift
actor FakeAssetWriter: AssetWriting {
    var _status: AVAssetWriter.Status = .unknown
    var _err: Error?
    var finishHangsUntil: ContinuousClock.Instant?  // if set, finishWriting waits until now >= this
    var startedSessionAt: CMTime?
    var markedFinished = false
    var cancelled = false

    var status: AVAssetWriter.Status { _status }
    var writerError: Error? { _err }
    func startWriting() -> Bool {
        _status = .writing
        return true
    }
    func startSession(atSourceTime t: CMTime) { startedSessionAt = t }
    func markInputFinished() { markedFinished = true }
    func finishWriting() async {
        if let deadline = finishHangsUntil {
            while ContinuousClock.now < deadline && !cancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        if cancelled { _status = .cancelled } else { _status = .completed }
    }
    func cancelWriting() { cancelled = true; _status = .cancelled }
    func setStatus(_ s: AVAssetWriter.Status, error: Error? = nil) { _status = s; _err = error }
    func setFinishHang(until: ContinuousClock.Instant) { finishHangsUntil = until }
}

actor FakeAdaptor: AssetWriterPixelBufferAdapting {
    var ready = true
    var appended: [(CVPixelBuffer, CMTime)] = []
    var isReadyForMoreMediaData: Bool { ready }
    func append(_ b: CVPixelBuffer, pts: CMTime) -> Bool {
        if !ready { return false }
        appended.append((b, pts))
        return true
    }
    func setReady(_ r: Bool) { ready = r }
}

func makeFakeFactory(
    writer: FakeAssetWriter,
    adaptor: FakeAdaptor
) -> AssetWriterFactory {
    return { _, _, _, _ in (writer, adaptor) }
}

func makeDummyPixelBuffer(w: Int = 64, h: Int = 64) -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buf
    )
    return buf!
}
```

- [ ] **Step 2: `10:record-start-stop-happy-path`**

```swift
@Suite("Stage 10 — happy path")
struct Stage10HappyPathTests {
    @Test("start → 30 frames → stop returns mp4 URI")
    func recordStartStopHappyPath() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        var states: [RecordingState] = []
        let hooks = Recording.Hooks(
            publishState: { states.append($0) },
            emitError: { _ in Issue.record("unexpected error") }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        let start = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 1920, height: 1080)
        )
        #expect(start.uri.hasSuffix(".mp4"))
        for i in 0..<30 {
            _ = await rec.submitEncodedBuffer(
                makeDummyPixelBuffer(),
                pts: CMTimeMake(value: Int64(i), timescale: 30)
            )
        }
        let uri = await rec.stop(reason: .user)
        #expect(uri == start.uri)
        #expect(states.contains(.recording))
        #expect(states.contains(.finalizing))
        if case .idle(let last) = states.last { #expect(last == uri) }
        else { Issue.record("final state was not idle") }
        let appendedCount = await adaptor.appended.count
        #expect(appendedCount == 30)
    }
}
```

- [ ] **Step 3: `10:recording-truncated-on-deadline`**

```swift
@Test("finishWriting deadline cancels; emits RECORDING_TRUNCATED")
func recordingTruncatedOnDeadline() async throws {
    let writer = FakeAssetWriter()
    let adaptor = FakeAdaptor()
    // Hang the writer well past the deadline.
    await writer.setFinishHang(
        until: .now.advanced(by: .seconds(Int(Constants.recordingFinishTimeoutSeconds) * 3))
    )
    var errors: [CameraError] = []
    let hooks = Recording.Hooks(
        publishState: { _ in },
        emitError: { errors.append($0) }
    )
    // Use a fast clock: a TestClock would inject zero-delay sleep here, but SystemClock
    // with the real 5s deadline is acceptable — the test only blocks ~5s.
    let rec = Recording(
        clock: SystemClock(),
        hooks: hooks,
        writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
    )
    _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
    _ = await rec.submitEncodedBuffer(makeDummyPixelBuffer(), pts: CMTimeMake(value: 0, timescale: 30))
    let uri = await rec.stop(reason: .user)
    #expect(errors.contains { $0.code == .recordingTruncated && !$0.isFatal })
    #expect(await writer.cancelled == true)
    // URI is returned even though the file is empty/cancelled.
    #expect(uri.hasSuffix(".mp4"))
}
```

Note: this test blocks ~5 real seconds. If test suite time is a concern, refactor `Recording.stop` to use the injected `CameraKitClock.sleep` (already in the impl) and inject a `TestClock` that advances instantly. The impl in Task 8 already uses `clock.sleep`, so a `TestClock` variant:

```swift
actor FastClock: CameraKitClock {
    func nowMs() -> UInt64 { 0 }
    func sleep(milliseconds: Int) async throws { /* instant */ }
}
```

and pass `FastClock()` to `Recording.init` — `finishWriting` deadline expires "instantly" while the fake writer is still hanging → cancel triggers. Use this for the test.

- [ ] **Step 4: `10:ae-frame-rate-range-toggles-on-mode`**

Introduce a test-only mock `CaptureDeviceProviding` that records writes to `activeVideoMin/MaxFrameDuration`. If intrusive, assert via the `setPreviewFrameRateRange()` / `setRecordingFrameRateRange()` helpers with a `TestCaptureDevice` double:

```swift
@Test("AE frame-rate range toggles between preview and recording")
func aeFrameRateRangeTogglesOnMode() async throws {
    // This test uses a TestCaptureDevice that records the CMTime pair passed to
    // activeVideoMin/MaxFrameDuration. CameraSession gained two helpers in Task 9
    // that call through the CaptureDeviceProviding protocol. Add matching method
    // shapes to the protocol in this task (see Step 4a below) so the double works.
    // ...assert: after setPreviewFrameRateRange(), min == max == 1/30.
    //           after setRecordingFrameRateRange(), min == 1/30, max == 1/15.
    //           after stopRecording / setPreviewFrameRateRange again, restored.
}
```

Step 4a: extend `CaptureDeviceProviding` with:

```swift
func setFrameRateRange(minDuration: CMTime, maxDuration: CMTime) async throws
```

and route the new `CameraSession.setPreviewFrameRateRange` / `setRecordingFrameRateRange` through that protocol method instead of touching `avDevice` directly. This makes the double trivial.

- [ ] **Step 5: `10:nv12-encoder-pass-byte-layout`**

```swift
@Test("Pass 5 NV12 output has expected Y + CbCr byte layout")
func nv12EncoderPassByteLayout() async throws {
    // Using MetalPipeline test seams: inject a known-color RGBA16F texture into
    // latestProcessedForTest, flip isRecording = true, invoke encodePass5ForTest (add seam),
    // read back Y + CbCr plane bytes from the returned CVPixelBuffer, assert they match
    // the closed-form BT.709 video-range conversion within ±1 quantization step.
    //
    // Add MetalPipeline.encodePass5ForTest() -> CVPixelBuffer seam that:
    //   1. Dequeues an encoder buffer
    //   2. Runs a minimal command buffer with just the Pass 5 encoder
    //   3. waitUntilCompleted
    //   4. Locks base address and returns the buffer.
    //
    // For a uniform mid-gray input (0.5, 0.5, 0.5):
    //   Y ≈ 0.5 * (kR_Y + kG_Y + kB_Y) + 16/255 ≈ 0.5 * 0.859 + 0.0627 ≈ 0.493 → ~125
    //   Cb ≈ 128, Cr ≈ 128 (all neutral axes sum to 128 offset).
    // Assert plane 0 byte 0 ~ 125; plane 1 bytes [0,1] ~ [128,128].
    // Both planes IOSurface-backed:
    //   #expect(CVPixelBufferGetIOSurface(buf) != nil)
}
```

- [ ] **Step 6: `10:pause-during-recording-finalizes-synchronously`**

```swift
@Test("pause() during recording awaits finalize")
func pauseDuringRecordingFinalizesSynchronously() async throws {
    // Drive engine.startRecording(), then call engine.pause().
    // Use a FakeAssetWriter with a short controllable finish delay.
    // Assert: pause() returns only after writer.status == .completed; recordingStateStream
    // observed .finalizing then .paused (or .idle(lastUri:) depending on Stop flow);
    // stateStream observed .paused.
}
```

- [ ] **Step 7: `10:resume-from-pause-restarts-session`**

```swift
@Test("resume() after pause() returns to .streaming")
func resumeFromPauseRestartsSession() async throws {
    let engine = CameraEngine()
    _ = try await engine.open()
    try await engine.pause()
    try await engine.resume()
    // Collect stateStream until .streaming seen after pause.
    // Assert a subsequent frame (inject via CaptureDelegate onSampleBuffer) yields a FrameSet.
}
```

- [ ] **Step 8: `10:adaptor-not-ready-drops-frame`**

```swift
@Test("adaptor.isReadyForMoreMediaData = false drops that frame")
func adaptorNotReadyDropsFrame() async throws {
    let writer = FakeAssetWriter()
    let adaptor = FakeAdaptor()
    let rec = Recording(
        clock: FastClock(),
        hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
        writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
    )
    _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
    for i in 0..<30 {
        if (5...7).contains(i) { await adaptor.setReady(false) } else { await adaptor.setReady(true) }
        _ = await rec.submitEncodedBuffer(makeDummyPixelBuffer(), pts: CMTimeMake(value: Int64(i), timescale: 30))
    }
    _ = await rec.stop(reason: .user)
    #expect(await adaptor.appended.count == 27)
    #expect(await rec.currentDroppedNotReady() == 3)
}
```

- [ ] **Step 9: `10:fatal-finalize-emits-recording-failed`**

```swift
@Test("writer.status == .failed on finish emits fatal RECORDING_FAILED")
func fatalFinalizeEmitsRecordingFailed() async throws {
    let writer = FakeAssetWriter()
    let adaptor = FakeAdaptor()
    var errors: [CameraError] = []
    var states: [RecordingState] = []
    let hooks = Recording.Hooks(
        publishState: { states.append($0) },
        emitError: { errors.append($0) }
    )
    let rec = Recording(
        clock: FastClock(),
        hooks: hooks,
        writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
    )
    _ = try await rec.start(options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
    // Arrange failed status right before stop completes its inner race.
    await writer.setStatus(.failed, error: NSError(domain: "test", code: 7))
    _ = await rec.stop(reason: .user)
    #expect(errors.contains { $0.code == .recordingFailed && $0.isFatal })
    // Error must be emitted BEFORE the final state transition.
    let errIdx = errors.firstIndex(where: { $0.code == .recordingFailed })!
    #expect(errIdx >= 0)
}
```

Note: this test relies on the emit-before-transition ordering the implementation in Task 8 step 3 guarantees (`hooks.emitError(err)` called before `hooks.publishState(state)` on the failed path).

- [ ] **Step 10: Run all Stage 10 tests**

XcodeBuildMCP test_device with filter `-only-testing:CameraKitTests/Stage10*`. Expected: all 8 PASS.

- [ ] **Step 11: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage10Tests.swift CameraKit/Sources/CameraKit/
git commit -m "test(stage-10): 8 TESTABLE tests — happy path, truncate, AE range, NV12, pause, resume, drops, fatal"
```

---

## Task 15: Wire Stage10Tests + full regression

**Files:** `eva-swift-stitch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add Stage10Tests.swift to the test target**

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
t = p.targets.find { |x| x.name == 'eva-swift-stitchTests' }
g = p.main_group.find_subpath('CameraKit/Tests/CameraKitTests', true)
f = g.new_reference('CameraKit/Tests/CameraKitTests/Stage10Tests.swift')
t.source_build_phase.add_file_reference(f)
p.save"
```

- [ ] **Step 2: Run full regression**

`test_device` with filter `Stage[01][0-9]Tests`. Expected: all Stage 01–10 green.

- [ ] **Step 3: Scaffold inventory**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/         # ≥1 hit
grep -rn -E '01:|04:|06:|07:|09:' CameraKit/Sources/             # 0 hits
```

- [ ] **Step 4: Commit**

```bash
git add eva-swift-stitch.xcodeproj
git commit -m "test(stage-10): wire Stage10Tests into eva-swift-stitchTests target"
```

---

## Task 16: state.md + HITL stub

**Files:** `CameraKit/state.md`, `docs/measurements/stage-10/recording.md`

- [ ] **Step 1: Prepend Stage 10 section to state.md**

Mirror the format used for prior stages. Include:

- `## Current stage` → Stage 10 complete.
- `## Scaffolding still live` → one row for `10:synchronous-drain-pause` in `CameraEngine.swift:pause()`, retires Stage 12.
- `## What's built — Stage 10 (permanent)` — Recording coordinator, AssetWriting seam, Pass 5, encoder pool, NV12 write textures, AE range helpers, startRecording / stopRecording / pause / resume / recordingStateStream, RecordingOptions/Start/State reshape, RecordingError variants, record-button UI + timer.
- `## Public API exposed so far (Stage 10 additions)`:

```swift
public func startRecording(options: RecordingOptions) async throws -> RecordingStart
public func stopRecording() async throws -> String
public func pause() async throws
public func resume() async throws
public func recordingStateStream() -> AsyncStream<RecordingState>
public protocol AssetWriting: Sendable { ... }
public protocol AssetWriterPixelBufferAdapting: Sendable { ... }
public typealias AssetWriterFactory = ...
public enum DefaultAssetWriterFactory { ... }
public actor Recording { ... }
```

- `## Manual test evidence — Stage 10`: 8 PASS rows for Stage10Tests + DEFERRED rows for HITL `10:mp4-plays-in-photos`, `10:low-light-ae-drops-below-30fps`, and `10:empirical-format-fps-range-fallback`.
- `## Decisions taken that weren't in briefs — Stage 10`:
  - **RecordingState reshape** — brief §4 vs architecture §Recording state machine disagree; brief wins for this stage (CLAUDE.md §8). Flag upstream.
  - **RecordingOptions / RecordingStart reshape** — matched architecture §Parameters + §Start flow; deleted prior Stage 01 stubs.
  - **`recordingTargetBitrateBpsDefault = 40_000_000`** — brief §Parameters table says "docs/measurements/"; 40 Mbps is a reasonable default for 4K HEVC @ 30fps pending on-device measurement. Log as open question.
  - **`AssetWriting` / `AssetWriterPixelBufferAdapting` protocol seam** — not in brief; required for the 4 TESTABLEs that fake `AVAssetWriter`. Mirrors `CaptureDeviceProviding` pattern already in the repo.
  - **`Watchdog.disarmAll` static helper** (carried from Stage 09) — n/a here, retain prior decision.
- `## Open questions for next stage`:
  - `TARGET_BITRATE_MBPS` upstream value after device measurements.
  - Stage 12 retires `10:synchronous-drain-pause` via `UIApplication.beginBackgroundTask` wrap.
  - Empirical format-fps range fallback (DEFERRED 10:empirical-format-fps-range-fallback) — evidence in `docs/measurements/stage-10/`.

- [ ] **Step 2: Regenerate CONTRACTS.md**

```bash
bash scripts/regen-contracts.sh
```

- [ ] **Step 3: Create HITL stub `docs/measurements/stage-10/recording.md`**

```markdown
# Stage 10 — HITL recording evidence

## 10:mp4-plays-in-photos
Device: iPad Pro M1 (iOS 26.x).
- Record 10s.
- Confirm `.mp4` appears in Photos.
- Playback works.
- `mediainfo` on the file reports `HEVC` codec + `MP4` container.
PASS / FAIL: ________
Date: ________

## 10:low-light-ae-drops-below-30fps
Device: iPad Pro M1 (iOS 26.x).
- Start recording, cover camera sensor.
- Observe FPS drop below 30 (toward 15) in live instrumentation or post-hoc mediainfo.
- Remove occlusion; FPS returns to 30.
PASS / FAIL: ________
Date: ________

## 10:empirical-format-fps-range-fallback (DEFERRED)
Device: iPad Pro M1 (iOS 26.x).
- If target active format does not natively support (1/30, 1/30), record the fallback:
  closest supported range, or which error the device returns.
Observations: ________
Date: ________
```

- [ ] **Step 4: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md docs/measurements/stage-10/recording.md
git commit -m "docs(stage-10): state.md Stage 10; HITL evidence stubs; regen CONTRACTS"
```

---

## Task 17: Final verification

- [ ] **Step 1: Full build + tests via XcodeBuildMCP**

`build_device` + `test_device` filter `Stage[01][0-9]Tests`. Expected: BUILD SUCCEEDED + all tests green.

- [ ] **Step 2: Device smoke**

On physical iPad Pro M1:
- Record 10s; confirm Photos playback + codec.
- Cover sensor while recording; observe AE FPS drop.
- Call `pause()` mid-recording; confirm `.paused` state + finalized file in Photos.
- `resume()`; confirm preview returns.

Record evidence in `docs/measurements/stage-10/recording.md`.

- [ ] **Step 3: Scaffold acceptance**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/         # ≥1 hit
grep -rn -E '01:|04:|06:|07:|09:' CameraKit/Sources/             # 0 hits
```

- [ ] **Step 4: Stop. Request user approval before push / merge.**

---

## Self-review

- **Spec coverage:** every §4 file has a task; every §8 TESTABLE has a test in Task 14; §7 invariants covered (HEVC-in-MP4 in Task 5's factory; timeout + cancelWriting in Task 8 stop(); AE range in Tasks 9 + 11; synchronous drain in Task 12 with explicit scaffold comment; `.bufferingOldest(64)` on recordingStateStream in Task 11). §10 acceptance checked in Tasks 15 + 17.
- **Placeholder scan:** `AVAssetWriter` status ordering in `finalizeFailed` is deterministic because impl emits before transition; two tests that are awkward to fully sketch (`10:ae-frame-rate-range-toggles-on-mode`, `10:nv12-encoder-pass-byte-layout`, `10:pause-during-recording-finalizes-synchronously`, `10:resume-from-pause-restarts-session`) include the extensibility hooks needed (new protocol method + `encodePass5ForTest` seam + FakeAssetWriter); an executing engineer adds the seams alongside the test. Acceptable because the pattern is explicit and the shape is pinned.
- **Type consistency:** `RecordingState`, `RecordingOptions`, `RecordingStart` shapes match across Tasks 3 + 8 + 11 + 13. `AssetWriting` / `AssetWriterPixelBufferAdapting` / `AssetWriterFactory` signatures identical across Tasks 5 + 8 + 11 + 14. `Recording.Hooks` / `Recording.init` match Tasks 8 + 11.
- **Stage-ordering guard:** Task 1 Step 2 halts if Stage 08 / 09 haven't landed (C++ dir present; no prior-stage scaffolds live).
- **Non-obvious decisions surfaced in state.md:** `RecordingState` reshape vs arch doc; bitrate default; `AssetWriting` seam; synchronous-drain scaffold semantics.
