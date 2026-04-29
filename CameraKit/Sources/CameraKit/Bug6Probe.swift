// Bug 6 instrumentation — green band below previews / Bug 9 still-capture
// green region. Hypothesis: GPU destination textures (naturalPool/processedPool)
// are allocated at `captureSize` (taken from CMVideoFormatDescription before the
// connection is wired), but the actual delivered CVPixelBuffer dimensions
// differ. Pass 1's compute kernel dispatches over the *destination* texture; for
// gid past the Y/CbCr input bounds, `texture2d::read` returns clamped zeros,
// which BT.601 maps to roughly (R=-0.7, G=0.53, B=-0.89) — pure GREEN on
// display. Pass 2's color transform then modulates that band via the
// Black-Balance green slider, which matches the user-confirmed symptom.
//
// TEMPORARY. Pre-Stage-12 HITL. Revert by deleting this file plus the
// `Bug6Probe.*` call sites in `MetalPipeline.swift` and `CameraView.swift`.

import AVFoundation
import Atomics
import CoreVideo
import Foundation
import Metal

enum Bug6Probe {

    // Master switch — flip to `false` to make every entry point a no-op.
    nonisolated(unsafe) static var enabled: Bool = true

    // Latched state per category — log once on first observation, again on change.
    nonisolated(unsafe) private static var lastConfiguredSize: (w: Int, h: Int)?
    nonisolated(unsafe) private static var lastBufferSig: (yW: Int, yH: Int, cW: Int, cH: Int, fullW: Int, fullH: Int)?
    nonisolated(unsafe) private static var lastDrawSig:
        (texW: Int, texH: Int, drawW: Int, drawH: Int, viewW: Int, viewH: Int)?
    nonisolated(unsafe) private static var mismatchCount: Int = 0

    /// Called once from `MetalPipeline.init` to record the configured destination size.
    static func noteConfigured(captureSize: Size, trackerSize: Size) {
        guard enabled else { return }
        let line =
            "[bug6][configured] dst=\(captureSize.width)x\(captureSize.height) "
            + "tracker=\(trackerSize.width)x\(trackerSize.height)"
        lastConfiguredSize = (captureSize.width, captureSize.height)
        CameraKitLog.write(line)
        CameraKitLog.metal.info("\(line, privacy: .public)")
    }

    /// Called per-frame from `MetalPipeline.encode()`.
    ///
    /// Logs once on first frame and again on any subsequent dimension change.
    /// Adds an explicit `[mismatch]` marker when the input differs from the
    /// configured destination — that's the smoking gun for Bug 6.
    static func noteIncomingPixelBuffer(_ pb: CVPixelBuffer, frame: UInt64) {
        guard enabled else { return }
        let yW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let yH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let cW = CVPixelBufferGetWidthOfPlane(pb, 1)
        let cH = CVPixelBufferGetHeightOfPlane(pb, 1)
        let fullW = CVPixelBufferGetWidth(pb)
        let fullH = CVPixelBufferGetHeight(pb)
        let sig = (yW: yW, yH: yH, cW: cW, cH: cH, fullW: fullW, fullH: fullH)
        if let prev = lastBufferSig,
            prev.yW == sig.yW && prev.yH == sig.yH
                && prev.cW == sig.cW && prev.cH == sig.cH
                && prev.fullW == sig.fullW && prev.fullH == sig.fullH
        {
            return  // no change since last log
        }
        lastBufferSig = sig
        let cfg = lastConfiguredSize
        let cfgW = cfg?.w ?? -1
        let cfgH = cfg?.h ?? -1
        let mismatch = (cfgW != yW) || (cfgH != yH) || (cfgW != fullW) || (cfgH != fullH)
        if mismatch { mismatchCount += 1 }
        let tag = mismatch ? "[mismatch]" : "[ok]"
        let line =
            "[bug6][incoming]\(tag) frame=\(frame) "
            + "configured=\(cfgW)x\(cfgH) "
            + "buffer=\(fullW)x\(fullH) y=\(yW)x\(yH) cbcr=\(cW)x\(cH) "
            + "mismatchCount=\(mismatchCount)"
        CameraKitLog.write(line)
        CameraKitLog.metal.info("\(line, privacy: .public)")
    }

