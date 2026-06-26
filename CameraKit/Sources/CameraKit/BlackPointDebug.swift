import Foundation

/// Per-channel diagnostics from a black-point calibration (linear-normalization-stage).
///
/// Surfaced to the demo app so an operator can see *why* a calibration produced
/// the offset it did — e.g. a too-bright surface yields `keptCount == 0` and a
/// high `maxGamma`, explaining a zero (no-op) black point.
public struct BlackPointChannelStats: Sendable, Hashable {
    /// The applied linear black-point offset (`mean + k·σ` over the kept pixels).
    public let offsetLinear: Double
    /// Mean of the *kept* (near-black) pixels, in gamma/display space (0…1).
    public let meanGamma: Double
    /// Min over ALL patch pixels (gamma) — shows how dark the darkest pixel was.
    public let minGamma: Double
    /// Max over ALL patch pixels (gamma) — if this exceeds the near-black
    /// threshold, those pixels were gated out.
    public let maxGamma: Double

    public init(offsetLinear: Double, meanGamma: Double, minGamma: Double, maxGamma: Double) {
        self.offsetLinear = offsetLinear
        self.meanGamma = meanGamma
        self.minGamma = minGamma
        self.maxGamma = maxGamma
    }
}

/// Per-channel black-point calibration diagnostics.
public struct BlackPointDebug: Sendable {
    /// Pixels that passed the per-pixel near-black gate (all channels < threshold).
    public let keptCount: Int
    /// Total pixels in the sampled patch.
    public let totalCount: Int
    public let r: BlackPointChannelStats
    public let g: BlackPointChannelStats
    public let b: BlackPointChannelStats

    public init(
        keptCount: Int, totalCount: Int,
        r: BlackPointChannelStats, g: BlackPointChannelStats, b: BlackPointChannelStats
    ) {
        self.keptCount = keptCount
        self.totalCount = totalCount
        self.r = r
        self.g = g
        self.b = b
    }
}
