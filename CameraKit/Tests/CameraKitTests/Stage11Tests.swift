import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

// MARK: - Stage 11 — Calibration compute (pure helpers)

@Suite("Stage 11 — calibration compute", .progressLogged)
struct Stage11CalibrationComputeTests {

    // Identity gains — useful for tests that want the reciprocal-only behavior
    // without the stacking multiplier.
    private let unityGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    private let typicalMax: Float = 4.0

    @Test("neutral linear sample with unity current gains returns unity (no-op)")
    func grayWorldNeutralLinearSampleIsNoOp() {
        // For r==g==b the mean ratio is exactly 1, so newGain == current
        // regardless of any input scaling.
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

    // MARK: - linear-normalization-stage: statistical black point

    @Test("black point: uniform dark field → offset = linearized value (σ = 0, no margin)")
    func blackPointUniformField() {
        let w = 128, h = 128
        let g: Float = 0.03  // gamma-encoded
        let pixels = [SIMD3<Float>](repeating: SIMD3<Float>(g, g, g), count: w * h)
        let off = CalibrationCompute.blackPointOffsets(
            pixels: pixels, width: w, height: h, patch: Constants.centerPatchSizePx)
        // Uniform ⇒ σ ≈ 0 ⇒ offset ≈ mean = linearized value. Tolerance 1e-8 (not
        // 1e-9): the single-pass variance (E[x²]−E[x]²) leaves a ~1.5e-9 residual
        // on a perfectly-uniform field, an utterly negligible black-point margin
        // (~6 orders below 8-bit precision).
        let expected = CalibrationCompute.srgbToLinear(Double(g))
        #expect(abs(off.r - expected) < 1e-8)
        #expect(abs(off.g - expected) < 1e-8)
        #expect(abs(off.b - expected) < 1e-8)
    }

    @Test("black point: per-pixel gate drops a pixel bright in ANY channel")
    func blackPointPerPixelGate() {
        let w = 128, h = 128
        let bg: Float = 0.03
        var pixels = [SIMD3<Float>](repeating: SIMD3<Float>(bg, bg, bg), count: w * h)
        // Pixels dark in R/G (0.2 < 0.3) but bright in B (0.6 > 0.3), inside the
        // patch. The per-PIXEL gate must drop them wholesale — their dark R/G must
        // NOT pull the R/G offset off the background (a per-channel gate would).
        let half = Constants.centerPatchSizePx / 2
        let cx = w / 2, cy = h / 2
        for y in 0..<h {
            for x in 0..<w {
                let inPatch = abs(x - cx) < half && abs(y - cy) < half
                if inPatch && (y * w + x) % 5 == 0 {
                    pixels[y * w + x] = SIMD3<Float>(0.2, 0.2, 0.6)
                }
            }
        }
        let off = CalibrationCompute.blackPointOffsets(
            pixels: pixels, width: w, height: h, patch: Constants.centerPatchSizePx)
        let expected = CalibrationCompute.srgbToLinear(Double(bg))
        #expect(abs(off.r - expected) < 1e-8, "R pulled by a B-bright pixel: \(off.r)")
        #expect(abs(off.g - expected) < 1e-8, "G pulled by a B-bright pixel: \(off.g)")
        #expect(abs(off.b - expected) < 1e-8, "B pulled by a B-bright pixel: \(off.b)")
    }

    @Test("black point: offset = mean + k·σ over the masked set")
    func blackPointSigmaMargin() {
        let w = 128, h = 128
        // Balanced two-level background (0.02 / 0.04 gamma) so σ > 0.
        var pixels = [SIMD3<Float>](repeating: SIMD3<Float>(0.02, 0.02, 0.02), count: w * h)
        for i in 0..<pixels.count where i % 2 == 0 {
            pixels[i] = SIMD3<Float>(0.04, 0.04, 0.04)
        }
        let off = CalibrationCompute.blackPointOffsets(
            pixels: pixels, width: w, height: h, patch: Constants.centerPatchSizePx)
        let l02 = CalibrationCompute.srgbToLinear(0.02)
        let l04 = CalibrationCompute.srgbToLinear(0.04)
        let mean = (l02 + l04) / 2
        let sigma = abs(l04 - l02) / 2  // population std of a balanced two-level set
        let expected = mean + Constants.blackPointSigmaK * sigma
        #expect(abs(off.r - expected) < 1e-6, "offset \(off.r) != mean+kσ \(expected)")
    }
}


// MARK: - Stage 11 — center-patch sizing

@Suite("Stage 11 — center-patch sizing", .progressLogged)
struct Stage11CenterPatchSizingTests {

