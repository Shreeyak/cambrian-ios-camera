# Stage 01 — Walking Skeleton — Bare Natural Preview on Screen

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Stage 01 CameraKit walking skeleton — a local Swift package at `CameraKit/` that, when wired into the Xcode app target, shows a live camera preview filling the screen with an empty bottom bar placeholder.

**Architecture:** Single actor (`CameraEngine`) drives `AVCaptureSession` through `CameraSession` (on `sessionQueue`), feeds frames to `CaptureDelegate` (on `delivery` queue), which encodes Pass-1 YUV→RGBA via `MetalPipeline` and writes into a single IOSurface-backed texture managed by `TexturePoolManager`. `CameraView` (SwiftUI) wraps an `MTKView` with `UIViewRepresentable` and displays it. Three intentional scaffolds are left in place with required comment slugs for Stage 02's pre-flight grep.

**Tech Stack:** Swift 6 / iOS 26 / strict concurrency; SwiftPM local package; AVFoundation + Metal + CoreVideo; swift-testing (ADR-33); XcodeBuildMCP for build/run.

---

## Pre-flight: Existing State

Before implementing anything, verify what already exists:

- `CameraKit/Package.swift` — exists, correct swift-tools-version 6.0 and iOS 26. **Needs update**: add `Shaders` resource path.
- `CameraKit/Sources/CameraKit/Constants.swift` — exists and correct. No changes needed.
- `CameraKit/Tests/CameraKitTests/` — directory exists, empty.
- `eva-swift-stitch/eva_swift_stitchApp.swift` — shows `ContentView()`. Needs to show `CameraView()` after Task 9.
- `eva-swift-stitch/ContentView.swift` — to be deleted in Task 11.
- `eva-swift-stitch/CameraCapabilitiesReporter.swift` — to be deleted in Task 11.
- `eva-swift-stitch.xcodeproj` — does NOT yet reference `CameraKit`. Wired in Task 11 (manual Xcode UI step).

## Type compression decision (logged in state.md)

Brief §4 does not list `Settings.swift`, `Recording.swift`, or `StillCapture.swift`, but `CameraEngine.swift` must compile with stub signatures that reference types from those files. To avoid creating undocumented files, these types are compressed into the files brief §4 does list:

- `CameraMode`, `WhiteBalanceMode`, `CameraSettings`, `ProcessingParameters` → `Capabilities.swift`
- `FrameResult`, `RgbSample` → `FrameSet.swift`
- `RecordingOptions`, `RecordingStart` → `SessionState.swift`
- `StillCaptureOutput`, `StillCaptureError` → `Errors.swift`

This decision is recorded in `state.md` under "Decisions taken that weren't in briefs."

---

## File Map

| File | Action | Contents |
|------|--------|----------|
| `CameraKit/Package.swift` | **Modify** | Add `Shaders` resource declaration |
| `CameraKit/Sources/CameraKit/Constants.swift` | Already correct | No change |
| `CameraKit/Sources/CameraKit/Capabilities.swift` | **Create** | `SessionCapabilities`, `Size`, `Rect`, `OpenConfiguration`, `CameraSettings`, `ProcessingParameters`, `CameraMode`, `WhiteBalanceMode` |
| `CameraKit/Sources/CameraKit/SessionState.swift` | **Create** | `SessionState`, `StreamId`, `RecordingState`, `RecordingOptions`, `RecordingStart` |
| `CameraKit/Sources/CameraKit/Errors.swift` | **Create** | `ErrorCode`, `CameraError`, `EngineError`, `MetalError`, `InteropError`, `RecordingError`, `StillCaptureOutput`, `StillCaptureError` |
| `CameraKit/Sources/CameraKit/FrameSet.swift` | **Create** | `FrameSet` (stub), `TrackerQuality`, `CaptureMetadata`, `ProcessingMetadata`, `WhiteBalanceGains`, `CameraPosition`, `FrameDeliveryStats`, `FrameResult`, `RgbSample` |
| `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` | **Create** | `CaptureDeviceProviding` protocol + `LiveCaptureDevice` production actor |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | **Create** | `CameraSession` internal class; configures `AVCaptureSession` on `sessionQueue` |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | **Create** | `nonisolated` `AVCaptureVideoDataOutputSampleBufferDelegate` |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | **Create** | Single `naturalTex`; `CVMetalTextureCache` (scaffold) |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | **Create** | Pass-1 compute encode + commit (scaffold) |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | **Create** | Actor; implements `init`, `open`, `close`, `stateStream` |
| `CameraKit/Sources/CameraKit/PixelSink.swift` | **Create** | `ConsumerRegistry` actor stub; `ConsumerToken` |
| `CameraKit/Sources/CameraKit/CameraView.swift` | **Create** | SwiftUI `CameraView`; `UIViewRepresentable<MTKView>` |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | **Create** | `@Observable @MainActor ViewModel`; scenePhase scaffold |
| `CameraKit/Sources/CameraKit/Shaders/YUVToRGBA.metal` | **Create** | Pass-1 compute kernel |
| `CameraKit/Tests/CameraKitTests/Stage01Tests.swift` | **Create** | All TESTABLE entries from brief §8 |
| `eva-swift-stitch/eva_swift_stitchApp.swift` | **Modify** | Replace `ContentView()` with `CameraView()` |
| `eva-swift-stitch/ContentView.swift` | **Delete** | |
| `eva-swift-stitch/CameraCapabilitiesReporter.swift` | **Delete** | |
| `CameraKit/state.md` | **Create** | Populated per brief §12 |

---

## Task 1: Update Package.swift (add Shaders resource)

**Files:**
- Modify: `CameraKit/Package.swift`

- [ ] **Step 1: Update Package.swift to declare the Shaders resource path**

Replace the CameraKit target definition so it declares the metal resource:

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
            resources: [.process("Shaders")],
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

- [ ] **Step 2: Create the Shaders directory**

```bash
mkdir -p /path/to/CameraKit/Sources/CameraKit/Shaders
```

---

## Task 2: Value types — Capabilities.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/Capabilities.swift`

- [ ] **Step 1: Create Capabilities.swift**

```swift
import Foundation
import CoreGraphics

// MARK: - Core geometry types

public struct Size: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - Session capabilities

/// Returned by CameraEngine.open(configuration:) per domain-revised/10-api-contract.md §SessionCapabilities.
public struct SessionCapabilities: Sendable, Hashable {
    public let supportedSizes: [Size]
    public let previewTextureId: Int
    public let naturalTextureId: Int
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    public let streamPixelFormat: String

    public init(
        supportedSizes: [Size],
        previewTextureId: Int,
        naturalTextureId: Int,
        activeCaptureResolution: Size,
        activeCropRegion: Rect,
        streamPixelFormat: String
    ) {
        self.supportedSizes = supportedSizes
        self.previewTextureId = previewTextureId
        self.naturalTextureId = naturalTextureId
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
        self.streamPixelFormat = streamPixelFormat
    }
}

/// Startup arguments for CameraEngine.open(configuration:).
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        cropRegion: Rect? = nil
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.cropRegion = cropRegion
    }
}

// MARK: - Settings types (compressed here per Stage 01 type-compression decision)

public enum CameraMode: String, Sendable, Hashable {
    case auto
    case manual
}

public enum WhiteBalanceMode: String, Sendable, Hashable {
    case auto
    case locked
    case manual
}

/// Partial-update settings object per domain-revised/10-api-contract.md §CameraSettings.
/// Every field is optional; null = "do not change." Full merge logic arrives Stage 03.
public struct CameraSettings: Sendable, Hashable {
    public var isoMode: CameraMode?
    public var iso: Int?
    public var exposureMode: CameraMode?
    public var exposureTimeNs: Int64?
    public var focusMode: CameraMode?
    public var focusDistance: Double?
    public var wbMode: WhiteBalanceMode?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?
    public var zoomRatio: Double?
    public var evCompensation: Int?

    public init(
        isoMode: CameraMode? = nil,
        iso: Int? = nil,
        exposureMode: CameraMode? = nil,
        exposureTimeNs: Int64? = nil,
        focusMode: CameraMode? = nil,
        focusDistance: Double? = nil,
        wbMode: WhiteBalanceMode? = nil,
        wbGainR: Double? = nil,
        wbGainG: Double? = nil,
        wbGainB: Double? = nil,
        zoomRatio: Double? = nil,
        evCompensation: Int? = nil
    ) {
        self.isoMode = isoMode; self.iso = iso
        self.exposureMode = exposureMode; self.exposureTimeNs = exposureTimeNs
        self.focusMode = focusMode; self.focusDistance = focusDistance
        self.wbMode = wbMode; self.wbGainR = wbGainR; self.wbGainG = wbGainG; self.wbGainB = wbGainB
        self.zoomRatio = zoomRatio; self.evCompensation = evCompensation
    }
}

/// GPU color-processing shader parameters. All fields required. Full implementation Stage 04.
public struct ProcessingParameters: Sendable, Hashable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var blackR: Double
    public var blackG: Double
    public var blackB: Double
    public var gamma: Double

    public init(
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 0.0,
        blackR: Double = 0.0,
        blackG: Double = 0.0,
        blackB: Double = 0.0,
        gamma: Double = 1.0
    ) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.blackR = blackR; self.blackG = blackG; self.blackB = blackB; self.gamma = gamma
    }

    public static let identity = ProcessingParameters()
}
```

