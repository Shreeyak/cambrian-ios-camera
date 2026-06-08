import Foundation
import Testing

@testable import CameraKit

/// camera-crop-config — center-relative crop math (D2), the remembered default
/// (D3/D4), resolution validation (D1), and the geometry invariants enforced at
/// every entry point.
///
/// The ROI/validation logic is unit-tested through the pure static helpers
/// (`centerCropRect`, `centeredDefaultCrop`, `validateRequestedResolution`) so the
/// math is deterministic without a live capture session. The open()/setResolution
/// *apply* paths and "first frame already cropped" need camera hardware and are
/// covered by device HITL (matching the Stage04 crop-precedent).
@Suite("CameraCropConfigTests", .progressLogged)
struct CameraCropConfigTests {

    /// Every applied crop must have even x/y/width/height (4:2:0) and lie fully
    /// within the resolution — the "Crop geometry invariants" requirement.
    private func expectInvariants(_ r: Rect, in res: Size) {
        #expect(r.x % 2 == 0 && r.y % 2 == 0 && r.width % 2 == 0 && r.height % 2 == 0)
        #expect(r.x >= 0 && r.y >= 0)
        #expect(r.x + r.width <= res.width)
        #expect(r.y + r.height <= res.height)
    }

    // MARK: - setCenterCrop math (D2)

    @Test func centeredNoOffsetIsCentered() {
        let res = Size(width: 1920, height: 1440)
        let r = CameraEngine.centerCropRect(
            width: 1440, height: 1440, offsetX: 0, offsetY: 0, resolution: res)
        #expect(r == Rect(x: 240, y: 0, width: 1440, height: 1440))
        expectInvariants(r, in: res)
    }

    /// The user worked example: 100×100 resolution & crop, offset (0.1, 0.2).
    ///
    /// Center computes to (60, 70) but a full-size crop has only one legal
    /// origin (0, 0) — the offset is a no-op after the clamp.
    @Test func workedExampleFullSizeCropOffsetIsNoOp() {
        let res = Size(width: 100, height: 100)
        let r = CameraEngine.centerCropRect(
            width: 100, height: 100, offsetX: 0.1, offsetY: 0.2, resolution: res)
        #expect(r == Rect(x: 0, y: 0, width: 100, height: 100))
        expectInvariants(r, in: res)
    }

    @Test func offsetHonoredWhenCropHasRoom() {
        let res = Size(width: 1920, height: 1440)
        // centerX = 960 + 0.1*1920 = 1152 → x = 1152 - 720 = 432 (in-bounds).
        let r = CameraEngine.centerCropRect(
            width: 1440, height: 1440, offsetX: 0.1, offsetY: 0, resolution: res)
        #expect(r == Rect(x: 432, y: 0, width: 1440, height: 1440))
        expectInvariants(r, in: res)
    }

    @Test func offsetOutOfBoundsClampsInside() {
        let res = Size(width: 1920, height: 1440)
        // centerX = 960 + 0.9*1920 = 2688 → x = 1968, clamped to (1920-1440)=480.
        let r = CameraEngine.centerCropRect(
            width: 1440, height: 1440, offsetX: 0.9, offsetY: 0, resolution: res)
        #expect(r == Rect(x: 480, y: 0, width: 1440, height: 1440))
        expectInvariants(r, in: res)
    }

    @Test func oddAndOversizedDimensionsNormalize() {
        let res = Size(width: 1920, height: 1440)
        // width 1001 → even-down 1000; height 5000 → capped at 1440.
        let r = CameraEngine.centerCropRect(
            width: 1001, height: 5000, offsetX: 0, offsetY: 0, resolution: res)
        #expect(r.width == 1000)
        #expect(r.height == 1440)
        expectInvariants(r, in: res)
    }

    // MARK: - Remembered default (D3/D4)

    @Test func defaultCropMatchesConstantOnLargeSensor() {
        let res = Size(width: 4160, height: 3120)
        let r = CameraEngine.centeredDefaultCrop(in: res)
        #expect(r.width == Constants.cropDefaultWidthPx)
        #expect(r.height == Constants.cropDefaultHeightPx)
        #expect(r == Rect(x: 1360, y: 840, width: 1440, height: 1440))
        expectInvariants(r, in: res)
    }

    @Test func defaultCropClampsToSmallerResolution() {
        let res = Size(width: 1280, height: 960)
        let r = CameraEngine.centeredDefaultCrop(in: res)
        // 1440² does not fit 1280×960 — clamp to full frame, never upscale.
        #expect(r == Rect(x: 0, y: 0, width: 1280, height: 960))
        expectInvariants(r, in: res)
    }

    // MARK: - Resolution validation (D1)

    @Test func nilResolutionIsAlwaysValid() throws {
        try CameraEngine.validateRequestedResolution(nil, supportedSizes: [Size(width: 1280, height: 960)])
    }

    @Test func supportedResolutionPasses() throws {
        let supported = [Size(width: 1920, height: 1440), Size(width: 1280, height: 960)]
        try CameraEngine.validateRequestedResolution(Size(width: 1280, height: 960), supportedSizes: supported)
    }

    @Test func unsupportedResolutionThrowsSettingsConflict() {
        let supported = [Size(width: 1280, height: 960)]
        #expect(throws: EngineError.self) {
            try CameraEngine.validateRequestedResolution(Size(width: 123, height: 456), supportedSizes: supported)
        }
    }

    // MARK: - Engine entry-point guards (no session → notOpen)

    @Test func centerCropOnUnopenedEngineThrows() async {
        let engine = CameraEngine(initialPhase: .active)
        await #expect(throws: EngineError.self) {
            try await engine.setCenterCrop(width: 1440, height: 1440, offsetX: 0, offsetY: 0)
        }
    }

    @Test func setCropEnabledOnUnopenedEngineThrows() async {
        let engine = CameraEngine(initialPhase: .active)
        await #expect(throws: EngineError.self) {
            try await engine.setCropEnabled(true)
        }
    }
}

/// Device-backed coverage for the one open-session behavior that can run under
/// `xcodebuild test` here: rejection of an unsupported resolution.
///
/// It throws inside `CameraSession.configure()` at format selection — *before*
/// `open()` reaches `device.exposureDurationRangeNs`, which fatal-errors in the
/// xcodebuild-test launch context on this device (a pre-existing, out-of-scope
/// `Int64(CMTimeGetSeconds(maxExposureDuration) * 1e9)` crash on a non-finite
/// CMTime; production `open()` is unaffected). So the full-open scenarios
/// (apply-a-supported-size, crop-on-open, disable→re-enable) cannot run here and
/// are verified by construction + app HITL, not by this suite.
@Suite("CameraCropConfigDeviceTests", .serialized)
struct CameraCropConfigDeviceTests {

    /// An unsupported requested resolution is rejected at open with
    /// `settingsConflict` (not a generic error), and the session is not started.
    @Test func openRejectsUnsupportedResolution() async throws {
        let engine = CameraEngine(initialPhase: .active)
        do {
            _ = try await engine.open(
                configuration: OpenConfiguration(captureResolution: Size(width: 123, height: 457)))
            Issue.record("expected open() to throw for an unsupported resolution")
        } catch let error as EngineError {
            guard case .settingsConflict = error else {
                Issue.record("expected EngineError.settingsConflict, got \(error)")
                await engine.close()
                return
            }
        }
        await engine.close()
    }
}
