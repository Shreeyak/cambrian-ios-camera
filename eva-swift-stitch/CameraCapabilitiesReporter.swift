import AVFoundation
import CoreMedia
import os

/// Standalone diagnostic reporter — NOT part of CamPlugin.
/// Logs camera hardware capabilities to inform design decisions.
/// Call `report()` once after camera permission is granted.
/// Returns a formatted string suitable for on-screen display.
struct CameraCapabilitiesReporter {

    private static let log = Logger(subsystem: "com.cambrian.cam-caps", category: "capabilities")

    /// Runs all three passes and returns the full report as a string.
    static func report() -> String {
        var lines: [String] = []
        func emit(_ s: String) {
            log.info("\(s)")
            lines.append(s)
        }

        emit("=== Camera Capabilities Report ===")
        deviceInventory(emit: emit)
        activeFormatDetails(emit: emit)
        pixelFormatAvailability(emit: emit)
        emit("=== End of Report ===")

        let output = lines.joined(separator: "\n")
        saveToDocuments(output)
        return output
    }

    // MARK: - Pass 1: Device inventory (no session required)

    private static func deviceInventory(emit: (String) -> Void) {
        emit("--- Pass 1: Device Inventory ---")

        let deviceTypes: [AVCaptureDevice.DeviceType]
#if os(iOS)
        deviceTypes = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
            .builtInLiDARDepthCamera,
        ]
#else
        deviceTypes = [.builtInWideAngleCamera]
#endif

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        if discovery.devices.isEmpty {
            emit("  (no video capture devices found)")
            return
        }

        for device in discovery.devices {
            let pos = positionName(device.position)
#if os(iOS)
            emit("[\(device.deviceType.rawValue)]")
            emit("  name    : \(device.localizedName)")
            emit("  position: \(pos)")
            emit("  modelID : \(device.modelID)")
            emit(String(format: "  zoom    : %.1fx – %.1fx",
                        device.minAvailableVideoZoomFactor,
                        device.maxAvailableVideoZoomFactor))

            let switchFactors = device.virtualDeviceSwitchOverVideoZoomFactors
            if !switchFactors.isEmpty {
                let s = switchFactors.map { String(format: "%.1fx", $0.doubleValue) }.joined(separator: ", ")
                emit("  opticalSwitchPoints: \(s)")
            }
#else
            emit("[\(device.deviceType.rawValue)] \(device.localizedName)  pos=\(pos)")
#endif
            emit("")
        }
    }

    // MARK: - Pass 2: Active-format details for the back wide-angle camera

    private static func activeFormatDetails(emit: (String) -> Void) {
        emit("--- Pass 2: Active Format Details ---")

        guard let device = preferredWideAngle() else {
            emit("  (no wide-angle camera found)")
            return
        }
        emit("Device: \(device.localizedName)  (total formats: \(device.formats.count))")

        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let fpsStr = fmt.videoSupportedFrameRateRanges
            .map { "\(Int($0.minFrameRate))–\(Int($0.maxFrameRate))fps" }
            .joined(separator: ", ")

#if os(iOS)
        let nativeZoomStr = fmt.secondaryNativeResolutionZoomFactors
            .map { String(format: "%.2fx", Double($0)) }
            .joined(separator: ", ")

        emit("Active format:")
        emit("  dimensions   : \(dims.width)x\(dims.height)")
        emit(String(format: "  upscaleThresh: %.2fx  <- digital upscale starts here", fmt.videoZoomFactorUpscaleThreshold))
        emit("  nativeZooms  : \(nativeZoomStr.isEmpty ? "(none)" : nativeZoomStr)  <- lossless non-1x points")
        emit("  frameRates   : \(fpsStr)")
        emit("  HDR video    : \(fmt.isVideoHDRSupported)")
        emit("")

        let withNative = device.formats.filter { !$0.secondaryNativeResolutionZoomFactors.isEmpty }
        emit("Formats with secondaryNativeResolutionZoomFactors: \(withNative.count) / \(device.formats.count)")
        for f in withNative {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let nz = f.secondaryNativeResolutionZoomFactors
                .map { String(format: "%.2fx", Double($0)) }.joined(separator: ", ")
            let marker = f == device.activeFormat ? " <- ACTIVE" : ""
            emit(String(format: "  %dx%d  nativeZooms=[%@]  upscale@%.2fx%@",
                        d.width, d.height, nz, f.videoZoomFactorUpscaleThreshold, marker))
        }
#else
        emit("  \(dims.width)x\(dims.height)  \(fpsStr)  (zoom props unavailable on macOS)")
#endif
        emit("")
    }

    // MARK: - Pass 3: Pixel format availability via ephemeral session

    private static func pixelFormatAvailability(emit: (String) -> Void) {
        emit("--- Pass 3: Pixel Format Availability ---")

        guard let device = preferredWideAngle() else {
            emit("  (no camera available)")
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                emit("  ERROR: cannot add camera input")
                return
            }
            session.addInput(input)
        } catch {
            emit("  ERROR: \(error)")
            return
        }

        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else {
            emit("  ERROR: cannot add video output")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        let available = output.availableVideoPixelFormatTypes
        emit("All available pixel formats (\(available.count)):")
        for fmt in available {
            emit("  \(pixelFormatName(fmt))  (\(fmt))")
        }
        emit("")

        let interesting: [(OSType, String)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,  "420v   8-bit BiPlanar VideoRange"),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,   "420f   8-bit BiPlanar FullRange"),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "x420  10-bit BiPlanar VideoRange"),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,  "xf20  10-bit BiPlanar FullRange"),
            (kCVPixelFormatType_32BGRA,                        "BGRA  32-bit"),
            (kCVPixelFormatType_64RGBAHalf,                    "RGhA  64-bit RGBA half-float  <- KEY"),
        ]

        emit("Formats of interest:")
        for (type, name) in interesting {
            emit("  \(available.contains(type) ? "[YES]" : "[ NO]")  \(name)")
        }

        // Lossless 64RGBAHalf: 'lR6h' = 0x6C523668
        let lossless64: OSType = 0x6C523668
        emit("  \(available.contains(lossless64) ? "[YES]" : "[ NO]")  lossless-64RGBAHalf (0x\(String(lossless64, radix: 16)))")
    }

    // MARK: - File output

    private static func saveToDocuments(_ text: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("capabilities.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            print("Saved report to: \(url.path)")
        } catch {
            print("Failed to save report: \(error)")
        }
    }

    // MARK: - Helpers

    private static func preferredWideAngle() -> AVCaptureDevice? {
#if os(iOS)
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
#else
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
#endif
    }

    private static func positionName(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .back:        return "back"
        case .front:       return "front"
        case .unspecified: return "unspecified"
        @unknown default:  return "unknown(\(position.rawValue))"
        }
    }

    private static func pixelFormatName(_ type: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8)  & 0xFF),
            UInt8( type        & 0xFF),
        ]
        if bytes.allSatisfy({ $0 > 31 && $0 < 127 }),
           let str = String(bytes: bytes, encoding: .ascii) {
            return "'\(str)'"
        }
        return "0x\(String(type, radix: 16, uppercase: true))"
    }
}