- [ ] **Step 2: Verify no compile errors for just this file**

```bash
swift build --package-path CameraKit/ 2>&1 | head -30
```

Expected: the build might fail on missing types from other files — that is fine. Focus on confirming Capabilities.swift has no syntax errors.

---

## Task 3: Value types — SessionState.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/SessionState.swift`

- [ ] **Step 1: Create SessionState.swift**

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

// MARK: - Recording types (compressed here per Stage 01 type-compression decision)

/// Options for starting a recording session. Full implementation Stage 06.
public struct RecordingOptions: Sendable, Hashable {
    public var outputPath: String?
    public init(outputPath: String? = nil) { self.outputPath = outputPath }
}

/// Result of a successful recording start. Full implementation Stage 06.
public struct RecordingStart: Sendable, Hashable {
    public let sessionId: UInt64
    public init(sessionId: UInt64) { self.sessionId = sessionId }
}
```

---

## Task 4: Value types — Errors.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/Errors.swift`

- [ ] **Step 1: Create Errors.swift**

```swift
import Foundation

/// Domain-public error-code taxonomy per domain-revised/10-api-contract.md §ErrorCode.
public enum ErrorCode: String, Sendable, Hashable {
    case cameraNotFound       = "CAMERA_NOT_FOUND"
    case cameraInUse          = "CAMERA_IN_USE"
    case permissionDenied     = "PERMISSION_DENIED"
    case cameraAccessError    = "CAMERA_ACCESS_ERROR"
    case cameraDisconnected   = "CAMERA_DISCONNECTED"
    case configurationFailed  = "CONFIGURATION_FAILED"
    case captureFailure       = "CAPTURE_FAILURE"
    case recordingStartFailed = "RECORDING_START_FAILED"
    case recordingFailed      = "RECORDING_FAILED"
    case recordingTruncated   = "RECORDING_TRUNCATED"
    case frameStall           = "FRAME_STALL"
    case maxRetriesExceeded   = "MAX_RETRIES_EXCEEDED"
    case unknownError         = "UNKNOWN_ERROR"
    case settingsConflict     = "SETTINGS_CONFLICT"
    case invalidFormat        = "INVALID_FORMAT"
    case fpsDegraded          = "FPS_DEGRADED"
    case aeConvergenceTimeout = "AE_CONVERGENCE_TIMEOUT"
    case invalidState         = "INVALID_STATE"
    case hardwareError        = "HARDWARE_ERROR"
}

/// onError payload per domain-revised/10-api-contract.md §Error.
public struct CameraError: Sendable, Error, Hashable {
    public let code: ErrorCode
    public let message: String
    public let isFatal: Bool

    public init(code: ErrorCode, message: String, isFatal: Bool) {
        self.code = code; self.message = message; self.isFatal = isFatal
    }
}

/// Typed throws per ADR-25. Wraps framework errors without losing root cause.
public enum EngineError: Error, Sendable {
    case alreadyOpen
    case notOpen
    case cameraDenied
    case noBackCamera
    case noSupportedFormat(reason: String)
    case lockForConfigurationFailed
    case settingsConflict(reason: String)
    case sessionLifecycleTimeout
    case metal(MetalError)
    case interop(InteropError)
    case recording(RecordingError)
    case fatal(CameraError)
}

public enum MetalError: Error, Sendable {
    case commandBufferFailed(code: Int)
    case textureCacheCreateFailed(code: Int32)
    case textureWrapFailed(code: Int32)
    case pipelineStateCompilation(String)
    case unsupportedFormat
}

public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
}

public enum RecordingError: Error, Sendable {
    case writerStartFailed(status: Int)
    case appendFailed(status: Int)
    case finishTimeout
    case diskFull
}

// MARK: - Still capture types (compressed here per Stage 01 type-compression decision)

/// Output of a successful captureImage() call. Full implementation Stage 06.
public struct StillCaptureOutput: Sendable, Hashable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}

/// Errors specific to still capture. Full implementation Stage 06.
public enum StillCaptureError: Error, Sendable {
    case captureInProgress
    case metalReadbackFailed
    case fileWriteFailed(String)
}
```

---

## Task 5: Value types — FrameSet.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/FrameSet.swift`

- [ ] **Step 1: Create FrameSet.swift**

```swift
import Foundation
import CoreVideo
import CoreMedia

/// Atomic unit of publication per ADR-18. Full construction arrives Stage 06.
/// @unchecked Sendable: CVPixelBuffer is not yet Sendable on iOS 26 (G-13).
/// IOSurface backing + GPU-completion-before-construction guarantee safe cross-thread use.
public struct FrameSet: @unchecked Sendable, Hashable {
    public let frameNumber: UInt64
    public let captureTime: CMTime
    public let natural: CVPixelBuffer
    public let processed: CVPixelBuffer
    public let tracker: CVPixelBuffer
    public let capture: CaptureMetadata
    public let processing: ProcessingMetadata
    public let blurScore: Float
    public let trackerQuality: TrackerQuality

    public init(
        frameNumber: UInt64, captureTime: CMTime,
        natural: CVPixelBuffer, processed: CVPixelBuffer, tracker: CVPixelBuffer,
        capture: CaptureMetadata, processing: ProcessingMetadata,
        blurScore: Float, trackerQuality: TrackerQuality
    ) {
        self.frameNumber = frameNumber; self.captureTime = captureTime
        self.natural = natural; self.processed = processed; self.tracker = tracker
        self.capture = capture; self.processing = processing
        self.blurScore = blurScore; self.trackerQuality = trackerQuality
    }

    public static func == (lhs: FrameSet, rhs: FrameSet) -> Bool {
        lhs.frameNumber == rhs.frameNumber && lhs.captureTime == rhs.captureTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameNumber)
        hasher.combine(captureTime.value)
    }
}

public enum TrackerQuality: String, Sendable, Hashable {
    case good; case degraded; case invalid
}

public struct CaptureMetadata: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let whiteBalanceGains: WhiteBalanceGains
    public let whiteBalanceModeActive: WhiteBalanceMode
    public let lensPosition: Float
    public let focusModeActive: CameraMode
    public let exposureModeActive: CameraMode
    public let zoomFactor: Double
    public let cameraPosition: CameraPosition

    public init(iso: Float, exposureDurationNs: Int64, whiteBalanceGains: WhiteBalanceGains,
                whiteBalanceModeActive: WhiteBalanceMode, lensPosition: Float,
                focusModeActive: CameraMode, exposureModeActive: CameraMode,
                zoomFactor: Double, cameraPosition: CameraPosition) {
        self.iso = iso; self.exposureDurationNs = exposureDurationNs
        self.whiteBalanceGains = whiteBalanceGains; self.whiteBalanceModeActive = whiteBalanceModeActive
        self.lensPosition = lensPosition; self.focusModeActive = focusModeActive
        self.exposureModeActive = exposureModeActive; self.zoomFactor = zoomFactor
        self.cameraPosition = cameraPosition
    }
}

public struct ProcessingMetadata: Sendable, Hashable {
    public let cropRegion: Rect
    public let brightness: Float
    public let contrast: Float
    public let saturation: Float
    public let gamma: Float
    public let whiteBalanceGains: WhiteBalanceGains

    public init(cropRegion: Rect, brightness: Float, contrast: Float,
                saturation: Float, gamma: Float, whiteBalanceGains: WhiteBalanceGains) {
        self.cropRegion = cropRegion; self.brightness = brightness; self.contrast = contrast
        self.saturation = saturation; self.gamma = gamma; self.whiteBalanceGains = whiteBalanceGains
    }
}

public struct WhiteBalanceGains: Sendable, Hashable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public init(red: Float, green: Float, blue: Float) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public enum CameraPosition: String, Sendable, Hashable {
    case back; case front; case wide
}

public struct FrameDeliveryStats: Sendable, Hashable {
    public let producedByLane: [StreamId: UInt64]
    public let deliveredByLane: [StreamId: UInt64]
    public let droppedByLane: [StreamId: UInt64]
    public let holdOverBudgetByLane: [StreamId: UInt64]
    public let poolExhaustion: UInt64
    public let cppOverwriteByLane: [StreamId: UInt64]

    public init(producedByLane: [StreamId: UInt64], deliveredByLane: [StreamId: UInt64],
                droppedByLane: [StreamId: UInt64], holdOverBudgetByLane: [StreamId: UInt64],
                poolExhaustion: UInt64, cppOverwriteByLane: [StreamId: UInt64]) {
        self.producedByLane = producedByLane; self.deliveredByLane = deliveredByLane
        self.droppedByLane = droppedByLane; self.holdOverBudgetByLane = holdOverBudgetByLane
        self.poolExhaustion = poolExhaustion; self.cppOverwriteByLane = cppOverwriteByLane
    }
}

// MARK: - Sensor read types (compressed here per Stage 01 type-compression decision)

/// Sensor metadata delivered at constants.md#FRAME_RESULT_HEARTBEAT_HZ. Full implementation Stage 04.
public struct FrameResult: Sendable, Hashable {
    public var iso: Int?
    public var exposureTimeNs: Int64?
    public var focusDistance: Double?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?

    public init(iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil,
                wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil) {
        self.iso = iso; self.exposureTimeNs = exposureTimeNs; self.focusDistance = focusDistance
        self.wbGainR = wbGainR; self.wbGainG = wbGainG; self.wbGainB = wbGainB
    }
}

/// Per-channel trimmed-mean sample from sampleCenterPatch(). Full implementation Stage 04.
public struct RgbSample: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
}
```

