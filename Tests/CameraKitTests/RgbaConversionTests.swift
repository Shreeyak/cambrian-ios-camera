import CoreMedia
import CoreVideo
import Metal
import Testing

@testable import CameraKit

// MARK: - Constants

@Suite("RGBA8 conversion — pixel-format constants")
struct RgbaConversionConstantsTests {

    @Test("eightBitLanePixelFormat is kCVPixelFormatType_32BGRA")
    func eightBitLanePixelFormatIsBGRA() {
        #expect(Constants.eightBitLanePixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test("eightBitLaneMetalFormat is .bgra8Unorm")
    func eightBitLaneMetalFormatIsBgra8Unorm() {
        #expect(Constants.eightBitLaneMetalFormat == MTLPixelFormat.bgra8Unorm)
    }

    @Test("streamPixelFormatString is the literal \"BGRA8\"")
    func streamPixelFormatStringMatchesBgra8() {
        #expect(Constants.streamPixelFormatString == "BGRA8")
    }
}

// MARK: - TexturePoolManager — BGRA8 factory

@Suite("RGBA8 conversion — BGRA8 pool factory")
struct RgbaConversionPoolFactoryTests {

    @Test("makeBgra8LanePool vends BGRA8 IOSurface-backed buffers")
    func makeBgra8LanePoolVendsBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        var bufOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &bufOut)
        #expect(status == kCVReturnSuccess)
        guard let buf = bufOut else {
            Issue.record("no buffer")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(buf) == 256)
        #expect(CVPixelBufferGetHeight(buf) == 256)
        #expect(CVPixelBufferGetIOSurface(buf) != nil)
    }

    @Test("dequeueEightBitPoolTexture wraps as MTLPixelFormat.bgra8Unorm")
    func dequeueEightBitPoolTextureWrapsAsBgra8Unorm() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        let pair = try tpm.dequeueEightBitPoolTexture(
            pool: pool, width: 256, height: 256)
        #expect(pair.texture.pixelFormat == .bgra8Unorm)
        #expect(pair.texture.width == 256)
        #expect(pair.texture.height == 256)
        #expect(
            CVPixelBufferGetPixelFormatType(pair.buffer) == kCVPixelFormatType_32BGRA)
    }
}

// MARK: - Pass-7 kernel discoverability

@Suite("RGBA8 conversion — Pass-7 kernel discoverability")
struct RgbaConversionKernelDiscoveryTests {

    @Test("rgba16fToBgra8 is discoverable in the SwiftPM Metal library")
    func kernelIsDiscoverable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let library = try device.makeDefaultLibrary(bundle: .module)
        #expect(library.makeFunction(name: "rgba16fToBgra8") != nil)
    }
}

// MARK: - MetalPipeline — BGRA8 pools always allocated

@Suite("RGBA8 conversion — MetalPipeline always allocates BGRA8 pools")
struct RgbaConversionPipelinePoolTests {

    @Test("Pipeline always allocates 8-bit pools for natural and processed")
    func pipelineAlwaysAllocatesEightBitPools() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let captureSize = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: captureSize,
            gateOpen: true)

        // Dequeue from each pool and verify the vended format — a non-nil pool
        // that vends the wrong format would still be a bug.
        var naturalBufOut: CVPixelBuffer?
        var processedBufOut: CVPixelBuffer?
        let naturalStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.eightBitNaturalPoolForTest, &naturalBufOut)
        let processedStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.eightBitProcessedPoolForTest, &processedBufOut)

        #expect(naturalStatus == kCVReturnSuccess)
        #expect(processedStatus == kCVReturnSuccess)
        if let nat = naturalBufOut {
            #expect(CVPixelBufferGetPixelFormatType(nat) == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(nat) == captureSize.width)
            #expect(CVPixelBufferGetHeight(nat) == captureSize.height)
        }
        if let proc = processedBufOut {
            #expect(CVPixelBufferGetPixelFormatType(proc) == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(proc) == captureSize.width)
            #expect(CVPixelBufferGetHeight(proc) == captureSize.height)
        }
        // Tracker lane is not converted — no Phase-3 Pigeon counterpart (Plan OQ #4).
        #expect(pipeline.eightBitTrackerPoolForTest == nil)
    }
}

// MARK: - End-to-end mailbox format

@Suite("RGBA8 conversion — mailbox format end-to-end")
struct RgbaConversionMailboxFormatTests {

    @Test("latest*Buffer is BGRA8 for natural and processed (conversion is unconditional)")
    func naturalProcessedAreBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)

        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        // Metal invokes completion handlers as part of the transition to
        // `.completed`; `waitUntilCompleted()` blocks until both finish.
        // Deterministic — no sleep.
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        guard let natural = pipeline.latestNaturalBufferForTest,
            let processed = pipeline.latestProcessedBufferForTest
        else {
            Issue.record("natural/processed mailboxes not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(natural) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(processed) == kCVPixelFormatType_32BGRA)
    }

    @Test("Texture mailboxes always return .rgba16Float")
    func textureMailboxesAlwaysRgba16Float() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)
        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        #expect(pipeline.latestNaturalTex?.pixelFormat == .rgba16Float)
        #expect(pipeline.latestProcessedTex?.pixelFormat == .rgba16Float)
    }
}

// MARK: - Tracker lane regression

@Suite("RGBA8 conversion — tracker lane stays RGBA16F")
struct RgbaConversionTrackerStaysRgba16fTests {

    @Test("Pipeline init does NOT allocate a tracker 8-bit pool")
    func noTrackerEightBitPool() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 256),
            gateOpen: true)
        #expect(pipeline.eightBitTrackerPoolForTest == nil)
    }
}

// MARK: - latestNaturalBufferRGBA16F preserves HDR precision for still capture

@Suite("RGBA8 conversion — captureNaturalPicture sources RGBA16F")
struct RgbaConversionNaturalCaptureSourceTests {

    @Test("latestNaturalBufferRGBA16F is RGBA16F (still-capture HDR fidelity)")
    func naturalCaptureBufferIsRgba16f() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)
        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        guard let buffer = pipeline.latestNaturalBufferRGBA16F else {
            Issue.record("RGBA16F natural-capture mailbox not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf)
    }
}

// MARK: - SessionCapabilities.streamPixelFormat is unconditionally BGRA8

@Suite("RGBA8 conversion — streamPixelFormat is unconditionally BGRA8")
struct RgbaConversionStreamPixelFormatTests {

    @Test("SessionCapabilities.streamPixelFormat equals the BGRA8 constant")
    func streamPixelFormatIsBgra8() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }
}

// MARK: - Helpers

/// Creates an IOSurface-backed YUV biplanar CVPixelBuffer wrapped in a
/// CMSampleBuffer for `encode(sampleBuffer:)`.
///
/// Mirrors the helper in Stage02Tests / Stage06Tests; named distinctly to avoid
/// linker overlap.
private func makeSyntheticYUVSampleBufferForRgba8Tests(
    width: Int, height: Int
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer
    )
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw MetalError.unsupportedFormat
    }
    var fdOut: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescriptionOut: &fdOut
    )
    guard let fd = fdOut else { throw MetalError.unsupportedFormat }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sbOut: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescription: fd,
        sampleTiming: &timing,
        sampleBufferOut: &sbOut
    )
    guard let sb = sbOut else { throw MetalError.unsupportedFormat }
    return sb
}
