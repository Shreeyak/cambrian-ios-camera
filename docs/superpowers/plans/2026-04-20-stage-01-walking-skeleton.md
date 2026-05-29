# Stage 01 — Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a live camera preview that fills the screen on app launch — a bare natural (unprocessed) preview with an empty bottom bar; no color processing, no recording, no controls wired.

**Architecture:** The `CameraKit` Swift Package is created as a subdirectory `CameraKit/` alongside the existing `.xcodeproj`. It contains a `CameraEngine` actor that drives `AVCaptureSession` on a dedicated `sessionQueue`, passes frames to a Metal passthrough pipeline on the `delivery` queue, and publishes state via `AsyncStream`. A SwiftUI `CameraView` wraps a `UIViewRepresentable<MTKView>` and a `@Observable @MainActor` ViewModel. The xcodeproj stays as the app host; it adds `CameraKit/` as a local Swift Package dependency.

**Tech Stack:** Swift 6 strict concurrency, AVFoundation (`AVCaptureSession`, `AVCaptureVideoDataOutput`), Metal (`MTLCommandBuffer`, `CVMetalTextureCache`), MetalKit (`MTKView`), swift-testing unit tests.

---

## Directory shape

```
eva-swift-stitch/                          # repo root — xcodeproj stays here
├── eva-swift-stitch.xcodeproj             # app host — unchanged except local pkg ref
├── eva-swift-stitch/                      # app target sources
│   ├── eva_swift_stitchApp.swift          # import CameraKit; WindowGroup { CameraView(...) }
│   └── (delete ContentView.swift + CameraCapabilitiesReporter.swift)
├── CameraKit/                             # NEW — local Swift package
│   ├── Package.swift
│   ├── Sources/CameraKit/                 # 17 files listed below
│   └── Tests/CameraKitTests/
│       └── Stage01Tests.swift
```

`Info.plist`, `NSCameraUsageDescription`, entitlements, and signing all stay in the Xcode project — never in the package.

---

## File Map

Files to **create**:

| Path | Responsibility |
|---|---|
| `CameraKit/Package.swift` | SwiftPM manifest — `CameraKit` library + `CameraKitTests` test target |
| `CameraKit/Sources/CameraKit/Constants.swift` | Load-bearing numeric constants from `constants.md` |
| `CameraKit/Sources/CameraKit/SessionState.swift` | `SessionState`, `RecordingState`, `StreamId` enums |
| `CameraKit/Sources/CameraKit/Errors.swift` | `EngineError`, `MetalError`, `InteropError`, `RecordingError`, `CameraError`, `ErrorCode` |
| `CameraKit/Sources/CameraKit/Capabilities.swift` | `OpenConfiguration`, `SessionCapabilities`, `Size`, `Rect` |
| `CameraKit/Sources/CameraKit/FrameSet.swift` | `FrameSet` struct stub + associated metadata types |
| `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` | Protocol seam (ADR-32) + `DeviceStateSnapshot`, `WhiteBalanceGains`, etc. |
| `CameraKit/Sources/CameraKit/PixelSink.swift` | `ConsumerRegistry` stub + `ConsumerToken`, `PixelSinkCallbacks` |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | Single IOSurface-backed `naturalTex` via `CVMetalTextureCache` (scaffolding:01:simple-metal-passthrough) |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | Pass-1 YUV→RGBA compute + blit to MTKView (scaffolding:01:simple-metal-passthrough) |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | `nonisolated` `AVCaptureVideoDataOutputSampleBufferDelegate` on `delivery` queue |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | `AVCaptureSession` config: device selection, format selection, orientation, output wiring |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | `actor CameraEngine` — `init`, `open`, `close`, `stateStream` only |
| `CameraKit/Sources/CameraKit/CameraView.swift` | SwiftUI root + `UIViewRepresentable<MTKView>` + empty bottom bar |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | `@Observable @MainActor` ViewModel — `bind(engine:)`, scenePhase stop (scaffolding:01:naive-scenephase-stop) |
| `CameraKit/Sources/CameraKit/RealCaptureDeviceProvider.swift` | Production `CaptureDeviceProviding` wrapping `AVCaptureDevice` |
| `CameraKit/Sources/CameraKit/Shaders.metal` | YUV→RGBA compute kernel (`yuvToRgba`) |
| `CameraKit/Tests/CameraKitTests/Stage01Tests.swift` | Unit tests: device seam, format selection, rotation constant |

Files to **modify**:

| Path | Change |
|---|---|
| `eva-swift-stitch/eva_swift_stitchApp.swift` | `import CameraKit`; set `CameraView` as root |
| `eva-swift-stitch.xcodeproj/project.pbxproj` | Add local `CameraKit/` package dependency via Xcode UI |

Files to **delete**:

| Path | Reason |
|---|---|
| `eva-swift-stitch/ContentView.swift` | Replaced by `CameraKit.CameraView` |
| `eva-swift-stitch/CameraCapabilitiesReporter.swift` | Diagnostic; no longer needed |

---

## Task 1: Package.swift + value types

**Files:**
- Create: `CameraKit/Package.swift`
- Create: `CameraKit/Sources/CameraKit/Constants.swift`
- Create: `CameraKit/Sources/CameraKit/SessionState.swift`
- Create: `CameraKit/Sources/CameraKit/Errors.swift`
- Create: `CameraKit/Sources/CameraKit/Capabilities.swift`
- Create: `CameraKit/Sources/CameraKit/FrameSet.swift`

- [ ] **Step 1.1: Create the CameraKit directory**

```bash
mkdir -p CameraKit/Sources/CameraKit CameraKit/Tests/CameraKitTests
```