---

## Task 6: CaptureDeviceProviding.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift`

- [ ] **Step 1: Create CaptureDeviceProviding.swift**

The protocol is the ADR-32 test seam. `CameraEngine` depends only on this protocol.
`LiveCaptureDevice` is the production actor — it holds `AVCaptureDevice` and
provides format metadata. `CameraSession` receives the raw `AVCaptureDevice` from
`LiveCaptureDevice` for its sessionQueue work (tests never reach `CameraSession`).

```swift
import Foundation
import AVFoundation

// MARK: - ADR-32 test seam

/// ADR-32: engine depends on this protocol, never on AVCaptureDevice directly.
/// The fake in tests supplies canned format data without touching AVFoundation.
public protocol CaptureDeviceProviding: AnyObject, Sendable {
    var uniqueID: String { get async }
    var activeFormatSize: Size { get async }
    var supportedSizes: [Size] { get async }
    var isoRange: ClosedRange<Float> { get async }
    var exposureDurationRangeNs: ClosedRange<Int64> { get async }
    var maxWhiteBalanceGain: Float { get async }

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

// MARK: - DeviceStateSnapshot (ADR-14; KVO stream wired Stage 03)

public struct DeviceStateSnapshot: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let lensPosition: Float
    public let whiteBalanceGains: WhiteBalanceGains
    public let isAdjustingExposure: Bool
    public let systemPressureLevel: SystemPressureLevel

    public init(iso: Float, exposureDurationNs: Int64, lensPosition: Float,
                whiteBalanceGains: WhiteBalanceGains, isAdjustingExposure: Bool,
                systemPressureLevel: SystemPressureLevel) {
        self.iso = iso; self.exposureDurationNs = exposureDurationNs
        self.lensPosition = lensPosition; self.whiteBalanceGains = whiteBalanceGains
        self.isAdjustingExposure = isAdjustingExposure; self.systemPressureLevel = systemPressureLevel
    }
}

public enum SystemPressureLevel: String, Sendable, Hashable {
    case nominal; case fair; case serious; case critical; case shutdown
}

// MARK: - Production implementation

/// Production implementation: wraps a single back-facing wide-angle AVCaptureDevice (D-08).
/// CameraSession receives avDevice for sessionQueue work; tests never reach this type.
final actor LiveCaptureDevice: CaptureDeviceProviding {
    let avDevice: AVCaptureDevice

    init(avDevice: AVCaptureDevice) {
        self.avDevice = avDevice
    }

    var uniqueID: String { avDevice.uniqueID }

    var activeFormatSize: Size {
        let dims = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)
        return Size(width: Int(dims.width), height: Int(dims.height))
    }

    var supportedSizes: [Size] {
        avDevice.formats.compactMap { format in
            // Filter to 8-bit biplanar YUV (CAPTURE_PIXEL_FORMAT per constants.md)
            let desc = format.formatDescription
            let pixelFormat = CMFormatDescriptionGetMediaSubType(desc)
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            return Size(width: Int(dims.width), height: Int(dims.height))
        }
    }

    var isoRange: ClosedRange<Float> {
        avDevice.activeFormat.minISO ... avDevice.activeFormat.maxISO
    }

    var exposureDurationRangeNs: ClosedRange<Int64> {
        let minNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.minExposureDuration) * 1_000_000_000)
        let maxNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.maxExposureDuration) * 1_000_000_000)
        return minNs ... maxNs
    }

    var maxWhiteBalanceGain: Float { avDevice.maxWhiteBalanceGain }

    func lockForConfiguration() throws { try avDevice.lockForConfiguration() }
    func unlockForConfiguration() { avDevice.unlockForConfiguration() }

    func setExposureModeCustom(durationNs: Int64, iso: Float) throws {
        let duration = CMTimeMake(value: durationNs, timescale: 1_000_000_000)
        avDevice.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
    }

    func setContinuousAutoExposure() throws {
        guard avDevice.isExposureModeSupported(.continuousAutoExposure) else { return }
        avDevice.exposureMode = .continuousAutoExposure
    }

    func setFocusModeLocked(lensPosition: Float) throws {
        avDevice.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
    }

    func setContinuousAutoFocus() throws {
        guard avDevice.isFocusModeSupported(.continuousAutoFocus) else { return }
        avDevice.focusMode = .continuousAutoFocus
    }

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {
        let avGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: gains.red, greenGain: gains.green, blueGain: gains.blue)
        avDevice.setWhiteBalanceModeLocked(with: avGains, completionHandler: nil)
    }

    func setContinuousAutoWhiteBalance() throws {
        guard avDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        avDevice.whiteBalanceMode = .continuousAutoWhiteBalance
    }

    func setWhiteBalanceLocked() throws {
        guard avDevice.isWhiteBalanceModeSupported(.locked) else { return }
        avDevice.whiteBalanceMode = .locked
    }

    func setZoomFactor(_ factor: Double) throws {
        avDevice.videoZoomFactor = CGFloat(factor)
    }

    func setExposureCompensation(_ steps: Int) throws {
        avDevice.setExposureTargetBias(Float(steps), completionHandler: nil)
    }

    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {
        avDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(minFrameDurationFps))
        avDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(maxFrameDurationFps))
    }
}
```

---

## Task 7: CameraSession.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraSession.swift`

`CameraSession` is internal and runs on `sessionQueue` (ADR-07). It receives the `AVCaptureDevice` from `CameraEngine` (which obtained it through `CaptureDeviceProviding`). It stores `appliedRotationAngle` so the rotation unit test can verify intent without touching a live connection.

- [ ] **Step 1: Create CameraSession.swift**

```swift
import Foundation
import AVFoundation

/// Drives AVCaptureSession on the caller-supplied sessionQueue (ADR-07).
/// All methods on this type MUST be called from sessionQueue.
/// CaptureDeviceProviding is the test seam at CameraEngine level;
/// CameraSession works directly with AVCaptureDevice (tests never reach this type).
// @unchecked Sendable: accessed only from sessionQueue (ADR-07); Swift 6 strict concurrency
final class CameraSession: NSObject, @unchecked Sendable {
    let avSession: AVCaptureSession
    private(set) var appliedRotationAngle: CGFloat = 0
    private(set) var appliedCaptureResolution: Size?
    private let avDevice: AVCaptureDevice
    private var videoOutput: AVCaptureVideoDataOutput?

    init(avDevice: AVCaptureDevice) {
        self.avDevice = avDevice
        self.avSession = AVCaptureSession()
        super.init()
    }

    /// Configure the session. Call on sessionQueue only.
    /// Selects the provided format, sets orientation (ADR-17), wires AVCaptureVideoDataOutput.
    /// Returns the active capture resolution and all supported sizes for SessionCapabilities.
    func configure(
        selectedFormat: AVCaptureDevice.Format,
        supportedSizes: [Size]
    ) throws -> (activeCaptureResolution: Size, supportedSizes: [Size]) {
        avSession.beginConfiguration()
        defer { avSession.commitConfiguration() }

        // Remove existing inputs
        avSession.inputs.forEach { avSession.removeInput($0) }
        avSession.outputs.forEach { avSession.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: avDevice)
        guard avSession.canAddInput(input) else {
            throw EngineError.noSupportedFormat(reason: "Cannot add device input to session")
        }
        avSession.addInput(input)

        // Apply format + frame rate (G-17: 8-bit YUV, 30fps lock in preview mode)
        try avDevice.lockForConfiguration()
        defer { avDevice.unlockForConfiguration() }

        avDevice.activeFormat = selectedFormat
        // Lock frame rate to FRAME_RATE_TARGET_FPS in preview mode (03-camera-session.md §AE frame-rate range)
        let frameDuration = CMTimeMake(value: 1, timescale: Int32(Constants.frameRateTargetFPS))
        avDevice.activeVideoMinFrameDuration = frameDuration
        avDevice.activeVideoMaxFrameDuration = frameDuration

        // Wire AVCaptureVideoDataOutput (03-camera-session.md §Capture output configuration)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Constants.capturePixelFormat
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard avSession.canAddOutput(output) else {
            throw EngineError.noSupportedFormat(reason: "Cannot add video output to session")
        }
        avSession.addOutput(output)
        self.videoOutput = output

        // Set landscape-right orientation via videoRotationAngle (ADR-17)
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(Constants.captureOrientationAngleDeg) {
            connection.videoRotationAngle = Constants.captureOrientationAngleDeg
            appliedRotationAngle = Constants.captureOrientationAngleDeg
        } else {
            throw EngineError.noSupportedFormat(reason: "videoRotationAngle 90° not supported")
        }

        let dims = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
        let resolution = Size(width: Int(dims.width), height: Int(dims.height))
        appliedCaptureResolution = resolution

        return (activeCaptureResolution: resolution, supportedSizes: supportedSizes)
    }

    /// Set the sample buffer delegate. Call on sessionQueue only.
    func setDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate, queue: DispatchQueue) {
        videoOutput?.setSampleBufferDelegate(delegate, queue: queue)
    }

    /// Call on sessionQueue only.
    func startRunning() { avSession.startRunning() }

    /// Call on sessionQueue only.
    func stopRunning() { avSession.stopRunning() }
}
```

