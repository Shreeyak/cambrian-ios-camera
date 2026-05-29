// CABIParityTests — Phase 1B C-ABI parity probe.
// Exercises pixel_sink_pool_register (raw C-ABI) on the same pool as
// engine.consumers.registerCallback (Swift API) and asserts identical
// frame sequences. This is the path Phase 3's Flutter plugin native code
// will use; without this probe it ships unexercised until Phase 3, where
// divergences (context lifetime, threading, counters) are hardest to debug.
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CameraKit
@testable import ios_example_app  // counter_consumer_* C-ABI via bridging header

@Suite("Phase-1B C-ABI parity", .progressLogged)
struct CABIParityTests {

    private func makeSyntheticFrameSet(frameNumber: UInt64) throws -> FrameSet {
        let width = 64
        let height = 48
        func makeBuffer() throws -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_64RGBAHalf,
                attrs as CFDictionary, &buf)
            guard status == kCVReturnSuccess, let b = buf else {
                throw NSError(domain: "test", code: Int(status))
            }
            return b
        }
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: 1000, timescale: 1_000_000_000),
            natural: try makeBuffer(),
            processed: try makeBuffer(),
            tracker: try makeBuffer(),
            capture: .placeholder(),
            processing: ProcessingMetadata(
                color: ColorUniform(.identity),
                crop: CropUniform.full(width: width, height: height)),
            blurScore: 0,
            trackerQuality: .good
        )
    }

    /// A C-ABI-registered consumer and a Swift-API-registered consumer on the
    /// same stream observe identical frame numbers when yield() is called.
    @Test("1b:c-abi-parity-with-swift-api")
    func cabiParityWithSwiftAPI() async throws {
        let registry = ConsumerRegistry()
        // Raw pool pointer — registry.nativePipelinePointer() returns UInt64
        // (uintptr_t of the pool); the C-ABI takes void*.
        let rawPool = UnsafeMutableRawPointer(bitPattern: UInt(registry.nativePipelinePointer()))!

        // C-ABI consumer (counter, via pixel_sink_pool_register).
        let counter = counter_consumer_create()!
        let cAbiToken = counter_consumer_register(counter, rawPool, StreamId.tracker.rawPoolId)
        #expect(cAbiToken != 0, "Counter registration via C-ABI rejected (token 0)")

        // Swift API consumer on the same stream.
        let swiftCounter = LockingCounter()
        let swiftLast = LockingLastFrame()
        let pair = CounterPair(counter: swiftCounter, last: swiftLast)
        let pairRetained = Unmanaged.passRetained(pair)
        defer { pairRetained.release() }
        let swiftCbs = PixelSinkCallbacks(
            onFrame: { ctx, _, frameNumber, _, _ in
                let pair = Unmanaged<CounterPair>.fromOpaque(ctx!).takeUnretainedValue()
                pair.counter.increment()
                pair.last.set(frameNumber)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: pairRetained.toOpaque()
        )
        let swiftToken = try await registry.registerCallback(stream: .tracker, callbacks: swiftCbs)

        // Drive 20 frames through the registry's yield path.
        for i: UInt64 in 1...20 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }

        // Parity assertions.
        let cAbiFrameCount = counter_consumer_frame_count(counter)
        let cAbiLastFrame = counter_consumer_last_frame_number(counter)
        #expect(cAbiFrameCount == 20, "C-ABI counter saw \(cAbiFrameCount) frames, expected 20")
        #expect(cAbiLastFrame == 20, "C-ABI counter's last frame is \(cAbiLastFrame), expected 20")
        #expect(swiftCounter.value == 20, "Swift counter saw \(swiftCounter.value) frames, expected 20")
        #expect(swiftLast.value == 20, "Swift counter's last frame is \(swiftLast.value), expected 20")

        counter_consumer_unregister(counter, rawPool, cAbiToken)
        counter_consumer_destroy(counter)
        await registry.unregister(token: swiftToken)
    }

    /// Register → unregister cycle leaks nothing observable: a second register
    /// with a fresh counter still sees frames; the first counter's count freezes.
    @Test("1b:c-abi-unregister-stops-delivery")
    func cabiUnregisterStopsDelivery() async throws {
        let registry = ConsumerRegistry()
        let rawPool = UnsafeMutableRawPointer(bitPattern: UInt(registry.nativePipelinePointer()))!

        let counter1 = counter_consumer_create()!
        let token1 = counter_consumer_register(counter1, rawPool, StreamId.tracker.rawPoolId)
        #expect(token1 != 0)

        for i: UInt64 in 1...5 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter1) == 5)

        counter_consumer_unregister(counter1, rawPool, token1)

        // Frames 6-10 go to no consumer.
        for i: UInt64 in 6...10 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter1) == 5,
                "Unregistered counter must not receive further frames")

        // Re-register with a fresh counter; observes only future frames.
        let counter2 = counter_consumer_create()!
        let token2 = counter_consumer_register(counter2, rawPool, StreamId.tracker.rawPoolId)
        #expect(token2 != 0)
        for i: UInt64 in 11...15 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter_consumer_frame_count(counter2) == 5)
        #expect(counter_consumer_last_frame_number(counter2) == 15)

        counter_consumer_unregister(counter2, rawPool, token2)
        counter_consumer_destroy(counter1)
        counter_consumer_destroy(counter2)
    }
}

// MARK: - Test helpers

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class LockingLastFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    func set(_ v: UInt64) { lock.withLock { _value = v } }
    var value: UInt64 { lock.withLock { _value } }
}

private final class CounterPair {
    let counter: LockingCounter
    let last: LockingLastFrame
    init(counter: LockingCounter, last: LockingLastFrame) {
        self.counter = counter
        self.last = last
    }
}
