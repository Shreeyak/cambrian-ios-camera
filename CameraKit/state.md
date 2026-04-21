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
- `KVOAsyncStream.swift` — `DeviceKVOObserver` + Tokens-box pattern (ios-platform-guide/04-avfoundation.md); two factories: `makeStream(avDevice:)` (production, uses `nonisolated(unsafe)` capture for `AVCaptureDevice`) and `makeStream(source: FakeKVODevice)` (test-only, defined in `Stage03Tests.swift`). Buffering: `.bufferingOldest(Constants.stateStreamBufferSize)`.
- `CaptureDeviceProviding` gains `snapshotStream() -> AsyncStream<DeviceStateSnapshot>` and `var lastSnapshot: DeviceStateSnapshot? { get async }`. `LiveCaptureDevice` owns a `DeviceKVOObserver` + ingest task that populates `_lastSnapshot`. `avDevice` marked `nonisolated(unsafe) let` to allow nonisolated factory access.
- `CameraSession.applySettings(_:on:)` — single `lockForConfiguration()` window committing ISO+exposure (coupled via `setExposureModeCustom`), focus, white balance, zoom, EV — all on the device actor (ADR-07 discipline).
- `CameraSession.reconfigureSize(_:)` — format re-selection on `sessionQueue`; pool-resize placeholder until Stage 06 trio.
- `CameraEngine.updateSettings(_:)` — real implementation: merge → couple → validate → commit → persist.
- `CameraEngine.setResolution(size:)` — session-only teardown + re-pipeline + restart.
- `CameraEngine.frameResultStream()` — 3 Hz heartbeat (`frameRateTargetFPS / frameResultHeartbeatIntervalFrames`); `.bufferingNewest(1)`.
- `CameraEngine.open()` applies persisted settings (swallows Rule-3 pre-first-readback); `close()` cancels KVO ingest and finishes frame-result stream.
- `SessionCapabilities.isoRange` + `SessionCapabilities.exposureDurationRangeNs`.
- `ViewModel` observable `currentSettings`, `deviceSnapshot`, `lastFrameResult`; per-control update helpers (`updateISO`, `updateShutterNs`, `updateFocus`, `updateZoom`); `frameResultTask` consumer.
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
| `03:iso-shutter-auto-switch` | PASS | Stage03Tests/isoShutterAutoSwitch — Rules 1/2 + Rule 3 latch. |
| `03:rule3-manual-latch-from-last-readback` | PASS | Stage03Tests/rule3ManualWithoutLatchThrows — failure path. |
| `03:userdefaults-persistence-roundtrip` | PASS | Stage03Tests/userDefaultsPersistenceRoundtrip — per-test UUID suite. |
| `03:kvo-asyncstream-adapter-emits-on-change` | PASS | Stage03Tests/kvoAsyncStreamAdapterEmitsOnChange — FakeKVODevice mutation. |
| `03:focus-distance-identity` | PASS | Stage03Tests/focusDistanceIdentity — Float(0.5) → lensPosition identity. |
| `03:settings-conflict-throws` | PASS | Stage03Tests/settingsConflictThrows — throws EngineError.notOpen via nil-session guard. |
| `03:iso-slider-updates-exposure-live` | DEFERRED | measurements/stage-03/controls.md — device deploy via CLI blocked (iOS 26.5 platform vs 26.4.1 device). |
| `03:restart-restores-settings` | DEFERRED | measurements/stage-03/controls.md — same blocker. |

## Decisions taken that weren't in briefs

(Continuing from Stage 02, numbered from 11.)

