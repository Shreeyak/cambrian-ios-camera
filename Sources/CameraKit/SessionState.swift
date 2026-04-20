import Foundation

public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
}

public enum RecordingState: String, Sendable, Hashable {
    case idle
    case preparing
    case recording
    case stopping
}

public enum StreamId: String, Sendable, Hashable, CaseIterable {
    case natural
    case processed
    case tracker
}

// MARK: - Recording types (compressed here per Stage 01 type-compression decision)

/// Options for starting a recording session. Full implementation Stage 06.
public struct RecordingOptions: Sendable, Hashable {
    public var outputPath: String?
    public init(outputPath: String? = nil) { self.outputPath = outputPath }
}

/// Result of a successful recording start. Full implementation Stage 06.
public struct RecordingStart: Sendable, Hashable {
    public let sessionId: UInt64
    public init(sessionId: UInt64) { self.sessionId = sessionId }
}
