import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing

@testable import CameraKit

// frame-delivery-rework: the FrameSet-delivery and C-ABI tests that used to live
// here (frame-set-publication, swift-consumer-drop, subscribe-then-cancel,
// register-callback, natural-stream-is-subscribable) were removed with FrameSet
// and the C-ABI path. Per-lane Frame delivery / drop / cancel / termination are
// covered by FrameDeliveryTests. The pool/seed/tracker-size/crop tests below are
// unaffected and stay.
@Suite("Stage06Tests", .progressLogged)
struct Stage06Tests {

    @Test func poolTrioAllocationOnOpen() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 128, height: 128)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())

        let (nb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        let (pb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        // Tracker pool is BGRA8 — use the 8-bit dequeue helper (Task 2 format change).
        let (tb, _) = try pipeline.texturePoolForTest.dequeueEightBitPoolTexture(
            pool: pipeline.trackerPoolForTest,
            width: pipeline.trackerSizeForTest.width,
            height: pipeline.trackerSizeForTest.height)

        #expect(CVPixelBufferGetIOSurface(nb) != nil)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
        #expect(CVPixelBufferGetIOSurface(tb) != nil)
    }

    // MARK: - P2b — first-open preview seeding (measurements 2026-05-20 §1)

    /// `seedPreviewMailboxes()` makes the processed lane non-nil before the first
    /// frame is encoded, and seeds the internal 16F natural texture for calibration.
    ///
    /// remove-natural-lane: the streaming natural BGRA8 buffer/texture mailboxes are
    /// gone; only the processed BGRA8 lane (Flutter bridge) and the 16F natural
    /// texture (calibration sampler) are seeded.
    @Test func seedPreviewMailboxesPopulatesLanesBeforeFirstFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)

        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())
        #expect(pipeline.latestProcessedBuffer == nil, "precondition: nil before any frame")
        pipeline.seedPreviewMailboxes()
        #expect(pipeline.latestProcessedBuffer != nil, "processed lane seeded on open")
        #expect(pipeline.latestProcessedBgra8Tex != nil)
        #expect(pipeline.latestNaturalTex16F != nil, "calibration RGBA16F texture seeded")

        // The bridge buffer must be BGRA8 (the unconditional Flutter delivery format).
        let proc8 = try #require(pipeline.latestProcessedBuffer)
        #expect(
            CVPixelBufferGetPixelFormatType(proc8) == kCVPixelFormatType_32BGRA,
            "BGRA8 lane must seed a BGRA8 buffer for the Flutter bridge")
        #expect(CVPixelBufferGetIOSurface(proc8) != nil, "seeded buffer is IOSurface-backed")
    }

    /// Seeding is idempotent: a second call must not replace a live mailbox.
    @Test func seedPreviewMailboxesIsIdempotent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())
        pipeline.seedPreviewMailboxes()
        let firstTex = try #require(pipeline.latestProcessedBgra8Tex)
        pipeline.seedPreviewMailboxes()  // guard: latestNaturalTex16F != nil → no-op
        let secondTex = try #require(pipeline.latestProcessedBgra8Tex)
        #expect(firstTex === secondTex, "second seed must not replace the live texture")
    }

    // MARK: - Test 4 — 06:tracker-downsample-height-matches-constant

    @Test func trackerDownsampleHeightMatchesConstant() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1280, height: 720)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())

        #expect(pipeline.trackerSizeForTest.height == Constants.trackerHeightPx)
        #expect(pipeline.trackerSizeForTest.width % 2 == 0)

        let rawW = Int((Double(Constants.trackerHeightPx) * Double(size.width) / Double(size.height)).rounded())
        let expectedEven = rawW - (rawW % 2)
        #expect(pipeline.trackerSizeForTest.width == expectedEven)
    }

    // MARK: - Test — 06:true-crop-output-resolution

    /// P2a true crop: a pipeline built with `outputSize`/`cropOrigin` emits
    /// natural (16F) + graded (BGRA8) textures sized to the crop region, not the sensor.
    ///
    /// The synthetic YUV sample buffer is sensor-sized (1024×768); Pass-1 reads
    /// the (256,192)-offset 512×384 sub-region into the output textures.
    @Test func trueCropOutputResolution() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1024, height: 768)
        let crop = Size(width: 512, height: 384)
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: sensor,
            outputSize: crop,
            cropOrigin: (256, 192),
            gateOpen: true)

        // Source is sensor-sized; Pass-1 reads the offset sub-region.
        // Arm the natural tap (opt C) so renderFrame writes the 16F natural texture.
        pipeline.setNaturalTapArmedForTest(true)
        let sb = try makeSyntheticYUVSampleBuffer(width: sensor.width, height: sensor.height)
        try pipeline.renderFrame(sampleBuffer: sb)
        // Mailbox stores happen in addCompletedHandler, which fires as part of
        // the transition to .completed — deterministic, no sleep.
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        let nat = try #require(pipeline.latestNaturalTex16F)
        let proc = try #require(pipeline.latestProcessedBgra8Tex)
        #expect(nat.width == 512)
        #expect(nat.height == 384)
        #expect(proc.width == 512)
        #expect(proc.height == 384)
    }

    // MARK: - Test — 06:default-crop-output-equals-capture

    /// P2a default (no crop): output textures equal the sensor size.
    @Test func defaultCropOutputEqualsCapture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 512, height: 384)
        let pipeline = try MetalPipeline(
            device: device, captureSize: sensor, gateOpen: true)
        #expect(pipeline.outputSize == sensor)

        pipeline.setNaturalTapArmedForTest(true)  // opt C: make renderFrame write natural
        let sb = try makeSyntheticYUVSampleBuffer(width: sensor.width, height: sensor.height)
        try pipeline.renderFrame(sampleBuffer: sb)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        let nat = try #require(pipeline.latestNaturalTex16F)
        #expect(nat.width == 512)
        #expect(nat.height == 384)
    }
}

