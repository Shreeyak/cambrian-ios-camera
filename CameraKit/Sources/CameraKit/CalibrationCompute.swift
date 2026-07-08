import Foundation

/// Pure helpers for white-balance and black-balance calibration math.
///
/// Called from `CalibrationViewModel` (07-settings.md §Calibration). The engine
/// applies `ProcessingParameters` / `CameraSettings`; the math derivation lives
/// here so it stays unit-testable without an `AVCaptureSession`.
public enum CalibrationCompute {

    /// Gray-world reciprocal gains with per-iteration log-cap damping,
    /// stacked onto current device gains.
    ///
    /// Operates in **gamma-encoded sample space**. Linearization was tried and
    /// rejected — see "History" below. The per-iteration log2-space cap
    /// (`Constants.wbGrayWorldLogCap`) bounds the multiplicative gain change
    /// per call to `[2^-k, 2^k]` so a single step can't overshoot into the
    /// `[1.0, maxGain]` hardware boundaries.
    ///
    /// Source: WWDC 2014 §508 + `AVCaptureDevice.h` lines 1244–1434.
    ///
    /// - Parameter sample: per-channel trimmed-mean read from `naturalTex`
    ///   (BT.601 full-range RGB, gamma-encoded by the sensor/ISP).
    /// - Parameter current: WB gains applied by `AVCaptureDevice` at the moment
    ///   the sample was taken — `device.deviceWhiteBalanceGains`.
    /// - Parameter maxGain: `device.maxWhiteBalanceGain` — used for the final
    ///   per-channel clamp.
    ///
    /// Steps:
    ///   1. Compute per-channel reciprocal `mean / channel` on the raw
    ///      (gamma-encoded) sample.
    ///   2. Cap each ratio to `[2^-k, 2^k]` where `k = wbGrayWorldLogCap`.
    ///   3. Stack onto current gains: `newGain = current × cappedRatio`.
    ///   4. Normalize to `min == 1.0`.
    ///   5. Per-channel clamp to `[1.0, maxGain]`.
    ///
    /// **Why log-cap:** undamped gray-world demands a single step that can be
    /// 2× or more in either direction on a strong initial cast. After the
    /// stack-and-normalize-to-min, that lands one channel exactly on the
    /// 1.0 floor and another on the `maxGain` ceiling. With two channels
    /// pinned at boundaries the loop loses degrees of freedom and oscillates.
    /// Capping the per-step magnitude at √2 (k=0.5) keeps the trajectory
    /// inside the feasible gain box and the loop converges in 2–4 steps from
    /// a near-optimal seed (Apple's `grayWorldDeviceWhiteBalanceGains`).
    ///
    /// **History — why not linearize:** the physically-correct approach is to
    /// apply sRGB EOTF before computing ratios, since AVF's gains operate
    /// pre-gamma in the sensor pipeline. We tried this — and it deadlocked.
    /// On warm-lit scenes, linear-space R-ratios are below 0.5, which after
    /// `current.red × ratio` and the min-normalize lands R-gain on the 1.0
    /// floor. With one channel pinned at the floor, the algorithm has no
    /// degree of freedom left for that channel and the loop oscillates
    /// between two states. Gamma-encoded ratios are mathematically a
    /// compression of the linear ratios, but operationally they keep gains
    /// off the floor/ceiling boundaries.
    public static func grayWorldGains(
        sample: RgbSample,
        current: WhiteBalanceGains,
        maxGain: Float
    ) -> WhiteBalanceGains {
        let eps = 1e-4
        let r = max(eps, sample.r)
        let g = max(eps, sample.g)
        let b = max(eps, sample.b)
        let mean = (r + g + b) / 3.0

        let k = Constants.wbGrayWorldLogCap
        let cappedR = capLogRatio(Float(mean / r), cap: k)
        let cappedG = capLogRatio(Float(mean / g), cap: k)
        let cappedB = capLogRatio(Float(mean / b), cap: k)

        var newR = current.red * cappedR
        var newG = current.green * cappedG
        var newB = current.blue * cappedB

        let m = min(newR, min(newG, newB))
        if m > 0 {
            newR /= m
            newG /= m
            newB /= m
        }

        return WhiteBalanceGains(
            red: min(maxGain, max(1.0, newR)),
            green: min(maxGain, max(1.0, newG)),
            blue: min(maxGain, max(1.0, newB))
        )
    }

