import Atomics
import CoreMedia
import CoreVideo
import Metal
import Synchronization

// MARK: - Stage 04 uniform structs (host ↔ shader layout)

// Mirrors struct ColorUniform in ColorShaders.metal. Float (32-bit) layout.
// Fields map 1:1 to the Metal shader struct; no padding.
struct ColorUniform: Hashable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var blackR: Float
    var blackG: Float
    var blackB: Float
    var gamma: Float

    init(_ p: ProcessingParameters) {
        brightness = Float(p.brightness)
        contrast = Float(p.contrast)
        saturation = Float(p.saturation)
        blackR = Float(p.blackR)
        blackG = Float(p.blackG)
        blackB = Float(p.blackB)
        gamma = Float(p.gamma)
    }

    static let identity = ColorUniform(.identity)
}

// Mirrors struct CropUniform in YUVToRGBA.metal. UInt32 layout.
// Fields map 1:1 to the Metal shader struct; no padding.
struct CropUniform: Hashable {
    var originX: UInt32
    var originY: UInt32
    var width: UInt32
    var height: UInt32

    static func full(width: Int, height: Int) -> CropUniform {
        CropUniform(originX: 0, originY: 0, width: UInt32(width), height: UInt32(height))
    }
}

// Mirrors `struct PatchUniform` in CenterPatchKernel.metal.
struct PatchUniform {
    var patchSize: UInt32
    var patchOriginX: UInt32
    var patchOriginY: UInt32
}

// UniformsHost removed in Stage 05. Replaced by Mutex<UniformStorage> (ADR-34, D-17).

/// Owns the GPU pipeline that converts YUV sample buffers into an RGBA16Float texture
/// consumed by the MTKView render pass.
///
/// ADR-02: `encode(sampleBuffer:)` runs entirely on the `delivery` DispatchQueue.
/// No actor hops, no `Task {}`, no `await`, no `DispatchQueue.main.async`.
///
/// ADR-06: CPU access to frame data is ONLY through IOSurface-backed `CVPixelBuffer`.
/// `MTLTexture.getBytes` is never called.
///
/// ADR-09: `submissionGate` is checked after CPU-side encode and immediately before
/// `commandBuffer.commit()`. If the gate is false the frame is dropped; no commit occurs.
///
/// `@unchecked Sendable`: instances are captured in `@Sendable` closures on the
/// `delivery` queue. `lastCommandBuffer` is written on `delivery` and read via
/// `drainLastBuffer()` — safe under the @unchecked Sendable assertion.
final class MetalPipeline: @unchecked Sendable {

    // scaffolding:01:simple-metal-passthrough — only Pass 1 (YUV→RGBA) runs into
    // naturalTex; Pass 2 (color transform) writes processedTex; Pass 3+ (blit,
    // tracker, encoder, still readback) arrive Stage 06+.
    private(set) var naturalTex: MTLTexture
    private(set) var processedTex: MTLTexture

    // Retain the IOSurface-backed CVPixelBuffers for the session lifetime so the
    // CVMetalTexture views stay valid (Apple docs: "maintain a strong reference
    // to textureOut until the GPU finishes execution").
    private let naturalBuffer: CVPixelBuffer
    private let processedBuffer: CVPixelBuffer

    private let commandQueue: MTLCommandQueue
    private let yuvToRgbaPSO: MTLComputePipelineState
    private let colorTransformPSO: MTLComputePipelineState
    private let centerPatchPSO: MTLComputePipelineState
    private let patchBufferR: MTLBuffer
    private let patchBufferG: MTLBuffer
    private let patchBufferB: MTLBuffer
    /// Stage 05: `Mutex<UniformStorage>` protecting host-written shader params (ADR-34, D-17, Inv 6).
    ///
    /// Both color-transform and crop uniforms live inside `UniformStorage` so a single
    /// lock protects all host→GPU parameter paths. Writes route through
    /// `uniforms.withLock { $0 = new }` (CameraEngine); per-frame snapshots route
    /// through `uniforms.withLock { $0 }` at the top of `encode()` — the critical
    /// section contains only the struct-copy snapshot, never a Metal commit.
    let uniforms: Mutex<UniformStorage>
    private let texturePool: TexturePoolManager

    // ADR-09: GPU submission gate shared with CameraEngine. Loaded on delivery queue
    /// (.acquiring) before every commit; stored by engine actor (.sequentiallyConsistent).
    private let submissionGate: ManagedAtomic<Bool>

    // Most recently committed command buffer. Written on delivery queue after each
    // commit; read via drainLastBuffer() which is called from the engine actor.
    // Safe under the @unchecked Sendable assertion — writes cease once the gate is
    /// closed (sequentiallyConsistent store) before any drain read occurs.
    // `internal private(set)` — tests verify non-nil after a committed frame (02:wait-until-scheduled-on-inactive).
    internal private(set) var lastCommandBuffer: (any MTLCommandBuffer)?

