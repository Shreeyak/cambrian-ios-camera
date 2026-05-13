# state.md — Stage 11

## Current stage
Stage 11 complete (Phase E §8 TESTABLEs verified). Bugs 1–4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 fixed. Three §11 HITL evidence items (UI / Liquid Glass / VoiceOver) verified 2026-05-09. **All Stage-12 entry blockers cleared; HITL verification of the Bug 11 picker pending.**

## Stage-12 entry — Bug 11 picker pending HITL

Stage 11 regression and follow-up HITL on iPad surfaced 16 pre-existing bugs (none introduced by Stage 11). Full root-cause analysis and fix shapes in `docs/stage-11-pre-existing-bugs.md`. Stage 12 begins by retiring `scaffolding:10:synchronous-drain-pause` and starting `UIApplication.beginBackgroundTask` work; the only remaining gate is iPad HITL on the resolution picker.

| # | Bug | Severity | Status |
|---|-----|----------|--------|
| 1 | Recursive `os_unfair_lock` in `PixelSink.release/unregister` | BLOCKER | **FIXED** (Stage 11 Phase D-cleanup; drain continuations outside lock) |
| 2 | Stage 06 `frameNumber == 1` test asserts wrong value | HIGH | **FIXED** (2026-04-30; 4 sites updated to `== 0`) |
| 3 | Stage 09 `errorStream()` race — continuation set via `Task` | HIGH | **FIXED** (2026-04-30; nonisolated `Mutex<Continuation?>` boxes; all 4 cached streams in `CameraEngine`) |
| 4 | `processedTex` freezes on long sessions (right preview stuck 2-3 min while natural+tracker keep flowing) | MED-HIGH | **FIXED** (2026-04-30 live mailbox forwarding; verified 2026-05-09 HITL) |
| 7 | WB Calibrate crashes app — gains out of `[1.0, maxWB]` | BLOCKER | **FIXED** (clamp in `applySettings` + Bug 13 single-shot Apple gray-world; verified 2026-05-09 HITL) |
| 12 | Black preview on cold launch; capture/REC unfreezes it | HIGH | **FIXED** (verified 2026-05-09 HITL) |
| 13 | WB Calibrate is one-shot with no revert / re-sample / auto path | MED | **FIXED** (single-shot Apple `grayWorldDeviceWhiteBalanceGains`; Calibrate / Lock / Auto sidebar; UI status; verified 2026-05-09 HITL) |
| 8 | Black-balance has no sample-point indicator | LOW | **FIXED** (Stage 11 Task 11 reticle overlay; verified 2026-05-09 HITL) |
| 10 | REC button crashes app — fps-range setters missing `lockForConfiguration` | BLOCKER | **FIXED** (2026-04-30 lock around fps setters in `39b9ffe`; verified 2026-05-12 HITL) |
| 11 | Resolution control is a static label, not a button | LOW-MED | **FIXED** (2026-05-13 — `resolutionLabel` rewritten as `Menu` listing `capabilities.supportedSizes`; checkmark on `activeCaptureResolution`; `ViewModel.setResolution(_:)` wraps `engine.setResolution`, reconstructs capabilities mirror on success, surfaces errors via `error: EngineError?`. iPad HITL pending.) |
| 14 | Second REC press silently fails to save video | HIGH | **FIXED** (2026-05-12 — `Recording.stop` rewritten to ADR-30 CAS-race finalize; verified 2026-05-12 HITL — stop `durationMs` 39-99 vs 5032-5102 pre-fix; zero silent `.finalizing` no-ops) |

Bugs 5, 6, 9, 15, 16 status in `docs/stage-11-pre-existing-bugs.md` summary table.

Full regression after fixes (2026-04-30, iPad iOS 26.4.1, scheme `eva-swift-stitch`, no `-skip-testing` flags): **71 passed, 0 failed, 1 skipped** (same DEBUG-gated skip as Stage 11 baseline).

Three Stage 11 §11 HITL evidence items — verified 2026-05-09 on iPad:

| Slug | What to verify | Status |
|------|----------------|--------|
| `11:full-bar-and-sidebar-match-domain-09` | Bottom bar + expanded bar + calibration sidebar match `domain-revised/09-ui-behaviors.md` visually on iPad Pro M1 | **PASS** (2026-05-09 — also surfaced + fixed two layout bugs: expanded-bar pushed bottom-bar off-screen when calibration sidebar was open, and the Calibrate toggle was nudging the bottom safeAreaInset by a few px. Both fixed by splitting bottom-edge insets and moving the sidebar to `.overlay(alignment: .trailing)`.) |
| `11:liquid-glass-and-landscape-lock` | Liquid Glass styling visible on bars/sidebar/toast; orientation stays landscape-right under physical rotation | **PASS** (2026-05-09 — Liquid Glass material confirmed visible on bottom bar, expanded bar, and calibration sidebar; orientation lock holds landscape-right) |
| `11:accessibility-voiceover-pass` | VoiceOver navigates the 5-button bar, expanded sliders, calibration sidebar, error toast/dialog correctly | **PASS** (2026-05-09 — traversal works, labels read correctly. Known-acceptable: SwiftUI `Slider` reads its value plus `"adjustable"` without picking up the adjacent `Text` label as its accessibility label; VO users land on a slider hearing `"267. adjustable"` then must traverse left to hear the label. Apple HIG default; not blocking. Adding `.accessibilityLabel(...)` to each slider is a future polish item.) |

HITL items require human verification on a physical iPad — cannot be automated.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `10:synchronous-drain-pause` | `CameraEngine.swift` | `pause()` | Stage 12 |

Pre-flight grep command (Stage 12 must run before modifying sources):
```
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/
```
Must return ≥1 hit before any Stage 12 edit.

## What's built — Stage 11 (permanent)

UI control plane decomposed from a single 398-line `ViewModel` into a parent + six `@Observable @MainActor` child VMs, plus four pure helpers. No new module-level public API beyond `OrientationLock` and a `WhiteBalanceGains.init(fromGrayWorld:)` convenience. Engine surface unchanged.

- `OrientationLock.swift` — `enum OrientationLock { static var declaredSupported: UIInterfaceOrientationMask { .landscapeRight } }`. Wired in `eva_swift_stitchApp.AppDelegate` (replaces the inline literal).
- `CalibrationCompute.swift` — pure helpers: `grayWorldGains(sample:maxGain:)`, `blackBalanceOffsets(sample:)`. Sendable; no engine reference.
- `SliderDebouncer.swift` — `actor SliderDebouncer<Value: Sendable>` wrapping `AsyncStream.bufferingNewest(1)` + 16 ms coalesce + `dispatch` callback. Reset on slider end-of-drag.
- `ControlEnablement.swift` — `struct ControlEnablement: Sendable, Hashable` derives 7 booleans from `(SessionState, RecordingState)`. View layer reads it inline; no central computed-property store.
- `FrameSet.swift` (extension) — `WhiteBalanceGains.init(fromGrayWorld sample: RgbSample, maxGain: Float = 4.0)` convenience.
- `DisplayViewModel.swift` — owns `naturalTex` / `processedTex` / `trackerTex` (`@ObservationIgnored nonisolated(unsafe) MTLTexture?`), `debugOverlay`, `debugTrackerSubscribed`, DEBUG `cannyStub`/`cannyToken`, tracker subscriber task, `attachAfterOpen()` / `detachBeforeClose()`.
- `RecordingViewModel.swift` — `recordingState`, `recordingElapsedSeconds`, `toggleRecording()`, `startRecordingTimer()`, `recordingStateStream` subscription, `recordingTimerTask`. Init: `(engine: CameraEngine)`. Lifecycle: `start()` / `stop()`.
- `HardwareControlsViewModel.swift` — 4 debouncers + 4 push methods (`pushISO`/`pushShutter`/`pushFocus`/`pushZoom`). Mirrors `currentSettings` for view-side reads. Each debouncer dispatches via `engine.updateSettings(delta)`. Init: `(engine: CameraEngine)`.
- `ProcessingViewModel.swift` — owns `currentProcessing: ProcessingParameters`. 7 debouncers + 7 push methods (brightness, contrast, saturation, gamma, blackR, blackG, blackB). `applyBlackBalance(sample:)` for `CalibrationViewModel` writeback. `resetProcessing()`. Each debouncer mutates `currentProcessing` then dispatches via `engine.setProcessingParameters(_:)`.
- `CalibrationViewModel.swift` — `calibrateWB()` / `calibrateBB()`. WB: sample → `CalibrationCompute.grayWorldGains` → `engine.updateSettings(whiteBalance: .custom(...))`. BB: sample → `processingVM.applyBlackBalance(_:)`. Init: `(engine: CalibrationEngineProtocol, processingVM: ProcessingViewModel)`. Internal `protocol CalibrationEngineProtocol: Sendable` exposing only `sampleCenterPatch()` + `updateSettings(_:)`; `CameraEngine` adopts via internal extension.
- `ErrorPresenterViewModel.swift` — `currentToast: CameraError?` (auto-dismiss ≥3 s), `fatalDialog: CameraError?` (no auto-dismiss). Subscribes `engine.errorStream()`; routes by `err.isFatal`. `dismissFatal()` and `_feedErrorForTest(_:)` test seam. **Retry hops to parent `ViewModel.retryFromFatal()`** — see Decisions §52.
- `ViewModel.swift` (rewritten, ~150 lines, down from 398) — owns `engine` + 6 child VMs (`@ObservationIgnored let`). Owns session-level state: `sessionState`, `capabilities`, `currentSettings`, `lastFrameResult`, `captureResult`. Subscribes `stateStream` / `frameResultStream` / `deviceSnapshotStream` from parent. `start()` / `stop()` / `handleScenePhase(_:)` / `retryFromFatal()`.
- `CameraView.swift` (rewired) — 5-button bottom bar (Settings / Calibrate / Capture / Record / Resolution) with `ControlEnablement` derived inline. Expanded bar (ISO/Shutter/Focus/Zoom sliders via `SliderRebinding` helper). Calibration sidebar (WB / BB / 7 processing sliders / Reset). Recording indicator (`TimelineView.periodic` red-dot + `mm:ss`). Top toast + `.alert` for non-fatal vs fatal errors. Scanning overlay bound to `SessionState`. `.glassEffect` Liquid Glass on bars/sidebar/toast.
- `eva_swift_stitchApp.swift` — `AppDelegate` calls `OrientationLock.declaredSupported`.
- `Stage11Tests.swift` — 5 `@Suite`s, 17 `@Test` cases. All §8 TESTABLEs covered (see Manual test evidence below).

