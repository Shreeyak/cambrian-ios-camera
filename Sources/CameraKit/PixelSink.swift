import Foundation
import Synchronization

// Stage 06 — ConsumerRegistry actor + C-ABI PixelSinkCallbacks struct
// per architecture 05-consumers.md §D-01 / §D-03 and ADR-18 / ADR-22 / ADR-31.

/// Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and
/// `.registerCallback(stream:callbacks:)`.
///
/// Holds the lane id so unregister can route to the right internal collection
/// without a second lookup.
public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId
    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}

/// C-ABI-shaped callback struct per ADR-31 and D-03.
///
/// The Stage-08 C++ `PixelSink` pool will invoke these `@convention(c)` function
/// pointers; in Stage 06 this type exists only so the signature of
/// `registerCallback` can compile — the method itself throws
/// `InteropError.notWired` (scaffolding:06:simple-consumer-swift-only).
public struct PixelSinkCallbacks {
    // swiftlint:disable nesting
    public typealias OnFrame =
        @convention(c) (
            _ context: UnsafeMutableRawPointer?,
            _ stream: UInt32,
            _ frameNumber: UInt64,
            _ presentationTimeNs: Int64,
            _ surface: UnsafeMutableRawPointer?
        ) -> Void

    public typealias OnOverwrite =
        @convention(c) (
            _ context: UnsafeMutableRawPointer?,
            _ stream: UInt32
        ) -> Void

    public typealias OnError =
        @convention(c) (
            _ context: UnsafeMutableRawPointer?,
            _ code: Int32
        ) -> Void
    // swiftlint:enable nesting

    public let onFrame: OnFrame
    public let onOverwrite: OnOverwrite
    public let onError: OnError
    public let context: UnsafeMutableRawPointer?

    public init(
        onFrame: OnFrame,
        onOverwrite: OnOverwrite,
        onError: OnError,
        context: UnsafeMutableRawPointer?
    ) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

// `UnsafeMutableRawPointer?` prevents synthesized Sendable; C-ABI pointer lifetime
// is managed by the C++ caller per ADR-31 / D-03 — safe to cross actor boundaries.
extension PixelSinkCallbacks: @unchecked Sendable {}

/// Swift facade for the consumer fan-out.
///
/// Actor for subscribe/unregister/registerCallback (cold paths), but publication
/// runs on the delivery queue through a `nonisolated` `yield(_:stream:)` — no
/// actor hop on the frame clock (ADR-02).
///
/// The internal subscriber table is a `Mutex<InnerState>` (iOS 18+). Readers
/// (yield + hasSubscriber) hold the lock only for the duration of the table
/// lookup and a `Continuation.yield(_)` call; the Continuation's buffering
/// policy (`.bufferingNewest(1)`) + drop counter via `YieldResult.dropped`
/// satisfy ADR-22 per-lane mailbox semantics.
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncStream<FrameSet>.Continuation
    }

    private struct InnerState {
        var subscribers: [StreamId: [Subscriber]] = [:]
        var nextId: UInt64 = 0
        /// Per-lane drop counter — incremented every time `Continuation.yield`
        /// returns `.dropped(_)` (a newer frame pushed out the prior buffered one).
        var dropCounts: [StreamId: UInt64] = [:]
    }

    // `nonisolated let` so `yield(_:stream:)` (non-isolated) can reach the mutex
    // without an actor hop. `Mutex` is Sendable.
    private nonisolated let state: Mutex<InnerState> = Mutex(InnerState())

    public init() {}

    // MARK: - Subscribe (Swift lane, D-01)

    /// Returns an `AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22.
    ///
    /// Termination of the stream (consuming `Task` cancelled or returned) runs
    /// the onTermination closure, which removes the subscriber synchronously.
    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        return AsyncStream<FrameSet>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
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

    // MARK: - registerCallback (C-ABI lane, D-03) — stub until Stage 08

    // scaffolding:06:simple-consumer-swift-only
    /// C-ABI consumer registration lands in Stage 08.
    ///
    /// Throws `InteropError.notWired` this stage so any attempted external
    /// wiring surfaces loudly instead of silently no-op'ing.
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        throw InteropError.notWired
    }

    // MARK: - Unregister

    /// Finishes the subscriber's continuation and removes it from the table.
    public func unregister(token: ConsumerToken) {
        state.withLock { inner in
            guard var lane = inner.subscribers[token.stream] else { return }
            if let idx = lane.firstIndex(where: { $0.id == token.id }) {
                lane[idx].continuation.finish()
                lane.remove(at: idx)
                inner.subscribers[token.stream] = lane
            }
        }
    }

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Yields `frameSet` into every subscriber's mailbox for `stream`.
    ///
    /// Runs inline on the delivery queue; no actor hop. Increments
    /// `dropCounts[stream]` each time a Continuation reports `.dropped`
    /// (ADR-22: newest wins).
    nonisolated func yield(_ frameSet: FrameSet, stream: StreamId) {
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
                    // Consumer task cancelled; remove eagerly so future yields skip the dead entry.
                    // onTermination will also fire but continuation.finish() is idempotent.
                    return false
                @unknown default:
                    return true
                }
            }
        }
    }

    /// True if there is at least one subscriber for `stream`.
    ///
    /// Used by the Metal pipeline to gate Pass 4 dequeue + encode (no tracker
    /// work when no one listens). Nonisolated because it's polled per frame on
    /// the delivery queue.
    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        state.withLock { inner in
            inner.subscribers[stream]?.isEmpty == false
        }
    }

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
}