- [ ] **Step 1.2: Write CameraKit/Package.swift**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
    ],
    targets: [
        .target(
            name: "CameraKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: ["CameraKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
```

- [ ] **Step 1.3: Write CameraKit/Sources/CameraKit/Constants.swift**

```swift
import Metal
import CoreVideo

enum Constants {
    static let frameRateTargetFPS: Int = 30
    static let capturePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    static let captureDefaultWidthPx: Int = 4160
    static let captureDefaultHeightPx: Int = 3120
    static let captureFallbackWidthPx: Int = 1280
    static let captureFallbackHeightPx: Int = 960
    static let cropDefaultWidthPx: Int = 1600
    static let cropDefaultHeightPx: Int = 1200
    static let captureOrientationAngleDeg: CGFloat = 90
    static let stateStreamBufferSize: Int = 64
}
```

- [ ] **Step 1.4: Write CameraKit/Sources/CameraKit/SessionState.swift**

Transplant verbatim from `implementation/architecture/api-skeletons/Sources/CameraKit/SessionState.swift`:

```swift
import Foundation

public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
}

public enum RecordingState: String, Sendable, Hashable {
    case idle
    case preparing
    case recording
    case stopping
}

public enum StreamId: String, Sendable, Hashable, CaseIterable {
    case natural
    case processed
    case tracker
}
```

- [ ] **Step 1.5: Write CameraKit/Sources/CameraKit/Errors.swift**

Transplant from skeleton verbatim — all `ErrorCode`, `CameraError`, `EngineError`, `MetalError`, `InteropError`, `RecordingError`. File content is identical to `implementation/architecture/api-skeletons/Sources/CameraKit/Errors.swift`.

- [ ] **Step 1.6: Write CameraKit/Sources/CameraKit/Capabilities.swift**

Transplant from skeleton verbatim — `SessionCapabilities`, `Size`, `Rect`, `OpenConfiguration`. Identical to `implementation/architecture/api-skeletons/Sources/CameraKit/Capabilities.swift`.

- [ ] **Step 1.7: Write CameraKit/Sources/CameraKit/FrameSet.swift**

Transplant from skeleton verbatim — `FrameSet`, `TrackerQuality`, `CaptureMetadata`, `ProcessingMetadata`, `WhiteBalanceGains`, `CameraPosition`, `FrameDeliveryStats`. Identical to `implementation/architecture/api-skeletons/Sources/CameraKit/FrameSet.swift`.

- [ ] **Step 1.8: Verify the package parses**

```bash
swift package dump-package --package-path CameraKit/
```
Expected: prints the package JSON without errors.

- [ ] **Step 1.9: Commit**

```bash
git add CameraKit/
git commit -m "stage-01: CameraKit package skeleton + value types (SessionState, Errors, Capabilities, FrameSet)"
```

---

## Task 2: Protocol seams + ConsumerRegistry stub

**Files:**
- Create: `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift`
- Create: `CameraKit/Sources/CameraKit/PixelSink.swift`

- [ ] **Step 2.1: Write CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift**

The skeleton's `CaptureDeviceProviding.swift` doesn't include `WhiteBalanceMode`, `CameraMode` (used by `CaptureMetadata` in `FrameSet.swift`) or the two Stage-01-specific additions (`availableFormats`, `makeDeviceInput`). Define all of them here.

```swift
import Foundation
import AVFoundation

public enum WhiteBalanceMode: String, Sendable, Hashable {
    case auto
    case locked
    case manual
}

public enum CameraMode: String, Sendable, Hashable {
    case auto
    case manual
}

public enum SystemPressureLevel: String, Sendable, Hashable {
    case nominal
    case fair
    case serious
    case critical
    case shutdown
}

public struct DeviceStateSnapshot: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let lensPosition: Float
    public let whiteBalanceGains: WhiteBalanceGains
    public let isAdjustingExposure: Bool
    public let systemPressureLevel: SystemPressureLevel

    public init(
        iso: Float,
        exposureDurationNs: Int64,
        lensPosition: Float,
        whiteBalanceGains: WhiteBalanceGains,
        isAdjustingExposure: Bool,
        systemPressureLevel: SystemPressureLevel
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.lensPosition = lensPosition
        self.whiteBalanceGains = whiteBalanceGains
        self.isAdjustingExposure = isAdjustingExposure
        self.systemPressureLevel = systemPressureLevel
    }
}

public protocol CaptureDeviceProviding: AnyObject, Sendable {
    var uniqueID: String { get async }
    var activeFormatSize: Size { get async }
    var supportedSizes: [Size] { get async }
    var isoRange: ClosedRange<Float> { get async }
    var exposureDurationRangeNs: ClosedRange<Int64> { get async }
    var maxWhiteBalanceGain: Float { get async }

    /// Enumerate capture formats: (width, height, maxFPS, pixelFormat).
    /// Fake implementations return canned values; production wraps AVCaptureDevice.formats.
    var availableFormats: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] { get async }

    /// Return an AVCaptureDeviceInput for attaching to AVCaptureSession.
    /// Fakes throw EngineError.noBackCamera to signal "not for use in unit tests".
    func makeDeviceInput() throws -> AVCaptureDeviceInput

    func lockForConfiguration() async throws
    func unlockForConfiguration() async

    func setExposureModeCustom(durationNs: Int64, iso: Float) async throws
    func setContinuousAutoExposure() async throws

    func setFocusModeLocked(lensPosition: Float) async throws
    func setContinuousAutoFocus() async throws

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) async throws
    func setContinuousAutoWhiteBalance() async throws
    func setWhiteBalanceLocked() async throws

    func setZoomFactor(_ factor: Double) async throws
    func setExposureCompensation(_ steps: Int) async throws

    func setVideoFrameDurationRange(
        minFrameDurationFps: Int,
        maxFrameDurationFps: Int
    ) async throws
}
```

- [ ] **Step 2.2: Write CameraKit/Sources/CameraKit/PixelSink.swift**

Transplant from skeleton verbatim — `PixelSinkCallbacks`, `ConsumerRegistry` (all methods `fatalError("Stage 08")`), `ConsumerToken`. Identical to `implementation/architecture/api-skeletons/Sources/CameraKit/PixelSink.swift`.

- [ ] **Step 2.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift \
  CameraKit/Sources/CameraKit/PixelSink.swift
git commit -m "stage-01: CaptureDeviceProviding protocol seam + ConsumerRegistry stub"
```

