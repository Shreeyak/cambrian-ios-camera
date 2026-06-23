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

    /// Black-balance pedestal: per-channel dark-patch sample passes through as offsets.
    ///
    /// **Important:** the BB pedestal is subtracted at the *end* of the GPU color
    /// pipeline (after brightness/contrast/saturation/gamma) per `ColorShaders.metal`
    /// step 5. The sample fed in here MUST come from a render where **BCSG is
    /// applied and BB is zeroed** — typically `CameraEngine.sampleCenterPatchForBBCalibration`,
    /// which runs a one-shot Pass-2 encode into a scratch texture with BB
    /// temporarily zeroed. This satisfies two requirements simultaneously:
    /// the sample is in the same color space the pedestal will operate on
    /// (BCSG applied), and it isn't biased by the prior pedestal (BB zeroed).
    /// Caller writes these into `ProcessingParameters.blackR/G/B`.
    ///
    /// `Constants.blackBalanceOverscan` (1.5×) over-subtracts the trimmed-mean
    /// sample. The sample is the *average* of the patch, but per-pixel noise
    /// means many pixels sit above the mean — subtracting only the mean leaves
    /// the brighter end of the dark-patch distribution above zero. Multiplying
    /// by 1.5 drives roughly the upper σ of pixel noise to the clamp floor,
    /// making the calibrated dark patch render as actual black on iPad HITL.
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        let k = Constants.blackBalanceOverscan
        return (sample.r * k, sample.g * k, sample.b * k)
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

    /// Derives the per-channel **linear** black-point offset from a dark-field readback.
    ///
    /// Implements the patch-seeded value mask (design D8), all statistics in
    /// LINEAR light:
    ///   1. Seed `patchMean`/`patchσ` per channel from the center patch.
    ///   2. Grow the sample to every frame pixel whose channel value lies within
    ///      `patchMean ± blackPointSelectSigmaK·patchσ` (excludes brighter objects).
    ///   3. `offset = mean + blackPointSigmaK·σ` over that masked set — a gentle,
    ///      noise-adaptive crush (k = 1.5 leaves ~the top 7% of the noise band).
    ///
    /// The result is subtracted from linearized pixels by the shader affine
    /// (`b = −a·blackPoint`), so it is returned in the same linear space.
    ///
    /// - Parameters:
    ///   - pixels: row-major gamma-encoded RGB, one entry per pixel.
    ///   - width, height: frame dimensions (`pixels.count == width * height`).
    ///   - patch: center-patch side length in pixels (the seed region).
    public static func blackPointOffsets(
        pixels: [SIMD3<Float>], width: Int, height: Int, patch: Int
    ) -> (r: Double, g: Double, b: Double) {
        guard width > 0, height > 0, pixels.count == width * height else {
            return (0, 0, 0)
        }
        // Linearize once (gamma → linear), per channel.
        let lin = pixels.map {
            SIMD3<Double>(
                srgbToLinear(Double($0.x)),
                srgbToLinear(Double($0.y)),
                srgbToLinear(Double($0.z)))
        }
        // 1. Seed region: the centered `patch × patch` window, per channel.
        let half = patch / 2
        let cx = width / 2
        let cy = height / 2
        let x0 = max(0, cx - half)
        let x1 = min(width, cx + half)
        let y0 = max(0, cy - half)
        let y1 = min(height, cy + half)
        var patchVals: [[Double]] = [[], [], []]
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = lin[y * width + x]
                patchVals[0].append(p.x)
                patchVals[1].append(p.y)
                patchVals[2].append(p.z)
            }
        }
        let kSel = Constants.blackPointSelectSigmaK
        let kSig = Constants.blackPointSigmaK

        func meanStd(_ a: [Double]) -> (mean: Double, std: Double) {
            guard !a.isEmpty else { return (0, 0) }
            let m = a.reduce(0, +) / Double(a.count)
            let varc = a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)
            return (m, varc.squareRoot())
        }

        // 2. Per channel: value-mask the full frame off the patch seed, then mean + k·σ.
        func offset(_ channel: KeyPath<SIMD3<Double>, Double>, seed: [Double]) -> Double {
            let (pm, ps) = meanStd(seed)
            let lo = pm - kSel * ps
            let hi = pm + kSel * ps
            var masked: [Double] = []
            masked.reserveCapacity(lin.count)
            for p in lin {
                let v = p[keyPath: channel]
                if v >= lo && v <= hi { masked.append(v) }
            }
            // Degenerate fields (e.g. patchσ ≈ 0) can mask out everything but the
            // seed — fall back to the seed so the offset is still defined.
            let (m, s) = meanStd(masked.isEmpty ? seed : masked)
            return m + kSig * s
        }
        return (
            offset(\.x, seed: patchVals[0]),
            offset(\.y, seed: patchVals[1]),
            offset(\.z, seed: patchVals[2])
        )
    }

}
