/// One lane of one capture — the single element type carried end-to-end.
///
/// The two lanes of a single capture share the same ``index`` and
/// ``timestampNs``; the `index` is monotonic and session-scoped but NOT
/// gap-free (a latest-wins lane drops intermediate captures, so consumers may
/// observe jumps).
public struct Frame: Sendable {
    /// Which lane this frame belongs to.
    public let lane: Lane
    /// Capture index — shared across lanes, gaps allowed, session-scoped.
    ///
    /// This is THE cross-lane correlation key.
    public let index: UInt64
    /// Capture timestamp in nanoseconds — one unit end-to-end.
    public let timestampNs: Int64
    /// The self-describing pixel lease.
    public let pixels: PixelHandle
    /// Producer-specific metadata; downcast to the concrete type to read it.
    public let metadata: any FrameMetadata

    public init(
        lane: Lane,
        index: UInt64,
        timestampNs: Int64,
        pixels: PixelHandle,
        metadata: any FrameMetadata
    ) {
        self.lane = lane
        self.index = index
        self.timestampNs = timestampNs
        self.pixels = pixels
        self.metadata = metadata
    }
}
