import CoreMedia

extension CMTime {
    /// The time in nanoseconds as an `Int64`, or `nil` when the value is
    /// non-finite (invalid, indefinite, or infinite).
    ///
    /// `CMTimeGetSeconds` returns `NaN` or `±infinity` for non-numeric times —
    /// for example `activeFormat.maxExposureDuration` can read non-finite in some
    /// launch contexts where the format is not fully materialized (notably under
    /// `xcodebuild test`). The `Int64(_:)` initializer **traps** on a non-finite
    /// `Double` ("Double value cannot be converted to Int64 because it is either
    /// infinite or NaN"), so callers that build integer-nanosecond ranges must go
    /// through this guard and substitute a safe bound when it returns `nil`.
    var finiteNanoseconds: Int64? {
        let seconds = CMTimeGetSeconds(self)
        guard seconds.isFinite else { return nil }
        return Int64(seconds * 1_000_000_000)
    }
}
