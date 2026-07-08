import CoreMedia
import CoreVideo
import Foundation

// CVPixelBuffer (CVImageBuffer) is a Core Foundation ref-counted object backed by IOSurface.
// Its retain/release operations are thread-safe. @unchecked Sendable per G-13: CPU access
// is strictly gated by CVPixelBufferLockBaseAddress (ADR-06) at all call sites.
extension CVPixelBuffer: @retroactive @unchecked Sendable {}

// `FrameSet` (the bundled all-lanes envelope) was removed in
// frame-delivery-rework — delivery is now per-lane `FrameTransport.Frame`
// streams. The value types below survived because they are self-contained and
// referenced beyond FrameSet.

// `TrackerQuality` and the `blurScore`/`trackerQuality` frame fields were removed
// in frame-metadata-signals: they were hardcoded (`0.0` / `.good`) — a contract
// advertising GPU-computed quality signals that were never computed. A consumer
// needing a frame-quality gate uses its own (e.g. EvaScan's `QualityGate`). If
// CameraKit ever provides these, they must be honestly computed.

public struct CaptureMetadata: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let whiteBalanceGains: WhiteBalanceGains
    public let whiteBalanceModeActive: WhiteBalanceMode
    public let lensPosition: Float
    public let focusModeActive: CameraMode
    public let exposureModeActive: CameraMode
    public let zoomFactor: Double
    public let cameraPosition: CameraPosition

    public init(
        iso: Float, exposureDurationNs: Int64, whiteBalanceGains: WhiteBalanceGains,
        whiteBalanceModeActive: WhiteBalanceMode, lensPosition: Float,
        focusModeActive: CameraMode, exposureModeActive: CameraMode,
        zoomFactor: Double, cameraPosition: CameraPosition
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.whiteBalanceGains = whiteBalanceGains
        self.whiteBalanceModeActive = whiteBalanceModeActive
        self.lensPosition = lensPosition
        self.focusModeActive = focusModeActive
        self.exposureModeActive = exposureModeActive
        self.zoomFactor = zoomFactor
        self.cameraPosition = cameraPosition
    }
}

// ProcessingMetadata extracted to ProcessingMetadata.swift in Stage 05 (brief §4).

// MARK: - CaptureMetadata convenience

extension CaptureMetadata {
    /// Stage 06 placeholder: zero-valued sensor metadata.
    ///
    /// Full attachment-derived implementation lands with sensor-metadata
    /// plumbing in a later stage.
    static func placeholder() -> CaptureMetadata {
        CaptureMetadata(
            iso: 0,
            exposureDurationNs: 0,
            whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            whiteBalanceModeActive: .auto,
            lensPosition: 0,
            focusModeActive: .auto,
            exposureModeActive: .auto,
            zoomFactor: 1.0,
            cameraPosition: .back
        )
    }
}

public struct WhiteBalanceGains: Sendable, Hashable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum CameraPosition: String, Sendable, Hashable {
    case back
    case front
    case wide
}

public struct FrameDeliveryStats: Sendable, Hashable {
    public let producedByLane: [StreamId: UInt64]
    public let deliveredByLane: [StreamId: UInt64]
    public let droppedByLane: [StreamId: UInt64]
    public let holdOverBudgetByLane: [StreamId: UInt64]
    public let poolExhaustion: UInt64
    public let cppOverwriteByLane: [StreamId: UInt64]

    public init(
        producedByLane: [StreamId: UInt64], deliveredByLane: [StreamId: UInt64],
        droppedByLane: [StreamId: UInt64], holdOverBudgetByLane: [StreamId: UInt64],
        poolExhaustion: UInt64, cppOverwriteByLane: [StreamId: UInt64]
    ) {
        self.producedByLane = producedByLane
        self.deliveredByLane = deliveredByLane
        self.droppedByLane = droppedByLane
        self.holdOverBudgetByLane = holdOverBudgetByLane
        self.poolExhaustion = poolExhaustion
        self.cppOverwriteByLane = cppOverwriteByLane
    }
}

// MARK: - Sensor read types (compressed here per Stage 01 type-compression decision)

/// Sensor metadata delivered at constants.md#FRAME_RESULT_HEARTBEAT_HZ.
///
/// Full implementation Stage 04.
public struct FrameResult: Sendable, Hashable {
    public var iso: Int?
    public var exposureTimeNs: Int64?
    public var focusDistance: Double?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?
    /// Heavyweight, debug-only diagnostics as a JSON string (frame-metadata-signals).
    ///
    /// Carries detail a consumer does NOT branch on — full AF/WB/AE convergence
    /// state and the grade params (brightness/contrast/saturation/gamma/cropRegion/
    /// white-balance gains, formerly `ProcessingMetadata`). It is NOT a control
    /// surface: anything load-bearing must be promoted to a typed field (on
    /// `CameraFrameMetadata` for per-frame decisions). Shape is intentionally
    /// unstable — debug grade, not a contract.
    public var diagnosticsJSON: String?

    public init(
        iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil,
        wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil,
        diagnosticsJSON: String? = nil
    ) {
        self.iso = iso
        self.exposureTimeNs = exposureTimeNs
        self.focusDistance = focusDistance
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
        self.diagnosticsJSON = diagnosticsJSON
    }
}

/// Per-channel trimmed-mean sample from the calibration center-patch sampler.
///
/// Full implementation Stage 04.
public struct RgbSample: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}
