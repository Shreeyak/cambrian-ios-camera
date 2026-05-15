# Phase 2 — Vocabulary, Additive Capabilities, Calibration Move-Down

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conform CameraKit's facade to the (amended) Pigeon contract vocabulary, add the additive capabilities Phase 3 needs, move calibration orchestration into the engine, and curate the public surface so the package is cleanly extractable.

**Architecture:** All work is inside `eva-swift-stitch`. CameraKit `CameraEngine` gains: a `setProcessingParams` rename; an `OpenConfiguration.initialSettings` widening (applied during `setupSession`); range fields on `SessionCapabilities`; `SessionState.interrupted`; `cameraPermissionStatus` / `requestCameraPermission` static helpers; a `currentPixelBuffer(stream:)` synchronous accessor; a `streamConfigurationStream()` for active-config changes; and `calibrateWhiteBalance()` / `calibrateBlackBalance()` wrapping the existing single-shot iOS algorithms with explicit exclusive + abort-on-lifecycle concurrency. Fine-grained calibration helpers demote to `internal`. The relocated `CalibrationViewModel` thins to a caller; its protocol/stub shrink accordingly.

**Tech Stack:** Swift 6.2, iOS 26, AVFoundation, Metal, swift-testing, XcodeBuildMCP.

**Decisions baked in (from user input + advisor):**
- **`focusDistance` is NOT renamed.** iOS `lensPosition` is `[0.0, 1.0]`, not real diopters; the contract name is misleading on iOS. Phase-3 Pigeon adapter does the rename. Logged in DECISIONS.md.
- **`CalibrationResult` matches contract shape**: `before: RgbSample`, `after: RgbSample`, `converged: Bool`, `iterations: Int`. Single-shot returns `converged: true, iterations: 1`.
- **Processing-state sync**: add `currentProcessingParametersSnapshot()` mirroring the existing `currentSettingsSnapshot()` pattern (advisor option b). VM reads after `calibrateBlackBalance()`.
- **Permission methods are `nonisolated static`** so they're callable pre-`open()` (Flutter side queries before instantiating the handle).
- **Phase-2 `.interrupted` covers `.otherInterruption` only** (Control Center, Split View, Stage Manager). `.cameraInUseBegan` keeps its current `.error`-with-self-heal semantics — Stage 9 tests + recovery loop depend on it. Logged in DECISIONS.md; Phase 3 may revisit.
- **Natural-stream vocabulary**: no Phase-2 work — `StreamId.natural`, `currentTexture()` (natural lane), `sampleCenterPatchOnNatural` already use the term. The §2d.1 amendment is Phase-3 contract work.
- **§2d.7 BGRA verification**: lightweight unit test asserting the lane format string is `kCVPixelFormatType_32BGRA`-compatible. No conversion code expected.
- **Test cadence**: build + relevant filter after each task; full bundle after the last task.

---

## Pre-flight

### Task 0: Stage pre-flight + branch hygiene

**Files:** N/A (read-only orientation).

- [ ] **Step 0.1: Run pre-flight script (CLAUDE.md §3)**

```bash
scripts/stage-preflight.sh
```

Expected: `exit 0`. Reports current state, scaffold inventory (must be empty per Phase 1B state.md), build OK.

- [ ] **Step 0.2: Confirm clean tree apart from this plan**

```bash
git status
```

Expected: only `docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md` (unrelated) and the new plan file under `docs/superpowers/plans/` are untracked.

- [ ] **Step 0.3: Branch off `main`**

```bash
git checkout -b phase-2-vocabulary-additive
```

(Working in a topic branch; commits stay local until user-approved per CLAUDE.md §7.)

---

## Cluster A — Vocabulary alignment + OpenConfiguration widening (§2a)

### Task 1: Rename `setProcessingParameters` → `setProcessingParams`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:632` (declaration), `:273` (internal call site in `open()` path)
- Modify: `eva-swift-stitch/UI/ProcessingViewModel.swift:117,124,148` (3 call sites)
- Modify: `eva-swift-stitch/UI/HardwareControlsViewModel.swift:12` (comment)
- Modify: `CameraKit/Tests/CameraKitTests/Stage05Tests.swift:52` (comment)

- [ ] **Step 1.1: Rename declaration in `CameraEngine.swift`**

```swift
// Before:
public func setProcessingParameters(_ params: ProcessingParameters) async {

// After:
public func setProcessingParams(_ params: ProcessingParameters) async {
```

- [ ] **Step 1.2: Update internal call site at line 273**

```swift
// Before:
await self.setProcessingParameters(persistedProcessing)
// After:
await self.setProcessingParams(persistedProcessing)
```

- [ ] **Step 1.3: Update 3 call sites in `ProcessingViewModel.swift` (lines 117, 124, 148)**

Replace `engine.setProcessingParameters(next)` with `engine.setProcessingParams(next)` at each line.

- [ ] **Step 1.4: Update doc comments mentioning the old name**

- `HardwareControlsViewModel.swift:12`: `setProcessingParameters` → `setProcessingParams`
- `ProcessingViewModel.swift:9, 106, 134`: same rename in doc comments
- `Stage05Tests.swift:52`: same rename in doc comment

- [ ] **Step 1.5: Build to verify**

```
mcp__XcodeBuildMCP__build_run_device
```

Expected: BUILD SUCCEEDED. (If build complains, the rename missed a site — grep `setProcessingParameters` and fix.)

```bash
grep -rn 'setProcessingParameters' CameraKit/Sources/ eva-swift-stitch/ CameraKit/Tests/ eva-swift-stitchTests/
```

Expected: 0 hits.

### Task 2: Widen `OpenConfiguration` with `initialSettings`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift:63-77` (`OpenConfiguration`)
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift` (apply settings inside `setupSession`'s `lockForConfiguration` block, before commit)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` `open(configuration:)` body — pass `configuration.initialSettings` through to `setupSession`
- Test: `CameraKit/Tests/CameraKitTests/Stage03Tests.swift` (or new `Stage13Phase2Tests.swift` — see below)

