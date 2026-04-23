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

    // scaffolding:01:simple-metal-passthrough — pool-backed per-frame textures replace
    // single-buffer shape. Stage 06: naturalPool/processedPool/trackerPool each vend
    // one IOSurface-backed buffer per frame; latest* mailboxes expose the most recent
    // texture to the MTKView draw pass without an actor hop (G-13).

    // MARK: - Per-frame pool properties (Stage 06)

    private let naturalPool: CVPixelBufferPool
    private let processedPool: CVPixelBufferPool
    private let trackerPool: CVPixelBufferPool

    private(set) var captureSize: Size
    private let trackerSize: Size

    /// Preview-facing "latest" textures.
    ///
    /// Written on the delivery queue after each successful encode; read by
    /// MTKView.draw via `currentTexture()` without an actor hop.
    /// `nonisolated(unsafe)` per G-13 / Stage 06 design: two pointer-sized stores
    /// accepted as a Stage 06 trade-off (single writer: delivery queue).
    nonisolated(unsafe) private(set) var latestNaturalTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestProcessedTex: MTLTexture?
    nonisolated(unsafe) private(set) var latestTrackerTex: MTLTexture?

    nonisolated(unsafe) private var latestNaturalBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestProcessedBuffer: CVPixelBuffer?
    nonisolated(unsafe) private var latestTrackerBuffer: CVPixelBuffer?

    // Still capture (Stage 07) — one slot, CPU-readable pool.
    private var stillCapturePool: CVPixelBufferPool?
    // Armed by StillCapture.armCapture(); cleared by completion handler after delivery.
    // Single-writer guarantee: CAS guard in StillCapture prevents concurrent arming.
    nonisolated(unsafe) var pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?
    private(set) var stillCaptureDequeueCount: Int = 0  // test seam

    // MARK: - Pass 4 — tracker downsample (Stage 06)

    /// Pass-4 tracker downsample PSO + sampler.
    ///
    /// Compiled in init().
    private let trackerDownsamplePSO: MTLComputePipelineState
    private let trackerSampler: MTLSamplerState

    /// Frame counter incremented per encode.
    ///
    /// Delivery-queue only.
    private var frameNumber: UInt64 = 0

    /// Consumer registry handed in from CameraEngine.
    let consumers: ConsumerRegistry

    // MARK: - Shared properties

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

    /// - Parameters:
    ///   - device: From `MTLCreateSystemDefaultDevice()`.
    ///   - captureSize: Dimensions reported by `CameraSession.configure()`.
    ///   - gate: Shared `ManagedAtomic<Bool>` owned by `CameraEngine` (ADR-09).
    ///   - consumers: `ConsumerRegistry` owned by `CameraEngine`; used to publish
    ///     `FrameSet` values on the delivery queue.
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(device: MTLDevice, captureSize: Size, gate: ManagedAtomic<Bool>, consumers: ConsumerRegistry) throws {
        submissionGate = gate
        self.consumers = consumers
        self.captureSize = captureSize

        // Tracker dimensions: preserve capture aspect ratio, scale to trackerHeightPx.
        let trackerH = Constants.trackerHeightPx
        let aspect = Double(captureSize.width) / Double(captureSize.height)
        let rawW = Int((Double(trackerH) * aspect).rounded())
        let trackerW = rawW - (rawW % 2)
        self.trackerSize = Size(width: trackerW, height: trackerH)

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

        // 4c. Center-patch sampler.
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

        // 4d. Host-side uniforms — Stage 05 mutex-protected storage (ADR-34, D-17).
        uniforms = Mutex(
            UniformStorage(
                color: .identity,
                crop: .full(width: captureSize.width, height: captureSize.height)
            ))

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Per-stream CVPixelBufferPools (Stage 06 pool-backed lineage).
        naturalPool = try texturePool.makeWorkingFormatPool(size: captureSize)
        processedPool = try texturePool.makeWorkingFormatPool(size: captureSize)
        trackerPool = try texturePool.makeWorkingFormatPool(size: trackerSize)

        // 8. Still-capture pool — 1-slot, CPU-readable, RGBA16F (Stage 07).
        let sPool = try texturePool.makeStillCapturePool(size: captureSize)
        self.stillCapturePool = sPool

        // 7. Pass-4 tracker downsample PSO + sampler.
        guard let trackerFunction = library.makeFunction(name: "trackerDownsample") else {
            throw MetalError.pipelineStateCompilation("trackerDownsample not found")
        }
        do {
            trackerDownsamplePSO = try device.makeComputePipelineState(function: trackerFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalError.pipelineStateCompilation("tracker sampler state")
        }
        trackerSampler = sampler
    }

    /// Encodes a YUV→RGBA + color-transform + tracker-downsample compute pass for one camera frame.
    ///
    /// Must be called on the `delivery` DispatchQueue (ADR-02).
    /// Frames that cannot be processed are silently dropped.
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

        // 3. Dequeue per-frame pool buffers.
        let naturalPair: (buffer: CVPixelBuffer, texture: MTLTexture)
        let processedPair: (buffer: CVPixelBuffer, texture: MTLTexture)
        do {
            naturalPair = try texturePool.dequeuePoolTexture(
                pool: naturalPool, width: captureSize.width, height: captureSize.height)
            processedPair = try texturePool.dequeuePoolTexture(
                pool: processedPool, width: captureSize.width, height: captureSize.height)
        } catch {
            return  // pool exhausted — drop frame
        }

        // Tracker buffer only when someone is subscribed to .tracker (no wasteful alloc).
        let trackerPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if consumers.hasSubscriber(.tracker) {
            trackerPair = try? texturePool.dequeuePoolTexture(
                pool: trackerPool, width: trackerSize.width, height: trackerSize.height)
        } else {
            trackerPair = nil
        }

        // 4. Snapshot uniforms — Stage 05 Mutex<UniformStorage> (ADR-34, D-17, Inv 6).
        //    `withLock` critical section contains only the struct-copy snapshot;
        //    no Metal encode or commit call appears inside the closure (05:mutex-scope-is-tight).
        let (colorSnapshot, cropSnapshot, metadataSnapshot): (ColorUniform, CropUniform, ProcessingMetadata) =
            uniforms.withLock { storage in
                let c = storage.color
                let r = storage.crop
                return (c, r, ProcessingMetadata(color: c, crop: r))
            }

        // 5. Command buffer.
        let commandBuffer = commandQueue.makeCommandBuffer()!

        let naturalTexI = naturalPair.texture
        let processedTexI = processedPair.texture

        // 6. Pass 1: YUV → RGBA into naturalTexI, with crop uniform.
        let pass1 = commandBuffer.makeComputeCommandEncoder()!
        pass1.setComputePipelineState(yuvToRgbaPSO)
        pass1.setTexture(yTexture, index: 0)
        pass1.setTexture(cbcrTexture, index: 1)
        pass1.setTexture(naturalTexI, index: 2)
        var cropLocal = cropSnapshot  // setBytes needs a mutable address
        pass1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (naturalTexI.width + 15) / 16,
            height: (naturalTexI.height + 15) / 16,
            depth: 1
        )
        pass1.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass1.endEncoding()

        // 7. Pass 2: color transform naturalTexI → processedTexI with ColorUniform.
        let pass2 = commandBuffer.makeComputeCommandEncoder()!
        pass2.setComputePipelineState(colorTransformPSO)
        pass2.setTexture(naturalTexI, index: 0)
        pass2.setTexture(processedTexI, index: 1)
        var colorLocal = colorSnapshot
        pass2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
        pass2.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass2.endEncoding()

        // 8. Pass 4: tracker downsample naturalTexI → trackerTexI (when subscribed).
        if let trackerPair {
            let trackerTexI = trackerPair.texture
            let pass4 = commandBuffer.makeComputeCommandEncoder()!
            pass4.setComputePipelineState(trackerDownsamplePSO)
            pass4.setTexture(naturalTexI, index: 0)
            pass4.setTexture(trackerTexI, index: 1)
            pass4.setSamplerState(trackerSampler, index: 0)
            let tgTracker = MTLSize(width: 16, height: 16, depth: 1)
            let groupsTracker = MTLSize(
                width: (trackerTexI.width + 15) / 16,
                height: (trackerTexI.height + 15) / 16,
                depth: 1
            )
            pass4.dispatchThreadgroups(groupsTracker, threadsPerThreadgroup: tgTracker)
            pass4.endEncoding()
        }

        // Pass 6: blit processedTexI → still readback buffer (gated on pending capture).
        // Origins must be (0,0,0) — non-zero origins on IOSurface textures break rendering
        // (CLAUDE.md §8 invariant). Dequeue from dedicated still pool, not processed pool.
        var stillPairForCompletion: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if pendingCaptureContinuation != nil, let sPool = stillCapturePool {
            if let pair = try? texturePool.dequeuePoolTexture(
                pool: sPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass6 = commandBuffer.makeBlitCommandEncoder()!
                pass6.copy(
                    from: processedTexI,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: processedTexI.width, height: processedTexI.height, depth: 1
                    ),
                    to: pair.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                pass6.endEncoding()
                stillPairForCompletion = pair
                stillCaptureDequeueCount += 1
            }
        }

        // 9. Gate check (ADR-09, D-06). Strict policy: every .inactive gates.
        guard submissionGate.load(ordering: .acquiring) else { return }

        // Capture all frame-local values before the completion handler. CMSampleBuffer
        // is not Sendable; capture derived values (CMTime, metadata snapshot) instead.
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureMeta = CaptureMetadata.placeholder()
        let meta = metadataSnapshot
        let fn = frameNumber
        let naturalBuf = naturalPair.buffer
        let processedBuf = processedPair.buffer
        let trackerBuf = trackerPair?.buffer
        let trackerTex = trackerPair?.texture
        let consumers = self.consumers
        let trackerForSet: CVPixelBuffer = trackerBuf ?? naturalBuf
        let stillBufForCompletion: CVPixelBuffer? = stillPairForCompletion?.buffer

        // scaffolding:01:skip-completion-guard — addCompletedHandler does not
        // check sessionState before touching flush state. D-10 guard arrives
        // Stage 09.
        commandBuffer.addCompletedHandler { [weak self] cb in
            // Deliver still readback buffer to StillCapture if Pass 6 ran.
            if let buf = stillBufForCompletion {
                let cont = self?.pendingCaptureContinuation
                self?.pendingCaptureContinuation = nil
                if cb.status == .error {
                    cont?.resume(
                        throwing: MetalError.commandBufferFailed(
                            code: (cb.error as NSError?)?.code ?? -1
                        ))
                } else {
                    cont?.resume(returning: buf)
                }
            }
            // Construct FrameSet from delivery-queue-local captures only.
            let fs = FrameSet(
                frameNumber: fn,
                captureTime: captureTime,
                natural: naturalBuf,
                processed: processedBuf,
                tracker: trackerForSet,
                capture: captureMeta,
                processing: meta,
                blurScore: 0.0,
                trackerQuality: .good
            )
            // Publish to subscribed lanes (nonisolated — no actor hop).
            consumers.yield(fs, stream: .natural)
            consumers.yield(fs, stream: .processed)
            if trackerBuf != nil {
                consumers.yield(fs, stream: .tracker)
            }
            // Update preview mailboxes for MTKView draw pass.
            guard let self else { return }
            self.latestNaturalBuffer = naturalBuf
            self.latestNaturalTex = naturalTexI
            self.latestProcessedBuffer = processedBuf
            self.latestProcessedTex = processedTexI
            if let tBuf = trackerBuf, let tTex = trackerTex {
                self.latestTrackerBuffer = tBuf
                self.latestTrackerTex = tTex
            }
            self.texturePool.flush()
        }

        // 10. Track for drain (ADR-09 waitUntilScheduled path) and increment.
        lastCommandBuffer = commandBuffer
        commitCount += 1
        frameNumber &+= 1
        commandBuffer.commit()
    }

    /// Blocks until the most recently committed command buffer has been scheduled.
    ///
    /// Called from CameraEngine.drainSubmittedFrame() on .inactive.
    /// Safe to call from any thread (Metal contract for waitUntilScheduled).
    func drainLastBuffer() {
        lastCommandBuffer?.waitUntilScheduled()
    }

    /// Returns the latest natural texture for the MTKView draw pass.
    ///
    /// Reads `latestNaturalTex` mailbox (nonisolated(unsafe) per G-13).
    /// Falls back to dequeuing a blank pool buffer on the first call before any frame arrives.
    func currentTexture() -> MTLTexture {
        if let t = latestNaturalTex { return t }
        if let pair = try? texturePool.dequeuePoolTexture(
            pool: naturalPool, width: captureSize.width, height: captureSize.height
        ) {
            latestNaturalBuffer = pair.buffer
            latestNaturalTex = pair.texture
            return pair.texture
        }
        fatalError("MetalPipeline.currentTexture: no preview texture available")
    }

    /// Returns the latest processed texture for the right-half MTKView.
    ///
    /// Reads `latestProcessedTex` mailbox (nonisolated(unsafe) per G-13).
    /// Falls back to dequeuing a blank pool buffer on the first call before any frame arrives.
    func currentProcessedTex() -> MTLTexture {
        if let t = latestProcessedTex { return t }
        if let pair = try? texturePool.dequeuePoolTexture(
            pool: processedPool, width: captureSize.width, height: captureSize.height
        ) {
            latestProcessedBuffer = pair.buffer
            latestProcessedTex = pair.texture
            return pair.texture
        }
        fatalError("MetalPipeline.currentProcessedTex: no preview texture available")
    }

    /// Stage 04: encodes the center-patch sampler over the latest processed texture and returns one RgbSample.
    ///
    /// Awaits completion, then computes per-channel trimmed mean from the readback buffers.
    func dispatchCenterPatch() async throws -> RgbSample {
        let patchSize = Constants.centerPatchSizePx
        let tex = currentProcessedTex()
        let texW = tex.width
        let texH = tex.height
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
        encoder.setTexture(tex, index: 0)
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

    // MARK: - Still capture (Stage 07)

    /// Arms the next-frame Pass 6 blit.
    ///
    /// Called by StillCapture after winning the CAS. Must be called before the next
    /// `encode()` invocation. The continuation will be resumed exactly once — either
    /// with the readback buffer on success, or with an error on GPU failure.
    func armCapture(continuation: CheckedContinuation<CVPixelBuffer, Error>) {
        pendingCaptureContinuation = continuation
    }

    // MARK: - Internal test seams

    /// Convenience init that creates its own gate and an empty ConsumerRegistry.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to import Atomics.
    convenience init(device: MTLDevice, captureSize: Size, gateOpen: Bool = true) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: ConsumerRegistry()
        )
    }

    /// Convenience init that accepts an explicit ConsumerRegistry but hides ManagedAtomic.
    ///
    /// Used by Stage06Tests so tests can inject a specific registry without importing Atomics.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        gateOpen: Bool = true,
        consumers: ConsumerRegistry
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: consumers
        )
    }

    /// Opens or closes the pipeline's submission gate.
    ///
    /// Used by Stage02Tests.
    func setGate(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    // MARK: - Test seams (internal — accessed via @testable import)

    // Stage 06: pool-backed buffer accessors replace the removed single-buffer properties.
    var latestNaturalBufferForTest: CVPixelBuffer? { latestNaturalBuffer }
    var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer }
    var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer }

    var texturePoolForTest: TexturePoolManager { texturePool }
    var naturalPoolForTest: CVPixelBufferPool { naturalPool }
    var processedPoolForTest: CVPixelBufferPool { processedPool }
    var trackerPoolForTest: CVPixelBufferPool { trackerPool }
    var trackerSizeForTest: Size { trackerSize }
    var stillCapturePoolForTest: CVPixelBufferPool? { stillCapturePool }
    var stillCaptureDequeueCountForTest: Int { stillCaptureDequeueCount }

    func setLatestNaturalForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestNaturalBuffer = buffer
        latestNaturalTex = texture
    }

    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        latestProcessedBuffer = buffer
        latestProcessedTex = texture
    }

    // Test-only: dispatches Pass 2 (color transform) over the latest natural texture,
    // awaits scheduled, and returns. Use after writing test-pattern bytes via lock/unlock.
    func encodePass2Only() async throws {
        let natTex = currentTexture()
        let procTex = currentProcessedTex()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }
        var color: ColorUniform = uniforms.withLock { $0.color }
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(natTex, index: 0)
        encoder.setTexture(procTex, index: 1)
        encoder.setBytes(&color, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (procTex.width + 15) / 16,
            height: (procTex.height + 15) / 16,
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