    /// Dumps every `AVCaptureDevice.Format` the device exposes.
    ///
    /// Records the fields that matter for the binning / detail trade-off:
    /// dimensions, framerate range, pixel format, isVideoBinned,
    /// isHighestPhotoQualitySupported, supportedMaxPhotoDimensions,
    /// videoFieldOfView. One header line + one row per format.
    static func dumpDeviceFormats(_ device: AVCaptureDevice) {
        guard enabled else { return }
        let header =
            "[bug6][formats][begin] modelID=\(device.modelID) "
            + "deviceType=\(device.deviceType.rawValue) count=\(device.formats.count)"
        CameraKitLog.write(header)
        CameraKitLog.metal.info("\(header, privacy: .public)")
        for (idx, f) in device.formats.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let subStr = fourCC(sub)
            let fpsRanges = f.videoSupportedFrameRateRanges
                .map { "\($0.minFrameRate)-\($0.maxFrameRate)" }
                .joined(separator: ",")
            let binned = f.isVideoBinned
            let hqPhoto = f.isHighestPhotoQualitySupported
            let hPhoto = f.isHighPhotoQualitySupported
            let maxPhoto = f.supportedMaxPhotoDimensions
                .map { "\($0.width)x\($0.height)" }
                .joined(separator: ",")
            let fov = f.videoFieldOfView
            let stabStd = f.isVideoStabilizationModeSupported(.standard)
            let stabCine = f.isVideoStabilizationModeSupported(.cinematic)
            let line =
                "[bug6][format] idx=\(idx) "
                + "dims=\(dims.width)x\(dims.height) sub=\(subStr) "
                + "fpsRanges=[\(fpsRanges)] "
                + "binned=\(binned) hqPhoto=\(hqPhoto) hPhoto=\(hPhoto) "
                + "maxPhotoDims=[\(maxPhoto)] "
                + "fov=\(String(format: "%.1f", fov)) "
                + "stab(std=\(stabStd),cine=\(stabCine))"
            CameraKitLog.write(line)
            CameraKitLog.metal.info("\(line, privacy: .public)")
        }
        let footer = "[bug6][formats][end]"
        CameraKitLog.write(footer)
        CameraKitLog.metal.info("\(footer, privacy: .public)")
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let s = String(bytes: bytes, encoding: .ascii) ?? "?"
        return "\(s)(\(String(format: "0x%08x", code)))"
    }

    /// Called from `MTKViewCoordinator.draw(in:)`.
    ///
    /// Logs once on first draw and again on any subsequent dimension change.
    /// Flags when the source preview texture is smaller than the drawable —
    /// the un-blitted region is what shows the persistent green band.
    static func noteDraw(
        label: String,
        texture: MTLTexture,
        drawable: any MTLDrawable,
        drawableTextureWidth: Int,
        drawableTextureHeight: Int,
        viewBounds: CGSize
    ) {
        guard enabled else { return }
        _ = drawable  // documents intent
        let texW = texture.width
        let texH = texture.height
        let drW = drawableTextureWidth
        let drH = drawableTextureHeight
        let vW = Int(viewBounds.width.rounded())
        let vH = Int(viewBounds.height.rounded())
        let sig = (
            texW: texW, texH: texH, drawW: drW, drawH: drH, viewW: vW, viewH: vH
        )
        if let prev = lastDrawSig,
            prev.texW == sig.texW && prev.texH == sig.texH
                && prev.drawW == sig.drawW && prev.drawH == sig.drawH
                && prev.viewW == sig.viewW && prev.viewH == sig.viewH
        {
            return  // no change since last log
        }
        lastDrawSig = sig
        let dropX = drW - texW
        let dropY = drH - texH
        let underfill = dropX > 0 || dropY > 0
        let tag = underfill ? "[underfill]" : "[fits]"
        let line =
            "[bug6][draw]\(tag) view=\(label) "
            + "tex=\(texW)x\(texH) drawable=\(drW)x\(drH) "
            + "viewBounds=\(vW)x\(vH) underfillPx=\(dropX)x\(dropY)"
        CameraKitLog.write(line)
        CameraKitLog.metal.info("\(line, privacy: .public)")
    }
}
