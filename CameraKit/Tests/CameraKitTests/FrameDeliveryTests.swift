import CoreMedia
import CoreVideo
import FrameTransport
import Metal
import Testing

@testable import CameraKit

// frame-delivery-rework task 6.2: per-lane Frame delivery, per-lane buffering,
// tracker-absent-when-unsubscribed, and terminal-vs-transient termination.

private func makeBgraFrame(lane: Lane, index: UInt64) -> Frame {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let handle = PixelHandle(pixelBuffer: pb!, format: .bgra8)!
    return Frame(
        lane: lane, index: index, timestampNs: Int64(index),
        pixels: handle, metadata: CameraFrameMetadata())
}

@Suite("Frame delivery — per-lane streams")
struct FrameDeliveryTests {

    // A lane subscription yields only that lane's Frame, carrying its own index.
    @Test("a lane subscription yields only its lane")
    func singleLaneDelivery() async throws {
        let registry = ConsumerRegistry()
        let primaryStream = await registry.subscribe(stream: .primary, buffering: .latestWins)
        // Hold the tracker stream alive — discarding it terminates the
        // continuation and removes the subscriber before we can assert.
        let trackerStream = await registry.subscribe(stream: .tracker, buffering: .keepBuffered(depth: 4))

        registry.yield(makeBgraFrame(lane: .primary, index: 5), stream: .primary)

        var it = primaryStream.makeAsyncIterator()
        let got = try await it.next()
        #expect(got?.lane == .primary)
        #expect(got?.index == 5)
        // No tracker frame was yielded; the tracker subscriber simply never fires.
        #expect(registry.subscriberCount(for: .tracker) == 1)
        _ = trackerStream
    }

    // keepBuffered(depth:) keeps up to depth, dropping the OLDEST on overflow.
    @Test("keepBuffered(depth:) drops oldest, keeps newest depth")
    func keepBufferedDropsOldest() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .tracker, buffering: .keepBuffered(depth: 2))
        for i in 1...3 {
            registry.yield(makeBgraFrame(lane: .tracker, index: UInt64(i)), stream: .tracker)
        }
        var it = stream.makeAsyncIterator()
        let a = try await it.next()
        let b = try await it.next()
        #expect(a?.index == 2)  // 1 dropped (oldest)
        #expect(b?.index == 3)
    }

    // latestWins keeps only the newest unconsumed frame.
    @Test("latestWins keeps only the newest")
    func latestWinsKeepsNewest() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .primary, buffering: .latestWins)
        for i in 1...3 {
            registry.yield(makeBgraFrame(lane: .primary, index: UInt64(i)), stream: .primary)
        }
        var it = stream.makeAsyncIterator()
        let a = try await it.next()
        #expect(a?.index == 3)
    }

    // A fatal error finishes the lane stream by throwing.
    @Test("fatal error throws on the lane stream")
    func fatalThrows() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .primary, buffering: .latestWins)
        registry.failAllLanes(CameraError(code: .hardwareError, message: "boom", isFatal: true))
        var it = stream.makeAsyncIterator()
        await #expect(throws: CameraError.self) {
            _ = try await it.next()
        }
    }

    // CameraKit owns terminality: publishError throws on the stream only when
    // the error is fatal; a transient fault leaves the stream open and delivering.
    @Test("transient error leaves the stream open; fatal throws")
    func engineTerminationGating() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let stream = await engine.consumers.subscribe(stream: .primary, buffering: .latestWins)

        // Transient: stream stays open; a subsequent frame is delivered.
        await engine._emitErrorForTest(
            CameraError(code: .frameStall, message: "transient", isFatal: false))
        engine.consumers.yield(makeBgraFrame(lane: .primary, index: 9), stream: .primary)

        var it = stream.makeAsyncIterator()
        let got = try await it.next()
        #expect(got?.index == 9)

        // Fatal: stream finishes by throwing.
        await engine._emitErrorForTest(
            CameraError(code: .hardwareError, message: "fatal", isFatal: true))
        await #expect(throws: CameraError.self) {
            _ = try await it.next()
        }
    }

    // No tracker subscriber → MetalPipeline produces no tracker buffer and yields
    // no .tracker Frame (and never substitutes the full-res primary buffer).
    @Test("tracker lane absent when unsubscribed")
    func trackerAbsentWhenUnsubscribed() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let registry = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device, captureSize: size, gateOpen: true, consumers: registry)

        // Subscribe ONLY to .primary.
        let primaryStream = await registry.subscribe(stream: .primary, buffering: .latestWins)
        #expect(registry.hasSubscriber(.tracker) == false)

        let sb = try makeSyntheticYUV(width: size.width, height: size.height)
        try pipeline.renderFrame(sampleBuffer: sb)

        // Awaiting the primary frame guarantees the completion handler ran — that
        // is also where a tracker buffer would have been produced/stored.
        var it = primaryStream.makeAsyncIterator()
        let f = try await it.next()
        #expect(f?.lane == .primary)
        // No tracker buffer was produced or stored (no .tracker subscriber).
        #expect(pipeline.latestTrackerBuffer == nil)
    }
}

