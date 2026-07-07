import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing

@testable import CameraKit

@Suite("Stage04Tests", .progressLogged)
struct Stage04Tests {

    // MARK: - Test 1 — 04:color-pipeline-golden-frame

    /// Inject a known half-float RGBA pattern into naturalTex (via IOSurface).
    ///
    /// Run Pass 2 with identity ProcessingParameters, and assert processedTex
    /// matches naturalTex byte-for-byte modulo rgba16Float ULP. Then apply
    /// brightness=+0.2 and assert the closed-form luminance shift.
    @Test func colorPipelineGoldenFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Identity uniforms → byte-for-byte equality (within rgba16Float ULP).
        pipeline.uniforms.withLock { $0.color = ColorUniform(.identity) }

        // Dequeue a natural buffer from the pool, fill it, then install it as latest.
        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        pipeline.setLatestNaturalForTest(texture: nTex)

        // Dequeue a processed buffer to receive the output.
        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        try await pipeline.encodeGradeOnly()

        // Read processedTex.
        let processedBuf = try #require(pipeline.latestProcessedBufferForTest)
        let (pr, pg, pb, _) = try sampleCenterPixel(processedBuf)
        // rgba16Float ULP at 0.5 ≈ 2^-11 ≈ 4.88e-4. Use 1e-3 tolerance.
        #expect(abs(pr - 0.5) < 1e-3)
        #expect(abs(pg - 0.5) < 1e-3)
        #expect(abs(pb - 0.5) < 1e-3)