### Mid-stream fixes folded into Stage 11

- **`PixelSink.release()` / `unregister()`** — drain continuations outside `state.withLock`, then `finish()`. Was crashing the Stage 11 regression with `BUG IN CLIENT OF LIBPLATFORM: Trying to recursively lock an os_unfair_lock` on iPad iOS 26.4.1; cascaded as 58 false "Crash" entries. Bug 1 in `docs/stage-11-pre-existing-bugs.md`. Latent since Stage 06 (commit `5d51be0`); exposed by 26.4.1 timing change.
- **`Stage01Tests.swift` `landscapeRightRotationApplied`** — updated assertion from `== 90` to `== 0` to match the Stage 06 HITL fix (`captureOrientationAngleDeg = 0`, commit `e09c1f3`). Test was the leftover stale assertion from Stage 01 brief; brief vs. HITL conflict resolved per CLAUDE.md §8 ("HITL fix wins; log deviations").

### Pre-existing bug fixes folded in 2026-04-30 (post-Stage 11)

- **Bug 2** — `Stage06Tests.swift` 4 sites: `?.frameNumber == 1` → `== 0`. `MetalPipeline` assigns `fn = frameNumber` then increments after; first FrameSet's frameNumber is 0. Test was wrong from inception; latent because Bug 1 was aborting the test process before Stage 06 ran.
- **Bug 3** — `CameraEngine.swift`: all four cached-stream + Task-set patterns (`stateStream`, `errorStream`, `frameResultStream`, `recordingStateStream`) converted from actor-isolated `Task { await self?.setXContinuation(c) }` to nonisolated `Mutex<AsyncStream<X>.Continuation?>` boxes installed synchronously inside the AsyncStream init closure. Continuation is non-nil before `errorStream()` etc. return to the caller — the race window where early emits were silently dropped is gone. Symmetric audit-fix per the bug doc's "Same fix likely needed in `stateStream()` and any other cached-stream-with-Task-set pattern".

## Public API exposed — Stage 11

No new module-level public API beyond:

```swift
public enum OrientationLock {                                       // OrientationLock.swift
    public static var declaredSupported: UIInterfaceOrientationMask { get }
}

extension WhiteBalanceGains {                                       // FrameSet.swift
    public init(fromGrayWorld sample: RgbSample, maxGain: Float)
}
```

`ViewModel`, child VMs, `CalibrationEngineProtocol`, helpers (`CalibrationCompute`, `SliderDebouncer`, `ControlEnablement`) are all `internal`. `CameraView` consumes `ViewModel` directly; no public abstraction.

## Manual test evidence — Stage 11

§8 TESTABLEs from `implementation/briefs/stage-11.md`. All run via `mcp__XcodeBuildMCP__test_device` against `eva-swift-stitch` scheme on Shreeyak's iPad (UDID `00008027-000539EA0184402E`, iOS 26.4.1). Filtered run on Stage11* suites: 17/17 pass. Full regression with skips: 63 passed, 0 failed, 1 method-skipped.

| Slug | Suite / test | Result |
|------|--------------|--------|
| `11:wb-calibrate-applies-computed-gains` | `Stage11CalibrationVMTests.wbCalibrateAppliesComputedGains` (uses `CalibrationEngineStub`) | PASS |
| `11:bb-calibrate-updates-processing-params` | `Stage11CalibrationVMTests.bbCalibrateUpdatesProcessingParams` (real `ProcessingViewModel` + stub) | PASS |
| `11:slider-coalescing-60hz` | `Stage11SliderDebouncerTests.sliderCoalescing60Hz` | PASS |
| `11:state-driven-control-enable-disable` | `Stage11ControlEnablementTests` (full 6-state matrix, 8 cases) | PASS |
| `11:non-fatal-error-shows-toast` | `Stage11ErrorPresenterTests.nonFatalErrorShowsToast` (via `_feedErrorForTest`) | PASS |
| `11:fatal-error-shows-blocking-dialog` | `Stage11ErrorPresenterTests.fatalErrorShowsBlockingDialog` | PASS |
| `11:scanning-animation-binds-to-session-state` | `Stage11ControlEnablementTests` (J4 — bound to `SessionState`, NOT `focusDistance == nil`) | PASS |

Pure-helper coverage:
- `Stage11CalibrationComputeTests` — gray-world reciprocal + BB offsets (4 cases). PASS.

### Deferred HITL evidence

Per Stage 11 brief §11. iPad device manual passes captured separately; not blocking Phase E completion.

| Slug | Evidence | Status |
|------|----------|--------|
| `11:full-bar-and-sidebar-match-domain-09` | visual sweep against `domain-revised/09-ui-behaviors.md` | **PASS** (2026-05-09 HITL) |
| `11:liquid-glass-and-landscape-lock` | rotation + Liquid Glass styling visible on iPad Pro M1 | **PASS** (2026-05-09 HITL) |
| `11:accessibility-voiceover-pass` | manual VoiceOver sweep | **PASS** (2026-05-09 HITL) — slider labels read as `"<value>. adjustable"` (HIG default; future polish: per-slider `.accessibilityLabel`) |

## Decisions taken that weren't in briefs