// MARK: - Helper

private enum YUVError: Error { case failed }

private func makeSyntheticYUV(width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pixelBuffer)
            == kCVReturnSuccess, let pb = pixelBuffer
    else { throw YUVError.failed }
    var fd: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
    guard let formatDescription = fd else { throw YUVError.failed }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sb)
    guard let sampleBuffer = sb else { throw YUVError.failed }
    return sampleBuffer
}

/// configurable-tracker-size §4.2/§4.3: real-open device coverage that the tracker
/// lane is delivered at the requested size — downscaled for a small `trackerHeight`,
/// full-res via the 1:1 blit when `trackerHeight == primaryHeight`. Serialized to
/// avoid camera contention. The tracker texture is produced only while a `.tracker`
/// subscriber exists (frame-delivery: tracker-absent-when-unsubscribed), so each
/// test holds a subscription.
@Suite("ConfigurableTrackerSizeDeviceTests", .serialized)
struct ConfigurableTrackerSizeDeviceTests {

    /// Poll the live tracker texture (produced a frame or two after subscribing).
    private func awaitTrackerTexture(_ engine: CameraEngine, tries: Int = 40) async -> (any MTLTexture)? {
        for _ in 0..<tries {
            if let t = engine.currentTrackerTexture() { return t }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// §4.2 — a `trackerHeight` smaller than primary delivers a downscaled tracker
    /// matching `SessionCapabilities.trackerResolution`.
    @Test func smallTrackerHeightDownscales() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let caps = try await engine.open(configuration: OpenConfiguration(trackerHeight: 256))
        let stream = await engine.consumers.subscribe(stream: .tracker, buffering: .latestWins)
        _ = stream  // hold the subscription so the pipeline produces the tracker texture
        #expect(caps.trackerResolution.height == 256)
        #expect(caps.trackerResolution.height < caps.activeCaptureResolution.height)
        let tex = await awaitTrackerTexture(engine)
        #expect(tex != nil)
        #expect(tex?.width == caps.trackerResolution.width)
        #expect(tex?.height == caps.trackerResolution.height)
        await engine.close()
    }

    /// §4.3 — `trackerHeight == primaryHeight` selects the no-resample 1:1 blit;
    /// `trackerResolution` equals the primary resolution and the tracker is full-res.
    @Test func trackerHeightEqualsPrimaryIsFullRes() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let probe = try await engine.open(configuration: OpenConfiguration())
        let primary = probe.activeCaptureResolution
        await engine.close()
        let caps = try await engine.open(
            configuration: OpenConfiguration(trackerHeight: primary.height))
        let stream = await engine.consumers.subscribe(stream: .tracker, buffering: .latestWins)
        _ = stream
        #expect(caps.trackerResolution == primary)
        let tex = await awaitTrackerTexture(engine)
        #expect(tex?.width == primary.width)
        #expect(tex?.height == primary.height)
        await engine.close()
    }
}
