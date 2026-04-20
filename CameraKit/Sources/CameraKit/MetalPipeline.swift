import Metal
import CoreVideo
import CoreMedia

/// Owns the GPU pipeline that converts YUV sample buffers into an RGBA16Float texture
/// consumed by the MTKView render pass.
///
/// ADR-02: `encode(sampleBuffer:)` runs entirely on the `delivery` DispatchQueue.
/// No actor hops, no `Task {}`, no `await`, no `DispatchQueue.main.async`.
///
/// ADR-06: CPU access to frame data is ONLY through IOSurface-backed `CVPixelBuffer`.
/// `MTLTexture.getBytes` is never called.
///
/// `@unchecked Sendable`: instances are captured in `@Sendable` closures on the
/// `delivery` queue.
final class MetalPipeline: @unchecked Sendable {

    /// The output texture from Pass 1 (YUV→RGBA).
    /// Created once at init with `Constants.workingPixelFormat` (.rgba16Float).
    /// Storage mode: `.private` (GPU-only). Readable from the MTKView delegate.
    // scaffolding:01:simple-metal-passthrough — only Pass 1 (YUV→RGBA) is wired;
    // processed and tracker passes arrive Stage 02+.
    private(set) var naturalTex: MTLTexture

    private let commandQueue: MTLCommandQueue
    private let yuvToRgbaPSO: MTLComputePipelineState
    private let texturePool: TexturePoolManager

    /// - Parameters:
    ///   - device: From `MTLCreateSystemDefaultDevice()`.
    ///   - captureSize: Dimensions reported by `CameraSession.configure()`.
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(device: MTLDevice, captureSize: Size) throws {
        // 1. Texture pool (CVMetalTextureCache wrapper).
        texturePool = try TexturePoolManager(device: device)

        // 2. Load Metal library from the SwiftPM resource bundle.
        //    `device.makeDefaultLibrary()` without bundle: fails in a SwiftPM package.
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw MetalError.pipelineStateCompilation("Failed to load default Metal library: \(error.localizedDescription)")
        }

        // 3. Look up the YUV→RGBA compute kernel.
        guard let yuvFunction = library.makeFunction(name: "yuvToRgba") else {
            throw MetalError.pipelineStateCompilation("yuvToRgba not found")
        }

        // 4. Compile the compute pipeline state.
        do {
            yuvToRgbaPSO = try device.makeComputePipelineState(function: yuvFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Output texture — GPU-private RGBA16Float, same dimensions as capture.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Constants.workingPixelFormat,
            width: captureSize.width,
            height: captureSize.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        naturalTex = device.makeTexture(descriptor: desc)!
    }

    /// Encodes a YUV→RGBA compute pass for one camera frame.
    ///
    /// Must be called on the `delivery` DispatchQueue (ADR-02).
    /// Frames that cannot be processed are silently dropped; Stage 01 does not
    /// propagate per-frame errors upstream.
    func encode(sampleBuffer: CMSampleBuffer) throws {
        // 1. Unwrap the pixel buffer; drop frame if unavailable.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 2. Wrap YUV planes as zero-copy MTLTextures (ADR-06).
        let yTexture: MTLTexture
        let cbcrTexture: MTLTexture
        do {
            yTexture    = try texturePool.makeYTexture(from: pixelBuffer)
            cbcrTexture = try texturePool.makeCbCrTexture(from: pixelBuffer)
        } catch {
            return // drop frame on texture-wrap failure
        }

        // 3. Command buffer + compute encoder.
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(yuvToRgbaPSO)
        encoder.setTexture(yTexture,    index: 0)
        encoder.setTexture(cbcrTexture, index: 1)
        encoder.setTexture(naturalTex,  index: 2)

        // 4. Dispatch — 16×16 threadgroup size is adequate for Stage 01.
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width:  (naturalTex.width  + 15) / 16,
            height: (naturalTex.height + 15) / 16,
            depth:  1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        // 5. Flush the texture cache once the GPU is done with this frame.
        // scaffolding:01:skip-completion-guard — addCompletedHandler does not check sessionState
        // before touching flush state. D-10 guard arrives Stage 09.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.texturePool.flush()
        }

        commandBuffer.commit()
    }

    /// Returns the current output texture for the MTKView draw pass.
    /// Thread-safe: `naturalTex` is read-only after `init`.
    func currentTexture() -> MTLTexture {
        return naturalTex
    }
}
