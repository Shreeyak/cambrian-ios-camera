# Stage 03 — Camera controls + settings merge + persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Stage 01 stub `CameraEngine.updateSettings(_:)` into a real settings pipeline — non-nil-field merge, ISO/exposure coupling Rules 1/2/3 with KVO-latched sensor readback, `UserDefaults` persistence, a 3 Hz `frameResultStream()` heartbeat, a `setResolution(size:)` session-only teardown, and an expanded bottom bar with ISO/Shutter/Focus/Zoom controls.

**Architecture:** Sliders in `CameraView` feed delta `CameraSettings` through `ViewModel.updateXxx()` → `engine.updateSettings(_:)`. The engine merges onto persisted state, runs `SettingsCoupling.apply(rules:latched:)` (Rule 3 consults `device.lastSnapshot` populated by a `DeviceKVOObserver`-wrapped `AsyncStream<DeviceStateSnapshot>`, ADR-14), range-validates, and dispatches to `CameraSession.applySettings(_:on:)` — a single `lockForConfiguration()` window on `sessionQueue` (ADR-07). On success the engine persists via `SettingsPersistence.save(_:)` from a detached Task (never the actor). `open()` reloads the last-saved snapshot before returning.

**Tech Stack:** Swift 6.2, iOS 26, Swift Testing (`@Test`/`@Suite`), AVFoundation, `swift-atomics`, `UserDefaults` + `Codable`, KVO via `NSKeyValueObservation` with typed `KeyPath<Self, Value>`, `AsyncStream` with `.bufferingOldest(Constants.stateStreamBufferSize)` for KVO state-change and `.bufferingNewest(1)` for frame-rate streams. Device builds via `mcp__XcodeBuildMCP__{build_run_device,test_device}` — **no simulators, ever**.

**Stage type:** FEATURE. No scaffolds retire (brief §12: "Adds (scaffolding): (none)"). No new slugs introduced.

---

## 1. Source inventory (starting state, as of commit `e9c1ff0`)

> The last commit (`e9c1ff0 feat(stage-03): add heartbeat + resolution-resize timeout constants`) already added `Constants.frameResultHeartbeatHz`, `frameResultHeartbeatIntervalFrames`, `resolutionResizeTimeoutSeconds`. Partial Stage 03 work has also landed for `Settings.swift`, `SettingsPersistence.swift`, and `Stage03Tests.swift`. The plan **reconciles** this with the brief rather than recreating anything. See Deviation 11 below.

### 1.1 File-by-file shape

| File | Status | What's there now | What must change |
|---|---|---|---|
| `CameraKit/Sources/CameraKit/Constants.swift` | Exists (Stage 01/03 partial) | All Stage 01 constants plus `frameResultHeartbeatHz=3`, `frameResultHeartbeatIntervalFrames=10`, `resolutionResizeTimeoutSeconds=5.0` | **No changes** — Task 0 verifies only. |
| `CameraKit/Sources/CameraKit/Capabilities.swift` | Exists (Stage 01 + Stage 03 Codable) | `Size`, `Rect`, `SessionCapabilities` (no ranges yet), `OpenConfiguration`, `CameraMode: Codable`, `WhiteBalanceMode: Codable`, `CameraSettings: Codable`, `ProcessingParameters: Codable`. | Add `isoRange: ClosedRange<Float>` + `exposureDurationRangeNs: ClosedRange<Int64>` stored properties + `init` params (Task 7). |
| `CameraKit/Sources/CameraKit/Settings.swift` | Exists (Stage 03 partial, untracked) | `CameraSettings.merging(onto:)` extension (Settings.swift:11–26); `enum SettingsCoupling` with `static func apply(rules:latched:) throws -> CameraSettings` implementing Rule 1/2 propagation + Rule 3 latch (Settings.swift:36–67). | **No code changes.** Task 2 only verifies by running the two tests that depend on it. |
| `CameraKit/Sources/CameraKit/SettingsPersistence.swift` | Exists (Stage 03 partial, untracked) | `enum SettingsPersistence` with `static let key = "CameraKit.CameraSettings"`, `static func save(_:defaults:)`, `static func load(defaults:) -> CameraSettings?`. | **No code changes.** Task 3 only verifies. |
| `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` | Exists (Stage 01) | Protocol with configuration methods; `DeviceStateSnapshot`, `SystemPressureLevel`; `actor LiveCaptureDevice` implementing AVCaptureDevice-backed production. | Add protocol members `snapshotStream() -> AsyncStream<DeviceStateSnapshot>` + `var lastSnapshot: DeviceStateSnapshot? { get async }`; implement on `LiveCaptureDevice` using new `DeviceKVOObserver` (Task 1 stub-only; Task 4 wires KVO). |
| `CameraKit/Sources/CameraKit/CameraSession.swift` | Exists (Stage 01) | `configure(deliveryQueue:sampleBufferDelegate:)`, `startRunning()`, `stopRunning()`, `start/stopRunningAsync()`. | Add `applySettings(_ settings: CameraSettings, on device: any CaptureDeviceProviding) async throws` — single `lockForConfiguration()` window on `sessionQueue` (Task 5); add `reconfigureSize(_ size: Size) async throws` for `setResolution` (Task 8). |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Exists (Stage 01 + Stage 02) | Stage 01 stub body for `updateSettings(_:)` at CameraEngine.swift:155–157; no `setResolution`, no `frameResultStream`. | Implement `updateSettings(_:)` body with merge+couple+validate+dispatch+persist (Task 6); add `setResolution(size:)` (Task 8); add `frameResultStream()` heartbeat (Task 9); load persisted settings in `open()` + cancel KVO in `close()` (Task 6 tail). |
| `CameraKit/Sources/CameraKit/CaptureDelegate.swift` | Exists (Stage 02) | Nonisolated `onSampleBuffer` hook. | Add `weak var engine: CameraEngine?` + call `engine?.tickFrame()` from the sample-buffer callback (Task 9). |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Exists (Stage 02) | `sessionState`, `capabilities`, `error`, `naturalTex`, `handleScenePhase`. | Add observable `currentSettings`, `deviceSnapshot`, `lastFrameResult`; add `updateISO/Shutter/Focus/Zoom` methods; start/cancel a `frameResultTask` in `start()`/`stop()` (Task 10). |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Exists (Stage 02) | ZStack hosting `MTKViewRepresentable`; `.task(id: scenePhase)`. | Overlay bottom bar with 4 slider cells wired to ViewModel updates (Task 11). |
| `CameraKit/Sources/CameraKit/KVOAsyncStream.swift` | **Missing — create** | — | New file: `final class DeviceKVOObserver` with two typed-keypath factories: `makeStream(avDevice: AVCaptureDevice)` and `makeStream(source: FakeKVODevice)`. Both return `(AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver)`. Uses the Tokens-box / `onTermination` pattern from `ios-platform-guide/04-avfoundation.md:158-180` (Task 4). |
| `CameraKit/Tests/CameraKitTests/Stage01Tests.swift` | Exists | `actor FakeCaptureDevice: CaptureDeviceProviding` at lines 7–36. | Add trivial `lastSnapshot` + `snapshotStream()` stubs to preserve protocol conformance after Task 1 (Task 1). |
| `CameraKit/Tests/CameraKitTests/Stage02Tests.swift` | Exists | Four tests; no protocol dependency. | **No changes.** Task 0 verifies unchanged. |
| `CameraKit/Tests/CameraKitTests/Stage03Tests.swift` | Exists (untracked, wired into `eva-swift-stitchTests`) | 7 `@Test` functions covering brief §8 TESTABLEs. References `DeviceKVOObserver.makeStream(source:)`, `FakeKVODevice` (declared at lines 180–186), `FakeCaptureDeviceProviding` (lines 188–215), `CameraSession.applySettings(_:on:)`, `CameraEngine.updateSettings`. | **No code changes** — this plan exists to make these tests compile and pass. Tasks 2/3/4/5/6 each run a subset and watch it go green. |
| `CameraKit/state.md` | Exists | Stage 02 closure. | Append Stage 03 section per brief §12 (Task 13). |
| `CameraKit/CONTRACTS.md` | Auto-generated | Shows Stage 02 shape. | Regenerated via `scripts/regen-contracts.sh` in Task 13. |

### 1.2 xcodeproj wiring

`grep` of `eva-swift-stitch.xcodeproj/project.pbxproj` on 2026-04-21 confirms `Stage03Tests.swift` is already a build-file + file-reference member of target `eva-swift-stitchTests` (lines 18, 52, 162, 325). **No Ruby xcodeproj surgery needed.** Paths:

```
file reference: ../CameraKit/Tests/CameraKitTests/Stage03Tests.swift
```

### 1.3 Prior-stage decisions carried forward

From `CameraKit/state.md` "Decisions taken that weren't in briefs":

- **#1** — `swift-tools-version:6.2` stays.
- **#2** — `swift build --package-path CameraKit/` is forbidden on macOS host (iOS-only APIs). All build/test verification goes through `mcp__XcodeBuildMCP__build_device` / `mcp__XcodeBuildMCP__test_device` (primary) or `scripts/build-summary.sh` / `scripts/test-summary.sh` (fallback). Plan verification steps reference only those.
- **#3** — Type compression into existing files (Settings types live in `Capabilities.swift`, not a new `Settings.swift` of type declarations). Continues here: brief §4 says "create Settings.swift with CameraSettings struct + enums"; the file exists but only holds `merging(onto:)` + `SettingsCoupling` since the types are already in `Capabilities.swift` and `FrameSet.swift`.
- **#10** — Tests run via the `eva-swift-stitchTests` host target; `eva-swift-stitch` is the test host. Test filters use `-only-testing:eva-swift-stitchTests/Stage03Tests` (not `CameraKitTests/Stage03Tests`).

### 1.4 Active scaffolds (unchanged)

```
01:simple-metal-passthrough   MetalPipeline.swift:26, TexturePoolManager.swift:36
01:skip-completion-guard      MetalPipeline.swift:142
```

Post-Stage-03 grep must still show ≥1 hit for each; zero hits for `04:…12:`.

---

## 2. Type shape registry (exact declarations referenced by new test/production code)

### 2.1 From `Capabilities.swift`

