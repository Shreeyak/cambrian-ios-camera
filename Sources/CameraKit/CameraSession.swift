import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Owns the `AVCaptureSession` lifecycle: configure, start, stop.
///
/// All `AVCaptureSession` mutations and `AVCaptureDevice.lockForConfiguration()` calls
/// run on `sessionQueue` (ADR-07). `CameraEngine` dispatches onto that queue; this class
/// never dispatches internally.
///
/// `@unchecked Sendable` because the instance is captured in `@Sendable` closures that
/// run on `sessionQueue`. Callers must ensure all methods are invoked on `sessionQueue`.
final class CameraSession: @unchecked Sendable {

    // MARK: - Stored properties

    /// Serializes all AVCaptureSession mutations and lockForConfiguration() calls (ADR-07).
    let sessionQueue: DispatchQueue

    /// Set by configure(); nil until then.
    private(set) var device: (any CaptureDeviceProviding)?

    /// The AVCaptureSession instance.
    ///
    /// Created once per open() call, reused across
    /// pause/resume (G-07 / ADR-07 §Session object is created once per open()).
    let avSession: AVCaptureSession

    /// Retained output — created in init() and wired in configure().
    private let videoOutput: AVCaptureVideoDataOutput

    // MARK: - Init

    init() {
        sessionQueue = DispatchQueue(
            label: "com.cambrian.camerakit.session",
            qos: .userInitiated)
        avSession = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
    }

    // MARK: - configure()

    /// Finds the back wide-angle camera (D-08), selects the largest 4:3 format at 30 fps
    /// (G-17), wires the video data output, and sets landscape-right rotation (ADR-17).
    ///
    /// Must be called on `sessionQueue`.
    ///
    /// - Parameters:
    ///   - deliveryQueue: Queue passed to `setSampleBufferDelegate(_:queue:)`. Owned by
    ///     the caller (`CameraEngine`).
    ///   - sampleBufferDelegate: The `CaptureDelegate` that receives sample buffers.
    ///     Owned by the caller.
    /// - Returns: The live device wrapper and the chosen capture size.
    /// - Throws: `EngineError.noBackCamera` if the device is absent;
    ///   `EngineError.lockForConfigurationFailed` if the device lock fails;
    ///   `EngineError.noSupportedFormat` if landscape-right rotation is unsupported.
    func configure(
        deliveryQueue: DispatchQueue,
        sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) throws -> (device: any CaptureDeviceProviding, captureSize: Size) {

        // ── 1. Device discovery (D-08) ──────────────────────────────────────────────
        // Use the default API per architecture/03-camera-session.md §Device selection.
        guard
            let avDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            )
        else {
            throw EngineError.noBackCamera
        }