    /// Clamps `|log2(ratio)| ≤ cap`, returning the corresponding linear ratio.
    /// `ratio = 1.0` (no change) maps to `1.0` regardless of cap.
    private static func capLogRatio(_ ratio: Float, cap: Float) -> Float {
        let logR = log2(max(ratio, 1e-6))
        let cappedLog = max(-cap, min(cap, logR))
        return exp2(cappedLog)
    }

    // MARK: - linear-normalization-stage: statistical black point

    /// sRGB EOTF (gamma → linear) — the TRUE piecewise curve (IEC 61966-2-1).
    ///
    /// This MUST match `ColorShaders.metal`'s `srgbToLinear` exactly: the black
    /// point is *derived* here in linear light and *applied* there in linear
    /// light, so a curve mismatch would make calibrated black land at the wrong
    /// value and not come out solid. The piecewise (not `pow(2.2)`) form matters
    /// because the black point lives in the near-black region where they diverge.
    /// Pinned to the shader by the `normalizationSrgbRoundTripIsIdentity` device
    /// test (which round-trips through the shader helpers).
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Per-channel **linear** black-point offsets from a dark-field readback.
    ///
    /// Thin wrapper over `blackPointDebug` (which carries the full diagnostics);
    /// returns just the applied offsets. See `blackPointDebug` for the algorithm.
    public static func blackPointOffsets(
        pixels: [SIMD3<Float>], width: Int, height: Int, patch: Int
    ) -> (r: Double, g: Double, b: Double) {
        let d = blackPointDebug(
            pixels: pixels, width: width, height: height, patch: patch)
        return (d.r.offsetLinear, d.g.offsetLinear, d.b.offsetLinear)
    }