    // Count of commandBuffer.commit() calls that passed the gate check.
    // Internal; used by 02:gate-closes-on-inactive to verify gate-before-commit (ADR-09).
    internal private(set) var commitCount: Int = 0

    /// Stage 05: most recent per-frame ProcessingMetadata snapshot from the mutex.
    ///
    /// Written on the delivery queue inside `encode()` immediately after the
    /// `uniforms.withLock` snapshot. Read by `CaptureDelegate` on the same delivery
    /// queue; population of downstream `FrameSet.processing` arrives in Stage 06.
    internal private(set) var lastProcessingMetadata: ProcessingMetadata?

    /// - Parameters:
    ///   - device: From `MTLCreateSystemDefaultDevice()`.
    ///   - captureSize: Dimensions reported by `CameraSession.configure()`.
    ///   - gate: Shared `ManagedAtomic<Bool>` owned by `CameraEngine` (ADR-09).
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(device: MTLDevice, captureSize: Size, gate: ManagedAtomic<Bool>) throws {
        submissionGate = gate

        // 1. Texture pool (CVMetalTextureCache wrapper).
        texturePool = try TexturePoolManager(device: device)

        // 2. Load Metal library from the SwiftPM resource bundle.
        //    `device.makeDefaultLibrary()` without bundle: fails in a SwiftPM package.
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw MetalError.pipelineStateCompilation(
                "Failed to load default Metal library: \(error.localizedDescription)")
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

        // 4b. Look up + compile the Stage-04 color-transform compute kernel.
        guard let colorFunction = library.makeFunction(name: "colorTransform") else {
            throw MetalError.pipelineStateCompilation("colorTransform not found")
        }
        do {
            colorTransformPSO = try device.makeComputePipelineState(function: colorFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }

        // 4d. Center-patch sampler.
        guard let patchFunction = library.makeFunction(name: "centerPatchHistogram") else {
            throw MetalError.pipelineStateCompilation("centerPatchHistogram not found")
        }
        do {
            centerPatchPSO = try device.makeComputePipelineState(function: patchFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }
        let patchPixelCount = Constants.centerPatchSizePx * Constants.centerPatchSizePx
        let patchByteSize = patchPixelCount * MemoryLayout<Float>.stride
        guard
            let bufR = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufG = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufB = device.makeBuffer(length: patchByteSize, options: .storageModeShared)
        else {
            throw MetalError.unsupportedFormat
        }
        patchBufferR = bufR
        patchBufferG = bufG
        patchBufferB = bufB

        // 4c. Host-side uniforms — Stage 05 mutex-protected storage (ADR-34, D-17).
        uniforms = Mutex(
            UniformStorage(
                color: .identity,
                crop: .full(width: captureSize.width, height: captureSize.height)
            ))

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Working textures — IOSurface-backed .shared CVPixelBuffers wrapped
        //    as RGBA16F MTLTextures (D-02, ADR-20 start-simple default; brief §7).
        let (naturalBuf, naturalTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
        let (processedBuf, processedTexture) = try texturePool.makeIOSurfaceBackedRGBA16F(size: captureSize)
        self.naturalBuffer = naturalBuf
        self.naturalTex = naturalTexture
        self.processedBuffer = processedBuf
        self.processedTex = processedTexture
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
            yTexture = try texturePool.makeYTexture(from: pixelBuffer)
            cbcrTexture = try texturePool.makeCbCrTexture(from: pixelBuffer)
        } catch {
            return  // drop frame on texture-wrap failure
        }

        // 3. Snapshot uniforms — Stage 05 Mutex<UniformStorage> (ADR-34, D-17, Inv 6).
        //    `withLock` critical section contains only the struct-copy snapshot;
        //    no Metal encode or commit call appears inside the closure (05:mutex-scope-is-tight).
        let (colorSnapshot, cropSnapshot, metadataSnapshot): (ColorUniform, CropUniform, ProcessingMetadata) =
            uniforms.withLock { storage in
                let c = storage.color
                let r = storage.crop
                return (c, r, ProcessingMetadata(color: c, crop: r))
            }
        // Store for downstream attachment to FrameSet (Stage 06 populates consumer path).
        lastProcessingMetadata = metadataSnapshot

        // 4. Command buffer.
        let commandBuffer = commandQueue.makeCommandBuffer()!

        // 5. Pass 1: YUV → RGBA into naturalTex, with crop uniform.
        let pass1 = commandBuffer.makeComputeCommandEncoder()!
        pass1.setComputePipelineState(yuvToRgbaPSO)
        pass1.setTexture(yTexture, index: 0)
        pass1.setTexture(cbcrTexture, index: 1)
        pass1.setTexture(naturalTex, index: 2)
        var cropLocal = cropSnapshot  // setBytes needs a mutable address
        pass1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (naturalTex.width + 15) / 16,
            height: (naturalTex.height + 15) / 16,
            depth: 1
        )
        pass1.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass1.endEncoding()

        // 6. Pass 2: color transform naturalTex → processedTex with ColorUniform.
        let pass2 = commandBuffer.makeComputeCommandEncoder()!
        pass2.setComputePipelineState(colorTransformPSO)
        pass2.setTexture(naturalTex, index: 0)
        pass2.setTexture(processedTex, index: 1)
        var colorLocal = colorSnapshot
        pass2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
        pass2.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass2.endEncoding()

        // 7. Gate check (ADR-09, D-06). Strict policy: every .inactive gates.
        guard submissionGate.load(ordering: .acquiring) else { return }

        // scaffolding:01:skip-completion-guard — addCompletedHandler does not
        // check sessionState before touching flush state. D-10 guard arrives
        // Stage 09.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.texturePool.flush()
        }

        // 8. Track for drain (ADR-09 waitUntilScheduled path) and increment.
        lastCommandBuffer = commandBuffer
        commitCount += 1
        commandBuffer.commit()
    }