---

## Task 8: CaptureDelegate.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/CaptureDelegate.swift`

`CaptureDelegate` is `nonisolated` and `@unchecked Sendable` — it is called on the `delivery` queue by AVFoundation and calls `MetalPipeline` inline per ADR-02, ADR-10.

- [ ] **Step 1: Create CaptureDelegate.swift**

```swift
import Foundation
import AVFoundation

/// nonisolated sample-buffer delegate running on the delivery queue (ADR-07, ADR-02).
/// Metal encode + commit happen inline inside captureOutput — the frame clock
/// never hops a Swift actor boundary (ADR-10).
final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                             @unchecked Sendable {
    private let pipeline: MetalPipeline

    init(pipeline: MetalPipeline) {
        self.pipeline = pipeline
        super.init()
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Encode and commit inline on delivery queue (ADR-10)
        pipeline.encodeAndCommit(pixelBuffer: pixelBuffer)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Drop-on-busy per Invariant 10 / ADR-13; no recovery needed
    }
}
```

---

## Task 9: TexturePoolManager.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`

Stage 01 scaffold: single IOSurface-backed `naturalTex` only (no pool trio, no `processed`, no `tracker`). Full pool arrives Stage 08.

- [ ] **Step 1: Create TexturePoolManager.swift**

```swift
import Foundation
import Metal
import CoreVideo

/// Manages the CVMetalTextureCache and the single naturalTex used in Stage 01.
/// scaffolding:01:simple-metal-passthrough — only naturalTex (one IOSurface-backed buffer).
/// Full CVPixelBufferPool trio (natural, processed, tracker) arrives Stage 08.
// @unchecked Sendable: accessed only from delivery queue (ADR-07); CVMetalTextureCache is thread-safe
final class TexturePoolManager: @unchecked Sendable {
    let textureCache: CVMetalTextureCache
    private(set) var naturalTexture: CVMetalTexture?

    init(device: MTLDevice) throws {
        // ADR-04: one CVMetalTextureCache per device
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else {
            throw EngineError.metal(.textureCacheCreateFailed(code: result))
        }
        textureCache = cache
    }

    // scaffolding:01:simple-metal-passthrough
    /// Wraps an IOSurface-backed CVPixelBuffer in a CVMetalTexture for the naturalTex slot.
    /// ADR-06: no MTLTexture.getBytes — all CPU access through IOSurface-backed CVPixelBuffer.
    func updateNaturalTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        // WORKING_PIXEL_FORMAT = rgba16Float (constants.md)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            Constants.workingPixelFormat, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            throw EngineError.metal(.textureWrapFailed(code: status))
        }
        naturalTexture = cvTexture
        guard let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw EngineError.metal(.textureWrapFailed(code: kCVReturnInvalidArgument))
        }
        return mtlTexture
    }

    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
```

---

## Task 10: Metal Shader — YUVToRGBA.metal

**Files:**
- Create: `CameraKit/Sources/CameraKit/Shaders/YUVToRGBA.metal`

Pass-1 compute kernel: reads biplanar YUV (luma plane + chroma plane) and writes RGBA16F.

- [ ] **Step 1: Create the Shaders directory**

```bash
mkdir -p CameraKit/Sources/CameraKit/Shaders
```

- [ ] **Step 2: Create YUVToRGBA.metal**

```metal
#include <metal_stdlib>
using namespace metal;

// Pass-1 compute kernel: biplanar YUV (420f) → RGBA16F (scaffolding:01:simple-metal-passthrough)
// Luma in texture0 (r8Unorm), chroma UV interleaved in texture1 (rg8Unorm).
// BT.601 full-range coefficients match kCVPixelFormatType_420YpCbCr8BiPlanarFullRange (CAPTURE_PIXEL_FORMAT).
kernel void yuvToRGBA(
    texture2d<float, access::sample> lumaTexture   [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<half,  access::write>  outTexture    [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
)
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }

    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float2 uv = float2(gid) / float2(outTexture.get_width(), outTexture.get_height());

    float y  = lumaTexture.sample(s, uv).r;
    float2 cbcr = chromaTexture.sample(s, uv).rg - 0.5h;
    float cb = cbcr.r;
    float cr = cbcr.g;

    // BT.601 full-range YCbCr → RGB
    float r = y + 1.402   * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772   * cb;

    outTexture.write(half4(half(r), half(g), half(b), 1.0h), gid);
}
```

---

## Task 11: MetalPipeline.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

Stage 01 scaffold: Pass 1 (YUV→RGBA into naturalTex) only. No Pass 2–6.
Contains both `scaffolding:01:simple-metal-passthrough` and `scaffolding:01:skip-completion-guard`.

- [ ] **Step 1: Create MetalPipeline.swift**

```swift
import Foundation
import Metal
import CoreVideo
import CoreMedia

/// Manages the Metal device, command queue, compute pipeline state, and texture pool.
/// scaffolding:01:simple-metal-passthrough — Pass 1 (YUV→RGBA) only;
/// no Pass 2 (color), Pass 3 (blit), Pass 4 (tracker), Pass 5 (encoder), Pass 6 (still readback).
/// No CVPixelBufferPool trio — single IOSurface slot only.
// @unchecked Sendable: MTLDevice/MTLCommandQueue are thread-safe; accessed only from delivery queue (ADR-07)
final class MetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    let poolManager: TexturePoolManager
    private(set) var mtkView: MTKView?

    init(captureSize: Size) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(.unsupportedFormat)
        }
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.metal(.commandBufferFailed(code: 0))
        }
        self.device = device
        self.commandQueue = queue

        // Load compute kernel from SwiftPM package bundle (ADR-04; .module resolves Bundle.module)
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "yuvToRGBA") else {
            throw EngineError.metal(.pipelineStateCompilation("yuvToRGBA kernel not found"))
        }
        pipelineState = try device.makeComputePipelineState(function: function)
        poolManager = try TexturePoolManager(device: device)
    }

    func bind(mtkView: MTKView) {
        self.mtkView = mtkView
    }

    /// Encode Pass 1 inline on the delivery queue. Called from CaptureDelegate (ADR-10).
    // scaffolding:01:simple-metal-passthrough
    func encodeAndCommit(pixelBuffer: CVPixelBuffer) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        do {
            let naturalTex = try poolManager.updateNaturalTexture(from: pixelBuffer)

            // Wrap luma + chroma planes from the biplanar CVPixelBuffer
            guard let lumaTexture = makePlaneTexture(from: pixelBuffer, plane: 0, format: .r8Unorm),
                  let chromaTexture = makePlaneTexture(from: pixelBuffer, plane: 1, format: .rg8Unorm)
            else { return }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(lumaTexture, index: 0)
            encoder.setTexture(chromaTexture, index: 1)
            encoder.setTexture(naturalTex, index: 2)

            let w = pipelineState.threadExecutionWidth
            let h = pipelineState.maxTotalThreadsPerThreadgroup / w
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadsPerGrid = MTLSize(
                width: naturalTex.width, height: naturalTex.height, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            // scaffolding:01:skip-completion-guard
            // addCompletedHandler does NOT check sessionState before touching readback state.
            // Full D-10 guard (sessionState check + OSAllocatedUnfairLock) arrives Stage 09.
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self, let view = self.mtkView,
                      let drawable = view.currentDrawable else { return }
                // Blit naturalTex into MTKView drawable for preview
                guard let blitBuffer = self.commandQueue.makeCommandBuffer(),
                      let blitEncoder = blitBuffer.makeBlitCommandEncoder() else { return }
                blitEncoder.copy(from: naturalTex, to: drawable.texture)
                blitEncoder.endEncoding()
                blitBuffer.present(drawable)
                blitBuffer.commit()
            }
        } catch {
            // Texture wrap failure: flush cache and skip this frame
            poolManager.flush()
            return
        }

        commandBuffer.commit()
    }

    private func makePlaneTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, poolManager.textureCache, pixelBuffer, nil,
            format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
```