    /// Per-channel black-point diagnostics from a dark-field readback: the linear
    /// offset and per-channel statistics.
    ///
    /// Patch-only + near-black per-pixel gate (design D8, revised 2026-06-23), all
    /// offset statistics in LINEAR light:
    ///   1. Look only at the centered `patch × patch` window (the full-frame
    ///      value-mask was dropped — it pulled in per-channel-divergent pixels that
    ///      over-inflated the offsets and tinted the image).
    ///   2. Keep a pixel only if EVERY channel is near-black ((gamma) value
    ///      `< blackPointMaxSampleGamma`); a pixel bright in any channel is dropped
    ///      wholesale, so all channels are estimated from the same dark-pixel set
    ///      (consistent per-channel offsets, no tinting). `keptCount` reports how
    ///      many survived — `0` means the surface was too bright to black-point.
    ///   3. `offset = mean + blackPointSigmaK·σ` over the kept pixels (per channel);
    ///      no kept pixels ⇒ offset `0`.
    ///
    /// - Parameters:
    ///   - pixels: row-major gamma-encoded RGB, one entry per pixel.
    ///   - width, height: frame dimensions (`pixels.count == width * height`).
    ///   - patch: center-patch side length in pixels (the only region sampled).
    public static func blackPointDebug(
        pixels: [SIMD3<Float>], width: Int, height: Int, patch: Int
    ) -> BlackPointDebug {
        let kSig = Constants.blackPointSigmaK
        let maxSample = Constants.blackPointMaxSampleGamma
        let half = patch / 2
        let cx = width / 2
        let cy = height / 2
        let x0 = max(0, cx - half)
        let x1 = min(width, cx + half)
        let y0 = max(0, cy - half)
        let y1 = min(height, cy + half)
        let pw = max(0, x1 - x0)
        let ph = max(0, y1 - y0)
        let emptyStats = BlackPointChannelStats(
            offsetLinear: 0, meanGamma: 0, minGamma: 0, maxGamma: 0)
        guard width > 0, height > 0, pixels.count == width * height, pw > 0, ph > 0
        else {
            return BlackPointDebug(
                keptCount: 0, totalCount: 0, r: emptyStats, g: emptyStats, b: emptyStats)
        }

        var sum = SIMD3<Double>(repeating: 0)
        var sumSq = SIMD3<Double>(repeating: 0)
        var gammaSum = SIMD3<Double>(repeating: 0)
        var minG = SIMD3<Double>(repeating: 1)
        var maxG = SIMD3<Double>(repeating: 0)
        var keptCount = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixels[y * width + x]
                let g = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
                minG = SIMD3(min(minG.x, g.x), min(minG.y, g.y), min(minG.z, g.z))
                maxG = SIMD3(max(maxG.x, g.x), max(maxG.y, g.y), max(maxG.z, g.z))
                // Per-pixel near-black gate: keep only if every channel is dark.
                if g.x < maxSample && g.y < maxSample && g.z < maxSample {
                    let l = SIMD3<Double>(srgbToLinear(g.x), srgbToLinear(g.y), srgbToLinear(g.z))
                    sum += l
                    sumSq += l * l
                    gammaSum += g
                    keptCount += 1
                }
            }
        }

        // Per channel: mean + k·σ over kept pixels (population var = E[x²]−E[x]²,
        // clamped ≥ 0). No kept pixels ⇒ offset 0.
        func stats(
            _ s: Double, _ sq: Double, _ gSum: Double, _ minc: Double, _ maxc: Double
        ) -> BlackPointChannelStats {
            guard keptCount > 0 else {
                return BlackPointChannelStats(
                    offsetLinear: 0, meanGamma: 0, minGamma: minc, maxGamma: maxc)
            }
            let n = Double(keptCount)
            let m = s / n
            let v = max(0, sq / n - m * m)
            return BlackPointChannelStats(
                offsetLinear: m + kSig * v.squareRoot(),
                meanGamma: gSum / n, minGamma: minc, maxGamma: maxc)
        }
        return BlackPointDebug(
            keptCount: keptCount, totalCount: pw * ph,
            r: stats(sum.x, sumSq.x, gammaSum.x, minG.x, maxG.x),
            g: stats(sum.y, sumSq.y, gammaSum.y, minG.y, maxG.y),
            b: stats(sum.z, sumSq.z, gammaSum.z, minG.z, maxG.z))
    }

    // MARK: - linear-normalization-stage: white-balance residual + white point

    /// Decomposes one white-field sample into a per-channel **chroma residual**
    /// gain and a scalar **white-point level**, both in linear light (§5.1).
    ///
    /// The sample is the centered patch read from the natural (pre-grade) lane
    /// *after* the hardware white-balance gains have been locked, so it carries
    /// the residual color cast the hardware gains could not remove. The
    /// decomposition (design D4):
    ///   1. Linearize each gamma-encoded channel (`srgbToLinear`, the same curve
    ///      the shader applies — pinned by `normalizationSrgbRoundTripIsIdentity`).
    ///   2. `meanLin = (lr + lg + lb) / 3` — computed **once** and fed to both
    ///      terms. The composite gain is `chroma·level = meanLin/lC · target/meanLin
    ///      = target/lC`; the mean cancels, so brightfield always lands every
    ///      channel on `target`. Splitting the mean between the two terms (e.g.
    ///      geometric for one) would break that cancellation — don't.
    ///   3. **Chroma residual** `chromaC = meanLin / lC`: equalizes the channels to
    ///      their shared linear mean. Brightness-preserving — it conserves the
    ///      linear-RGB sum (`Σ chromaC·lC = 3·meanLin = Σ lC`), so a grey reference
    ///      stays at its level instead of being pushed toward white. Safe for phase
    ///      contrast.
    ///   4. **Level** `targetLin / meanLin`, with `targetLin =
    ///      srgbToLinear(Constants.whitePointTargetDisplay)`: lifts the neutralized
    ///      reference to the configured white target. Optional, applied only in
    ///      brightfield (see `enableWhitePoint() / disableWhitePoint()`).
    ///
    /// Near-zero channels are eps-clamped so a (degenerate) black sample can't
    /// divide by zero; on a real white field every channel is bright.
    ///
    /// - Parameter whiteSample: per-channel **gamma-encoded** RGB of the locked
    ///   white-field patch (`sampleCenterPatchOnNatural()`'s `after`).
    /// - Returns: the per-channel chroma gains and the scalar white-point level.
    public static func whiteBalanceResidual(
        whiteSample: RgbSample
    ) -> (chroma: RgbSample, level: Double) {
        let eps = 1e-4
        let lr = max(eps, srgbToLinear(whiteSample.r))
        let lg = max(eps, srgbToLinear(whiteSample.g))
        let lb = max(eps, srgbToLinear(whiteSample.b))
        let meanLin = (lr + lg + lb) / 3.0
        let targetLin = srgbToLinear(Constants.whitePointTargetDisplay)
        let chroma = RgbSample(r: meanLin / lr, g: meanLin / lg, b: meanLin / lb)
        let level = targetLin / meanLin
        return (chroma: chroma, level: level)
    }

}