        // ── 2. Format selection (G-17) ──────────────────────────────────────────────
        // Filter: 8-bit biplanar YUV (FullRange preferred, VideoRange accepted per G-17
        // and architecture/03-camera-session.md §Enumeration step 1).
        let yuvFormats: [AVCaptureDevice.Format] = avDevice.formats.filter { format in
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        // Among YUV formats, prefer FullRange, then VideoRange.
        // Sort FullRange first so the first 4:3 hit is FullRange when available.
        let sortedByPreference: [AVCaptureDevice.Format] = yuvFormats.sorted { lhs, rhs in
            let lhsFull =
                CMFormatDescriptionGetMediaSubType(lhs.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let rhsFull =
                CMFormatDescriptionGetMediaSubType(rhs.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if lhsFull != rhsFull { return lhsFull }  // FullRange first

            // Within same range type, sort by pixel count descending (largest first).
            let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(lDims.width) * Int(lDims.height) > Int(rDims.width) * Int(rDims.height)
        }

        // Select the largest 4:3 format that supports 30 fps.
        let fps30 = Int32(Constants.frameRateTargetFPS)
        let candidateFormats: [AVCaptureDevice.Format] =
            sortedByPreference
            .filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let w = Int32(dims.width)
                let h = Int32(dims.height)
                guard w * 3 == h * 4 else { return false }  // 4:3 ratio
                // Must support 30 fps within at least one frame-rate range.
                return format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= Double(fps30) && Double(fps30) <= range.maxFrameRate
                }
            }
            // Sort by pixel count descending so `.first` is the largest.
            .sorted { lhs, rhs in
                let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(lDims.width) * Int(lDims.height) > Int(rDims.width) * Int(rDims.height)
            }

        let (chosenFormat, chosenSize): (AVCaptureDevice.Format?, Size) = {
            if let best = candidateFormats.first {
                let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                return (best, Size(width: Int(dims.width), height: Int(dims.height)))
            }
            // Fallback: no 4:3 at 30fps found; use the fallback dimensions (G-17).
            // Pick the format nearest the fallback dimensions if one exists; otherwise nil.
            let fallbackW = Constants.captureFallbackWidthPx
            let fallbackH = Constants.captureFallbackHeightPx
            let nearest = sortedByPreference.min { lhs, rhs in
                let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let lDist = abs(Int(lDims.width) - fallbackW) + abs(Int(lDims.height) - fallbackH)
                let rDist = abs(Int(rDims.width) - fallbackW) + abs(Int(rDims.height) - fallbackH)
                return lDist < rDist
            }
            return (nearest, Size(width: fallbackW, height: fallbackH))
        }()

        // ── 3. Lock for configuration and apply format + frame rate ────────────────
        // Explicit unlock (no defer) so the lock scope closes before we "send"
        // avDevice into LiveCaptureDevice's actor isolation below. A defer that
        // captures avDevice would remain live across the actor-init, which Swift 6
        // strict concurrency flags as a potential data race.
        do {
            try avDevice.lockForConfiguration()
        } catch {
            throw EngineError.lockForConfigurationFailed
        }

        if let format = chosenFormat {
            avDevice.activeFormat = format
        }
        let frameDuration = CMTimeMake(value: 1, timescale: Int32(Constants.frameRateTargetFPS))
        avDevice.activeVideoMinFrameDuration = frameDuration
        avDevice.activeVideoMaxFrameDuration = frameDuration
        avDevice.unlockForConfiguration()

        // ── 4. Wire session input + output ──────────────────────────────────────────
        // All avDevice-derived objects (deviceInput) must be created and added to the
        // session BEFORE avDevice is "sent" into LiveCaptureDevice's actor isolation.
        // Swift 6 region isolation treats LiveCaptureDevice(avDevice:) as a send; any
        // subsequent use of avDevice or values derived from it would be flagged.
        let deviceInput = try AVCaptureDeviceInput(device: avDevice)

        avSession.beginConfiguration()
        defer { avSession.commitConfiguration() }

        if avSession.canAddInput(deviceInput) {
            avSession.addInput(deviceInput)
        }

        // Output settings: request the pixel format we want from AVFoundation.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Constants.capturePixelFormat
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(sampleBufferDelegate, queue: deliveryQueue)

        if avSession.canAddOutput(videoOutput) {
            avSession.addOutput(videoOutput)
        }

        // ── 5. Wrap in LiveCaptureDevice (ADR-32 test seam) ─────────────────────────
        // Done last: avDevice is "sent" into the actor here; no further direct uses
        // of avDevice follow in this function.
        let liveDevice = LiveCaptureDevice(avDevice: avDevice)
        self.device = liveDevice

        // ── 6. Orientation: landscape-right via videoRotationAngle (ADR-17) ─────────
        if let connection = videoOutput.connection(with: .video) {
            let angle = Constants.captureOrientationAngleDeg  // ADR-17
            guard connection.isVideoRotationAngleSupported(angle) else {
                throw EngineError.noSupportedFormat(
                    reason: "videoRotationAngle \(angle)° not supported on this device (ADR-17)")
            }
            connection.videoRotationAngle = angle  // ADR-17
        }

        return (device: liveDevice, captureSize: chosenSize)
    }

    // MARK: - Lifecycle wrappers

    /// Starts the capture session.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func startRunning() {
        avSession.startRunning()
    }

    /// Stops the capture session.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func stopRunning() {
        avSession.stopRunning()
    }

    /// Starts the capture session asynchronously with a timeout (ADR-30).
    ///
    /// Returns when startRunning() completes or when SESSION_LIFECYCLE_TIMEOUT_SECONDS
    /// elapses, whichever comes first. Never throws.
    func startRunningAsync() async {
        await runOnQueue(sessionQueue) { [self] in
            startRunning()
        }
    }

    /// Stops the capture session asynchronously with a timeout (ADR-30).
    ///
    /// Returns when stopRunning() completes or when SESSION_LIFECYCLE_TIMEOUT_SECONDS
    /// elapses, whichever comes first. Never throws.
    func stopRunningAsync() async {
        await runOnQueue(sessionQueue) { [self] in
            stopRunning()
        }
    }
}