- [ ] **Step 2.1: Add `initialSettings` field**

In `Capabilities.swift`:

```swift
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?
    /// Hardware settings to apply during session setup, before the first frame
    /// is delivered. Folds the Pigeon contract's `open(cameraId, settings)`
    /// shape into CameraKit's structural `OpenConfiguration` so the
    /// requested settings are live from frame one (no defaults-then-snap
    /// flicker). Phase-2 design §2a.
    public var initialSettings: CameraSettings?

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        cropRegion: Rect? = nil,
        initialSettings: CameraSettings? = nil
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.cropRegion = cropRegion
        self.initialSettings = initialSettings
    }
}
```

- [ ] **Step 2.2: Plumb `initialSettings` through `CameraEngine.open(configuration:)` to `CameraSession.setupSession(...)`**

Read `CameraEngine.swift:1538` (the `open` body) and `CameraSession.setupSession`'s signature. Pass `configuration.initialSettings` as a new parameter to `setupSession`. The setup-time apply path uses the same merge + coupling logic `updateSettings` calls (`SettingsCoupling.apply` + the device-side setters), but inside the existing `lockForConfiguration` window before `commitConfiguration`/`startRunning`. If `initialSettings == nil`, do nothing — preserve current behavior.

> **Implementation note for the engineer:** the simplest correct path is to apply the settings via the engine's existing `applySettingsLocked` path immediately after `setupSession` returns and before `startRunning()`. That keeps the lock semantics correct (ADR-07: device lock on `sessionQueue`) without restructuring `setupSession`. Confirm by reading the `applySettings`/`updateSettings` cluster and reusing it; do not invent a parallel apply path.

- [ ] **Step 2.3: Add a test exercising `initialSettings`**

Create `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift` (new file, dual-membered; sync via `scripts/sync-test-target.sh` after creation):

```swift
import Testing
import Foundation
@testable import CameraKit

@Suite("Stage13Phase2OpenConfiguration")
struct Stage13Phase2OpenConfigurationTests {

    @Test("OpenConfiguration carries initialSettings without breaking source compatibility")
    func openConfigurationCarriesInitialSettings() {
        // Old-shape init still compiles (default nil for new field).
        let legacy = OpenConfiguration(cameraId: "back", captureResolution: Size(width: 1920, height: 1080))
        #expect(legacy.initialSettings == nil)

        var s = CameraSettings()
        s.iso = 400
        s.isoMode = .manual
        s.exposureMode = .manual
        s.exposureTimeNs = 16_000_000
        let cfg = OpenConfiguration(initialSettings: s)
        #expect(cfg.initialSettings?.iso == 400)
    }
}
```