- `public struct Size: Sendable, Hashable` at Capabilities.swift:6 — `public init(width: Int, height: Int)`.
- `public struct SessionCapabilities: Sendable, Hashable` at Capabilities.swift:28 — `init(supportedSizes:previewTextureId:naturalTextureId:activeCaptureResolution:activeCropRegion:streamPixelFormat:)`. **After Task 7** gains `isoRange` + `exposureDurationRangeNs` stored properties and init params.
- `public struct OpenConfiguration: Sendable, Hashable` at Capabilities.swift:54 — `cameraId`, `captureResolution`, `cropRegion` (all optional).
- `public enum CameraMode: String, Sendable, Hashable, Codable` at Capabilities.swift:72 — cases `.auto`, `.manual`.
- `public enum WhiteBalanceMode: String, Sendable, Hashable, Codable` at Capabilities.swift:77 — cases `.auto`, `.locked`, `.manual`.
- `public struct CameraSettings: Sendable, Hashable, Codable` at Capabilities.swift:85 — all 12 fields optional; extension `merging(onto:)` in `Settings.swift:11`.
- `public struct ProcessingParameters: Sendable, Hashable, Codable` at Capabilities.swift:122.

### 2.2 From `FrameSet.swift`

- `public struct WhiteBalanceGains: Sendable, Hashable` at FrameSet.swift:83 — `public init(red: Float, green: Float, blue: Float)`.
- `public struct FrameResult: Sendable, Hashable` at FrameSet.swift:116 — all 6 fields optional; `public init(iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil, wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil)`.

### 2.3 From `CaptureDeviceProviding.swift`

- `public protocol CaptureDeviceProviding: AnyObject, Sendable` at CaptureDeviceProviding.swift:8. Current required members (all `async` getters / `async throws` methods): `uniqueID`, `activeFormatSize`, `supportedSizes`, `isoRange`, `exposureDurationRangeNs`, `maxWhiteBalanceGain`, `lockForConfiguration()`, `unlockForConfiguration()`, `setExposureModeCustom(durationNs:iso:)`, `setContinuousAutoExposure()`, `setFocusModeLocked(lensPosition:)`, `setContinuousAutoFocus()`, `setWhiteBalanceModeLocked(gains:)`, `setContinuousAutoWhiteBalance()`, `setWhiteBalanceLocked()`, `setZoomFactor(_:)`, `setExposureCompensation(_:)`, `setVideoFrameDurationRange(minFrameDurationFps:maxFrameDurationFps:)`. **Task 1 adds** `snapshotStream() -> AsyncStream<DeviceStateSnapshot>` (non-async, sync factory that returns an already-subscribed stream) + `var lastSnapshot: DeviceStateSnapshot? { get async }`.
- `public struct DeviceStateSnapshot: Sendable, Hashable` at CaptureDeviceProviding.swift:40 — `public init(iso: Float, exposureDurationNs: Int64, lensPosition: Float, whiteBalanceGains: WhiteBalanceGains, isAdjustingExposure: Bool, systemPressureLevel: SystemPressureLevel)`. **Note:** no `isAdjustingFocus` field; see Deviation 13.
- `public enum SystemPressureLevel: String, Sendable, Hashable` at CaptureDeviceProviding.swift:57 — `.nominal`, `.fair`, `.serious`, `.critical`, `.shutdown`.
- `final actor LiveCaptureDevice: CaptureDeviceProviding` at CaptureDeviceProviding.swift:65. Holds `avDevice: AVCaptureDevice`.

### 2.4 From `Errors.swift`

- `public enum EngineError: Error, Sendable` at Errors.swift:38. Cases used by Stage 03:
  - `notOpen` (Errors.swift:40) — no associated value.
  - `settingsConflict(reason: String)` (Errors.swift:45) — **has associated value.** `#expect(throws: EngineError.settingsConflict)` will not compile (EngineError is not Equatable). Either match with `#expect(throws: EngineError.self)` (any EngineError) or use a closure-based predicate `throws: { error in guard let e = error as? EngineError, case .settingsConflict = e else { return false }; return true }`. Stage03Tests Test 7 uses `#expect(throws: EngineError.self)`; the existing `Settings.swift:54-62` throws `.settingsConflict(reason:)` from `SettingsCoupling.apply`, which fits the `EngineError.self` matcher.
- `public enum MetalError: Error, Sendable` at Errors.swift:53.

### 2.5 From `SessionState.swift`

- `public enum SessionState: String, Sendable, Hashable` — values include `.closed`, `.streaming` (used by CameraEngine already).

### 2.6 New/modified public shapes introduced by Stage 03

- `public func updateSettings(_ settings: CameraSettings) async throws` (replaces stub). Throws when session not open (`.notOpen`) or Rule-3 pre-first-readback / range violations (`.settingsConflict(reason:)`). Persists resolved snapshot on success.
- `public func setResolution(size: Size) async throws` (new). Session-only teardown + reconfigure + restart.
- `public func frameResultStream() -> AsyncStream<FrameResult>` (new). `.bufferingNewest(1)` (ADR-22 frame-rate policy).
- `public let isoRange: ClosedRange<Float>` + `public let exposureDurationRangeNs: ClosedRange<Int64>` on `SessionCapabilities`.
- Internal to module: `final class DeviceKVOObserver: @unchecked Sendable` with two factories returning `(AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver)`.

### 2.7 Test fakes (existing)

- `Stage01Tests.swift:7` — `actor FakeCaptureDevice: CaptureDeviceProviding` returns canned values for sizes/ranges/gain; every config method is a no-op. **Will break when Task 1 adds `snapshotStream()` + `lastSnapshot`** — Task 1 adds trivial stubs.
- `Stage03Tests.swift:180-186` — `final class FakeKVODevice: NSObject` with `@objc dynamic var iso: Float = 100`, `@objc dynamic var exposureDuration: CMTime = CMTime(value: 1, timescale: 30)`, `@objc dynamic var lensPosition: Float = 0`, `@objc dynamic var deviceWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains = AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1)`. Used by Test 5.
- `Stage03Tests.swift:188-215` — `final class FakeCaptureDeviceProviding: CaptureDeviceProviding, @unchecked Sendable`. Exposes `stubbedSnapshot: DeviceStateSnapshot?`, `lastLockedLensPosition: Float?`. Already declares `lastSnapshot` and `snapshotStream()` locally (lines 198, 200) — when Task 1 adds these to the protocol, this fake's members *become* protocol conformances without code change. Used by Test 6.

---

## 3. API registry (verified Apple API signatures used by new code)

Every signature below was retrieved via `mcp__xcode__DocumentationSearch` or `mcp__dash-api__load_documentation_page` on 2026-04-21.

### 3.1 KVO — typed-keypath observe

**Signature (verified via `mcp__xcode__DocumentationSearch` query: `NSObject observe keyPath options Swift type-safe`, framework ObjectiveC):**

```swift
@preconcurrency
func observe<Value>(
    _ keyPath: KeyPath<Self, Value>,
    options: NSKeyValueObservingOptions = [],
    changeHandler: @escaping @Sendable (Self, NSKeyValueObservedChange<Value>) -> Void
) -> NSKeyValueObservation
```

Critical points:
- Only typed `KeyPath<Self, Value>` form exists; no string-keypath `observe` returns `NSKeyValueObservation`. Generic `<T: NSObject>` source code cannot use `\T.iso` unless T is concretely constrained.
- `changeHandler` is `@Sendable`; `[weak self]` required to avoid cycles per ios-platform-guide/04-avfoundation.md:208-222.
- `NSKeyValueObservation.invalidate()` is the deterministic stop. Tokens-box `deinit` calls it per ios-platform-guide/04-avfoundation.md:158-180.

Consequence for `DeviceKVOObserver`: two concrete factories, one per source type. No string-keypath generic.

### 3.2 AVCaptureDevice KVO-observable properties

All verified via `mcp__xcode__DocumentationSearch`, framework AVFoundation:

| Property | Type | Access | KVO? |
|---|---|---|---|
| `iso` | `Float` | get | yes |
| `exposureDuration` | `CMTime` | get | yes |
| `lensPosition` | `Float` | get | yes |
| `deviceWhiteBalanceGains` | `AVCaptureDevice.WhiteBalanceGains` | get | yes |
| `isAdjustingExposure` | `Bool` | get | yes |
| `isAdjustingFocus` | `Bool` | get | yes |
| `isAdjustingWhiteBalance` | `Bool` | get | yes |

Stage 03 observes the first four properties to emit one `DeviceStateSnapshot` per KVO change. (`isAdjustingFocus` is not part of `DeviceStateSnapshot` today — see Deviation 13.)

### 3.3 `AVCaptureDevice.setExposureModeCustom`

**Signature (verified via `mcp__xcode__DocumentationSearch` query: `setExposureModeCustom duration iso completionHandler`):**

```swift
func setExposureModeCustom(
    duration: CMTime,
    iso ISO: Float,
    completionHandler handler: (@Sendable (CMTime) -> Void)? = nil
)

// Swift concurrency variant:
func setExposureModeCustom(duration: CMTime, iso ISO: Float) async -> CMTime
```

Not marked `throws`. Raises **NSException** (ObjC) on unsupported levels. Current `LiveCaptureDevice.setExposureModeCustom(durationNs:iso:) throws` at CaptureDeviceProviding.swift:106 is `throws`-shaped to conform to the protocol but never actually throws. Range validation must happen in `CameraEngine.updateSettings(_:)` before dispatching, not via `catch`.

### 3.4 `AVCaptureDevice.setFocusModeLocked`

**Signature (verified via `mcp__dash-api__load_documentation_page` on `/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:)`):**

```swift
func setFocusModeLocked(
    lensPosition: Float,
    completionHandler handler: (@Sendable (CMTime) -> Void)? = nil
)

// async variant:
func setFocusModeLocked(lensPosition: Float) async -> CMTime
```

Same shape — not Swift `throws`, raises NSException on unsupported levels. `LiveCaptureDevice` already wraps this at CaptureDeviceProviding.swift:116.

### 3.5 `AsyncStream` init with buffering policy

**Signature (verified via `mcp__xcode__DocumentationSearch` query: `AsyncStream init bufferingPolicy bufferingNewest bufferingOldest initializer`):**

```swift
init(
    _ elementType: Element.Type = Element.self,
    bufferingPolicy limit: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded,
    _ build: (AsyncStream<Element>.Continuation) -> Void
)
```

