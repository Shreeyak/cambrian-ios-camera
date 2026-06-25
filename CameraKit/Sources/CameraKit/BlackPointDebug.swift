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

/// Full black-point calibration diagnostics: the sampled center patch (for display)
/// plus per-channel statistics.
public struct BlackPointDebug: Sendable {
    /// Patch side length in pixels (square; `patchRGBA.count == side*side*4`).
    public let side: Int
    /// The sampled patch as RGBA8 (gamma/display values), row-major — for the demo
    /// app to render a magnified thumbnail of exactly what was measured.
    public let patchRGBA: [UInt8]
    /// Pixels that passed the per-pixel near-black gate (all channels < threshold).
    public let keptCount: Int
    /// Total pixels in the patch (`side*side`).
    public let totalCount: Int
    public let r: BlackPointChannelStats
    public let g: BlackPointChannelStats
    public let b: BlackPointChannelStats

    /// A wider, centered context window around the sampled patch as RGBA8.
    ///
    /// Row-major (`contextRGBA.count == contextSide*contextSide*4`), for the demo
    /// app to render the patch *in its surroundings* so the operator can confirm,
    /// against the live preview, exactly where (and in which orientation) the
    /// sample was taken. The sampled `side`×`side` patch is centered within it.
    /// Empty when not requested.
    public let contextRGBA: [UInt8]
    /// Side length (px) of the square context window (`0` when not requested).
    public let contextSide: Int

    public init(
        side: Int, patchRGBA: [UInt8], keptCount: Int, totalCount: Int,
        r: BlackPointChannelStats, g: BlackPointChannelStats, b: BlackPointChannelStats,
        contextRGBA: [UInt8] = [], contextSide: Int = 0
    ) {
        self.side = side
        self.patchRGBA = patchRGBA
        self.keptCount = keptCount
        self.totalCount = totalCount
        self.r = r
        self.g = g
        self.b = b
        self.contextRGBA = contextRGBA
        self.contextSide = contextSide
    }
}