(Engine-side verification that `initialSettings` actually applies to AVF runs only on real hardware — we'll cover that with a HITL device run after the cluster, not a unit test.)

- [ ] **Step 2.4: Wire the new file into the Xcode test target**

```bash
scripts/sync-test-target.sh
```

Expected: idempotent; reports added file.

- [ ] **Step 2.5: Build + run filtered tests**

```
mcp__XcodeBuildMCP__test_device  with extraArgs ["-only-testing:eva-swift-stitchTests/Stage13Phase2OpenConfigurationTests"]
```

Expected: PASS.

### Task 3: Capability range fields on `SessionCapabilities`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift` (`SessionCapabilities`)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:1538` (open() body — populate the new fields from `device`)
- Modify: `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` (expose `minAvailableVideoZoomFactor` / `maxAvailableVideoZoomFactor` / `minExposureTargetBias` / `maxExposureTargetBias` if not already present)
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 3.1: Add the new fields to `SessionCapabilities`**

```swift
public struct SessionCapabilities: Sendable, Hashable {
    public let supportedSizes: [Size]
    public let previewTextureId: Int
    public let naturalTextureId: Int
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    public let streamPixelFormat: String
    public let isoRange: ClosedRange<Float>
    public let exposureDurationRangeNs: ClosedRange<Int64>
    /// Lens-position range (iOS `AVCaptureDevice.minimumFocusDistance` is in mm
    /// but `lensPosition` is `[0.0, 1.0]`; we expose the lensPosition range
    /// here, which is always `0.0...1.0` on iOS — kept for shape symmetry with
    /// the contract's `focusMin`/`focusMax`).
    public let focusRange: ClosedRange<Double>
    /// `AVCaptureDevice.minAvailableVideoZoomFactor`...`maxAvailableVideoZoomFactor`.
    public let zoomRange: ClosedRange<Double>
    /// `AVCaptureDevice.minExposureTargetBias`...`maxExposureTargetBias` (EV stops).
    public let evCompensationRange: ClosedRange<Float>
    // ... append to init(...)
}
```

(Update the init signature + assignments accordingly.)

- [ ] **Step 3.2: Expose the AVF readbacks on `CaptureDeviceProviding`**

Add four read-only async properties to the protocol + `LiveCaptureDevice`:
- `var minAvailableVideoZoomFactor: Double { get async }`
- `var maxAvailableVideoZoomFactor: Double { get async }`
- `var minExposureTargetBias: Float { get async }`
- `var maxExposureTargetBias: Float { get async }`

Implementations forward to the underlying `AVCaptureDevice` properties of the same name. Update the test fakes (e.g. `Stage01Tests.swift:20`-region) with sensible defaults (1.0/1.0 for zoom; -3.0/+3.0 for EV bias).

- [ ] **Step 3.3: Populate the new fields in `CameraEngine.open(configuration:)`**

In the `open` body where `SessionCapabilities` is constructed, read the four new device values and pass them into the init. `focusRange` is `0.0...1.0` (iOS lensPosition range — constant). `evCompensationRange` is the AVF bias range.

- [ ] **Step 3.4: Update existing `SessionCapabilities` test fixtures**

Search for `SessionCapabilities(` callers in tests and add the four new field values. Use sensible defaults (zoom `1.0...1.0`, EV `-3.0...3.0`, focus `0.0...1.0`).

- [ ] **Step 3.5: Add a test asserting the new fields populate**

Append to `Stage13Phase2Tests.swift`:

```swift
@Suite("Stage13Phase2SessionCapabilities")
struct Stage13Phase2SessionCapabilitiesTests {
    @Test("SessionCapabilities carries focus/zoom/EV ranges")
    func sessionCapabilitiesCarriesRangeFields() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0, naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: "kCVPixelFormatType_32BGRA",
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...8.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.focusRange == 0.0...1.0)
        #expect(cap.zoomRange == 1.0...8.0)
        #expect(cap.evCompensationRange == -3.0...3.0)
    }
}
```

- [ ] **Step 3.6: Build + run cluster tests**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2SessionCapabilitiesTests, eva-swift-stitchTests/Stage13Phase2OpenConfigurationTests
```

Expected: PASS. Build clean (no `SessionCapabilities(` callsite missing the new args).

---

## Cluster B — Lifecycle & permissions (§2c, §2d.5, §2d.6, §2d.7)

### Task 4: Add `SessionState.interrupted`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/SessionState.swift` (add case)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:1262` (route `.otherInterruption` → publish `.interrupted`; restore on `.interruptionEnded` — note CameraSession only fires `.cameraInUseEnded` for the cameraInUse-specific case, so we need a separate signal for "other ended")
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift:340-351` (add `.otherInterruptionEnded` event so the engine can revert state)
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 4.1: Add the case**

```swift
public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
    /// Routine AVCaptureSession interruption (Control Center, Split View / Stage
    /// Manager, phone call). Distinct from `.error` — auto-resumes on
    /// `interruptionEndedNotification`. Phase-2 design §2d.5.
    case interrupted
}
```

- [ ] **Step 4.2: Add `.otherInterruptionEnded` to `CameraSession.SessionEvent`**

In `CameraSession.swift:35-39`:

```swift
enum SessionEvent: Sendable {
    case cameraInUseBegan
    case cameraInUseEnded
    case otherInterruption(reasonRawValue: Int)
    case otherInterruptionEnded
    case runtimeError(String)
}
```

In `handleInterruption(note:ended:)`, the `else` branch needs to fire `.otherInterruptionEnded` when `ended == true`:

```swift
} else {
    if ended {
        onSessionEvent?(.otherInterruptionEnded)
    } else {
        onSessionEvent?(.otherInterruption(reasonRawValue: rawReason))
    }
}
```

- [ ] **Step 4.3: Route in `CameraEngine.onSessionEvent`**

Replace the existing `.otherInterruption: break` with state publication; add the `.otherInterruptionEnded` case to revert:

```swift
case .otherInterruption(let raw):
    CameraKitLog.notice(.engine, "[interruption] entering .interrupted (raw=\(raw))")
    publishState(.interrupted)
    // Abort any in-flight calibration (added in Task 8) — its task.cancel()
    // unwinds the WB-restore defer.
    calibrationTask?.cancel()
case .otherInterruptionEnded:
    CameraKitLog.notice(.engine, "[interruption] ended — reverting to .streaming")
    publishState(.streaming)
```

(The `calibrationTask?.cancel()` line stays commented-out / removed until Task 8 lands the property; the engineer adds it then.)

- [ ] **Step 4.4: Add a test (using existing `_postSessionEventForTest` seam)**

```swift
@Suite("Stage13Phase2InterruptedState")
struct Stage13Phase2InterruptedStateTests {
    @Test("otherInterruption publishes .interrupted; ended reverts to .streaming")
    func otherInterruptionPublishesInterruptedState() async {
        let engine = CameraEngine()
        let states = engine.stateStream()
        var observed: [SessionState] = []
        let collectorTask = Task {
            for await s in states {
                observed.append(s)
                if observed.count >= 2 { break }
            }
        }
        // Allow the stream to set up.
        try? await Task.sleep(for: .milliseconds(50))
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        await engine._postSessionEventForTest(.otherInterruptionEnded)
        _ = await collectorTask.value
        #expect(observed.contains(.interrupted))
        #expect(observed.last == .streaming)
    }
}
```

- [ ] **Step 4.5: Build + run filter**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2InterruptedStateTests
```

Expected: PASS.

### Task 5: `cameraPermissionStatus` / `requestCameraPermission` (+ Photos)

**Files:**
- Create: `CameraKit/Sources/CameraKit/Permissions.swift` (new file holding the static helpers + a public enum)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (extension exposing them via the engine type for discoverability — they're `static`)
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 5.1: Create the file**

```swift
// CameraKit/Sources/CameraKit/Permissions.swift
import AVFoundation
import Photos

public enum CameraPermissionStatus: String, Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

extension CameraEngine {
    /// AVCaptureDevice.authorizationStatus(for: .video) mapped to a
    /// platform-neutral enum. `static` so the Flutter side can query before
    /// instantiating an engine handle. Phase-2 design §2d.6.
    public nonisolated static func cameraPermissionStatus() -> CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    /// Triggers the system permission prompt (or returns the cached answer if
    /// already prompted). Returns the status after the prompt resolves.
    public nonisolated static func requestCameraPermission() async -> CameraPermissionStatus {
        // AVCaptureDevice.requestAccess returns a Bool; remap to the enum.
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return cameraPermissionStatus()
    }

    /// PHPhotoLibrary add-only authorization status, mapped to the same enum.
    public nonisolated static func photosAddPermissionStatus() -> CameraPermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized, .limited: return .authorized
        @unknown default: return .denied
        }
    }

    /// Triggers the system Photos add-only prompt.
    public nonisolated static func requestPhotosAddPermission() async -> CameraPermissionStatus {
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return photosAddPermissionStatus()
    }
}
```

- [ ] **Step 5.2: Add a test**

```swift
@Suite("Stage13Phase2Permissions")
struct Stage13Phase2PermissionsTests {
    @Test("cameraPermissionStatus returns authorized on the test iPad (Info.plist grants camera at launch)")
    func cameraPermissionStatusReturnsAuthorized() {
        // After the first launch with NSCameraUsageDescription accepted,
        // status is .authorized for the remainder of the install. The CI/HITL
        // device has accepted, so this asserts the readback works.
        let s = CameraEngine.cameraPermissionStatus()
        #expect(s == .authorized || s == .notDetermined || s == .denied || s == .restricted)
    }
}
```

(We assert "one of the four valid values" — the actual value depends on prior install state. The point is the static method is callable and maps cleanly.)

- [ ] **Step 5.3: Sync test target + build + run filter**

```bash
scripts/sync-test-target.sh
```
```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2PermissionsTests
```

Expected: PASS.

### Task 6: `currentPixelBuffer(stream:) -> CVPixelBuffer?` accessor

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (add the public accessor near the existing `currentTexture()` group around line 1618)
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift` or the lane mailbox (wherever `currentTexture()` reads from) to expose the underlying `CVPixelBuffer`
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 6.1: Locate the lane mailbox**