---

## Task 3: TexturePoolManager + Metal shader

**Files:**
- Create: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`
- Create: `CameraKit/Sources/CameraKit/Shaders.metal`

- [ ] **Step 3.1: Write CameraKit/Sources/CameraKit/Shaders.metal**

Pass-1 compute kernel: center-crop from YUV biplanar capture buffer, convert to RGBA16F.

```metal
#include <metal_stdlib>
using namespace metal;

// BT.709 full-range YUV→RGB matrix
constant float3x3 kYuvToRgb = float3x3(
    float3(1.0,     1.0,      1.0   ),
    float3(0.0,    -0.18732,  1.8556),
    float3(1.5748, -0.46812,  0.0   )
);

struct CropUniforms {
    uint2 srcOffset;  // top-left pixel of crop region in source
    uint2 cropSize;   // width, height of crop region
};

kernel void yuvToRgba(
    texture2d<float, access::sample> yTex     [[texture(0)]],
    texture2d<float, access::sample> cbcrTex  [[texture(1)]],
    texture2d<float, access::write>  outTex   [[texture(2)]],
    constant CropUniforms&           uniforms [[buffer(0)]],
    uint2                            gid      [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.cropSize.x || gid.y >= uniforms.cropSize.y) return;

    constexpr sampler s(coord::pixel, filter::nearest);

    uint2 srcPx   = gid + uniforms.srcOffset;
    float  y      = yTex.sample(s, float2(srcPx)).r;
    float2 cbcr   = cbcrTex.sample(s, float2(srcPx / 2)).rg;

    float3 yuv = float3(y, cbcr.r - 0.5, cbcr.g - 0.5);
    float3 rgb = clamp(kYuvToRgb * yuv, 0.0, 1.0);

    outTex.write(float4(rgb, 1.0), gid);
}
```

- [ ] **Step 3.2: Write CameraKit/Sources/CameraKit/TexturePoolManager.swift**

Single IOSurface-backed `CVPixelBuffer` for the natural texture + `CVMetalTextureCache`.

```swift
// scaffolding:01:simple-metal-passthrough
import Metal
import CoreVideo

final class TexturePoolManager: @unchecked Sendable {
    private(set) var textureCache: CVMetalTextureCache?
    private(set) var naturalTexture: MTLTexture?
    private var naturalBuffer: CVPixelBuffer?

    init(device: MTLDevice, width: Int, height: Int) throws {
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw EngineError.metal(.textureCacheCreateFailed(code: cacheStatus))
        }
        textureCache = cache

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buf: CVPixelBuffer?
        let bufStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_64RGBAHalf,
            attrs as CFDictionary, &buf
        )
        guard bufStatus == kCVReturnSuccess, let buf else {
            throw EngineError.metal(.textureWrapFailed(code: bufStatus))
        }
        naturalBuffer = buf

        var cvTex: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buf, nil, .rgba16Float, width, height, 0, &cvTex
        )
        guard texStatus == kCVReturnSuccess, let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex) else {
            throw EngineError.metal(.textureWrapFailed(code: texStatus))
        }
        naturalTexture = tex
    }

    func invalidate() {
        naturalTexture = nil
        naturalBuffer = nil
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
        textureCache = nil
    }
}
```

- [ ] **Step 3.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/TexturePoolManager.swift \
  CameraKit/Sources/CameraKit/Shaders.metal
git commit -m "stage-01: TexturePoolManager (CVMetalTextureCache + IOSurface naturalTex) + YUV→RGBA shader"
```

---

## Task 4: MetalPipeline (Pass-1 scaffolding)

**Files:**
- Create: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

- [ ] **Step 4.1: Write CameraKit/Sources/CameraKit/MetalPipeline.swift**

Pass-1 (crop + YUV→RGBA) + Pass-3 (blit naturalTex → MTKView drawable). No Pass 2/4/5/6.
Completion handler does NOT gate on `sessionState` — scaffold tag `01:skip-completion-guard`.

