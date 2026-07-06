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

    /// Photo output — created in init() and wired in configure().
    private let photoOutput: AVCapturePhotoOutput

    // MARK: - Session event routing

    enum SessionEvent: Sendable {
        case cameraInUseBegan
        case cameraInUseEnded
        case runtimeError(String)
        case otherInterruption(reasonRawValue: Int)
        /// Counterpart to `.otherInterruption` — fired by AVF's
        /// `interruptionEndedNotification` for any non-cameraInUse reason.
        /// Phase-2 §2d.5: lets the engine revert from `.interrupted` to
        /// `.streaming` without conflating with the cameraInUse self-heal path.
        case otherInterruptionEnded
    }

    // Set by CameraEngine at open(). Routes interruption/runtime-error events up.
    var onSessionEvent: (@Sendable (SessionEvent) -> Void)?

    // MARK: - Init

    init() {
        sessionQueue = DispatchQueue(
            label: "com.cambrian.camerakit.session",
            qos: .userInitiated)
        avSession = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
        photoOutput = AVCapturePhotoOutput()
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
    ///   - requestedSize: When non-`nil`, the capture resolution to select. It must
    ///     match (exact dimensions) one of the device's FullRange formats — the same
    ///     set surfaced by `SessionCapabilities.supportedSizes` and selectable by
    ///     `reconfigureSize(_:)` — so validation and selection draw from one list. An
    ///     unsupported size throws `EngineError.settingsConflict`. `nil` keeps the
    ///     default behavior (largest 4:3 format at 30 fps).
    /// - Returns: The live device wrapper and the chosen capture size.
    /// - Throws: `EngineError.noBackCamera` if the device is absent;
    ///   `EngineError.settingsConflict` if `requestedSize` is not a supported format;
    ///   `EngineError.lockForConfigurationFailed` if the device lock fails;
    ///   `EngineError.noSupportedFormat` if landscape-right rotation is unsupported.
    /// Frame rate the session is locked to, chosen at `configure` and reused by the
    /// preview/recording frame-rate setters (which lock min == max at this value in
    /// every mode). Defaults to the package default until `configure` runs.
    private(set) var lockedFps: Int = Constants.frameRateTargetFPS

    func configure(
        deliveryQueue: DispatchQueue,
        sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        requestedSize: Size? = nil,
        targetFps: Int = Constants.frameRateTargetFPS,
        orientationAngleDeg: CGFloat = Constants.captureOrientationAngleDeg
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

        // ── 2. Format selection — always full-range 420f; resolution and frame rate
        //      resolved independently (configurable-frame-rate). 420f (FullRange) is a
        //      hard invariant (state.md Decision §63) — no video-range fallback; HDR is
        //      disabled below.
        let yuvFormats: [AVCaptureDevice.Format] = avDevice.formats.filter { format in
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        guard !yuvFormats.isEmpty else {
            throw EngineError.noSupportedFormat(
                reason: "device exposes no full-range 420f capture format")
        }

        // Resolve the resolution first, independent of frame rate: the requested size,
        // or — when nil — the largest 4:3 supported size (computed live, not hardcoded).
        // A requested size not offered as 420f is rejected naming the supported set.
        let targetSize: Size = try {
            guard let requested = requestedSize else {
                return Self.largestFourThreeSize(yuvFormats)
            }
            let exists = yuvFormats.contains { fmt in
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                return Int(d.width) == requested.width && Int(d.height) == requested.height
            }
            guard exists else {
                throw EngineError.settingsConflict(
                    reason:
                        "requested capture resolution \(requested.width)x\(requested.height) "
                        + "is not a supported format; supported: "
                        + Self.uniqueSupportedSizes(yuvFormats)
                        .map { "\($0.width)x\($0.height)" }
                        .joined(separator: ", "))
            }
            return requested
        }()

        // Among the 420f formats at that resolution, pick one whose supported frame-rate
        // range contains `targetFps`, preferring a non-HDR-capable format
        // (`isVideoHDRSupported == false`) so we run pure SDR when the sensor offers it;
        // an HDR-capable-only resolution (the largest sizes) is still used, with HDR
        // disabled below. An unsupported (resolution, fps) pair is rejected naming the
        // frame rates valid at that resolution.
        let formatsAtSize = yuvFormats.filter { fmt in
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            return Int(d.width) == targetSize.width && Int(d.height) == targetSize.height
        }
        let fpsCapable = formatsAtSize.filter { Self.formatSupportsFps($0, targetFps) }
        guard
            let chosenFormat = fpsCapable.first(where: { !$0.isVideoHDRSupported })
                ?? fpsCapable.first
        else {
            throw EngineError.settingsConflict(
                reason:
                    "requested frame rate \(targetFps) fps is not supported at "
                    + "\(targetSize.width)x\(targetSize.height); supported: "
                    + Self.supportedFpsDescription(formatsAtSize))
        }
        let chosenSize = targetSize

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

        avDevice.activeFormat = chosenFormat
        // HDR always off: extended-range tone-mapping fights the linear-light
        // normalization stage. Disable it explicitly on the selected format
        // (configurable-frame-rate Rec A) — this is what lets an HDR-capable-only
        // resolution (the largest sensor sizes) run as plain SDR.
        avDevice.automaticallyAdjustsVideoHDREnabled = false
        if avDevice.activeFormat.isVideoHDRSupported {
            avDevice.isVideoHDREnabled = false
        }
        // NOTE: the frame-rate lock (activeVideoMin/MaxFrameDuration) is applied
        // in step 4b, AFTER commitConfiguration — not here. Setting it before
        // `sessionPreset = .inputPriority` (step 4) is silently wiped: per Apple's
        // docs, "Choosing a new preset for the capture session also resets
        // [activeVideoMinFrameDuration] to its default value." Doing it here made
        // the session run at the format default instead of `targetFps` (measured:
        // requested 15/30/60 all read back as the format default). Only `lockedFps`
        // (a Swift property, not device state) is recorded here.
        self.lockedFps = targetFps

        // bug6: disable low-light boost. LLB multiplies analog gain in dim
        // scenes, which sacrifices spatial detail for SNR. Stills come out
        // softer when LLB engages mid-frame. Disabling makes detail
        // deterministic across exposure conditions; AE still handles low
        // light via shutter/ISO within format limits.
        if avDevice.isLowLightBoostSupported {
            avDevice.automaticallyEnablesLowLightBoostWhenAvailable = false
        }

        avDevice.unlockForConfiguration()

        // ── 4. Wire session input + output ──────────────────────────────────────────
        // All avDevice-derived objects (deviceInput) must be created and added to the
        // session BEFORE avDevice is "sent" into LiveCaptureDevice's actor isolation.
        // Swift 6 region isolation treats LiveCaptureDevice(avDevice:) as a send; any
        // subsequent use of avDevice or values derived from it would be flagged.
        let deviceInput = try AVCaptureDeviceInput(device: avDevice)

        avSession.beginConfiguration()

        // bug6: set sessionPreset to .inputPriority before adding the input so the
        // device's activeFormat is honored. The default preset (.high) overrides
        // activeFormat and silently downgrades the delivered buffer to 1080p,
        // which left the destination textures (sized at format dims, e.g.
        // 4032×3024) under-filled and showing un-sampled BT.601-of-zero green
        // along the bottom and right edges.
        if avSession.canSetSessionPreset(.inputPriority) {
            avSession.sessionPreset = .inputPriority
        }

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

        if avSession.canAddOutput(photoOutput) {
            avSession.addOutput(photoOutput)
        }

        avSession.commitConfiguration()

        // ── 4b. Lock the frame rate at exactly `targetFps` (min == max) ──────────────
        // Must run AFTER commitConfiguration: setting `sessionPreset` (step 4) resets
        // activeVideoMin/MaxFrameDuration to the format default (Apple docs), so an
        // earlier lock is wiped. Setting min == max == 1/targetFps here pins delivery
        // to exactly `targetFps` in every mode — not a variable range. Clamp with the
        // format's own CMTime bounds so a non-integer supported edge can't trip
        // setActiveVideoMinFrameDuration: (the crash guard — see clampFrameDuration).
        do {
            try avDevice.lockForConfiguration()
        } catch {
            throw EngineError.lockForConfigurationFailed
        }
        let frameDuration = clampFrameDuration(
            CMTimeMake(value: 1, timescale: Int32(targetFps)),
            toSupportedRanges: avDevice.activeFormat.videoSupportedFrameRateRanges)
        avDevice.activeVideoMinFrameDuration = frameDuration
        avDevice.activeVideoMaxFrameDuration = frameDuration
        avDevice.unlockForConfiguration()

        // Register interruption and runtime-error observers now that configuration is committed.
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note: note, ended: false)
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note: note, ended: true)
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleRuntimeError(note: note)
        }

        // ── 5. Wrap in LiveCaptureDevice (ADR-32 test seam) ─────────────────────────
        // Done last: avDevice is "sent" into the actor here; no further direct uses
        // of avDevice follow in this function.
        let liveDevice = LiveCaptureDevice(avDevice: avDevice)
        self.device = liveDevice

        // ── 6. Orientation: landscape-right via videoRotationAngle (ADR-17) ─────────
        // Angle defaults to the package convention (0°) but is overridable per
        // open() via OpenConfiguration.captureOrientationAngleDeg, so a host that
        // locks to a different landscape edge can rotate the delivered buffers
        // without changing the package default for other consumers.
        if let connection = videoOutput.connection(with: .video) {
            let angle = orientationAngleDeg  // ADR-17 (configurable per open)
            guard connection.isVideoRotationAngleSupported(angle) else {
                throw EngineError.noSupportedFormat(
                    reason: "videoRotationAngle \(angle)° not supported on this device (ADR-17)")
            }
            connection.videoRotationAngle = angle  // ADR-17

            // bug6: disable video stabilization. The standard / cinematic modes
            // warp each frame (rolling-shutter correction + bilinear resample +
            // crop), which softens fine detail. Off makes the captured frame a
            // raw read of the sensor's ISP-processed output without geometric
            // post-processing — material sharpness gain on stills.
            connection.preferredVideoStabilizationMode = .off

            // Horizontal (left-right) mirror. On an AVCaptureVideoDataOutput
            // connection isVideoMirrored flips the delivered pixel buffers
            // themselves (not a display-only transform), so preview, every
            // lane, and recording all inherit the flip from this single point.
            // Must clear the auto-adjust flag first, else the assignment is
            // ignored.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        // Match landscape-right rotation on the photo output connection (ADR-17).
        // Unlike the video path, unsupported angle is a silent skip — not a throw —
        // because photo rotation is a best-effort orientation hint, not a hard
        // pipeline requirement.
        if let pc = photoOutput.connection(with: .video),
            pc.isVideoRotationAngleSupported(orientationAngleDeg)
        {
            pc.videoRotationAngle = orientationAngleDeg  // ADR-17 (configurable per open)
        }

        // NOTE: the photo-output connection is deliberately NOT mirrored.
        // AVCapturePhotoOutput does not apply isVideoMirrored to the raw
        // `photo.pixelBuffer` (it would only tag orientation metadata), so
        // setting it had no effect. captureNaturalPicture therefore reflects the
        // un-mirrored ISP geometry — distinct from the mirrored preview /
        // captureImage. (The video-data-output mirror above still applies.)
        //
        // FUTURE: the same applies to `videoRotationAngle` set on the photo
        // connection above — AVCapturePhotoOutput tags orientation metadata but
        // does NOT physically rotate the raw `photo.pixelBuffer` that
        // `captureNaturalPicture` → `renderStill` consumes. So with a non-zero
        // `captureOrientationAngleDeg`, the natural still is delivered in native
        // ISP orientation (e.g. upside down vs the rotated preview). Fix when
        // needed by rotating the raw buffer in the natural-still path (Metal pass
        // or honoring the orientation tag at readback) — or correct in post.

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

    /// Shoots a one-shot still.
    ///
    /// The capturePhoto request runs on sessionQueue (ADR-07); returns the captured
    /// pixel buffer. The transient `StillPhotoCapture` is retained by `output` for
    /// the capture's duration and by this async frame.
    ///
    /// - Note: No timeout is installed — if the session is torn down before the
    ///   photo delegate fires, the calling Task suspends indefinitely. A
    ///   cancellation-aware timeout (ADR-30 / AsyncWithTimeout pattern) should be
    ///   added if this surfaces in production.
    func capturePhoto() async throws -> CVPixelBuffer {
        try await StillPhotoCapture().capture(using: photoOutput, on: sessionQueue)
    }

    /// Re-select device format for new resolution.
    ///
    /// Stage 03 placeholder for `setResolution` (brief §4): re-select device format.
    /// Stage 06 replaces with pool-resize. Runs on `sessionQueue` (ADR-07).
    /// Unique selectable capture sizes from a FullRange format list, ≥640×480,
    /// sorted by area descending — mirrors `LiveCaptureDevice.supportedSizes` so the
    /// `requestedSize` validation message names the same set the picker advertises.
    private static func uniqueSupportedSizes(_ fullRangeFormats: [AVCaptureDevice.Format]) -> [Size] {
        var seen: Set<Size> = []
        var unique: [Size] = []
        for format in fullRangeFormats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(d.width)
            let h = Int(d.height)
            guard w >= 640, h >= 480 else { continue }
            let size = Size(width: w, height: h)
            if seen.insert(size).inserted { unique.append(size) }
        }
        return unique.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
    }

    /// Largest 4:3 capture size among `fullRangeFormats` (≥640×480), computed live.
    ///
    /// The default resolution when `open()` gets no explicit `captureResolution`,
    /// decoupled from frame rate (configurable-frame-rate). Falls back to the overall
    /// largest size, then the package fallback, if the device offers no 4:3 format.
    private static func largestFourThreeSize(_ fullRangeFormats: [AVCaptureDevice.Format]) -> Size {
        let sizes = uniqueSupportedSizes(fullRangeFormats)
        return sizes.first { $0.width * 3 == $0.height * 4 } ?? sizes.first
            ?? Size(width: Constants.captureFallbackWidthPx, height: Constants.captureFallbackHeightPx)
    }

    /// Whether `format` supports `fps` within one of its frame-rate ranges.
    private static func formatSupportsFps(_ format: AVCaptureDevice.Format, _ fps: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains { range in
            Int(range.minFrameRate.rounded(.down)) <= fps
                && fps <= Int(range.maxFrameRate.rounded(.down))
        }
    }

    /// Human-readable, de-duplicated list of the frame-rate ranges supported at a
    /// resolution, for the settings-conflict message (e.g. "1-30, 2-240").
    private static func supportedFpsDescription(_ formatsAtSize: [AVCaptureDevice.Format]) -> String {
        var seen: Set<String> = []
        let unique =
            formatsAtSize
            .flatMap { $0.videoSupportedFrameRateRanges }
            .map { "\(Int($0.minFrameRate.rounded(.down)))-\(Int($0.maxFrameRate.rounded(.down)))" }
            .filter { seen.insert($0).inserted }
        return unique.isEmpty ? "none" : unique.joined(separator: ", ")
    }

    func reconfigureSize(_ size: Size) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                self.avSession.beginConfiguration()
                defer { self.avSession.commitConfiguration() }

                let currentInput = self.avSession.inputs
                    .compactMap { $0 as? AVCaptureDeviceInput }
                    .first
                guard let dev = currentInput?.device else {
                    cont.resume(throwing: EngineError.noBackCamera)
                    return
                }
                // Match on (FullRange pixel format, exact dimensions). FullRange-only
                // mirrors the initial open() filter (state.md Decision §63) so resolution
                // changes can't accidentally land on a VideoRange format.
                // Match on (FullRange 420f, exact dimensions), preferring a non-HDR
                // format that supports the currently-locked frame rate; a size that
                // can't do the locked fps is a conflict (configurable-frame-rate).
                let formatsAtSize = dev.formats.filter { fmt in
                    let subType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
                    guard subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                        return false
                    }
                    let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                    return Int(d.width) == size.width && Int(d.height) == size.height
                }
                guard !formatsAtSize.isEmpty else {
                    cont.resume(
                        throwing: EngineError.noSupportedFormat(
                            reason: "no format matching \(size.width)x\(size.height)"))
                    return
                }
                let fpsCapable = formatsAtSize.filter { Self.formatSupportsFps($0, self.lockedFps) }
                guard
                    let match = fpsCapable.first(where: { !$0.isVideoHDRSupported })
                        ?? fpsCapable.first
                else {
                    cont.resume(
                        throwing: EngineError.settingsConflict(
                            reason:
                                "frame rate \(self.lockedFps) fps is not supported at "
                                + "\(size.width)x\(size.height); supported: "
                                + Self.supportedFpsDescription(formatsAtSize)))
                    return
                }
                do {
                    try dev.lockForConfiguration()
                    dev.activeFormat = match
                    dev.automaticallyAdjustsVideoHDREnabled = false
                    if dev.activeFormat.isVideoHDRSupported {
                        dev.isVideoHDREnabled = false
                    }
                    let frameDuration = clampFrameDuration(
                        CMTimeMake(value: 1, timescale: Int32(self.lockedFps)),
                        toSupportedRanges: dev.activeFormat.videoSupportedFrameRateRanges)
                    dev.activeVideoMinFrameDuration = frameDuration
                    dev.activeVideoMaxFrameDuration = frameDuration
                    dev.unlockForConfiguration()
                    cont.resume()
                } catch {
                    cont.resume(throwing: EngineError.lockForConfigurationFailed)
                }
            }
        }
    }

    // MARK: - Private event handlers

    /// Human-readable name for an interruption reason — diagnostics only.
    ///
    /// The engine treats every reason except `videoDeviceInUseByAnotherClient`
    /// through the same generic interrupted → reconcile path, so this is for the
    /// log, not control flow. `sensitiveContentMitigationActivated` is decoded for
    /// completeness but is not expected for CameraKit: it only fires when an
    /// `SCVideoStreamAnalyzer` is associated with the device input (CameraKit
    /// attaches none) and would not auto-recover via `interruptionEndedNotification`
    /// (it needs the analyzer's `continueStream`).
    private static func interruptionReasonName(_ raw: Int) -> String {
        guard let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "invalid(\(raw))"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: return "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient: return "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "videoDeviceNotAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated: return "sensitiveContentMitigationActivated"
        @unknown default: return "unknown(\(raw))"
        }
    }

    private func handleInterruption(note: Notification, ended: Bool) {
        let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        let keys = note.userInfo?.keys.map { "\($0)" } ?? []
        CameraKitLog.notice(
            .engine,
            "[interruption] ended=\(ended) reason=\(Self.interruptionReasonName(rawReason)) "
                + "rawReason=\(rawReason) keys=\(keys)")
        let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason)
        if reason == .videoDeviceInUseByAnotherClient {
            onSessionEvent?(ended ? .cameraInUseEnded : .cameraInUseBegan)
        } else if ended {
            onSessionEvent?(.otherInterruptionEnded)
        } else {
            onSessionEvent?(.otherInterruption(reasonRawValue: rawReason))
        }
    }

    private func handleRuntimeError(note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        let msg = err.map { "\($0)" } ?? "unknown"
        CameraKitLog.error(.engine, "[session] runtime error: \(msg)")
        onSessionEvent?(.runtimeError(msg))
    }

    // MARK: - Frame rate control (U-16)

    /// Lock the frame rate to the session's `lockedFps` (min == max).
    ///
    /// The rate is locked identically in every mode (configurable-frame-rate); this
    /// is the idle/preview entry point. Caller must dispatch onto `sessionQueue`
    /// (ADR-07).
    func setPreviewFrameRateRange() async throws {
        guard let device = device else { return }
        try await device.lockForConfiguration()
        do {
            try await device.setVideoFrameDurationRange(
                minFrameDurationFps: lockedFps,
                maxFrameDurationFps: lockedFps
            )
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }

    /// Lock the frame rate to the session's `lockedFps` (min == max) for recording.
    ///
    /// configurable-frame-rate: the frame rate is locked identically in every mode —
    /// recording no longer widens the range to a low-light floor (that variable-rate
    /// behavior was removed; low-light auto-rate is out of scope). Kept as a distinct
    /// entry point for the record start/stop call sites. Caller must dispatch onto
    /// `sessionQueue` (ADR-07).
    func setRecordingFrameRateRange() async throws {
        guard let device = device else { return }
        try await device.lockForConfiguration()
        do {
            try await device.setVideoFrameDurationRange(
                minFrameDurationFps: lockedFps,
                maxFrameDurationFps: lockedFps
            )
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }

    // MARK: - Settings commit

    /// Commits a fully-resolved `CameraSettings` to the device inside a single
    /// `lockForConfiguration()` window on `sessionQueue` (ADR-07).
    ///
    /// The caller (`CameraEngine.updateSettings`) is responsible for having
    /// already run `merging(onto:)`, `SettingsCoupling.apply(rules:latched:)`,
    /// and range validation — this function only commits.
    ///
    /// ISO + exposure are coupled by `setIsoExposureManual(durationNs:iso:)`'s
    /// API shape (07-settings.md §Commit shape). Focus, white balance, zoom,
    /// and EV bias commit independently inside the same lock window.
    func applySettings(
        _ settings: CameraSettings,
        on device: any CaptureDeviceProviding
    ) async throws {
        try await device.lockForConfiguration()
        do {
            // Exposure + ISO — coupled commit when both manual.
            if settings.exposureMode == .manual,
                let durationNs = settings.exposureTimeNs,
                let iso = settings.iso
            {
                try await device.setIsoExposureManual(
                    durationNs: durationNs,
                    iso: Float(iso))
            } else if settings.exposureMode == .auto {
                try await device.setContinuousAutoExposure()
            }

            // Focus.
            if settings.focusMode == .manual, let d = settings.focusDistance {
                try await device.setFocusModeLocked(lensPosition: Float(d))
            } else if settings.focusMode == .auto {
                try await device.setContinuousAutoFocus()
            }

            // White balance.
            if let mode = settings.wbMode {
                switch mode {
                case .manual:
                    if let r = settings.wbGainR,
                        let g = settings.wbGainG,
                        let b = settings.wbGainB
                    {
                        // Bug 7: AVFoundation requires each gain in [1.0, maxWhiteBalanceGain]
                        // and throws NSInvalidArgumentException → SIGABRT otherwise.
                        // grayWorldGains() can produce out-of-range values for any
                        // non-gray sample, so clamp here regardless of source.
                        let maxGain = await device.maxWhiteBalanceGain
                        let clamp: (Double) -> Float = { v in
                            min(maxGain, max(1.0, Float(v)))
                        }
                        try await device.setWhiteBalanceModeLocked(
                            gains: WhiteBalanceGains(
                                red: clamp(r),
                                green: clamp(g),
                                blue: clamp(b)))
                    }
                case .locked:
                    try await device.setWhiteBalanceLocked()
                case .auto:
                    try await device.setContinuousAutoWhiteBalance()
                }
            }

            // Zoom.
            if let z = settings.zoomRatio {
                try await device.setZoomFactor(z)
            }

            // EV compensation (effective only in auto exposure per domain).
            if let ev = settings.evCompensation {
                try await device.setExposureCompensation(ev)
            }

            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }
}