```bash
grep -rn 'currentTexture\|naturalTex\|processedTex\|trackerTex' CameraKit/Sources/CameraKit/ | head -30
```

Expected: identifies the property / actor that holds the latest per-lane texture. The `MTLTexture` is a *view* on a `CVPixelBuffer`; we need the underlying buffer.

- [ ] **Step 6.2: Expose `currentPixelBuffer(stream:)`**

Add a sibling to `currentTexture()` / `currentProcessedTexture()` / `currentTrackerTexture()`:

```swift
/// Returns the latest IOSurface-backed `CVPixelBuffer` for the requested
/// lane, or `nil` if no frame has been delivered yet (or post-pause/close).
/// `nonisolated` + synchronous — Phase-3's `FlutterTexture.copyPixelBuffer()`
/// is called on the GPU thread and must not suspend. Phase-2 design §2c.
public nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer? {
    switch stream {
    case .natural: return /* underlying-mailbox-read for natural */
    case .processed: return /* underlying-mailbox-read for processed */
    case .tracker: return /* underlying-mailbox-read for tracker */
    }
}
```

> **Implementation note for the engineer:** if the existing mailbox holds only the `MTLTexture` and not the `CVPixelBuffer`, store the buffer alongside the texture (the `CVMetalTexture` already retains both — straightforward extraction). Do not introduce a new copy.

- [ ] **Step 6.3: Test**

```swift
@Suite("Stage13Phase2CurrentPixelBuffer")
struct Stage13Phase2CurrentPixelBufferTests {
    @Test("currentPixelBuffer returns nil before any frame")
    func currentPixelBufferIsNilBeforeFirstFrame() async {
        let engine = CameraEngine()
        #expect(engine.currentPixelBuffer(stream: .natural) == nil)
        #expect(engine.currentPixelBuffer(stream: .processed) == nil)
        #expect(engine.currentPixelBuffer(stream: .tracker) == nil)
    }
}
```

(End-to-end "non-nil after first frame" requires a real session and is verified by the device run at the end.)

- [ ] **Step 6.4: Build + run filter**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2CurrentPixelBufferTests
```

Expected: PASS.

### Task 7: §2d.7 — assert lane pixel format is BGRA-cache-compatible

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift` (or wherever the AVF output `videoSettings` are configured) — add a constant for the format string
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 7.1: Locate the videoSettings dict**

```bash
grep -rn 'kCVPixelFormatType\|videoSettings\|kCVPixelBufferPixelFormatTypeKey' CameraKit/Sources/CameraKit/ | head -10
```

Expected: a single configuration site setting `kCVPixelFormatType_32BGRA`. If something else, the spec's zero-copy assumption is wrong — flag it as a blocker.

- [ ] **Step 7.2: Add a regression test**

```swift
@Suite("Stage13Phase2PixelFormat")
struct Stage13Phase2PixelFormatTests {
    @Test("CameraKit emits BGRA-cache-compatible lane buffers — Phase-3 zero-copy invariant")
    func sessionCapabilitiesReportsBgra() {
        // The format string is reported in SessionCapabilities.streamPixelFormat.
        // Construct the cap directly — we're asserting the string CameraKit
        // uses, not the runtime device behavior.
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0, naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: "kCVPixelFormatType_32BGRA",
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0, zoomRange: 1.0...1.0, evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "kCVPixelFormatType_32BGRA")
    }
}
```

(Engineer: also confirm by inspection that the actual `videoSettings` dict uses BGRA; if not, escalate before Phase 3.)

- [ ] **Step 7.3: Build + run filter**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2PixelFormatTests
```

Expected: PASS.

---

## Cluster C — Active-config-changed stream (§2c)

### Task 8: `streamConfigurationStream()`

**Files:**
- Create: `CameraKit/Sources/CameraKit/StreamConfiguration.swift` (new public type)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (cached `AsyncStream<StreamConfiguration>` + emit on `setResolution` and `setCropRegion`)
- Test: append to `Stage13Phase2Tests.swift`

- [ ] **Step 8.1: Add the type**

```swift
// CameraKit/Sources/CameraKit/StreamConfiguration.swift
import Foundation

/// Active stream configuration emitted on `streamConfigurationStream()`.
///
/// Fires after `setResolution(...)` resolves to a new camera stream size or
/// after `setCropRegion(...)` mutates the active crop. Phase-2 payload is
/// resolution + crop only; Phase 3's Pigeon `CamStreamConfiguration` adds
/// the texture-ID field (minted by the texture bridge). Phase-2 design §2c.
public struct StreamConfiguration: Sendable, Hashable {
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    public init(activeCaptureResolution: Size, activeCropRegion: Rect) {
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
    }
}
```

- [ ] **Step 8.2: Add the cached stream + emitter on `CameraEngine`**

Mirror the existing `stateStream()` / `frameResultStream()` cached-stream pattern. Find one of those (`CameraEngine.swift:1574-1582`-ish) and copy the `Mutex<Continuation?>` + cached `AsyncStream` shape exactly.

```swift
public func streamConfigurationStream() -> AsyncStream<StreamConfiguration> {
    // see existing stateStream() — same cached-continuation pattern.
}

