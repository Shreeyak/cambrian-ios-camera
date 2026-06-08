import Foundation
import Testing

@testable import CameraKit

/// camera-crop-config — center-relative crop math (D2), the remembered default
/// (D3/D4), resolution validation (D1), and the geometry invariants enforced at
/// every entry point.
///
/// The ROI/validation logic is unit-tested here through the pure static helpers
/// (`centerCropRect`, `centeredDefaultCrop`, `validateRequestedResolution`) so the
/// math is deterministic without a live capture session. The open()/apply paths
/// (resolution applied, crop-on-open, disable→re-enable) run on real hardware in
/// `CameraCropConfigDeviceTests`; cropped-pixel delivery remains app HITL.
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

/// Device-backed coverage of the open-session crop/resolution behavior.
///
/// Full `open()` runs under `xcodebuild test` since the `CMTime.finiteNanoseconds`
/// guard fixed the non-finite `maxExposureDuration` → `Int64` trap that previously
/// fatal-errored at `device.exposureDurationRangeNs` on every open. These tests
/// read *measured* hardware state — `_activeFormatSizeForTest` (the real active
/// format, not the echoed `activeCaptureResolution`) and `_activeCropRegionForTest`
/// (the live pipeline crop, not the `currentCropRegion` mirror) — so the
/// assertions are non-tautological. Actual cropped-pixel *delivery* still relies
/// on app HITL; this suite verifies the applied geometry, not frame contents.
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

    /// Discriminating probe: a default `open()` completes and reports a *real*
    /// active format.
    ///
    /// Before the `CMTime.finiteNanoseconds` guard, `open()` fatal-errored here
    /// (non-finite `maxExposureDuration` → `Int64` trap). A real materialized
    /// format has non-degenerate dimensions (≥ the 640×480 floor the picker
    /// enforces); a placeholder would not. If this passes, the active format is
    /// genuine and the measured-resolution assertion below is meaningful.
    @Test func openCompletesWithRealActiveFormat() async throws {
        let engine = CameraEngine(initialPhase: .active)
        _ = try await engine.open(configuration: OpenConfiguration())
        let measured = try await engine._activeFormatSizeForTest()
        #expect(measured.width >= 640 && measured.height >= 480)
        await engine.close()
    }

    /// A requested supported resolution is actually applied to the hardware.
    ///
    /// Reads the *measured* `activeFormatSize` (not the echoed
    /// `activeCaptureResolution`): opens at the default to discover the supported
    /// set and the default format, then reopens at a different supported size and
    /// confirms the device's active format matches the request.
    @Test func appliesRequestedSupportedResolution() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let caps = try await engine.open(configuration: OpenConfiguration())
        let defaultSize = try await engine._activeFormatSizeForTest()
        let supported = caps.supportedSizes
        await engine.close()

        guard let target = supported.first(where: { $0 != defaultSize }) else {
            // A silent skip here would report green without exercising the apply
            // path — the one behavior this test exists to prove. Make it loud.
            Issue.record(
                "device reported only one distinct supported size (\(defaultSize)); resolution-apply path not exercised"
            )
            return
        }

        let caps2 = try await engine.open(
            configuration: OpenConfiguration(captureResolution: target))
        let measured = try await engine._activeFormatSizeForTest()
        #expect(measured == target)
        #expect(caps2.activeCaptureResolution == target)
        await engine.close()
    }

    /// Opening with `cropEnabled` applies the centered default crop geometry —
    /// the first pipeline state is already cropped, not full-frame.
    ///
    /// Reads the pipeline-derived `activeCropRegion` (not an echoed value) and
    /// compares it to the expected default computed from the measured format.
    @Test func cropOnOpenAppliesDefaultGeometry() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let caps = try await engine.open(
            configuration: OpenConfiguration(cropEnabled: true))
        let measured = try await engine._activeFormatSizeForTest()
        let expected = CameraEngine.centeredDefaultCrop(in: measured)
        #expect(caps.activeCropRegion == expected)
        // The default crop must be a true sub-region, not the full frame, on a
        // sensor large enough to contain it.
        if measured.width > expected.width || measured.height > expected.height {
            #expect(
                caps.activeCropRegion
                    != Rect(
                        x: 0, y: 0, width: measured.width, height: measured.height))
        }
        await engine.close()
    }

    /// Disabling crop returns to full-frame; re-enabling restores the default
    /// geometry — verified against the live pipeline crop, not the mirror.
    @Test func disableThenReEnableRestoresGeometry() async throws {
        let engine = CameraEngine(initialPhase: .active)
        _ = try await engine.open(configuration: OpenConfiguration(cropEnabled: true))
        let measured = try await engine._activeFormatSizeForTest()
        let fullFrame = Rect(x: 0, y: 0, width: measured.width, height: measured.height)
        let expectedCrop = CameraEngine.centeredDefaultCrop(in: measured)

        // Enabled at open → default crop.
        #expect(try await engine._activeCropRegionForTest() == expectedCrop)

        // Disable → full frame.
        try await engine.setCropEnabled(false)
        #expect(try await engine._activeCropRegionForTest() == fullFrame)

        // Re-enable → default crop again.
        try await engine.setCropEnabled(true)
        #expect(try await engine._activeCropRegionForTest() == expectedCrop)

        await engine.close()
    }
}