    @Test("scaledCenterPatchSize: default → 96, fallback → ≥16, tiny → clamped to 16")
    func scaledCenterPatchSize() {
        // 4160×3120 default → exact 96 (no scaling).
        #expect(
            MetalPipeline.scaledCenterPatchSize(
                captureSize: Size(width: 4160, height: 3120)) == 96)
        // 1280×960 fallback: 96 × 960/3120 = 29.538 → round → 30 (above the 16 floor).
        let s2 = MetalPipeline.scaledCenterPatchSize(
            captureSize: Size(width: 1280, height: 960))
        #expect(s2 == 30)
        // Tiny 480×360 → would compute ~11; clamps to 16 minimum.
        #expect(
            MetalPipeline.scaledCenterPatchSize(
                captureSize: Size(width: 480, height: 360)) == 16)
    }

    // Pixel helpers (`fillBufferUniform`, `packHalfRGBA`, `HalfPixel`) live in
    // `TestPixelHelpers.swift` and are shared with `Stage04Tests`.
}

// MARK: - Stage 11 — Family B follow-ups (calibration "no frame yet" semantics)
//
// Covers the post-Family-B rework where both calibration sampling paths refuse
// to sample a blank pool buffer and instead throw `MetalError.noFrameAvailable`.
// Pre-rework, `dispatchCenterPatchOnNatural` would silently sample a (0,0,0)
// pool fallback, biasing WB-calibrate on cold engines.

@Suite("Stage 11 — Family B follow-ups: calibration no-frame semantics", .progressLogged)
struct Stage11FamilyBFollowupCalibrationTests {

    /// `dispatchCenterPatchOnNatural` must refuse to sample when no frame has
    /// arrived — otherwise WB-calibrate on a cold engine would sample a blank
    /// pool buffer and produce (0,0,0).
    @Test("dispatchCenterPatchOnNatural throws .noFrameAvailable before any frame")
    func centerPatchOnNaturalThrowsBeforeFirstFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 256),
            gateOpen: true
        )

        await #expect(throws: MetalError.noFrameAvailable) {
            _ = try await pipeline.dispatchCenterPatchOnNatural()
        }
    }

    /// Once a natural texture is installed, `dispatchCenterPatchOnNatural`
    /// succeeds and reads back the installed pixel values. Confirms the new
    /// guard doesn't regress the happy path.
    @Test("dispatchCenterPatchOnNatural samples installed natural texture")
    func centerPatchOnNaturalSamplesInstalledTexture() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.4, g: 0.6, b: 0.2, a: 1.0)
        pipeline.setLatestNaturalForTest(texture: nTex)

        let sample = try await pipeline.dispatchCenterPatchOnNatural()
        #expect(abs(sample.r - 0.4) < 1e-2)
        #expect(abs(sample.g - 0.6) < 1e-2)
        #expect(abs(sample.b - 0.2) < 1e-2)
    }

    /// `MetalError.textureAllocationFailed` and `.noFrameAvailable` are distinct
    /// cases that can each be caught by name. Guards against accidental
    /// rename/merge in a future cleanup pass.
    @Test("new MetalError cases are distinguishable")
    func newMetalErrorCasesDistinguishable() {
        let alloc: MetalError = .textureAllocationFailed
        let noFrame: MetalError = .noFrameAvailable

        switch alloc {
        case .textureAllocationFailed: break
        default: Issue.record("textureAllocationFailed did not match its own case")
        }
        switch noFrame {
        case .noFrameAvailable: break
        default: Issue.record("noFrameAvailable did not match its own case")
        }
    }
}

// MARK: - Stage 11 — Settings persistence WB policy

@Suite("Stage 11 — settings persistence WB policy", .progressLogged)
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
