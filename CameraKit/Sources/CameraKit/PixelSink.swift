// PixelSink.swift — Stage 01 stub for the consumer registration system.
// Full C++ interop (OSAllocatedUnfairLock guard, pool delivery) arrives Stage 05.

/// Opaque token returned by CameraEngine.registerPixelSink(_:).
/// Caller passes it back to deregisterPixelSink(_:).
public struct ConsumerToken: Sendable, Hashable {
    let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// Callbacks registered by a pixel sink consumer.
public struct PixelSinkCallbacks: Sendable {
    /// Called on the delivery queue for each frame. Full implementation Stage 05.
    public var onFrame: (@Sendable (FrameSet) -> Void)?
    /// Called when the engine closes or the consumer is deregistered.
    public var onClose: (@Sendable () -> Void)?

    public init(
        onFrame: (@Sendable (FrameSet) -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) {
        self.onFrame = onFrame
        self.onClose = onClose
    }
}

/// Stage 01 stub registry. Full C++ interop lands Stage 05.
/// @unchecked Sendable: internal dictionary protected by callers serialising on sessionQueue (ADR-07).
final class ConsumerRegistry: @unchecked Sendable {
    private var consumers: [ConsumerToken: PixelSinkCallbacks] = [:]
    private var nextId: UInt64 = 0

    func register(_ callbacks: PixelSinkCallbacks) -> ConsumerToken {
        nextId += 1
        let token = ConsumerToken(id: nextId)
        consumers[token] = callbacks
        return token
    }

    func deregister(_ token: ConsumerToken) {
        consumers.removeValue(forKey: token)
    }

    /// No-op stub in Stage 01. Broadcast to consumers over C++ interop arrives Stage 05.
    func broadcast(_ frame: FrameSet) {
        // no-op stub: full fan-out via C++ pool arrives Stage 05.
    }
}
