// RemoveNaturalLaneTests — verification for the remove-natural-lane change.
//
// Pure, device-free assertions that the streaming natural lane is gone:
//   • StreamId is exactly {primary, tracker} — no `natural`.
//   • SessionCapabilities carries no `naturalTextureId`.
//
// The calibration-independence requirement (WB/BB still sample the preserved
// internal 16F natural texture) is exercised on-device by Stage04Tests /
// Stage11Tests via `setLatestNaturalForTest` + the calibration dispatch. The
// natural still-capture survival (ISP one-shot + gradeOneShot) is covered by
// CaptureNaturalPictureTests (encode path) and on-device HITL.
import Foundation
import Testing

@testable import CameraKit

@Suite struct RemoveNaturalLaneTests {

    // The streaming lanes are exactly `primary` and `tracker`; `natural` is absent.
    @Test func streamIdHasOnlyPrimaryAndTracker() {
        #expect(StreamId.allCases == [.primary, .tracker])
        #expect(StreamId(rawValue: "natural") == nil)
    }

    // SessionCapabilities no longer exposes a natural texture id.
    @Test func sessionCapabilitiesHasNoNaturalTextureId() {
        let caps = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0,
            trackerResolution: Size(width: 854, height: 480))
        let fieldNames = Set(Mirror(reflecting: caps).children.compactMap { $0.label })
        #expect(!fieldNames.contains("naturalTextureId"))
        #expect(fieldNames.contains("previewTextureId"))
    }
}
