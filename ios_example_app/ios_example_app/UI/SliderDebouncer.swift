import CameraKit
import Foundation

/// Per-control 60 Hz coalescer for high-frequency UI input (sliders).
///
/// Pattern: `AsyncStream(bufferingPolicy: .bufferingNewest(1))` accumulates the
/// most-recent slider value; a consumer task reads it, dispatches via the closure,
/// then sleeps `intervalMs` milliseconds. Pushes are non-blocking and never block
/// the main thread. Enforces brief §7's mechanism-independent assertion: no more
/// than one engine dispatch per frame, with the final committed value equal to
/// the last input.
///
/// `@unchecked Sendable` — internal mutable state is confined to the consumer
/// task; pushes are atomic via `AsyncStream.Continuation`.
public final class SliderDebouncer: @unchecked Sendable {

    public typealias Dispatch = @Sendable (Double) async -> Void

    private let intervalMs: Int
    private let dispatch: Dispatch
    // continuation + stream are recreated on each start() so the debouncer
    // can be restarted after stop() — stop() calls continuation.finish(),
    // which would otherwise leave the previously-iterated stream permanently
    // closed.
    private var continuation: AsyncStream<Double>.Continuation
    private var stream: AsyncStream<Double>
    private var consumerTask: Task<Void, Never>?

    public init(intervalMs: Int = 16, dispatch: @escaping Dispatch) {
        self.intervalMs = intervalMs
        self.dispatch = dispatch
        var c: AsyncStream<Double>.Continuation!
        self.stream = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        self.continuation = c
    }

    public func start() async {
        consumerTask?.cancel()
        // Recreate the stream/continuation pair so a start() after stop() works.
        // The previous pair (if any) was finished by stop(); reusing it would
        // make the for-await below exit immediately.
        var c: AsyncStream<Double>.Continuation!
        self.stream = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        self.continuation = c
        let stream = self.stream
        let dispatch = self.dispatch
        let intervalMs = self.intervalMs
        consumerTask = Task {
            for await v in stream {
                if Task.isCancelled { break }
                await dispatch(v)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    public func push(_ value: Double) {
        continuation.yield(value)
    }

    public func stop() async {
        continuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
    }
}