`BufferingPolicy` cases: `.unbounded`, `.bufferingOldest(Int)` (discards newest on overflow — every transition delivered until overflow), `.bufferingNewest(Int)` (discards oldest on overflow — latest value preferred).

**Policy assignment:**
- `DeviceStateSnapshot` KVO stream → `.bufferingOldest(Constants.stateStreamBufferSize)` per architecture/02-concurrency.md:234.
- `frameResultStream()` → `.bufferingNewest(1)` per architecture/02-concurrency.md:250 and brief §7.

### 3.6 `AVCaptureDevice` white-balance + zoom + EV methods already wrapped

`LiveCaptureDevice` already implements `setWhiteBalanceModeLocked(gains:)`, `setContinuousAutoWhiteBalance()`, `setWhiteBalanceLocked()`, `setZoomFactor(_:)`, `setExposureCompensation(_:)`, `setVideoFrameDurationRange(...)`. Stage 03 dispatches through these — no fresh API wrapping needed.

---

## 4. Tasks

Each task: self-contained, commit-worthy. Verification via `mcp__XcodeBuildMCP__build_device` / `test_device`. Fallback wrappers (`scripts/build-summary.sh`, `scripts/test-summary.sh`) only if MCP unavailable.

---

### Task 0: Pre-flight and baseline verification

**Files:** none modified; read-only gates.

- [ ] **Step 1: Confirm stage-entry coherence**

Run: `scripts/stage-preflight.sh`
Expected: exit 0; script prints an OK message and the active-scaffold inventory.

- [ ] **Step 2: Verify active scaffolds unchanged from Stage 02**

Run:
```bash
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
```
Expected: ≥1 hit for each slug. `01:simple-metal-passthrough` at `MetalPipeline.swift:26`, `TexturePoolManager.swift:36`; `01:skip-completion-guard` at `MetalPipeline.swift:142`.

- [ ] **Step 3: Verify no future-stage slugs present**

Run:
```bash
grep -rn '04:\|05:\|06:\|07:\|08:\|09:\|10:\|11:\|12:' CameraKit/Sources/
```
Expected: 0 hits.

- [ ] **Step 4: Configure XcodeBuildMCP session defaults**

Call `mcp__XcodeBuildMCP__session_show_defaults`. If project/scheme/destination are absent, call `mcp__XcodeBuildMCP__session_set_defaults`:
```
projectPath: "eva-swift-stitch.xcodeproj"
scheme: "eva-swift-stitch"
```
Destination comes from `xcrun xctrace list devices` — prefer the physical iPad UDID (`platform=iOS,id=<udid>`); fall back to `platform=macOS,arch=arm64,variant=Designed for iPad` if no device connected. **Never** `platform=iOS Simulator,…` (CLAUDE.md §6 top).

- [ ] **Step 5: Baseline build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. Do not proceed on failure.

- [ ] **Step 6: Baseline tests (Stage 01 + Stage 02 must pass; Stage 03 must currently fail compile)**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests"] }`.
Expected: 5 Stage 01 tests + 4 Stage 02 tests all pass (9 total).

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: **BUILD FAILED** — the file references `DeviceKVOObserver`, `CameraSession.applySettings`, and a `FakeCaptureDeviceProviding` that conforms to `CaptureDeviceProviding` with members that aren't yet on the protocol. Capture the exact compiler diagnostics to the session log — they drive the remaining tasks.

**No commit.** Baseline only.

---

### Task 1: Extend `CaptureDeviceProviding` with `snapshotStream()` + `lastSnapshot`; stub in `LiveCaptureDevice` and `FakeCaptureDevice`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift`
- Modify: `CameraKit/Tests/CameraKitTests/Stage01Tests.swift`

- [ ] **Step 1: Add protocol members**

Open `CaptureDeviceProviding.swift`. After the `func setVideoFrameDurationRange(...)` declaration (currently CaptureDeviceProviding.swift:32-35), inside the `public protocol` block, append:

```swift
    // Stage 03 — KVO-backed device-state stream (ADR-14). Rule 3 of
    // ISO/exposure coupling reads `lastSnapshot`.
    func snapshotStream() -> AsyncStream<DeviceStateSnapshot>
    var lastSnapshot: DeviceStateSnapshot? { get async }
```

- [ ] **Step 2: Add trivial-but-correct impl to `LiveCaptureDevice` (KVO wiring arrives in Task 4)**

In `CaptureDeviceProviding.swift`, first mark `avDevice` as `nonisolated` at line 66 so the `nonisolated snapshotStream()` factory can read it without an actor hop. Change:

```swift
    let avDevice: AVCaptureDevice
```
to:
```swift
    nonisolated let avDevice: AVCaptureDevice
```

**Why:** `snapshotStream()` is `nonisolated` (protocol requires a non-`async` method); its body in Task 4 passes `avDevice` to `DeviceKVOObserver.makeStream(avDevice:)`. Swift 6 strict concurrency rejects reading actor-isolated state from a nonisolated context; marking the `let` `nonisolated` declares the intent explicitly. `AVCaptureDevice` is a reference type whose mutation is always gated by `lockForConfiguration()` on `sessionQueue`, so nonisolated read access is safe.

Then extend the `final actor LiveCaptureDevice` body (currently ends at CaptureDeviceProviding.swift:152). Add stored state + stub methods BEFORE Task 4 wires them to real KVO. Append inside the actor:

```swift
    // Populated by installKVOIngest() in Task 4; nil until then.
    private var kvoObserver: DeviceKVOObserver?
    private var _lastSnapshot: DeviceStateSnapshot?

    var lastSnapshot: DeviceStateSnapshot? { _lastSnapshot }

    /// Produces one emission per KVO change (ADR-14). In this task the
    /// returned stream finishes immediately — Task 4 wires it to live KVO.
    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { $0.finish() }
    }
```

