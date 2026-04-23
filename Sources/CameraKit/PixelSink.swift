import CameraKitInterop
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

// Stage 08 — Real ConsumerRegistry backed by CppPixelSinkPool (Mechanism A, D-01 / D-03).
// Dual-dispatch: yield() drives both Swift AsyncStream subscribers and C++ pool consumers.

/// Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and
/// `.registerCallback(stream:callbacks:)`.
public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId

    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}

/// C-ABI-shaped callback struct per ADR-31 and D-03.
public struct PixelSinkCallbacks: @unchecked Sendable {
    // swiftlint:disable nesting
    public typealias OnFrame =
        @convention(c) (
            _ context: UnsafeMutableRawPointer?, _ stream: UInt32,
            _ frameNumber: UInt64, _ presentationTimeNs: Int64,
            _ surface: UnsafeMutableRawPointer?
        ) -> Void
    public typealias OnOverwrite =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32) -> Void
    public typealias OnError =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ code: Int32) -> Void
    // swiftlint:enable nesting

    public let onFrame: OnFrame?
    public let onOverwrite: OnOverwrite?
    public let onError: OnError?
    public let context: UnsafeMutableRawPointer?

    public init(
        onFrame: OnFrame?,
        onOverwrite: OnOverwrite?,
        onError: OnError?,
        context: UnsafeMutableRawPointer?
    ) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

