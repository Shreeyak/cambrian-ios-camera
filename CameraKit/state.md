# state.md — Stage 02

## Current stage
Stage 02 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 03 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```
Both slugs returned ≥1 hit as of Stage 02.

## What's built (permanent)

- `Package.swift` — `swift-tools-version:6.2`, iOS 26, Swift 6 strict concurrency; `CameraKit` library target + `CameraKitTests` test target; `resources: [.process("Shaders")]`; `swift-atomics 1.3.0` dependency (`Atomics` product).
- `Constants.swift` — all compile-time constants including `sessionLifecycleTimeoutSeconds: Double = 2.0` (ADR-30).
- `Capabilities.swift` — `Size`, `Rect`, `SessionCapabilities`, `OpenConfiguration`, `CameraMode`, `WhiteBalanceMode`, `CameraSettings`, `ProcessingParameters`.
- `SessionState.swift` — `SessionState`, `RecordingState`, `StreamId`, `RecordingOptions`, `RecordingStart`.
- `Errors.swift` — `ErrorCode`, `CameraError`, `EngineError`, `MetalError`, `InteropError`, `RecordingError`, `StillCaptureOutput`, `StillCaptureError`.
- `FrameSet.swift` — `FrameSet` (`@unchecked Sendable`), `TrackerQuality`, `CaptureMetadata`, `ProcessingMetadata`, `WhiteBalanceGains`, `CameraPosition`, `FrameDeliveryStats`, `FrameResult`, `RgbSample`.
- `CaptureDeviceProviding.swift` — `CaptureDeviceProviding` protocol (ADR-32 test seam), `DeviceStateSnapshot`, `SystemPressureLevel`, `LiveCaptureDevice` actor.
- `CameraSession.swift` — `AVCaptureSession` lifecycle: device discovery (D-08), 4:3 format selection at 30fps (G-17), `AVCaptureVideoDataOutput` wiring, landscape-right orientation (ADR-17). `startRunningAsync()` / `stopRunningAsync()` via `runOnQueue` (ADR-30). `@unchecked Sendable`.
- `CaptureDelegate.swift` — `AVCaptureVideoDataOutputSampleBufferDelegate`; nonisolated on `delivery` queue (ADR-02). Gate check enforced downstream in `MetalPipeline.encode()`. No actor hops.
- `TexturePoolManager.swift` — `CVMetalTextureCache` wrapper; `makeYTexture` (plane 0, `.r8Unorm`) + `makeCbCrTexture` (plane 1, `.rg8Unorm`); `flush()`. `@unchecked Sendable`.
- `Shaders/YUVToRGBA.metal` — BT.601 full-range YCbCr→RGBA16F compute kernel `yuvToRgba`.
- `MetalPipeline.swift` — Pass 1 encode: wraps YUV planes via `TexturePoolManager`, dispatches `yuvToRgba` kernel, outputs to `naturalTex` (`.rgba16Float`, `.private`). Gate check (ADR-09) after CPU-side encode, immediately before `commit()`. `drainLastBuffer()` for `waitUntilScheduled()` drain. `@unchecked Sendable`.
- `AsyncWithTimeout.swift` — `runOnQueue(_:timeout:_:)` helper (ADR-30): `ManagedAtomic<Bool>` CAS race between work branch and deadline branch; non-throwing; caller observes state stall on timeout.
- `CameraEngine.swift` — public actor; `open()`, `close()`, `stateStream()`, `updateSettings()` (stub), `registerPixelSink()`, `deregisterPixelSink()`, `backgroundSuspend()`, `backgroundResume()`, `setGate(_:)`, `drainSubmittedFrame()`, `currentTexture()`. `submissionGate: ManagedAtomic<Bool>` shared with `MetalPipeline`.
- `PixelSink.swift` — `ConsumerToken`, `PixelSinkCallbacks`, `ConsumerRegistry` stub (`broadcast` is no-op).
- `CameraView.swift` — `public struct CameraView: View`; `UIViewRepresentable` wrapping `MTKView`; `.task(id: scenePhase)` calls `viewModel.handleScenePhase(_:)`.
- `ViewModel.swift` — `@Observable @MainActor`; holds `CameraEngine`; observes `stateStream()`; `handleScenePhase(_:)` implements D-06 strict gate policy; tracks `previousPhase` to distinguish `.active`-from-`.inactive` vs `.active`-from-`.background`.
- `Tests/CameraKitTests/Stage01Tests.swift` — swift-testing suite; 5 `@Test` functions covering all Stage 01 TESTABLE entries.
- `Tests/CameraKitTests/Stage02Tests.swift` — swift-testing suite; 4 `@Test` functions covering all Stage 02 TESTABLE entries.
- `eva-swift-stitch/eva_swift_stitchApp.swift` — `import CameraKit`; `WindowGroup { CameraView() }`.
- CameraKit wired as local SPM dependency in `eva-swift-stitch.xcodeproj`.
- `eva-swift-stitch.xcodeproj/xcshareddata/xcschemes/eva-swift-stitch.xcscheme` — shared scheme with `eva-swift-stitchTests` in test action (host-app test runner for device testing).
- `eva-swift-stitchTests` — Stage01Tests.swift + Stage02Tests.swift wired as sources; CameraKit added as package product dependency; `TEST_HOST` = `eva-swift-stitch.app`.

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
    public func backgroundSuspend() async
    public func backgroundResume() async
    public func currentTexture() -> (any MTLTexture)?
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
| `02:notification-banner-freezes-preview` | PASS | Preview froze on last frame with Notification Center visible; resumed on dismiss. Gate open/close confirmed. Evidence: `measurements/stage-02/scenephase.md`. Device: Shreeyak's iPad (iPad8,9, iOS 26.4.1). |
| `02:background-stops-session-cleanly` | PASS (partial) | No crash on backgrounding (no MTLCommandBufferErrorNotPermitted). Preview frozen on return — expected: backgroundResume() does not call startRunning() in Stage 02 (see Decision #9). Evidence: `measurements/stage-02/scenephase.md`. |

## Decisions taken that weren't in briefs

1. **`swift-tools-version:6.2` (not 6.0)**: `swift-tools-version:6.0` cannot parse `.iOS(.v26)`; 6.2 is the minimum that accepts the platform constraint. Logged as deviation from brief §4 Package.swift spec which implied 6.0.

2. **`swift build --package-path CameraKit/` not used for verification**: The package contains iOS-only AVFoundation APIs (`minISO`, `maxISO`, `WhiteBalanceGains`, `videoZoomFactor`, etc.) in `LiveCaptureDevice`. `swift build` on macOS uses the macOS SDK and fails with `API_UNAVAILABLE(macos)` errors. Substituted `scripts/test-summary.sh --scheme eva-swift-stitch --destination 'platform=iOS,id=<device>'` throughout. Brief §11 says `swift build`; this is a hard platform incompatibility, not a code deficiency.

3. **Type compression into brief §4 files**: `CameraSettings`, `RecordingOptions`, `RecordingStart`, `StillCaptureOutput`, `StillCaptureError`, `FrameResult`, `RgbSample` were compressed into `Capabilities.swift`, `SessionState.swift`, `Errors.swift`, and `FrameSet.swift` respectively (brief §4 doesn't list separate Settings.swift / Recording.swift / StillCapture.swift). Noted with inline comments.

4. **`CameraEngine.init()` has no `device:consumers:` parameters**: Brief §4 line 17 mentions `init(device:consumers:)`. Implemented as `public init()` with internal state; device is resolved inside `open()` via `CameraSession`. The test seam (ADR-32) is `CaptureDeviceProviding` protocol, not an injected device at engine init. Tests use `FakeCaptureDevice` via the protocol, not by injecting into `CameraEngine`. If brief intended engine-level injection, escalate to upstream.

5. **`ViewModel.naturalTex` as `nonisolated(unsafe) var`**: Required to allow `MTKViewCoordinator.draw(in:)` (Metal thread, no actor isolation) to read the texture. The property is written once after `open()` completes and the GPU pipeline has started; no race in practice.

6. **`CameraCapabilitiesReporter.swift` deleted without keeping any parts**: The reporter was an exploratory probe for device capabilities and had no overlap with `CameraEngine.open()` → `SessionCapabilities`. No reusable logic identified.

7. **Gate check only in `MetalPipeline.encode()`, not in `CaptureDelegate`**: Brief §4 describes CaptureDelegate as "reading the gate after encoding and before commit". Architecture 02-concurrency.md §Sequence A and ADR-09 specify the check must be "after CPU-side work, immediately before commit()" — that site is in `MetalPipeline.encode()`, not `CaptureDelegate.captureOutput()`. CaptureDelegate modification is a doc-comment update only. Logged here to close the brief ambiguity.

8. **`AsyncWithTimeout` uses `ManagedAtomic<Bool>` CAS, not `withThrowingTaskGroup`**: The `withThrowingTaskGroup` pattern from `ios-platform-guide/02-concurrency.md` blocks on group teardown, waiting for all child tasks to complete. A hung `withCheckedContinuation` (blocking dispatch queue thread) does not respond to task cancellation, causing `group.cancelAll()` to block until the continuation resumes (potentially seconds). The `ManagedAtomic<Bool>` CAS race resumes the outer continuation exactly once without waiting for the losing branch — correct behavior per ADR-30's "never throw" contract. Verified empirically: `withThrowingTaskGroup` took 5s on device; `ManagedAtomic` approach took 150ms as specified.

9. **`backgroundResume()` does not call `startRunning()`**: Architecture `03-camera-session.md` §Background suspend and resume describes eventual-stage behavior where `startRunning()` is triggered by `AVCaptureSessionInterruptionEnded`. Per `08-ui.md` L100: "no session restart triggered from UI". Stage 02 implements gate-only resume; session restart via interruption observer arrives in a later stage. Brief test `02:background-resume-is-noop-until-interruption-ended` confirms this is the intended Stage 02 behavior.

10. **CameraKitTests wired into `eva-swift-stitchTests` for device testing**: Apple prohibits "tool-hosted testing" on physical device destinations (only simulator supports it). Added Stage01Tests.swift and Stage02Tests.swift as sources to `eva-swift-stitchTests` (which has `eva-swift-stitch.app` as test host via `TEST_HOST` build setting). Created `eva-swift-stitch.xcscheme` as a shared scheme. All 9 tests (5 Stage01 + 4 Stage02) run and pass on Shreeyak's iPad.

## Open questions for next stage

1. **Metal toolchain**: `xcodebuild -downloadComponent MetalToolchain` must be run once to compile `YUVToRGBA.metal`. Without it, the full app build fails. Stage 03 pre-flight should document this requirement.

2. **`AVCaptureConnection.videoRotationAngle` not tested**: Brief §8 TESTABLE `01:landscape-right-rotation-applied` was implemented as a `Constants` check (`captureOrientationAngleDeg == 90`) rather than asserting the actual connection property. Real connection assertion requires an actual `AVCaptureSession` configure pass which can't run in unit tests without camera hardware. Upstream should clarify whether this test requires a physical-device test harness.

3. **`CameraEngine.stateStream()` continuation timing**: The continuation is set via a `Task { await self?.setStateContinuation(continuation) }` inside the `AsyncStream` initializer closure. This is technically a race: if `open()` is called before the Task completes, the `.opening` → `.streaming` state emissions may be missed by the consumer. Full fix deferred; ADR-22 should address ordering guarantees.

4. **DEFERRED measurements**: `measurements/stage-01/` and `measurements/stage-02/` directories not yet created; need physical-device HITL evidence.
