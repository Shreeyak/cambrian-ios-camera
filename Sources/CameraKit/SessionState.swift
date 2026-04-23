import Foundation

public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
}

public enum RecordingState: Sendable, Hashable {
    case idle(lastUri: String?)
    case recording
    case finalizing
    case paused
}

public enum StreamId: String, Sendable, Hashable, CaseIterable {
    case natural
    case processed
    case tracker
}

// MARK: - Recording types (compressed here per Stage 01 type-compression decision)

/// Options for starting a recording session.
///
/// Full implementation Stage 06.
public struct RecordingOptions: Sendable, Hashable {
    /// Target video bitrate in bits per second.
    ///
    /// Nil → `Constants.recordingTargetBitrateBpsDefault`.
    public var bitrateBps: Int?
    /// Target frame rate (30).
    ///
    /// Nil → `Constants.frameRateTargetFPS`.
    public var fps: Int?
    /// Destination directory.
    ///
    /// Nil → app Documents directory.
    public var outputDirectory: URL?
    /// Filename excluding extension.
    ///
    /// Nil → ISO-8601 timestamp.
    public var fileName: String?

    public init(
        bitrateBps: Int? = nil,
        fps: Int? = nil,
        outputDirectory: URL? = nil,
        fileName: String? = nil
    ) {
        self.bitrateBps = bitrateBps
        self.fps = fps
        self.outputDirectory = outputDirectory
        self.fileName = fileName
    }
}

/// Result of a successful recording start.
///
/// Full implementation Stage 06.
public struct RecordingStart: Sendable, Hashable {
    /// Destination URL as a string per `api-surface.md`.
    public let uri: String
    /// Displayed filename (without path).
    public let displayName: String
    public init(uri: String, displayName: String) {
        self.uri = uri
        self.displayName = displayName
    }
}