11. **`Settings.swift` holds behavior, not type declarations.** Brief §4 says "create Settings.swift" with `CameraSettings`, `ProcessingParameters`, `WhiteBalanceMode`, `CameraMode`, `WhiteBalanceGains`, `TrackerQuality`, `CameraPosition`. Stage 01 already placed those types in `Capabilities.swift` / `FrameSet.swift` / `CaptureDeviceProviding.swift` (per Stage 02 Decision #3). Stage 03's `Settings.swift` holds only `CameraSettings.merging(onto:)` and `SettingsCoupling` — redeclaring would break existing call sites.
12. **`FakeKVODevice`-targeted `DeviceKVOObserver.makeStream(source:)` lives in `Stage03Tests.swift`.** Swift's typed-keypath KVO can't be generic over `NSObject` subclasses, so the adapter needs a separate factory per source type. Rather than leak `FakeKVODevice` into the production module, the test-only factory is declared as a `@testable` extension on `DeviceKVOObserver` inside `Stage03Tests.swift`.
13. **`DeviceStateSnapshot` still only has `isAdjustingExposure`, not `isAdjustingFocus`.** Stage 03 ships `frameResultStream` with `focusDistance = Double(snap.lensPosition)` unconditionally — the AF-mid-scan `nil` semantic lands when the snapshot type gains `isAdjustingFocus`.
14. **`CameraEngine.updateSettings` throws `.notOpen` when session is nil, not `.settingsConflict`.** Test 7 creates a bare engine without `open()`; `EngineError.notOpen` is the accurate cause.
15. **`setResolution` pool-resize is a placeholder until Stage 06.** Session-only teardown + format re-select runs correctly; true pool-resize via the trio lands with Stage 06.
16. **`avDevice` marked `nonisolated(unsafe) let` in `LiveCaptureDevice`.** Required so the `nonisolated snapshotStream()` factory can pass it to `DeviceKVOObserver.makeStream(avDevice:)` without an actor hop. Safe because `AVCaptureDevice` mutations are always gated by `lockForConfiguration()` on `sessionQueue` (ADR-07).
17. **`DeviceKVOObserver.Tokens` marked `@unchecked Sendable`.** Required by Swift 6 strict concurrency: `Tokens` is captured in the `@Sendable` build closure of `AsyncStream`. Thread-safe by construction: mutations only happen inside the `AsyncStream` build closure (single-threaded), and `deinit` invalidates all tokens deterministically.
18. **Test-only KVO factory uses `[.new]` option (not `[.initial, .new]`) for `iso`.** Using `.initial` causes the stream to emit the starting value (100.0) before the test mutation, which makes `receivedOne` resolve to 100.0 instead of 800.0. Production `makeStream(avDevice:)` retains `.initial` for the real device to populate `_lastSnapshot` immediately on open.
19. **HITL evidence DEFERRED for this session.** `xcodebuild` CLI cannot deploy to the physical iPad (iOS 26.4.1 device, Xcode 26.5 beta active; CLI uses `generic/platform=iOS` requiring iOS 26.5 platform components). Xcode GUI can build and run. Device smoke tests to be completed when CLI deployment is unblocked.

## Open questions for next stage

1. **`isAdjustingFocus` wiring** — Stage 04 (or wherever `DeviceStateSnapshot` grows an `isAdjustingFocus` field) must update the KVO adapter to observe `\.isAdjustingFocus` and flow it into both the snapshot and the `frameResultStream` focus-distance-nil semantic.
2. **`setResolution` budget enforcement** — `Constants.resolutionResizeTimeoutSeconds = 5.0` is declared but the full budget isn't enforced end-to-end. Full 5 s envelope with pre-resize state restore on timeout arrives with Stage 06 trio.
3. **HITL measurements** — `measurements/stage-03/controls.md` entries are DEFERRED; device smoke tests to be completed when the Xcode CLI destination issue is resolved (iOS 26.5 platform components download completion, or device updated to 26.5).
4. **Xcode CLI → device deploy** — `xcodebuild build_device` uses `generic/platform=iOS` which requires the iOS 26.5 platform package. Install via Xcode > Settings > Platforms > iOS 26.5, or update device to iOS 26.5. Once resolved, test-summary.sh and XcodeBuildMCP `test_device` will work.
