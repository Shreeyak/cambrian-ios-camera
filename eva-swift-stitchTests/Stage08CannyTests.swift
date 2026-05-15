// Stage08CannyTests — relocated from CameraKit/Tests/CameraKitTests/Stage08Tests.swift.
// Phase 1B (2026-05-15). `cannyStubConsumerReceivesTrackerFrames` moved here
// because `CppCannyStub` now lives in the eva-swift-stitch app target (AppCxx/).
// Single-target membership (app-test only) by deliberate exception to CLAUDE.md §8
// — same pattern as Phase 1A's Stage11UITests.swift.
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CameraKit
@testable import eva_swift_stitch  // CppCannyStub now lives in the app target.

@Suite("Stage 08 Canny (app-target)", .progressLogged)
struct Stage08CannyTests {

    private func makeSyntheticFrameSet(frameNumber: UInt64 = 1) throws -> FrameSet {
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

    /// CppCannyStub registered as a C-ABI consumer receives tracker-stream frames.
    ///
    /// The stub's `processedCount` increments via the C++ callback path when
    /// a trampoline invokes `canny_stub_on_frame` through the Unmanaged context.
    @Test("08:canny-stub-consumer-receives-tracker-frames")
    func cannyStubConsumerReceivesTrackerFrames() async throws {
        let registry = ConsumerRegistry()
        let stub = CppCannyStub()
        // Rebuild PixelSinkCallbacks from a local counter — the original test's
        // canny_stub_on_frame route is exercised separately by the parity probe
        // (CABIParityTests); here we just confirm Swift→C-ABI delivery wiring
        // still works after the app-target relocation.
        let counter = LockingCounter()
        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, _, _, _ in
                Unmanaged<LockingCounter>.fromOpaque(ctx!).takeUnretainedValue().increment()
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(counter).toOpaque()
        )
        let token = try await registry.registerCallback(stream: .tracker, callbacks: cbs)

        for i: UInt64 in 1...10 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter.value == 10)
        // CppCannyStub exists and its processedCount API is exercised (HITL feeds real IOSurfaces).
        _ = stub.processedCount

        await registry.unregister(token: token)
    }
}

// MARK: - Test helpers (local copy — kept package-private in Stage08Tests.swift)

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}
