import CoreVideo
import Metal

enum Constants {
    static let frameRateTargetFPS: Int = 30
    static let capturePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    static let captureDefaultWidthPx: Int = 4160
    static let captureDefaultHeightPx: Int = 3120
    static let captureFallbackWidthPx: Int = 1280
    static let captureFallbackHeightPx: Int = 960
    static let cropDefaultWidthPx: Int = 1600
    static let cropDefaultHeightPx: Int = 1200
    static let captureOrientationAngleDeg: CGFloat = 0
    static let stateStreamBufferSize: Int = 64
    /// ADR-30: Deadline for startRunning() / stopRunning() awaited from @MainActor.
    static let sessionLifecycleTimeoutSeconds: Double = 2.0
    // Frame-result heartbeat (07-settings.md §Frame-result heartbeat).
    static let frameResultHeartbeatHz: Int = 3
    static let frameResultHeartbeatIntervalFrames: Int = 10  // 30 fps ÷ 3 Hz
    // Session-only teardown budget for setResolution (03-camera-session.md).
    static let resolutionResizeTimeoutSeconds: Double = 5.0
    // Stage 04 — color pipeline + sample-center-patch (architecture/constants.md).
    /// Square center-patch size in pixels for `sampleCenterPatch()` (constants.md line 35).
    static let centerPatchSizePx: Int = 96
    /// Discard top/bottom % of intensity values for the trimmed mean (constants.md line 36).
    static let centerPatchTrimPercent: Int = 10
    /// Per-frame wall-clock budget at 30fps (constants.md line 15).
    static let frameLatencyBudgetMs: Int = 33
    /// IOSurface-backed working-texture pixel format — pairs with .rgba16Float MTLTexture views.
    static let processedPixelFormat: OSType = kCVPixelFormatType_64RGBAHalf

    // MARK: - Stage 06 — Pool trio + tracker stream

    /// Tracker texture height in pixels; width is aspect-preserved and
    /// even-pixel-rounded in `MetalPipeline` (domain 02-frame-delivery §Parallel
    /// Stream Outputs, U-15 resolved; constants.md#TRACKER_HEIGHT_PX).
    static let trackerHeightPx: Int = 480

    /// `kCVPixelBufferPoolMinimumBufferCountKey` — 1 current mailbox ref +
    /// 1 GPU write slot + 1 slack (constants.md#POOL_MIN_BUFFER_COUNT, ADR-19).
    static let poolMinBufferCount: Int = 3

    /// `kCVPixelBufferPoolMaximumBufferAgeKey` — CF ages out unused buffers
    /// after this many seconds of disuse (constants.md#POOL_MAX_BUFFER_AGE_SECONDS,
    /// ADR-19).
    static let poolMaxBufferAgeSeconds: Double = 1.0

    // MARK: - Stage 08 — C++ pool

    /// Thread-count cap for the C++ PixelSinkPool worker queue.
    static let cppPoolThreadCount: Int = min(4, ProcessInfo.processInfo.processorCount)
}