```swift
// scaffolding:01:simple-metal-passthrough
import Metal
import MetalKit
import CoreVideo
import CoreMedia

final class MetalPipeline: @unchecked Sendable {
    private let commandQueue: MTLCommandQueue
    private let yuvToRgbaPSO: MTLComputePipelineState
    let poolManager: TexturePoolManager   // internal: CameraEngine reads textureCache
    private weak var mtkView: MTKView?

    private let cropWidth: Int
    private let cropHeight: Int

    init(device: MTLDevice, mtkView: MTKView) throws {
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.metal(.commandBufferFailed(code: -1))
        }
        commandQueue = queue
        self.mtkView = mtkView
        cropWidth  = Constants.cropDefaultWidthPx
        cropHeight = Constants.cropDefaultHeightPx

        poolManager = try TexturePoolManager(device: device, width: cropWidth, height: cropHeight)

        guard let lib = device.makeDefaultLibrary(),
              let fn  = lib.makeFunction(name: "yuvToRgba") else {
            throw EngineError.metal(.pipelineStateCompilation("yuvToRgba not found in default library"))
        }
        yuvToRgbaPSO = try device.makeComputePipelineState(function: fn)

        mtkView.device = device
        mtkView.colorPixelFormat = .rgba16Float
        mtkView.framebufferOnly  = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
    }

    var textureCache: CVMetalTextureCache? { poolManager.textureCache }

    // Called nonisolated on the delivery queue per ADR-10.
    // scaffolding:01:skip-completion-guard — completion handler has no sessionState gate
    func encodeFrame(sampleBuffer: CMSampleBuffer, textureCache: CVMetalTextureCache) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cb = commandQueue.makeCommandBuffer() else { return }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)

        var yRef: CVMetalTexture?, cbcrRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, srcW, srcH, 0, &yRef
        )
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, srcW / 2, srcH / 2, 1, &cbcrRef
        )
        guard let yRef, let cbcrRef,
              let yTex    = CVMetalTextureGetTexture(yRef),
              let cbcrTex = CVMetalTextureGetTexture(cbcrRef),
              let outTex  = poolManager.naturalTexture else { return }

        // Pass 1 — YUV → RGBA compute
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.pushDebugGroup("pass1.yuvToRgba")
        enc.setComputePipelineState(yuvToRgbaPSO)
        enc.setTexture(yTex,    index: 0)
        enc.setTexture(cbcrTex, index: 1)
        enc.setTexture(outTex,  index: 2)

        struct CropUniforms { var srcOffset: SIMD2<UInt32>; var cropSize: SIMD2<UInt32> }
        var u = CropUniforms(
            srcOffset: SIMD2(UInt32((srcW - cropWidth) / 2), UInt32((srcH - cropHeight) / 2)),
            cropSize:  SIMD2(UInt32(cropWidth), UInt32(cropHeight))
        )
        enc.setBytes(&u, length: MemoryLayout<CropUniforms>.stride, index: 0)
        enc.dispatchThreadgroups(
            MTLSize(width: (cropWidth + 15) / 16, height: (cropHeight + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        enc.popDebugGroup()
        enc.endEncoding()

        // Pass 3 — blit naturalTex → MTKView drawable
        if let view = mtkView, let drawable = view.currentDrawable {
            guard let blit = cb.makeBlitCommandEncoder() else { cb.commit(); return }
            blit.pushDebugGroup("pass3.naturalBlit")
            blit.copy(from: outTex, to: drawable.texture)
            blit.popDebugGroup()
            blit.endEncoding()
            cb.present(drawable)
        }

        cb.commit()
    }

    func teardown() { poolManager.invalidate() }
}
```

- [ ] **Step 4.2: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "stage-01: MetalPipeline Pass-1 YUV→RGBA + Pass-3 blit scaffold"
```

---

## Task 5: CaptureDelegate + CameraSession

**Files:**
- Create: `CameraKit/Sources/CameraKit/CaptureDelegate.swift`
- Create: `CameraKit/Sources/CameraKit/CameraSession.swift`

- [ ] **Step 5.1: Write CameraKit/Sources/CameraKit/CaptureDelegate.swift**

`nonisolated` delegate on `delivery` queue per ADR-07. Encodes Metal command buffer inline per ADR-10.

```swift
import AVFoundation
import CoreMedia

// nonisolated + @unchecked Sendable per ADR-07 §Swift 6 delegate class declaration
final class CaptureDelegate: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let pipeline: MetalPipeline
    private let textureCache: CVMetalTextureCache

    init(pipeline: MetalPipeline, textureCache: CVMetalTextureCache) {
        self.pipeline = pipeline
        self.textureCache = textureCache
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        pipeline.encodeFrame(sampleBuffer: sampleBuffer, textureCache: textureCache)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // drop-on-busy: no action needed at Stage 01
    }
}
```

- [ ] **Step 5.2: Write CameraKit/Sources/CameraKit/CameraSession.swift**

`AVCaptureSession` configured on `sessionQueue`. Implements D-08 device selection, G-17 format selection (largest 4:3 8-bit YUV at 30fps), ADR-17 orientation, and output wiring. `selectFormat` is `internal` so unit tests can call it directly.

```swift
import AVFoundation
import CoreMedia