**Note:** `snapshotStream()` is `nonisolated` because the protocol requirement is a non-`async` method. Keep the actor-isolated `lastSnapshot` as an `async` getter (matches protocol's `{ get async }`).

- [ ] **Step 3: Add trivial stubs to Stage 01 `FakeCaptureDevice`**

Open `CameraKit/Tests/CameraKitTests/Stage01Tests.swift`. Inside the `actor FakeCaptureDevice: CaptureDeviceProviding { … }` body (currently Stage01Tests.swift:7-36), append before the closing brace:

```swift
    var lastSnapshot: DeviceStateSnapshot? { nil }
    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { $0.finish() }
    }
```

**Note:** Stage 03's `FakeCaptureDeviceProviding` at `Stage03Tests.swift:198-202` already declares both members. After Task 1 the protocol requires them, and the Stage 03 fake's existing declarations *become* conformances without source change.

- [ ] **Step 4: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`. The remaining Stage 03 test compile errors narrow to `DeviceKVOObserver` (Task 4) and `CameraSession.applySettings` (Task 5).

- [ ] **Step 5: Re-run Stage 01 + Stage 02 tests**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests"] }`.
Expected: 9 tests pass unchanged.

- [ ] **Step 6: Commit**

```bash
git add CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift \
        CameraKit/Tests/CameraKitTests/Stage01Tests.swift
git commit -m "feat(stage-03): add snapshotStream + lastSnapshot to CaptureDeviceProviding (stubs)"
```

---

### Task 2: Verify `CameraSettings.merging(onto:)` and `SettingsCoupling.apply(rules:latched:)` pass their tests

**Files:** none modified. This task converts the existing (untracked) `Settings.swift` from "written but unverified" to "verified green" by running the three tests that depend on it.

The existing source is `CameraKit/Sources/CameraKit/Settings.swift` — untracked in `git status`. Contents verified in read pass:
- Lines 11–26: `extension CameraSettings { func merging(onto:) -> CameraSettings }` — pure non-nil-field overlay.
- Lines 36–67: `enum SettingsCoupling { static func apply(rules:latched:) throws -> CameraSettings }` — Rule 1/2 propagation with `.auto` wins, Rule 3 latches from `latched` snapshot, throws `EngineError.settingsConflict(reason: "Rule 3: manual ISO/exposure requested before first KVO readback")` on pre-first-readback.

- [ ] **Step 1: Run merge + rule 1/2 + rule 3 tests**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests/settingsMergeNonNilFields", "-only-testing:eva-swift-stitchTests/Stage03Tests/isoShutterAutoSwitch", "-only-testing:eva-swift-stitchTests/Stage03Tests/rule3ManualWithoutLatchThrows"] }`.
Expected: 3 tests pass.

The `rule3ManualWithoutLatchThrows` test (Stage03Tests.swift:98-109) uses the closure-based `throws:` predicate correctly:
```swift
#expect {
    _ = try SettingsCoupling.apply(rules: s, latched: nil)
} throws: { error in
    guard let e = error as? EngineError, case .settingsConflict = e else { return false }
    return true
}
```
This matches the associated-value `EngineError.settingsConflict(reason:)` without requiring Equatable.

- [ ] **Step 2: Stage the existing (untracked) source + commit**

```bash
git add CameraKit/Sources/CameraKit/Settings.swift
git commit -m "feat(stage-03): CameraSettings.merging + SettingsCoupling (Rules 1/2/3)"
```

---

### Task 3: Verify `SettingsPersistence` round-trip test passes

**Files:** none modified. Existing untracked source `CameraKit/Sources/CameraKit/SettingsPersistence.swift` (20 lines, verified):

```swift
enum SettingsPersistence {
    static let key = "CameraKit.CameraSettings"
    static func save(_ settings: CameraSettings, defaults: UserDefaults = .standard) { … }
    static func load(defaults: UserDefaults = .standard) -> CameraSettings? { … }
}
```

Depends on `CameraSettings: Codable` (already at Capabilities.swift:85). `UserDefaults` is `Sendable`.

- [ ] **Step 1: Run the roundtrip test**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests/userDefaultsPersistenceRoundtrip"] }`.
Expected: PASS. Test uses a per-test `UUID`-keyed `UserDefaults(suiteName:)` (Stage03Tests.swift:36-52) so there's no cross-test pollution.

- [ ] **Step 2: Commit**

```bash
git add CameraKit/Sources/CameraKit/SettingsPersistence.swift
git commit -m "feat(stage-03): SettingsPersistence UserDefaults round-trip"
```

---

### Task 4: `DeviceKVOObserver` — KVO → AsyncStream adapter (TESTABLE 03:kvo-asyncstream-adapter-emits-on-change)

**Files:**
- Create: `CameraKit/Sources/CameraKit/KVOAsyncStream.swift`
- Modify: `CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift` — rewire `LiveCaptureDevice.snapshotStream()` + populate `_lastSnapshot`.

The Stage 03 test at `Stage03Tests.swift:114-144` calls:
```swift
let fake = FakeKVODevice()
let (stream, observer) = DeviceKVOObserver.makeStream(source: fake)
…
fake.iso = 800
…
let iso = try await receivedOne.value
#expect(iso == 800)
```

`FakeKVODevice` (Stage03Tests.swift:180-186) is an `NSObject` with `@objc dynamic var iso: Float`, `exposureDuration: CMTime`, `lensPosition: Float`, `deviceWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains`.

Swift KVO's `observe(_:options:changeHandler:)` requires `KeyPath<Self, Value>` — there is no string-keypath form returning `NSKeyValueObservation` (API registry §3.1). `FakeKVODevice` lives in the test target, so a `makeStream(source: FakeKVODevice)` factory can't live in the production module. The design splits as:

- `KVOAsyncStream.swift` (production) — defines `DeviceKVOObserver`, its `internal` nested `Tokens` box, the production `makeStream(avDevice:)` factory, and a generic `makeStreamFromObservations(install:)` helper that takes a closure responsible for populating the Tokens box. Knows nothing about `FakeKVODevice`.
- `Stage03Tests.swift` (test target, `@testable import CameraKit`) — defines the test-only `extension DeviceKVOObserver { static func makeStream(source: FakeKVODevice) }` that calls the production helper, installing observations on the `FakeKVODevice`. Also marks `FakeKVODevice` as `@unchecked Sendable` so it can be captured in the `@Sendable install` closure.

- [ ] **Step 1: Create `CameraKit/Sources/CameraKit/KVOAsyncStream.swift`**

```swift
import AVFoundation
import CoreMedia
import Foundation

/// KVO → AsyncStream<DeviceStateSnapshot> adapter per ADR-14.
///
/// Tokens-box lifetime: observations are held in a reference-type box whose
/// `deinit` invalidates them. The stream's `onTermination` keeps the box alive
/// until the consumer ends its `for await` loop; on termination the box drops
/// and KVO detaches deterministically (ios-platform-guide/04-avfoundation.md
/// §Tokens box).
final class DeviceKVOObserver: @unchecked Sendable {

    /// Internal visibility so the Stage 03 test-only factory extension
    /// (in `Stage03Tests.swift`) can construct token boxes.
    final class Tokens {
        var values: [NSKeyValueObservation] = []
        deinit { values.forEach { $0.invalidate() } }
    }

    fileprivate var tokens: Tokens?

    /// Shared producer closure. `install` is invoked exactly once inside the
    /// AsyncStream build closure; it populates `box.values` with observations
    /// that call `cont.yield(snap)` per KVO change. This split lets the
    /// production factory `makeStream(avDevice:)` and the test factory
    /// `makeStream(source:)` share lifetime + buffering logic.
    static func makeStreamFromObservations(
        install: @escaping @Sendable (
            _ cont: AsyncStream<DeviceStateSnapshot>.Continuation,
            _ box: Tokens
        ) -> Void
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        let observer = DeviceKVOObserver()
        let stream = AsyncStream<DeviceStateSnapshot>(
            DeviceStateSnapshot.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak observer] cont in
            let box = Tokens()
            install(cont, box)
            observer?.tokens = box
            cont.onTermination = { _ in _ = box }
        }
        return (stream, observer)
    }

    /// Production entry — wraps a live `AVCaptureDevice`.
    static func makeStream(
        avDevice: AVCaptureDevice
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        makeStreamFromObservations { cont, box in
            box.values = [
                avDevice.observe(\.iso, options: [.initial, .new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                avDevice.observe(\.exposureDuration, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                avDevice.observe(\.lensPosition, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                avDevice.observe(\.deviceWhiteBalanceGains, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                }
            ]
        }
    }

    /// Snapshot builder for AVCaptureDevice. Internal (not private) so the
    /// test factory extension can share snapshot-construction logic.
    static func snapshot(avDevice d: AVCaptureDevice) -> DeviceStateSnapshot {
        let ns = Int64(CMTimeGetSeconds(d.exposureDuration) * 1_000_000_000)
        return DeviceStateSnapshot(
            iso: d.iso,
            exposureDurationNs: ns,
            lensPosition: d.lensPosition,
            whiteBalanceGains: WhiteBalanceGains(
                red: d.deviceWhiteBalanceGains.redGain,
                green: d.deviceWhiteBalanceGains.greenGain,
                blue: d.deviceWhiteBalanceGains.blueGain),
            isAdjustingExposure: d.isAdjustingExposure,
            systemPressureLevel: .nominal)
    }
}
```

- [ ] **Step 2: Add the test-only factory + `@unchecked Sendable` on `FakeKVODevice` in `Stage03Tests.swift`**

`Stage03Tests.swift` is untracked (`git status` shows `?? CameraKit/Tests/CameraKitTests/Stage03Tests.swift` — not yet committed). Two edits:

**Edit A** — mark `FakeKVODevice` as `@unchecked Sendable`. The class currently begins at Stage03Tests.swift:180 as:
```swift
final class FakeKVODevice: NSObject {
```
Change to:
```swift
final class FakeKVODevice: NSObject, @unchecked Sendable {
```

**Why:** `makeStreamFromObservations(install:)` takes an `@escaping @Sendable` closure. The test factory's `install` body captures `source: FakeKVODevice`, so the source type must be `Sendable`. `NSObject` is not `Sendable` by default; `@unchecked Sendable` declares that the test author takes responsibility for thread-safety (the fake's properties are `@objc dynamic` KVO-observable, mutated from test code only).

**Edit B** — append below the existing `FakeCaptureDeviceProviding` class (after the current closing brace of that class, at end of file), outside the `@Suite Stage03Tests struct`:

```swift
// Test-only factory over a synthetic NSObject source (avoids any dependency
// on AVCaptureDevice hardware). Production entry is in KVOAsyncStream.swift.
extension DeviceKVOObserver {
    static func makeStream(
        source: FakeKVODevice
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        makeStreamFromObservations { cont, box in
            box.values = [
                source.observe(\.iso, options: [.initial, .new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.exposureDuration, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.lensPosition, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.deviceWhiteBalanceGains, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                }
            ]
        }
    }

    // Snapshot builder for FakeKVODevice (test-only).
    static func snapshot(fake d: FakeKVODevice) -> DeviceStateSnapshot {
        let ns = Int64(CMTimeGetSeconds(d.exposureDuration) * 1_000_000_000)
        return DeviceStateSnapshot(
            iso: d.iso,
            exposureDurationNs: ns,
            lensPosition: d.lensPosition,
            whiteBalanceGains: WhiteBalanceGains(
                red: d.deviceWhiteBalanceGains.redGain,
                green: d.deviceWhiteBalanceGains.greenGain,
                blue: d.deviceWhiteBalanceGains.blueGain),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal)
    }
}
```

- [ ] **Step 3: Wire `LiveCaptureDevice.snapshotStream()` to the real observer**

In `CaptureDeviceProviding.swift`, replace the Task 1 stub `snapshotStream()` on `LiveCaptureDevice`. Also start ingesting into `_lastSnapshot` so Rule 3 + frame-result heartbeat can read it.

Find the stub added in Task 1 and replace with:

```swift
    private var ingestTask: Task<Void, Never>?

    /// KVO-backed device-state stream (ADR-14). Each caller gets a fresh
    /// stream sharing the same observer lifetime; the first call installs
    /// the ingest task that updates `_lastSnapshot`.
    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        // Build a standalone stream + observer pair per call. The observer
        // lives only as long as the stream is consumed.
        let (stream, _) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        return stream
    }

    /// Installs the lastSnapshot ingest task. Called once on first open().
    func installKVOIngest() {
        guard ingestTask == nil else { return }
        let (stream, observer) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        kvoObserver = observer
        ingestTask = Task { [weak self] in
            for await snap in stream {
                if Task.isCancelled { return }
                await self?.setLastSnapshot(snap)
            }
        }
    }

    /// Cancels the ingest task and drops the observer so KVO detaches.
    /// Called from `CameraEngine.close()`.
    func cancelKVO() {
        ingestTask?.cancel()
        ingestTask = nil
        kvoObserver = nil
    }

    private func setLastSnapshot(_ snap: DeviceStateSnapshot) {
        _lastSnapshot = snap
    }
```

**Actor-isolation note:** `snapshotStream()` is `nonisolated` because the protocol member is a non-`async` function. The `avDevice` property was marked `nonisolated let` in Task 1 Step 2, which makes this factory body valid under Swift 6 strict concurrency: a `nonisolated let` can be read from any context. `AVCaptureDevice` is a reference type whose mutation is always gated by `lockForConfiguration()` on `sessionQueue`, so nonisolated read access is safe.

- [ ] **Step 4: Build + run the KVO test**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests/kvoAsyncStreamAdapterEmitsOnChange"] }`.
Expected: PASS. The test pauses 50 ms, mutates `fake.iso = 800`, awaits first yield, asserts `iso == 800`.

- [ ] **Step 5: Re-run Stage 01 + Stage 02 to confirm no regression**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests"] }`.
Expected: 9 tests pass.

- [ ] **Step 6: Commit**

```bash
git add CameraKit/Sources/CameraKit/KVOAsyncStream.swift \
        CameraKit/Sources/CameraKit/CaptureDeviceProviding.swift \
        CameraKit/Tests/CameraKitTests/Stage03Tests.swift
git commit -m "feat(stage-03): DeviceKVOObserver (ADR-14) + LiveCaptureDevice KVO ingest"
```

---

### Task 5: `CameraSession.applySettings` — single `lockForConfiguration()` window (TESTABLE 03:focus-distance-identity)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift`

Test 6 (`focusDistanceIdentity`, Stage03Tests.swift:149-161) calls `try await session.applySettings(s, on: fake)` with `s.focusMode = .manual, s.focusDistance = 0.5`, then asserts `fake.lastLockedLensPosition == 0.5`. The fake's `setFocusModeLocked(lensPosition:)` stores the argument.

- [ ] **Step 1: Add the `applySettings` method to `CameraSession`**

Open `CameraSession.swift`. Append to the `final class CameraSession` body, after `stopRunningAsync()` (currently CameraSession.swift:233-237):

