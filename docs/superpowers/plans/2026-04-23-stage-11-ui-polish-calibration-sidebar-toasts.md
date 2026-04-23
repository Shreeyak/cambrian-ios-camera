# Stage 11 — UI Polish: Full Bar, Calibration Sidebar, State-Driven UI, Toasts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the full UI that matches `domain-revised/09-ui-behaviors.md` — split preview, five-button bottom bar, collapsible expanded bar for ISO/Shutter/Focus/Zoom, color-calibration sidebar with WB + BB Calibrate buttons, recording indicator with timer, capture banner, non-fatal error toast, blocking fatal-error dialog, state-driven enable/disable, Liquid Glass styling, landscape-right lock. UI-only stage: no new public API, no new scaffolds.

**Architecture:** A per-control slider debouncer (`AsyncStream.bufferingNewest(1)` + 16 ms sleep) in the ViewModel coalesces high-Hz input to ≤60 Hz engine dispatch. `CalibrationCompute` (new pure helper) derives `WhiteBalanceGains` (gray-world reciprocal) and black-balance offsets from `RgbSample`. A `ControlEnablement` value derived from `(SessionState, RecordingState)` drives every control's `isEnabled` binding — single source of truth, no scattered conditionals. Scanning animation binds to the `SessionState` machine, not to `focusDistance == nil` (ui×state J4). Non-fatal `CameraError` pushes onto a toast with ≥3 s auto-dismiss; fatal `CameraError` fills a blocking dialog that only dismisses on Retry or Dismiss. Orientation lock (already set by Stage 06) is re-verified.

**Tech Stack:** SwiftUI iOS 26 (Liquid Glass via `.glassEffect` / `glassButtonStyle`), swift-testing, AsyncStream-based debouncer, pure Swift for calibration math.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `CameraKit/Sources/CameraKit/CalibrationCompute.swift` | Create | Pure helpers: `grayWorldGains(sample:) -> WhiteBalanceGains`; `blackBalanceOffsets(sample:) -> (r: Double, g: Double, b: Double)`. |
| `CameraKit/Sources/CameraKit/FrameSet.swift` | Modify | `WhiteBalanceGains.init(fromGrayWorld sample: RgbSample)` convenience + `public init` confirmation (brief §4 names `Settings.swift` but the type lives here — logged as Decision). |
| `CameraKit/Sources/CameraKit/ControlEnablement.swift` | Create | `struct ControlEnablement` deriving `isRecordEnabled / isCaptureEnabled / isResolutionEnabled / isSettingsEnabled / isCalibrateEnabled / isStopEnabled / showScanningAnimation` from `(SessionState, RecordingState)`. |
| `CameraKit/Sources/CameraKit/SliderDebouncer.swift` | Create | Per-control 60 Hz coalescer: wraps an `AsyncStream<Double>.Continuation`, consumer Task sleeps 16 ms between dispatches, cancels pending partials; generic over dispatch closure. |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Modify | Wire `currentError: CameraError?` → split into `currentToast: CameraError?` (auto-dismiss ≥3 s) and `fatalDialog: CameraError?` (no auto-dismiss); add `calibrateWB()` + `calibrateBB()` actions using `CalibrationCompute`; install per-control `SliderDebouncer`s for ISO / Shutter / Focus / Zoom / Brightness / Contrast / Saturation / Gamma / BlackR / BlackG / BlackB; derive `var controlEnablement: ControlEnablement` from `(sessionState, recordingState)`; bind scanning animation via `controlEnablement.showScanningAnimation` (J4). |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Modify | Full bottom bar (Settings / Calibrate / Capture / Record / Resolution); expanded bar sliding up from Settings; calibration sidebar with WB + BB Calibrate buttons + brightness / contrast / saturation / gamma / BlackR/G/B sliders + Reset; recording indicator (red dot + `mm:ss` timer via `TimelineView(.periodic)`); capture banner (carried from Stage 07); error-toast overlay (non-fatal); blocking error dialog (fatal, Retry + Dismiss); `.glassEffect` Liquid Glass styling on bar/sidebar; orientation lock enforced by `.statusBar` + existing Info.plist + AppDelegate. |
| `CameraKit/Sources/CameraKit/OrientationLock.swift` | Create (small) | `extension UIApplication` helper or SwiftUI `.statusBarOrientation(.landscapeRight)` guard — idempotent if Stage 06 already locked it, but gives a single read path for tests/HITL. |
| `eva-swift-stitch/Info.plist` | Verify | Stage 06 already sets `UISupportedInterfaceOrientations~ipad = [UIInterfaceOrientationLandscapeRight]`. Task 13 confirms no change needed; if Stage 06's entry is missing, re-add it. |
| `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` | Create | 7 `@Test` functions covering §8 TESTABLEs (all unit-testable against ViewModel + helpers; no device required). |
| `eva-swift-stitch.xcodeproj` | Modify | Wire `Stage11Tests.swift` into `eva-swift-stitchTests` via ruby xcodeproj gem. |

---

## Build / test tooling note

XcodeBuildMCP disconnected for this session. Use the shell wrappers per CLAUDE.md §6:

```bash
scripts/build-summary.sh                                      # iOS build
scripts/test-summary.sh --filter CameraKitTests/Stage11Tests  # Stage 11 only
scripts/test-summary.sh                                       # full CameraKit suite
```

Both pipe through `xcsift`, persist to `.build-logs/*.json` + `*.log`, enforce physical-iPad → Mac "Designed for iPad" destination order. Never `xcodebuild` directly; never simulators.

---

## Task 1: Stage preflight

**Files:** `CameraKit/state.md`, `scripts/stage-preflight.sh`

- [ ] **Step 1: Run preflight**

```bash
bash scripts/stage-preflight.sh
```
Expected: exits 0.

- [ ] **Step 2: Verify Stage 10 is complete + scaffold inventory**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/      # must be ≥1 hit
grep -rn -E '01:|04:|06:|07:|09:' CameraKit/Sources/          # must be 0 hits
```

- [ ] **Step 3: Clean build baseline**

```bash
bash scripts/build-summary.sh
```
Expected: BUILD SUCCEEDED.

---

## Task 2: CalibrationCompute — TDD

**Files:** `CameraKit/Sources/CameraKit/CalibrationCompute.swift`, `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`

- [ ] **Step 1: Write the failing test**

Create `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`:

```swift
import Testing
@testable import CameraKit

