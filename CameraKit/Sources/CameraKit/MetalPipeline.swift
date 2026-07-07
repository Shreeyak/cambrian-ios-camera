import Atomics
import CoreMedia
import CoreVideo
import FrameTransport
import Metal
import MetalPerformanceShaders
import Synchronization

// MARK: - Stage 04 uniform structs (host ↔ shader layout)

// Mirrors struct ColorUniform in ColorShaders.metal. Float (32-bit) layout.
// Fields map 1:1 to the Metal shader struct; no padding.
struct ColorUniform: Hashable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var gamma: Float
    // linear-normalization-stage: fused per-channel affine (linear light), applied
    // pre-grade. Field order MUST match struct ColorUniform in ColorShaders.metal
    // exactly — setBytes copies `MemoryLayout<ColorUniform>.stride` bytes verbatim.
    var aR: Float
    var aG: Float
    var aB: Float
    var bR: Float
    var bG: Float
    var bB: Float
    var transferFn: UInt32
    /// Master gate for the linear-light normalization block.
    ///
    /// 0 ⇒ skip linearize→affine→re-encode entirely (off-path stays byte-identical
    /// to the legacy grade — the half-float sRGB round-trip is NOT bit-exact, and
    /// BT.601 can emit out-of-gamut values a clamp would alter). 1 ⇒ apply. Set iff
    /// any normalization toggle is on.
    var normalizeEnabled: UInt32

    init(_ p: ProcessingParameters) {
        brightness = Float(p.brightness)
        contrast = Float(p.contrast)
        saturation = Float(p.saturation)
        gamma = Float(p.gamma)
        // linear-normalization-stage §2.2 — fuse the per-channel normalization into
        // ONE affine evaluated in LINEAR light (the shader undoes gamma first):
        //
        //   normalized = gain · (x − blackPoint)   ⇒   out = a·x + b
        //     a = gain = wbChroma · whitePointLevel   (per channel; level is scalar)
        //     b = −a · blackPoint                     (black subtracted FIRST, then gain)
        //
        // Each contributing op is gated by its own toggle (identity value when off):
        // blackPoint → 0, wbChroma → 1, whitePointLevel → 1. All quantities are in
        // LINEAR light. WB-mode gating (chroma identity in auto WB) is applied
        // upstream by CameraEngine, so the stored coefficients are already effective.
        let bpR = p.blackPointEnabled ? p.blackPointR : 0.0
        let bpG = p.blackPointEnabled ? p.blackPointG : 0.0
        let bpB = p.blackPointEnabled ? p.blackPointB : 0.0
        let chromaR = p.wbChromaEnabled ? p.wbChromaR : 1.0
        let chromaG = p.wbChromaEnabled ? p.wbChromaG : 1.0
        let chromaB = p.wbChromaEnabled ? p.wbChromaB : 1.0
        // White point is a level on top of chroma — "level without chroma" is not a
        // valid state (design D4). Gate it by chroma here too, so even a hand-built
        // ProcessingParameters with whitePointEnabled but wbChromaEnabled == false
        // contributes identity instead of stretching an un-neutralized reference.
        let level = (p.whitePointEnabled && p.wbChromaEnabled) ? p.whitePointLevel : 1.0
        let gainR = chromaR * level
        let gainG = chromaG * level
        let gainB = chromaB * level
        aR = Float(gainR)
        aG = Float(gainG)
        aB = Float(gainB)
        bR = Float(-gainR * bpR)
        bG = Float(-gainG * bpG)
        bB = Float(-gainB * bpB)
        // sRGB only for now; the per-frame buffer-attachment transfer-function read
        // (kCVImageBufferTransferFunctionKey) lands with §2.1's Swift side.
        transferFn = 0
        // Gate: run the normalization block only when an op is actually active, so
        // the off-path stays byte-identical to the legacy grade (§2.3). White point
        // is intentionally NOT a trigger on its own — it's inert without chroma
        // (gated above), so an orphan whitePointEnabled must not switch on the linear
        // round-trip and break the byte-identical off-path guarantee.
        normalizeEnabled =
            (p.blackPointEnabled || p.wbChromaEnabled) ? 1 : 0
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

/// Owns the GPU pipeline that converts YUV sample buffers through RGBA16F
/// compute passes and delivers BGRA8 lane surfaces (preview, bridge, tracker,
/// still capture).
///
/// RGBA16F is the internal math format; BGRA8 is the single delivery format.
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

    // MARK: - Per-frame pool properties (Stage 06)

    private let naturalPool: CVPixelBufferPool
    private let processedPool: CVPixelBufferPool
    private let trackerPool: CVPixelBufferPool

    // RGBA8 lane conversion — unconditional for natural + processed.
    //
    // Pass-7 dispatches per-frame for natural + processed and writes into these
    // IOSurface-backed BGRA8 pools. The tracker lane uses a fused approach:
    // `trackerPool` is itself BGRA8, so Pass-4's downsample writes BGRA8 directly
    // with no separate conversion pass. All three buffer mailboxes deliver BGRA8
    // to `CameraEngine.currentPixelBuffer(stream:)` for the Phase-3 bridge. See
    // `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    private let eightBitNaturalPool: CVPixelBufferPool
    private let eightBitProcessedPool: CVPixelBufferPool
    private let rgba16fToBgra8PSO: MTLComputePipelineState
    /// Extracts a small centered region from a lane texture (black-point readback).
    private let extractCenterRegionPSO: MTLComputePipelineState

    private(set) var captureSize: Size

    /// P2a true crop — the output (natural/processed/still/encoder/8-bit) texture
    /// size.
    ///
    /// Equals `captureSize` when uncropped. When a crop is active, this is the
    /// crop-region size: the AVCaptureSession keeps producing `captureSize`
    /// capture-resolution buffers, and Pass-1 reads the `cropOrigin`-offset
    /// sub-region into these `outputSize` output textures (a sub-region
    /// resolution change, not a zoom). The SOURCE Y/CbCr textures still derive
    /// their size from the incoming sample buffer (= `captureSize`).
    private(set) var outputSize: Size

    /// P2a true crop — top-left of the sub-region read from the capture buffer,
    /// in capture-resolution pixels.
    ///
    /// `(0, 0)` when uncropped. Carried into Pass-1's `CropUniform.origin*` so
    /// the shader offsets every source read by it.
    private(set) var cropOrigin: (x: Int, y: Int)

    private let trackerSize: Size
    /// Resolved tracker lane dimensions (after clamping and even-rounding).
    ///
    /// Read by CameraEngine to populate `SessionCapabilities.trackerResolution`.
    var resolvedTrackerSize: Size { trackerSize }

    /// Internal RGBA16F "latest" textures — Metal-compute intermediates, NOT a
    /// delivery surface.
    ///
    /// `_latestNaturalTex16F` is the Pass-1 output sampled by WB / black-point
    /// calibration (`dispatchCenterPatchOnNatural` / `readbackNaturalCenterRegion`).
    /// It stays 16F because the calibration math wants float headroom near black —
    /// the camera is 8-bit-locked, so this precision only buys anything in-shader,
    /// never at the delivery boundary. The preview/bridge surfaces are the BGRA8
    /// mailboxes below. `_latestProcessedTex16F` is production-unused after
    /// optimization B (the graded surface is BGRA8) — it survives only as the
    /// target the Stage-04 grade golden tests install via `setLatestProcessedForTest`
    /// and read back through `encodeGradeOnly`.
    ///
    /// Single writer on the AVF delivery queue (`addCompletedHandler`
    /// callback); readers on MainActor / sessionQueue. See `Mailbox<T>` for the
    /// safety contract. G-13 / Stage 06 design.
    private let _latestNaturalTex16F = Mailbox<MTLTexture>()
    private let _latestProcessedTex16F = Mailbox<MTLTexture>()
    private let _latestTrackerTex = Mailbox<MTLTexture>()

    var latestNaturalTex16F: MTLTexture? { _latestNaturalTex16F.latest }
    var latestProcessedTex16F: MTLTexture? { _latestProcessedTex16F.latest }
    /// Tracker texture — `.bgra8Unorm`, downsampled from the **processed**
    /// (graded) lane (Pass-4 writes directly into the BGRA8 tracker pool; no
    /// separate 16F texture exists for this lane).
    var latestTrackerTex: MTLTexture? { _latestTrackerTex.latest }

    /// Preview/bridge-facing BGRA8 processed lane texture.
    ///
    /// The `.bgra8Unorm` view of the Pass-7p convert output, sharing its IOSurface
    /// with `_latestProcessedBuffer` — so the processed lane exposes one surface as
    /// both a `CVPixelBuffer` and an `MTLTexture`. The public
    /// `CameraEngine.currentProcessedTexture()` accessor reads this; the MTKView
    /// preview and the Phase-3 bridge get identical 8-bit pixels. Single writer on
    /// the delivery queue (`Mailbox<T>`). (remove-natural-lane: the natural BGRA8
    /// texture mailbox was removed with the streaming natural lane.)
    private let _latestProcessedBgra8Tex = Mailbox<MTLTexture>()

    var latestProcessedBgra8Tex: MTLTexture? { _latestProcessedBgra8Tex.latest }

    // Phase-2 §2c: lane CVPixelBuffer mailboxes — paired with the texture
    // mailboxes above. Single writer on the AVF delivery queue; readers
    // wherever the raw `CVPixelBuffer` is needed
    // (`CameraEngine.currentPixelBuffer(stream:)` for the Phase-3 zero-copy
    // FlutterTexture bridge). See `Mailbox<T>`. (remove-natural-lane: no natural
    // buffer mailbox — the streaming natural lane is gone.)
    private let _latestProcessedBuffer = Mailbox<CVPixelBuffer>()
    private let _latestTrackerBuffer = Mailbox<CVPixelBuffer>()

    var latestProcessedBuffer: CVPixelBuffer? { _latestProcessedBuffer.latest }
    var latestTrackerBuffer: CVPixelBuffer? { _latestTrackerBuffer.latest }

    /// PTS (in nanoseconds) of the most recent CMSampleBuffer encoded into `latestNaturalTex16F`.
    ///
    /// Read by `CameraEngine.awaitNaturalAfter` to confirm the natural texture
    /// has been refreshed past a target buffer timestamp (e.g. the `t_apply`
    /// from `setWhiteBalanceModeLocked(...handler:)`). Stored as Int64 ns to
    /// allow lock-free CAS reads. Single writer: completion handler on the
    /// delivery queue.
    let latestNaturalPTSNs: ManagedAtomic<Int64> = ManagedAtomic(0)

    // MARK: - Pass 4 — tracker resample

    /// MPS Lanczos scaler for the tracker downscale path.
    ///
    /// Used when `trackerNeedsResize == true` (tracker smaller than primary).
    /// Created once at pipeline init, reused per frame. When `trackerNeedsResize`
    /// is false the blit-copy path is taken instead and this scaler is not called.
    private let trackerLanczos: MPSImageLanczosScale
    // True when `trackerSize != outputSize` — selects the Lanczos downscale path;
    // false means a 1:1 blit copy (no resampling).
    private let trackerNeedsResize: Bool

    /// Frame counter incremented per encode.
    ///
    /// Delivery-queue only.
    private var frameNumber: UInt64 = 0

    // MARK: - linear-normalization-stage §7.1 — GPU-time profiler (temporary)
    //
    // Establishes the pre-fusion baseline (task 7.1) before any kernel fusion
    // (7.2). The whole pipeline shares ONE command buffer, so `gpuEndTime −
    // gpuStartTime` read in the completion handler is the total GPU wall-time for
    // the entire pointwise chain (decode → grade → pack) PLUS tracker (MPS) and
    // NV12 — i.e. the headroom-vs-budget number, measured through the GPU's own
    // timestamps. Deliberately NOT split into per-pass command buffers: that would
    // inject the very flushes/barriers fusion removes and rig the baseline toward
    // fusing (CLAUDE.md §8, tautological-evidence trap). Windowed average + max are
    // logged every `gpuProfileWindow` frames via `CameraKitLog` (.public) for the
    // `ipad-logs` skill. Flip `gpuProfilingEnabled` to true to capture; left off in
    // committed code. Remove (or keep flag-off) once §7.2/§7.3 land.
    private static let gpuProfilingEnabled = false
    private static let gpuProfileWindow = 120  // ~4 s at 30 fps
    private let gpuProfileSumMicros = ManagedAtomic<Int64>(0)
    private let gpuProfileMaxMicros = ManagedAtomic<Int64>(0)
    private let gpuProfileCount = ManagedAtomic<Int64>(0)

    /// Consumer registry handed in from CameraEngine.
    let consumers: ConsumerRegistry

    /// Latest device KVO snapshot, shared by reference with `CameraEngine`.
    ///
    /// Written by the engine's snapshot forwarder; read in the nonisolated
    /// completion handler to build per-frame `CameraFrameMetadata` — no actor hop.
    private let deviceSnapshot: Mailbox<DeviceStateSnapshot>

    // MARK: - Shared properties

    private let commandQueue: MTLCommandQueue
    // Fused decode→grade→pack PSOs (kernel-fusion): the production frame core. Two
    // variants of `yuvGradedFused`, selected at build time by the `kWritePacked`
    // function constant — `Pack` writes the BGRA8 tracker/mailbox output, `NoPack`
    // drops that binding for frames with no .tracker subscriber and no mailbox target.
    private let yuvGradedFusedPackPSO: MTLComputePipelineState
    private let yuvGradedFusedNoPackPSO: MTLComputePipelineState
    // Pre-fusion single-purpose PSOs. `yuvToRgba` (decode) and `rgba16fToBgra8`
    // (pack) are NO LONGER on the production path (folded into yuvGradedFused); they
    // — and `colorTransform` (grade) — are retained ONLY as the reference passes for
    // the fused-vs-separate equivalence test (`encodeSeparateCoreForTest`) and the
    // `encodeGradeOnly` grade golden tests. Do not add production callers.
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

    // Session token reference from the owning engine. Used by completion handler (D-10).
    private let engineSessionToken: ManagedAtomic<UInt64>

    #if DEBUG
    // Test-only: count of completion-handler invocations that no-op due to token mismatch.
    nonisolated(unsafe) var didNoOpCountForTest: UInt64 = 0
    #endif

    // Resume-latency diagnostic (one-shot). Armed by the engine actor in
    // `reconcile(.active)` the instant the gate reopens; the first frame to pass
    // the gate logs its commit (t1b) and the moment its texture is stored (t1c),
    // then clears the flag. Mirrors `CaptureDelegate.framesToLog` (t1): together
    // they split AVF delivery-resume from GPU/commit cost on a Control Center
    // resume. nonisolated(unsafe): set on the actor, read/cleared on the delivery
    // queue — a benign one-shot race, same pattern as `framesToLog`.
    nonisolated(unsafe) var logNextCommit: Bool = false

    // Hook for Metal-level errors; set by engine after init.
    var onMetalError: (@Sendable (MetalError) -> Void)?

    // MARK: - Stage 10: Pass 5 encoder (NV12 encode)

    /// NV12 pixel buffer pool for the encoder path.
    ///
    /// Allocated once in init().
    private let encoderPool: CVPixelBufferPool
    // Compute PSO for the gradedToNV12 kernel (Stage 10 / Task 7 shader; sources BGRA8).
    private let nv12EncodePSO: MTLComputePipelineState
    /// Engine sets this to true at startRecording(), false at stopRecording()/pause().
    ///
    /// Loaded on the delivery queue with .acquiring before each Pass 5 dispatch.
    let isRecording: ManagedAtomic<Bool> = ManagedAtomic(false)
    /// Installed by the engine after open().
    ///
    /// Pass 5 delivers the NV12 CVPixelBuffer + PTS.
    var onEncodedBufferReady: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

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
    ///   - captureSize: Capture-resolution (selected-format) dimensions reported
    ///     by `CameraSession.configure()`.
    ///   - outputSize: P2a true-crop output texture size. `nil` (default) means
    ///     no crop — output equals `captureSize`. When a crop is active, this is
    ///     the crop-region size.
    ///   - cropOrigin: P2a true-crop top-left in capture-resolution pixels. `(0, 0)` (default)
    ///     when uncropped.
    ///   - gate: Shared `ManagedAtomic<Bool>` owned by `CameraEngine` (ADR-09).
    ///   - consumers: `ConsumerRegistry` owned by `CameraEngine`; used to publish
    ///     `FrameSet` values on the delivery queue.
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        gate: ManagedAtomic<Bool>,
        consumers: ConsumerRegistry,
        engineSessionToken: ManagedAtomic<UInt64>,
        deviceSnapshot: Mailbox<DeviceStateSnapshot>,
        trackerHeight: Int? = nil
    ) throws {
        submissionGate = gate
        self.engineSessionToken = engineSessionToken
        self.consumers = consumers
        self.deviceSnapshot = deviceSnapshot
        self.captureSize = captureSize
        let resolvedOutputSize = outputSize ?? captureSize
        self.outputSize = resolvedOutputSize
        self.cropOrigin = cropOrigin

        // Tracker dimensions: preserve OUTPUT aspect ratio, scale to the requested
        // (or default) tracker height. P2a — the tracker downsamples the rendered
        // processed image (outputSize), so its aspect must follow outputSize, not
        // the capture resolution. The height is consumer-configurable
        // (`OpenConfiguration.trackerHeight`); clamp to `2 ... outputHeight` (the
        // lane is a downsample, never an upscale) and force even.
        let requestedH = trackerHeight ?? Constants.trackerHeightPx
        let clampedH = max(2, min(requestedH, resolvedOutputSize.height))
        let trackerH = clampedH - (clampedH % 2)
        if trackerH != requestedH {
            CameraKitLog.notice(
                .metal,
                "trackerHeight \(requestedH) clamped to \(trackerH) (output height \(resolvedOutputSize.height))"
            )
        }
        let aspect = Double(resolvedOutputSize.width) / Double(resolvedOutputSize.height)
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

        // 4b'. Fused decode→grade→pack — the production frame core. One kernel source
        //      (`yuvGradedFused`) compiled into two PSOs via the `kWritePacked`
        //      function constant: `Pack` (writes the BGRA8 tracker/mailbox output) and
        //      `NoPack` (drops that binding). See encodeGradedCore for selection.
        func makeFusedPSO(writePacked: Bool) throws -> MTLComputePipelineState {
            let constants = MTLFunctionConstantValues()
            var flag = writePacked
            constants.setConstantValue(&flag, type: .bool, index: 0)
            let fn: MTLFunction
            do {
                fn = try library.makeFunction(name: "yuvGradedFused", constantValues: constants)
            } catch {
                throw MetalError.pipelineStateCompilation(
                    "yuvGradedFused specialization failed: \(error.localizedDescription)")
            }
            return try device.makeComputePipelineState(function: fn)
        }
        do {
            yuvGradedFusedPackPSO = try makeFusedPSO(writePacked: true)
            yuvGradedFusedNoPackPSO = try makeFusedPSO(writePacked: false)
        } catch let e as MetalError {
            throw e
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
        //     P2a — the crop uniform is now set ONCE at construction and carries
        //     the capture-resolution-pixel origin of the sub-region Pass-1 reads. It is no
        //     longer mutated per-frame (the Stage-04 black-out masking retired).
        //     `width`/`height` mirror the output (crop-region) size; the shader
        //     ignores them and uses the output texture's own dims.
        uniforms = Mutex(
            UniformStorage(
                color: .identity,
                crop: CropUniform(
                    originX: UInt32(cropOrigin.x),
                    originY: UInt32(cropOrigin.y),
                    width: UInt32(resolvedOutputSize.width),
                    height: UInt32(resolvedOutputSize.height)
                )
            ))

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Per-stream CVPixelBufferPools (Stage 06 pool-backed lineage).
        //    P2a — natural/processed pools size to `outputSize` (the crop region),
        //    NOT the capture resolution. Tracker derives from `trackerSize` (already
        //    scaled to the output aspect above).
        naturalPool = try texturePool.makeWorkingFormatPool(size: resolvedOutputSize)
        processedPool = try texturePool.makeWorkingFormatPool(size: resolvedOutputSize)
        // Tracker pool is BGRA8 — Pass-4's kernel writes `float4` via
        // `texture2d<float, access::write>`, so a `.bgra8Unorm` output texture
        // clamps [0,1] and stores BGRA8 with no shader edit (Task 2, 8-bit
        // BGRA end-to-end delivery design).
        trackerPool = try texturePool.makeBgra8LanePool(size: trackerSize)

        // 6b. RGBA8 lane conversion — unconditional for natural + processed.
        //     P2a — sized to outputSize (the crop region), not the capture resolution.
        self.eightBitNaturalPool = try texturePool.makeBgra8LanePool(size: resolvedOutputSize)
        self.eightBitProcessedPool = try texturePool.makeBgra8LanePool(size: resolvedOutputSize)
        guard let fnConvert = library.makeFunction(name: "rgba16fToBgra8") else {
            throw MetalError.pipelineStateCompilation("rgba16fToBgra8 missing")
        }
        self.rgba16fToBgra8PSO = try device.makeComputePipelineState(function: fnConvert)
        guard let fnExtract = library.makeFunction(name: "extractCenterRegion") else {
            throw MetalError.pipelineStateCompilation("extractCenterRegion missing")
        }
        self.extractCenterRegionPSO = try device.makeComputePipelineState(function: fnExtract)

        // 9. Stage 10: encoder NV12 pool + gradedToNV12 PSO (Pass 5).
        //    P2a — Pass-5 encodes processedTexI (outputSize); NV12 pool follows.
        encoderPool = try texturePool.makeEncoderNV12Pool(size: resolvedOutputSize)
        guard let fnEncode = library.makeFunction(name: "gradedToNV12") else {
            throw MetalError.pipelineStateCompilation("gradedToNV12 missing")
        }
        nv12EncodePSO = try device.makeComputePipelineState(function: fnEncode)

        // 7. Pass-4 tracker: MPS Lanczos scaler (downscale path) + resize flag.
        trackerLanczos = MPSImageLanczosScale(device: device)
        trackerNeedsResize = (trackerSize != resolvedOutputSize)

    }

    /// Encodes a YUV→RGBA + color-transform + tracker-downsample compute pass for one camera frame.
    ///
    /// Must be called on the `delivery` DispatchQueue (ADR-02).
    /// Frames that cannot be processed are silently dropped.
    /// Shared graded core — encodes `decode → grade → pack` into `commandBuffer`
    /// as ONE fused dispatch (`yuvGradedFused`), producing its outputs from
    /// registers after a single YUV read.
    ///
    /// Two outputs (the 16F `processed` texture was retired — optimization B; every
    /// graded consumer now reads the BGRA8 `packed` surface):
    /// - **natural** (RGBA16F): YUV→RGB + crop. The calibration tap only.
    /// - **packed** (BGRA8): the graded frame (`gradePixel` — the single insertion
    ///   point for the linear-light normalization, §2). The one graded surface:
    ///   tracker source, delivery mailbox, and NV12 recorder all read it. Written
    ///   only when `packed` is non-nil (NoPack PSO variant otherwise) — the streaming
    ///   path passes nil with no .tracker subscriber / on pool exhaustion; the still
    ///   path always supplies a target.
    ///
    /// Called by both `renderFrame` (streaming) and `renderStill` (one-shot) so
    /// the grade — and the normalization folded into it — lives in exactly one
    /// place. Encodes into the caller's command buffer; the caller owns pool
    /// dequeue, commit, and any post-core passes (tracker / NV12 / completion).
    private func encodeGradedCore(
        into commandBuffer: MTLCommandBuffer,
        y yTexture: MTLTexture,
        cbcr cbcrTexture: MTLTexture,
        natural naturalTex: MTLTexture,
        packed packedTex: MTLTexture?,
        color colorSnapshot: ColorUniform,
        crop cropSnapshot: CropUniform,
        threadGroups: MTLSize,
        threadGroupSize: MTLSize
    ) {
        // Fused decode → grade (+ normalization) → pack in ONE dispatch. Reads the
        // YUV planes once and produces natural (16F) and — when a `packedTex` target
        // is supplied — packed (BGRA8), from registers. This eliminates the two
        // full-frame RGBA16F re-reads the old three-encoder path paid. Kernel math
        // and the precision note live in ColorShaders.metal `yuvGradedFused`.
        //
        // Variant select: the NoPack PSO drops the BGRA8 write entirely (no bound
        // packed texture) when `packedTex == nil` — a frame with no .tracker
        // subscriber and no mailbox target. The still path always supplies `packedTex`.
        let core = commandBuffer.makeComputeCommandEncoder()!
        core.setComputePipelineState(packedTex != nil ? yuvGradedFusedPackPSO : yuvGradedFusedNoPackPSO)
        core.setTexture(yTexture, index: 0)
        core.setTexture(cbcrTexture, index: 1)
        core.setTexture(naturalTex, index: 2)
        if let packedTex {
            core.setTexture(packedTex, index: 3)
        }
        var cropLocal = cropSnapshot  // setBytes needs a mutable address
        core.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        var colorLocal = colorSnapshot
        core.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 1)
        core.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        core.endEncoding()
    }

    func renderFrame(sampleBuffer: CMSampleBuffer) throws {
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

        // 3. Dequeue per-frame pool buffers. The 16F processed pool was retired from
        //    production (optimization B) — the graded surface is BGRA8 (`packed`); the
        //    natural 16F pool remains for the calibration tap.
        let naturalPair: (buffer: CVPixelBuffer, texture: MTLTexture)
        do {
            naturalPair = try texturePool.dequeuePoolTexture(
                pool: naturalPool, width: outputSize.width, height: outputSize.height)
        } catch {
            return  // pool exhausted — drop frame
        }

        // Tracker buffer only when someone is subscribed to .tracker (no wasteful alloc).
        // Pool is BGRA8; dequeueEightBitPoolTexture wraps it as .bgra8Unorm — Pass-4's
        // shader writes float4 into a bgra8Unorm output which clamps and stores BGRA8.
        let trackerPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if consumers.hasSubscriber(.tracker) {
            trackerPair = try? texturePool.dequeueEightBitPoolTexture(
                pool: trackerPool, width: trackerSize.width, height: trackerSize.height)
        } else {
            trackerPair = nil
        }

        // 4. Snapshot uniforms — Stage 05 Mutex<UniformStorage> (ADR-34, D-17, Inv 6).
        //    `withLock` critical section contains only the struct-copy snapshot;
        //    no Metal encode or commit call appears inside the closure (05:mutex-scope-is-tight).
        // ProcessingMetadata snapshot is no longer delivered (CameraFrameMetadata
        // is minimal in frame-delivery-rework; fields land in frame-metadata-signals).
        let (colorSnapshot, cropSnapshot): (ColorUniform, CropUniform) =
            uniforms.withLock { storage in
                (storage.color, storage.crop)
            }

        // 5. Command buffer.
        let commandBuffer = commandQueue.makeCommandBuffer()!

        let naturalTexI = naturalPair.texture

        // Threadgroup config for the pointwise core passes (16×16 tiles over outputSize).
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (naturalTexI.width + 15) / 16,
            height: (naturalTexI.height + 15) / 16,
            depth: 1
        )

        // Dequeue the BGRA8 "pack" target for the processed lane-buffer mailbox.
        // On the rare miss (genuine alloc/wrap failure) the processed frame is
        // dropped — NOT delivered as 16F (see the no-fallback note below). The pack
        // runs (inside the core) before Pass-4
        // (tracker) so both tracker paths (Lanczos and blit) can source the BGRA8
        // result (bgra8→bgra8, sidestepping any rgba16f→bgra8 MPS format-compat
        // concern). remove-natural-lane: the per-frame natural pack was cut — the
        // streaming natural lane is gone. The internal 16F natural texture (decode
        // output, `_latestNaturalTex16F`) is preserved for calibration; the natural
        // *still* (`captureNaturalPicture`) converts on demand via `renderStill`.
        let processedEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)? =
            try? texturePool.dequeueEightBitPoolTexture(
                pool: eightBitProcessedPool, width: outputSize.width, height: outputSize.height)

        // 6–7. Shared graded core: decode → grade (+ normalization) → pack (BGRA8).
        encodeGradedCore(
            into: commandBuffer,
            y: yTexture, cbcr: cbcrTexture,
            natural: naturalTexI,
            packed: processedEightBitPair?.texture,
            color: colorSnapshot, crop: cropSnapshot,
            threadGroups: threadGroups, threadGroupSize: threadGroupSize)

        // 8. Pass 4: tracker resample — when subscribed and BGRA8 processed is available.
        //    Sources the GRADED (Pass-2) image via the BGRA8 processed texture produced
        //    above so brightness/contrast/saturation/gamma/black-balance help the tracker.
        //    Two paths based on whether the tracker needs resizing:
        //    - Resize (trackerNeedsResize): MPS Lanczos anti-aliased downscale (bgra8→bgra8).
        //      MPS manages its own encoder — no open encoder may be active when encode() fires.
        //    - No-resize: 1:1 MTLBlitCommandEncoder copy, origins (0,0,0) (IOSurface invariant).
        if let trackerPair, let processedBgra8Tex = processedEightBitPair?.texture {
            if trackerNeedsResize {
                // Lanczos downscale: MPS opens/closes its own encoder.
                trackerLanczos.encode(
                    commandBuffer: commandBuffer,
                    sourceTexture: processedBgra8Tex,
                    destinationTexture: trackerPair.texture)
            } else {
                // 1:1 blit copy — no resampling. Origins (0,0,0) per IOSurface-blit invariant.
                let blit = commandBuffer.makeBlitCommandEncoder()!
                let sz = MTLSize(
                    width: processedBgra8Tex.width, height: processedBgra8Tex.height, depth: 1)
                blit.copy(
                    from: processedBgra8Tex,
                    sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: sz,
                    to: trackerPair.texture,
                    destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        }

        // Pass 5: RGBA16F → NV12 encode (Stage 10). Runs only while recording.
        // Pool exhaustion drops this frame from the recorder; preview is unaffected
        // (domain 06 Recording-Sink Back-Pressure).
        var encoderPairForCompletion: (buffer: CVPixelBuffer, yTex: MTLTexture, cbcrTex: MTLTexture)?
        // NV12 sources the BGRA8 graded surface (`packed`) — optimization B retired the
        // 16F processed texture. If the pack buffer was dropped this frame (rare
        // alloc/wrap failure), skip the recorder for this frame (preview unaffected).
        if isRecording.load(ordering: .acquiring), let gradedTex = processedEightBitPair?.texture {
            if let enc = try? texturePool.dequeueEncoderBuffer(pool: encoderPool) {
                let pass5 = commandBuffer.makeComputeCommandEncoder()!
                pass5.setComputePipelineState(nv12EncodePSO)
                pass5.setTexture(gradedTex, index: 0)
                pass5.setTexture(enc.yTex, index: 1)
                pass5.setTexture(enc.cbcrTex, index: 2)
                let cbcrW = enc.cbcrTex.width
                let cbcrH = enc.cbcrTex.height
                let tg5 = MTLSize(width: 16, height: 16, depth: 1)
                let groups5 = MTLSize(
                    width: (cbcrW + 15) / 16,
                    height: (cbcrH + 15) / 16,
                    depth: 1
                )
                pass5.dispatchThreadgroups(groups5, threadsPerThreadgroup: tg5)
                pass5.endEncoding()
                encoderPairForCompletion = enc
            }
        }

        // 9. Gate check (ADR-09, D-06). Strict policy: every .inactive gates.
        guard submissionGate.load(ordering: .acquiring) else { return }

        // Resume probe (one-shot): if the gate was just reopened this is the first
        // frame through. Snapshot + clear so t1b (commit) and t1c (texture stored)
        // each fire exactly once. Captured into the completion handler below.
        let logFirstAfterGate = logNextCommit
        if logFirstAfterGate { logNextCommit = false }

        // Capture all frame-local values before the completion handler. CMSampleBuffer
        // is not Sendable; capture derived values (CMTime, metadata snapshot) instead.
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let fn = frameNumber
        let trackerBuf = trackerPair?.buffer
        let trackerTex = trackerPair?.texture
        let consumers = self.consumers
        // Stage 10: extract NV12 buffer for delivery in completion handler.
        let encoderBufForCompletion: CVPixelBuffer? = encoderPairForCompletion?.buffer
        // Capture the BGRA8-converted processed buffer + texture for the mailbox store
        // in the completion handler. The buffer and texture share one IOSurface.
        // Tracker buffer is already BGRA8 (pool fused in Pass-4). (remove-natural-lane:
        // no natural BGRA8 capture — the streaming natural lane is gone.)
        let processedEightBitBuf: CVPixelBuffer? = processedEightBitPair?.buffer
        let processedEightBitTex: MTLTexture? = processedEightBitPair?.texture

        // Per-lane delivery is BGRA8 ONLY. If the BGRA8 pack buffer is missing —
        // a genuine allocation / texture-cache-wrap failure, NOT normal
        // back-pressure (these pools have no allocation threshold, so they GROW on
        // demand rather than block) — DROP this processed frame. The old
        // `?? processedBuf` fallback delivered the 16F `processedBuf` tagged
        // `.bgra8`, which a consumer would misread (8 B/px read as 4). The tracker
        // lane has likewise never had a fallback (frame-delivery-rework §4.2).

        // D-10: capture the session token at commit. Handler no-ops if the token has
        // advanced (close() / recovery ran) — prevents stale FrameSet publish and
        // stale mailbox stores after teardown/recovery (G-20).
        let tokenAtCommit = self.engineSessionToken.load(ordering: .acquiring)
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let liveToken = self.engineSessionToken.load(ordering: .acquiring)
            if liveToken != tokenAtCommit {
                // Session advanced — drop this frame's delivery entirely.
                #if DEBUG
                self.didNoOpCountForTest &+= 1
                #endif
                return
            }
            // Metal-level error classification (G-02 / ADR-15).
            if cb.status == .error {
                let code = (cb.error as NSError?)?.code ?? -1
                self.onMetalError?(MetalError.commandBufferFailed(code: code))
                return
            }
            // Stage 10: deliver NV12 encoder buffer if Pass 5 ran and command buffer succeeded.
            if let encBuf = encoderBufForCompletion, cb.status == .completed {
                self.onEncodedBufferReady?(encBuf, captureTime)
            }
            // §7.1 baseline profiler — total GPU wall-time of the shared command
            // buffer (whole pointwise chain + tracker + NV12). See the property block.
            if Self.gpuProfilingEnabled, cb.status == .completed {
                let micros = Int64((cb.gpuEndTime - cb.gpuStartTime) * 1_000_000)
                if micros > 0 {
                    self.gpuProfileSumMicros.wrappingIncrement(by: micros, ordering: .relaxed)
                    var curMax = self.gpuProfileMaxMicros.load(ordering: .relaxed)
                    while micros > curMax {
                        let (ok, actual) = self.gpuProfileMaxMicros.compareExchange(
                            expected: curMax, desired: micros, ordering: .relaxed)
                        if ok { break }
                        curMax = actual
                    }
                    let n = self.gpuProfileCount.wrappingIncrementThenLoad(
                        by: 1, ordering: .relaxed)
                    if n % Int64(Self.gpuProfileWindow) == 0 {
                        let sum = self.gpuProfileSumMicros.exchange(0, ordering: .relaxed)
                        let mx = self.gpuProfileMaxMicros.exchange(0, ordering: .relaxed)
                        let avgMs = Double(sum) / Double(Self.gpuProfileWindow) / 1000.0
                        let maxMs = Double(mx) / 1000.0
                        let rec = self.isRecording.load(ordering: .acquiring)
                        CameraKitLog.notice(
                            .metal,
                            "[gpuprofile] avg=\(String(format: "%.2f", avgMs))ms "
                                + "max=\(String(format: "%.2f", maxMs))ms over "
                                + "\(Self.gpuProfileWindow) frames "
                                + "out=\(naturalTexI.width)x\(naturalTexI.height) "
                                + "recording=\(rec) (budget 33.3ms)")
                    }
                }
            }
            // Publish per-lane Frames (nonisolated — no actor hop). Each Frame
            // carries a PixelHandle lease that locks the pool buffer until the
            // consumer releases it (the holdable lease, §4.1). Both lanes share
            // `fn` (the cross-lane correlation index) and `tsNs`.
            let tsNs = Int64(CMTimeGetSeconds(captureTime) * 1_000_000_000)
            // frame-metadata-signals: build typed convergence metadata from the
            // latest device KVO snapshot. `nil` before the first snapshot →
            // all-unknown → `settled == false` (fail-safe: never seed pre-snapshot).
            let frameMeta =
                self.deviceSnapshot.latest.map(CameraFrameMetadata.init(snapshot:))
                ?? CameraFrameMetadata()
            if let processedEightBitBuf,
                let primaryPixels = PixelHandle(pixelBuffer: processedEightBitBuf, format: .bgra8)
            {
                consumers.yield(
                    Frame(
                        lane: .primary, index: fn, timestampNs: tsNs,
                        pixels: primaryPixels, metadata: frameMeta),
                    stream: .primary)
            }
            // Tracker only when produced (a subscriber existed at dequeue time).
            if let trackerBuf, let trackerPixels = PixelHandle(pixelBuffer: trackerBuf, format: .bgra8) {
                consumers.yield(
                    Frame(
                        lane: .tracker, index: fn, timestampNs: tsNs,
                        pixels: trackerPixels, metadata: frameMeta),
                    stream: .tracker)
            }
            // Update lane mailboxes. The processed lane delivers BGRA8: the buffer
            // mailbox (via the core's pack step) and the BGRA8 texture mailbox
            // (sharing the buffer's IOSurface); tracker via the fused Pass-4 pool.
            // The natural 16F texture mailbox is kept as an internal compute
            // intermediate for calibration/diagnostic sampling — never delivered
            // (remove-natural-lane). `captureImage` reads the processed BGRA8 buffer
            // mailbox; `captureNaturalPicture` converts on demand via `renderStill`.
            self._latestNaturalTex16F.store(naturalTexI)
            if logFirstAfterGate {
                CameraKitLog.notice(
                    .metal, "[resume] first texture stored (t1c) — preview texture live")
            }
            // Publish the buffer PTS as nanoseconds so `awaitNaturalAfter` can
            // confirm naturalTex has been refreshed past a given timestamp. CAS
            // loop ensures we only advance the published PTS — out-of-order
            // command-buffer completion (rare but possible across Metal queues)
            // must not regress the timeline.
            let captureNs = Int64(CMTimeGetSeconds(captureTime) * 1_000_000_000)
            var cur = self.latestNaturalPTSNs.load(ordering: .relaxed)
            while captureNs > cur {
                let (ok, actual) = self.latestNaturalPTSNs.compareExchange(
                    expected: cur, desired: captureNs, ordering: .releasing)
                if ok { break }
                cur = actual
            }
            // BGRA8 mailbox (read by `captureImage`): store only the real BGRA8
            // buffer; on the rare miss keep the previous good frame, never a 16F one.
            // (optimization B: the 16F processed texture is no longer produced in
            // production — `_latestProcessedTex16F` is written only by test seams now.)
            if let processedEightBitBuf { self._latestProcessedBuffer.store(processedEightBitBuf) }
            if let pTex = processedEightBitTex { self._latestProcessedBgra8Tex.store(pTex) }
            if let tBuf = trackerBuf, let tTex = trackerTex {
                self._latestTrackerBuffer.store(tBuf)
                self._latestTrackerTex.store(tTex)
            }
            self.texturePool.flush()
        }

        // 10. Track for drain (ADR-09 waitUntilScheduled path) and increment.
        lastCommandBuffer = commandBuffer
        commitCount += 1
        frameNumber &+= 1
        commandBuffer.commit()
        if logFirstAfterGate {
            CameraKitLog.notice(.metal, "[resume] first commit after gate (t1b)")
        }
    }

    /// One-shot crop+grade of an arbitrary YUV buffer (e.g. an AVCapturePhotoOutput
    /// still) into a BGRA8 `outputSize` buffer — the saved natural-capture path.
    ///
    /// Reuses the live crop uniform + current ColorUniform so the result matches the
    /// graded preview. Input dims MUST equal `captureSize`; throws
    /// `MetalError.unsupportedFormat` otherwise (1:1 crop mapping).
    /// Dequeues from the same `naturalPool`/`processedPool`/`eightBitNaturalPool` as
    /// the live `renderFrame(sampleBuffer:)` path, so under an active capture session
    /// it can throw on transient pool exhaustion. Shares the `encodeGradedCore`
    /// decode → grade → pack with `renderFrame` (§3.0).
    func renderStill(pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(pixelBuffer) == captureSize.width,
            CVPixelBufferGetHeight(pixelBuffer) == captureSize.height
        else {
            throw MetalError.unsupportedFormat
        }
        let yTex = try texturePool.makeYTexture(from: pixelBuffer)
        let cbcrTex = try texturePool.makeCbCrTexture(from: pixelBuffer)
        let nat = try texturePool.dequeuePoolTexture(
            pool: naturalPool, width: outputSize.width, height: outputSize.height)
        let out = try texturePool.dequeueEightBitPoolTexture(
            pool: eightBitNaturalPool, width: outputSize.width, height: outputSize.height)

        let (color, crop) = uniforms.withLock { ($0.color, $0.crop) }
        let cb = commandQueue.makeCommandBuffer()!
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (outputSize.width + 15) / 16,
            height: (outputSize.height + 15) / 16,
            depth: 1)

        // Shared graded core: decode → grade (+ normalization) → pack. The still
        // always supplies a pack target (`out`), the BGRA8 graded still.
        encodeGradedCore(
            into: cb,
            y: yTex, cbcr: cbcrTex,
            natural: nat.texture,
            packed: out.texture,
            color: color, crop: crop,
            threadGroups: groups, threadGroupSize: tg)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cb.addCompletedHandler { cb in
                cb.status == .error
                    ? c.resume(
                        throwing: MetalError.commandBufferFailed(
                            code: (cb.error as NSError?)?.code ?? -1))
                    : c.resume()
            }
            cb.commit()
        }
        return out.buffer
    }

    /// Blocks until the most recently committed command buffer has been scheduled.
    ///
    /// Called from CameraEngine.drainSubmittedFrame() on .inactive.
    /// Safe to call from any thread (Metal contract for waitUntilScheduled).
    func drainLastBuffer() {
        lastCommandBuffer?.waitUntilScheduled()
    }

    /// Pre-seed the processed preview mailboxes (and the internal 16F natural
    /// texture) with blank pool buffers so the processed lane is non-nil
    /// immediately after `open()`.
    ///
    /// Without this, `CameraEngine.currentProcessedTexture()` /
    /// `currentPixelBuffer(stream:)` are nil on the first `open()` until a frame is
    /// encoded, so the Flutter texture bridge registers id 0 and the lane stays
    /// black until a close→open cycle (measurements 2026-05-20 §1, P2b). Mirrors
    /// the mailboxes `encode()` writes: the processed RGBA16F texture (diagnostic
    /// sampling), the processed BGRA8 texture (bridge accessor) + buffer
    /// (FlutterTexture), and the natural 16F texture (calibration sampling;
    /// remove-natural-lane keeps only this natural surface). Sizes to
    /// `outputSize` so a seeded crop matches its frames. Idempotent and
    /// best-effort — a no-op once a frame has populated the mailboxes, and a pool
    /// miss simply leaves the mailbox nil (today's behavior). Fresh pool buffers
    /// are zero-filled, so the seeded frame is black, never uninitialized garbage.
    func seedPreviewMailboxes() {
        guard latestNaturalTex16F == nil else { return }
        // Keep seeding the internal 16F natural texture — calibration samples it
        // (remove-natural-lane). The natural BGRA8 streaming seed was removed.
        if let nat = try? texturePool.dequeuePoolTexture(
            pool: naturalPool, width: outputSize.width, height: outputSize.height)
        {
            _latestNaturalTex16F.store(nat.texture)
        }
        // (optimization B: no 16F processed seed — the graded surface is BGRA8 below.)
        if let proc8 = try? texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: outputSize.width, height: outputSize.height)
        {
            _latestProcessedBgra8Tex.store(proc8.texture)
            _latestProcessedBuffer.store(proc8.buffer)
        }
    }

    /// Returns the center-patch sample size in pixels, scaled with capture
    /// resolution and clamped to a 16-pixel minimum.
    ///
    /// `Constants.centerPatchSizePx` (96) is the baseline at the default
    /// 4160×3120 capture; below that, the patch shrinks proportionally with
    /// the shorter texture dimension so we don't over-sample on a downsized
    /// lane. Floor of 16 keeps a 16×16 threadgroup viable.
    static func scaledCenterPatchSize(captureSize: Size) -> Int {
        let baseShorter = min(
            Constants.captureDefaultWidthPx,
            Constants.captureDefaultHeightPx
        )
        let curShorter = min(captureSize.width, captureSize.height)
        let scaled = Int(
            (Double(Constants.centerPatchSizePx)
                * Double(curShorter) / Double(baseShorter)).rounded())
        return max(16, scaled)
    }

    /// Encodes the center-patch sampler over a caller-supplied texture and returns one RgbSample.
    private func dispatchCenterPatch(on tex: MTLTexture) async throws -> RgbSample {
        // P2a — patch scales to the OUTPUT (crop-region) size, since the natural/
        // processed textures sampled here are now `outputSize`. The static
        // method's `captureSize:` label is kept to avoid cross-file churn.
        let patchSize = Self.scaledCenterPatchSize(captureSize: outputSize)
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
        let trimCount = Int(Double(count) * Constants.centerPatchTrimRatio)
        let r = trimmedMean(buffer: bufR, count: count, trim: trimCount)
        let g = trimmedMean(buffer: bufG, count: count, trim: trimCount)
        let b = trimmedMean(buffer: bufB, count: count, trim: trimCount)
        return RgbSample(r: Double(r), g: Double(g), b: Double(b))
    }

    /// WB calibration entry point — samples the latest **natural** texture (Pass-1 output).
    ///
    /// `naturalTex` carries the deterministic BT.601 full-range YCbCr→RGB
    /// matrix conversion of the AVF sample buffer — and **nothing else**. No
    /// shader-applied processing: no BCSG, no gamma curve, no saturation, no
    /// black-balance, no calibration-derived gains beyond what AVF already
    /// applied at the sensor. This is the most pre-grade signal accessible on
    /// the GPU; the only step further upstream is CPU readback of the NV12
    /// pixel buffer with manual YUV→RGB on CPU, which produces identical
    /// values. WB calibration must sample here so the gains computed don't
    /// feed back the previously-applied calibration state.
    func dispatchCenterPatchOnNatural() async throws -> RgbSample {
        // Read the live mailbox directly: do NOT route through `currentTexture()`,
        // which falls back to a blank pool buffer for the preview path. A
        // calibration sample of a blank texture is silently (0,0,0) — worse than
        // a thrown error. Single-writer invariant (delivery queue) + Metal's
        // command-buffer retention through encode make this read race-free.
        guard let naturalTex = latestNaturalTex16F else {
            throw MetalError.noFrameAvailable
        }
        return try await dispatchCenterPatch(on: naturalTex)
    }

    /// Reads back a centered square region of the **natural** (pre-grade) lane as
    /// gamma-encoded RGB, for one-shot black-point calibration stats.
    ///
    /// Only the `side × side` window centered on the frame is read back — not the
    /// full multi-megapixel frame — so calibration stays cheap (it samples a
    /// small patch). Returned values are gamma-encoded; the stats helper
    /// linearizes them. `side` is clamped to the lane's dimensions.
    func readbackNaturalCenterRegion(
        side: Int
    ) async throws -> (pixels: [SIMD3<Float>], width: Int, height: Int) {
        guard let natTex = latestNaturalTex16F else { throw MetalError.noFrameAvailable }
        return try await readbackCenterRegion(from: natTex, side: side)
    }

    /// Extracts the centered `side × side` window of `source` on the GPU, then
    /// reads back only that small region.
    ///
    /// `extractCenterRegion` copies the window (a kernel read at an offset — safe
    /// on the IOSurface-backed lane, unlike a non-zero-origin blit) into a small
    /// private texture; that texture is blitted (origin 0) into shared memory and
    /// unpacked RGBA16F → `[SIMD3<Float>]` (alpha dropped). Avoiding the
    /// full-frame readback keeps calibration off the multi-megapixel CPU path.
    /// `side` is clamped to the source dimensions. Single-writer invariant
    /// (delivery queue) + command-buffer ordering make the read race-free.
    private func readbackCenterRegion(
        from source: MTLTexture, side: Int
    ) async throws -> (pixels: [SIMD3<Float>], width: Int, height: Int) {
        let s = max(1, min(side, source.width, source.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: s, height: s, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let region = commandQueue.device.makeTexture(descriptor: desc) else {
            throw MetalError.textureAllocationFailed
        }
        let bytesPerRow = s * 4 * MemoryLayout<UInt16>.size  // RGBA16F = 8 B/px
        let length = bytesPerRow * s
        guard
            let buf = commandQueue.device.makeBuffer(length: length, options: .storageModeShared)
        else { throw MetalError.textureAllocationFailed }
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -5)
        }

        // GPU step 1: copy the centered window from the full lane into `region`.
        guard let extract = cb.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -5)
        }
        extract.setComputePipelineState(extractCenterRegionPSO)
        extract.setTexture(source, index: 0)
        extract.setTexture(region, index: 1)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (s + 15) / 16, height: (s + 15) / 16, depth: 1)
        extract.dispatchThreadgroups(groups, threadsPerThreadgroup: tgSize)
        extract.endEncoding()

        // GPU step 2: copy the small region (origin 0 — safe) into shared memory.
        guard let blit = cb.makeBlitCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -4)
        }
        blit.copy(
            from: region, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: s, height: s, depth: 1),
            to: buf, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cb.addCompletedHandler { cb in
                cb.status == .error
                    ? c.resume(
                        throwing: MetalError.commandBufferFailed(
                            code: (cb.error as NSError?)?.code ?? -1))
                    : c.resume()
            }
            cb.commit()
        }
        let half = buf.contents().bindMemory(to: UInt16.self, capacity: s * s * 4)
        var pixels = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: s * s)
        for i in 0..<(s * s) {
            pixels[i] = SIMD3<Float>(
                Float(Float16(bitPattern: half[i * 4 + 0])),
                Float(Float16(bitPattern: half[i * 4 + 1])),
                Float(Float16(bitPattern: half[i * 4 + 2])))
        }
        return (pixels, s, s)
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

    /// Convenience init that creates its own gate and an empty ConsumerRegistry.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to
    /// import Atomics.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        trackerHeight: Int? = nil,
        gateOpen: Bool = true
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            outputSize: outputSize,
            cropOrigin: cropOrigin,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: ConsumerRegistry(),
            engineSessionToken: ManagedAtomic<UInt64>(0),
            deviceSnapshot: Mailbox<DeviceStateSnapshot>(),
            trackerHeight: trackerHeight
        )
    }

    /// Convenience init that accepts an explicit ConsumerRegistry but hides ManagedAtomic.
    ///
    /// Used by Stage06Tests so tests can inject a specific registry without
    /// importing Atomics.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        trackerHeight: Int? = nil,
        gateOpen: Bool = true,
        consumers: ConsumerRegistry
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            outputSize: outputSize,
            cropOrigin: cropOrigin,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: consumers,
            engineSessionToken: ManagedAtomic<UInt64>(0),
            deviceSnapshot: Mailbox<DeviceStateSnapshot>(),
            trackerHeight: trackerHeight
        )
    }

}

