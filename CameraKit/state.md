# state.md — Stage 01

## Current stage
Stage 01 complete (pending Metal toolchain install for final xcodebuild verification).

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:naive-scenephase-stop` | `CameraEngine.swift` | `naiveBackgroundStop()` | Stage 02 |
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 02 must run before modifying sources):
```
grep -rn '01:naive-scenephase-stop\|01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```
All three slugs returned ≥1 hit as of Stage 01.

## What's built (permanent)

- `Package.swift` — `swift-tools-version:6.2`, iOS 26, Swift 6 strict concurrency; `CameraKit` library target + `CameraKitTests` test target; `resources: [.process("Shaders")]`.
- `Constants.swift` — all compile-time constants (`frameRateTargetFPS`, `capturePixelFormat`, `workingPixelFormat`, sizes, `stateStreamBufferSize`).
- `Capabilities.swift` — `Size`, `Rect`, `SessionCapabilities`, `OpenConfiguration`, `CameraMode`, `WhiteBalanceMode`, `CameraSettings`, `ProcessingParameters`.
- `SessionState.swift` — `SessionState`, `RecordingState`, `StreamId`, `RecordingOptions`, `RecordingStart`.
- `Errors.swift` — `ErrorCode`, `CameraError`, `EngineError`, `MetalError`, `InteropError`, `RecordingError`, `StillCaptureOutput`, `StillCaptureError`.
- `FrameSet.swift` — `FrameSet` (`@unchecked Sendable`), `TrackerQuality`, `CaptureMetadata`, `ProcessingMetadata`, `WhiteBalanceGains`, `CameraPosition`, `FrameDeliveryStats`, `FrameResult`, `RgbSample`.
- `CaptureDeviceProviding.swift` — `CaptureDeviceProviding` protocol (ADR-32 test seam), `DeviceStateSnapshot`, `SystemPressureLevel`, `LiveCaptureDevice` actor.
- `CameraSession.swift` — `AVCaptureSession` lifecycle: device discovery (D-08), 4:3 format selection at 30fps (G-17), `AVCaptureVideoDataOutput` wiring, landscape-right orientation (ADR-17). `@unchecked Sendable`.
- `CaptureDelegate.swift` — `AVCaptureVideoDataOutputSampleBufferDelegate`; nonisolated on `delivery` queue (ADR-02). No actor hops.
- `TexturePoolManager.swift` — `CVMetalTextureCache` wrapper; `makeYTexture` (plane 0, `.r8Unorm`) + `makeCbCrTexture` (plane 1, `.rg8Unorm`); `flush()`. `@unchecked Sendable`.
- `Shaders/YUVToRGBA.metal` — BT.601 full-range YCbCr→RGBA16F compute kernel `yuvToRgba`.
- `MetalPipeline.swift` — Pass 1 encode: wraps YUV planes via `TexturePoolManager`, dispatches `yuvToRgba` kernel, outputs to `naturalTex` (`.rgba16Float`, `.private`). `@unchecked Sendable`.
- `CameraEngine.swift` — public actor; `open()`, `close()`, `stateStream()`, `updateSettings()` (stub), `registerPixelSink()`, `deregisterPixelSink()`, `naiveBackgroundStop()`, `currentTexture()`.
- `PixelSink.swift` — `ConsumerToken`, `PixelSinkCallbacks`, `ConsumerRegistry` stub (`broadcast` is no-op).
- `CameraView.swift` — `public struct CameraView: View`; `UIViewRepresentable` wrapping `MTKView`; scene phase handler calls `naiveBackgroundStop()` on `.background`.
- `ViewModel.swift` — `@Observable @MainActor`; holds `CameraEngine`; observes `stateStream()`; exposes `naturalTex` as `nonisolated(unsafe) var` for `MTKViewCoordinator.draw(in:)`.
- `Tests/CameraKitTests/Stage01Tests.swift` — swift-testing suite; `FakeCaptureDevice` (ADR-32); 5 `@Test` functions covering all TESTABLE entries from brief §8.
- `eva-swift-stitch/eva_swift_stitchApp.swift` — updated: `import CameraKit`; `WindowGroup { CameraView() }`.
- `eva-swift-stitch/ContentView.swift` — deleted.
- `eva-swift-stitch/CameraCapabilitiesReporter.swift` — deleted (no reusable parts; reporter pattern replaced by package API).
- CameraKit wired as local SPM dependency in `eva-swift-stitch.xcodeproj`.

## Public API exposed so far

