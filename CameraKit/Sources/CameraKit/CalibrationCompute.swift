import Foundation

/// Pure helpers for white-balance and black-balance calibration math.
///
/// Called from `CalibrationViewModel` (07-settings.md §Calibration). The engine
/// applies `ProcessingParameters` / `CameraSettings`; the math derivation lives
/// here so it stays unit-testable without an `AVCaptureSession`.
public enum CalibrationCompute {

    /// Gray-world reciprocal gains, linearized + stacked onto current device gains.
    ///
    /// Source: WWDC 2014 §508 + `AVCaptureDevice.h` lines 1244–1434.
    ///
    /// - Parameter sample: per-channel trimmed-mean read from `naturalTex`
    ///   (BT.601 full-range gamma-encoded RGB).
    /// - Parameter current: WB gains applied by `AVCaptureDevice` at the moment
    ///   the sample was taken — `device.deviceWhiteBalanceGains`.
    /// - Parameter maxGain: `device.maxWhiteBalanceGain` — used for the final
    ///   per-channel clamp.
    ///
    /// Steps:
    ///   1. Linearize the gamma-encoded sample channels (sRGB EOTF).
    ///   2. Compute reciprocal correction `mean / channel` per channel.
    ///   3. Stack onto current gains: `newGain = current × reciprocal` (the
    ///      sample is post-WB, so the reciprocal is a *delta* not an absolute).
    ///   4. Normalize to `min == 1.0` (Apple does this internally too —
    ///      making it explicit keeps clamping predictable).
    ///   5. Per-channel clamp to `[1.0, maxGain]`.
    public static func grayWorldGains(
        sample: RgbSample,
        current: WhiteBalanceGains,
        maxGain: Float
    ) -> WhiteBalanceGains {
        let lr = srgbLinearize(sample.r)
        let lg = srgbLinearize(sample.g)
        let lb = srgbLinearize(sample.b)

        let eps = 1e-4
        let r = max(eps, lr)
        let g = max(eps, lg)
        let b = max(eps, lb)
        let mean = (r + g + b) / 3.0

        var newR = current.red * Float(mean / r)
        var newG = current.green * Float(mean / g)
        var newB = current.blue * Float(mean / b)

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
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        (sample.r, sample.g, sample.b)
    }

    /// sRGB EOTF — converts a gamma-encoded channel value to linear light.
    ///
    /// Why sRGB specifically (research-backed, 2026-05-08):
    ///   - `naturalTex` is `MTLPixelFormat.rgba16Float` with no `_sRGB` suffix,
    ///     so Metal performs no implicit transform on read/write — values are
    ///     stored exactly as written.
    ///   - The Y'CbCr → R'G'B' BT.601 matrix in `YUVToRGBA.metal` is linear
    ///     applied to already-gamma-encoded Y' (the prime denotes gamma) so
    ///     the output is gamma-encoded R'G'B'.
    ///   - `CameraView.swift` sets `(mtkView.layer as? CAMetalLayer)?.colorspace = sRGB`,
    ///     asserting to the compositor "interpret these values as sRGB-encoded".
    ///     For math intended to match what's on screen, sRGB EOTF is the
    ///     consistent inverse.
    ///
    /// Skipping this step biases gains by 5–15% depending on the scene
    /// mid-tone level (per research dispatched in this session).
    private static func srgbLinearize(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }
}