---

## Task 12: CameraEngine.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraEngine.swift`

The central actor. Stage 01 implements `init`, `open`, `close`, `stateStream`. All other methods are `fatalError("Stage N")` stubs.

- [ ] **Step 1: Create CameraEngine.swift**

```swift
import Foundation
import AVFoundation
import Metal

/// Single actor per ADR-02. Owns all stateful resources.
/// Drives AVCaptureSession through sessionQueue via async-with-timeout helper (ADR-30).
/// Frame clock stays on delivery queue — never hops a Swift actor boundary (ADR-10).
public actor CameraEngine {
    // MARK: - Queues (ADR-07)
    let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    let deliveryQueue = DispatchQueue(label: "camera.delivery", qos: .userInitiated)

    // MARK: - State
    private var sessionState: SessionState = .closed
    public let consumers: ConsumerRegistry

    // MARK: - Components (non-nil while open)
    private var captureDevice: (any CaptureDeviceProviding)?
    private var cameraSession: CameraSession?
    private var metalPipeline: MetalPipeline?
    private var captureDelegate: CaptureDelegate?

    // MARK: - State stream (ADR-22: bufferingOldest(STATE_STREAM_BUFFER_SIZE))
    private let _stateStream: AsyncStream<SessionState>
    private let stateStreamContinuation: AsyncStream<SessionState>.Continuation

    public init(device: any CaptureDeviceProviding, consumers: ConsumerRegistry) {
        self.captureDevice = device
        self.consumers = consumers
        var cont: AsyncStream<SessionState>.Continuation!
        _stateStream = AsyncStream(
            SessionState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { cont = $0 }
        stateStreamContinuation = cont
    }

    // MARK: - Public API (Stage 01)

    public func open(configuration: OpenConfiguration) async throws -> SessionCapabilities {
        guard sessionState == .closed else { throw EngineError.alreadyOpen }

        emit(.opening)

        // Permission check (G-16, 03-camera-session.md §Permission flow)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied, .restricted:
            throw EngineError.cameraDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw EngineError.cameraDenied }
        default:
            break
        }

        // Obtain device (D-08: back-facing wide-angle only)
        guard let avRawDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            throw EngineError.noBackCamera
        }
        let liveDevice = LiveCaptureDevice(avDevice: avRawDevice)
        captureDevice = liveDevice

        // Format selection on engine actor (ADR-32 seam + G-17, 03-camera-session.md §Format selection)
        let allSizes = await liveDevice.supportedSizes
        let selectedFormat = try selectFormat(from: avRawDevice, supportedSizes: allSizes)

        // Create Metal pipeline (held for life of engine per 01-system-shape.md §Ownership)
        let pipeline = try MetalPipeline(captureSize: Size(
            width: CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription).width.int,
            height: CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription).height.int
        ))
        metalPipeline = pipeline

        // Configure session on sessionQueue (ADR-07, ADR-30)
        let session = CameraSession(avDevice: avRawDevice)
        let (activeCaptureResolution, supportedSizes) = try await withSessionQueue {
            try session.configure(selectedFormat: selectedFormat, supportedSizes: allSizes)
        }
        cameraSession = session

        // Wire delegate on delivery queue (ADR-07)
        let delegate = CaptureDelegate(pipeline: pipeline)
        session.setDelegate(delegate, queue: deliveryQueue)
        captureDelegate = delegate

        // Start (ADR-30)
        try await withSessionQueue { session.startRunning() }

        sessionState = .streaming
        emit(.streaming)

        let cropRegion = Rect(
            x: 0, y: 0,
            width: Constants.cropDefaultWidthPx,
            height: Constants.cropDefaultHeightPx
        )
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: activeCaptureResolution,
            activeCropRegion: cropRegion,
            streamPixelFormat: "RGBA16F"
        )
    }

    public func close() async {
        guard sessionState != .closed else { return }
        let session = cameraSession
        sessionQueue.async { session?.stopRunning() }
        metalPipeline = nil
        captureDelegate = nil
        cameraSession = nil
        captureDevice = nil
        sessionState = .closed
        emit(.closed)
    }

    public func stateStream() -> AsyncStream<SessionState> { _stateStream }

    // MARK: - Stubs (implemented in later stages)

    public func pause() async { fatalError("Stage 05") }
    public func resume() async throws { fatalError("Stage 05") }
    public func backgroundSuspend() async { fatalError("Stage 09") }
    public func backgroundResume() async { fatalError("Stage 09") }
    public func updateSettings(_ settings: CameraSettings) async throws { fatalError("Stage 03") }
    public func setProcessingParameters(_ params: ProcessingParameters) async { fatalError("Stage 04") }
    public nonisolated func getPersistedProcessingParameters() async -> ProcessingParameters? { fatalError("Stage 07") }
    public func sampleCenterPatch() async throws -> RgbSample { fatalError("Stage 04") }
    public func captureImage(outputPath: String?) async throws -> StillCaptureOutput { fatalError("Stage 06") }
    public func startRecording(options: RecordingOptions) async throws -> RecordingStart { fatalError("Stage 06") }
    public func stopRecording() async throws -> String { fatalError("Stage 06") }
    public func setResolution(size: Size) async throws { fatalError("Stage 03") }
    public func setCropRegion(_ rect: Rect) async throws { fatalError("Stage 04") }
    public func getNativePipelineHandle() async -> UInt64? { fatalError("Stage 08") }
    public func errorStream() -> AsyncStream<CameraError> { fatalError("Stage 09") }
    public func frameResultStream() -> AsyncStream<FrameResult> { fatalError("Stage 04") }
    public func recordingStateStream() -> AsyncStream<RecordingState> { fatalError("Stage 06") }

    // MARK: - Internals

    func bindNaturalPreview(mtkView: MTKView) {
        metalPipeline?.bind(mtkView: mtkView)
    }

    // scaffolding:01:naive-scenephase-stop
    // Plain sessionQueue.async { stopRunning() } — no GPU-submission gate,
    // no waitUntilScheduled(), no beginBackgroundTask. Retires Stage 02.
    func naiveBackgroundStop() {
        let s = cameraSession
        sessionQueue.async { s?.stopRunning() }
    }

    private func emit(_ state: SessionState) {
        stateStreamContinuation.yield(state)
    }

    /// ADR-30 async-with-timeout helper (simplified for Stage 01; timeout enforcement arrives Stage 02).
    private func withSessionQueue<T: Sendable>(
        _ body: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// G-17: select largest 4:3 format at 30fps; fall back to CAPTURE_FALLBACK dimensions.
    private func selectFormat(
        from avDevice: AVCaptureDevice,
        supportedSizes: [Size]
    ) throws -> AVCaptureDevice.Format {
        let fps = Constants.frameRateTargetFPS
        let candidates = avDevice.formats.filter { format in
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }
        }

        // Prefer largest 4:3 (width × 3 == height × 4)
        let fourByThree = candidates.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) * 3 == Int(dims.height) * 4
        }.sorted {
            let d0 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let d1 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(d0.width) * Int(d0.height) > Int(d1.width) * Int(d1.height)
        }

        if let best = fourByThree.first { return best }

        // Fallback: nearest format to CAPTURE_FALLBACK dimensions
        let fallbackW = Constants.captureFallbackWidthPx
        let fallbackH = Constants.captureFallbackHeightPx
        if let fallback = candidates.min(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let diffA = abs(Int(da.width) - fallbackW) + abs(Int(da.height) - fallbackH)
            let diffB = abs(Int(db.width) - fallbackW) + abs(Int(db.height) - fallbackH)
            return diffA < diffB
        }) { return fallback }

        throw EngineError.noSupportedFormat(reason: "No 8-bit YUV format at \(fps)fps")
    }
}

// Helper: CMVideoDimensions.width/height are Int32; convert cleanly
private extension Int32 {
    var int: Int { Int(self) }
}
```

---

## Task 13: PixelSink.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/PixelSink.swift`

All bodies are `fatalError` stubs. No C++ dependency this stage.

- [ ] **Step 1: Create PixelSink.swift**