/// Swift facade for the consumer fan-out (D-01).
///
/// `subscribe(stream:)` uses `AsyncStream` directly (Phase A of D-01's dual-dispatch).
/// `registerCallback(stream:callbacks:)` inserts a C++ pool entry (D-03).
/// `yield(_:stream:)` dispatches to both paths.
///
/// Actor isolation governs subscribe/unregister/registerCallback (cold paths).
/// Publication runs on the delivery queue via a `nonisolated` `yield(_:stream:)`
/// — no actor hop on the frame clock (ADR-02).
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncStream<FrameSet>.Continuation
    }

    private struct InnerState {
        var subscribers: [StreamId: [Subscriber]] = [:]
        var nextId: UInt64 = 0
        /// Per-lane drop counter incremented when `Continuation.yield` returns `.dropped`.
        var dropCounts: [StreamId: UInt64] = [:]
    }

    // `nonisolated let` so `yield(_:stream:)` (non-isolated) can reach the mutex
    // without an actor hop. `Mutex` is Sendable.
    private nonisolated let state: Mutex<InnerState> = Mutex(InnerState())

    // C++ pool — owns all C-ABI consumer registrations.
    // `nonisolated let` so `yield()` (nonisolated) can dispatch without actor hop.
    nonisolated let cppPool: CppPixelSinkPool = CppPixelSinkPool()

    public init() {}

    // MARK: - Subscribe (Swift lane, D-01)

    /// Returns an `AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22.
    ///
    /// Termination of the stream (consuming `Task` cancelled or returned) removes
    /// the subscriber synchronously via `onTermination`.
    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        return AsyncStream<FrameSet>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.state.withLock { inner in
                inner.subscribers[stream, default: []].append(
                    Subscriber(id: id, continuation: continuation))
            }
            continuation.onTermination = { [self] _ in
                self.state.withLock { inner in
                    inner.subscribers[stream]?.removeAll { $0.id == id }
                }
            }
        }
    }

    // MARK: - registerCallback (C-ABI lane, D-03)

    /// Registers a C-ABI consumer in the C++ pool.
    ///
    /// Throws `InteropError.invalidCallbacks` if `callbacks.onFrame` is nil or
    /// if `callbacks.onOverwrite` is nil (both required by D-03).
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        guard let onFrame = callbacks.onFrame else { throw InteropError.invalidCallbacks }
        guard let onOverwrite = callbacks.onOverwrite else { throw InteropError.invalidCallbacks }
        // onError is optional per D-03; default to a no-op to satisfy CppPixelSinkCallbacks.
        let onError: PixelSinkCallbacks.OnError = callbacks.onError ?? { _, _ in }

        let cbs = CppPixelSinkCallbacks(
            onFrame: onFrame,
            onOverwrite: onOverwrite,
            onError: onError,
            context: callbacks.context
        )
        let token = cppPool.register(stream: stream.rawPoolId, callbacks: cbs)
        return ConsumerToken(id: token, stream: stream)
    }

    // MARK: - Unregister

    /// Finishes the subscriber's continuation (Swift lane) or removes the C++ pool entry.
    public func unregister(token: ConsumerToken) {
        var foundSwift = false
        state.withLock { inner in
            guard var lane = inner.subscribers[token.stream] else { return }
            if let idx = lane.firstIndex(where: { $0.id == token.id }) {
                lane[idx].continuation.finish()
                lane.remove(at: idx)
                inner.subscribers[token.stream] = lane
                foundSwift = true
            }
        }
        if !foundSwift {
            cppPool.unregister(token: token.id)
        }
    }

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Dual-dispatch: Swift AsyncStream subscribers + C++ pool consumers.
    ///
    /// Runs inline on delivery queue; no actor hop.
    nonisolated func yield(_ frameSet: FrameSet, stream: StreamId) {
        // 1. Swift AsyncStream subscribers.
        state.withLock { inner in
            guard let lane = inner.subscribers[stream], !lane.isEmpty else { return }
            inner.subscribers[stream] = lane.filter { sub in
                let r = sub.continuation.yield(frameSet)
                switch r {
                case .enqueued:
                    return true
                case .dropped:
                    inner.dropCounts[stream, default: 0] &+= 1
                    return true
                case .terminated:
                    // Consumer task cancelled — remove eagerly; onTermination fires too but is idempotent.
                    return false
                @unknown default:
                    return true
                }
            }
        }

        // 2. C++ pool consumers — dispatch per-stream IOSurface pointer (D-03).
        // CVPixelBufferGetIOSurface returns Unmanaged<IOSurface>?; toOpaque() gives the IOSurfaceRef.
        let surface = streamBuffer(for: stream, frameSet: frameSet)
            .flatMap { CVPixelBufferGetIOSurface($0) }
            .map { $0.toOpaque() }
        // Convert CMTime to nanoseconds safely regardless of source timescale.
        let tsNs = CMTimeConvertScale(
            frameSet.captureTime, timescale: 1_000_000_000,
            method: .default)
        let presentationNs = tsNs.value
        cppPool.dispatch(
            stream: stream.rawPoolId,
            frameNumber: frameSet.frameNumber,
            presentationTimeNs: presentationNs,
            surface: surface ?? nil)
    }

    private nonisolated func streamBuffer(
        for stream: StreamId, frameSet: FrameSet
    ) -> CVPixelBuffer? {
        switch stream {
        case .natural: return frameSet.natural
        case .processed: return frameSet.processed
        case .tracker: return frameSet.tracker
        }
    }

    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        let swiftHas = state.withLock { $0.subscribers[stream]?.isEmpty == false }
        let cppHas = cppPool.consumerCount(stream: stream.rawPoolId) > 0
        return swiftHas || cppHas
    }

    // MARK: - Native pipeline pointer

    nonisolated func nativePipelinePointer() -> UInt64 { cppPool.rawPointer() }

    // MARK: - Teardown

    /// Finishes every subscriber's continuation.
    ///
    /// Called from `CameraEngine.close()`.
    func release() {
        state.withLock { inner in
            for (_, lane) in inner.subscribers {
                for sub in lane { sub.continuation.finish() }
            }
            inner.subscribers.removeAll()
        }
    }

    // MARK: - Test-visible metrics

    /// Per-lane drop counter — readable from tests via @testable import.
    nonisolated func dropCount(for stream: StreamId) -> UInt64 {
        state.withLock { $0.dropCounts[stream] ?? 0 }
    }

    /// Per-lane subscriber count — readable from tests via @testable import.
    nonisolated func subscriberCount(for stream: StreamId) -> Int {
        state.withLock { $0.subscribers[stream]?.count ?? 0 }
    }

    /// C++ pool consumer count for `stream` — test seam.
    nonisolated func cppConsumerCount(for stream: StreamId) -> UInt32 {
        cppPool.consumerCount(stream: stream.rawPoolId)
    }
}

// MARK: - StreamId C++ pool lane index

extension StreamId {
    /// Maps the `StreamId` String-raw enum to a compact UInt32 lane index
    /// for the C++ `PixelSinkPool` (D-03).
    var rawPoolId: UInt32 {
        switch self {
        case .natural: return 0
        case .processed: return 1
        case .tracker: return 2
        }
    }
}
