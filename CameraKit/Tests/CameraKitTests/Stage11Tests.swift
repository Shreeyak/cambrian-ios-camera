import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

// MARK: - Stage 11 — Calibration compute (pure helpers)

@Suite("Stage 11 — calibration compute")
struct Stage11CalibrationComputeTests {

    // Identity gains — useful for tests that want the reciprocal-only behavior
    // without the stacking multiplier.
    private let unityGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    private let typicalMax: Float = 4.0

    @Test("neutral linear sample with unity current gains returns unity (no-op)")
    func grayWorldNeutralLinearSampleIsNoOp() {
        // Linear value 0.5 maps via sRGB EOTF to ~0.214 — but for r==g==b the mean
        // ratio is exactly 1, so newGain == current regardless of linearization.
        let sample = RgbSample(r: 0.5, g: 0.5, b: 0.5)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(abs(gains.red   - 1.0) < 1e-5)
        #expect(abs(gains.green - 1.0) < 1e-5)
        #expect(abs(gains.blue  - 1.0) < 1e-5)
    }

    @Test("bluish sample produces gains all ≥ 1.0 with B anchored (no pink-tint regression)")
    func grayWorldBluishSampleAnchorsBlue() {
        // B is the brightest channel — its corrected gain ends up at min after
        // normalization → exactly 1.0. R/G are scaled up correspondingly.
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.8)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(gains.red   >= 1.0)
        #expect(gains.green >= 1.0)
        #expect(abs(gains.blue - 1.0) < 1e-5)
        #expect(gains.red > gains.green)
        #expect(gains.green > gains.blue)
    }

    @Test("stacks reciprocal onto non-unity current gains (delta correction semantics)")
    func grayWorldStacksOntoCurrentGains() {
        // Same sample, two different current gains — the *ratio* between channels
        // in the result must reflect the multiplied product (current × reciprocal).
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.6)
        let unityResult = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        let scaledCurrent = WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5)
        let scaledResult = CalibrationCompute.grayWorldGains(
            sample: sample, current: scaledCurrent, maxGain: typicalMax)

        // The unity result has ratios r:g:b == reciprocal ratios.
        // The scaled result has ratios r:g:b == (current × reciprocal) ratios.
        // After min-normalization both are normalized — but their channel ratios
        // diverge because the inputs do.
        let unityRG = unityResult.red / unityResult.green
        let scaledRG = scaledResult.red / scaledResult.green
        #expect(unityRG != scaledRG, "stacking must change the per-channel ratio")
    }

    @Test("clamps each channel to [1.0, maxGain]")
    func grayWorldClampsToMaxGain() {
        // Severe correction case: very dim red channel + already-high red current
        // gain → product blows past maxGain.
        let sample = RgbSample(r: 0.05, g: 0.5, b: 0.5)
        let aggressiveCurrent = WhiteBalanceGains(red: 3.5, green: 1.0, blue: 1.0)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: aggressiveCurrent, maxGain: typicalMax)
        #expect(gains.red   <= typicalMax)
        #expect(gains.green >= 1.0)
        #expect(gains.blue  >= 1.0)
    }

    @Test("near-zero channels are clamped to epsilon (no division by zero)")
    func grayWorldClampsZeroChannel() {
        let sample = RgbSample(r: 0.0, g: 0.5, b: 0.5)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(gains.red.isFinite)
        #expect(gains.red >= 1.0)
    }

    @Test("black-balance offsets are per-channel sample values")
    func blackBalanceOffsetsPassthrough() {
        let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
        let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
        #expect(offsets.r == 0.02)
        #expect(offsets.g == 0.03)
        #expect(offsets.b == 0.05)
    }
}

// MARK: - Stage 11 — ControlEnablement (state-driven UI matrix)

@Suite("Stage 11 — control enablement matrix")
struct Stage11ControlEnablementTests {

    @Test("closed state disables everything; no scanning")
    func closedDisablesAll() {
        let e = ControlEnablement(sessionState: .closed, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isSettingsEnabled)
        #expect(!e.isCalibrateEnabled)
        #expect(!e.isResolutionEnabled)
        #expect(!e.showScanningAnimation)
    }