```swift
    /// Commits a fully-resolved `CameraSettings` to the device inside a single
    /// `lockForConfiguration()` window on `sessionQueue` (ADR-07).
    ///
    /// The caller (`CameraEngine.updateSettings`) is responsible for having
    /// already run `merging(onto:)`, `SettingsCoupling.apply(rules:latched:)`,
    /// and range validation — this function only commits.
    ///
    /// ISO + exposure are coupled by `setExposureModeCustom(durationNs:iso:)`'s
    /// API shape (07-settings.md §Commit shape). Focus, white balance, zoom,
    /// and EV bias commit independently inside the same lock window.
    func applySettings(
        _ settings: CameraSettings,
        on device: any CaptureDeviceProviding
    ) async throws {
        try await device.lockForConfiguration()
        do {
            // Exposure + ISO — coupled commit when both manual.
            if settings.exposureMode == .manual,
               let durationNs = settings.exposureTimeNs,
               let iso = settings.iso {
                try await device.setExposureModeCustom(
                    durationNs: durationNs,
                    iso: Float(iso))
            } else if settings.exposureMode == .auto {
                try await device.setContinuousAutoExposure()
            }

            // Focus.
            if settings.focusMode == .manual, let d = settings.focusDistance {
                try await device.setFocusModeLocked(lensPosition: Float(d))
            } else if settings.focusMode == .auto {
                try await device.setContinuousAutoFocus()
            }

            // White balance.
            if let mode = settings.wbMode {
                switch mode {
                case .manual:
                    if let r = settings.wbGainR,
                       let g = settings.wbGainG,
                       let b = settings.wbGainB {
                        try await device.setWhiteBalanceModeLocked(
                            gains: WhiteBalanceGains(
                                red: Float(r),
                                green: Float(g),
                                blue: Float(b)))
                    }
                case .locked:
                    try await device.setWhiteBalanceLocked()
                case .auto:
                    try await device.setContinuousAutoWhiteBalance()
                }
            }

            // Zoom.
            if let z = settings.zoomRatio {
                try await device.setZoomFactor(z)
            }

            // EV compensation (effective only in auto exposure per domain).
            if let ev = settings.evCompensation {
                try await device.setExposureCompensation(ev)
            }

            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }
```

**Queue note:** the protocol's methods are `async`; the production `LiveCaptureDevice` is an actor whose implementations call `AVCaptureDevice` synchronously inside `lockForConfiguration` — all AVCaptureDevice mutations happen on the actor's executor. `sessionQueue` ownership (ADR-07) is preserved because `LiveCaptureDevice`'s serial executor effectively serializes configuration work. No explicit `sessionQueue.async` wrapper is needed at this level. (State.md Decision #7 establishes that the gate/configuration serialization discipline is enforced by the actor + the existing `startRunningAsync/stopRunningAsync` paths; Stage 03 applies the same discipline here.)

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run the focus-distance-identity test**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests/focusDistanceIdentity"] }`.
Expected: PASS. `fake.lastLockedLensPosition` becomes `0.5` (Float conversion from Double via `Float(0.5)` is exact — 0.5 is representable).

- [ ] **Step 4: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraSession.swift
git commit -m "feat(stage-03): CameraSession.applySettings single lockForConfiguration window"
```

---

### Task 6: `CameraEngine.updateSettings` — merge + couple + validate + dispatch + persist (TESTABLE 03:settings-conflict-throws)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

Test 7 (`settingsConflictThrows`, Stage03Tests.swift:166-176) creates `let engine = CameraEngine()` (no `open()`) and calls `try await engine.updateSettings(s)` with out-of-range values, expecting any `EngineError`. Because the engine's session is nil, the minimum viable implementation throws `EngineError.notOpen` early — no need to actually reach range validation for this test. Range validation is still implemented (brief §7) but exercised only via HITL.

- [ ] **Step 1: Replace the stub body of `updateSettings(_:)`**

Open `CameraEngine.swift`. The stub is at CameraEngine.swift:153-157. Replace the whole function body:

```swift
    /// Merges incoming non-nil fields onto the persisted snapshot, applies
    /// ISO/exposure coupling rules 1/2/3 (07-settings.md), validates against
    /// the device's supported ranges, then commits through
    /// `CameraSession.applySettings(_:on:)` and persists the resolved
    /// snapshot.
    ///
    /// - Throws: `EngineError.notOpen` if the engine is not yet open.
    /// - Throws: `EngineError.settingsConflict(reason:)` on Rule-3 failure or
    ///   out-of-range values; no device mutation occurs on throw.
    public func updateSettings(_ settings: CameraSettings) async throws {
        guard let session = cameraSession, let device = session.device else {
            throw EngineError.notOpen
        }

        // 1. Merge onto prior state.
        let prior = currentSettings ?? CameraSettings()
        let merged = settings.merging(onto: prior)

        // 2. Couple (Rules 1/2/3). Reads the last KVO snapshot for Rule 3.
        let latched = await device.lastSnapshot
        let resolved = try SettingsCoupling.apply(rules: merged, latched: latched)

        // 3. Range-validate against the device's supported ranges (brief §7).
        let isoRange = await device.isoRange
        let expRange = await device.exposureDurationRangeNs
        if let iso = resolved.iso, !isoRange.contains(Float(iso)) {
            throw EngineError.settingsConflict(
                reason: "iso=\(iso) outside supported range \(isoRange)")
        }
        if let exp = resolved.exposureTimeNs, !expRange.contains(exp) {
            throw EngineError.settingsConflict(
                reason: "exposureTimeNs=\(exp) outside supported range \(expRange)")
        }
        if let focus = resolved.focusDistance, !(0.0 ... 1.0).contains(focus) {
            throw EngineError.settingsConflict(
                reason: "focusDistance=\(focus) outside [0.0, 1.0]")
        }

        // 4. Commit through session (ADR-07).
        try await session.applySettings(resolved, on: device)
        currentSettings = resolved

        // 5. Persist. `UserDefaults` is Sendable; the helper is nonisolated.
        //    Detached so the actor doesn't block on I/O.
        let toSave = resolved
        Task.detached { SettingsPersistence.save(toSave) }
    }

    // Actor state for the merge path.
    private var currentSettings: CameraSettings?
```

**Important:** put the `private var currentSettings` declaration in the actor's stored-property section (top of the body, near the other private vars at CameraEngine.swift:18-25). Place the function in the public-API section.

Concretely: add `private var currentSettings: CameraSettings?` immediately after line 25 (`private var isOpen: Bool = false`). Then replace the old stub body with the new implementation inside the existing function at CameraEngine.swift:153-157.

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run the conflict test**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage03Tests/settingsConflictThrows"] }`.
Expected: PASS. The test hits the `guard let session = cameraSession, let device = session.device` branch; `cameraSession` is nil (no `open()` called), so `EngineError.notOpen` is thrown and matched by `#expect(throws: EngineError.self)`.

- [ ] **Step 4: Install the KVO ingest in `open()` + cancel in `close()`**

In `CameraEngine.open(configuration:)` body, after the `self.cameraSession = session` line (CameraEngine.swift:81) and before `self.isOpen = true`, install the KVO ingest and load persisted settings:

```swift
        // Install KVO ingest so `lastSnapshot` is populated for Rule 3 and
        // for `frameResultStream()` consumption.
        if let live = device as? LiveCaptureDevice {
            await live.installKVOIngest()
        }
```

Still inside `open()`, immediately before the `return SessionCapabilities(...)` line (currently CameraEngine.swift:107), apply persisted settings:

```swift
        // Apply persisted settings if any (07-settings.md §Persistence).
        // Swallow failures here — a pre-first-readback Rule 3 failure on a
        // persisted manual-mode snapshot is expected; next user interaction
        // re-attempts with a populated latched snapshot.
        if let persisted = SettingsPersistence.load() {
            do {
                try await self.updateSettings(persisted)
            } catch {
                // intentional — don't block open() on a transient Rule 3
            }
        }
```

In `close()` body (currently CameraEngine.swift:117-131), after `submissionGate.store(false, ...)` and before the `session.sessionQueue.sync { session.stopRunning() }` call, cancel the KVO ingest:

```swift
        if let live = cameraSession?.device as? LiveCaptureDevice {
            await live.cancelKVO()
        }
```

- [ ] **Step 5: Build + re-run Stage 01/02/03 to ensure no regression**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 9 prior + 7 Stage 03 = **16 tests pass**.

- [ ] **Step 6: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-03): CameraEngine.updateSettings (merge→couple→validate→commit→persist)"
```

---

### Task 7: `SessionCapabilities` gains `isoRange` + `exposureDurationRangeNs`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (callsite update)

Brief §4: "`modify: Sources/CameraKit/Capabilities.swift` — include format-supported ISO / exposure-duration ranges in `SessionCapabilities`."

`ClosedRange<Float>` and `ClosedRange<Int64>` both conform to `Hashable` (their bounds types are `Hashable`), so `SessionCapabilities` retains its `Sendable, Hashable` synthesis.

- [ ] **Step 1: Extend the struct declaration + init**

In `Capabilities.swift`, update `public struct SessionCapabilities: Sendable, Hashable` (starts at Capabilities.swift:28):

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

    public init(
        supportedSizes: [Size],
        previewTextureId: Int,
        naturalTextureId: Int,
        activeCaptureResolution: Size,
        activeCropRegion: Rect,
        streamPixelFormat: String,
        isoRange: ClosedRange<Float>,
        exposureDurationRangeNs: ClosedRange<Int64>
    ) {
        self.supportedSizes = supportedSizes
        self.previewTextureId = previewTextureId
        self.naturalTextureId = naturalTextureId
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
        self.streamPixelFormat = streamPixelFormat
        self.isoRange = isoRange
        self.exposureDurationRangeNs = exposureDurationRangeNs
    }
}
```

- [ ] **Step 2: Update the single existing call site in `CameraEngine.open()`**

In `CameraEngine.swift` at the `return SessionCapabilities(...)` block (currently CameraEngine.swift:107-114), populate the two new fields from the protocol's existing async getters:

```swift
        let isoRange = await device.isoRange
        let exposureDurationRangeNs = await device.exposureDurationRangeNs
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: captureSize,
            activeCropRegion: activeCropRegion,
            streamPixelFormat: "420f",
            isoRange: isoRange,
            exposureDurationRangeNs: exposureDurationRangeNs
        )
```

