// IMPORTANT: this file imports ONLY FrameTransport — never CameraKit. It is the
// literal-wording cover for the "importable without CameraKit" requirement; the
// load-bearing proof is the standalone `swift build --target FrameTransport`
// host build (the FrameTransport target has no CameraKit/AVFoundation deps).
import CoreVideo
import Foundation
import FrameTransport
import Testing

@Suite("FrameTransport vocabulary")
struct FrameTransportVocabularyTests {

    // 3.1 — the types exist and are usable with only `import FrameTransport`.
    @Test("Exposes Frame / PixelHandle / FrameMetadata / Lane / PixelFormat / BufferingPolicy")
    func exposesTypesWithoutCameraKit() {
        let lane: Lane = .primary
        let format: PixelFormat = .bgra8
        let policy: BufferingPolicy = .keepBuffered(depth: 3)

        // A trivial concrete metadata proves the marker protocol is conformable.
        struct ProbeMetadata: FrameMetadata {}

        var byte: UInt8 = 0
        withUnsafeMutableBytes(of: &byte) { raw in
            let handle = PixelHandle(
                baseAddress: UnsafeRawPointer(raw.baseAddress!),
                width: 1, height: 1, bytesPerRow: 4, format: format
            )
            let frame = Frame(
                lane: lane, index: 7, timestampNs: 123,
                pixels: handle, metadata: ProbeMetadata()
            )
            #expect(frame.lane == .primary)
            #expect(frame.index == 7)
            #expect(frame.timestampNs == 123)
            #expect(frame.pixels.format == .bgra8)
            #expect(frame.metadata is ProbeMetadata)
            if case .keepBuffered(let depth) = policy { #expect(depth == 3) }
        }
    }
}

@Suite("PixelHandle lease")
struct PixelHandleTests {

    // 3.2a — bytesPerRow reflects the real (padded) IOSurface stride, not width*4.
    @Test("bytesPerRow is the padded surface stride, not width*4")
    func strideIsPaddedNotWidthTimesFour() throws {
        // A 1-px-wide IOSurface-backed BGRA buffer: the surface pads each row far
        // beyond the naive width*4 == 4 bytes.
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(pb)

        let handle = try #require(PixelHandle(pixelBuffer: buffer, format: .bgra8))
        #expect(handle.width == 1)
        #expect(handle.height == 1)
        #expect(handle.format == .bgra8)
        // The whole point: stride is the padded surface stride, never width*4.
        #expect(handle.bytesPerRow > 1 * 4)
        #expect(handle.bytesPerRow == CVPixelBufferGetBytesPerRow(buffer))
    }

    // 3.2b — the release hook runs exactly once on deinit (the lock-release path).
    @Test("release hook fires on deinit (lock released)")
    func releaseFiresOnDeinit() {
        final class Flag { var released = false }
        let flag = Flag()

        var byte: UInt8 = 0
        withUnsafeMutableBytes(of: &byte) { raw in
            var handle: PixelHandle? = PixelHandle(
                baseAddress: UnsafeRawPointer(raw.baseAddress!),
                width: 1, height: 1, bytesPerRow: 4, format: .bgra8,
                release: { flag.released = true }
            )
            #expect(flag.released == false)
            #expect(handle != nil)
            handle = nil  // drop the last reference -> deinit -> release
            #expect(flag.released == true)
        }
    }
}

@Suite("BufferingPolicy semantics")
struct BufferingPolicyTests {

    // A minimal reference buffer that honors a BufferingPolicy. The policy enum
    // itself carries no behavior (this change is types-only); consumers
    // implement buffering. This proves the vocabulary is sufficient to express
    // the documented semantics.
    private func apply(_ policy: BufferingPolicy, to incoming: [Int]) -> [Int] {
        var buffer: [Int] = []
        for value in incoming {
            switch policy {
            case .blocking:
                buffer.append(value)  // no drops — producer is back-pressured
            case .latestWins:
                buffer = [value]  // keep newest 1
            case .keepBuffered(let depth):
                buffer.append(value)
                if buffer.count > depth { buffer.removeFirst() }  // drop oldest
            }
        }
        return buffer
    }

    // 3.3a — keepBuffered drops the oldest on overflow.
    @Test("keepBuffered(depth:) drops the oldest, keeps the newest depth")
    func keepBufferedDropsOldest() {
        let result = apply(.keepBuffered(depth: 3), to: [1, 2, 3, 4, 5])
        #expect(result == [3, 4, 5])
    }

    // 3.3b — latestWins keeps only the newest.
    @Test("latestWins keeps only the newest")
    func latestWinsKeepsNewest() {
        let result = apply(.latestWins, to: [1, 2, 3, 4, 5])
        #expect(result == [5])
    }
}