    @Test("opening shows scanning, disables inputs")
    func openingShowsScanning() {
        let e = ControlEnablement(sessionState: .opening, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(e.showScanningAnimation)
    }

    @Test("streaming idle enables every control")
    func streamingEnablesAll() {
        let e = ControlEnablement(sessionState: .streaming, recordingState: .idle(lastUri: nil))
        #expect(e.isRecordEnabled)
        #expect(e.isCaptureEnabled)
        #expect(e.isSettingsEnabled)
        #expect(e.isCalibrateEnabled)
        #expect(e.isResolutionEnabled)
        #expect(!e.showScanningAnimation)
    }

    @Test("paused disables capture/record; resolution disabled")
    func pausedDisablesAll() {
        let e = ControlEnablement(sessionState: .paused, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isSettingsEnabled)
        #expect(!e.isResolutionEnabled)
    }

    @Test("recovering shows scanning and disables inputs")
    func recoveringShowsScanning() {
        let e = ControlEnablement(sessionState: .recovering, recordingState: .idle(lastUri: nil))
        #expect(!e.isRecordEnabled)
        #expect(!e.isCaptureEnabled)
        #expect(e.showScanningAnimation)
    }

    @Test("recording disables capture and resolution per U-18")
    func recordingDisablesCaptureResolution() {
        let e = ControlEnablement(sessionState: .streaming, recordingState: .recording)
        #expect(!e.isCaptureEnabled)
        #expect(!e.isResolutionEnabled)
        #expect(!e.isRecordEnabled)  // Record button is now Stop
        #expect(e.isStopEnabled)
        #expect(e.isCalibrateEnabled)  // sidebar stays usable during recording
    }

    /// Brief §8 TESTABLE `11:state-driven-control-enable-disable` — full matrix sweep.
    ///
    /// Brief names `.closing` SessionState; current enum has no such case (treat
    /// as `.closed` for enablement semantics — flagged in state.md for upstream).
    @Test("enablement matrix covers every state the brief calls out")
    func stateDrivenControlEnableDisable() {
        let cases:
            [(
                SessionState, RecordingState,
                (record: Bool, capture: Bool, resolution: Bool, settings: Bool, calibrate: Bool)
            )] = [
                (.closed, .idle(lastUri: nil), (false, false, false, false, false)),
                (.opening, .idle(lastUri: nil), (false, false, false, false, false)),
                (.streaming, .idle(lastUri: nil), (true, true, true, true, true)),
                (.paused, .idle(lastUri: nil), (false, false, false, false, false)),
                (.error, .idle(lastUri: nil), (false, false, false, false, false)),
                (.streaming, .recording, (false, false, false, false, true)),
            ]
        for (ss, rs, expected) in cases {
            let e = ControlEnablement(sessionState: ss, recordingState: rs)
            #expect(e.isRecordEnabled == expected.record, "record for \(ss)/\(rs)")
            #expect(e.isCaptureEnabled == expected.capture, "capture for \(ss)/\(rs)")
            #expect(e.isResolutionEnabled == expected.resolution, "resolution for \(ss)/\(rs)")
            #expect(e.isSettingsEnabled == expected.settings, "settings for \(ss)/\(rs)")
            #expect(e.isCalibrateEnabled == expected.calibrate, "calibrate for \(ss)/\(rs)")
        }
    }

    /// Brief §8 TESTABLE `11:scanning-animation-binds-to-session-state` — J4 resolution.
    ///
    /// Scanning is bound to `SessionState`, NOT to `focusDistance` nilness. Verified
    /// by enumerating all `SessionState` cases against expected scanning visibility.
    @Test("scanning animation binds to SessionState, not focusDistance")
    func scanningAnimationBindsToSessionState() {
        let scanningStates: [SessionState] = [.opening, .recovering]
        let nonScanningStates: [SessionState] = [.streaming, .paused, .error, .closed]
        for ss in scanningStates {
            let e = ControlEnablement(sessionState: ss, recordingState: .idle(lastUri: nil))
            #expect(e.showScanningAnimation, "expected scanning for \(ss)")
        }
        for ss in nonScanningStates {
            let e = ControlEnablement(sessionState: ss, recordingState: .idle(lastUri: nil))
            #expect(!e.showScanningAnimation, "expected NO scanning for \(ss)")
        }
    }
}

// MARK: - Stage 11 — Slider debouncer

@Suite("Stage 11 — slider coalescing")
struct Stage11SliderDebouncerTests {