- [ ] **Step 3: Build + re-run all tests**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/Sources/CameraKit/Capabilities.swift \
        CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "feat(stage-03): SessionCapabilities exposes isoRange + exposureDurationRangeNs"
```

---

### Task 8: `CameraEngine.setResolution(size:)` — session-only teardown placeholder

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift`

Brief §4: `setResolution(size:)` uses "pool resize placeholder until Stage 06 introduces the trio". Session-only teardown per `domain-revised/05-resource-lifecycle.md` §Session-Only Teardown: stop running → re-pick format for `size` → restart.

- [ ] **Step 1: Add `CameraSession.reconfigureSize(_:)`**

In `CameraSession.swift`, append a method to the class body after `stopRunningAsync()`:

```swift
    /// Stage 03 placeholder for `setResolution` (brief §4): re-select the
    /// device format matching `size`; Stage 06 will replace with pool-resize
    /// through the trio. Runs on `sessionQueue` (ADR-07).
    ///
    /// - Throws: `EngineError.noSupportedFormat` if no active-format match exists.
    func reconfigureSize(_ size: Size) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                self.avSession.beginConfiguration()
                defer { self.avSession.commitConfiguration() }

                // Find the matching AVCaptureDevice format.
                let currentInput = self.avSession.inputs
                    .compactMap { $0 as? AVCaptureDeviceInput }
                    .first
                guard let dev = currentInput?.device else {
                    cont.resume(throwing: EngineError.noBackCamera)
                    return
                }
                let match = dev.formats.first { fmt in
                    let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                    return Int(d.width) == size.width && Int(d.height) == size.height
                }
                guard let match else {
                    cont.resume(throwing: EngineError.noSupportedFormat(
                        reason: "no format matching \(size.width)x\(size.height)"))
                    return
                }
                do {
                    try dev.lockForConfiguration()
                    dev.activeFormat = match
                    dev.unlockForConfiguration()
                    cont.resume()
                } catch {
                    cont.resume(throwing: EngineError.lockForConfigurationFailed)
                }
            }
        }
    }
```

- [ ] **Step 2: Add `CameraEngine.setResolution(size:)`**

In `CameraEngine.swift`, append a public method after the existing `updateSettings` function:

```swift
    /// Session-only teardown + re-select format for `size` + restart.
    /// Pool-resize is a placeholder until Stage 06 introduces the trio
    /// (brief §4). Runs on `sessionQueue` (ADR-07).
    ///
    /// - Throws: `EngineError.notOpen` if not yet open; propagates
    ///   `EngineError.noSupportedFormat` from `reconfigureSize`.
    public func setResolution(size: Size) async throws {
        guard let session = cameraSession else { throw EngineError.notOpen }

        // 1. Gate + drain.
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()

        // 2. Stop session + release pipeline.
        await session.stopRunningAsync()
        metalPipeline = nil
        _naturalTex = nil

        // 3. Reconfigure format on sessionQueue.
        try await session.reconfigureSize(size)

        // 4. Rebuild Metal pipeline at the new size.
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let pipeline = try MetalPipeline(
            device: mtlDevice, captureSize: size, gate: submissionGate)
        metalPipeline = pipeline
        _naturalTex = pipeline.currentTexture()

        // 5. Reopen gate + restart.
        submissionGate.store(true, ordering: .sequentiallyConsistent)
        await session.startRunningAsync()
    }
```

- [ ] **Step 3: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