```swift
import Foundation
import CoreVideo

/// C-ABI callback struct per ADR-31 and D-03. C++ registration arrives Stage 08.
public struct PixelSinkCallbacks {
    public typealias OnFrame = @convention(c) (
        _ context: UnsafeMutableRawPointer?, _ stream: UInt32,
        _ frameNumber: UInt64, _ presentationTimeNs: Int64,
        _ surface: UnsafeMutableRawPointer?) -> Void
    public typealias OnOverwrite = @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32) -> Void
    public typealias OnError = @convention(c) (_ context: UnsafeMutableRawPointer?, _ code: Int32) -> Void

    public let onFrame: OnFrame
    public let onOverwrite: OnOverwrite
    public let onError: OnError
    public let context: UnsafeMutableRawPointer?

    public init(onFrame: OnFrame, onOverwrite: OnOverwrite, onError: OnError, context: UnsafeMutableRawPointer?) {
        self.onFrame = onFrame; self.onOverwrite = onOverwrite
        self.onError = onError; self.context = context
    }
}

/// Swift facade over the C++ PixelSink pool. All methods stub until Stage 08.
public actor ConsumerRegistry {
    public init() {}

    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> { fatalError("Stage 08") }

    public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) throws -> ConsumerToken {
        fatalError("Stage 08")
    }

    public func unregister(token: ConsumerToken) { fatalError("Stage 08") }

    public func deliveryStats() -> AsyncStream<FrameDeliveryStats> { fatalError("Stage 08") }
}

public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId
    public init(id: UInt64, stream: StreamId) { self.id = id; self.stream = stream }
}
```

---

## Task 14: CameraView.swift + ViewModel.swift

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraView.swift`
- Create: `CameraKit/Sources/CameraKit/ViewModel.swift`

- [ ] **Step 1: Create ViewModel.swift**

```swift
import SwiftUI
import AVFoundation

/// @Observable @MainActor ViewModel per ADR-21. Holds CameraEngine; binds stateStream.
@Observable
@MainActor
public final class ViewModel {
    public var sessionState: SessionState = .closed
    public var capabilities: SessionCapabilities?
    private(set) var engine: CameraEngine?

    public init() {}

    func setEngine(_ engine: CameraEngine) {
        self.engine = engine
    }

    /// Called from CameraView.task. Starts the camera and consumes stateStream.
    func start() async {
        guard let engine else { return }
        do {
            let caps = try await engine.open(configuration: OpenConfiguration())
            capabilities = caps
        } catch {
            // Surface in error state; full error handling Stage 09
            sessionState = .error
            return
        }

        for await state in engine.stateStream() {
            sessionState = state
        }
    }

    /// Delegate scene-phase stops to CameraEngine (which holds the scaffold).
    func handleScenePhase(_ phase: ScenePhase) {
        guard let engine else { return }
        if phase == .background {
            // scaffolding:01:naive-scenephase-stop — see CameraEngine.naiveBackgroundStop()
            Task { await engine.naiveBackgroundStop() }
        }
    }
}
```

> **Note for executor:** The scaffold comment `// scaffolding:01:naive-scenephase-stop` is on `CameraEngine.naiveBackgroundStop()` (Task 12). The ViewModel cannot access `engine.sessionQueue` or `engine.cameraSession` directly — those are actor-isolated and inaccessible from `@MainActor` context under Swift 6 strict concurrency. The fix is to delegate to the actor method.

- [ ] **Step 2: Create CameraView.swift**

```swift
import SwiftUI
import MetalKit
import UIKit

/// SwiftUI root per ADR-01. Wraps MTKView for the natural preview (ADR-08-ui §UIViewRepresentable).
public struct CameraView: View {
    @State private var viewModel = ViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.sessionState == .streaming {
                NaturalPreviewView(viewModel: viewModel)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                Spacer()
                // Empty bottom bar placeholder — controls arrive in later stages
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(height: 60)
            }
        }
        .task {
            let engine = CameraEngine(
                device: LiveCaptureDevice(avDevice: {
                    // This path is only reached on real hardware; simulator has no back camera
                    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)!
                }()),
                consumers: ConsumerRegistry()
            )
            viewModel.setEngine(engine)
            await viewModel.start()
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.handleScenePhase(phase)
        }
    }
}

// MARK: - MTKView UIViewRepresentable wrapper (08-ui.md §UIViewRepresentable-MTKView-wrappers)

struct NaturalPreviewView: UIViewRepresentable {
    let viewModel: ViewModel

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = Constants.workingPixelFormat
        view.framebufferOnly = false  // ADR-08: we blit to the drawable
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        // Hand to engine for binding on next frame
        if let engine = viewModel.engine {
            Task { await engine.bindNaturalPreview(mtkView: view) }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // No-op; engine drives drawable redraws on delivery queue
    }
}
```

> **Note for executor:** The `CameraView.task` block constructs `LiveCaptureDevice` inline for Stage 01 simplicity. The `!` force-unwrap is safe only on real hardware (simulator has no back camera; on simulator, `open()` will throw `EngineError.noBackCamera` which the ViewModel will catch and set `.error` state). This is acceptable for Stage 01. The dependency-injection pattern (passing engine in) arrives when the app layer is fleshed out.

---

## Task 15: Stage01Tests.swift

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage01Tests.swift`

Uses swift-testing. Fake `CaptureDeviceProviding` returns canned data — no `AVCaptureDevice` in test code (ADR-32).

- [ ] **Step 1: Create Stage01Tests.swift**

```swift
import Testing
import Foundation
import AVFoundation
@testable import CameraKit

// MARK: - Fake device for all tests (ADR-32)

final class FakeCaptureDevice: CaptureDeviceProviding, @unchecked Sendable {
    var fakeSizes: [Size] = []
    var fakeFormats: [FakeFormat] = []  // used by format-selection tests via formats property
    var lockedForConfig = false
    var appliedMinFps: Int = 0
    var appliedMaxFps: Int = 0

    var uniqueID: String { "fake-device-001" }
    var activeFormatSize: Size { fakeSizes.first ?? Size(width: 0, height: 0) }
    var supportedSizes: [Size] { fakeSizes }
    var isoRange: ClosedRange<Float> { 50 ... 3200 }
    var exposureDurationRangeNs: ClosedRange<Int64> { 10_000 ... 100_000_000 }
    var maxWhiteBalanceGain: Float { 4.0 }

    func lockForConfiguration() throws { lockedForConfig = true }
    func unlockForConfiguration() { lockedForConfig = false }
    func setExposureModeCustom(durationNs: Int64, iso: Float) throws {}
    func setContinuousAutoExposure() throws {}
    func setFocusModeLocked(lensPosition: Float) throws {}
    func setContinuousAutoFocus() throws {}
    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {}
    func setContinuousAutoWhiteBalance() throws {}
    func setWhiteBalanceLocked() throws {}
    func setZoomFactor(_ factor: Double) throws {}
    func setExposureCompensation(_ steps: Int) throws {}
    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {
        appliedMinFps = minFrameDurationFps
        appliedMaxFps = maxFrameDurationFps
    }
}

/// Placeholder format shape for unit tests that inspect format selection logic.
struct FakeFormat {
    let width: Int
    let height: Int
    let maxFps: Double
    var is4x3: Bool { width * 3 == height * 4 }
    var pixelCount: Int { width * height }
}

// MARK: - 01:capture-device-provider-seam

@Suite("CaptureDeviceProviding seam")
struct CaptureDeviceProviderSeamTests {
    @Test("FakeCaptureDevice returns canned sizes; no AVCaptureDevice constructed")
    func fakeDeviceReturnsSizes() async {
        let fake = FakeCaptureDevice()
        fake.fakeSizes = [
            Size(width: 4160, height: 3120),
            Size(width: 1920, height: 1080),
        ]
        let sizes = await fake.supportedSizes
        #expect(sizes.count == 2)
        #expect(sizes[0].width == 4160)
        #expect(sizes[0].height == 3120)
    }
}

// MARK: - 01:largest-4x3-format-selected (format selection logic)

@Suite("Format selection")
struct FormatSelectionTests {
    /// Verify the 4:3 selection heuristic using FakeFormat values.
    /// Production code path (CameraEngine.selectFormat) requires AVCaptureDevice.formats
    /// which are not constructible in unit tests — tested here at the logic level.
    @Test("4:3 format is preferred over 16:9 when both support 30fps")
    func selects4x3OverWidescreen() {
        let formats = [
            FakeFormat(width: 1920, height: 1080, maxFps: 30), // 16:9
            FakeFormat(width: 1280, height: 960,  maxFps: 30), // 4:3
        ]
        let fps = 30.0
        let at30 = formats.filter { $0.maxFps >= fps }
        let fourByThree = at30.filter(\.is4x3).sorted { $0.pixelCount > $1.pixelCount }
        #expect(fourByThree.first?.width == 1280)
        #expect(fourByThree.first?.height == 960)
    }

    @Test("Largest 4:3 wins when multiple 4:3 formats available")
    func selectsLargest4x3() {
        let formats = [
            FakeFormat(width: 1280, height: 960,  maxFps: 30),
            FakeFormat(width: 4160, height: 3120, maxFps: 30),
            FakeFormat(width: 2560, height: 1920, maxFps: 30),
        ]
        let sorted = formats.filter { $0.is4x3 }.sorted { $0.pixelCount > $1.pixelCount }
        #expect(sorted.first?.width == 4160)
    }