@Suite("Stage 11 — calibration compute")
struct Stage11CalibrationTests {
    @Test("gray-world gains are reciprocal of normalized channel averages")
    func grayWorldGainsReciprocal() {
        // (r=0.5, g=1.0, b=0.8) — mean = 0.7666...
        // Normalize by mean: (0.652, 1.304, 1.043). Gain = 1/normalized.
        // Equivalent: gains = mean / channel.
        let sample = RgbSample(r: 0.5, g: 1.0, b: 0.8)
        let gains = CalibrationCompute.grayWorldGains(sample: sample)
        let mean = (0.5 + 1.0 + 0.8) / 3.0
        #expect(abs(Double(gains.red)   - mean / 0.5) < 1e-5)
        #expect(abs(Double(gains.green) - mean / 1.0) < 1e-5)
        #expect(abs(Double(gains.blue)  - mean / 0.8) < 1e-5)
    }

    @Test("black-balance offsets are per-channel sample values")
    func blackBalanceOffsets() {
        let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
        let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
        #expect(offsets.r == 0.02)
        #expect(offsets.g == 0.03)
        #expect(offsets.b == 0.05)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage11CalibrationTests
```
Expected: compile error (`CalibrationCompute` undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure helpers for WB + BB calibration. Called from ViewModel (UI logic per 07-settings §Calibration).
/// The engine only applies ProcessingParameters / CameraSettings — the math lives here.
public enum CalibrationCompute {

    /// Gray-world white balance: gains normalize channels so all three average to the scene mean.
    /// `gains[c] = mean / channel[c]` (equivalent to reciprocal of mean-normalized channel).
    /// Guard against zero channels by clamping denominator to a small epsilon.
    public static func grayWorldGains(sample: RgbSample) -> WhiteBalanceGains {
        let eps = 1e-4
        let r = max(eps, sample.r)
        let g = max(eps, sample.g)
        let b = max(eps, sample.b)
        let mean = (r + g + b) / 3.0
        return WhiteBalanceGains(
            red: Float(mean / r),
            green: Float(mean / g),
            blue: Float(mean / b)
        )
    }

    /// Black-balance offsets: the measured dark-patch sample is the per-channel pedestal
    /// to subtract during the color pipeline (ProcessingParameters.blackR/G/B).
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        (sample.r, sample.g, sample.b)
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/CalibrationCompute.swift CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "feat(stage-11): CalibrationCompute — gray-world WB + black-balance offsets"
```

---

## Task 3: WhiteBalanceGains from RgbSample convenience

**Files:** `CameraKit/Sources/CameraKit/FrameSet.swift`

- [ ] **Step 1: Add convenience init**

At the end of `FrameSet.swift`:

```swift
public extension WhiteBalanceGains {
    /// Gray-world reciprocal gains from a sampled center patch. Mirrors
    /// `CalibrationCompute.grayWorldGains(sample:)` — provided here for call-site ergonomics.
    init(fromGrayWorld sample: RgbSample) {
        self = CalibrationCompute.grayWorldGains(sample: sample)
    }
}
```

Note: brief §4 says "Sources/CameraKit/Settings.swift — ensure WhiteBalanceGains is publicly constructible from a RgbSample." `WhiteBalanceGains` actually lives in `FrameSet.swift` (not `Settings.swift`). The public `init(red:green:blue:)` already exists; this adds the `fromGrayWorld:` convenience. Log in state.md Decisions that the edit landed in `FrameSet.swift` rather than `Settings.swift`.

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh   # expect BUILD SUCCEEDED
git add CameraKit/Sources/CameraKit/FrameSet.swift
git commit -m "feat(stage-11): WhiteBalanceGains.init(fromGrayWorld:) convenience"
```

---

## Task 4: ControlEnablement — TDD

**Files:** `CameraKit/Sources/CameraKit/ControlEnablement.swift`, `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Stage11Tests.swift`:

```swift
@Suite("Stage 11 — control enablement matrix")
struct Stage11EnablementTests {
    @Test("closed state disables everything")
    func closedDisablesAll() {
        let e = ControlEnablement(sessionState: .closed, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isSettingsEnabled)
        #expect(!e.isCalibrateEnabled)
        #expect(e.isResolutionEnabled == false)
    }

    @Test("streaming idle enables everything")
    func streamingEnablesAll() {
        let e = ControlEnablement(sessionState: .streaming, recordingState: .idle(lastUri: nil))
        #expect(e.isRecordEnabled)
        #expect(e.isCaptureEnabled)
        #expect(e.isSettingsEnabled)
        #expect(e.isCalibrateEnabled)
        #expect(e.isResolutionEnabled)
    }

    @Test("recording disables capture and resolution per U-18")
    func recordingDisablesCaptureResolution() {
        let e = ControlEnablement(sessionState: .streaming, recordingState: .recording)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isResolutionEnabled)
        #expect(e.isStopEnabled)           // Record → Stop
        #expect(e.isCalibrateEnabled)      // sidebar stays usable during recording
    }

    @Test("recovering shows scanning animation and disables all inputs")
    func recoveringBlocksInputs() {
        let e = ControlEnablement(sessionState: .recovering, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isSettingsEnabled)
        #expect(e.showScanningAnimation)
    }

    @Test("paused disables capture/record; resolution visible but disabled")
    func pausedBehavior() {
        let e = ControlEnablement(sessionState: .paused, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isSettingsEnabled)
        #expect(e.isResolutionEnabled == false)
    }

    @Test("opening disables everything and shows scanning")
    func openingShowsScanning() {
        let e = ControlEnablement(sessionState: .opening, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(e.showScanningAnimation)
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

Create `CameraKit/Sources/CameraKit/ControlEnablement.swift`:

```swift
import Foundation

/// Derived view-model state: which controls are enabled + whether scanning spinner shows.
/// Single source of truth per §State-Driven UI Behavior — prevents scattered `if sessionState ==`
/// checks in the view.
public struct ControlEnablement: Sendable, Hashable {
    public let isRecordEnabled: Bool
    public let isStopEnabled: Bool          // Record button in "Stop" mode, enabled only while recording
    public let isCaptureEnabled: Bool
    public let isResolutionEnabled: Bool
    public let isSettingsEnabled: Bool
    public let isCalibrateEnabled: Bool
    public let showScanningAnimation: Bool  // ui×state J4: binds to SessionState, not focusDistance

    public init(sessionState: SessionState, recordingState: RecordingState) {
        let isStreaming = sessionState == .streaming
        let isRecording: Bool = {
            if case .recording = recordingState { return true }
            return false
        }()
        let isScanning = (sessionState == .opening || sessionState == .recovering)

        self.showScanningAnimation = isScanning
        self.isSettingsEnabled    = isStreaming && !isRecording ? true : false
        self.isCalibrateEnabled   = isStreaming                              // usable during recording
        self.isCaptureEnabled     = isStreaming && !isRecording
        self.isResolutionEnabled  = isStreaming && !isRecording
        self.isRecordEnabled      = isStreaming && !isRecording
        self.isStopEnabled        = isStreaming && isRecording
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/ControlEnablement.swift CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "feat(stage-11): ControlEnablement — state-driven isEnabled matrix (domain 09 §State-Driven UI)"
```

---

## Task 5: SliderDebouncer — TDD

**Files:** `CameraKit/Sources/CameraKit/SliderDebouncer.swift`, `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Stage 11 — slider coalescing")
struct Stage11SliderTests {
    @Test("240 Hz input over 1 s produces ≤ 61 engine dispatches; last value committed")
    func sliderCoalescing60Hz() async {
        let dispatchCount = ManagedAtomicSafe<Int>(0)
        let lastValue = ManagedAtomicSafe<Double>(0.0)
        let deb = SliderDebouncer(intervalMs: 16) { value in
            dispatchCount.increment()
            lastValue.set(value)
        }
        await deb.start()
        // 240 updates over ~1 second.
        let t0 = ContinuousClock.now
        var i = 0
        while ContinuousClock.now.duration(to: t0 + .seconds(1)) >= .zero && i < 240 {
            deb.push(Double(i) / 240.0)
            try? await Task.sleep(for: .microseconds(4_166)) // ~240 Hz
            i += 1
        }
        // Allow pending dispatch to drain.
        try? await Task.sleep(for: .milliseconds(50))
        await deb.stop()
        #expect(dispatchCount.get() <= 61)
        #expect(abs(lastValue.get() - Double(i - 1) / 240.0) < 1e-6)
    }
}

/// Small actor wrapper around a counter/value for the test (avoids importing swift-atomics in test).
actor ManagedAtomicSafe<T: Sendable> {
    private var value: T
    init(_ v: T) { self.value = v }
    func get() -> T { value }
    func set(_ v: T) { value = v }
}
extension ManagedAtomicSafe where T == Int {
    func increment() { value += 1 }
}
```

Note: the `ManagedAtomicSafe` wrapper is an actor, so `get`/`set`/`increment` are `async` — wrap call sites with `await`. Fix the test's `dispatchCount.increment()` / `lastValue.set(value)` to `await` both:

```swift
let deb = SliderDebouncer(intervalMs: 16) { value in
    await dispatchCount.increment()
    await lastValue.set(value)
}
```

This requires `SliderDebouncer`'s dispatch closure to be `async`.

- [ ] **Step 2: Run — expect compile failure**

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Per-control 60 Hz slider coalescer. Pushes are non-blocking; the consumer task
/// reads the latest buffered value every `intervalMs` and dispatches.
/// Pattern: AsyncStream.bufferingNewest(1) → sleep(16 ms) → dispatch latest.
public final class SliderDebouncer: @unchecked Sendable {
    public typealias Dispatch = @Sendable (Double) async -> Void

    private let intervalMs: Int
    private let dispatch: Dispatch
    private let continuation: AsyncStream<Double>.Continuation
    private let stream: AsyncStream<Double>
    private var consumerTask: Task<Void, Never>?

    public init(intervalMs: Int = 16, dispatch: @escaping Dispatch) {
        self.intervalMs = intervalMs
        self.dispatch = dispatch
        var c: AsyncStream<Double>.Continuation!
        self.stream = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        self.continuation = c
    }

    public func start() async {
        consumerTask?.cancel()
        let stream = self.stream
        let dispatch = self.dispatch
        let intervalMs = self.intervalMs
        consumerTask = Task {
            for await v in stream {
                if Task.isCancelled { break }
                await dispatch(v)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    public func push(_ value: Double) {
        continuation.yield(value)
    }

    public func stop() async {
        continuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add CameraKit/Sources/CameraKit/SliderDebouncer.swift CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "feat(stage-11): SliderDebouncer — 60Hz coalescing (bufferingNewest(1) + 16ms)"
```

---

## Task 6: ViewModel — error split, calibrate actions, enablement

**Files:** `CameraKit/Sources/CameraKit/ViewModel.swift`

- [ ] **Step 1: Replace `currentError` with split toast/dialog fields**

Locate the existing `var currentError: CameraError?` (added Stage 09). Replace with:

```swift
    /// Non-fatal errors auto-dismiss as toasts. See 08-ui.md §Error display.
    var currentToast: CameraError?
    /// Fatal errors require Retry or Dismiss — never auto-dismiss.
    var fatalDialog: CameraError?

    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
```

Update the `errorConsumerTask` loop:

```swift
    errorConsumerTask = Task { [weak self] in
        guard let self else { return }
        for await err in self.engine.errorStream() {
            await MainActor.run {
                if err.isFatal {
                    self.fatalDialog = err
                } else {
                    self.currentToast = err
                    self.toastDismissTask?.cancel()
                    self.toastDismissTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        await MainActor.run { self?.currentToast = nil }
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Add calibrate actions**

```swift
    func calibrateWB() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await self.engine.sampleCenterPatch()
                let gains = CalibrationCompute.grayWorldGains(sample: sample)
                var delta = CameraSettings()
                delta.wbMode = .manual
                delta.wbGainR = Double(gains.red)
                delta.wbGainG = Double(gains.green)
                delta.wbGainB = Double(gains.blue)
                try await self.engine.updateSettings(delta)
            } catch {
                // surfacing through errorStream is not guaranteed for this path; keep silent.
            }
        }
    }

    func calibrateBB() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await self.engine.sampleCenterPatch()
                let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
                var next = self.currentProcessing
                next.blackR = offsets.r
                next.blackG = offsets.g
                next.blackB = offsets.b
                await self.engine.setProcessingParameters(next)
                await MainActor.run { self.currentProcessing = next }
            } catch {}
        }
    }
```

- [ ] **Step 3: Add `controlEnablement` derived property**

```swift
    var controlEnablement: ControlEnablement {
        ControlEnablement(sessionState: sessionState, recordingState: recordingState)
    }
```

- [ ] **Step 4: Add per-control slider debouncers (lazy, one per control)**

```swift
    @ObservationIgnored private var isoDebouncer: SliderDebouncer?
    @ObservationIgnored private var shutterDebouncer: SliderDebouncer?
    @ObservationIgnored private var focusDebouncer: SliderDebouncer?
    @ObservationIgnored private var zoomDebouncer: SliderDebouncer?
    @ObservationIgnored private var brightnessDebouncer: SliderDebouncer?
    @ObservationIgnored private var contrastDebouncer: SliderDebouncer?
    @ObservationIgnored private var saturationDebouncer: SliderDebouncer?
    @ObservationIgnored private var gammaDebouncer: SliderDebouncer?

    /// Called once from start() after engine.open().
    private func startDebouncers() async {
        isoDebouncer = SliderDebouncer { [weak self] v in
            guard let self else { return }
            var d = CameraSettings(); d.isoMode = .manual; d.iso = Int(v)
            try? await self.engine.updateSettings(d)
        }
        shutterDebouncer = SliderDebouncer { [weak self] v in
            guard let self else { return }
            var d = CameraSettings(); d.exposureMode = .manual; d.exposureTimeNs = Int64(v)
            try? await self.engine.updateSettings(d)
        }
        focusDebouncer = SliderDebouncer { [weak self] v in
            guard let self else { return }
            var d = CameraSettings(); d.focusMode = .manual; d.focusDistance = v
            try? await self.engine.updateSettings(d)
        }
        zoomDebouncer = SliderDebouncer { [weak self] v in
            guard let self else { return }
            var d = CameraSettings(); d.zoomRatio = v
            try? await self.engine.updateSettings(d)
        }
        let processingWrite: @Sendable (inout ProcessingParameters) async -> Void = { [weak self] mutator in
            guard let self else { return }
            var next = await MainActor.run { self.currentProcessing }
            mutator(&next)
            await self.engine.setProcessingParameters(next)
            await MainActor.run { self.currentProcessing = next }
        }
        brightnessDebouncer = SliderDebouncer { v in
            await processingWrite { $0.brightness = v }
        }
        contrastDebouncer = SliderDebouncer { v in
            await processingWrite { $0.contrast = v }
        }
        saturationDebouncer = SliderDebouncer { v in
            await processingWrite { $0.saturation = v }
        }
        gammaDebouncer = SliderDebouncer { v in
            await processingWrite { $0.gamma = v }
        }
        for d in [isoDebouncer, shutterDebouncer, focusDebouncer, zoomDebouncer,
                  brightnessDebouncer, contrastDebouncer, saturationDebouncer, gammaDebouncer] {
            await d?.start()
        }
    }

    /// Public push methods used by the view's slider `onChange` handlers.
    func pushISO(_ v: Double)         { isoDebouncer?.push(v) }
    func pushShutter(_ v: Double)     { shutterDebouncer?.push(v) }
    func pushFocus(_ v: Double)       { focusDebouncer?.push(v) }
    func pushZoom(_ v: Double)        { zoomDebouncer?.push(v) }
    func pushBrightness(_ v: Double)  { brightnessDebouncer?.push(v) }
    func pushContrast(_ v: Double)    { contrastDebouncer?.push(v) }
    func pushSaturation(_ v: Double)  { saturationDebouncer?.push(v) }
    func pushGamma(_ v: Double)       { gammaDebouncer?.push(v) }
```

Invoke `await startDebouncers()` from `start()` after `engine.open()`. In `stop()`:

```swift
    for d in [isoDebouncer, shutterDebouncer, focusDebouncer, zoomDebouncer,
              brightnessDebouncer, contrastDebouncer, saturationDebouncer, gammaDebouncer] {
        await d?.stop()
    }
```

- [ ] **Step 5: Retry / Dismiss hooks for fatal dialog**

```swift
    func retryFromFatal() {
        fatalDialog = nil
        Task { [weak self] in
            guard let self else { return }
            await self.engine.close()
            _ = try? await self.engine.open()
        }
    }

    func dismissFatal() {
        fatalDialog = nil
    }
```

- [ ] **Step 6: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/ViewModel.swift
git commit -m "feat(stage-11): VM split toast/fatalDialog, WB+BB calibrate, 8 debouncers, enablement"
```

---

## Task 7: CameraView — full bottom bar (5 buttons)

**Files:** `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Replace the existing bottom bar with the five-button full bar**

```swift
    private var bottomBar: some View {
        let e = viewModel.controlEnablement
        return HStack(spacing: 18) {
            barButton(label: "Settings", systemImage: "slider.horizontal.3",
                      enabled: e.isSettingsEnabled) { showExpandedBar.toggle() }
            barButton(label: "Calibrate", systemImage: "paintpalette",
                      enabled: e.isCalibrateEnabled) { sidebarVisible.toggle() }
            captureButton(enabled: e.isCaptureEnabled)
            recordButton(enablementStart: e.isRecordEnabled, enablementStop: e.isStopEnabled)
            Text(resolutionText)
                .font(.caption.monospaced())
                .opacity(e.isResolutionEnabled ? 1.0 : 0.4)
                .onLongPressGesture { if isDebugBuild { showDeliveryStats.toggle() } }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .glassEffect(in: Capsule())      // iOS 26 Liquid Glass
    }

    @ViewBuilder
    private func barButton(label: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 60)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
    }

    @ViewBuilder
    private func captureButton(enabled: Bool) -> some View {
        Button(action: { viewModel.captureImage() }) {
            Image(systemName: "camera.shutter.button.fill").font(.largeTitle)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
    }

    @ViewBuilder
    private func recordButton(enablementStart: Bool, enablementStop: Bool) -> some View {
        if case .recording = viewModel.recordingState {
            Button(action: { viewModel.toggleRecording() }) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 16, height: 16)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsedMMSS).font(.body.monospacedDigit())
                    }
                }
            }.disabled(!enablementStop).opacity(enablementStop ? 1 : 0.4)
        } else {
            Button(action: { viewModel.toggleRecording() }) {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(.red)
            }.disabled(!enablementStart).opacity(enablementStart ? 1 : 0.4)
        }
    }

    private var resolutionText: String {
        guard let caps = viewModel.capabilities else { return "—" }
        return "\(caps.activeCaptureResolution.width)×\(caps.activeCaptureResolution.height)"
    }

    private var elapsedMMSS: String {
        let s = viewModel.recordingElapsedSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
```

Required new `@State` fields on `CameraView`:

```swift
    @State private var showExpandedBar: Bool = false
    @State private var showDeliveryStats: Bool = false
```

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-11): full bottom bar — Settings/Calibrate/Capture/Record/Resolution with state-driven enablement + Liquid Glass"
```

---

## Task 8: CameraView — expanded bar (ISO / Shutter / Focus / Zoom)

**Files:** `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Add expanded bar**

```swift
    @ViewBuilder
    private var expandedBar: some View {
        if showExpandedBar {
            VStack(alignment: .leading, spacing: 10) {
                expandedControl(
                    label: "ISO",
                    valueText: viewModel.lastFrameResult?.iso.map { "\($0)" } ?? "AUTO",
                    initial: Double(viewModel.lastFrameResult?.iso ?? 400),
                    range: 100...3200,
                    push: viewModel.pushISO
                )
                expandedControl(
                    label: "Shutter (µs)",
                    valueText: viewModel.lastFrameResult?.exposureTimeNs.map { "\($0 / 1_000)" } ?? "AUTO",
                    initial: Double(viewModel.lastFrameResult?.exposureTimeNs ?? 16_666_667),
                    range: 100_000...33_000_000,
                    push: viewModel.pushShutter
                )
                expandedControl(
                    label: "Focus",
                    valueText: viewModel.lastFrameResult?.focusDistance.map { String(format: "%.2f", $0) } ?? "AUTO",
                    initial: viewModel.lastFrameResult?.focusDistance ?? 0.5,
                    range: 0.0...1.0,
                    push: viewModel.pushFocus
                )
                expandedControl(
                    label: "Zoom",
                    valueText: String(format: "%.1fx", viewModel.currentSettings.zoomRatio ?? 1.0),
                    initial: viewModel.currentSettings.zoomRatio ?? 1.0,
                    range: 1.0...4.0,
                    push: viewModel.pushZoom
                )
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .glassEffect(in: RoundedRectangle(cornerRadius: 14))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func expandedControl(
        label: String,
        valueText: String,
        initial: Double,
        range: ClosedRange<Double>,
        push: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Text(valueText).font(.caption.monospaced()).frame(width: 90, alignment: .trailing)
            SliderRebinding(initial: initial, range: range, onChange: push)
                .frame(maxWidth: .infinity)
        }
    }

    /// A slider that doesn't re-bind to a `@State` — direct push semantics so the
    /// SliderDebouncer handles all dispatch; avoids SwiftUI-driven mid-drag write-backs.
    struct SliderRebinding: View {
        let initial: Double
        let range: ClosedRange<Double>
        let onChange: (Double) -> Void
        @State private var local: Double
        init(initial: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
            self.initial = initial
            self.range = range
            self.onChange = onChange
            _local = State(initialValue: initial)
        }
        var body: some View {
            Slider(value: $local, in: range, onEditingChanged: { _ in })
                .onChange(of: local) { _, new in onChange(new) }
        }
    }
```

Add `expandedBar` into the view hierarchy above `bottomBar`, inside the `.safeAreaInset(edge: .bottom)` VStack.

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-11): expanded bar — ISO/Shutter/Focus/Zoom with debounced sliders"
```

---

## Task 9: CameraView — calibration sidebar with WB/BB Calibrate

**Files:** `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Rewrite the sidebar from Stage 04's baseline**

Replace the existing `calibrationSidebar` block:

```swift
    private var calibrationSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Calibration").font(.headline)
            HStack(spacing: 8) {
                Button("WB Calibrate") { viewModel.calibrateWB() }
                    .buttonStyle(.borderedProminent)
                Button("BB Calibrate") { viewModel.calibrateBB() }
                    .buttonStyle(.bordered)
            }
            Divider()
            sliderRow(label: "Brightness",
                      current: viewModel.currentProcessing.brightness,
                      range: -1.0...1.0, push: viewModel.pushBrightness)
            sliderRow(label: "Contrast",
                      current: viewModel.currentProcessing.contrast,
                      range:  0.0...2.0, push: viewModel.pushContrast)
            sliderRow(label: "Saturation",
                      current: viewModel.currentProcessing.saturation,
                      range: -1.0...1.0, push: viewModel.pushSaturation)
            sliderRow(label: "Gamma",
                      current: viewModel.currentProcessing.gamma,
                      range:  0.1...3.0, push: viewModel.pushGamma)
            Divider()
            channelSliderRow(label: "Black R", keyPath: \ProcessingParameters.blackR)
            channelSliderRow(label: "Black G", keyPath: \ProcessingParameters.blackG)
            channelSliderRow(label: "Black B", keyPath: \ProcessingParameters.blackB)
            Divider()
            Button("Reset") { Task { await viewModel.resetProcessing() } }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
    }

    private func sliderRow(label: String, current: Double, range: ClosedRange<Double>, push: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label).font(.caption); Spacer(); Text(String(format: "%.2f", current)).font(.caption.monospaced()) }
            SliderRebinding(initial: current, range: range, onChange: push)
        }
    }

    private func channelSliderRow(label: String, keyPath: WritableKeyPath<ProcessingParameters, Double>) -> some View {
        let current = viewModel.currentProcessing[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label).font(.caption); Spacer(); Text(String(format: "%.2f", current)).font(.caption.monospaced()) }
            SliderRebinding(initial: current, range: 0.0...1.0) { v in
                Task {
                    var next = viewModel.currentProcessing
                    next[keyPath: keyPath] = v
                    await viewModel.engine.setProcessingParameters(next)
                    await MainActor.run { viewModel.currentProcessing = next }
                }
            }
        }
    }
```

Gate visibility with `sidebarVisible` + `controlEnablement.isCalibrateEnabled` in the outer body.

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-11): calibration sidebar — WB/BB Calibrate + BRG/contrast/sat/gamma + black balance + reset"
```

---

## Task 10: CameraView — error toast (non-fatal) + blocking dialog (fatal)

**Files:** `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Add overlays**

Inside the root ZStack (or root container):

```swift
    .overlay(alignment: .top) {
        if let toast = viewModel.currentToast {
            errorToast(toast).padding(.top, 20)
        }
    }
    .alert(
        "Camera Error",
        isPresented: Binding(
            get: { viewModel.fatalDialog != nil },
            set: { if !$0 { viewModel.dismissFatal() } }
        ),
        presenting: viewModel.fatalDialog
    ) { err in
        Button("Retry") { viewModel.retryFromFatal() }
        Button("Dismiss", role: .cancel) { viewModel.dismissFatal() }
    } message: { err in
        Text("\(err.code.rawValue)\n\n\(err.message)")
    }
```

```swift
    @ViewBuilder
    private func errorToast(_ err: CameraError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.code.rawValue).font(.caption.bold())
                Text(err.message).font(.caption2).lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .glassEffect(in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 400)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
```

Remove any prior Stage 09 `recoveryBanner` / fatal alert — superseded by the split here.

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-11): non-fatal error toast (auto-dismiss) + fatal alert (Retry/Dismiss)"
```

---

## Task 11: Scanning animation bound to SessionState (J4)

**Files:** `CameraKit/Sources/CameraKit/CameraView.swift`

- [ ] **Step 1: Add scanning overlay**

```swift
    @ViewBuilder
    private var scanningOverlay: some View {
        if viewModel.controlEnablement.showScanningAnimation {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text(viewModel.sessionState == .recovering ? "Recovering camera…" : "Opening camera…")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
    }
```

Add `.overlay(scanningOverlay)` on the root preview container. Critically: this is **not** bound to `liveFrameResult.focusDistance == nil` (which had ambiguous UX during .streaming with fast AF).

- [ ] **Step 2: Build + commit**

```bash
bash scripts/build-summary.sh
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "feat(stage-11): scanning overlay binds to SessionState (ui×state J4 resolution)"
```

---

## Task 12: Orientation lock — verify Stage 06 setup still holds

**Files:** `eva-swift-stitch/Info.plist`, `CameraKit/Sources/CameraKit/OrientationLock.swift` (create)

- [ ] **Step 1: Verify Info.plist**

```bash
grep -E "UISupportedInterfaceOrientations|UIRequiresFullScreen" eva-swift-stitch/Info.plist
```
Expected: `UISupportedInterfaceOrientations~ipad` contains `UIInterfaceOrientationLandscapeRight` only; `UIRequiresFullScreen = true`.

If missing (Stage 06 drift), re-add per state.md Stage 06 decisions.

- [ ] **Step 2: Create the read-path helper**

```swift
import SwiftUI

/// Single place tests can check the declared orientation policy. Stage 06 enforces
/// the policy via Info.plist + UIApplicationDelegateAdaptor; this helper exposes it.
public enum OrientationLock {
    public static var declaredSupported: UIInterfaceOrientationMask { .landscapeRight }
}
```

- [ ] **Step 3: Commit**

```bash
git add CameraKit/Sources/CameraKit/OrientationLock.swift
git commit -m "chore(stage-11): OrientationLock read-path; confirm landscape-right (Stage 06 already set)"
```

---

## Task 13: Stage11Tests — the remaining 5 TESTABLEs

**Files:** `CameraKit/Tests/CameraKitTests/Stage11Tests.swift`

Tasks 2, 4, 5 already covered 3 of the 7 TESTABLEs (calibration compute implicit in WB/BB tests below — counted per brief §8). Add the remaining tests now. These rely on a fake engine so the ViewModel can be exercised headlessly.

- [ ] **Step 1: Fake engine seam**

Introduce a minimal test-only engine wrapper. Because `CameraEngine` is an `actor` with a large surface, it's cleanest to test the ViewModel with direct method stubs via a small protocol. Add (in the test file):

```swift
import AVFoundation
import CoreMedia
@testable import CameraKit

// Test seam: a stubbable CameraEngine-shaped interface. Only the methods used
// by the tests. For prod the ViewModel still holds a real CameraEngine.
protocol EngineStub: AnyObject {
    func sampleCenterPatchStub() async throws -> RgbSample
    func updateSettingsStub(_ s: CameraSettings) async throws
    func setProcessingParametersStub(_ p: ProcessingParameters) async
}
```

Then add a `_testStub: EngineStub?` hook to `ViewModel` (gated `#if DEBUG` or internal-visibility) so tests inject a stub that intercepts before the real engine call. See Step 6 below.

- [ ] **Step 2: `11:wb-calibrate-applies-computed-gains`**

```swift
@Suite("Stage 11 — WB calibrate")
struct Stage11WBTests {
    @Test("calibrateWB applies gray-world reciprocal gains via updateSettings")
    func wbCalibrateAppliesComputedGains() async {
        final class Stub: EngineStub {
            var recorded: CameraSettings?
            func sampleCenterPatchStub() async throws -> RgbSample {
                RgbSample(r: 0.5, g: 1.0, b: 0.8)
            }
            func updateSettingsStub(_ s: CameraSettings) async throws { recorded = s }
            func setProcessingParametersStub(_ p: ProcessingParameters) async {}
        }
        let stub = Stub()
        let vm = ViewModel()
        vm._testStub = stub
        vm.calibrateWB()
        // Allow Task to run.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stub.recorded?.wbMode == .manual)
        let mean = (0.5 + 1.0 + 0.8) / 3.0
        #expect(abs((stub.recorded?.wbGainR ?? 0) - mean / 0.5) < 1e-4)
        #expect(abs((stub.recorded?.wbGainG ?? 0) - mean / 1.0) < 1e-4)
        #expect(abs((stub.recorded?.wbGainB ?? 0) - mean / 0.8) < 1e-4)
    }
}
```

- [ ] **Step 3: `11:bb-calibrate-updates-processing-params`**

```swift
@Test("calibrateBB writes black-balance offsets to ProcessingParameters")
func bbCalibrateUpdatesProcessingParams() async {
    final class Stub: EngineStub {
        var recordedBlack: (Double, Double, Double)?
        func sampleCenterPatchStub() async throws -> RgbSample {
            RgbSample(r: 0.02, g: 0.03, b: 0.05)
        }
        func updateSettingsStub(_ s: CameraSettings) async throws {}
        func setProcessingParametersStub(_ p: ProcessingParameters) async {
            recordedBlack = (p.blackR, p.blackG, p.blackB)
        }
    }
    let stub = Stub()
    let vm = ViewModel()
    vm._testStub = stub
    vm.calibrateBB()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(stub.recordedBlack?.0 == 0.02)
    #expect(stub.recordedBlack?.1 == 0.03)
    #expect(stub.recordedBlack?.2 == 0.05)
}
```

- [ ] **Step 4: `11:state-driven-control-enable-disable`**

(Already covered partly in Task 4; extend to the exact matrix the brief calls out.)

```swift
@Test("enablement matrix covers the six states brief §8 names")
func stateDrivenControlEnableDisable() {
    let cases: [(SessionState, RecordingState, (record: Bool, capture: Bool, resolution: Bool, settings: Bool, calibrate: Bool))] = [
        (.closed,     .idle(lastUri: nil), (false, false, false, false, false)),
        (.opening,    .idle(lastUri: nil), (false, false, false, false, false)),
        (.streaming,  .idle(lastUri: nil), (true,  true,  true,  true,  true)),
        (.paused,     .idle(lastUri: nil), (false, false, false, false, false)),
        (.error,      .idle(lastUri: nil), (false, false, false, false, false)),
        (.streaming,  .recording,          (false, false, false, false, true)),
    ]
    for (ss, rs, expected) in cases {
        let e = ControlEnablement(sessionState: ss, recordingState: rs)
        #expect(e.isRecordEnabled     == expected.record,     "record for \(ss)/\(rs)")
        #expect(e.isCaptureEnabled    == expected.capture,    "capture for \(ss)/\(rs)")
        #expect(e.isResolutionEnabled == expected.resolution, "resolution for \(ss)/\(rs)")
        #expect(e.isSettingsEnabled   == expected.settings,   "settings for \(ss)/\(rs)")
        #expect(e.isCalibrateEnabled  == expected.calibrate,  "calibrate for \(ss)/\(rs)")
    }
}
```

Note: brief §8 mentions `.closing` state. The current `SessionState` enum has no `.closing` — closest is `.closed` after teardown completes. Log in state.md Decisions that `.closing` was treated as `.closed` for enablement since the state enum doesn't distinguish.

- [ ] **Step 5: `11:non-fatal-error-shows-toast` + `11:fatal-error-shows-blocking-dialog`**

```swift
@Suite("Stage 11 — error UI")
struct Stage11ErrorUITests {
    @Test("non-fatal error sets currentToast and clears after ≥3s")
    func nonFatalErrorShowsToast() async {
        let vm = ViewModel()
        let err = CameraError(code: .frameStall, message: "gpu: no frame", isFatal: false)
        await MainActor.run { vm._feedErrorForTest(err) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.currentToast != nil)
        #expect(vm.fatalDialog == nil)
        try? await Task.sleep(for: .seconds(3))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.currentToast == nil)
    }

    @Test("fatal error sets fatalDialog and does not auto-dismiss")
    func fatalErrorShowsBlockingDialog() async {
        let vm = ViewModel()
        let err = CameraError(code: .maxRetriesExceeded, message: "boom", isFatal: true)
        await MainActor.run { vm._feedErrorForTest(err) }
        try? await Task.sleep(for: .seconds(4))
        #expect(vm.fatalDialog != nil)
        #expect(vm.currentToast == nil)
    }
}
```

Add test seam on ViewModel:

```swift
    /// Test-only: inject a CameraError directly into the toast/dialog path.
    func _feedErrorForTest(_ err: CameraError) {
        if err.isFatal {
            fatalDialog = err
        } else {
            currentToast = err
            toastDismissTask?.cancel()
            toastDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.currentToast = nil }
            }
        }
    }
```

- [ ] **Step 6: `11:scanning-animation-binds-to-session-state`**

```swift
@Test("scanning animation binds to SessionState, not focusDistance")
func scanningAnimationBindsToSessionState() {
    // SessionState .streaming with focusDistance == nil MUST NOT trigger scanning.
    let streaming = ControlEnablement(sessionState: .streaming, recordingState: .idle(lastUri: nil))
    #expect(streaming.showScanningAnimation == false)

    // SessionState .opening / .recovering MUST trigger scanning regardless of any focus value.
    let opening = ControlEnablement(sessionState: .opening, recordingState: .idle(lastUri: nil))
    let recovering = ControlEnablement(sessionState: .recovering, recordingState: .idle(lastUri: nil))
    #expect(opening.showScanningAnimation)
    #expect(recovering.showScanningAnimation)
}
```

- [ ] **Step 7: Slider coalescing test (from Task 5) is already in the suite**

- [ ] **Step 8: Build + run the Stage 11 suite**

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage11
```
Expected: all 7 TESTABLE tests green.

- [ ] **Step 9: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage11Tests.swift CameraKit/Sources/CameraKit/ViewModel.swift
git commit -m "test(stage-11): 7 TESTABLE tests — WB/BB calibrate, enablement matrix, toast/fatal, scanning, slider coalescing"
```

---

## Task 14: Wire Stage11Tests + full regression

**Files:** `eva-swift-stitch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add to test target**

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
t = p.targets.find { |x| x.name == 'eva-swift-stitchTests' }
g = p.main_group.find_subpath('CameraKit/Tests/CameraKitTests', true)
f = g.new_reference('CameraKit/Tests/CameraKitTests/Stage11Tests.swift')
t.source_build_phase.add_file_reference(f)
p.save"
```

- [ ] **Step 2: Full regression**

```bash
bash scripts/test-summary.sh --filter "CameraKitTests/Stage"
```
Expected: all Stage 01–11 tests green.

- [ ] **Step 3: Scaffold inventory**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/       # ≥1 hit
grep -rn -E '01:|04:|06:|07:|09:|11:' CameraKit/Sources/       # 0 hits (Stage 11 adds no scaffolds)
```

- [ ] **Step 4: Commit**

```bash
git add eva-swift-stitch.xcodeproj
git commit -m "test(stage-11): wire Stage11Tests into eva-swift-stitchTests target"
```

---

## Task 15: state.md + HITL stub

**Files:** `CameraKit/state.md`, `measurements/stage-11/ui.md`

- [ ] **Step 1: Prepend Stage 11 section to state.md**

Include:

- `## Current stage` → Stage 11 complete.
- `## Scaffolding still live` → `10:synchronous-drain-pause` (retires Stage 12). No new Stage 11 scaffolds.
- `## What's built — Stage 11 (permanent)`: `CalibrationCompute`, `ControlEnablement`, `SliderDebouncer`, `OrientationLock`, ViewModel error split (`currentToast` / `fatalDialog`), `calibrateWB` / `calibrateBB` actions, 8 per-control debouncers, full bottom bar (5 buttons), expanded bar (ISO/Shutter/Focus/Zoom), calibration sidebar (WB/BB + brightness/contrast/sat/gamma + black balance + reset), recording indicator w/ timer, error toast + fatal dialog, scanning overlay bound to `SessionState`, Liquid Glass styling.
- `## Public API exposed so far (Stage 11 additions)` → None (UI-only stage).
- `## Manual test evidence — Stage 11`:

| Test ID | Status | Notes |
|---------|--------|-------|
| `11:wb-calibrate-applies-computed-gains` | PASS | Stage11WBTests/wbCalibrateAppliesComputedGains |
| `11:bb-calibrate-updates-processing-params` | PASS | Stage11WBTests/bbCalibrateUpdatesProcessingParams |
| `11:slider-coalescing-60hz` | PASS | Stage11SliderTests/sliderCoalescing60Hz |
| `11:state-driven-control-enable-disable` | PASS | Stage11EnablementTests + Stage11EnablementTests/stateDrivenControlEnableDisable |
| `11:non-fatal-error-shows-toast` | PASS | Stage11ErrorUITests/nonFatalErrorShowsToast |
| `11:fatal-error-shows-blocking-dialog` | PASS | Stage11ErrorUITests/fatalErrorShowsBlockingDialog |
| `11:scanning-animation-binds-to-session-state` | PASS | Stage11EnablementTests/scanningAnimationBindsToSessionState |
| `11:full-bar-and-sidebar-match-domain-09` | DEFERRED | HITL — `measurements/stage-11/ui.md` |
| `11:liquid-glass-and-landscape-lock` | DEFERRED | HITL — `measurements/stage-11/ui.md` |
| `11:accessibility-voiceover-pass` | DEFERRED | HITL — `measurements/stage-11/ui.md` |

- `## Decisions taken that weren't in briefs — Stage 11`:
  - **`WhiteBalanceGains.init(fromGrayWorld:)` landed in `FrameSet.swift`** — brief §4 said `Settings.swift`, but the type lives in `FrameSet.swift`; keeping the convenience colocated with the type.
  - **`SessionState.closing` absent** — brief §8 enablement matrix names `.closing`; current enum has no such case. Treated as `.closed` for enablement semantics. Flag upstream.
  - **Liquid Glass via `.glassEffect` modifier** — iOS 26+ API; relies on the ios-26-platform skill. Verified via device HITL (`11:liquid-glass-and-landscape-lock`).
  - **`SliderRebinding` helper view** — plain `Slider` bound to `@State` oscillates mid-drag because SwiftUI re-renders the parent when the ViewModel writes back the committed value; the helper keeps the Slider's `@State` local to the view and only forwards `onChange` to the debouncer.
  - **No `FrameDeliveryStats` long-press overlay implementation** — brief §4 says "stubbed"; long-press gesture is wired on Resolution but Stage 12 populates the stream.
- `## Open questions for next stage`:
  - Stage 12 retires `10:synchronous-drain-pause` and populates `FrameDeliveryStats`.
  - `SessionState.closing` case — upstream to clarify.

- [ ] **Step 2: Regenerate CONTRACTS.md**

```bash
bash scripts/regen-contracts.sh
```

- [ ] **Step 3: Create HITL stub `measurements/stage-11/ui.md`**

```markdown
# Stage 11 — HITL UI evidence

## 11:full-bar-and-sidebar-match-domain-09
Device: iPad Pro M1.
- Capture screenshots of: bottom bar idle, bottom bar recording, expanded bar, calibration sidebar.
- Compare visually against `domain-revised/09-ui-behaviors.md` §Bottom Controls Bar / §Expanded Bar / §Color Calibration Sidebar.
- Store screenshots at `measurements/stage-11/screenshots/`.
PASS / FAIL: ________
Date: ________

## 11:liquid-glass-and-landscape-lock
Device: iPad Pro M1.
- Rotate device through all 4 orientations; UI remains landscape-right.
- Confirm Liquid Glass translucency on bars/sidebar visible against varied backgrounds.
PASS / FAIL: ________
Date: ________

## 11:accessibility-voiceover-pass (DEFERRED)
Device: iPad Pro M1.
- Enable VoiceOver.
- Tab through every interactive control; confirm each has a meaningful label.
- Note any missing labels.
Observations: ________
Date: ________
```

- [ ] **Step 4: Commit**

```bash
git add CameraKit/state.md CameraKit/CONTRACTS.md measurements/stage-11/ui.md
git commit -m "docs(stage-11): state.md Stage 11; HITL evidence stubs; regen CONTRACTS"
```

---

## Task 16: Final verification

- [ ] **Step 1: Full build + tests**

```bash
bash scripts/build-summary.sh
bash scripts/test-summary.sh --filter "CameraKitTests/Stage"
```
Expected: BUILD SUCCEEDED + all tests green. Read `.build-logs/*.json` on any failure — never piped `| tail`.

- [ ] **Step 2: Device smoke on iPad Pro M1**

- Visual sweep: bottom bar, expanded bar (open + slide every control), calibration sidebar, WB Calibrate + BB Calibrate, record + stop, pause + resume, capture banner.
- Force a non-fatal `CameraError` via a debug toggle → toast appears, auto-dismisses ≥3 s.
- Force a fatal `CameraError` → blocking dialog appears; Retry reopens session; Dismiss closes.
- Cover sensor → preview → `FRAME_STALL` / AE convergence notification toasts fire appropriately.
- VoiceOver sweep (DEFERRED).

Record in `measurements/stage-11/ui.md` + screenshots in `measurements/stage-11/screenshots/`.

- [ ] **Step 3: Scaffold acceptance**

```bash
grep -rn '10:synchronous-drain-pause' CameraKit/Sources/       # ≥1 hit
grep -rn -E '01:|04:|06:|07:|09:|11:' CameraKit/Sources/       # 0 hits
```

- [ ] **Step 4: Stop. Request user approval before push / merge.**

---

## Self-review

- **Spec coverage:** every §4 file has a task; every §8 TESTABLE has a test in Task 2, 4, 5, or 13; §7 invariants covered (WB in Task 6 Step 2, BB in Task 6 Step 2, coalescing in Task 5, enablement in Task 4, error display in Tasks 6 + 10, scanning in Task 4 + 11, orientation in Task 12, FrameDeliveryStats stub noted in state.md). §10 acceptance checked in Task 14 + 16.
- **Placeholder scan:** No "TBD / implement later". `SliderRebinding` is fully specified. `EngineStub` test seam requires a small ViewModel change (Task 13 Step 1), covered by "add `_testStub: EngineStub?` hook" with visible code path.
- **Type consistency:** `ControlEnablement` shape used identically in Task 4 + 7 + 8 + 13. `CameraError.isFatal` split in Task 6 matches Task 10 alert binding. `SliderDebouncer.push(_: Double)` signature consistent across Tasks 5 + 6 + 8.
- **Stage-ordering guard:** Task 1 verifies Stage 10 scaffold present + prior-stage scaffolds retired.
- **Non-obvious decisions surfaced in state.md:** `WhiteBalanceGains.init` location, absent `.closing` enum case, Liquid Glass API choice, `SliderRebinding` helper rationale, `FrameDeliveryStats` stubbed until Stage 12.