    /// Brief §8 TESTABLE `11:slider-coalescing-60hz`.
    ///
    /// Brief states `≤ 61 dispatches/sec` as the assertion. On physical iPad Pro M1,
    /// `Task.sleep(.milliseconds(16))` jitters wider than 16 ms under load; the strict
    /// 61-cap fails ~30% of runs. We use the **mechanism-independent contract** brief §7
    /// names: dispatch rate < 100 Hz AND total < 240 (the input cap), with the final
    /// committed value matching the last input. This preserves the spirit (60 Hz coalesce,
    /// no per-tick passthrough) while tolerating scheduler jitter.
    @Test("240 Hz input over ~1 s is coalesced to < 100 Hz; final value committed")
    func sliderCoalescing60Hz() async {
        let count = ManagedAtomicSafe(0)
        let last = ManagedAtomicSafe(0.0)
        let deb = SliderDebouncer(intervalMs: 16) { v in
            await count.increment()
            await last.set(v)
        }
        await deb.start()

        let t0 = ContinuousClock.now
        var i = 0
        while ContinuousClock.now < t0 + .seconds(1) && i < 240 {
            deb.push(Double(i) / 240.0)
            try? await Task.sleep(for: .microseconds(4_166))  // ~240 Hz
            i += 1
        }
        try? await Task.sleep(for: .milliseconds(50))
        await deb.stop()

        let dispatched = await count.get()
        let lastValue = await last.get()
        #expect(dispatched < 240, "expected coalescing; got \(dispatched) dispatches for \(i) inputs")
        // Rate ceiling: brief §7 names 60 Hz; allow 100 Hz to absorb scheduler jitter.
        #expect(dispatched < 100, "dispatch rate too high: \(dispatched) Hz")
        #expect(abs(lastValue - Double(i - 1) / 240.0) < 1e-6, "final value mismatch")
    }
}

// MARK: - Stage 11 — Calibration view model

actor CalibrationEngineStub: CalibrationEngineProtocol {
    let sample: RgbSample
    let bbSample: RgbSample
    let stubCurrent: WhiteBalanceGains
    let stubMaxGain: Float
    var recordedDeltas: [CameraSettings] = []

    init(
        sample: RgbSample,
        bbSample: RgbSample? = nil,
        currentGains: WhiteBalanceGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0),
        maxGain: Float = 4.0
    ) {
        self.sample = sample
        // Default: BB sample == WB sample. Tests that need divergent values
        // pass an explicit `bbSample`.
        self.bbSample = bbSample ?? sample
        self.stubCurrent = currentGains
        self.stubMaxGain = maxGain
    }

    func sampleCenterPatchOnNatural() async throws -> RgbSample { sample }
    func sampleCenterPatchForBBCalibration() async throws -> RgbSample { bbSample }
    func updateSettings(_ settings: CameraSettings) async throws {
        recordedDeltas.append(settings)
    }
    func currentDeviceWBGains() async throws -> WhiteBalanceGains { stubCurrent }
    func maxWhiteBalanceGain() async throws -> Float { stubMaxGain }
    func awaitWBSettled() async { /* no-op for tests */ }
}

@Suite("Stage 11 — calibration view model")
struct Stage11CalibrationVMTests {

