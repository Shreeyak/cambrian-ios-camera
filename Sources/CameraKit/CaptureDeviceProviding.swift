import AVFoundation
import Foundation

// MARK: - ADR-32 test seam

/// ADR-32: engine depends on this protocol, never on AVCaptureDevice directly.
///
/// The fake in tests supplies canned format data without touching AVFoundation.
public protocol CaptureDeviceProviding: AnyObject, Sendable {
    var uniqueID: String { get async }
    var activeFormatSize: Size { get async }
    var supportedSizes: [Size] { get async }
    var isoRange: ClosedRange<Float> { get async }
    var exposureDurationRangeNs: ClosedRange<Int64> { get async }
    var maxWhiteBalanceGain: Float { get async }

    func lockForConfiguration() async throws
    func unlockForConfiguration() async

    func setExposureModeCustom(durationNs: Int64, iso: Float) async throws
    func setContinuousAutoExposure() async throws

    func setFocusModeLocked(lensPosition: Float) async throws
    func setContinuousAutoFocus() async throws

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) async throws
    func setContinuousAutoWhiteBalance() async throws
    func setWhiteBalanceLocked() async throws

    func setZoomFactor(_ factor: Double) async throws
    func setExposureCompensation(_ steps: Int) async throws

    func setVideoFrameDurationRange(
        minFrameDurationFps: Int,
        maxFrameDurationFps: Int
    ) async throws

    // Stage 03 — KVO-backed device-state stream (ADR-14). Rule 3 of
    // ISO/exposure coupling reads `lastSnapshot`.
    func snapshotStream() -> AsyncStream<DeviceStateSnapshot>
    var lastSnapshot: DeviceStateSnapshot? { get async }
}

// MARK: - DeviceStateSnapshot (ADR-14; KVO stream wired Stage 03)

public struct DeviceStateSnapshot: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let lensPosition: Float
    public let whiteBalanceGains: WhiteBalanceGains
    public let isAdjustingExposure: Bool
    public let systemPressureLevel: SystemPressureLevel

    public init(
        iso: Float, exposureDurationNs: Int64, lensPosition: Float,
        whiteBalanceGains: WhiteBalanceGains, isAdjustingExposure: Bool,
        systemPressureLevel: SystemPressureLevel
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.lensPosition = lensPosition
        self.whiteBalanceGains = whiteBalanceGains
        self.isAdjustingExposure = isAdjustingExposure
        self.systemPressureLevel = systemPressureLevel
    }
}

public enum SystemPressureLevel: String, Sendable, Hashable {
    case nominal
    case fair
    case serious
    case critical
    case shutdown
}

// MARK: - Production implementation

/// Production implementation: wraps a single back-facing wide-angle AVCaptureDevice (D-08).
/// CameraSession receives avDevice for sessionQueue work; tests never reach this type.
final actor LiveCaptureDevice: CaptureDeviceProviding {
    // nonisolated(unsafe): accessed from nonisolated snapshotStream() factory;
    // AVCaptureDevice mutations always gate through lockForConfiguration() on
    // sessionQueue (ADR-07), so cross-isolation reads are safe.
    nonisolated(unsafe) let avDevice: AVCaptureDevice

    init(avDevice: AVCaptureDevice) {
        self.avDevice = avDevice
    }

    var uniqueID: String { avDevice.uniqueID }

    var activeFormatSize: Size {
        let dims = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)
        return Size(width: Int(dims.width), height: Int(dims.height))
    }

    var supportedSizes: [Size] {
        avDevice.formats.compactMap { format in
            // Filter to 8-bit biplanar YUV (CAPTURE_PIXEL_FORMAT per constants.md)
            let desc = format.formatDescription
            let pixelFormat = CMFormatDescriptionGetMediaSubType(desc)
            guard
                pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            return Size(width: Int(dims.width), height: Int(dims.height))
        }
    }

    var isoRange: ClosedRange<Float> {
        avDevice.activeFormat.minISO...avDevice.activeFormat.maxISO
    }

    var exposureDurationRangeNs: ClosedRange<Int64> {
        let minNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.minExposureDuration) * 1_000_000_000)
        let maxNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.maxExposureDuration) * 1_000_000_000)
        return minNs...maxNs
    }

    var maxWhiteBalanceGain: Float { avDevice.maxWhiteBalanceGain }

    func lockForConfiguration() throws { try avDevice.lockForConfiguration() }
    func unlockForConfiguration() { avDevice.unlockForConfiguration() }

    func setExposureModeCustom(durationNs: Int64, iso: Float) throws {
        let duration = CMTimeMake(value: durationNs, timescale: 1_000_000_000)
        avDevice.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
    }

    func setContinuousAutoExposure() throws {
        guard avDevice.isExposureModeSupported(.continuousAutoExposure) else { return }
        avDevice.exposureMode = .continuousAutoExposure
    }

    func setFocusModeLocked(lensPosition: Float) throws {
        avDevice.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
    }

    func setContinuousAutoFocus() throws {
        guard avDevice.isFocusModeSupported(.continuousAutoFocus) else { return }
        avDevice.focusMode = .continuousAutoFocus
    }

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {
        let avGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: gains.red, greenGain: gains.green, blueGain: gains.blue)
        avDevice.setWhiteBalanceModeLocked(with: avGains, completionHandler: nil)
    }

    func setContinuousAutoWhiteBalance() throws {
        guard avDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        avDevice.whiteBalanceMode = .continuousAutoWhiteBalance
    }

    func setWhiteBalanceLocked() throws {
        guard avDevice.isWhiteBalanceModeSupported(.locked) else { return }
        avDevice.whiteBalanceMode = .locked
    }

    func setZoomFactor(_ factor: Double) throws {
        avDevice.videoZoomFactor = CGFloat(factor)
    }

    func setExposureCompensation(_ steps: Int) throws {
        avDevice.setExposureTargetBias(Float(steps), completionHandler: nil)
    }

    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {
        avDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(minFrameDurationFps))
        avDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(maxFrameDurationFps))
    }

    private var kvoObserver: DeviceKVOObserver?
    private var _lastSnapshot: DeviceStateSnapshot?
    private var ingestTask: Task<Void, Never>?

    var lastSnapshot: DeviceStateSnapshot? { _lastSnapshot }

    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        let (stream, _) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        return stream
    }

    func installKVOIngest() {
        guard ingestTask == nil else { return }
        let (stream, observer) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        kvoObserver = observer
        ingestTask = Task { [weak self] in
            for await snap in stream {
                if Task.isCancelled { return }
                await self?.setLastSnapshot(snap)
            }
        }
    }

    func cancelKVO() {
        ingestTask?.cancel()
        ingestTask = nil
        kvoObserver = nil
    }

    private func setLastSnapshot(_ snap: DeviceStateSnapshot) {
        _lastSnapshot = snap
    }
}