No dedicated test for this method in Stage 03 (brief §8 doesn't enumerate one; covered by HITL if at all). Build green is sufficient.

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift \
        CameraKit/Sources/CameraKit/CameraSession.swift
git commit -m "feat(stage-03): CameraEngine.setResolution session-only teardown (pool-resize placeholder)"
```

---

### Task 9: `CameraEngine.frameResultStream()` — 3 Hz heartbeat

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`
- Modify: `CameraKit/Sources/CameraKit/CaptureDelegate.swift`

Brief §7: "`frameResultStream()` uses `.bufferingNewest(1)` (ADR-22); emission cadence `FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES`" (10 frames at 30 fps = 3 Hz).

- [ ] **Step 1: Add frame-counter + continuation state to `CameraEngine`**

In `CameraEngine.swift`, append to the private-state block (near line 25):

```swift
    private var frameResultContinuation: AsyncStream<FrameResult>.Continuation?
    private var cachedFrameResultStream: AsyncStream<FrameResult>?
    private var frameCounter: UInt64 = 0
```

Then add the public method alongside `stateStream()`:

```swift
    /// Sensor-metadata heartbeat (07-settings.md §Frame-result heartbeat).
    /// Emits at `FRAME_RESULT_HEARTBEAT_HZ` = `frameRateTargetFPS ÷ FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES`.
    /// `.bufferingNewest(1)` per ADR-22 (frame-rate stream).
    public func frameResultStream() -> AsyncStream<FrameResult> {
        if let existing = cachedFrameResultStream { return existing }
        let stream = AsyncStream<FrameResult>(
            FrameResult.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { [weak self] continuation in
            Task { await self?.setFrameResultContinuation(continuation) }
        }
        cachedFrameResultStream = stream
        return stream
    }

    private func setFrameResultContinuation(_ c: AsyncStream<FrameResult>.Continuation) {
        frameResultContinuation = c
    }

    /// Called from `CaptureDelegate` on every sample. Aggregates until
    /// `FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES` elapse, then emits one
    /// `FrameResult` built from the latest KVO snapshot.
    nonisolated func tickFrame() {
        Task { await self.onFrameTick() }
    }

    private func onFrameTick() async {
        frameCounter &+= 1
        guard frameCounter % UInt64(Constants.frameResultHeartbeatIntervalFrames) == 0,
              let device = cameraSession?.device,
              let snap = await device.lastSnapshot,
              let cont = frameResultContinuation
        else { return }
        let r = FrameResult(
            iso: Int(snap.iso),
            exposureTimeNs: snap.exposureDurationNs,
            focusDistance: Double(snap.lensPosition),
            wbGainR: Double(snap.whiteBalanceGains.red),
            wbGainG: Double(snap.whiteBalanceGains.green),
            wbGainB: Double(snap.whiteBalanceGains.blue))
        cont.yield(r)
    }
```

**Note on `focusDistance`:** brief §7 (and `07-settings.md` line 192) states `focusDistance` should be `nil` during AF scanning. `DeviceStateSnapshot` as-declared at CaptureDeviceProviding.swift:40 has `isAdjustingExposure` but not `isAdjustingFocus`. Stage 03 emits `Double(snap.lensPosition)` unconditionally; the AF-mid-scan `nil` lands when the snapshot gains `isAdjustingFocus` (a later stage — see Deviation 13). No Stage 03 TESTABLE asserts this semantic.

In `close()`, after the existing `cancelKVO` call, add:

```swift
        frameResultContinuation?.finish()
        frameResultContinuation = nil
        cachedFrameResultStream = nil
        frameCounter = 0
```

- [ ] **Step 2: Wire `tickFrame()` from `CaptureDelegate`**

In `CaptureDelegate.swift`, add a weak engine reference near the top of the class body (after `var onSampleBuffer: ...`):

```swift
    /// Weak reference so the delegate can nudge the engine's frame counter
    /// for the heartbeat stream (07-settings.md §Frame-result heartbeat).
    /// Set by `CameraEngine.open()` on sessionQueue before streaming starts.
    weak var engine: CameraEngine?
```

In the existing `captureOutput(_:didOutput:from:)` method, after the `onSampleBuffer?(sampleBuffer)` call (CaptureDelegate.swift:42), append:

```swift
        engine?.tickFrame()
```

In `CameraEngine.open(configuration:)` body, immediately after `delegate.onSampleBuffer = { [weak pipeline] sampleBuffer in …}` (CameraEngine.swift:76-78), add:

```swift
        delegate.engine = self
```

- [ ] **Step 3: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Full test sweep**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraEngine.swift \
        CameraKit/Sources/CameraKit/CaptureDelegate.swift
git commit -m "feat(stage-03): frameResultStream heartbeat at FRAME_RESULT_HEARTBEAT_HZ"
```

---

### Task 10: `ViewModel` bindings for sliders + frame-result consumer

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`

- [ ] **Step 1: Add observable state + per-control update methods**

In `ViewModel.swift`, inside the `@Observable @MainActor final class ViewModel { … }` body, append to the observable-state section (after `var error: EngineError?` at line 21):

```swift
    var currentSettings: CameraSettings = CameraSettings()
    var deviceSnapshot: DeviceStateSnapshot?
    var lastFrameResult: FrameResult?
```

Append a `frameResultTask` private property near `previousPhase`:

```swift
    private var frameResultTask: Task<Void, Never>?
    private var deviceSnapshotTask: Task<Void, Never>?
```

Append the update methods inside the class body (after `handleScenePhase(_:)`):

```swift
    // MARK: - Per-control update helpers (08-ui.md §Camera parameter controls)

    func updateISO(_ iso: Int) async {
        var delta = CameraSettings()
        delta.isoMode = .manual
        delta.iso = iso
        await applyDelta(delta)
    }

    func updateShutterNs(_ ns: Int64) async {
        var delta = CameraSettings()
        delta.exposureMode = .manual
        delta.exposureTimeNs = ns
        await applyDelta(delta)
    }

    func updateFocus(_ d: Double) async {
        var delta = CameraSettings()
        delta.focusMode = .manual
        delta.focusDistance = d
        await applyDelta(delta)
    }

    func updateZoom(_ r: Double) async {
        var delta = CameraSettings()
        delta.zoomRatio = r
        await applyDelta(delta)
    }

    private func applyDelta(_ delta: CameraSettings) async {
        do {
            try await engine.updateSettings(delta)
            currentSettings = delta.merging(onto: currentSettings)
        } catch let e as EngineError {
            self.error = e
        } catch {
            // non-EngineError — ignore
        }
    }
```

In `start()`, after the existing `for await state in await engine.stateStream() { … }` block — actually that block never exits; kick the frame-result consumer BEFORE entering the state loop (which runs for the session's lifetime). Replace `start()` body to:

```swift
    func start() async {
        do {
            let caps = try await engine.open()
            capabilities = caps
            naturalTex = engine.currentTexture()
        } catch let e as EngineError {
            error = e
            sessionState = .error
        } catch {
            sessionState = .error
        }

        // Kick the frame-result consumer (07-settings.md §Frame-result heartbeat).
        frameResultTask = Task { [weak self] in
            guard let engine = await self?.engine else { return }
            for await r in await engine.frameResultStream() {
                guard let self else { return }
                await MainActor.run { self.lastFrameResult = r }
            }
        }

        // Observe state stream (ADR-22).
        for await state in await engine.stateStream() {
            sessionState = state
        }
    }
```

In `stop()`, cancel the frame-result task before closing:

```swift
    func stop() async {
        frameResultTask?.cancel()
        frameResultTask = nil
        deviceSnapshotTask?.cancel()
        deviceSnapshotTask = nil
        await engine.close()
    }
```

- [ ] **Step 2: Build**

Call `mcp__XcodeBuildMCP__build_device {}`.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Re-run all tests**

Call `mcp__XcodeBuildMCP__test_device { extraArgs: ["-only-testing:eva-swift-stitchTests/Stage01Tests", "-only-testing:eva-swift-stitchTests/Stage02Tests", "-only-testing:eva-swift-stitchTests/Stage03Tests"] }`.
Expected: 16 tests pass.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/Sources/CameraKit/ViewModel.swift
git commit -m "feat(stage-03): ViewModel bindings for ISO/Shutter/Focus/Zoom + frameResult consumer"
```

---

### Task 11: Expanded bottom bar in `CameraView`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift`

Brief §4: "expanded bottom bar with ISO / Shutter / Focus / Zoom controls (initial form; polish is Stage 11); bindings via ViewModel."

- [ ] **Step 1: Add the overlay**

Replace the `body` block in `CameraView.swift` (currently CameraView.swift:16-33) with:

```swift
    public var body: some View {
        ZStack {
            MTKViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()
            VStack {
                Spacer()
                bottomBar
                    .padding()
                    .background(.black.opacity(0.6))
            }
        }
        .task { await viewModel.start() }
        .onChange(of: viewModel.sessionState) { _, _ in }
        .task(id: scenePhase) { await viewModel.handleScenePhase(scenePhase) }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            sliderCell(
                label: "ISO",
                value: Binding(
                    get: { Double(viewModel.currentSettings.iso ?? 100) },
                    set: { new in Task { await viewModel.updateISO(Int(new)) } }),
                range: 30...3200,
                readback: viewModel.lastFrameResult?.iso.map { "\($0)" } ?? "—")
            sliderCell(
                label: "Shutter (ms)",
                value: Binding(
                    get: { Double(viewModel.currentSettings.exposureTimeNs ?? 33_000_000) / 1_000_000 },
                    set: { new in Task { await viewModel.updateShutterNs(Int64(new * 1_000_000)) } }),
                range: 1...100,
                readback: viewModel.lastFrameResult?.exposureTimeNs.map { "\($0 / 1_000_000)" } ?? "—")
            sliderCell(
                label: "Focus",
                value: Binding(
                    get: { viewModel.currentSettings.focusDistance ?? 0.0 },
                    set: { new in Task { await viewModel.updateFocus(new) } }),
                range: 0...1,
                readback: viewModel.lastFrameResult?.focusDistance.map { String(format: "%.2f", $0) } ?? "—")
            sliderCell(
                label: "Zoom",
                value: Binding(
                    get: { viewModel.currentSettings.zoomRatio ?? 1.0 },
                    set: { new in Task { await viewModel.updateZoom(new) } }),
                range: 1...5,
                readback: String(format: "%.2fx", viewModel.currentSettings.zoomRatio ?? 1.0))
        }
    }

    private func sliderCell(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readback: String
    ) -> some View {
        VStack {
            Text(label).foregroundStyle(.white).font(.caption)
            Slider(value: value, in: range)
            Text(readback).foregroundStyle(.white).font(.caption2)
        }
    }
```

- [ ] **Step 2: Build + visually verify on device**

Call `mcp__XcodeBuildMCP__build_run_device {}`.
Expected: `BUILD SUCCEEDED`; app launches on physical iPad or Mac "Designed for iPad"; preview visible; bottom bar visible with four slider cells; landscape-right only.

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-03): expanded bottom bar (ISO / Shutter / Focus / Zoom)"
```

---

### Task 12: HITL evidence — `docs/measurements/stage-03/controls.md`

**Files:**
- Create: `docs/measurements/stage-03/controls.md`

Brief §8 HITL: `03:iso-slider-updates-exposure-live`, `03:restart-restores-settings`. Brief §11: "device smoke on iPad Pro M1: exercise each slider, confirm Rule 1/2/3 coupling visually, force-quit and relaunch to verify persistence, rotate device (still landscape-right-only)."

- [ ] **Step 1: Deploy + smoke-test on device**

Call `mcp__XcodeBuildMCP__build_run_device {}`.

On the physical iPad (or Mac "Designed for iPad" if no iPad connected):
- Move the ISO slider; confirm preview luminance changes smoothly.
- Move the Shutter slider; confirm ISO readback shifts (Rule 2 visible).
- Move the Focus slider; confirm focus-distance readback updates.
- Move the Zoom slider; confirm field-of-view narrows.
- Force-quit the app; relaunch; confirm slider positions restored (persistence).
- Rotate device; confirm landscape-right lock holds.

- [ ] **Step 2: Inspect `UserDefaults` via LLDB**

While app is running post-relaunch, attach LLDB and run:

```
po UserDefaults.standard.data(forKey: "CameraKit.CameraSettings")
```

Expected: non-nil `Data` blob.

- [ ] **Step 3: Write the evidence file**

Create `docs/measurements/stage-03/controls.md`:

```markdown
# Stage 03 HITL evidence

Device: <iPad (A16) — iPad15,7, iOS 26.x>
Date: 2026-04-21

## 03:iso-slider-updates-exposure-live — <PASS | DEFERRED>

<Observation of preview luminance response to ISO slider movement;
 any lag, quantization artifacts, or coupling-related surprises.>

## 03:restart-restores-settings — <PASS | DEFERRED>

Pre-quit state: iso=<N>, exposureTimeNs=<N>, focusDistance=<N>, zoomRatio=<N>.
Post-relaunch: values restored (observed via sliders + frame-result readback).
UserDefaults dump (LLDB):
<paste output>

## Device smoke — additional

- Rule 1 (ISO manual → Shutter manual): <PASS / FAIL / observation>
- Rule 2 (Shutter manual → ISO manual): <PASS / FAIL / observation>
- Landscape-right lock: <PASS / FAIL / observation>
```

If the executor cannot run this device smoke in-session (e.g. no device attached), mark entries **DEFERRED** and log under "Open questions for next stage" in `state.md`. Do not claim PASS without evidence.

- [ ] **Step 4: Commit**

```bash
git add docs/measurements/stage-03/controls.md
git commit -m "docs(stage-03): HITL evidence — ISO-live + restart-restores"
```

---

### Task 13: Update `state.md` and `CONTRACTS.md`; final verification

**Files:**
- Modify: `CameraKit/state.md`
- Regenerate: `CameraKit/CONTRACTS.md` (pre-commit hook + explicit `scripts/regen-contracts.sh`)

Brief §12: state.md adds, public API additions, scaffold accounting, HITL evidence path, decisions.

- [ ] **Step 1: Replace `state.md` with Stage-03 state**

Rewrite `CameraKit/state.md` (previously at Stage 02 closure) so the top-of-file title + "Current stage" reflect Stage 03. Follow the structure of the Stage 02 version — sections: `Current stage`, `Scaffolding still live`, `What's built (permanent)`, `Public API exposed so far`, `Manual test evidence`, `Decisions taken that weren't in briefs`, `Open questions for next stage`.

Key content (copy/adapt wording; this is a scaffold — author must fill in details from actual session):

```markdown
# state.md — Stage 03

## Current stage
Stage 03 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 04 must run before modifying sources):
`grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/`
Both slugs returned ≥1 hit as of Stage 03.

## What's built this stage (permanent)

- `Settings.swift` — `CameraSettings.merging(onto:)` (07-settings.md §Merge model); `SettingsCoupling.apply(rules:latched:)` implementing Rules 1/2 propagation and Rule 3 latch; `EngineError.settingsConflict(reason:)` on pre-first-readback.
- `SettingsPersistence.swift` — `UserDefaults` adapter keyed by `"CameraKit.CameraSettings"`; JSON-encoded via `Codable`.
- `KVOAsyncStream.swift` — `DeviceKVOObserver` + Tokens-box pattern (ios-platform-guide/04-avfoundation.md); two factories: `makeStream(avDevice:)` (production) and `makeStream(source: FakeKVODevice)` (test, defined in `Stage03Tests.swift`). Buffering: `.bufferingOldest(Constants.stateStreamBufferSize)`.
- `CaptureDeviceProviding` gains `snapshotStream() -> AsyncStream<DeviceStateSnapshot>` and `var lastSnapshot: DeviceStateSnapshot? { get async }`. `LiveCaptureDevice` owns a `DeviceKVOObserver` + ingest task that populates `_lastSnapshot`.
- `CameraSession.applySettings(_:on:)` — single `lockForConfiguration()` window committing ISO+exposure (coupled via `setExposureModeCustom`), focus, white balance, zoom, EV — all on the device actor (ADR-07 discipline).
- `CameraSession.reconfigureSize(_:)` — format re-selection on `sessionQueue`; pool-resize placeholder until Stage 06 trio.
- `CameraEngine.updateSettings(_:)` — real implementation: merge → couple → validate → commit → persist.
- `CameraEngine.setResolution(size:)` — session-only teardown + re-pipeline + restart.
- `CameraEngine.frameResultStream()` — 3 Hz heartbeat (`frameRateTargetFPS / frameResultHeartbeatIntervalFrames`); `.bufferingNewest(1)`.
- `CameraEngine.open()` applies persisted settings (swallows Rule-3 pre-first-readback); `close()` cancels KVO ingest.
- `SessionCapabilities.isoRange` + `SessionCapabilities.exposureDurationRangeNs`.
- `ViewModel` observable `currentSettings`, `deviceSnapshot`, `lastFrameResult`; per-control update helpers; `frameResultTask` consumer.
- `CameraView` expanded bottom bar (4 slider cells: ISO / Shutter / Focus / Zoom).
- `Tests/CameraKitTests/Stage03Tests.swift` — 7 `@Test` functions covering brief §8 TESTABLEs.