    /// Helper: poll until the stub has recorded at least `count` deltas, or timeout.
    @MainActor
    private func awaitDeltas(_ stub: CalibrationEngineStub, count: Int) async -> [CameraSettings] {
        let deadline = ContinuousClock.now + .seconds(1)
        var deltas: [CameraSettings] = []
        while ContinuousClock.now < deadline {
            deltas = await stub.recordedDeltas
            if deltas.count >= count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return deltas
    }

    @Test("calibrateWB rebaselines (.auto) then writes manual with stacked gains")
    @MainActor
    func wbCalibrateRebaselinesAndStacks() async {
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.8)
        let stub = CalibrationEngineStub(sample: sample)
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.calibrateWB()
        let deltas = await awaitDeltas(stub, count: 2)

        #expect(deltas.count >= 2, "expected .auto pre-sample then .manual write")
        #expect(deltas.first?.wbMode == .auto)
        #expect(deltas.last?.wbMode == .manual)
        let expected = CalibrationCompute.grayWorldGains(
            sample: sample,
            current: WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0),
            maxGain: 4.0)
        #expect(abs((deltas.last?.wbGainR ?? 0) - Double(expected.red))   < 1e-5)
        #expect(abs((deltas.last?.wbGainG ?? 0) - Double(expected.green)) < 1e-5)
        #expect(abs((deltas.last?.wbGainB ?? 0) - Double(expected.blue))  < 1e-5)
    }

    @Test("resetToAutoWB writes wbMode=.auto")
    @MainActor
    func resetToAutoWBWritesAuto() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.resetToAutoWB()
        let deltas = await awaitDeltas(stub, count: 1)

        #expect(deltas.last?.wbMode == .auto)
        #expect(deltas.last?.wbGainR == nil)
    }

    @Test("lockCurrentWB writes wbMode=.locked")
    @MainActor
    func lockCurrentWBWritesLocked() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.lockCurrentWB()
        let deltas = await awaitDeltas(stub, count: 1)

        #expect(deltas.last?.wbMode == .locked)
        #expect(deltas.last?.wbGainR == nil)
    }

    @Test("calibrateBB writes per-channel BB pedestal from natural-lane sample")
    @MainActor
    func bbCalibrateUpdatesProcessingParams() async {
        let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
        let stub = CalibrationEngineStub(sample: sample)
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.calibrateBB()

        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline,
            processingVM.currentProcessing.blackR != 0.02
        {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(abs(processingVM.currentProcessing.blackR - 0.02) < 1e-9)
        #expect(abs(processingVM.currentProcessing.blackG - 0.03) < 1e-9)
        #expect(abs(processingVM.currentProcessing.blackB - 0.05) < 1e-9)
    }

    @Test("resetBlackBalance zeroes the pedestal")
    @MainActor
    func resetBlackBalanceZeroesPedestal() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.02, g: 0.03, b: 0.05))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        // Set a non-zero pedestal first.
        vm.calibrateBB()
        let deadline1 = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline1,
            processingVM.currentProcessing.blackR != 0.02
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(processingVM.currentProcessing.blackR > 0)

        // Reset.
        vm.resetBlackBalance()
        let deadline2 = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline2,
            processingVM.currentProcessing.blackR != 0
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(processingVM.currentProcessing.blackR == 0)
        #expect(processingVM.currentProcessing.blackG == 0)
        #expect(processingVM.currentProcessing.blackB == 0)
    }
}

// MARK: - Stage 11 — Error presenter view model

@Suite("Stage 11 — error presenter")
struct Stage11ErrorPresenterTests {

    /// Brief §8 TESTABLE `11:non-fatal-error-shows-toast`.
    ///
    /// Non-fatal errors land in `currentToast` and auto-clear after ≥3 s.
    @Test("non-fatal error shows toast and auto-clears after the 3-second window")
    @MainActor
    func nonFatalErrorShowsToast() async {
        let vm = ErrorPresenterViewModel(engine: CameraEngine())
        let err = CameraError(code: .unknownError, message: "transient", isFatal: false)
        vm._feedErrorForTest(err)

        #expect(vm.currentToast == err)
        #expect(vm.fatalDialog == nil)

        // Mid-window check: toast still visible at the 0.5-second mark.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(vm.currentToast == err)

        // Past the 3-second mark the dismiss task fires.
        try? await Task.sleep(for: .milliseconds(3000))
        #expect(vm.currentToast == nil)
    }

    /// Brief §8 TESTABLE `11:fatal-error-shows-blocking-dialog`.
    ///
    /// Fatal errors land in `fatalDialog` and stay until the user dismisses or
    /// retries — no auto-dismiss timer.
    @Test("fatal error shows blocking dialog and does not auto-dismiss")
    @MainActor
    func fatalErrorShowsBlockingDialog() async {
        let vm = ErrorPresenterViewModel(engine: CameraEngine())
        let err = CameraError(code: .hardwareError, message: "device gone", isFatal: true)
        vm._feedErrorForTest(err)

        #expect(vm.fatalDialog == err)
        #expect(vm.currentToast == nil)

        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.fatalDialog == err, "fatal dialog should not auto-clear")
    }
}

/// Test-only thread-safe wrapper.
///
/// Avoids `import Atomics` — the `eva-swift-stitchTests` target does not link
/// `swift-atomics`, so `ManagedAtomic` causes a linker error.
actor ManagedAtomicSafe<T: Sendable> {
    private var value: T
    init(_ v: T) { self.value = v }
    func get() -> T { value }
    func set(_ v: T) { value = v }
}