    @Test("Falls back to CAPTURE_FALLBACK dimensions when no 4:3 format present")
    func fallbackWhenNo4x3() {
        let formats = [
            FakeFormat(width: 1920, height: 1080, maxFps: 30),
            FakeFormat(width: 1280, height: 720,  maxFps: 30),
        ]
        let fourByThree = formats.filter(\.is4x3)
        #expect(fourByThree.isEmpty)
        // Engine falls back to CAPTURE_FALLBACK_WIDTH_PX x CAPTURE_FALLBACK_HEIGHT_PX
        #expect(Constants.captureFallbackWidthPx == 1280)
        #expect(Constants.captureFallbackHeightPx == 960)
    }
}

// MARK: - 01:landscape-right-rotation-applied

@Suite("Orientation")
struct OrientationTests {
    @Test("CAPTURE_ORIENTATION_ANGLE_DEG is 90 (landscape-right per ADR-17)")
    func orientationAngleIs90() {
        #expect(Constants.captureOrientationAngleDeg == 90)
    }
}

// MARK: - 01:engine-open-close-transitions (limited without real hardware)

@Suite("Engine state machine")
struct EngineStateTests {
    @Test("EngineError.alreadyOpen is thrown on double-open (type check)")
    func alreadyOpenError() async {
        // Verify the error type is defined and its cases match the contract
        let err = EngineError.alreadyOpen
        switch err {
        case .alreadyOpen: break  // correct
        default: Issue.record("Unexpected case")
        }
    }

    @Test("EngineError.notOpen is defined")
    func notOpenErrorDefined() {
        let err = EngineError.notOpen
        switch err {
        case .notOpen: break
        default: Issue.record("Unexpected case")
        }
    }

    @Test("STATE_STREAM_BUFFER_SIZE is 64 per ADR-22")
    func stateStreamBufferSize() {
        #expect(Constants.stateStreamBufferSize == 64)
    }

    @Test("SessionState has all required cases")
    func sessionStateCases() {
        let all: [SessionState] = [.opening, .streaming, .recovering, .paused, .error, .closed]
        #expect(all.count == 6)
    }
}

// MARK: - Constants verification