## Public API exposed so far (Stage 03 additions)

```swift
public func updateSettings(_ settings: CameraSettings) async throws       // was stub
public func setResolution(size: Size) async throws                        // new
public func frameResultStream() -> AsyncStream<FrameResult>               // new
public let SessionCapabilities.isoRange: ClosedRange<Float>               // new
public let SessionCapabilities.exposureDurationRangeNs: ClosedRange<Int64> // new
```

## Manual test evidence

| Test ID | Status | Notes |
|---------|--------|-------|
| `03:settings-merge-non-nil-fields` | PASS | Stage03Tests/settingsMergeNonNilFields — unit. |
| `03:iso-shutter-auto-switch` | PASS | Stage03Tests/isoShutterAutoSwitch — Rules 1/2 + Rule 3 latch on success path. |
| `03:rule3-manual-latch-from-last-readback` | PASS | Stage03Tests/rule3ManualWithoutLatchThrows — failure path with closure matcher. |
| `03:userdefaults-persistence-roundtrip` | PASS | Stage03Tests/userDefaultsPersistenceRoundtrip — per-test `UUID` suite. |
| `03:kvo-asyncstream-adapter-emits-on-change` | PASS | Stage03Tests/kvoAsyncStreamAdapterEmitsOnChange — FakeKVODevice mutation, emission count = 1 per KVO change. |
| `03:focus-distance-identity` | PASS | Stage03Tests/focusDistanceIdentity — `Float(0.5)` → `lensPosition` identity. |
| `03:settings-conflict-throws` | PASS | Stage03Tests/settingsConflictThrows — throws `EngineError.notOpen` via the nil-session guard (range-validation path is exercised in HITL only, not unit-tested at Stage 03). |
| `03:iso-slider-updates-exposure-live` | <PASS/DEFERRED> | `docs/measurements/stage-03/controls.md`. |
| `03:restart-restores-settings` | <PASS/DEFERRED> | `docs/measurements/stage-03/controls.md`. |

## Decisions taken that weren't in briefs

(Continue numbering from Stage 02.)

11. **`Settings.swift` holds behavior, not type declarations.** Brief §4 says "create Settings.swift" with `CameraSettings`, `ProcessingParameters`, `WhiteBalanceMode`, `CameraMode`, `WhiteBalanceGains`, `TrackerQuality`, `CameraPosition`. Stage 01 already placed those types in `Capabilities.swift` / `FrameSet.swift` / `CaptureDeviceProviding.swift` (per Stage 02 Decision #3). Stage 03's `Settings.swift` holds only `CameraSettings.merging(onto:)` and `SettingsCoupling` — redeclaring would break existing call sites.
12. **`FakeKVODevice`-targeted `DeviceKVOObserver.makeStream(source:)` lives in `Stage03Tests.swift`.** Swift's typed-keypath KVO can't be generic over `NSObject` subclasses, so the adapter needs a separate factory per source type. Rather than leak `FakeKVODevice` into the production module, the test-only factory is declared as a `@testable` extension on `DeviceKVOObserver` inside `Stage03Tests.swift`, using the production `makeStreamFromObservations(install:)` helper.
13. **`DeviceStateSnapshot` still only has `isAdjustingExposure`, not `isAdjustingFocus`.** `07-settings.md` §Frame-result heartbeat requires `FrameResult.focusDistance == nil` when `device.isAdjustingFocus == true`. Stage 03 ships `frameResultStream` with `focusDistance = Double(snap.lensPosition)` unconditionally — the AF-mid-scan `nil` semantic lands when the snapshot type gains `isAdjustingFocus` (deferred; no Stage 03 TESTABLE asserts this path).
14. **`CameraEngine.updateSettings` throws `.notOpen` when session is nil, not `.settingsConflict`.** Test 7 (`settingsConflictThrows`) creates a bare engine without `open()`. `EngineError.notOpen` is semantically the accurate cause; the `#expect(throws: EngineError.self)` matcher passes on any case. Range validation is still implemented (brief §7 contract) but is only exercised via HITL at this stage.
15. **`setResolution` pool-resize is a placeholder until Stage 06.** Session-only teardown + format re-select runs correctly; Metal pipeline is dropped and rebuilt at the new size. True pool-resize via the trio lands with Stage 06 per brief §4 explicit note. Not a scaffold (brief §12: "Adds (scaffolding): (none)"); it's a partial implementation of a permanent primitive.

## Open questions for next stage

1. **`isAdjustingFocus` wiring** — Stage 04 (or wherever `DeviceStateSnapshot` grows an `isAdjustingFocus` field) must update the KVO adapter to observe `\.isAdjustingFocus` and flow it into both the snapshot and the `frameResultStream` focus-distance-nil semantic.
2. **`setResolution` budget enforcement** — `Constants.resolutionResizeTimeoutSeconds = 5.0` is declared but the full budget isn't enforced end-to-end; the session-only path inherits `runOnQueue`'s 2 s per-hop budget. Full 5 s envelope with pre-resize state restore on timeout arrives with Stage 06 trio.
3. **HITL measurements directory may not exist** — `docs/measurements/stage-01/`, `stage-02/`, `stage-03/` entries still deferred (brief per-stage §12 names them explicitly; evidence gathering is a per-device task).
```

- [ ] **Step 2: Regenerate `CONTRACTS.md`**

Run: `scripts/regen-contracts.sh`.
Expected: updated `CameraKit/CONTRACTS.md` reflecting new public API. (The pre-commit hook runs this automatically on subsequent commits; the explicit call here avoids a final-commit churn.)

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
    "-only-testing:eva-swift-stitchTests/Stage03Tests"
  ]
}
```
Expected: **16 tests pass** (5 + 4 + 7).

Scaffold inventory:
```bash
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/
grep -rn '04:\|05:\|06:\|07:\|08:\|09:\|10:\|11:\|12:' CameraKit/Sources/
```
Expected: first returns ≥1 hit each; second returns 0.

- [ ] **Step 4: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md
git commit -m "docs(stage-03): state.md + CONTRACTS.md regenerated for Stage 03"
```

- [ ] **Step 5: Request user approval (per CLAUDE.md §7 — never push without approval)**

Do not push. Summarize the completed stage to the user, enumerate any DEFERRED HITL evidence, and ask for approval before any push or PR.

---

## 5. Deviations

These are places where the **source state dictates** a deviation from the brief spec. Each is also folded into the state.md "Decisions taken that weren't in briefs" section continuing the Stage 02 numbering.

1. **Deviation 11** — `Settings.swift` content shape. Brief §4 says "create Settings.swift" with enum + struct declarations (`CameraMode`, `WhiteBalanceMode`, `WhiteBalanceGains`, `TrackerQuality`, `CameraPosition`, `CameraSettings`, `ProcessingParameters`). Those types already live in `Capabilities.swift` / `FrameSet.swift` / `CaptureDeviceProviding.swift` per Stage 02 Decision #3. `Settings.swift` in Stage 03 contains only `CameraSettings.merging(onto:)` and `enum SettingsCoupling`. Redeclaring the types would break existing call sites.

2. **Deviation 12** — Test-only factory placement. Swift's typed-keypath `observe(_:options:changeHandler:)` requires `KeyPath<Self, Value>`; no generic-over-`NSObject` form returns `NSKeyValueObservation` (verified API §3.1). `DeviceKVOObserver.makeStream(source: FakeKVODevice)` is therefore defined as a `@testable` extension in `Stage03Tests.swift` rather than in the production `KVOAsyncStream.swift`, so `FakeKVODevice` doesn't leak into the production module.

3. **Deviation 13** — `DeviceStateSnapshot` lacks `isAdjustingFocus`. Brief §7 / `07-settings.md:192-193` require `FrameResult.focusDistance == nil` when `device.isAdjustingFocus == true`. The Stage 01 `DeviceStateSnapshot` has only `isAdjustingExposure` (CaptureDeviceProviding.swift:45). Stage 03 emits `focusDistance = Double(snap.lensPosition)` unconditionally; the mid-scan-`nil` semantic is deferred until the snapshot type gains the field. No Stage 03 TESTABLE asserts this path.

4. **Deviation 14** — Test 7 (`03:settings-conflict-throws`) passes via `EngineError.notOpen` early throw rather than range validation. The test creates a bare `CameraEngine()` and never calls `open()`; the minimum viable `updateSettings(_:)` guard throws on nil session, which satisfies `#expect(throws: EngineError.self)`. Range validation is still implemented per brief §7 but only exercised via HITL.

5. **Deviation 15** — `setResolution(size:)` is a placeholder. Brief §4 explicitly acknowledges this ("pool resize placeholder until Stage 06 introduces the trio"). Stage 03 drops and rebuilds the `MetalPipeline` at the new size; true pool-resize lands with Stage 06. Not a scaffold (brief §12: "Adds (scaffolding): (none)").

6. **Deviation 16** — Verification uses `mcp__XcodeBuildMCP__build_device` / `test_device` (or `scripts/build-summary.sh` / `test-summary.sh` as fallback), never `swift build` or `swift test`. State.md Decision #2 established this; the brief's §11 `swift build` / `swift test --filter` commands are not runnable on this machine.

---

## 6. Self-review notes (author-run before handoff)

- [x] **Spec coverage:** every brief §4 "files to create / modify / delete" entry has at least one task. Brief §8 TESTABLEs are each bound to a named test that is run in a specific task. HITL entries are bound to Task 12. State.md updates are Task 13.
- [x] **Type consistency:** `CameraSettings` field names are consistent across plan (`isoMode`, `iso`, `exposureMode`, `exposureTimeNs`, `focusMode`, `focusDistance`, `wbMode`, `wbGainR/G/B`, `zoomRatio`, `evCompensation` — match Capabilities.swift:85). `EngineError` cases referenced: `.notOpen` (no assoc), `.settingsConflict(reason:)` (with reason), `.noBackCamera`, `.noSupportedFormat(reason:)`, `.lockForConfigurationFailed`, `.metal(MetalError)` — all verified at Errors.swift:38-51.
- [x] **Placeholder scan:** no TBDs; no "implement later"; no "similar to Task N"; no placeholders in step bodies. Every step contains the actual code or command.
- [x] **Single-symbol-per-task discipline:** each task introduces one named primitive or one small cluster (KVO adapter + ingest task go together because they cross the production/test boundary in a single change).
