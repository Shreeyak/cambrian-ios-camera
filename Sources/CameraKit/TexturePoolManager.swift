import Metal
import CoreVideo
import CoreMedia

/// Wraps `CVMetalTextureCache` to vend `MTLTexture` views over `CVPixelBuffer` planes
/// delivered by AVFoundation sample buffers.
///
/// ADR-06: CPU access to frame data is ONLY through IOSurface-backed `CVPixelBuffer`.
/// `MTLTexture.getBytes` is never called; all textures are zero-copy wrappers.
///
/// `@unchecked Sendable`: instances are captured in `@Sendable` closures on the
/// `delivery` queue. The texture cache is accessed only from that queue.
final class TexturePoolManager: @unchecked Sendable {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    /// Creates the `CVMetalTextureCache` backed by `device`.
    /// - Throws: `MetalError.textureCacheCreateFailed` if the cache cannot be created.
    init(device: MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw MetalError.textureCacheCreateFailed(code: status)
        }
        self.textureCache = cache
    }

    // scaffolding:01:simple-metal-passthrough — Stage 01 only exposes the Y plane;
    // full multi-plane CVPixelBufferPool trio (natural/processed/tracker) arrives Stage 08.

    /// Wraps the luma (Y) plane of a YUV `CVPixelBuffer` as an `MTLTexture`.
    ///
    /// Used by `MetalPipeline` for the YUV→RGBA compute pass (plane index 0, `.r8Unorm`).
    /// - Parameter pixelBuffer: An IOSurface-backed buffer from an AVFoundation sample buffer.
    /// - Returns: An `MTLTexture` view over the Y plane; zero-copy, no CPU readback.
    /// - Throws: `MetalError.textureWrapFailed` if `CVMetalTextureCacheCreateTextureFromImage` fails.
    func makeYTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        try makeTexture(from: pixelBuffer, planeIndex: 0, pixelFormat: .r8Unorm)
    }

    /// Wraps the interleaved chroma (CbCr) plane of a YUV `CVPixelBuffer` as an `MTLTexture`.
    ///
    /// Used by `MetalPipeline` for the YUV→RGBA compute pass (plane index 1, `.rg8Unorm`).
    /// - Parameter pixelBuffer: An IOSurface-backed buffer from an AVFoundation sample buffer.
    /// - Returns: An `MTLTexture` view over the CbCr plane; zero-copy, no CPU readback.
    /// - Throws: `MetalError.textureWrapFailed` if `CVMetalTextureCacheCreateTextureFromImage` fails.
    func makeCbCrTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        try makeTexture(from: pixelBuffer, planeIndex: 1, pixelFormat: .rg8Unorm)
    }

    /// Flushes stale entries from the texture cache.
    ///
    /// Call once per frame after the Metal command buffer completes so the cache
    /// does not hold retired `CVPixelBuffer` references longer than necessary.
    func flush() {
        CVMetalTextureCacheFlush(textureCache!, 0)
    }

    // MARK: - Private

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        let width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture else {
            throw MetalError.textureWrapFailed(code: status)
        }

        // Safe: create succeeded, so the texture object is guaranteed non-nil.
        return CVMetalTextureGetTexture(cvTexture)!
    }
}