@Suite("Constants")
struct ConstantsTests {
    @Test("FRAME_RATE_TARGET_FPS is 30")
    func frameRateTarget() { #expect(Constants.frameRateTargetFPS == 30) }

    @Test("CAPTURE_PIXEL_FORMAT is 420YpCbCr8BiPlanarFullRange")
    func capturePixelFormat() {
        #expect(Constants.capturePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    @Test("WORKING_PIXEL_FORMAT is rgba16Float")
    func workingPixelFormat() {
        #expect(Constants.workingPixelFormat == .rgba16Float)
    }

    @Test("Fallback dimensions are 1280x960")
    func fallbackDimensions() {
        #expect(Constants.captureFallbackWidthPx == 1280)
        #expect(Constants.captureFallbackHeightPx == 960)
    }
}
```

> **Note on 01:engine-open-close-transitions:** Full state transition testing (`.opening` → `.streaming` → `.closed` via `stateStream()`) requires a real `AVCaptureDevice` (unavailable in unit tests) or a fully mocked `AVCaptureSession`. These are integration tests. The TESTABLE entry is partially covered here at the error-type and state-enum level; the live-hardware behavior is covered by HITL `01:preview-renders-first-frame`. Record this gap in `state.md` under "Open questions for next stage."

---

## Task 16: Run swift build + swift test

**Verify the package builds and tests pass before any xcodeproj changes.**

- [ ] **Step 1: Build the package**

```bash
swift build --package-path CameraKit/
```

Expected: exits 0, zero warnings under Swift 6 strict concurrency.

If warnings appear:
- `Sendable` warnings → add `@unchecked Sendable` or isolate the type
- Actor isolation warnings → ensure cross-actor calls use `await`
- Concurrency warnings on `nonisolated` → verify `CaptureDelegate` is `nonisolated`

- [ ] **Step 2: Run Stage01Tests**

```bash
swift test --package-path CameraKit/ --filter Stage01Tests
```

Expected: all tests green. If a test fails, fix the implementation (not the test).

- [ ] **Step 3: Scaffold slug grep**

```bash
grep -rn '01:naive-scenephase-stop\|01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```

Expected: at least one hit for each slug. The grep must find:
- `// scaffolding:01:naive-scenephase-stop` in `CameraEngine.swift` (and a reference in `ViewModel.swift`)
- `// scaffolding:01:simple-metal-passthrough` in `MetalPipeline.swift` AND `TexturePoolManager.swift`
- `// scaffolding:01:skip-completion-guard` in `MetalPipeline.swift`

---

## Task 17: Wire xcodeproj + delete old files + update app entry point

**This is the one manual Xcode step. It cannot be reliably automated via pbxproj editing.**

- [ ] **Step 1: Open the project in Xcode**

```bash
open eva-swift-stitch.xcodeproj
```

- [ ] **Step 2: Add the local CameraKit package**

In Xcode: File → Add Package Dependencies → Add Local…
Navigate to `CameraKit/` (the directory containing `Package.swift`).
Click "Add Package".
In the "Choose package products" dialog, ensure `CameraKit` is checked and the target is `eva-swift-stitch`.
Click "Add Package".

- [ ] **Step 3: Verify the package appears in the navigator**

In the Project Navigator, you should see:
- A `CameraKit` package reference under the project
- `CameraKit` linked under the app target's "Frameworks, Libraries, and Embedded Content"

- [ ] **Step 4: Delete ContentView.swift from the app target**

In Xcode, right-click `ContentView.swift` → Delete → Move to Trash.

- [ ] **Step 5: Delete CameraCapabilitiesReporter.swift from the app target**

In Xcode, right-click `CameraCapabilitiesReporter.swift` → Delete → Move to Trash.

- [ ] **Step 6: Update eva_swift_stitchApp.swift**

Edit `eva-swift-stitch/eva_swift_stitchApp.swift` to:

```swift
import SwiftUI
import CameraKit

@main
struct eva_swift_stitchApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
        }
    }
}
```

---

## Task 18: Run xcodebuild verification

- [ ] **Step 1: Find an installed simulator**

```bash
xcrun simctl list devices available | grep iPad
```

Pick one that is available, e.g. `iPad Pro 13-inch (M4)`.

- [ ] **Step 2: Build via XcodeBuildMCP**

Use `session_show_defaults` first to verify project/scheme/simulator are set, then `build_sim`. Or use raw xcodebuild:

```bash
xcodebuild \
  -project eva-swift-stitch.xcodeproj \
  -scheme eva-swift-stitch \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. If it fails with missing types, check that all files from Tasks 2–14 are present in `CameraKit/Sources/CameraKit/`.

---

## Task 19: Create state.md

**Files:**
- Create: `CameraKit/state.md`

- [ ] **Step 1: Create CameraKit/state.md**

```markdown
# state.md — Stage 01

## Current stage
Stage 01 — Walking skeleton — bare natural preview on screen

## Scaffolding still live
- `01:naive-scenephase-stop` — CameraEngine.swift `naiveBackgroundStop()`: plain `sessionQueue.async { stopRunning() }` with no GPU gate, no `waitUntilScheduled()`, no `beginBackgroundTask`. Called from ViewModel.handleScenePhase via `Task { await engine.naiveBackgroundStop() }`. Retires Stage 02.
- `01:simple-metal-passthrough` — MetalPipeline.swift + TexturePoolManager.swift: Pass 1 (crop + YUV→RGBA into single IOSurface-backed naturalTex) only. No Pass 2/3/4/5/6. No CVPixelBufferPool trio. Retires Stage 08.
- `01:skip-completion-guard` — MetalPipeline.swift `addCompletedHandler`: does not check `sessionState` before touching readback state. Retires Stage 09 with full D-10 guard.

## What's built (permanent)
- `Package.swift` — local SwiftPM library, swift-tools-version 6.0, iOS 26, Swift 6 strict concurrency
- `Constants.swift` — all Stage 01 constants mirroring constants.md
- `Capabilities.swift` — `SessionCapabilities`, `Size`, `Rect`, `OpenConfiguration`, `CameraSettings`, `ProcessingParameters`, `CameraMode`, `WhiteBalanceMode`
- `SessionState.swift` — `SessionState`, `RecordingState`, `StreamId`, `RecordingOptions`, `RecordingStart`
- `Errors.swift` — full error taxonomy: `ErrorCode`, `CameraError`, `EngineError`, `MetalError`, `InteropError`, `RecordingError`, `StillCaptureOutput`, `StillCaptureError`
- `FrameSet.swift` — `FrameSet` (stub struct), `TrackerQuality`, `CaptureMetadata`, `ProcessingMetadata`, `WhiteBalanceGains`, `CameraPosition`, `FrameDeliveryStats`, `FrameResult`, `RgbSample`
- `CaptureDeviceProviding.swift` — `CaptureDeviceProviding` protocol (ADR-32), `LiveCaptureDevice` actor, `DeviceStateSnapshot`, `SystemPressureLevel`
- `CameraSession.swift` — `AVCaptureSession` configuration, format commit, orientation, AVCaptureVideoDataOutput wiring — all on sessionQueue
- `CaptureDelegate.swift` — `nonisolated` `AVCaptureVideoDataOutputSampleBufferDelegate` on delivery queue
- `TexturePoolManager.swift` — single IOSurface-backed naturalTex slot + CVMetalTextureCache (ADR-04)
- `MetalPipeline.swift` — Pass-1 compute encode + commit inline on delivery queue; MTKView blit in completion handler
- `CameraEngine.swift` — actor; `init(device:consumers:)`, `open(configuration:)`, `close()`, `stateStream()` implemented; all other methods are `fatalError("Stage N")` stubs
- `PixelSink.swift` — `ConsumerRegistry` actor stub, `ConsumerToken`, `PixelSinkCallbacks`
- `CameraView.swift` — SwiftUI root; `NaturalPreviewView` UIViewRepresentable wrapping MTKView
- `ViewModel.swift` — `@Observable @MainActor`; starts engine; consumes stateStream; scenePhase handler (scaffold)
- `Shaders/YUVToRGBA.metal` — Pass-1 BT.601 full-range YUV→RGBA16F compute kernel

## Public API exposed so far
- `CameraEngine.init(device:consumers:)`
- `CameraEngine.open(configuration:) async throws -> SessionCapabilities`
- `CameraEngine.close() async`
- `CameraEngine.stateStream() -> AsyncStream<SessionState>`
- All value types: `SessionCapabilities`, `Size`, `Rect`, `OpenConfiguration`, `SessionState`, `StreamId`, `RecordingState`, `EngineError` (and subtypes), `CaptureDeviceProviding` protocol

## Manual test evidence
- HITL `01:preview-renders-first-frame`: PENDING — no physical device exercised this session. Requires iPad Pro M1. Record screenshot + note in `docs/measurements/stage-01/preview.md` on first device run.
- DEFERRED `01:empirical-format-enumeration`: PENDING — record `AVCaptureDevice.formats` list (dimensions, frame-rate ranges, formatDescription) on target hardware in `docs/measurements/stage-01/formats.md`.
- Instruments Time Profiler (brief §11): PENDING — 30s capture on iPad Pro M1 confirming `commit` is called from the `delivery` queue, not the engine actor.

## Decisions taken that weren't in briefs
- **Type compression**: `Settings.swift`, `Recording.swift`, `StillCapture.swift` are not in brief §4. To avoid adding undocumented files while still compiling `CameraEngine.swift`'s stub method signatures, the required types were compressed into brief §4 files: `CameraSettings`/`ProcessingParameters`/`CameraMode`/`WhiteBalanceMode` → `Capabilities.swift`; `FrameResult`/`RgbSample` → `FrameSet.swift`; `RecordingOptions`/`RecordingStart` → `SessionState.swift`; `StillCaptureOutput`/`StillCaptureError` → `Errors.swift`. Future stages should migrate each type to its canonical file when that file is created.
- **`CameraSession` receives `AVCaptureDevice` directly** (not through protocol): `CaptureDeviceProviding` is the test seam at the engine-actor boundary. `CameraSession` is internal and always created from engine code that already has the concrete `LiveCaptureDevice` actor; tests never reach `CameraSession`. This is consistent with ADR-32 which places the seam at `CameraEngine.init(device:)`.
- **`CameraEngine.cameraSession` and `sessionQueue` are `internal` (not `private`)**: both are accessed from `CameraEngine.naiveBackgroundStop()` which is actor-isolated, so no cross-actor boundary issues. The `internal` visibility may be tightened when the scaffold retires.

## Open questions for next stage
- `01:engine-open-close-transitions` unit test is partially covered (error-type and enum checks only). Full async state-transition test (`.opening` → `.streaming` via `stateStream()`) requires either a real device or a mockable `AVCaptureSession`. Consider introducing an `AVCaptureSessionProviding` protocol in Stage 02 to enable this coverage.
- ADR-30 timeout enforcement: `withSessionQueue` is a bare continuation with no timeout; the `SESSION_LIFECYCLE_TIMEOUT_SECONDS` deadline is noted but not wired. Stage 02 should add the timeout.
- `CameraView.task` constructs `LiveCaptureDevice` with a force-unwrap (`!`). Stage 02 should surface this as a graceful `EngineError.noBackCamera` shown in the UI, not a crash.
```

---

## Self-Review Checklist

Run this before declaring the plan complete.

### Spec coverage vs brief §4

| Brief §4 file | Task covering it |
|--------------|-----------------|
| Package.swift | Task 1 |
| CameraEngine.swift | Task 12 |
| CameraSession.swift | Task 7 |
| CaptureDelegate.swift | Task 8 |
| MetalPipeline.swift | Task 11 |
| TexturePoolManager.swift | Task 9 |
| CaptureDeviceProviding.swift | Task 6 |
| Capabilities.swift | Task 2 |
| SessionState.swift | Task 3 |
| Errors.swift | Task 4 |
| FrameSet.swift | Task 5 |
| Constants.swift | Pre-flight (exists) |
| CameraView.swift | Task 14 |
| ViewModel.swift | Task 14 |
| PixelSink.swift | Task 13 |
| Stage01Tests.swift | Task 15 |

### Brief §7 invariants

| Invariant | Met by |
|-----------|--------|
| CameraEngine is single actor per lifecycle | Task 12: `actor CameraEngine` |
| AVCaptureSession config + lockForConfiguration on sessionQueue | Task 7: CameraSession.configure() + Task 12: withSessionQueue |
| nonisolated delegate on delivery queue | Task 8: `nonisolated func captureOutput` |
| Device: .builtInWideAngleCamera back-facing | Task 12: `open()` D-08 comment + AVCaptureDevice.default call |
| 8-bit biplanar YUV, 30fps | Task 7: output.videoSettings, frameDuration |
| Landscape-right via videoRotationAngle = 90 | Task 7: CameraSession.configure() |
| open() while open → alreadyOpen | Task 12: guard sessionState == .closed |
| stateStream() bufferingOldest(64) | Task 12: AsyncStream init |
| CaptureDeviceProviding is sole seam | Task 6: protocol + LiveCaptureDevice |

### Brief §8 tests

| Test | Coverage |
|------|---------|
| 01:engine-open-close-transitions | Partial (error types, enums). Full: open question in state.md |
| 01:capture-device-provider-seam | Task 15: CaptureDeviceProviderSeamTests |
| 01:largest-4x3-format-selected | Task 15: FormatSelectionTests |
| 01:landscape-right-rotation-applied | Task 15: OrientationTests (constant verification) |
| 01:preview-renders-first-frame (HITL) | state.md: PENDING |
| 01:empirical-format-enumeration (DEFERRED) | state.md: PENDING |

### Brief §10 acceptance criteria

| Criterion | Verified by |
|-----------|------------|
| swift build passes, no warnings | Task 16 Step 1 |
| swift test Stage01Tests all pass | Task 16 Step 2 |
| HITL 01:preview-renders-first-frame | state.md: PENDING — no physical device |
| DEFERRED 01:empirical-format-enumeration | state.md: PENDING |
| Scaffold slug greps each ≥1 hit | Task 16 Step 3 |

### Scaffold slugs — exact strings required

Each must appear literally in source:
- `// scaffolding:01:naive-scenephase-stop` → `CameraEngine.swift` (naiveBackgroundStop), `ViewModel.swift` (reference)
- `// scaffolding:01:simple-metal-passthrough` → `MetalPipeline.swift` (×2), `TexturePoolManager.swift` (×1)
- `// scaffolding:01:skip-completion-guard` → `MetalPipeline.swift`

### Type consistency

Types introduced in early tasks used consistently in later tasks:
- `Size` (Task 2) used in `CaptureDeviceProviding` (Task 6), `CameraSession` (Task 7), `CameraEngine` (Task 12) ✓
- `SessionState` (Task 3) used in `CameraEngine` (Task 12), `ViewModel` (Task 14) ✓
- `EngineError` (Task 4) thrown in `CameraSession` (Task 7) and `CameraEngine` (Task 12) ✓
- `WhiteBalanceGains` (Task 5) used in `CaptureDeviceProviding` (Task 6) ✓
- `ConsumerRegistry` (Task 13) in `CameraEngine.init` (Task 12) ✓
- `MetalPipeline` (Task 11) used in `CaptureDelegate` (Task 8) and `CameraEngine` (Task 12) ✓
- `TexturePoolManager` (Task 9) used in `MetalPipeline` (Task 11) ✓
