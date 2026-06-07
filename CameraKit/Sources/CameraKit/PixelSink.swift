import CoreMedia
import CoreVideo
import Foundation
import FrameTransport
import OSLog
import Synchronization

// frame-delivery-rework — Swift-only consumer fan-out. The C-ABI PixelSink /
// PixelSinkPool path (and its CameraKitInterop bridge) was removed: its
// IOSurface was call-scoped and could not support a bounded consumer hold. The
// `subscribe()` path below is the supported zero-copy consumer path; each lane
// is its own `AsyncThrowingStream<Frame>` carrying a holdable `PixelHandle`.

/// Swift facade for the per-lane consumer fan-out.
///
/// `subscribe(stream:buffering:)` returns an `AsyncThrowingStream<Frame>` for one
/// lane. Actor isolation governs `subscribe` (a cold path). Publication runs on
/// the delivery queue via a `nonisolated` `yield(_:stream:)` — no actor hop on
/// the frame clock (ADR-02).
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncThrowingStream<Frame, Error>.Continuation
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

    public init() {}

    // MARK: - Subscribe (per-lane Frame stream)

    /// Returns an `AsyncThrowingStream<Frame>` for one lane with the given
    /// ``FrameTransport/BufferingPolicy``.
    ///
    /// The stream finishes cleanly on `close()` and finishes by THROWING only
    /// when CameraKit judges a fault terminal (`CameraError.isFatal`, via
    /// ``failAllLanes(_:)``). Transient faults leave the stream open.
    /// Termination of the consuming task removes the subscriber synchronously
    /// via `onTermination`.
    public func subscribe(
        stream: StreamId,
        buffering: BufferingPolicy
    ) -> AsyncThrowingStream<Frame, Error> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        // Map the transport policy onto AsyncStream's native buffering.
        // `.bufferingNewest(n)` drops the OLDEST on overflow, matching both
        // `latestWins` (n=1) and `keepBuffered(depth:)` (n=depth). `blocking`
        // has no native back-pressure in AsyncStream (it is for offline sources
        // the camera never uses); map it to `.unbounded`.
        let policy: AsyncThrowingStream<Frame, Error>.Continuation.BufferingPolicy
        switch buffering {
        case .latestWins: policy = .bufferingNewest(1)
        case .keepBuffered(let depth): policy = .bufferingNewest(max(1, depth))
        case .blocking: policy = .unbounded
        }
        return AsyncThrowingStream<Frame, Error>(bufferingPolicy: policy) { continuation in
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

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Publishes one lane's `Frame` to that lane's subscribers.
    ///
    /// Runs inline on the delivery queue; no actor hop.
    nonisolated func yield(_ frame: Frame, stream: StreamId) {
        state.withLock { inner in
            guard let lane = inner.subscribers[stream], !lane.isEmpty else { return }
            inner.subscribers[stream] = lane.filter { sub in
                let r = sub.continuation.yield(frame)
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
    }

    /// True when `stream` has at least one subscriber.
    ///
    /// Gates tracker production in `MetalPipeline` so no tracker buffer is
    /// dequeued when nobody listens.
    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        state.withLock { $0.subscribers[stream]?.isEmpty == false }
    }

    // MARK: - Termination

    /// Finishes every lane stream by THROWING `error` — the terminal path.
    ///
    /// Called from `CameraEngine.publishError` only when `CameraError.isFatal`.
    /// Drains continuations outside the lock: `finish(throwing:)` synchronously
    /// invokes the `onTermination` handler set in `subscribe`, which re-acquires
    /// `state.withLock`; finishing under the lock would recursively acquire the
    /// `os_unfair_lock` and abort.
    nonisolated func failAllLanes(_ error: Error) {
        let toFinish: [AsyncThrowingStream<Frame, Error>.Continuation] = state.withLock { inner in
            let conts = inner.subscribers.values.flatMap { $0.map(\.continuation) }
            inner.subscribers.removeAll()
            return conts
        }
        for c in toFinish { c.finish(throwing: error) }
    }

    /// Finishes every lane stream cleanly (no throw) — the close path.
    ///
    /// Called from `CameraEngine.close()`. Same out-of-lock drain rationale as
    /// ``failAllLanes(_:)``.
    func release() {
        let toFinish: [AsyncThrowingStream<Frame, Error>.Continuation] = state.withLock { inner in
            let conts = inner.subscribers.values.flatMap { $0.map(\.continuation) }
            inner.subscribers.removeAll()
            return conts
        }
        for c in toFinish { c.finish() }
    }

    // MARK: - Metrics

    /// Production per-lane drop counter.
    ///
    /// Read directly from tests via `@testable import` — a clean call into
    /// production, not a test seam.
    nonisolated func dropCount(for stream: StreamId) -> UInt64 {
        state.withLock { $0.dropCounts[stream] ?? 0 }
    }
}

// MARK: - Test seams (internal — accessed via @testable import)
#if DEBUG
extension ConsumerRegistry {
    /// Test seam: synthetically bump the per-lane drop counter.
    nonisolated func _incrementSwiftDropForTest(stream: StreamId, by count: UInt64 = 1) {
        state.withLock { $0.dropCounts[stream, default: 0] &+= count }
    }

    /// Per-lane subscriber count — readable from tests via @testable import.
    nonisolated func subscriberCount(for stream: StreamId) -> Int {
        state.withLock { $0.subscribers[stream]?.count ?? 0 }
    }
}
#endif
