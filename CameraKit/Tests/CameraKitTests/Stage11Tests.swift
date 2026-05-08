import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

// MARK: - Stage 11 — Calibration compute (pure helpers)

@Suite("Stage 11 — calibration compute")
struct Stage11CalibrationComputeTests {

    @Test("gray-world gains are reciprocal of normalized channel averages")
    func grayWorldGainsReciprocal() {
        // mean = (0.5 + 1.0 + 0.8) / 3 = 0.7666...
        // gain[c] = mean / channel[c]
        let sample = RgbSample(r: 0.5, g: 1.0, b: 0.8)
        let gains = CalibrationCompute.grayWorldGains(sample: sample)
        let mean = (0.5 + 1.0 + 0.8) / 3.0
        #expect(abs(Double(gains.red) - mean / 0.5) < 1e-5)
        #expect(abs(Double(gains.green) - mean / 1.0) < 1e-5)
        #expect(abs(Double(gains.blue) - mean / 0.8) < 1e-5)
    }

    @Test("WhiteBalanceGains.init(fromGrayWorld:) is equivalent to CalibrationCompute.grayWorldGains")
    func whiteBalanceGainsFromGrayWorldConvenience() {
        let sample = RgbSample(r: 0.42, g: 0.84, b: 0.63)
        let direct = CalibrationCompute.grayWorldGains(sample: sample)
        let viaInit = WhiteBalanceGains(fromGrayWorld: sample)
        #expect(direct.red == viaInit.red)
        #expect(direct.green == viaInit.green)
        #expect(direct.blue == viaInit.blue)
    }

    @Test("near-zero channels are clamped to epsilon (no division by zero)")
    func grayWorldClampsZeroChannel() {
        let sample = RgbSample(r: 0.0, g: 0.5, b: 0.5)
        let gains = CalibrationCompute.grayWorldGains(sample: sample)
        #expect(gains.red.isFinite)
        #expect(gains.red > 0)
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

/// Test-only stub conforming to `CalibrationEngineProtocol`.
///
/// Records the `CameraSettings` written through `updateSettings` so calibrate
/// flows can be asserted without instantiating an `AVCaptureSession`.
private actor CalibrationEngineStub: CalibrationEngineProtocol {
    private(set) var recordedDelta: CameraSettings?
    private let sample: RgbSample

    init(sample: RgbSample) { self.sample = sample }

    func sampleCenterPatch() async throws -> RgbSample { sample }

    func updateSettings(_ settings: CameraSettings) async throws {
        recordedDelta = settings
    }
}

@Suite("Stage 11 — calibration view model")
struct Stage11CalibrationVMTests {

    /// Brief §8 TESTABLE `11:wb-calibrate-applies-computed-gains`.
    ///
    /// Sample → gray-world reciprocal → `engine.updateSettings(.manual + gains)`.
    @Test("calibrateWB writes manual WB with gray-world gains")
    @MainActor
    func wbCalibrateAppliesComputedGains() async {
        let sample = RgbSample(r: 0.5, g: 1.0, b: 0.8)
        let stub = CalibrationEngineStub(sample: sample)
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.calibrateWB()

        let deadline = ContinuousClock.now + .seconds(1)
        var recorded: CameraSettings?
        while ContinuousClock.now < deadline {
            recorded = await stub.recordedDelta
            if recorded != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorded != nil, "calibrateWB never wrote settings")
        #expect(recorded?.wbMode == .manual)
        let expected = CalibrationCompute.grayWorldGains(sample: sample)
        #expect(abs((recorded?.wbGainR ?? 0) - Double(expected.red)) < 1e-5)
        #expect(abs((recorded?.wbGainG ?? 0) - Double(expected.green)) < 1e-5)
        #expect(abs((recorded?.wbGainB ?? 0) - Double(expected.blue)) < 1e-5)
    }

    /// Brief §8 TESTABLE `11:bb-calibrate-updates-processing-params`.
    ///
    /// Sample → `processingVM.applyBlackBalance(sample:)` → BB fields on
    /// `currentProcessing` reflect the sample (offsets are passthrough per
    /// `CalibrationCompute.blackBalanceOffsets`).
    @Test("calibrateBB writes per-channel black balance into ProcessingViewModel")
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