// Driven on sessionQueue per ADR-07. Never mutated from the engine actor directly.
final class CameraSession: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let device: any CaptureDeviceProviding
    private(set) var activeWidth: Int = 0
    private(set) var activeHeight: Int = 0

    init(device: any CaptureDeviceProviding) {
        self.device = device
    }

    // Must be called on sessionQueue.
    func configure(deliveryQueue: DispatchQueue, delegate: CaptureDelegate) async throws -> (width: Int, height: Int) {
        // Permission check per 03-camera-session.md §Permission flow
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied, .restricted:
            throw EngineError.cameraDenied
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw EngineError.cameraDenied
            }
        case .authorized:
            break
        @unknown default:
            throw EngineError.cameraDenied
        }

        let input = try device.makeDeviceInput()
        guard session.canAddInput(input) else {
            throw EngineError.noSupportedFormat(reason: "cannot add device input")
        }

        let formats = await device.availableFormats
        let selected = Self.selectFormat(from: formats)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: selected.pixelFormat]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: deliveryQueue)

        guard session.canAddOutput(output) else {
            throw EngineError.noSupportedFormat(reason: "cannot add video data output")
        }
        session.addOutput(output)

        // Orientation per ADR-17
        if let connection = output.connection(with: .video) {
            let angle = Constants.captureOrientationAngleDeg
            guard connection.isVideoRotationAngleSupported(angle) else {
                throw EngineError.noSupportedFormat(reason: "rotation \(angle)° not supported")
            }
            connection.videoRotationAngle = angle
        }

        activeWidth  = selected.width
        activeHeight = selected.height
        return (selected.width, selected.height)
    }

    func start()    { session.startRunning() }
    func stop()     { session.stopRunning() }

    func teardown() {
        session.beginConfiguration()
        session.inputs.forEach  { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    // Format selection per 03-camera-session.md §Format selection.
    // Internal so Stage01Tests can call it without AVFoundation hardware.
    static func selectFormat(
        from formats: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)]
    ) -> (width: Int, height: Int, maxFPS: Double, pixelFormat: OSType) {
        let yuv8 = formats.filter {
            $0.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            $0.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let fps30 = yuv8.filter { $0.maxFPS >= Double(Constants.frameRateTargetFPS) }
        let fourByThree = fps30
            .filter  { $0.width * 3 == $0.height * 4 }
            .sorted  { $0.width * $0.height > $1.width * $1.height }

        if let best = fourByThree.first { return best }

        // Fallback: no 4:3 format found
        return (
            width: Constants.captureFallbackWidthPx,
            height: Constants.captureFallbackHeightPx,
            maxFPS: Double(Constants.frameRateTargetFPS),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
    }
}
```

- [ ] **Step 5.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CaptureDelegate.swift \
  CameraKit/Sources/CameraKit/CameraSession.swift
git commit -m "stage-01: CaptureDelegate (delivery queue) + CameraSession (format selection, orientation)"
```

---

## Task 6: CameraEngine actor

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraEngine.swift`

- [ ] **Step 6.1: Write CameraKit/Sources/CameraKit/CameraEngine.swift**

`actor CameraEngine` — only `init`, `open`, `close`, `stateStream` implemented. All future-stage methods are `fatalError("Stage N")` stubs.

```swift
import Metal
import MetalKit
import AVFoundation

public actor CameraEngine {
    private let deviceProvider: any CaptureDeviceProviding
    private let consumers: ConsumerRegistry

    private var sessionState: SessionState = .closed
    private var stateStreamContinuation: AsyncStream<SessionState>.Continuation?

    // Serial queues per ADR-07
    private let sessionQueue  = DispatchQueue(label: "camera.session",  qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "camera.delivery", qos: .userInitiated)

    private var cameraSession:  CameraSession?
    private var metalPipeline:  MetalPipeline?
    private var captureDelegate: CaptureDelegate?

    private weak var mtkView: MTKView?

    public init(device: any CaptureDeviceProviding, consumers: ConsumerRegistry) {
        self.deviceProvider = device
        self.consumers = consumers
    }

    public func bindMTKView(_ view: MTKView) {
        mtkView = view
    }

    public func open(configuration: OpenConfiguration) async throws -> SessionCapabilities {
        guard sessionState == .closed else { throw EngineError.alreadyOpen }
        emit(.opening)

        guard let view = mtkView else {
            emit(.closed)
            throw EngineError.noSupportedFormat(reason: "MTKView not bound before open()")
        }
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            emit(.closed)
            throw EngineError.metal(.commandBufferFailed(code: -1))
        }

        let pipeline: MetalPipeline
        do { pipeline = try MetalPipeline(device: metalDevice, mtkView: view) }
        catch { emit(.closed); throw error }

        guard let cache = pipeline.textureCache else {
            emit(.closed); throw EngineError.metal(.textureCacheCreateFailed(code: -1))
        }

        let session  = CameraSession(device: deviceProvider)
        let delegate = CaptureDelegate(pipeline: pipeline, textureCache: cache)

        let (w, h): (Int, Int)
        do {
            (w, h) = try await withCheckedThrowingContinuation { cont in
                sessionQueue.async {
                    Task {
                        do {
                            let dims = try await session.configure(
                                deliveryQueue: self.deliveryQueue, delegate: delegate
                            )
                            cont.resume(returning: dims)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        } catch { pipeline.teardown(); emit(.closed); throw error }

        sessionQueue.async { session.start() }

        cameraSession   = session
        metalPipeline   = pipeline
        captureDelegate = delegate

        emit(.streaming)

        return SessionCapabilities(
            supportedSizes: [Size(width: w, height: h)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: w, height: h),
            activeCropRegion: Rect(
                x: 0, y: 0,
                width:  Constants.cropDefaultWidthPx,
                height: Constants.cropDefaultHeightPx
            ),
            streamPixelFormat: "rgba16Float"
        )
    }

    public func close() async {
        guard sessionState != .closed else { return }
        emit(.closed)
        let session = cameraSession
        sessionQueue.async { session?.stop(); session?.teardown() }
        metalPipeline?.teardown()
        cameraSession   = nil
        metalPipeline   = nil
        captureDelegate = nil
        stateStreamContinuation?.finish()
        stateStreamContinuation = nil
    }

    // TODO: Stage 09 — only one continuation is retained; a second call replaces the first.
    public func stateStream() -> AsyncStream<SessionState> {
        AsyncStream(bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)) { cont in
            self.stateStreamContinuation = cont
            cont.yield(self.sessionState)
        }
    }

    // MARK: Stubs — replaced in future stages

    public func pause() async { fatalError("Stage 05") }
    public func resume() async throws { fatalError("Stage 05") }
    public func backgroundSuspend() async { fatalError("Stage 09") }
    public func backgroundResume() async { fatalError("Stage 09") }
    public func setResolution(size: Size) async throws { fatalError("Stage 03") }
    public func setCropRegion(_ rect: Rect) async throws { fatalError("Stage 04") }
    public func getNativePipelineHandle() async -> UInt64? { fatalError("Stage 08") }
    public func errorStream() -> AsyncStream<CameraError> { fatalError("Stage 09") }
    public func recordingStateStream() -> AsyncStream<RecordingState> { fatalError("Stage 06") }

    // MARK: Private

    private func emit(_ state: SessionState) {
        sessionState = state
        stateStreamContinuation?.yield(state)
    }
}
```

- [ ] **Step 6.2: Build the package**

```bash
swift build --package-path CameraKit/
```
Expected: zero errors, zero warnings under Swift 6 strict concurrency. Fix any issues before continuing.

- [ ] **Step 6.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "stage-01: CameraEngine actor (open/close/stateStream)"
```

---

## Task 7: CameraView + ViewModel

**Files:**
- Create: `CameraKit/Sources/CameraKit/ViewModel.swift`
- Create: `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 7.1: Write CameraKit/Sources/CameraKit/ViewModel.swift**

```swift
// scaffolding:01:naive-scenephase-stop — no gate, no waitUntilScheduled(), no beginBackgroundTask
import SwiftUI
import MetalKit

@MainActor
@Observable
public final class CameraViewModel {
    public private(set) var sessionState: SessionState = .closed
    public private(set) var capabilities: SessionCapabilities?

    private var engine: CameraEngine?

    public init() {}

    public func bind(engine: CameraEngine, mtkView: MTKView) async {
        self.engine = engine
        await engine.bindMTKView(mtkView)

        do {
            capabilities = try await engine.open(configuration: OpenConfiguration())
        } catch {
            // state stream will reflect .closed; error UI wired in Stage 09
        }

        for await state in await engine.stateStream() {
            sessionState = state
        }
    }

    // scaffolding:01:naive-scenephase-stop
    public func handleScenePhase(_ phase: ScenePhase) async {
        guard let engine else { return }
        if phase == .background { await engine.close() }
    }
}
```

- [ ] **Step 7.2: Write CameraKit/Sources/CameraKit/CameraView.swift**

```swift
import SwiftUI
import MetalKit

public struct CameraView: View {
    @State private var viewModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase

    private let engine: CameraEngine

    public init(engine: CameraEngine) {
        self.engine = engine
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            NaturalPreviewRepresentable(viewModel: viewModel, engine: engine)
                .ignoresSafeArea()
            bottomBar
        }
        .task(id: scenePhase) {
            await viewModel.handleScenePhase(scenePhase)
        }
    }

    private var bottomBar: some View {
        HStack { Spacer() }
            .frame(height: 60)
            .background(.ultraThinMaterial)
    }
}

// UIViewRepresentable wrapping MTKView; bind fires once from makeCoordinator.
private struct NaturalPreviewRepresentable: UIViewRepresentable {
    let viewModel: CameraViewModel
    let engine: CameraEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.contentMode = .scaleAspectFill
        context.coordinator.startBind(mtkView: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    @MainActor
    final class Coordinator {
        private let viewModel: CameraViewModel
        private let engine: CameraEngine
        private var bindTask: Task<Void, Never>?

        init(viewModel: CameraViewModel, engine: CameraEngine) {
            self.viewModel = viewModel
            self.engine = engine
        }

        func startBind(mtkView: MTKView) {
            bindTask?.cancel()
            bindTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await viewModel.bind(engine: engine, mtkView: mtkView)
            }
        }

        deinit { bindTask?.cancel() }
    }
}
```

- [ ] **Step 7.3: Build the package again**

```bash
swift build --package-path CameraKit/
```
Expected: still zero errors. SwiftUI + MetalKit are available on iOS 26.

- [ ] **Step 7.4: Commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift \
  CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "stage-01: CameraView (MTKView UIViewRepresentable) + ViewModel (naive scenePhase stop)"
```

---

## Task 8: RealCaptureDeviceProvider + wire Xcode app

**Files:**
- Create: `CameraKit/Sources/CameraKit/RealCaptureDeviceProvider.swift`
- Modify: `eva-swift-stitch/eva_swift_stitchApp.swift`
- Delete:  `eva-swift-stitch/ContentView.swift`
- Delete:  `eva-swift-stitch/CameraCapabilitiesReporter.swift`

- [ ] **Step 8.1: Write CameraKit/Sources/CameraKit/RealCaptureDeviceProvider.swift**

Production `CaptureDeviceProviding` wrapping `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)`.

```swift
import AVFoundation
import CoreMedia

public final class RealCaptureDeviceProvider: CaptureDeviceProviding {
    private let avDevice: AVCaptureDevice

    public init() throws {
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw EngineError.noBackCamera
        }
        avDevice = d
    }

    public var uniqueID: String { avDevice.uniqueID }

    public var activeFormatSize: Size {
        let d = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)
        return Size(width: Int(d.width), height: Int(d.height))
    }

    public var supportedSizes: [Size] {
        avDevice.formats.map {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Size(width: Int(d.width), height: Int(d.height))
        }
    }

    public var isoRange: ClosedRange<Float> {
        avDevice.activeFormat.minISO...avDevice.activeFormat.maxISO
    }

    public var exposureDurationRangeNs: ClosedRange<Int64> {
        let lo = Int64(avDevice.activeFormat.minExposureDuration.seconds * 1_000_000_000)
        let hi = Int64(avDevice.activeFormat.maxExposureDuration.seconds * 1_000_000_000)
        return lo...hi
    }

    public var maxWhiteBalanceGain: Float { avDevice.maxWhiteBalanceGain }

    public var availableFormats: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] {
        avDevice.formats.flatMap { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let pf   = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            return fmt.videoSupportedFrameRateRanges.map {
                (Int(dims.width), Int(dims.height), $0.maxFrameRate, pf)
            }
        }
    }

    public func makeDeviceInput() throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceInput(device: avDevice)
    }

    public func lockForConfiguration()   throws { try avDevice.lockForConfiguration() }
    public func unlockForConfiguration()        { avDevice.unlockForConfiguration() }

    public func setExposureModeCustom(durationNs: Int64, iso: Float) throws {
        avDevice.setExposureModeCustom(
            duration: CMTime(value: durationNs, timescale: 1_000_000_000),
            iso: iso, completionHandler: nil
        )
    }
    public func setContinuousAutoExposure() throws { avDevice.exposureMode = .continuousAutoExposure }

    public func setFocusModeLocked(lensPosition: Float) throws {
        avDevice.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
    }
    public func setContinuousAutoFocus() throws { avDevice.focusMode = .continuousAutoFocus }

    public func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {
        avDevice.setWhiteBalanceModeLocked(
            with: .init(redGain: gains.red, greenGain: gains.green, blueGain: gains.blue),
            completionHandler: nil
        )
    }
    public func setContinuousAutoWhiteBalance() throws { avDevice.whiteBalanceMode = .continuousAutoWhiteBalance }
    public func setWhiteBalanceLocked()         throws { avDevice.whiteBalanceMode = .locked }

    public func setZoomFactor(_ factor: Double) throws { avDevice.videoZoomFactor = factor }
    public func setExposureCompensation(_ steps: Int) throws {
        avDevice.setExposureTargetBias(Float(steps), completionHandler: nil)
    }
    public func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {
        avDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(minFrameDurationFps))
        avDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFrameDurationFps))
    }
}
```

- [ ] **Step 8.2: Add CameraKit/ as local package in Xcode (manual step)**

In Xcode: **File → Add Package Dependencies → Add Local…** → select the `CameraKit/` directory (i.e. `/Users/shrek/work/cambrian/eva-swift-stitch/CameraKit/`) → choose the `CameraKit` product → add to the `eva-swift-stitch` app target.

Verify: `eva-swift-stitch` target shows `CameraKit` under "Frameworks, Libraries, and Embedded Content".

- [ ] **Step 8.3: Delete obsolete app source files**

In Xcode, delete `ContentView.swift` and `CameraCapabilitiesReporter.swift` from the `eva-swift-stitch` target (move to Trash). These are replaced by `CameraKit.CameraView`.

- [ ] **Step 8.4: Update eva-swift-stitch/eva_swift_stitchApp.swift**

`RealCaptureDeviceProvider.init()` is failable (no back camera on simulator). The app shows an error text in that case.

```swift
import SwiftUI
import CameraKit

@main
struct EvaSwiftStitchApp: App {
    // CameraEngine + provider are created once and live for the app lifetime.
    private let engine: CameraEngine? = {
        do {
            return CameraEngine(
                device: try RealCaptureDeviceProvider(),
                consumers: ConsumerRegistry()
            )
        } catch {
            return nil
        }
    }()

    var body: some Scene {
        WindowGroup {
            if let engine {
                CameraView(engine: engine)
            } else {
                Text("No back camera available")
                    .padding()
            }
        }
    }
}
```

- [ ] **Step 8.5: Build via Xcode (Mac "Designed for iPad")**

```bash
xcodebuild -project eva-swift-stitch.xcodeproj \
  -scheme eva-swift-stitch \
  -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' \
  build
```
Expected: zero errors. If there are missing-import errors in the app target, check the `CameraKit` product is linked.

- [ ] **Step 8.6: Commit**

```bash
git add CameraKit/Sources/CameraKit/RealCaptureDeviceProvider.swift \
  eva-swift-stitch/eva_swift_stitchApp.swift \
  eva-swift-stitch.xcodeproj/project.pbxproj
git rm eva-swift-stitch/ContentView.swift \
       eva-swift-stitch/CameraCapabilitiesReporter.swift
git commit -m "stage-01: RealCaptureDeviceProvider; wire Xcode app to local CameraKit package"
```

---

## Task 9: Unit tests (Stage01Tests)

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage01Tests.swift`

- [ ] **Step 9.1: Write CameraKit/Tests/CameraKitTests/Stage01Tests.swift**

```swift
import Testing
import AVFoundation
@testable import CameraKit

// MARK: — Fake device provider (ADR-32 test seam)

final class FakeCaptureDeviceProvider: CaptureDeviceProviding, @unchecked Sendable {
    var fakeFormats: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] = []

    var uniqueID: String { "fake" }
    var activeFormatSize: Size { Size(width: 4160, height: 3120) }
    var supportedSizes: [Size] { fakeFormats.map { Size(width: $0.width, height: $0.height) } }
    var isoRange: ClosedRange<Float> { 20.0...3200.0 }
    var exposureDurationRangeNs: ClosedRange<Int64> { 1000...500_000_000 }
    var maxWhiteBalanceGain: Float { 4.0 }
    var availableFormats: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] { fakeFormats }

    func makeDeviceInput() throws -> AVCaptureDeviceInput { throw EngineError.noBackCamera }
    func lockForConfiguration() async throws {}
    func unlockForConfiguration() async {}
    func setExposureModeCustom(durationNs: Int64, iso: Float) async throws {}
    func setContinuousAutoExposure() async throws {}
    func setFocusModeLocked(lensPosition: Float) async throws {}
    func setContinuousAutoFocus() async throws {}
    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) async throws {}
    func setContinuousAutoWhiteBalance() async throws {}
    func setWhiteBalanceLocked() async throws {}
    func setZoomFactor(_ factor: Double) async throws {}
    func setExposureCompensation(_ steps: Int) async throws {}
    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) async throws {}
}