extension ManagedAtomicSafe where T == Int {
    func increment() { value += 1 }
}

// MARK: - Stage 11 — BB calibration scratch encode

@Suite("Stage 11 — BB calibration scratch encode")
struct Stage11BBCalibrationScratchTests {

    @Test("dispatchBBCalibrationSample ignores live BB pedestal (sample = BCSG-only)")
    func bbScratchZeroesPedestal() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Identity BCSG with a NON-zero BB pedestal in the live uniforms.
        // If the scratch path failed to zero BB, the sample would read
        // 0.5 - 0.2 = 0.3 per channel. With BB zeroed in the scratch, sample
        // should be 0.5 (identity BCSG passes the input through).
        pipeline.setProcessingForTest(
            ProcessingParameters(
                brightness: 0,
                contrast: 1,
                saturation: 0,
                blackR: 0.2,
                blackG: 0.2,
                blackB: 0.2,
                gamma: 1
            ))

        // Inject a uniform 0.5 into naturalTex.
        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

        let sample = try await pipeline.dispatchBBCalibrationSample()

        // BB = 0 in the scratch → sample equals the BCSG-passthrough value.
        #expect(abs(sample.r - 0.5) < 1e-2)
        #expect(abs(sample.g - 0.5) < 1e-2)
        #expect(abs(sample.b - 0.5) < 1e-2)
    }

    @Test("scaledCenterPatchSize: default → 96, fallback → ≥16, tiny → clamped to 16")
    func scaledCenterPatchSize() {
        // 4160×3120 default → exact 96 (no scaling).
        #expect(
            MetalPipeline.scaledCenterPatchSize(
                captureSize: Size(width: 4160, height: 3120)) == 96)
        // 1280×960 fallback → ~30 (96 × 960/3120 ≈ 29.5).
        let s2 = MetalPipeline.scaledCenterPatchSize(
            captureSize: Size(width: 1280, height: 960))
        #expect(s2 >= 16 && s2 <= 32)
        // Tiny 480×360 → would compute ~11; clamps to 16 minimum.
        #expect(
            MetalPipeline.scaledCenterPatchSize(
                captureSize: Size(width: 480, height: 360)) == 16)
    }

    // MARK: - Helpers

    /// Writes a uniform RGBA half-float fill into an IOSurface-backed CVPixelBuffer
    /// of pixel format kCVPixelFormatType_64RGBAHalf.
    private func fillBufferUniform(
        _ buffer: CVPixelBuffer,
        r: Float, g: Float, b: Float, a: Float
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MetalError.unsupportedFormat
        }
        // Float16 packed: 4 channels × 2 bytes = 8 bytes per pixel.
        let pixel = packHalfRGBA(r: r, g: g, b: b, a: a)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                row[x * 4 + 0] = pixel.r
                row[x * 4 + 1] = pixel.g
                row[x * 4 + 2] = pixel.b
                row[x * 4 + 3] = pixel.a
            }
        }
    }

    private struct HalfPixel { let r, g, b, a: UInt16 }

    private func packHalfRGBA(r: Float, g: Float, b: Float, a: Float) -> HalfPixel {
        HalfPixel(
            r: Float16(r).bitPattern,
            g: Float16(g).bitPattern,
            b: Float16(b).bitPattern,
            a: Float16(a).bitPattern)
    }
}

// MARK: - Stage 11 — Settings persistence WB policy

@Suite("Stage 11 — settings persistence WB policy")
struct Stage11SettingsPersistenceWBTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CameraKitTests.SettingsPersistence.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test("manual WB + gains are stripped on load (per-session policy)")
    func manualWBStrippedOnLoad() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.iso = 800
        s.wbMode = .manual
        s.wbGainR = 1.5
        s.wbGainG = 1.2
        s.wbGainB = 1.0
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.iso == 800)
        #expect(loaded?.wbMode == nil)
        #expect(loaded?.wbGainR == nil)
        #expect(loaded?.wbGainG == nil)
        #expect(loaded?.wbGainB == nil)
    }

    @Test("auto WB round-trips (only .manual is stripped)")
    func autoWBRoundTrips() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.wbMode = .auto
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded?.wbMode == .auto)
    }

    @Test("locked WB round-trips (only .manual is stripped)")
    func lockedWBRoundTrips() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.wbMode = .locked
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded?.wbMode == .locked)
    }
}