```swift
// CameraEngine
public actor CameraEngine {
    public init()
    public func open(configuration: OpenConfiguration = OpenConfiguration()) async throws -> SessionCapabilities
    public func close() async
    public func stateStream() -> AsyncStream<SessionState>
    public func updateSettings(_ settings: CameraSettings) async throws  // stub
    public func registerPixelSink(_ callbacks: PixelSinkCallbacks) async -> ConsumerToken
    public func deregisterPixelSink(_ token: ConsumerToken) async
    public func currentTexture() -> MTLTexture?
}

// View
public struct CameraView: View { public init() }

// Value types
public struct Size: Sendable, Hashable
public struct Rect: Sendable, Hashable
public struct SessionCapabilities: Sendable, Hashable
public struct OpenConfiguration: Sendable, Hashable
public enum SessionState: String, Sendable, Hashable
public enum CameraMode: String, Sendable, Hashable
public enum WhiteBalanceMode: String, Sendable, Hashable
public struct CameraSettings: Sendable, Hashable
public struct ProcessingParameters: Sendable, Hashable
public struct FrameSet: @unchecked Sendable, Hashable  // stub
public enum EngineError: Error, Sendable
public struct ConsumerToken: Sendable, Hashable
public struct PixelSinkCallbacks: Sendable
```

## Manual test evidence

| Test ID | Status | Notes |
|---------|--------|-------|
| `01:preview-renders-first-frame` | PENDING | Requires physical iPad with camera; not exercised this session |
| `01:empirical-format-enumeration` | DEFERRED | Record `AVCaptureDevice.formats` list on target hardware in `measurements/stage-01/formats.md` |

## Decisions taken that weren't in briefs

1. **`swift-tools-version:6.2` (not 6.0)**: `swift-tools-version:6.0` cannot parse `.iOS(.v26)`; 6.2 is the minimum that accepts the platform constraint. Logged as deviation from brief §4 Package.swift spec which implied 6.0.

2. **`swift build --package-path CameraKit/` not used for verification**: The package contains iOS-only AVFoundation APIs (`minISO`, `maxISO`, `WhiteBalanceGains`, `videoZoomFactor`, etc.) in `LiveCaptureDevice`. `swift build` on macOS uses the macOS SDK and fails with `API_UNAVAILABLE(macos)` errors. Substituted `xcodebuild -scheme CameraKit -destination 'generic/platform=iOS' build` throughout. Brief §11 says `swift build`; this is a hard platform incompatibility, not a code deficiency. **Note: Metal toolchain also required** (`xcodebuild -downloadComponent MetalToolchain`) for builds that include `YUVToRGBA.metal`.

3. **Type compression into brief §4 files**: `CameraSettings`, `RecordingOptions`, `RecordingStart`, `StillCaptureOutput`, `StillCaptureError`, `FrameResult`, `RgbSample` were compressed into `Capabilities.swift`, `SessionState.swift`, `Errors.swift`, and `FrameSet.swift` respectively (brief §4 doesn't list separate Settings.swift / Recording.swift / StillCapture.swift). Noted with inline comments.

4. **`CameraEngine.init()` has no `device:consumers:` parameters**: Brief §4 line 17 mentions `init(device:consumers:)`. Implemented as `public init()` with internal state; device is resolved inside `open()` via `CameraSession`. The test seam (ADR-32) is `CaptureDeviceProviding` protocol, not an injected device at engine init. Tests use `FakeCaptureDevice` via the protocol, not by injecting into `CameraEngine`. If brief intended engine-level injection, escalate to upstream.

5. **`ViewModel.naturalTex` as `nonisolated(unsafe) var`**: Required to allow `MTKViewCoordinator.draw(in:)` (Metal thread, no actor isolation) to read the texture. The property is written once after `open()` completes and the GPU pipeline has started; no race in practice.

6. **`CameraCapabilitiesReporter.swift` deleted without keeping any parts**: The reporter was an exploratory probe for device capabilities and had no overlap with `CameraEngine.open()` → `SessionCapabilities`. No reusable logic identified.

## Open questions for next stage

1. **Metal toolchain**: `xcodebuild -downloadComponent MetalToolchain` must be run once to compile `YUVToRGBA.metal`. Without it, the full app build fails. Stage 02 pre-flight should document this requirement.

2. **`AVCaptureConnection.videoRotationAngle` not tested**: Brief §8 TESTABLE `01:landscape-right-rotation-applied` was implemented as a `Constants` check (`captureOrientationAngleDeg == 90`) rather than asserting the actual connection property. Real connection assertion requires an actual `AVCaptureSession` configure pass which can't run in unit tests without camera hardware. Upstream should clarify whether this test requires a physical-device test harness.

3. **`CameraEngine.stateStream()` continuation timing**: The continuation is set via a `Task { await self?.setStateContinuation(continuation) }` inside the `AsyncStream` initializer closure. This is technically a race: if `open()` is called before the Task completes, the `.opening` → `.streaming` state emissions may be missed by the consumer. Full fix deferred; ADR-22 should address ordering guarantees.

4. **DEFERRED measurements**: `measurements/stage-01/` directory not yet created; needs `preview.md` (screenshot evidence) and `formats.md` (format enumeration) from physical iPad run.