// MARK: - Configurable tracker size — resolution logic

@Suite("ConfigurableTrackerSizeTests", .progressLogged)
struct ConfigurableTrackerSizeTests {

    // trackerHeight == primaryHeight → no-resize path selected, trackerSize == outputSize
    @Test func trackerHeightEqualsPrimarySelectsNoResizePath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1920, height: 1080)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            trackerHeight: size.height,
            gateOpen: true, consumers: ConsumerRegistry())

        #expect(pipeline.trackerSizeForTest == size)
        #expect(pipeline.trackerNeedsResizeForTest == false)
    }

    // Smaller height → aspect-preserved, even-rounded, resize path selected
    @Test func smallerTrackerHeightProducesAspectPreservedEvenSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1920, height: 1080)
        let trackerH = 480
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            trackerHeight: trackerH,
            gateOpen: true, consumers: ConsumerRegistry())

        let ts = pipeline.trackerSizeForTest
        #expect(ts.height == trackerH)
        #expect(ts.width % 2 == 0)
        let rawW = Int((Double(trackerH) * Double(size.width) / Double(size.height)).rounded())
        let expectedW = rawW - (rawW % 2)
        #expect(ts.width == expectedW)
        #expect(pipeline.trackerNeedsResizeForTest == true)
    }

    // trackerHeight above primaryHeight → clamped to primaryHeight → no-resize
    @Test func oversizedTrackerHeightClampedToPrimary() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1280, height: 720)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            trackerHeight: 9999,
            gateOpen: true, consumers: ConsumerRegistry())

        #expect(pipeline.trackerSizeForTest == size)
        #expect(pipeline.trackerNeedsResizeForTest == false)
    }

    // trackerHeight of 1 → clamped to 2 (minimum even value)
    @Test func minimumTrackerHeightClampedToTwo() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 128, height: 128)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            trackerHeight: 1,
            gateOpen: true, consumers: ConsumerRegistry())

        #expect(pipeline.trackerSizeForTest.height == 2)
        #expect(pipeline.trackerNeedsResizeForTest == true)
    }

    // SessionCapabilities.trackerResolution echoes the pipeline's resolved size
    @Test func sessionCapabilitiesTrackerResolutionMatchesPipelineSize() throws {
        let size = Size(width: 1920, height: 1080)
        let rawW = Int((Double(480) * Double(size.width) / Double(size.height)).rounded())
        let expectedW = rawW - (rawW % 2)
        let expectedResolution = Size(width: expectedW, height: 480)
        let caps = SessionCapabilities(
            supportedSizes: [size],
            activeCaptureResolution: size,
            activeCropRegion: Rect(x: 0, y: 0, width: size.width, height: size.height),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0,
            trackerResolution: expectedResolution)
        #expect(caps.trackerResolution == expectedResolution)
    }
}

// MARK: - Shared test helper

private enum SyntheticBufferError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed
    case sampleBufferFailed
}

private func makeSyntheticYUVSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer)
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw SyntheticBufferError.pixelBufferFailed(cvStatus)
    }
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescriptionOut: &formatDescription)
    guard let fd = formatDescription else {
        throw SyntheticBufferError.formatDescriptionFailed
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescription: fd, sampleTiming: &timing,
        sampleBufferOut: &sb)
    guard let sampleBuffer = sb else { throw SyntheticBufferError.sampleBufferFailed }
    return sampleBuffer
}