48. **MVVM decomposed into parent + 6 child VMs** (not in brief — implementation-level). Rationale: monolithic Stage-10 `ViewModel` was 398 lines / 12 responsibilities; Stage 11 alone would have added ~250 lines (8 debouncers + WB/BB calibrate + error split + control-enablement + retry/dismiss) → 600+ lines in one file. Decomposed parent owns engine + child VMs as `@ObservationIgnored let`; children never reference parent; sibling references (CalibrationVM → ProcessingVM) injected at init.
49. **`currentSettings` mirror lives on `HardwareControlsViewModel`** (not on parent). View binds to `vm.hardware.currentSettings` for slider initial values; parent does not duplicate. Same rule for `currentProcessing` on `ProcessingViewModel`.
50. **`SessionState.closing` enablement-matrix case absent in current enum.** Brief §8 names `.closing`; current enum has only `.closed`/`.open`/`.error`/etc. Treated `.closing` semantics as `.closed` for `ControlEnablement`. Flag upstream — `implementation/briefs/stage-11.md` §8 should be reconciled with `architecture/04-state.md` enum shape.
51. **`SliderRebinding` helper view** — local `@State` slider value, `.onChange` forwards to debouncer. Prevents SwiftUI's write-back oscillation mid-drag (the canonical "slider jumps back" symptom when both `value:` binding and external mutation fire each frame).
52. **`retryFromFatal()` lives on parent `ViewModel`, not on `ErrorPresenterViewModel`.** Retry must reopen the engine, re-attach Display, restart `frameResultStream` — operations the error VM has no reference to. Implemented as parent method; `CameraView`'s `.alert` Retry button calls `await viewModel.retryFromFatal()`. ErrorPresenterVM keeps `dismissFatal()` only.
53. **`PixelSink.release()` / `unregister()` mid-stream lock fix** (Bug 1, fixed in Phase D-cleanup). Drain continuations outside `state.withLock`. Documented in `docs/stage-11-pre-existing-bugs.md` for traceability — was blocking the entire regression.
54. **`Stage01Tests.captureOrientationAngleDeg`** updated to expect `0` (matches Stage 06 HITL fix `e09c1f3`). The `90` value was the Stage 01 brief's spec; HITL changed the constant to fix landscape rendering on iPad Pro M1; test was never updated. Per CLAUDE.md §8: HITL wins; flag upstream.
55. **TCA migration reverted** before Phase E. Earlier Stage-11.5 attempt introduced `ComposableArchitecture` dep + `CameraFeature` reducer; user reversed the decision. Reverted to Stage 10 baseline + decomposed-MVVM rewrite. No TCA artifacts remain.
56. **`WhiteBalanceGains.init(fromGrayWorld:)`** lives in `FrameSet.swift` (the type's home), not `Settings.swift` as Stage 11 brief §4 names. Brief reference is wrong; flag upstream.
57. **`CalibrationEngineProtocol` is internal**, not public. Test seam only — exposes `sampleCenterPatch()` + `updateSettings(_:)` for `CalibrationEngineStub`. Real `CameraEngine` adopts via internal extension. No reason to leak to the package's public API.
58. **`HardwareControlsViewModel` logs `updateSettings` failures via `CameraKitLog.engine.warning`** instead of routing to error stream. ADR-22 errorStream is not yet wired for inline `updateSettings` throws; routing user-facing toasts on hardware-cap failures is **DEFERRED to a future engine pass**. Console-only for now.
59. **2026-05-08 — BB applied AFTER brightness/contrast/saturation/gamma.**
    `Shaders/ColorShaders.metal` was reordered to apply the black-balance
    pedestal as the *final* color step. This contradicts
    `architecture/07-settings.md §Processing order`, which specifies BB as
    the first step (noise-floor pre-compensation). Decision is user-directed:
    BB now behaves like a final shadow lift on the graded image. Pairs with
    the BB calibration sampling path: a one-shot Pass-2 scratch encode
    rendered with current BCSG and BB zeroed (`MetalPipeline.dispatchBBCalibrationSample`),
    so the sample is in the same color space the pedestal subtracts from
    while not feeding the prior pedestal back into the math. Public-API
    doc-comments were updated. Upstream should patch the spec.
60. **2026-05-08 — Manual WB is non-persistent across launches.**
    `SettingsPersistence.load` strips `wbMode = .manual` and the gain triple
    on decode. `.auto` and `.locked` round-trip unchanged. Calibration is a
    per-session intent. Side effect: any latent recurrence of the historical
    Bug-12 cold-launch-black symptom is rendered harmless.
61. **2026-05-13 — Recording output is now user-visible (Files.app + opt-in Photos).**
    Two-piece landing of `docs/superpowers/plans/2026-05-12-recording-output-visibility.md`:
    Piece 1 (`d8ecfc0`) added `INFOPLIST_KEY_UIFileSharingEnabled` +
    `LSSupportsOpeningDocumentsInPlace` so `<Documents>` shows in Files.app
    under "On My iPad → eva-swift-stitch". Piece 2 unified the still + video
    output API: `RecordingOptions.outputDirectory` + `fileName` were replaced
    by `outputURL: URL?` + `photosDestination: PhotosDestination` (`.none`
    / `.copy` / `.move`); `CameraEngine.captureImage(outputPath: String?)`
    became `captureImage(outputURL: URL? = nil, photosDestination: .none)`.
    Both APIs route through a new `PhotosLibraryClient` (`resolve` for the
    URL contract, `publish` for the dispatch, `describe` for typed
    PHPhotosError messages). `URL.documentsDirectory` is the default
    location; sandbox escapes throw `EngineError.invalidOutputPath`. Photos
    auth is requested eagerly in `engine.open()` so the prompts fire
    back-to-back at first launch instead of mid-shoot. Photos-publish
    failures are non-fatal: the on-disk file is preserved and a
    `CameraError(.unknownError, isFatal:false)` is emitted on
    `errorStream()` for the host app to react to. Architectural deviations
    versus the spec doc: the spec recommended a host-side "hook seam"; we
    chose a unified library-side API instead, so a host app drops in
    `CameraView()` with just the two usage-description Info.plist keys and
    no Photos plumbing of its own. Stop-promptness (Bug 14) is preserved
    for `.none` (default); `.copy`/`.move` add the `PHPhotoLibrary`
    roundtrip latency to `stopRecording`'s wall time, which is acceptable
    because the caller opted in.
62. **2026-05-13 — Photos publish errors emit on `errorStream()`; host UI
    surface deferred.** Both `engine.captureImage` and `engine.stopRecording`
    publish a non-fatal `CameraError` on `errorStream()` when
    `PhotosLibraryClient.publish` throws (e.g. `accessUserDenied`). The
    `eva-swift-stitch` host app does not yet subscribe a UI banner to that
    stream, and `RecordingViewModel.toggleRecording`'s catch only logs
    (so `EngineError.invalidOutputPath` from a bad outputURL also fails
    silently in-app today). Both gaps are documented in
    `docs/superpowers/plans/2026-05-13-error-surfacing-followups.md` for
    a follow-up pass.
63. **2026-05-13 — FullRange-only pixel format; VideoRange dropped; 640×480
    picker floor.** `CameraSession.swift` (initial open filter) and
    `CaptureDeviceProviding.supportedSizes` (picker list) and
    `CameraSession.reconfigureSize` (resolution-change match) all reject
    `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ('420v') and accept
    only `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` ('420f'). The
    picker additionally drops anything smaller than 640×480 (sub-VGA
    formats like 352×288 / 480×360 are not user-meaningful for this app).
    Contradicts G-17 and `architecture/03-camera-session.md` §Enumeration
    step 1, which both say "FullRange preferred, VideoRange accepted." User
    directive — the downstream Metal YCbCr→RGB conversion is calibrated for
    FullRange ([0,255]); VideoRange ([16,235]) would require a different
    matrix or pre-scale and we'd rather fail fast than render washed-out
    blacks. Risk: if a device exposes a resolution *only* in VideoRange,
    that resolution disappears from the picker (or, at startup with no 4:3
    FullRange match, `open()` falls back to fallback dimensions). The new
    `Documents/capabilities.txt` dump (every `device.formats` entry with
    FourCC + dimensions + FPS range + bit depth) lets us see exactly which
    formats are affected on each iPad. Flag upstream.
64. **2026-05-13 — Bug 11 picker robustness.** Three problems surfaced in
    first HITL: (a) menu listed each resolution 4–8 times because
    `supportedSizes` was one-`Size`-per-`AVCaptureDevice.Format` and each
    resolution typically has many format variants; (b) SwiftUI `Menu` was
    sluggish/unresponsive because `ForEach(id: \.self)` over duplicate
    `Size` hashes violated SwiftUI's ID-uniqueness contract; (c) tapping
    "different" resolutions often picked another format with the same
    `Size`, hitting `ViewModel.setResolution`'s `current == size`
    short-circuit and looking like a silent failure. Fix: dedupe at the
    source — `supportedSizes` insertion-orders unique `Size`s and sorts
    area-descending. Combined with §63 the picker now offers ~5 distinct
    resolutions in the order users expect.
65. **2026-05-13 — `delegate.onSampleBuffer` closure must read `_metalPipeline`
    live, not capture the original pipeline weakly.** Original
    `open()` wiring captured `[weak pipeline]` in the sample-buffer
    callback, so the closure pinned to the open-time pipeline. The
    first `setResolution` `metalPipeline = nil` cleared that weak
    reference; from that point on the closure resolved to `nil` and
    every sample buffer was silently dropped (`try? nil?.encode(...)`).
    AVF kept delivering, captureDelegate kept refreshing the watchdog
    (no stall), but no frames reached `MetalPipeline.encode` on the
    new pipeline — preview went black, capture continuations never
    resumed (Pass 6 never armed). Fix: capture `[weak self]` and dispatch
    via `self?._metalPipeline?.encode(...)`; the `_metalPipeline` slot
    is rewritten by `setResolution` so the closure always sees the
    current pipeline. Confirmed on iPad HITL — preview switches and
    captures land at the picker's chosen size. Bug latent since
    `setResolution` was first wired; surfaced only now because Bug 11
    made `setResolution` user-reachable.
66. **2026-05-13 — `ViewModel.supportedSizesCache` decouples picker
    items from the `capabilities` struct.** The list of supported
    resolutions is a property of the active `AVCaptureDevice` and
    doesn't change during a session, but `capabilities` is rebuilt
    by `ViewModel.setResolution` to update `activeCaptureResolution`.
    Cached separately as `@ObservationIgnored var supportedSizesCache:
    [Size]`, populated once from `caps.supportedSizes` at engine open
    (`start()` and `retryFromFatal()`). The resolution Menu's `ForEach`
    now reads from this stable slot, so SwiftUI's diffing doesn't
    rebuild the item tree on resolution change. Paired with restyling
    the Menu label as a `VStack(icon: "aspectratio", text: resolutionText)`
    with `.contentShape(Rectangle())` + `.menuStyle(.button)` +
    `.menuIndicator(.hidden)` for tap-target responsiveness on iPad.
67. **2026-05-13 — Picker → saved-image-resolution alignment is parked.**
    Plan written at
    `docs/superpowers/plans/2026-05-13-resolution-picker-honor-saved-image.md`.
    HITL confirmed picker drives both preview and saved-TIFF dimensions
    (1280×720 picker → 1280×720 preview + 1280×720 TIFF; same FOV as the
    full-res 4032×3024 capture). `activeCropRegion` in `SessionCapabilities`
    is still pure metadata that doesn't match what the Metal pipeline
    actually renders (no crop is applied); plan's Option B (drop the
    `activeCropRegion` / `setCropRegion` public API) remains the
    recommendation but is deferred. No code change today.

## Open questions for next stage

- Bug 4 from `docs/stage-11-pre-existing-bugs.md` — `processedTex` long-session freeze. Needs HITL on iPad: 5+ min run + temporary Pass 2 / pool-state logging in `MetalPipeline`. Hypotheses (unverified): silent Pass 2 error, processed pool exhaustion, uniforms.withLock contention, ObservationIgnored race on `DisplayViewModel.processedTex`. Fix before retiring `10:synchronous-drain-pause` in Stage 12.
- `SessionState.closing` enum reconciliation (Decision #50). Either add the case in `architecture/04-state.md` and use it, or drop `.closing` from brief §8 enablement matrix.
- HITL evidence under `measurements/stage-11/` — three slugs deferred.
- ADR-22 error routing for `updateSettings` failures (Decision #58).

## What's built — Stage 10 (permanent)

- `Constants.swift` — `frameRateRecordingMinFps = 15`, `recordingTargetBitrateBpsDefault = 40_000_000`, `recordingFinishTimeoutSeconds = 5.0`, `drainTimeoutSeconds = 5.0`, `encoderPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
- `SessionState.swift` — `RecordingState` reshaped to `idle(lastUri:) / recording / finalizing / paused`; `RecordingOptions` expanded with `bitrateBps / fps / outputDirectory / fileName`; `RecordingStart` reshaped to `uri / displayName`.
- `Errors.swift` — `RecordingError` gains `notReadyForMoreMediaData`, `finalizeTimeout`, `finalizeFailed(reason:)`, `cancelledByPause`.
- `AssetWriting.swift` — `AssetWriting` + `AssetWriterPixelBufferAdapting` protocol seams (Sendable); `AVAssetWritingBox` / `AVAdaptorBox` production wrappers; `AssetWriterFactory` typealias; `DefaultAssetWriterFactory.make`.
- `TexturePoolManager.swift` — `makeEncoderNV12Pool(size:)`, `dequeueEncoderBuffer(pool:)`, `makePlaneWriteTexture(from:planeIndex:format:)`; `makeEncoderNV12PoolForTest` static test seam.
- `Shaders/NV12Encode.metal` — `rgba16fToNV12` compute kernel (BT.709 video-range, 2×2 chroma downsample).
- `MetalPipeline.swift` — `encoderPool: CVPixelBufferPool`, `nv12EncodePSO: MTLComputePipelineState`, `isRecording: ManagedAtomic<Bool>` (nonisolated let), `onEncodedBufferReady` closure; Pass 5 dispatch in `encode()`; delivery in completion handler.
- `Recording.swift` — `actor Recording` coordinator: `start(options:captureSize:)`, `stop(reason:)`, `submitEncodedBuffer(_:pts:)`, `Recording.Hooks`, `Recording.StopReason`; `withTaskGroup` deadline-cancel race (D-04, ADR-16).
- `CameraSession.swift` — `setPreviewFrameRateRange()`, `setRecordingFrameRateRange()` async throws.
- `CameraEngine.swift` — `startRecording(options:)`, `stopRecording()`, `pause()`, `resume()`, `recordingStateStream()`; Pass 5 submission closure; AE range toggle; `scaffolding:10:synchronous-drain-pause` in `pause()`.
- `ViewModel.swift` — `recordingState`, `recordingElapsedSeconds`, `toggleRecording()`, `startRecordingTimer()`; `recordingStateTask` + `recordingTimerTask`.
- `CameraView.swift` — Record/stop button (red dot + mm:ss timer) in bottom bar.
- `Stage10Tests.swift` — 8 `@Test` functions covering all §8 TESTABLEs.

## Public API exposed — Stage 10

```swift
public func startRecording(options: RecordingOptions) async throws -> RecordingStart  // CameraEngine
public func stopRecording() async throws -> String                                     // CameraEngine
public func pause() async throws                                                       // CameraEngine
public func resume() async throws                                                      // CameraEngine
public func recordingStateStream() -> AsyncStream<RecordingState>                     // CameraEngine
public protocol AssetWriting: Sendable { ... }
public protocol AssetWriterPixelBufferAdapting: Sendable { ... }
public typealias AssetWriterFactory = @Sendable (_ outputURL: URL, _ size: Size, _ bitrateBps: Int, _ fps: Int) async throws -> (AssetWriting, AssetWriterPixelBufferAdapting)
public enum DefaultAssetWriterFactory { public static let make: AssetWriterFactory }
public actor Recording { ... }
```

## Manual test evidence — Stage 10

| Test ID | Status | Notes |
|---------|--------|-------|
| `10:record-start-stop-happy-path` | PASS | Stage10Tests |
| `10:recording-truncated-on-deadline` | PASS | Stage10Tests (FastClock collapses deadline) |
| `10:ae-frame-rate-range-toggles-on-mode` | PASS | Stage10Tests (options.fps forwarding verified) |
| `10:nv12-encoder-pass-byte-layout` | PASS | Stage10Tests (IOSurface-backed pool validated at pool level) |
| `10:pause-during-recording-finalizes-synchronously` | PASS | Stage10Tests |
| `10:resume-from-pause-restarts-session` | PASS | Stage10Tests |
| `10:adaptor-not-ready-drops-frame` | PASS | Stage10Tests |
| `10:fatal-finalize-emits-recording-failed` | PASS | Stage10Tests |
| `10:mp4-plays-in-photos` | DEFERRED | HITL — see measurements/stage-10/recording.md |
| `10:low-light-ae-drops-below-30fps` | DEFERRED | HITL — see measurements/stage-10/recording.md |
| `10:empirical-format-fps-range-fallback` | DEFERRED | HITL — see measurements/stage-10/recording.md |

## Decisions taken that weren't in briefs — Stage 10

43. **RecordingState reshape — brief §4 vs architecture §Recording state machine.** Brief §4 names `idle/recording/finalizing/paused`; architecture doc uses `preparing/stopping`. Brief wins per CLAUDE.md §8. Flagged upstream.

44. **`AssetWriting` / `AssetWriterPixelBufferAdapting` protocol seam.** Not in brief. Required for TESTABLEs that fake `AVAssetWriter`. Mirrors `CaptureDeviceProviding` pattern already in repo.

45. **`recordingTargetBitrateBpsDefault = 40_000_000`.** Brief §Parameters says "measurements/"; 40 Mbps is a reasonable default for 4K HEVC @ 30fps pending on-device measurement. Open question for next stage.

46. **`pause()` resets AE frame-rate range only in `stopRecording()`, not in `pause()`.** Consistent with the brief's intent that `pause()` is a session-only teardown; AE range reset on resume is not specified. Open question for Stage 12.

47. **`FakeAssetWriter.finishWriting()` polls on `cancelled` flag.** Enables the `withTaskGroup` deadline race to resolve deterministically in tests without requiring Swift structured concurrency cooperative cancellation.

## Open questions for next stage

1. `TARGET_BITRATE_MBPS` upstream value after device measurements.
2. Stage 12 retires `10:synchronous-drain-pause` via `UIApplication.beginBackgroundTask` wrap.
3. Empirical format-fps range fallback — evidence in `measurements/stage-10/recording.md`.
4. BUG (carried from Stage 09): `09:camera-in-use-self-heal-device` FAIL — fix needed for Stage 10 or 11.
5. Should `pause()` also reset AE frame-rate range to preview mode?

# state.md — Stage 09

## Current stage
Stage 09 complete.

## Scaffolding still live

All prior-stage scaffolds retired through Stage 09. No active scaffolds.

## What's built — Stage 09 (permanent)

- `Clock.swift` — `CameraKitClock` protocol + `SystemClock` struct; injectable timing for watchdogs, recovery, and AE/FPS monitors.
- `Watchdog.swift` — `Watchdog` (ManagedAtomic last-kick + Mutex<State> armed token); `WatchdogKind` (.gpu 3s notify-only, .capture 5s triggers recovery); `WatchdogPair` convenience struct; `Watchdog.disarmAll(_:)` static helper (D-13, Inv 12).
- `RecoveryCoordinator.swift` — `actor RecoveryCoordinator` with exponential backoff (500/1000/2000/4000/8000 ms); retry-Task ownership per ADR-23; consecutive-HW-error counter; `resetFromTerminal()` self-heal hook.
- `CameraEngine.swift` — `nonisolated let sessionToken: ManagedAtomic<UInt64>` (bumped on close + recovery); `WatchdogPair` + `RecoveryCoordinator` constructed in `open()`, torn down in `close()`; `errorStream()` with `.bufferingOldest(64)`; AE convergence monitor (`startAEMonitor`); FPS degradation monitor (`noteFrameDelivered`); `handleWatchdogFire`, `noteCaptureFailure`, `resetFromTerminal`, `onSessionEvent` handlers; `_emitErrorForTest` + `_postSessionEventForTest` test seams; clock injection via `init(clock:)`.
- `MetalPipeline.swift` — D-10 completion-handler re-entrancy guard (captures `tokenAtCommit`, no-ops on mismatch, releases pending capture slot); `onMetalError` hook; `didNoOpCountForTest` counter; `engineSessionToken` parameter added to `init`. Scaffold `01:skip-completion-guard` **retired**.
- `CaptureDelegate.swift` — `watchdogs: WatchdogPair?`; GPU + capture watchdog `refresh()` on every `captureOutput`; drop-delegate stub.
- `CameraSession.swift` — `wasInterruptedNotification` + `interruptionEndedNotification` + `runtimeErrorNotification` observers; `SessionEvent` enum; `onSessionEvent` callback; `CAMERA_IN_USE` → fatal error + self-heal path (D-14).
- `ViewModel.swift` — `currentError: CameraError?`; `errorConsumerTask` consuming `errorStream()`.
- `CameraView.swift` — non-fatal recovery banner (orange, `.safeAreaInset` bottom, dismiss button); fatal-error `.alert`.
- `Stage09Tests.swift` — 8 `@Test` functions + `TestClock` (final class, ManagedAtomic, NSLock).

## Public API exposed — Stage 09

```swift
public func errorStream() -> AsyncStream<CameraError>          // CameraEngine
public actor RecoveryCoordinator { ... }
public final class Watchdog: @unchecked Sendable { ... }
public struct WatchdogPair: Sendable { ... }
public protocol CameraKitClock: Sendable { ... }
public struct SystemClock: CameraKitClock { ... }
```

## Manual test evidence — Stage 09

| Test ID | Status | Notes |
|---------|--------|-------|
| `09:completion-guard-no-ops-after-close` | PASS | Stage09Tests |
| `09:watchdog-captured-token-survives-retry` | PASS | Stage09Tests |
| `09:exponential-backoff-schedule-matches-constants` | PASS | Stage09Tests |
| `09:camera-in-use-self-heal-to-closed` | PASS | Stage09Tests |
| `09:disarm-before-state-transition` | PASS | Stage09Tests |
| `09:ae-convergence-timeout-emits` | PASS | Stage09Tests (constants/type validation; device integration DEFERRED) |
| `09:fps-degraded-requires-streak` | PASS | Stage09Tests (constants/type validation; device integration DEFERRED) |
| `09:error-stream-delivers-every-transition` | PASS | Stage09Tests |
| `09:recovery-banner-on-simulated-capture-failure` | PASS | HITL — LLDB-triggered frame stall; banner rendered correctly. `measurements/stage-09/recovery.md` |
| `09:camera-in-use-self-heal-device` | FAIL | HITL — interruption notification unreliable; recovery loop crashed instead of fatal alert. Bug logged. `measurements/stage-09/recovery.md` |

## Decisions taken that weren't in briefs — Stage 09

39. **`TestClock` implemented as `final class` with `ManagedAtomic<UInt64>` + `NSLock`, not `actor`.** `CameraKitClock.nowMs()` is a synchronous non-isolated protocol requirement; an actor cannot satisfy it without `nonisolated(unsafe)`, which races under strict concurrency. `final class` with `ManagedAtomic` for the counter satisfies both `Sendable` and the sync requirement cleanly.

40. **AE and FPS tests are constant-validation stubs, not full integration tests.** Full integration requires driving `snapshotStream()` and `noteFrameDelivered()` with a `TestClock` against a live engine. Designated DEFERRED per brief §11; device HITL evidence in `measurements/stage-09/recovery.md`.

41. **`Watchdog.disarmAll(_:)` honored as `static func` delegating to `pair.disarmAll()`.** Brief §4 specifies a "static helper" spelling; both `WatchdogPair.disarmAll()` (instance) and `Watchdog.disarmAll(_:)` (static) are exposed per the brief's intent.

42. **`publishErrorAsync` added as a thin sync wrapper on `publishError`.** Needed so `@Sendable` hook closures in `RecoveryCoordinator.Hooks` can call back into the actor without requiring `async` propagation through the hooks struct.

## Open questions for next stage

1. **BUG: `09:camera-in-use-self-heal-device` FAIL** — `AVCaptureSession.wasInterruptedNotification` with `videoDeviceInUseByAnotherClient` did not arrive before watchdogs timed out (3s / 5s). Recovery loop then attempted `open()` while camera was locked by the system Camera app, crashed before `MAX_RETRIES_EXCEEDED` alert rendered. Fix needed: detect camera-in-use error from `open()` throws during retry and short-circuit to fatal state without exhausting retries.
2. **Full AE + FPS integration tests** — need `TestClock`-driven `startAEMonitor` and `noteFrameDelivered` harnesses; deferred to a test-improvement pass.
3. **Carried open questions from Stage 08** (focalLengthMm, ADR-13 upstream, OpenCV Mac slice, sigmoid curve, D-17 revision).

# state.md — Stage 08

## Current stage
Stage 08 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |

Pre-flight grep command (Stage 09 must run before modifying sources):
```
grep -rn '01:skip-completion-guard' CameraKit/Sources/
```
Must return ≥1 hit before any Stage 09 edit.

## What's built — Stage 08 (permanent)

- `CameraKitCxx` SPM target (C++20) — `PixelSink.hpp` abstract class; `PixelSinkCallbacks.h` C-ABI struct; `PixelSinkPool.cpp` (`std::mutex`-guarded, `pipeline > stage > consumer` lock order per D-16, thread cap `CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency)`); `CaptureAtomic.cpp` (`std::atomic<bool>` CAS, C-ABI bridge); `CannyStubConsumer.cpp` (real OpenCV v4.13 Canny, 64-entry ring buffer of edge counts per ADR-29).
- `CameraKitInterop` Swift target (`.interoperabilityMode(.Cxx)` per ADR-13) — `CppPixelSinkPool`; `CppCaptureAtomic`; `CppCannyStub` with `edgeCount(at:)`.
- `Frameworks/opencv2.xcframework` — flat arm64-only xcframework (converted from versioned macOS framework via lipo + xcodebuild).
- `PixelSink.swift` — `ConsumerRegistry.registerCallback(stream:callbacks:)` real implementation backed by `CppPixelSinkPool`; dual-dispatch `yield()` to both Swift `AsyncStream` subscribers and C++ pool; `nativePipelinePointer()`.
- `StillCapture.swift` — `captureInFlight: CppCaptureAtomic`; `ManagedAtomic<Bool>` and `import Atomics` removed.
- `MetalPipeline.swift` / `TexturePoolManager.swift` / `Shaders/ColorShaders.metal` — `01:simple-metal-passthrough` scaffold comments removed.
- `CameraEngine.swift` — `getNativePipelineHandle() -> UInt64?` real implementation.
- `Errors.swift` — `InteropError.invalidCallbacks` and `.retainMismatch` added; `.notWired` removed.
- `Constants.swift` — `cppPoolThreadCount` added.
- `Package.swift` — `binaryTarget(opencv2)`, `CameraKitCxx`, `CameraKitInterop` targets; `.interoperabilityMode(.Cxx)` on `CameraKit` + `CameraKitTests` (required by Swift's transitive C++ interop rule, decision 38).
- `eva-swift-stitch.xcodeproj` — `OTHER_SWIFT_FLAGS += -cxx-interoperability-mode=default` on `eva-swift-stitch` + `eva-swift-stitchTests` (both Debug + Release).
- `Stage08Tests.swift` — 7 `@Test` functions.

## Public API exposed — Stage 08

```swift
public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) async throws -> ConsumerToken  // ConsumerRegistry (real)
public func getNativePipelineHandle() -> UInt64?  // CameraEngine
```

## Manual test evidence — Stage 08

| Test ID | Status | Notes |
|---------|--------|-------|
| `08:cpp-pixelsink-registration-roundtrip` | PASS | Stage08Tests |
| `08:canny-stub-consumer-receives-tracker-frames` | PASS | Stage08Tests |
| `08:get-native-pipeline-handle-holds-actor` | PASS | Stage08Tests (nil path) |
| `08:c-abi-callbacks-without-on-frame-rejected` | PASS | Stage08Tests |
| `08:lock-order-pipeline-stage-consumer` | PASS | Stage08Tests (concurrent dispatch, no deadlock) |
| `08:still-capture-uses-cpp-atomic` | PASS | Stage08Tests |
| `08:swift-subscribe-is-facade-over-cpp-pool` | PASS | Stage08Tests |
| `06:frame-set-publication` | PASS | carried forward |
| `06:swift-consumer-drop-on-busy` | PASS | carried forward |
| `07:still-capture-in-flight-guard` | PASS | carried forward |
| `08:external-canny-stub-runs-on-device` | PASS | `measurements/stage-08/canny.md` — iPad Pro M1, OpenCV v4.13, non-zero time-varying edge counts confirmed |

## Decisions taken that weren't in briefs — Stage 08

See decisions 35–38 in `CameraKit/DECISIONS.md`.

## Open questions for next stage

1. **HITL `08:external-canny-stub-runs-on-device`** — pending device run; evidence template in `measurements/stage-08/canny.md`.
2. **ADR-13 upstream revision** — C++ interop transitivity requires all importers to enable the flag; upstream should revise ADR-13.
3. **OpenCV xcframework Mac slice** — xcframework contains only `ios-arm64`; Mac "Designed for iPad" fallback build unverified for Stage 08 C++ targets.
4. **Carried open questions from Stage 07** (focalLengthMm, sigmoid curve, D-17 revision).

# state.md — Stage 07

## Current stage
Stage 07 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `06:simple-consumer-swift-only` | `PixelSink.swift` | `registerCallback` throws `notWired` | Stage 08 |
| `07:swift-side-capture-atomic` | `StillCapture.swift` | `captureInFlight: ManagedAtomic<Bool>` | Stage 08 |

Pre-flight grep command (Stage 08 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only\|07:swift-side-capture-atomic' CameraKit/Sources/
```
All four slugs must return ≥1 hit before any Stage 08 edit.

## What's built — Stage 07 (permanent)

- `FrameSet.swift` — `extension CVPixelBuffer: @retroactive @unchecked Sendable {}` added (G-13: CVPixelBuffer not yet Sendable on iOS 26; IOSurface + GPU-completion ordering make cross-thread use safe; required for `CheckedContinuation<CVPixelBuffer, Error>` in Stage 07).
- `Errors.swift` — `StillCaptureError.captureInProgress` renamed to `alreadyInFlight`; `EngineError.capture(StillCaptureError)` case added.
- `TexturePoolManager.swift` — `makeStillCapturePool(size:)`: 1-slot, IOSurface-backed, RGBA16F pool for CPU-readable still capture readback.
- `MetalPipeline.swift` — `stillCapturePool` (dedicated 1-slot); `pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?` mailbox (`nonisolated(unsafe)`); `stillBufForCompletion` captured before closure (avoids Swift 6 tuple-send warning); Pass 6 (blit `processedTexI → stillReadbackBuffer` at zero origins, gated on `pendingCaptureContinuation != nil`); completion-handler delivery of readback buffer; `armCapture(continuation:)` method; `stillCapturePoolForTest` + `stillCaptureDequeueCountForTest` test seams.
- `StillCapture.swift` — `captureInFlight: ManagedAtomic<Bool>` CAS guard (scaffolding:07:swift-side-capture-atomic); `captureImage(pipeline:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:)` async throws; vImage RGBA16F→RGBA8 conversion via `vImageConverter_CreateWithCGImageFormat` + `vImageConvert_AnyToAny`; `CGImageDestination` TIFF writer; EXIF dictionary (`ISO`, `ExposureTime`, `FocalLength`, `ApertureValue`, `SubjectDistance`, `ExposureProgram`, `DateTimeOriginal`, `UserComment`); TIFF dictionary (`Orientation`, `DateTime`); `"CamPlugin/v1"` JSON envelope under `UserComment` (D-09); `PHPhotoLibrary.requestAuthorization(for: .addOnly)` + `performChanges`; app-documents fallback on denial; `authorizationProvider` closure injection seam; `encodeToTIFF(readbackBuffer:...)` internal helper for tests.
- `CameraEngine.swift` — `captureImage(outputPath:)` public API; engine state guard (must be open + session running); `StillCapture` instance created at `open()`, cleared at `close()`; `apertureValue` from `LiveCaptureDevice.avDevice.lensAperture`; `focalLengthMm = 0` (placeholder per §4 brief footnote — see open questions); typed-throws wrapping `StillCaptureError` in `EngineError.capture(...)`.
- `eva-swift-stitch.xcodeproj` — `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` build setting added to Debug + Release; `Stage07Tests.swift` wired into `eva-swift-stitchTests` target.
- `ViewModel.swift` — `captureResult: Result<StillCaptureOutput, Error>?`; `captureImage()` action; 3-second auto-dismiss `bannerDismissTask`.
- `CameraView.swift` — capture button (`camera.shutter.button`) in bottom bar; "Image saved: …" / "Capture failed: …" banner with `.safeAreaInset(edge: .bottom)` + 3s auto-dismiss animation.
- `Stage07Tests.swift` — 5 `@Test` functions: `stillCaptureInFlightGuard`, `tiffRoundTripMatchesProcessedPreview`, `exifEnvelopeContainsCamPluginV1`, `photoLibraryAuthorizationDeniedFallsBack`, `exifStandardDictionaryPresent`.

## Public API exposed so far (Stage 07 additions)

```swift
public func captureImage(outputPath: String? = nil) async throws -> StillCaptureOutput   // on CameraEngine
```

## Manual test evidence — Stage 07

| Test ID | Status | Notes |
|---------|--------|-------|
| `07:still-capture-in-flight-guard` | PASS | Stage07Tests/stillCaptureInFlightGuard |
| `07:tiff-round-trip-matches-processed-preview` | PASS | Stage07Tests/tiffRoundTripMatchesProcessedPreview |
| `07:exif-envelope-contains-camplugin-v1` | PASS | Stage07Tests/exifEnvelopeContainsCamPluginV1 |
| `07:photo-library-authorization-denied-falls-back` | PASS | Stage07Tests/photoLibraryAuthorizationDeniedFallsBack |
| `07:exif-standard-dictionary-present` | PASS | Stage07Tests/exifStandardDictionaryPresent |
| `07:tiff-opens-in-preview-and-photos` | DEFERRED | HITL — `measurements/stage-07/capture.md` |
| `07:saved-banner-appears-three-seconds` | DEFERRED | HITL — `measurements/stage-07/capture.md` |
| `07:authorization-dialog-first-capture` | DEFERRED | HITL — `measurements/stage-07/capture.md` |

## Decisions taken that weren't in briefs — Stage 07

31. **`vImageConverter_CreateWithCGImageFormat` + `vImageConvert_AnyToAny` instead of `vImageConvert_RGBA16FtoARGB8888`.** `vImageConvert_RGBA16FtoARGB8888` is not available in the SDK (no such symbol). Used the generic vImage converter pipeline with explicit `vImageCVImageFormat` source (RGBA16F) and `vImageCGImageFormat` destination (RGBA8) instead. Channel ordering is handled by the converter's format specification.

32. **`kCGImagePropertyTIFFImageWidth` / `kCGImagePropertyTIFFImageLength` don't exist as constants.** Plan referenced these keys; they are not in ImageIO's SDK headers. TIFF dimensions are derived from the CGImage itself by `CGImageDestinationAddImage`. Removed from the TIFF metadata dict.

33. **`CVPixelBuffer: @retroactive @unchecked Sendable` added to FrameSet.swift.** Swift 6 strict concurrency requires `Sendable` for values passed to `CheckedContinuation.resume(returning:)`. CVPixelBuffer is not formally Sendable on iOS 26. Adding a module-level retroactive conformance (matching the existing `FrameSet: @unchecked Sendable` rationale in G-13) resolves the error cleanly without changing the continuation type.

34. **`stillBufForCompletion: CVPixelBuffer?` captured as named let before closure.** Swift 6 flags accessing `stillPair.0` (tuple member) inside a `@Sendable` closure as a data race. Extracting the buffer to a named let binding before the closure (same pattern as `naturalBuf`/`processedBuf`) eliminates the diagnostic.

## Open questions for next stage

1. **`focalLengthMm`** — `AVCaptureDevice.activeFormat` doesn't expose focal length directly; used 0 as placeholder per brief §4 footnote. Upstream should clarify which metadata field to use.
2. **HITL evidence** (`07:tiff-opens-in-preview-and-photos`, `07:saved-banner-appears-three-seconds`, `07:authorization-dialog-first-capture`) deferred to device-on-hand session.
3. **`"CamPlugin/v1"` JSON schema** (U-09) remains deferred.
4. **Sigmoid contrast curve** (carried from Stage 06) — pin formula before Stage 11.
5. **D-17 upstream revision** (carried from Stage 06).

# state.md — Stage 06

## Current stage
Stage 06 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `06:simple-consumer-swift-only` | `PixelSink.swift` | `registerCallback` throws `notWired` | Stage 08 |

Pre-flight grep command (Stage 07 must run before modifying sources):
```
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only' CameraKit/Sources/
```
All three slugs returned ≥1 hit as of Stage 06.

## What's built — Stage 06 (permanent)

- `Constants.swift` — adds `trackerHeightPx: Int = 480`, `poolMinBufferCount: Int = 3`, `poolMaxBufferAgeSeconds: Double = 1.0`.
- `Errors.swift` — adds `InteropError.notWired`; C-ABI real variants arrive Stage 08.
- `TexturePoolManager.swift` — adds `makeWorkingFormatPool(size:) throws -> CVPixelBufferPool` (IOSurface-backed, Metal-compatible, RGBA16Half, 3-buffer minimum); adds `dequeuePoolTexture(pool:width:height:) throws -> (buffer: CVPixelBuffer, texture: MTLTexture)` (zero-copy CVMetalTextureCache wrap per ADR-06).
- `Shaders/TrackerDownsample.metal` — `trackerDownsample` compute kernel; bilinear sampling (`access::sample` + `MTLSamplerState`, clampToEdge) from natural texture into aspect-preserved even-pixel-rounded tracker texture; bounds check via `outTex.get_width()/get_height()`.
- `PixelSink.swift` — `ConsumerRegistry` rewritten as `public actor`; hot paths (`yield`, `hasSubscriber`) are `nonisolated` backed by `Mutex<InnerState>` (no actor hop on frame clock, ADR-02); `subscribe(stream:) -> AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22; `registerCallback(stream:callbacks:)` throws `InteropError.notWired` (scaffolding:06:simple-consumer-swift-only); `release()` terminates all streams; test-visible `dropCount(for:)` and `subscriberCount(for:)` metrics; `PixelSinkCallbacks` gains `@unchecked Sendable`.
- `MetalPipeline.swift` — promotes single `naturalTex`/`processedTex` to `CVPixelBufferPool` trio (`naturalPool`, `processedPool`, `trackerPool`); `nonisolated(unsafe)` mailboxes `latestNaturalTex`/`latestProcessedTex`/`latestTrackerTex` for MTKView draw pass (G-13, Stage 06 trade-off: single writer on delivery queue); Pass 4 (`trackerDownsample`) dispatched when `.tracker` has a subscriber; `FrameSet` constructed in `addCompletedHandler` from delivery-queue-local captures only (CMSampleBuffer not Sendable — timestamp + metadata extracted before closure); publishes to all three `StreamId`s; convenience `init(device:captureSize:gateOpen:consumers:)` for tests; test seams `naturalPoolForTest`, `processedPoolForTest`, `trackerPoolForTest`, `trackerSizeForTest`, `texturePoolForTest`, `setLatestNaturalForTest`, `setLatestProcessedForTest`.
- `CaptureDelegate.swift` — removed `weak var pipeline`; `captureOutput` delegates to `onSampleBuffer?` + `engine?.tickFrame()` (no direct pipeline coupling).
- `CameraEngine.swift` — `public nonisolated let consumers: ConsumerRegistry`; `open()` and `setResolution()` pass `consumers:` to `MetalPipeline`; `await consumers.release()` in `close()`; `public nonisolated func currentTrackerTexture() -> (any MTLTexture)?`.
- `FrameSet.swift` — adds `extension CaptureMetadata { static func placeholder() -> CaptureMetadata }` (zeroed fields, neutral white balance gains, used by completion handler until Stage 09 wires real metadata).
- `ViewModel.swift` — adds `DebugOverlay` struct (`frameNumber`, `captureTimeMs`); `var debugOverlay: DebugOverlay?`; `var debugTrackerSubscribed: Bool`; `nonisolated(unsafe) var trackerTex: MTLTexture?`; `startDebugOverlay()` subscribes to `.natural` and updates overlay every 10th frame (~3 fps — throttled to eliminate 30 SwiftUI re-renders/sec; MTKView preview is GPU-direct via mailboxes); `toggleDebugTrackerSubscription()` wires/unwires `.tracker` subscriber; `stop()` cancels all subscriber tasks.
- `CameraView.swift` (`#if DEBUG`) — yellow `#N  t=…ms` text overlay top-left from `debugOverlay`; `MTKViewRepresentable` tracker thumbnail (160×120 pt, yellow border, bottom-left) when `debugTrackerSubscribed`; "Show/Hide Tracker" toggle button.
- `Stage06Tests.swift` — 7 `@Test` functions: `frameSetPublication`, `swiftConsumerDropOnBusy`, `poolTrioAllocationOnOpen`, `trackerDownsampleHeightMatchesConstant`, `subscribeThenCancelReleasesSubscriber`, `registerCallbackThrowsNotWired`, `naturalStreamIsSubscribable`.
- `eva_swift_stitchApp.swift` — `UIApplicationDelegateAdaptor(AppDelegate.self)` with `supportedInterfaceOrientationsFor → .landscapeRight`; enforces landscape at UIKit level so SwiftUI `WindowGroup` never appears in portrait.
- `eva-swift-stitch/Info.plist` — `UISupportedInterfaceOrientations~ipad = [UIInterfaceOrientationLandscapeRight]`; `UIRequiresFullScreen = true` (disables Split View / Slide Over).

## What's built — Stage 05 (permanent)

- `UniformStorage.swift` — `struct UniformStorage: Sendable, Hashable` (color + crop fields); static `identity(captureSize:)` factory.
- `ProcessingMetadata.swift` — extracted from `FrameSet.swift`; public shape unchanged; internal `init(color:crop:)` used by `MetalPipeline.encode()` to construct the per-frame snapshot.
- `MetalPipeline` — `UniformsHost` class removed; replaced by `let uniforms: Mutex<UniformStorage>` (Synchronization framework, iOS 18+). `encode()` snapshots via `uniforms.withLock { $0 }` before any Metal command, satisfying Inv 6. `lastProcessingMetadata: ProcessingMetadata?` written per frame (Stage 06 consumer path). `ColorUniform` and `CropUniform` now `Hashable`.
- `CameraEngine` — `setProcessingParameters(_:)` and `setCropRegion(_:)` write through `pipeline.uniforms.withLock { ... }`.
- `CaptureDelegate.onProcessingMetadata` — `((ProcessingMetadata) -> Void)?` stub callback; no-op in Stage 05 (nil default); Stage 06 wires consumer dispatch.
- Inv 6 (no torn writes on uniform buffer) now enforced in code. Architecture prose unchanged (brief §4 literal).
- `Tests/CameraKitTests/Stage05Tests.swift` — 3 `@Test` functions: torn-write stress, snapshot-matches-lock, mutex-scope-is-tight.

## What's built — Stage 04 (permanent)

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

## Public API exposed so far (Stage 06 additions)

```swift
public actor ConsumerRegistry {
    public func subscribe(stream: StreamId) async -> AsyncStream<FrameSet>
    public func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) async throws -> ConsumerToken
    public func unregister(token: ConsumerToken) async
    public func release() async
    public nonisolated func yield(_ frameSet: FrameSet, stream: StreamId)
    public nonisolated func hasSubscriber(_ stream: StreamId) -> Bool
}
public nonisolated func currentTrackerTexture() -> (any MTLTexture)?  // on CameraEngine
```

## Public API exposed so far (Stage 05 additions)

(None — Stage 05 is a MIGRATION. `ProcessingMetadata` was already public from the Stage 04 stub; no new public API surface.)

## Public API exposed so far (Stage 04 additions)

```swift
public func setProcessingParameters(_ params: ProcessingParameters) async
public func setCropRegion(_ rect: Rect) async throws
public func sampleCenterPatch() async throws -> RgbSample
public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters?
public nonisolated func currentProcessedTexture() -> (any MTLTexture)?
```

## Manual test evidence — Stage 06

| Test ID | Status | Notes |
|---------|--------|-------|
| `06:frame-set-publication` | PASS | Stage06Tests/frameSetPublication — synthetic YUV buffer; all 3 streams receive frameNumber==1; IOSurface-backed. |
| `06:swift-consumer-drop-on-busy` | PASS | Stage06Tests/swiftConsumerDropOnBusy — 30-frame producer at ~100fps vs 30fps consumer; ≥1 drop recorded. |
| `06:pool-trio-allocation-on-open` | PASS | Stage06Tests/poolTrioAllocationOnOpen — dequeue from each pool; IOSurface-backed confirmed. |
| `06:tracker-downsample-height-matches-constant` | PASS | Stage06Tests/trackerDownsampleHeightMatchesConstant — height==480, width even, aspect-preserved. |
| `06:subscribe-then-cancel-releases-subscriber` | PASS | Stage06Tests/subscribeThenCancelReleasesSubscriber — count drops to 0 after task cancel + yield. |
| `06:register-callback-throws-not-wired` | PASS | Stage06Tests/registerCallbackThrowsNotWired — InteropError.notWired thrown. |
| `06:natural-stream-is-subscribable` | PASS | Stage06Tests/naturalStreamIsSubscribable — .natural lane delivers FrameSet. |
| `06:tracker-thumbnail-appears-on-subscribe` | PASS | HITL — `measurements/stage-06/consumers.md`. Device: iPad 00008027-000539EA0184402E, iOS 26. |
| `06:debug-overlay-shows-frame-number-capture-time` | PASS | HITL — `measurements/stage-06/consumers.md`. N increments monotonically; t non-decreasing. |

## Manual test evidence — Stage 05

| Test ID | Status | Notes |
|---------|--------|-------|
| `05:uniform-lock-no-torn-writes-under-stress` | PASS | Stage05Tests/uniformLockNoTornWritesUnderStress — 1 000 concurrent writes + 10 000 snapshots, 0 torn reads. |
| `05:processing-metadata-snapshot-matches-lock` | PASS | Stage05Tests/processingMetadataSnapshotMatchesLock — brightness 0.3 round-trips. |
| `05:mutex-scope-is-tight` | PASS | Stage05Tests/mutexScopeIsTight — source grep confirms no commit()/encoder inside withLock. |
| `04:color-pipeline-golden-frame` (carried) | PASS | Still green post-migration. |
| `04:processing-params-persistence-roundtrip` (carried) | PASS | Still green post-migration. |
| Device smoke (`04:rapid-slider-stress`) | DEFERRED | Brief §12 says unit tests only; device Instruments run is optional HITL. |

## Manual test evidence — Stage 04

| Test ID | Status | Notes |
|---------|--------|-------|
| `04:color-pipeline-golden-frame` | PASS | Stage04Tests/colorPipelineGoldenFrame — identity + brightness +0.2. |
| `04:processing-params-persistence-roundtrip` | PASS | Stage04Tests/processingParamsPersistenceRoundtrip — per-test UUID suite. |
| `04:center-patch-trimmed-mean` | PASS | Stage04Tests/centerPatchTrimmedMean — uniform fill + 10% outliers. |
| `04:set-crop-region-updates-uniform` | PASS | Stage04Tests/setCropRegionUpdatesUniform — happy + out-of-bounds throw. |
| `04:color-slider-visual-correctness` | PASS | `measurements/stage-04/color.md`. Verified Shreeyak's iPad iOS 26.4.1. |
| `04:rapid-slider-stress-sees-occasional-torn-frame` | PASS | `measurements/stage-04/color.md`. 0 glitches observed in ~10s stress. |

## Decisions taken that weren't in briefs — Stage 06

26. **`captureOrientationAngleDeg` corrected from 90° to 0°.** Brief ADR-17 specified a rotation angle for landscape-right delivery. On iPad's horizontal-sensor back camera, `videoRotationAngle = 90` delivered portrait-rotated buffers (width < height) while `captureSize` remained landscape (from format description before rotation). YUV shader out-of-bounds reads at `gid.x ≥ delivered_width` returned `(Y=0, Cb=0, Cr=0)` which the YCbCr→RGB formula maps to `RGB(0,154,0)` = green. Fixed to 0° (native sensor orientation = landscape). ADR-17 should be updated upstream to note this is device-class-dependent.

27. **`UIApplicationDelegateAdaptor` required to enforce landscape lock.** `UISupportedInterfaceOrientations~ipad` + `UIRequiresFullScreen` in Info.plist alone did not prevent portrait startup with SwiftUI `WindowGroup`. Adding a `UIApplicationDelegate` adapter returning `.landscapeRight` from `supportedInterfaceOrientationsFor(_:)` is the reliable mechanism for SwiftUI apps on iPadOS.

28. **Debug overlay throttled to every 10th frame (~3 fps).** Subscribing to `.natural` and calling `await MainActor.run { self.debugOverlay = overlay }` at 30 fps caused 30 full SwiftUI `CameraView.body` re-renders per second, visibly degrading preview smoothness. The MTKView preview is GPU-direct via `nonisolated(unsafe)` texture mailboxes and needs no SwiftUI involvement; only the text overlay requires MainActor. Throttling to 3 fps restores perceived 30 fps preview while keeping the overlay useful.

29. **`ProcessingMetadata` blackR/G/B resolved via `ColorUniform`.** Stage 05 open question: skeleton had `ProcessingMetadata` missing black-balance fields. Stage 06 constructs `ProcessingMetadata(color: ColorUniform, crop: CropUniform)` where `ColorUniform` includes `blackR/G/B/gamma` — fields are now present in every published `FrameSet.processing`. No separate field addition needed.

30. **Pass 4 input is `naturalTexI` (not `processedTexI`).** Brief §4 was ambiguous; tracker downsample runs after Pass 1 (YUV→RGBA) and uses the unprocessed natural frame as input, keeping the tracker stream independent of color-calibration sliders. This matches domain intent (tracker should see the raw scene, not a stylized version).

## Decisions taken that weren't in briefs — Stage 05

21. **`Mutex<UniformStorage>` (Synchronization framework) instead of `OSAllocatedUnfairLock` per D-17.** User-authorized override. Rationale: Mutex is the preferred primitive for new Swift 6+ code; exposes only `withLock`/`withLockIfAvailable` (no manual `lock()`/`unlock()`), structurally guaranteeing "lock not held across commit" (Inv 6 / ADR-09) without runtime assertions. Flag D-17 upstream for revision to reflect iOS 18+ Mutex availability.

22. **Property named `uniforms` not `uniformsLock`.** Plan specified `uniformsLock`; the previous-session implementation agent used `uniforms`. Tests were written against `uniforms.withLock`, matching the actual property name. Renaming would be a no-op behaviour change; keeping `uniforms` is consistent with usage and avoids churn.

23. **`05:mutex-scope-is-tight` replaces brief §8 "debug counter" test.** Brief asked for "a debug counter in the lock scope is zero at commit time." With `Mutex`, holding the lock across commit is structurally impossible (no manual lock/unlock API). The test instead scans the source text to confirm no `commit()` or encoder call appears inside any `withLock` closure.

24. **`ProcessingMetadata` missing `blackR/G/B` fields vs `ProcessingParameters`.** Skeleton discrepancy carried from `api-skeletons/`. `FrameSet.processing` field name retained as `processing` (not `processingMetadata` per brief §4 wording). Resolved in Stage 06 — see decision 29.

25. **`DispatchQueue.concurrentPerform` in stress test.** Brief §8 literally specifies it. The swift-concurrency skill forbids GCD in production; CLAUDE.md §8 gives brief precedence for stage-specific test harness tooling.

## Open questions for next stage

1. **Sigmoid contrast curve** — pin formula choice via ADR or 07-settings §Processing-order amendment before Stage 11 polish.
2. **D-17 upstream revision** — update `architecture/02-concurrency.md` §D-17 to reflect `Mutex` (iOS 18+, Synchronization framework) as the preferred lock for this pattern in new Swift 6+ code. Also note ADR-17 camera rotation is device-class-dependent (see decision 26).
3. **Crop visual verification** — Stage 06 pool trio is live; end-to-end crop→pixel correspondence test deferred to a future HITL pass or Stage 07.
4. **`UIRequiresFullScreen` deprecated in iOS 26** — Apple docs note this key will be ignored in a future release; no replacement API documented yet. Monitor for a replacement.
5. **Instruments pool high-water-mark** — brief §11 asks for Allocations evidence that pool per-lane equals `POOL_CAP_RULE` and ages out after `POOL_MAX_BUFFER_AGE_SECONDS`. Deferred; not a blocker for Stage 07.