    /// Blocks until the most recently committed command buffer has been scheduled.
    ///
    /// Called from CameraEngine.drainSubmittedFrame() on .inactive.
    /// Safe to call from any thread (Metal contract for waitUntilScheduled).
    func drainLastBuffer() {
        lastCommandBuffer?.waitUntilScheduled()
    }

    /// Returns the current output texture for the MTKView draw pass.
    ///
    /// Thread-safe: `naturalTex` is read-only after `init`.
    func currentTexture() -> MTLTexture {
        return naturalTex
    }

    /// Stage 04: returns the processedTex for the right-half MTKView.
    ///
    /// Thread-safe: `processedTex` is read-only after `init`.
    func currentProcessedTex() -> MTLTexture {
        return processedTex
    }

    /// Stage 04: encodes the center-patch sampler over `processedTex` and returns one RgbSample.
    ///
    /// Awaits completion, then computes per-channel trimmed mean from the readback buffers.
    func dispatchCenterPatch() async throws -> RgbSample {
        let patchSize = Constants.centerPatchSizePx
        let texW = processedTex.width
        let texH = processedTex.height
        guard texW >= patchSize, texH >= patchSize else {
            throw MetalError.unsupportedFormat
        }

        var uniform = PatchUniform(
            patchSize: UInt32(patchSize),
            patchOriginX: UInt32((texW - patchSize) / 2),
            patchOriginY: UInt32((texH - patchSize) / 2)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }

        encoder.setComputePipelineState(centerPatchPSO)
        encoder.setTexture(processedTex, index: 0)
        encoder.setBuffer(patchBufferR, offset: 0, index: 0)
        encoder.setBuffer(patchBufferG, offset: 0, index: 1)
        encoder.setBuffer(patchBufferB, offset: 0, index: 2)
        encoder.setBytes(&uniform, length: MemoryLayout<PatchUniform>.stride, index: 3)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (patchSize + 15) / 16,
            height: (patchSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        let bufR = patchBufferR
        let bufG = patchBufferG
        let bufB = patchBufferB
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }

        let count = patchSize * patchSize
        let trimCount = (count * Constants.centerPatchTrimPercent) / 100
        let r = trimmedMean(buffer: bufR, count: count, trim: trimCount)
        let g = trimmedMean(buffer: bufG, count: count, trim: trimCount)
        let b = trimmedMean(buffer: bufB, count: count, trim: trimCount)
        return RgbSample(r: Double(r), g: Double(g), b: Double(b))
    }

    private func trimmedMean(buffer: MTLBuffer, count: Int, trim: Int) -> Float {
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: count)
        var values = Array(UnsafeBufferPointer(start: ptr, count: count))
        values.sort()
        guard count > 2 * trim else { return 0 }
        let lo = trim
        let hi = count - trim
        var sum: Float = 0
        for i in lo..<hi { sum += values[i] }
        return sum / Float(hi - lo)
    }

    // MARK: - Internal test seams

    /// Convenience init that creates its own gate.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to import Atomics.
    convenience init(device: MTLDevice, captureSize: Size, gateOpen: Bool = true) throws {
        try self.init(device: device, captureSize: captureSize, gate: ManagedAtomic<Bool>(gateOpen))
    }

    /// Opens or closes the pipeline's submission gate.
    ///
    /// Used by Stage02Tests.
    func setGate(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    // MARK: - Test seams (internal — accessed via @testable import)

    // Test-only: returns the IOSurface-backed CVPixelBuffer for naturalTex,
    // for direct CPU read/write through CVPixelBufferLockBaseAddress.
    var naturalBufferForTest: CVPixelBuffer { naturalBuffer }
    var processedBufferForTest: CVPixelBuffer { processedBuffer }

    // Test-only: dispatches Pass 2 (color transform) over the current
    // `naturalTex` contents, awaits scheduled, and returns. Use after
    // writing test-pattern bytes into `naturalBufferForTest` via lock/unlock.
    func encodePass2Only() async throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }
        var color: ColorUniform = uniforms.withLock { $0.color }
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(naturalTex, index: 0)
        encoder.setTexture(processedTex, index: 1)
        encoder.setBytes(&color, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (processedTex.width + 15) / 16,
            height: (processedTex.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }
    }
}