        // Brightness +0.2 → exponent = 1 / 1.2 ≈ 0.833. pow(0.5, 0.833) ≈ 0.561.
        var bright = ProcessingParameters.identity
        bright.brightness = 0.2
        pipeline.uniforms.withLock { $0.color = ColorUniform(bright) }
        try await pipeline.encodeGradeOnly()
        let processedBuf2 = try #require(pipeline.latestProcessedBufferForTest)
        let (br, _, _, _) = try sampleCenterPixel(processedBuf2)
        let expected = Float(pow(0.5, 1.0 / 1.2))
        #expect(abs(br - expected) < 5e-3)
    }

    // MARK: - Test 1b — contrast convention (04:contrast-zero-is-identity)

    /// Locks the `[-1, 1]` / `0.0`-identity contrast convention.
    ///
    /// `contrast = 0` must be identity — NOT grey. (The cam2fd grey-frame bug was a
    /// `0.0` default reaching the old `[0, 2]` / `1.0`-identity shader as
    /// zero-contrast, collapsing every pixel to 0.5.) `-1` is fully flat grey
    /// (0.5); `+1` is 2× around the 0.5 midpoint. Input is 0.75 (off the 0.5
    /// pivot) so contrast actually moves the value.
    @Test func contrastConventionIdentityAtZero() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.75, g: 0.75, b: 0.75, a: 1.0)
        pipeline.setLatestNaturalForTest(texture: nTex)

        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        func centerR(contrast: Double) async throws -> Float {
            var params = ProcessingParameters.identity
            params.contrast = contrast
            pipeline.uniforms.withLock { $0.color = ColorUniform(params) }
            try await pipeline.encodeGradeOnly()
            let buf = try #require(pipeline.latestProcessedBufferForTest)
            return try sampleCenterPixel(buf).0
        }

        // contrast = 0 → identity → input unchanged (0.75), NOT grey (0.5).
        let identity = try await centerR(contrast: 0.0)
        #expect(abs(identity - 0.75) < 1e-3, "contrast=0 must be identity, got \(identity)")

        // contrast = -1 → fully flat grey → 0.5.
        let flat = try await centerR(contrast: -1.0)
        #expect(abs(flat - 0.5) < 1e-3, "contrast=-1 must be flat grey, got \(flat)")

        // contrast = +1 → 2× around 0.5 → (0.75-0.5)*2+0.5 = 1.0.
        let boosted = try await centerR(contrast: 1.0)
        #expect(abs(boosted - 1.0) < 1e-3, "contrast=+1 must be 2x, got \(boosted)")
    }

    // MARK: - Test 2 — 04:processing-params-persistence-roundtrip

    /// save → load returns identical struct; empty store returns nil.
    @Test func processingParamsPersistenceRoundtrip() {
        let suiteName = "CameraKit.Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsPersistence.loadProcessing(defaults: defaults) == nil)

        var p = ProcessingParameters.identity
        p.brightness = 0.25
        p.contrast = 0.4
        p.saturation = -0.3
        p.gamma = 1.8
        p.blackPointR = 0.05
        p.blackPointEnabled = true
        SettingsPersistence.saveProcessing(p, defaults: defaults)
        let loaded = SettingsPersistence.loadProcessing(defaults: defaults)
        #expect(loaded == p)
    }

    // MARK: - Test 3 — 04:center-patch-trimmed-mean

    /// Inject a uniform fill into processedTex (R=0.4, G=0.6, B=0.2).
    ///
    /// dispatchCenterPatch returns (0.4, 0.6, 0.2) within ULP.
    /// Then inject a gradient + 10% outliers; trimmed mean discards them.
    @Test func centerPatchTrimmedMean() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)  // > centerPatchSizePx so center fits
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Dequeue a processed buffer from the pool, fill it, then install it as latest.
        let (pBuf1, pTex1) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)

        // Uniform fill — trimmed mean exactly equals the fill value.
        try fillBufferUniform(pBuf1, r: 0.4, g: 0.6, b: 0.2, a: 1.0)
        pipeline.setLatestProcessedForTest(buffer: pBuf1, texture: pTex1)
        let s1 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s1.r - 0.4) < 1e-3)
        #expect(abs(s1.g - 0.6) < 1e-3)
        #expect(abs(s1.b - 0.2) < 1e-3)

        // Outliers test: 95% of pixels at 0.5, 5% at 1.0. The patch on a
        // 256×256 capture is 16×16 = 256 samples (see scaledCenterPatchSize),
        // trim = Int(256 * centerPatchTrimRatio) = Int(256 * 0.075) = 19
        // discarded from each end. 5% of 256 ≈ 13 outliers — the high-end
        // trim eats all of them and an extra slice of 0.5s, while the
        // low-end trim drops 19 more 0.5s. Mean of the remaining 218
        // samples is exactly 0.5. outlierFraction must stay strictly below
        // centerPatchTrimRatio (with a stride-placement safety margin) or
        // residual outliers leak through and the mean drifts.
        let (pBuf2, pTex2) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        try fillBufferWithOutliers(pBuf2, base: 0.5, outlier: 1.0, outlierFraction: 0.05)
        pipeline.setLatestProcessedForTest(buffer: pBuf2, texture: pTex2)
        let s2 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s2.r - 0.5) < 1e-3)
        #expect(abs(s2.g - 0.5) < 1e-3)
        #expect(abs(s2.b - 0.5) < 1e-3)
    }

    // MARK: - Test 4 — 04:set-crop-region-true-crop

    /// P2a true crop: a pipeline built with a crop region carries the crop
    /// origin in its CropUniform and sizes its output textures to the crop, NOT
    /// the sensor.
    ///
    /// Semantics changed from the Stage-04 black-out masking — the output
    /// resolution IS the crop-region size. Engine-level rects that are
    /// out-of-bounds or odd-coordinate throw `EngineError`.
    @Test func setCropRegionTrueCrop() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)

        // Build a cropped pipeline the way CameraEngine.setCropRegion now does.
        let rect = Rect(x: 100, y: 50, width: 800, height: 600)
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: sensor,
            outputSize: Size(width: rect.width, height: rect.height),
            cropOrigin: (rect.x, rect.y),
            gateOpen: true
        )

        // Sensor size is preserved; output size = crop size; origin carried.
        #expect(pipeline.captureSize == sensor)
        #expect(pipeline.outputSize == Size(width: 800, height: 600))
        #expect(pipeline.cropOrigin.x == 100)
        #expect(pipeline.cropOrigin.y == 50)

        // The crop uniform carries the origin (set once at construction).
        let (ox, oy) = pipeline.uniforms.withLock { s in (s.crop.originX, s.crop.originY) }
        #expect(ox == 100)
        #expect(oy == 50)

        // Engine-level out-of-bounds throw — exercise via CameraEngine when
        // session is nil → notOpen path. (Open path requires camera hardware.)
        let engine = CameraEngine(initialPhase: .active)
        let oob = Rect(x: 0, y: 0, width: 99999, height: 99999)
        await #expect(throws: EngineError.self) {
            try await engine.setCropRegion(oob)
        }
    }

    // MARK: - Test 4b — 04:set-crop-region-rejects-odd-coords

    /// P2a: odd crop coordinates are rejected (4:2:0 chroma alignment).
    ///
    /// An odd luma offset/extent would skew the half-resolution chroma plane
    /// sampling. On an unopened engine the call short-circuits on the
    /// `notOpen` guard, so this asserts `EngineError` like the OOB case (an
    /// opened engine maps the same rect to `.settingsConflict`).
    @Test func setCropRegionRejectsOddCoords() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let odd = Rect(x: 1, y: 0, width: 800, height: 600)
        await #expect(throws: EngineError.self) {
            try await engine.setCropRegion(odd)
        }
    }

    // MARK: - Test 4c — 04:default-crop-is-full-frame

    /// A pipeline built without a crop has output = capture (no crop applied).
    @Test func defaultCropIsFullFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)
        let pipeline = try MetalPipeline(device: device, captureSize: sensor, gateOpen: true)
        #expect(pipeline.outputSize == sensor)
        #expect(pipeline.cropOrigin.x == 0)
        #expect(pipeline.cropOrigin.y == 0)
    }

    // MARK: - Test 4d — 04:resolution-rebuild-drops-prior-crop

    /// A resolution change drops any active crop (measurements 2026-05-20 §1, P2a).
    ///
    /// `setResolution` rebuilds the pipeline with no `outputSize`/`cropOrigin`,
    /// so the new pipeline defaults to full-frame and `activeCropRect(for:)` —
    /// the single source of truth for the published `StreamConfiguration` — reads
    /// full-frame from it. This pins that structural guarantee at the pipeline
    /// level (the engine-level "StreamConfiguration emits full-frame" path needs
    /// an open session and is covered by HITL, not unit tests).
    @Test func resolutionRebuildDropsPriorCrop() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)

        // 1. A cropped pipeline, built the way setCropRegion builds it.
        let cropped = try MetalPipeline(
            device: device,
            captureSize: sensor,
            outputSize: Size(width: 800, height: 600),
            cropOrigin: (100, 50),
            gateOpen: true)
        #expect(cropped.outputSize == Size(width: 800, height: 600))

        // 2. Rebuilt the way setResolution builds it — no crop args → full frame.
        let rebuilt = try MetalPipeline(device: device, captureSize: sensor, gateOpen: true)
        #expect(rebuilt.outputSize == sensor)
        #expect(rebuilt.cropOrigin.x == 0)
        #expect(rebuilt.cropOrigin.y == 0)
    }

    // MARK: - Test 1c — linear-normalization-stage: fused affine in linear light

    /// The normalization block applies `out = a·x + b` in LINEAR light (gamma
    /// undone first), gated by `normalizeEnabled`. Drive a known gamma input
    /// through `colorTransform` with a known affine and assert the output matches
    /// an independent Swift reference (linearize → affine → clamp[0,1] → re-encode),
    /// grade held at identity.
    @Test func normalizationAffineInLinearLight() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        let input: Float = 0.5  // gamma-encoded input
        try fillBufferUniform(nBuf, r: input, g: input, b: input, a: 1.0)
        pipeline.setLatestNaturalForTest(texture: nTex)

        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        // a = chroma·level = 1·2 = 2; b = −a·bp = −2·0.05 = −0.1 (blackPoint).
        // White point is gated by chroma (D4: "level without chroma" is inert), so
        // enable chroma (identity 1·) alongside the level to realize the gain of 2.
        var params = ProcessingParameters.identity
        params.wbChromaEnabled = true
        params.wbChromaR = 1.0
        params.wbChromaG = 1.0
        params.wbChromaB = 1.0
        params.whitePointEnabled = true
        params.whitePointLevel = 2.0
        params.blackPointEnabled = true
        params.blackPointR = 0.05
        params.blackPointG = 0.05
        params.blackPointB = 0.05
        pipeline.uniforms.withLock { $0.color = ColorUniform(params) }
        try await pipeline.encodeGradeOnly()

        let buf = try #require(pipeline.latestProcessedBufferForTest)
        let (r, _, _, _) = try sampleCenterPixel(buf)

        // Independent reference: linearize → a·x+b → clamp[0,1] → re-encode.
        let lin = srgbToLinearRef(input)
        let affined = min(max(2.0 * lin - 0.1, 0.0), 1.0)
        let expected = srgbEncodeRef(affined)
        #expect(abs(r - expected) < 3e-3, "normalized R \(r) != reference \(expected)")
    }

    /// `normalizeEnabled` with an identity affine (a=1, b=0) must round-trip the
    /// input — confirming the shader's piecewise sRGB linearize/encode helpers are
    /// true inverses on-device. A `pow(2.2)` shortcut would fail this near black,
    /// so the input is deliberately in the near-black region.
    @Test func normalizationSrgbRoundTripIsIdentity() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        let input: Float = 0.03  // near-black: piecewise sRGB linear segment matters here
        try fillBufferUniform(nBuf, r: input, g: input, b: input, a: 1.0)
        pipeline.setLatestNaturalForTest(texture: nTex)

        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        // a=1, b=0, but normalizeEnabled=1 (wbChroma on with identity gains).
        var params = ProcessingParameters.identity
        params.wbChromaEnabled = true  // gains default 1.0 → a=1, b=0
        pipeline.uniforms.withLock { $0.color = ColorUniform(params) }
        let cu = pipeline.uniforms.withLock { $0.color }
        #expect(cu.normalizeEnabled == 1 && cu.aR == 1 && cu.bR == 0, "expected gated identity affine")

        try await pipeline.encodeGradeOnly()
        let buf = try #require(pipeline.latestProcessedBufferForTest)
        let (r, _, _, _) = try sampleCenterPixel(buf)
        #expect(abs(r - input) < 2e-3, "sRGB round-trip not identity: \(r) vs \(input)")
    }

    /// End-to-end golden test of the fused normalization affine over **specific,
    /// per-channel-distinct RGB patches** run through several parameter sets, each
    /// checked on all three channels against an independent Double-precision Swift
    /// reference (host affine composition → linearize → a·x+b → clamp → re-encode),
    /// with the creative grade held at identity so the output reflects normalization
    /// alone. Exercises real combinations a uniform-grey patch can't: per-channel
    /// black point, chroma neutralization of a colored field, white-point lift, and
    /// all three fused together.
    @Test func fusedNormalizationPatchCases() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)

        // Two specific, per-channel-distinct gamma-encoded R'G'B' patches.
        let colors: [(name: String, r: Float, g: Float, b: Float)] = [
            ("warm", 0.60, 0.40, 0.20),
            ("cool", 0.20, 0.50, 0.80),
        ]
        let targetGamma = Float(Constants.whitePointTargetDisplay)

        for color in colors {
            // Per-color linear values + the chroma gains that neutralize THIS color
            // (brightness-preserving: meanLin / channel), and the level that lifts the
            // neutralized mean to the white-point target.
            let lr = Double(srgbToLinearRef(color.r))
            let lg = Double(srgbToLinearRef(color.g))
            let lb = Double(srgbToLinearRef(color.b))
            let meanLin = (lr + lg + lb) / 3.0
            let targetLin = CalibrationCompute.srgbToLinear(Constants.whitePointTargetDisplay)

            // Case 1 — black point only (per-channel offset, a = 1).
            var blackOnly = ProcessingParameters.identity
            blackOnly.blackPointEnabled = true
            blackOnly.blackPointR = 0.02
            blackOnly.blackPointG = 0.02
            blackOnly.blackPointB = 0.02

            // Case 2 — chroma only (phase contrast: neutralize, preserve level).
            var chromaOnly = ProcessingParameters.identity
            chromaOnly.wbChromaEnabled = true
            chromaOnly.wbChromaR = meanLin / lr
            chromaOnly.wbChromaG = meanLin / lg
            chromaOnly.wbChromaB = meanLin / lb

            // Case 3 — chroma + white point (brightfield: lift to the white target).
            var brightfield = chromaOnly
            brightfield.whitePointEnabled = true
            brightfield.whitePointLevel = targetLin / meanLin

            // Case 4 — all three fused (black point + chroma + white point).
            var combined = brightfield
            combined.blackPointEnabled = true
            combined.blackPointR = 0.01
            combined.blackPointG = 0.01
            combined.blackPointB = 0.01

            let cases: [(name: String, params: ProcessingParameters)] = [
                ("blackPoint", blackOnly),
                ("chromaNeutralize", chromaOnly),
                ("brightfield", brightfield),
                ("combined", combined),
            ]

            for testCase in cases {
                let p = testCase.params
                // Independent per-channel a/b — re-derive the HOST composition (D2/D4)
                // in Double, so this reference also validates ColorUniform.init, not
                // just the shader. level is gated by chroma; b = −a·blackPoint.
                let level = (p.whitePointEnabled && p.wbChromaEnabled) ? p.whitePointLevel : 1.0
                func ab(_ chroma: Double, _ bp: Double) -> (a: Double, b: Double) {
                    let a = (p.wbChromaEnabled ? chroma : 1.0) * level
                    let b = -a * (p.blackPointEnabled ? bp : 0.0)
                    return (a, b)
                }
                let cR = ab(p.wbChromaR, p.blackPointR)
                let cG = ab(p.wbChromaG, p.blackPointG)
                let cB = ab(p.wbChromaB, p.blackPointB)
                let eR = fusedNormalizeRef(color.r, a: cR.a, b: cR.b)
                let eG = fusedNormalizeRef(color.g, a: cG.a, b: cG.b)
                let eB = fusedNormalizeRef(color.b, a: cB.a, b: cB.b)

                // Drive the patch through the GPU fused kernel (grade at identity).
                let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)
                let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
                    pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
                try fillBufferUniform(nBuf, r: color.r, g: color.g, b: color.b, a: 1.0)
                pipeline.setLatestNaturalForTest(texture: nTex)
                let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
                    pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
                pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)
                pipeline.uniforms.withLock { $0.color = ColorUniform(p) }
                try await pipeline.encodeGradeOnly()

                let out = try #require(pipeline.latestProcessedBufferForTest)
                let (gr, gg, gb, _) = try sampleCenterPixel(out)

                let tag = "\(color.name)/\(testCase.name)"
                let tol: Float = 3e-3
                #expect(abs(gr - eR) < tol, "\(tag) R: gpu \(gr) != ref \(eR)")
                #expect(abs(gg - eG) < tol, "\(tag) G: gpu \(gg) != ref \(eG)")
                #expect(abs(gb - eB) < tol, "\(tag) B: gpu \(gb) != ref \(eB)")

                // Cross-checks via an independent path (not the a·x+b reference):
                switch testCase.name {
                case "chromaNeutralize":
                    // Chroma alone equalizes the channels (neutral grey), level preserved.
                    #expect(
                        abs(gr - gg) < 5e-3 && abs(gg - gb) < 5e-3,
                        "\(tag): chroma should neutralize to grey, got (\(gr), \(gg), \(gb))")
                case "brightfield":
                    // Chroma + level lands every channel on the white-point target.
                    #expect(abs(gr - targetGamma) < 5e-3, "\(tag) R off target \(gr)")
                    #expect(abs(gg - targetGamma) < 5e-3, "\(tag) G off target \(gg)")
                    #expect(abs(gb - targetGamma) < 5e-3, "\(tag) B off target \(gb)")
                default:
                    break
                }
            }
        }
    }

    // MARK: - Test 5 — kernel-fusion: fused core ≡ separate core

    /// The fused `yuvGradedFused` kernel (decode→grade→pack in one dispatch) must
    /// reproduce the pre-fusion three-encoder core (`yuvToRgba`→`colorTransform`→
    /// `rgba16fToBgra8`) on the SAME YUV input. Runs both on identical y/cbcr planes
    /// through `encodeCoreComparisonForTest` and asserts:
    ///   • fused natural ≡ separate natural (both store 16F(decode) — byte-identical);
    ///   • fused natural ≡ an independent hand-computed BT.601 decode — the chroma-rich
    ///     input exercises the matrix, so this catches COEFFICIENT drift in the
    ///     DUPLICATED `decodeYuvBt601` (crop-ORIGIN drift is caught separately by
    ///     `fusedCropOriginMatchesSeparate`, which this test can't — input is uniform);
    ///   • fused processed ≡ separate processed within 1e-3 (they differ by ≲ one 16F
    ///     ULP because fused grades the f32 register, separate grades the 16F texture —
    ///     see the `yuvGradedFused` precision note; NOT byte-identical, by construction).
    /// Covers grade identity AND a full non-trivial grade+normalization, over a neutral
    /// and a chroma-rich input.
    @Test func fusedVsSeparateCoreEquivalence() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)

        // Non-trivial grade + normalization (all three normalization ops on).
        var full = ProcessingParameters.identity
        full.brightness = 0.3
        full.contrast = 0.2
        full.saturation = -0.1
        full.gamma = 1.2
        full.blackPointEnabled = true
        full.blackPointR = 0.02
        full.blackPointG = 0.02
        full.blackPointB = 0.02
        full.wbChromaEnabled = true
        full.wbChromaR = 1.1
        full.wbChromaG = 1.0
        full.wbChromaB = 0.9
        full.whitePointEnabled = true
        full.whitePointLevel = 1.3

        let colors: [(name: String, y: Float, cb: Float, cr: Float)] = [
            ("neutral", 0.50, 0.50, 0.50),  // grey: Cb=Cr=0 after centering
            ("chroma", 0.55, 0.40, 0.65),  // colored: exercises the BT.601 matrix
        ]
        let configs: [(name: String, params: ProcessingParameters)] = [
            ("identity", .identity),
            ("full", full),
        ]

        for color in colors {
            let (yTex, cbcrTex, yQ, cbQ, crQ) = makeYCbCrTextures(
                device: device, width: size.width, height: size.height,
                y: color.y, cb: color.cb, cr: color.cr)

            // Independent BT.601 decode from the QUANTIZED unorm8 samples the GPU reads.
            let cbC = cbQ - 0.5
            let crC = crQ - 0.5
            let rRef = yQ + 1.402 * crC
            let gRef = yQ - 0.344136 * cbC - 0.714136 * crC
            let bRef = yQ + 1.772 * cbC

            for config in configs {
                let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)
                let color32 = ColorUniform(config.params)
                let crop = pipeline.uniforms.withLock { $0.crop }

                let cmp = try await pipeline.encodeCoreComparisonForTest(
                    y: yTex, cbcr: cbcrTex, size: size, color: color32, crop: crop)

                let tag = "\(color.name)/\(config.name)"

                // Natural: fused ≡ separate (byte-identical), and ≡ hand BT.601.
                let (sNr, sNg, sNb, _) = try sampleCenterPixel(cmp.separateNatural)
                let (fNr, fNg, fNb, _) = try sampleCenterPixel(cmp.fusedNatural)
                #expect(abs(fNr - sNr) < 1e-4, "\(tag) natural R fused \(fNr) != sep \(sNr)")
                #expect(abs(fNg - sNg) < 1e-4, "\(tag) natural G fused \(fNg) != sep \(sNg)")
                #expect(abs(fNb - sNb) < 1e-4, "\(tag) natural B fused \(fNb) != sep \(sNb)")
                #expect(abs(fNr - rRef) < 2e-3, "\(tag) natural R \(fNr) != BT.601 \(rRef)")
                #expect(abs(fNg - gRef) < 2e-3, "\(tag) natural G \(fNg) != BT.601 \(gRef)")
                #expect(abs(fNb - bRef) < 2e-3, "\(tag) natural B \(fNb) != BT.601 \(bRef)")

                // Processed: fused ≡ separate within 1e-3 (the fusion equivalence claim).
                let (sPr, sPg, sPb, _) = try sampleCenterPixel(cmp.separateProcessed)
                let (fPr, fPg, fPb, _) = try sampleCenterPixel(cmp.fusedProcessed)
                #expect(abs(fPr - sPr) < 1e-3, "\(tag) processed R fused \(fPr) != sep \(sPr)")
                #expect(abs(fPg - sPg) < 1e-3, "\(tag) processed G fused \(fPg) != sep \(sPg)")
                #expect(abs(fPb - sPb) < 1e-3, "\(tag) processed B fused \(fPb) != sep \(sPb)")
            }
        }
    }

    // MARK: - Test 5b — kernel-fusion: crop-origin parity

    /// A cropped pipeline (captureSize > outputSize, non-zero non-square origin) run
    /// over a spatially-varying luma gradient. The fused `decodeYuvBt601` and the
    /// separate `yuvToRgba` both map output pixel → `gid + cropOrigin`; a crop-origin
    /// typo in EITHER duplicated copy (e.g. `gid.x + crop.originY`) reads a different
    /// source pixel of the gradient, so fused-vs-separate diverges and this fails.
    /// `fusedVsSeparateCoreEquivalence` can't catch that (uniform input, origin 0).
    @Test func fusedCropOriginMatchesSeparate() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let capture = Size(width: 64, height: 64)
        let output = Size(width: 32, height: 32)
        let origin = (x: 16, y: 8)  // even (4:2:0) and non-square so an X/Y swap diverges

        let pipeline = try MetalPipeline(
            device: device, captureSize: capture,
            outputSize: output, cropOrigin: origin, gateOpen: true)
        let crop = pipeline.uniforms.withLock { $0.crop }

        // Horizontal luma gradient Y(x) = x/width; uniform neutral chroma.
        let (yTex, cbcrTex) = makeGradientYCbCrTextures(
            device: device, width: capture.width, height: capture.height)

        let cmp = try await pipeline.encodeCoreComparisonForTest(
            y: yTex, cbcr: cbcrTex, size: output, color: ColorUniform(.identity), crop: crop)

        let (sNr, _, _, _) = try sampleCenterPixel(cmp.separateNatural)
        let (fNr, _, _, _) = try sampleCenterPixel(cmp.fusedNatural)
        #expect(abs(fNr - sNr) < 1e-4, "cropped decode diverged: fused \(fNr) vs sep \(sNr)")

        // Anchor to the source: center of the 32² output (cx=16) at origin.x=16 maps
        // to source x = 32; neutral chroma → R = Y(32) = round(32/64·255)/255.
        let srcX = output.width / 2 + origin.x
        let expected = Float(UInt8((Float(srcX) / Float(capture.width) * 255).rounded())) / 255
        #expect(abs(fNr - expected) < 3e-3, "cropped R \(fNr) != source luma \(expected)")
    }

    // MARK: - Test 5c — kernel-fusion: A/B GPU throughput benchmark (informational)

    /// Measures mean GPU wall-time per frame of the pre-fusion three-encoder core vs
    /// the fused core, back-to-back in one session at the production 1024² crop size,
    /// so the delta is the fusion saving (fewer full-frame RGBA16F re-reads + fewer
    /// kernel launches) rather than run-to-run thermal drift. Informational: the guard
    /// only asserts fusion is not materially SLOWER (perf numbers are inherently noisy);
    /// the actual per-frame microseconds are printed for the record.
    @Test func fusedCoreThroughputBenchmark() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1024, height: 1024)  // production center-crop size
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Chroma-rich input + a full non-trivial grade so the measured cost reflects
        // the real steady-state pointwise chain (normalization + BCSG), not a no-op.
        let (yTex, cbcrTex, _, _, _) = makeYCbCrTextures(
            device: device, width: size.width, height: size.height, y: 0.55, cb: 0.40, cr: 0.65)
        var full = ProcessingParameters.identity
        full.brightness = 0.3
        full.contrast = 0.2
        full.saturation = -0.1
        full.gamma = 1.2
        full.blackPointEnabled = true
        full.blackPointR = 0.02
        full.blackPointG = 0.02
        full.blackPointB = 0.02
        full.wbChromaEnabled = true
        full.wbChromaR = 1.1
        full.whitePointEnabled = true
        full.whitePointLevel = 1.3
        let crop = pipeline.uniforms.withLock { $0.crop }

        let (sep, fused) = try await pipeline.benchmarkCoresForTest(
            y: yTex, cbcr: cbcrTex, size: size, color: ColorUniform(full), crop: crop,
            iterations: 200)
        let saved = sep - fused
        let pct = sep > 0 ? saved / sep * 100 : 0
        let summary = String(
            format: "[fusion-bench 1024²] separate=%.1fµs/frame fused=%.1fµs/frame saved=%.1fµs (%.1f%%)",
            sep, fused, saved, pct)
        print(summary)
        #expect(fused <= sep * 1.15, "fused core materially slower — \(summary)")
    }

    // MARK: - Helpers

    /// Builds an `r8Unorm` luma plane with a horizontal gradient `Y(x) = x/width`
    /// (byte = round(x/width·255)) + a uniform neutral `rg8Unorm` half-res chroma
    /// plane. The spatial variation is what makes a crop-origin typo observable.
    private func makeGradientYCbCrTextures(
        device: MTLDevice, width: Int, height: Int
    ) -> (yTex: MTLTexture, cbcrTex: MTLTexture) {
        let yDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        yDesc.usage = [.shaderRead]
        let yTex = device.makeTexture(descriptor: yDesc)!
        var yBytes = [UInt8](repeating: 0, count: width * height)
        for x in 0..<width {
            let b = UInt8((Float(x) / Float(width) * 255).rounded())
            for y in 0..<height { yBytes[y * width + x] = b }
        }
        yBytes.withUnsafeBytes {
            yTex.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width)
        }

        let cw = width / 2, ch = height / 2
        let cDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: cw, height: ch, mipmapped: false)
        cDesc.usage = [.shaderRead]
        let cbcrTex = device.makeTexture(descriptor: cDesc)!
        let cBytes = [UInt8](repeating: 128, count: cw * ch * 2)  // Cb=Cr=0.5 → neutral
        cBytes.withUnsafeBytes {
            cbcrTex.replace(
                region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: cw * 2)
        }
        return (yTex, cbcrTex)
    }

    /// Builds standalone `r8Unorm` (luma) + `rg8Unorm` half-res (chroma) MTLTextures
    /// filled with one uniform YCbCr sample, mirroring the NV12 planes the live
    /// decode wraps. Returns the textures plus the QUANTIZED [0,1] sample values the
    /// GPU actually reads (unorm8 round-trip), so the test's reference math matches
    /// the shader input exactly.
    private func makeYCbCrTextures(
        device: MTLDevice, width: Int, height: Int, y: Float, cb: Float, cr: Float
    ) -> (yTex: MTLTexture, cbcrTex: MTLTexture, yQ: Float, cbQ: Float, crQ: Float) {
        let yByte = UInt8((y * 255).rounded())
        let cbByte = UInt8((cb * 255).rounded())
        let crByte = UInt8((cr * 255).rounded())

        let yDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        yDesc.usage = [.shaderRead]
        let yTex = device.makeTexture(descriptor: yDesc)!
        let yBytes = [UInt8](repeating: yByte, count: width * height)
        yBytes.withUnsafeBytes {
            yTex.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width)
        }

        let cw = width / 2, ch = height / 2
        let cDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: cw, height: ch, mipmapped: false)
        cDesc.usage = [.shaderRead]
        let cbcrTex = device.makeTexture(descriptor: cDesc)!
        var cBytes = [UInt8](repeating: 0, count: cw * ch * 2)
        for i in 0..<(cw * ch) {
            cBytes[i * 2] = cbByte
            cBytes[i * 2 + 1] = crByte
        }
        cBytes.withUnsafeBytes {
            cbcrTex.replace(
                region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: cw * 2)
        }
        return (yTex, cbcrTex, Float(yByte) / 255, Float(cbByte) / 255, Float(crByte) / 255)
    }

    /// Writes a uniform `base` fill, then overwrites a fraction of pixels
    /// with `outlier` value (used to verify trimmed-mean discard).
    private func fillBufferWithOutliers(
        _ buffer: CVPixelBuffer,
        base: Float, outlier: Float,
        outlierFraction: Double
    ) throws {
        try fillBufferUniform(buffer, r: base, g: base, b: base, a: 1.0)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base0 = CVPixelBufferGetBaseAddress(buffer) else { return }
        let outlierPx = packHalfRGBA(r: outlier, g: outlier, b: outlier, a: 1.0)
        let total = width * height
        let outlierCount = Int(Double(total) * outlierFraction)
        // Sprinkle outliers uniformly across the image — every Nth pixel.
        let stride = max(1, total / max(outlierCount, 1))
        var writes = 0
        for i in Swift.stride(from: 0, to: total, by: stride) where writes < outlierCount {
            let y = i / width
            let x = i % width
            let row = base0.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            row[x * 4 + 0] = outlierPx.r
            row[x * 4 + 1] = outlierPx.g
            row[x * 4 + 2] = outlierPx.b
            row[x * 4 + 3] = outlierPx.a
            writes += 1
        }
    }

    /// Reads the (R, G, B, A) at the center pixel of an RGBA16F IOSurface buffer.
    private func sampleCenterPixel(_ buffer: CVPixelBuffer) throws -> (Float, Float, Float, Float) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MetalError.unsupportedFormat
        }
        let cx = width / 2
        let cy = height / 2
        let row = base.advanced(by: cy * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        return (
            unpackHalf(row[cx * 4 + 0]),
            unpackHalf(row[cx * 4 + 1]),
            unpackHalf(row[cx * 4 + 2]),
            unpackHalf(row[cx * 4 + 3])
        )
    }

    // MARK: - Float16 packing helpers

    private func unpackHalf(_ bits: UInt16) -> Float {
        Float(Float16(bitPattern: bits))
    }

    // MARK: - sRGB reference (mirrors ColorShaders.metal srgbToLinear / linearToSrgb)

    /// gamma → linear (true piecewise sRGB, computed in Double for reference precision).
    private func srgbToLinearRef(_ c: Float) -> Float {
        let x = Double(c)
        return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    }

    /// linear → gamma (true piecewise sRGB, computed in Double for reference precision).
    private func srgbEncodeRef(_ c: Float) -> Float {
        let x = Double(c)
        return Float(x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055)
    }

    /// Independent reference for the shader's normalization block on one channel:
    /// linearize → `a·x + b` (in linear light) → clamp[0,1] → re-encode. Mirrors the
    /// `colorTransform` kernel's step 0; `a`/`b` are the caller's host-composed affine.
    private func fusedNormalizeRef(_ input: Float, a: Double, b: Double) -> Float {
        let lin = Double(srgbToLinearRef(input))
        let affined = min(max(a * lin + b, 0.0), 1.0)
        return srgbEncodeRef(Float(affined))
    }
}
