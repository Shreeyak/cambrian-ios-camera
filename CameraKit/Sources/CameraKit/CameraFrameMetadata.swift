import FrameTransport

/// The camera's per-frame metadata, carried on every delivered ``Frame``.
///
/// Carries the **typed decision signals** a consumer branches on — convergence
/// state derived from the real device (`DeviceStateSnapshot` / KVO), never a
/// zero-valued placeholder. Heavyweight debug detail (full AF/WB/AE state, grade
/// params) is NOT here — it rides the low-rate `frameResultStream()` JSON payload
/// (`FrameResult.diagnosticsJSON`). Rule (frame-metadata-signals): anything a
/// consumer makes a control decision on is a typed member here.
///
/// Consumers downcast `Frame.metadata` to this type at the camera-source
/// boundary, then read `settled` (and/or the per-axis states) to gate decisions
/// such as a first-writer-wins mosaic seed.
public struct CameraFrameMetadata: FrameMetadata, Hashable {
    /// `true` iff all three axes have converged.
    ///
    /// `AE converged && WB settled && focus converged`. A single Bool would hide
    /// which axis is unconverged, so the per-axis fields below are also exposed
    /// for finer gating.
    public let settled: Bool
    public let focusState: FocusState
    public let wbState: WhiteBalanceState
    public let exposureState: ExposureState

    /// Designated init.
    ///
    /// `settled` is computed as the conjunction of the three axes; it is never set
    /// independently. Defaults are `.unknown` (pre-snapshot fail-safe:
    /// `settled == false`, so an unconverged-or-unknown frame never seeds).
    public init(
        focusState: FocusState = .unknown,
        wbState: WhiteBalanceState = .unknown,
        exposureState: ExposureState = .unknown
    ) {
        self.focusState = focusState
        self.wbState = wbState
        self.exposureState = exposureState
        self.settled =
            focusState == .converged && wbState == .settled && exposureState == .converged
    }
}

extension CameraFrameMetadata {
    /// Builds typed convergence metadata from a live device snapshot.
    ///
    /// The `isAdjusting*` flags are the honest signal: a locked/manual axis is
    /// not adjusting, so it reports `.converged`/`.settled` — correct, because a
    /// locked camera IS stable. `settled` follows as the conjunction.
    init(snapshot: DeviceStateSnapshot) {
        self.init(
            focusState: snapshot.isAdjustingFocus ? .adjusting : .converged,
            wbState: snapshot.isAdjustingWhiteBalance ? .adjusting : .settled,
            exposureState: snapshot.isAdjustingExposure ? .adjusting : .converged)
    }
}

/// Lens convergence state for the frame.
public enum FocusState: String, Sendable, Hashable {
    /// Lens is locked or has finished adjusting.
    case converged
    /// Mid-autofocus — the lens is still moving.
    case adjusting
    /// No device snapshot was available when the frame was built.
    case unknown
}

/// White-balance convergence state for the frame.
public enum WhiteBalanceState: String, Sendable, Hashable {
    /// White balance has settled (locked, manual, or finished adjusting).
    case settled
    /// White balance is still adjusting.
    case adjusting
    /// No device snapshot was available when the frame was built.
    case unknown
}

/// Auto-exposure convergence state for the frame.
public enum ExposureState: String, Sendable, Hashable {
    /// Exposure is locked or has finished converging.
    case converged
    /// Auto-exposure is still searching.
    case adjusting
    /// No device snapshot was available when the frame was built.
    case unknown
}
