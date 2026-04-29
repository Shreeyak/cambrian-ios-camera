import Foundation

/// Pure helpers for white-balance and black-balance calibration math.
///
/// Called from `CalibrationViewModel` (07-settings.md §Calibration). The engine
/// applies `ProcessingParameters` / `CameraSettings`; the math derivation lives
/// here so it stays unit-testable without an `AVCaptureSession`.
public enum CalibrationCompute {

    /// Gray-world reciprocal: gains scale each channel so all three average to the scene mean.
    ///
    /// `gain[c] = mean / channel[c]`. Channels are clamped at `eps` to avoid
    /// division-by-zero on a near-black sample.
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

    /// Black-balance pedestal: per-channel dark-patch sample passes through as offsets.
    ///
    /// Caller writes these into `ProcessingParameters.blackR/G/B` so the color
    /// pipeline subtracts them downstream.
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        (sample.r, sample.g, sample.b)
    }
}
