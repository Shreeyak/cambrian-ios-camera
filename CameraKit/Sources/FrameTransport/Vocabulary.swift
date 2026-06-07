/// The two lanes a producer emits, correlated by a shared ``Frame/index``.
///
/// `Hashable` is an explicit contract: downstream keys pools and subscriptions
/// by lane (e.g. `[Lane: Pool]`, `Set<Lane>`).
public enum Lane: Sendable, Hashable {
    /// Full-resolution alignment frame (camera: the processed output).
    case primary
    /// Downscaled coarse-motion frame (camera: GPU tracker; files: derived).
    case tracker
}

/// The pixel layout a ``PixelHandle`` describes.
public enum PixelFormat: Sendable, Hashable {
    /// 8-bit BGRA, 4 bytes per pixel.
    ///
    /// `gray8` is reserved for a future single-channel tracker but is
    /// explicitly out of scope here.
    case bgra8
}

/// How a lane's stream behaves when the consumer cannot keep up.
public enum BufferingPolicy: Sendable {
    /// Back-pressure the producer — offline / deterministic sources.
    case blocking
    /// Keep newest 1, drop the rest — the `.primary` real-time lane.
    case latestWins
    /// Keep up to `depth`, drop the OLDEST on overflow — the `.tracker` lane.
    case keepBuffered(depth: Int)
}