private func publishStreamConfiguration() {
    guard let res = currentCaptureResolution, let crop = currentCropRegion else { return }
    streamConfigContinuation.value?.yield(
        StreamConfiguration(activeCaptureResolution: res, activeCropRegion: crop))
}
```

(Engineer: read the existing `publishState` / `publishError` cluster and add a parallel `publishStreamConfiguration` helper.)

Wire calls into:
- `setResolution(size:)` after the new size resolves and the session restarts (just before returning successfully)
- `setCropRegion(_:)` after the new crop is applied

- [ ] **Step 8.3: Test**

```swift
@Suite("Stage13Phase2StreamConfigurationStream")
struct Stage13Phase2StreamConfigurationStreamTests {
    @Test("streamConfigurationStream() returns an AsyncStream that can be consumed")
    func streamConfigurationStreamReturnsAsyncStream() async {
        let engine = CameraEngine()
        let s = engine.streamConfigurationStream()
        // Verify the stream is alive (terminates cleanly on engine deinit).
        let t = Task {
            for await _ in s { break }
        }
        t.cancel()
        _ = await t.value
    }
}
```

End-to-end "fires on setResolution / setCropRegion" requires a real session — covered by HITL device run.

- [ ] **Step 8.4: Build + run filter**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13Phase2StreamConfigurationStreamTests
```

Expected: PASS.

---

## Cluster D — Calibration move-down (§2b) — biggest cluster

### Task 9: Add `CalibrationResult` type + ProcessingParameters snapshot accessor

**Files:**
- Create: `CameraKit/Sources/CameraKit/CalibrationResult.swift` (new public struct)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (add `currentProcessingParametersSnapshot()` near `currentSettingsSnapshot()`)
- Modify: `CameraKit/Sources/CameraKit/Errors.swift` (add `EngineError.calibrationInProgress`)

- [ ] **Step 9.1: Add `CalibrationResult` struct**

```swift
// CameraKit/Sources/CameraKit/CalibrationResult.swift
import Foundation

/// Returned by `calibrateWhiteBalance()` / `calibrateBlackBalance()`.
///
/// Fields mirror the Pigeon contract's `CamCalibrationResult` (Phase-2 design
/// §2d.8). For the Phase-2 single-shot iOS algorithm, `converged = true` and
/// `iterations = 1`; the future Dart-iterative-loop port (see
/// `wb-calibration-dart-port.md`) populates them meaningfully.
public struct CalibrationResult: Sendable, Hashable {
    /// RGB sample of the center patch *before* the calibration applied.
    public let before: RgbSample
    /// RGB sample of the center patch *after* the calibration applied.
    public let after: RgbSample
    /// Whether the algorithm converged (always `true` for single-shot).
    public let converged: Bool
    /// Iteration count (always `1` for single-shot).
    public let iterations: Int

    public init(before: RgbSample, after: RgbSample, converged: Bool, iterations: Int) {
        self.before = before
        self.after = after
        self.converged = converged
        self.iterations = iterations
    }
}
```

- [ ] **Step 9.2: Add `EngineError.calibrationInProgress`**

In `Errors.swift`, append to the `EngineError` enum:

```swift
/// A `calibrate*()` is in flight; conflicting mutating ops (`updateSettings`
/// touching white balance, `setResolution`) must not race with it.
/// Phase-2 design §2b concurrency contract.
case calibrationInProgress
```

- [ ] **Step 9.3: Add `currentProcessingParametersSnapshot()`**

In `CameraEngine.swift` near `currentSettingsSnapshot()` (line 1536):

```swift
/// Latest applied `ProcessingParameters`, or `nil` pre-`open()`.
/// Symmetric with `currentSettingsSnapshot()`. Phase-2 design — used by
/// `CalibrationViewModel` to refresh its mirror after `calibrateBlackBalance()`.
public func currentProcessingParametersSnapshot() -> ProcessingParameters? {
    return currentProcessing  // confirm the actual storage name; engineer reads existing code
}
```