// MARK: - Test seams (internal — accessed via @testable import)
#if DEBUG
extension MetalPipeline {
    /// Test seam: opens/closes the pipeline's shared submission gate directly.
    ///
    /// For pipeline-level tests (Stage02) that exercise commit gating without a
    /// full engine. Production drives the same shared gate through `CameraEngine`
    /// (which owns the atomic and passes it in at construction).
    func setGateForTest(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    // Stage 06: pool-backed buffer accessors replace the removed single-buffer properties.
    // (remove-natural-lane: no natural streaming buffer seam.)
    var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer }
    var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer }

    var texturePoolForTest: TexturePoolManager { texturePool }
    var naturalPoolForTest: CVPixelBufferPool { naturalPool }
    var processedPoolForTest: CVPixelBufferPool { processedPool }
    var trackerPoolForTest: CVPixelBufferPool { trackerPool }
    var trackerSizeForTest: Size { trackerSize }
    var trackerNeedsResizeForTest: Bool { trackerNeedsResize }

    // RGBA8 conversion test seams.
    var eightBitNaturalPoolForTest: CVPixelBufferPool { eightBitNaturalPool }
    var eightBitProcessedPoolForTest: CVPixelBufferPool { eightBitProcessedPool }
    // Note: there is no separate eightBitTrackerPool — the tracker pool itself is
    // BGRA8 (fused into Pass-4). Use `trackerPoolForTest` to inspect tracker format.

    func setLatestNaturalForTest(texture: MTLTexture) {
        // remove-natural-lane: only the internal 16F natural texture survives (the
        // calibration sampler input); there is no streaming natural buffer mailbox.
        _latestNaturalTex16F.store(texture)
    }

    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        _latestProcessedBuffer.store(buffer)
        _latestProcessedTex16F.store(texture)
    }

    /// Writes color uniforms directly into the pipeline's uniforms Mutex.
    ///
    /// Mirrors the `uniforms.color` slice of the production path
    /// `CameraEngine.setProcessingParams` (which also routes through the
    /// session queue and KVO ingest). Used by Stage11Tests to inject known
    /// BCSG+BB state without needing a full engine. Crop uniforms are untouched.
    func setColorUniformsForTest(_ params: ProcessingParameters) {
        uniforms.withLock { storage in
            storage.color = ColorUniform(params)
        }
    }

    // Test-only: dispatches the grade (color transform) over the latest natural
    // texture, awaits scheduled, and returns. Use after installing natural +
    // processed textures via `setLatestNaturalForTest` / `setLatestProcessedForTest`.
    func encodeGradeOnly() async throws {
        guard let natTex = latestNaturalTex16F, let procTex = latestProcessedTex16F else {
            throw MetalError.noFrameAvailable
        }
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

    // Bundle of the natural (16F) + packed (BGRA8 graded) outputs from BOTH the
    // pre-fusion three-encoder core and the fused core, for equivalence testing.
    struct CoreComparisonForTest {
        let separateNatural: CVPixelBuffer
        let fusedNatural: CVPixelBuffer
        let separatePacked: CVPixelBuffer
        let fusedPacked: CVPixelBuffer
    }

    /// Test-only: the PRE-FUSION three-encoder core (decode → grade → pack).
    ///
    /// Byte-for-byte the old `encodeGradedCore` body. Retained ONLY as the reference
    /// path for `encodeCoreComparisonForTest`; the fused kernel must reproduce its
    /// natural/processed outputs (within 1e-3 — see the fused-kernel precision note).
    private func encodeSeparateCoreForTest(
        into commandBuffer: MTLCommandBuffer,
        y yTexture: MTLTexture, cbcr cbcrTexture: MTLTexture,
        natural naturalTex: MTLTexture, processed processedTex: MTLTexture,
        packed packedTex: MTLTexture?,
        color colorSnapshot: ColorUniform, crop cropSnapshot: CropUniform,
        threadGroups: MTLSize, threadGroupSize: MTLSize
    ) {
        let decode = commandBuffer.makeComputeCommandEncoder()!
        decode.setComputePipelineState(yuvToRgbaPSO)
        decode.setTexture(yTexture, index: 0)
        decode.setTexture(cbcrTexture, index: 1)
        decode.setTexture(naturalTex, index: 2)
        var cropLocal = cropSnapshot
        decode.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        decode.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        decode.endEncoding()

        let grade = commandBuffer.makeComputeCommandEncoder()!
        grade.setComputePipelineState(colorTransformPSO)
        grade.setTexture(naturalTex, index: 0)
        grade.setTexture(processedTex, index: 1)
        var colorLocal = colorSnapshot
        grade.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
        grade.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        grade.endEncoding()

        guard let packedTex else { return }
        let pack = commandBuffer.makeComputeCommandEncoder()!
        pack.setComputePipelineState(rgba16fToBgra8PSO)
        pack.setTexture(processedTex, index: 0)
        pack.setTexture(packedTex, index: 1)
        pack.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pack.endEncoding()
    }

    /// Test-only: runs the OLD separate core and the NEW fused core for equivalence.
    ///
    /// Both run on the SAME y/cbcr input + color/crop, in one command buffer, and
    /// return their natural (16F) and packed (BGRA8, the graded surface) outputs so
    /// the test can assert equivalence. The separate path also writes a 16F processed
    /// intermediate (its `rgba16fToBgra8` pack reads it), but the fused path no longer
    /// produces one (optimization B) — so the graded comparison is packed-vs-packed.
    func encodeCoreComparisonForTest(
        y: MTLTexture, cbcr: MTLTexture, size: Size, color: ColorUniform, crop: CropUniform
    ) async throws -> CoreComparisonForTest {
        let sepNat = try texturePool.dequeuePoolTexture(
            pool: naturalPool, width: size.width, height: size.height)
        let sepProc = try texturePool.dequeuePoolTexture(
            pool: processedPool, width: size.width, height: size.height)
        let sepPacked = try texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: size.width, height: size.height)
        let fusNat = try texturePool.dequeuePoolTexture(
            pool: naturalPool, width: size.width, height: size.height)
        let fusPacked = try texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: size.width, height: size.height)

        let cb = commandQueue.makeCommandBuffer()!
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (size.width + 15) / 16, height: (size.height + 15) / 16, depth: 1)

        encodeSeparateCoreForTest(
            into: cb, y: y, cbcr: cbcr,
            natural: sepNat.texture, processed: sepProc.texture, packed: sepPacked.texture,
            color: color, crop: crop, threadGroups: groups, threadGroupSize: tg)
        encodeGradedCore(
            into: cb, y: y, cbcr: cbcr,
            natural: fusNat.texture, packed: fusPacked.texture,
            color: color, crop: crop, threadGroups: groups, threadGroupSize: tg)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cb.addCompletedHandler { cb in
                cb.status == .error
                    ? c.resume(throwing: MetalError.commandBufferFailed(code: -9))
                    : c.resume()
            }
            cb.commit()
        }
        return CoreComparisonForTest(
            separateNatural: sepNat.buffer, fusedNatural: fusNat.buffer,
            separatePacked: sepPacked.buffer, fusedPacked: fusPacked.buffer)
    }

    /// Test-only A/B microbenchmark: mean GPU wall-time per frame of the separate
    /// core vs the fused core, measured back-to-back in ONE session (same thermal
    /// state, same input) so the delta is the fusion saving, not run-to-run drift.
    ///
    /// Each path encodes `iterations` cores into one command buffer (each writes the
    /// same textures, so Metal serializes them exactly like consecutive real frames),
    /// then divides the command buffer's `gpuEndTime − gpuStartTime` by `iterations`.
    /// A warm-up run precedes measurement to prime PSOs/caches. Returns microseconds
    /// per frame for each path.
    func benchmarkCoresForTest(
        y: MTLTexture, cbcr: MTLTexture, size: Size, color: ColorUniform, crop: CropUniform,
        iterations: Int
    ) async throws -> (separateMicrosPerFrame: Double, fusedMicrosPerFrame: Double) {
        let nat = try texturePool.dequeuePoolTexture(
            pool: naturalPool, width: size.width, height: size.height)
        let proc = try texturePool.dequeuePoolTexture(
            pool: processedPool, width: size.width, height: size.height)
        let packed = try texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: size.width, height: size.height)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (size.width + 15) / 16, height: (size.height + 15) / 16, depth: 1)

        func timeRun(fused: Bool) async throws -> Double {
            let cb = commandQueue.makeCommandBuffer()!
            for _ in 0..<iterations {
                if fused {
                    encodeGradedCore(
                        into: cb, y: y, cbcr: cbcr,
                        natural: nat.texture, packed: packed.texture,
                        color: color, crop: crop, threadGroups: groups, threadGroupSize: tg)
                } else {
                    encodeSeparateCoreForTest(
                        into: cb, y: y, cbcr: cbcr,
                        natural: nat.texture, processed: proc.texture, packed: packed.texture,
                        color: color, crop: crop, threadGroups: groups, threadGroupSize: tg)
                }
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                cb.addCompletedHandler { cb in
                    cb.status == .error
                        ? c.resume(throwing: MetalError.commandBufferFailed(code: -10))
                        : c.resume()
                }
                cb.commit()
            }
            return (cb.gpuEndTime - cb.gpuStartTime) * 1_000_000 / Double(iterations)
        }

        _ = try await timeRun(fused: true)  // warm-up (prime PSOs/caches/clocks)
        let separate = try await timeRun(fused: false)
        let fused = try await timeRun(fused: true)
        return (separate, fused)
    }
}
#endif
