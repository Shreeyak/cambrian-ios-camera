import AVFoundation
import CoreMedia
import Testing

@testable import CameraKit

// MARK: - Thread-safe state recorder

/// Thread-safe recorder for RecordingState events captured in @Sendable closures.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RecordingState] = []
    func append(_ s: RecordingState) { lock.withLock { items.append(s) } }
    var snapshot: [RecordingState] { lock.withLock { items } }
}

// MARK: - Stage10CoordinatorTests

@Suite("Stage 10 — recording coordinator")
struct Stage10CoordinatorTests {
    @Test("coordinator publishes idle(nil) on init")
    func initialState() async {
        let log = StateLog()
        let hooks = Recording.Hooks(
            publishState: { log.append($0) },
            emitError: { _ in }
        )
        let rec = Recording(
            clock: SystemClock(), hooks: hooks,
            writerFactory: { _, _, _, _ in
                fatalError("unused in this test")
            })
        await rec.observeCurrentStateForTest()
        #expect(log.snapshot == [.idle(lastUri: nil)])
    }
}