// MARK: — Tests

@Suite("Stage01Tests")
struct Stage01Tests {

    // 01:capture-device-provider-seam
    @Test("Fake CaptureDeviceProviding returns canned formats — no AVCaptureDevice created")
    func captureDeviceProviderSeam() async {
        let fake = FakeCaptureDeviceProvider()
        fake.fakeFormats = [
            (width: 4160, height: 3120, maxFPS: 30.0,
             pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        let formats = await fake.availableFormats
        #expect(formats.count == 1)
        #expect(formats[0].width  == 4160)
        #expect(formats[0].height == 3120)
    }

    // 01:largest-4x3-format-selected
    @Test("selectFormat picks largest 4:3 at 30fps; falls back when no 4:3 present")
    func largestFourByThreeFormatSelected() {
        let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let mixed: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] = [
            (1920, 1080, 30.0, yuv),   // 16:9 — must be rejected
            (1280,  960, 30.0, yuv),   // 4:3 smaller
            (4160, 3120, 30.0, yuv),   // 4:3 larger — must win
        ]
        let best = CameraSession.selectFormat(from: mixed)
        #expect(best.width  == 4160)
        #expect(best.height == 3120)

        // Fallback: no 4:3 format present
        let noFourByThree: [(width: Int, height: Int, maxFPS: Double, pixelFormat: OSType)] = [
            (1920, 1080, 30.0, yuv),
        ]
        let fallback = CameraSession.selectFormat(from: noFourByThree)
        #expect(fallback.width  == Constants.captureFallbackWidthPx)
        #expect(fallback.height == Constants.captureFallbackHeightPx)
    }

    // 01:landscape-right-rotation-applied (constant sanity check)
    @Test("CAPTURE_ORIENTATION_ANGLE_DEG constant equals 90")
    func landscapeRightRotationConstant() {
        #expect(Constants.captureOrientationAngleDeg == 90)
    }

    // 01:engine-open-close-transitions
    // INTEGRATION: requires live AVCaptureSession + MTKView (UIKit hardware).
    // Cannot run in a pure swift test --package-path context.
    // Covered by HITL 01:preview-renders-first-frame on device.
}
```

- [ ] **Step 9.2: Run unit tests**

```bash
swift test --package-path CameraKit/ --filter Stage01Tests
```
Expected: 3 tests PASS.

- [ ] **Step 9.3: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage01Tests.swift
git commit -m "stage-01: Stage01Tests (device seam, format selection, orientation constant)"
```

---

## Task 10: Acceptance verification + scaffold inventory

- [ ] **Step 10.1: Verify scaffold slugs present in Sources/**

```bash
grep -rn '01:naive-scenephase-stop'     CameraKit/Sources/
grep -rn '01:simple-metal-passthrough' CameraKit/Sources/
grep -rn '01:skip-completion-guard'    CameraKit/Sources/
```
Expected: ≥1 hit per slug.

- [ ] **Step 10.2: Run swift build**

```bash
swift build --package-path CameraKit/
```
Expected: zero errors, zero warnings.

- [ ] **Step 10.3: Run unit tests**

```bash
swift test --package-path CameraKit/ --filter Stage01Tests
```
Expected: 3 PASS.

- [ ] **Step 10.4: Run on Mac "Designed for iPad"**

Use XcodeBuildMCP:
1. `session_show_defaults` — confirm project/scheme/destination set
2. Build and run — confirm live preview fills screen, empty bottom bar visible, no crash

- [ ] **Step 10.5: Record measurements evidence**

Create `measurements/stage-01/preview.md` with:
- Screenshot path (or description of what was observed)
- Confirmation that preview rendered within 2s of launch
- Device/platform used

- [ ] **Step 10.6: Note acceptance-criteria path adjustment in state.md**

Stage 01 §10 says `swift build --package-path .`. Because the package lives in `CameraKit/`, the actual command is `swift build --package-path CameraKit/`. Record this in `state.md` under "Decisions taken that weren't in the brief".

- [ ] **Step 10.7: Final commit**

```bash
git add measurements/ state.md   # if state.md exists; create if not
git commit -m "stage-01: HITL evidence + acceptance notes"
```

---

## Self-Review

### Spec coverage

| Brief requirement | Task |
|---|---|
| `Package.swift` — CameraKit library + swift-testing test target | Task 1 |
| `CameraEngine` — `init`, `open`, `close`, `stateStream` | Task 6 |
| `CameraSession` — device selection, format selection, orientation, output | Task 5 |
| `CaptureDelegate` — nonisolated, delivery queue, inline Metal encode | Task 5 |
| `MetalPipeline` — scaffolding:01:simple-metal-passthrough (Pass-1 + blit) | Task 4 |
| `TexturePoolManager` — scaffolding:01:simple-metal-passthrough (single naturalTex) | Task 3 |
| `CaptureDeviceProviding` — protocol seam + `DeviceStateSnapshot` | Task 2 |
| `Capabilities` — `OpenConfiguration`, `SessionCapabilities`, `Size`, `Rect` | Task 1 |
| `SessionState`, `StreamId` enums | Task 1 |
| `Errors` — `EngineError` typed-throws variants | Task 1 |
| `FrameSet` stub + associated metadata types | Task 1 |
| `Constants` — Stage 01 values mirroring constants.md | Task 1 |
| `CameraView` — SwiftUI root + `UIViewRepresentable<MTKView>` + empty bottom bar | Task 7 |
| `ViewModel` — `@Observable @MainActor`, naive scenePhase stop | Task 7 |
| `PixelSink` / `ConsumerRegistry` stub | Task 2 |
| `Stage01Tests` — seam, format selection, orientation constant | Task 9 |
| All three scaffold slugs present in `Sources/` | Task 10 |
| `swift build --package-path CameraKit/` passes | Task 10 |
| `swift test --package-path CameraKit/ --filter Stage01Tests` passes | Task 10 |
| HITL evidence recorded in `measurements/stage-01/` | Task 10 |

### Structural notes

1. **xcodeproj as app host.** `CameraKit/` is a library-only local package. The xcodeproj owns `Info.plist`, `NSCameraUsageDescription`, entitlements, and signing — nothing from those moves into the package.

2. **`api-skeletons/Package.swift` is kept.** The plan transplants (copies) from the skeleton; it does not move or delete it. `verify-architecture.sh` M3 greps the skeleton file.

3. **`--package-path CameraKit/`** replaces the brief's `--package-path .` everywhere. Noted in step 10.6.

4. **`01:engine-open-close-transitions` is an integration test.** It requires `AVCaptureSession` + `MTKView` and cannot run via `swift test`. HITL on device covers it. The comment in Stage01Tests.swift is the paper trail.

5. **`RealCaptureDeviceProvider.init()` failable.** App shows a fallback `Text(...)` on simulator (no back camera). No crash.