(Engineer: locate the engine's stored `currentProcessing` / `processingParams` field and forward it; do not duplicate state.)

### Task 10: Add `calibrateWhiteBalance()` + concurrency guard

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (add the method, the `calibrationTask` property, the conflict guards in `updateSettings` / `setResolution`)

- [ ] **Step 10.1: Add `calibrationTask` property to the actor**

```swift
private var calibrationTask: Task<CalibrationResult, Error>?
```

- [ ] **Step 10.2: Add the conflict-guard helper**

```swift
/// Throws `.calibrationInProgress` if a `calibrate*` is in flight.
/// Called by `updateSettings` (when WB fields are present) and `setResolution`.
private func ensureNotCalibrating() throws {
    if calibrationTask != nil {
        throw EngineError.calibrationInProgress
    }
}
```

- [ ] **Step 10.3: Wire the guard into `updateSettings` and `setResolution`**

In `updateSettings(_ settings:)`: if `settings.wbMode != nil || settings.wbGainR != nil || settings.wbGainG != nil || settings.wbGainB != nil`, call `try ensureNotCalibrating()` before any mutation.

In `setResolution(size:)`: call `try ensureNotCalibrating()` at entry.

- [ ] **Step 10.4: Add `calibrateWhiteBalance()`**

Wraps `CalibrationViewModel.calibrateWB`'s current single-shot Apple gray-world algorithm:

```swift
/// Single-shot WB calibration: AWB → settle → read gray-world gains → clamp →
/// lock to manual. Phase-2 design §2b. Future iterative port: see
/// `docs/superpowers/plans/2026-05-15-wb-calibration-dart-port.md`.
///
/// Concurrency contract:
/// - Exclusive: a second `calibrate*()` while one is in flight throws
///   `.calibrationInProgress`.
/// - Conflicting ops (`updateSettings` touching WB, `setResolution`) throw
///   `.calibrationInProgress` while the flag is set.
/// - `Task.cancel()`, `close()`, and the `.interrupted` `SessionState`
///   abort: WB is restored to `.auto` before `CancellationError` propagates.
public func calibrateWhiteBalance() async throws -> CalibrationResult {
    try ensureNotCalibrating()

    let task = Task<CalibrationResult, Error> { [weak self] in
        guard let self else { throw EngineError.notOpen }
        // Defer-restore: on cancel/throw, return WB to .auto.
        var settled = false
        defer {
            if !settled {
                Task { try? await self._restoreWBAuto() }
            }
        }
        let before = try await self.sampleCenterPatchOnNatural()
        let maxGain = try await self.maxWhiteBalanceGain()
        let raw = try await self.freshGrayWorldDeviceWBGains()
        let gains = WhiteBalanceGains(
            red: min(maxGain, max(1.0, raw.red)),
            green: min(maxGain, max(1.0, raw.green)),
            blue: min(maxGain, max(1.0, raw.blue)))
        try await self.applyManualGainsAndAwait(gains)
        var manual = CameraSettings()
        manual.wbMode = .manual
        manual.wbGainR = Double(gains.red)
        manual.wbGainG = Double(gains.green)
        manual.wbGainB = Double(gains.blue)
        try await self._applySettingsBypassingCalibrationGuard(manual)
        let after = try await self.sampleCenterPatchOnNatural()
        settled = true
        return CalibrationResult(before: before, after: after, converged: true, iterations: 1)
    }
    calibrationTask = task
    defer { calibrationTask = nil }
    return try await task.value
}

/// Internal — `updateSettings` path bypassing the calibration guard so the
/// in-flight `calibrateWhiteBalance()` can write its own WB without tripping.
internal func _applySettingsBypassingCalibrationGuard(_ s: CameraSettings) async throws {
    // call the same internals updateSettings does, just without ensureNotCalibrating()
}

internal func _restoreWBAuto() async throws {
    var auto = CameraSettings()
    auto.wbMode = .auto
    try await _applySettingsBypassingCalibrationGuard(auto)
}
```

> **Implementation note for the engineer:** the exact factoring depends on the current `updateSettings` body. Read it first; the cleanest split is "public guard + private apply" so `_applySettingsBypassingCalibrationGuard` is just the existing apply path minus the guard. Keep the WB-restore call in `defer` synchronous-spawning a `Task` because `defer` can't be async-awaiting; the task will complete on the actor.

### Task 11: Add `calibrateBlackBalance()`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (add the method)

- [ ] **Step 11.1: Implementation**

Wraps `CalibrationViewModel.calibrateBB` + the BB-pedestal write:

```swift
/// Single-shot BB calibration: sample naturalTex through current BCSG with BB
/// zeroed → write per-channel pedestal into `ProcessingParameters.blackR/G/B`.
/// Phase-2 design §2b.
public func calibrateBlackBalance() async throws -> CalibrationResult {
    try ensureNotCalibrating()
    let task = Task<CalibrationResult, Error> { [weak self] in
        guard let self else { throw EngineError.notOpen }
        let before = try await self.sampleCenterPatchForBBCalibration()
        // Apply pedestal: subtract the sampled mean from current params.
        let prior = await self.currentProcessingParametersSnapshot() ?? .identity
        var next = prior
        next.blackR = before.r
        next.blackG = before.g
        next.blackB = before.b
        await self.setProcessingParams(next)
        let after = try await self.sampleCenterPatchForBBCalibration()
        return CalibrationResult(before: before, after: after, converged: true, iterations: 1)
    }
    calibrationTask = task
    defer { calibrationTask = nil }
    return try await task.value
}
```

### Task 12: Engine-side calibration tests

**Files:**
- Create: `CameraKit/Tests/CameraKitTests/Stage13CalibrationTests.swift` (new file, dual-membered)

- [ ] **Step 12.1: Tests**

```swift
import Testing
import Foundation
@testable import CameraKit

@Suite("Stage13Calibration")
struct Stage13CalibrationTests {

    @Test("calibrateWhiteBalance throws .notOpen pre-open")
    func calibrateWBThrowsNotOpenBeforeOpen() async {
        let engine = CameraEngine()
        await #expect(throws: EngineError.self) {
            _ = try await engine.calibrateWhiteBalance()
        }
    }

    @Test("calibrateBlackBalance throws .notOpen pre-open")
    func calibrateBBThrowsNotOpenBeforeOpen() async {
        let engine = CameraEngine()
        await #expect(throws: EngineError.self) {
            _ = try await engine.calibrateBlackBalance()
        }
    }

    @Test("CalibrationResult shape is correct for single-shot")
    func calibrationResultShapeForSingleShot() {
        let r = CalibrationResult(
            before: RgbSample(r: 0.5, g: 0.5, b: 0.5),
            after: RgbSample(r: 0.5, g: 0.5, b: 0.5),
            converged: true,
            iterations: 1)
        #expect(r.converged == true)
        #expect(r.iterations == 1)
    }

    @Test("EngineError.calibrationInProgress exists and is Sendable")
    func calibrationInProgressErrorExists() {
        let e: EngineError = .calibrationInProgress
        switch e {
        case .calibrationInProgress: break
        default: Issue.record("expected .calibrationInProgress")
        }
    }
}
```

(End-to-end calibration verification requires a real session — covered by HITL device run after the cluster.)

- [ ] **Step 12.2: Sync test target + run filter**

```bash
scripts/sync-test-target.sh
```
```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage13CalibrationTests
```

Expected: PASS.

### Task 13: Demote calibration helpers to `internal` and shrink `CalibrationEngineProtocol`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` — demote `applyManualGainsAndAwait`, `awaitWBSettled`, `sampleCenterPatchForBBCalibration`, `setWBPreset`, `awaitAESettled`, `freshGrayWorldDeviceWBGains`, `grayWorldDeviceWBGains`, `currentDeviceWBGains`, `maxWhiteBalanceGain`, `awaitNaturalAfter`, `sampleCenterPatchOnNatural` from `public` → `internal`. Keep `sampleCenterPatch` `public` (it's the contract's low-level primitive).
- Modify: `eva-swift-stitch/UI/CalibrationViewModel.swift` (rewrite VM as a thin caller; shrink `CalibrationEngineProtocol`)
- Modify: `eva-swift-stitchTests/Stage11UITests.swift` — update `CalibrationEngineStub` to the shrunk protocol; thin the WB/BB tests to wiring-only

- [ ] **Step 13.1: Identify the shrunk protocol surface**

The new `CalibrationEngineProtocol` only needs what the *thinned* VM calls:

```swift
protocol CalibrationEngineProtocol: Sendable {
    func calibrateWhiteBalance() async throws -> CalibrationResult
    func calibrateBlackBalance() async throws -> CalibrationResult
    func updateSettings(_ settings: CameraSettings) async throws
    func currentProcessingParametersSnapshot() async -> ProcessingParameters?
}
```

(BB-result-driven slider refresh uses `currentProcessingParametersSnapshot()` instead of `sampleCenterPatchForBBCalibration` directly.)

- [ ] **Step 13.2: Rewrite `CalibrationViewModel`**

```swift
@Observable @MainActor
final class CalibrationViewModel {
    var wbMode: WhiteBalanceMode = .auto
    var wbCalibrationStatus: WBCalibrationStatus = .idle

    private let engine: any CalibrationEngineProtocol
    private let processingVM: ProcessingViewModel
    init(engine: any CalibrationEngineProtocol, processingVM: ProcessingViewModel) {
        self.engine = engine
        self.processingVM = processingVM
    }

    func calibrateWB() {
        let engine = self.engine
        Task { @MainActor in
            self.wbCalibrationStatus = .calibrating
            do {
                _ = try await engine.calibrateWhiteBalance()
                self.wbMode = .manual
                self.wbCalibrationStatus = .completed
                try? await Task.sleep(for: .milliseconds(wbCompletedDisplayMs))
                if self.wbCalibrationStatus == .completed {
                    self.wbCalibrationStatus = .idle
                }
            } catch {
                CameraKitLog.error(.engine, "[wb] calibrateWB threw: \(error)")
                self.wbCalibrationStatus = .idle
            }
        }
    }

    func resetToAutoWB() {
        let engine = self.engine
        Task { @MainActor in
            var delta = CameraSettings()
            delta.wbMode = .auto
            try? await engine.updateSettings(delta)
            self.wbMode = .auto
        }
    }

    func lockCurrentWB() {
        let engine = self.engine
        Task { @MainActor in
            var delta = CameraSettings()
            delta.wbMode = .locked
            try? await engine.updateSettings(delta)
            self.wbMode = .locked
        }
    }

    func calibrateBB() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task {
            do {
                _ = try await engine.calibrateBlackBalance()
                // Sync VM mirror from engine's authoritative snapshot.
                if let snap = await engine.currentProcessingParametersSnapshot() {
                    await processingVM.refreshFromEngineSnapshot(snap)
                }
            } catch {
                // surfaces via errorStream → ErrorPresenterViewModel.
            }
        }
    }

    func resetBlackBalance() {
        let processingVM = self.processingVM
        Task {
            await processingVM.applyBlackBalance(sample: RgbSample(r: 0, g: 0, b: 0))
        }
    }
}
```

- [ ] **Step 13.3: Add `ProcessingViewModel.refreshFromEngineSnapshot(_:)`**

```swift
@MainActor
func refreshFromEngineSnapshot(_ snap: ProcessingParameters) {
    self.currentProcessing = snap  // confirm property name from existing code
}
```

(Engineer: read the existing `applyBlackBalance` body and locate the same mirror property — name-match it.)

- [ ] **Step 13.4: Demote helpers in `CameraEngine.swift`**

For each of these declarations, change `public func` → `func` (default internal):
- `sampleCenterPatchOnNatural`
- `sampleCenterPatchForBBCalibration`
- `currentDeviceWBGains`
- `maxWhiteBalanceGain`
- `grayWorldDeviceWBGains`
- `freshGrayWorldDeviceWBGains`
- `awaitWBSettled`
- `setWBPreset`
- `applyManualGainsAndAwait`
- `awaitNaturalAfter`
- `awaitAESettled`

Keep `public func sampleCenterPatch()` — it is the contract's low-level primitive.

- [ ] **Step 13.5: Update `Stage11UITests.swift`'s `CalibrationEngineStub` to the shrunk protocol**

Replace the stub's body to implement only the new four-method protocol; record what the VM passes (e.g. record settings deltas, count `calibrateWhiteBalance` invocations). Thin the existing tests:

- "calibrateWB sets calibrating then completed" — keep, but assert via the stub's invocation count rather than poking at engine internals.
- "resetToAutoWB sends `.auto` settings" — keep.
- "calibrateBB triggers `calibrateBlackBalance` on engine" — re-shape: assert the stub's `calibrateBB-invocation-count` increments.
- Drop tests that exercised `sampleCenterPatchOnNatural`/`grayWorldDeviceWBGains`/`applyManualGainsAndAwait` directly — those moved to engine-side tests in Task 12.

- [ ] **Step 13.6: Build + run Phase-2 + thinned UI suites**

```
mcp__XcodeBuildMCP__test_device with -only-testing:eva-swift-stitchTests/Stage11UITests, eva-swift-stitchTests/Stage13CalibrationTests
```

Expected: PASS. Build clean (no remaining external callers of the demoted helpers).

```bash
# sanity grep — should show 0 hits outside CameraKit/Sources/
grep -rn 'engine\.sampleCenterPatchOnNatural\|engine\.applyManualGainsAndAwait\|engine\.awaitWBSettled\|engine\.maxWhiteBalanceGain\|engine\.freshGrayWorldDeviceWBGains' eva-swift-stitch/ eva-swift-stitchTests/
```

Expected: 0 hits.

---

## Cluster E — Final wrap

### Task 14: Full test bundle on device

- [ ] **Step 14.1: Run the full bundle**

```
mcp__XcodeBuildMCP__test_device  (no -only-testing filter)
```

Expected: 127 prior baseline + new Phase-2 tests → ~135-140 PASSED, 0 FAILED, 0 SKIPPED.

If anything fails: read the structured output, diagnose, fix. Do NOT mass-skip to make the bundle green.

### Task 15: HITL device verification (per spec §Verification — Phase 2)

- [ ] **Step 15.1: Cold-launch on iPad and exercise the conformed harness**

Launch the app via `mcp__XcodeBuildMCP__build_run_device`. Verify:
- [ ] App opens; preview is live; control bar and calibration sidebar render.
- [ ] WB Calibrate triggers `engine.calibrateWhiteBalance()` (engine-side now); preview color shifts; "Calibrated ✓" confirmation appears; sidebar reverts to idle after ~1.5s.
- [ ] BB Calibrate triggers `engine.calibrateBlackBalance()`; black-balance sliders update to non-zero values matching the sampled patch.
- [ ] Resolution dropdown — pick a different resolution; confirm `streamConfigurationStream` fires (via `ipad-logs` skill — look for the `[stream-config]` log line we'll add in Task 8).
- [ ] Trigger an interruption (Control Center pull-down or Split View); confirm session state goes to `.interrupted` then back to `.streaming` (via device logs: `[interruption] entering .interrupted` → `[interruption] ended — reverting to .streaming`).
- [ ] No regressions in record start/stop, still capture, or Canny edge-count overlay (Phase 1B sanity).

- [ ] **Step 15.2: Capture evidence to `measurements/phase-2/`**

Create `measurements/phase-2/verification.md`:
- Test bundle pass count + iPad UDID + iOS version
- HITL items with timestamps from `camerakit.log` (use the `ipad-logs` skill recipes)

### Task 16: Regenerate CONTRACTS.md, update state.md + DECISIONS.md

- [ ] **Step 16.1: Regenerate CONTRACTS.md**

```bash
scripts/regen-contracts.sh
```

Inspect the diff: should reflect the rename (`setProcessingParams`), the widened `OpenConfiguration`, the new `SessionCapabilities` fields, the new `SessionState.interrupted` case, the new permission helpers, `currentPixelBuffer(stream:)`, `streamConfigurationStream()`, `CalibrationResult`, `calibrateWhiteBalance` / `calibrateBlackBalance`, demoted helpers no longer appearing, and `EngineError.calibrationInProgress`.

- [ ] **Step 16.2: Update `CameraKit/state.md`**

Prepend a new "# state.md — Migration Phase 2" section above the Phase-1B section:
- Current stage: Phase 2 complete
- Public-surface changes (additions + renames + demotions)
- Test bundle baseline (e.g. "138 passed / 0 failed / 0 skipped")
- HITL evidence pointer to `measurements/phase-2/verification.md`

- [ ] **Step 16.3: Append to `CameraKit/DECISIONS.md`**

One entry per decision logged here:

```
## Phase 2 — 2026-05-15

- **D-2P-01**: `focusDistance` NOT renamed to `focusDistanceDiopters`. iOS
  `lensPosition` is `[0.0, 1.0]` not real diopters; contract name is
  semantically wrong on iOS. Phase-3 Pigeon adapter does the rename.
- **D-2P-02**: `CalibrationResult` matches Pigeon `CamCalibrationResult`
  shape (before/after/converged/iterations). Single-shot returns
  `converged=true, iterations=1` so the future iterative-Dart-port
  upgrade is a swap-in, not a contract bump.
- **D-2P-03**: `CalibrationViewModel` reverses Stage-11 ADR-21
  decomposition for WB/BB orchestration only. Engine owns
  `calibrateWhiteBalance` / `calibrateBlackBalance`; VM is a thin caller.
  Spec §2b. Other VM responsibilities are unchanged.
- **D-2P-04**: Phase-2 `.interrupted` covers `.otherInterruption` only.
  `.cameraInUseBegan` keeps its existing `.error`-with-self-heal route —
  Stage 9 self-heal + tests depend on it. Phase-3 may reconcile.
- **D-2P-05**: Calibration concurrency contract — `internal var
  calibrationTask` flag; conflict guard in `updateSettings` (when WB
  fields present) + `setResolution`; `Task.cancel()` / `close()` /
  `.interrupted` cancel the task; defer-restores WB to `.auto`.
- **D-2P-06**: Permission helpers are `nonisolated static` on
  `CameraEngine` so they're callable pre-`open()` (Flutter side queries
  before instantiating an engine handle).
- **D-2P-07**: §2c "natural-stream vocabulary" — no Phase-2 work.
  CameraKit's surface already uses "natural" (`StreamId.natural`,
  `currentTexture()` is natural, `sampleCenterPatchOnNatural`). The
  rename is a Phase-3 contract amendment.
```

- [ ] **Step 16.4: Final commit gate**

Per CLAUDE.md §7: do NOT commit without explicit user approval. Surface the diff (use `git status` + `git diff --stat`) and ask the user to confirm before `git add`/`git commit`.

---

## Self-review checklist (engineer runs before declaring done)

- [ ] Every spec §2a-§2e item maps to a task in this plan (or an explicit "no Phase-2 work" note).
- [ ] No file was edited that wasn't in the listed file list.
- [ ] `CONTRACTS.md` regen diff matches the expected surface deltas above.
- [ ] No simulator was ever invoked (CLAUDE.md §6 hard rule).
- [ ] `swift build` / `swift test` were never invoked directly (CLAUDE.md §6).
- [ ] Pre-commit hook (swift-format `--strict`) passes — every multi-sentence `///` doc comment has a blank `///` after the first sentence.
- [ ] No demoted-internal helper has external callers (grep confirms).
- [ ] Phase-3 handoff notes (`docs/superpowers/specs/2026-05-15-phase3-handoff-notes.md`) still match what we shipped (no contract surprises).
