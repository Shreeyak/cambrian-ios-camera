// FrameMetadataSignalsTests — verification for the frame-metadata-signals change.
//
// Covers the pure mapping seams (no device required):
//   • DeviceStateSnapshot → CameraFrameMetadata convergence mapping (settled etc.)
//   • the typed/JSON split: grade params live in FrameDiagnostics JSON only, never
//     as typed CameraFrameMetadata fields.
import Foundation
import Testing

@testable import CameraKit

@Suite struct FrameMetadataSignalsTests {

    // Helper: a snapshot with all-converged defaults, overridable per axis.
    private func snapshot(
        adjustingFocus: Bool = false,
        adjustingWB: Bool = false,
        adjustingExposure: Bool = false
    ) -> DeviceStateSnapshot {
        DeviceStateSnapshot(
            iso: 100,
            exposureDurationNs: 16_000_000,
            lensPosition: 0.5,
            whiteBalanceGains: WhiteBalanceGains(red: 1.9, green: 1.0, blue: 1.6),
            isAdjustingExposure: adjustingExposure,
            isAdjustingFocus: adjustingFocus,
            isAdjustingWhiteBalance: adjustingWB,
            systemPressureLevel: .nominal)
    }

    // 4.1 — a mid-autofocus frame is not settled and reports the adjusting axis.
    @Test func midAutofocusIsNotSettled() {
        let meta = CameraFrameMetadata(snapshot: snapshot(adjustingFocus: true))
        #expect(meta.focusState == .adjusting)
        #expect(meta.settled == false)
    }

    // 4.1 — all three axes converged → settled.
    @Test func allConvergedIsSettled() {
        let meta = CameraFrameMetadata(snapshot: snapshot())
        #expect(meta.focusState == .converged)
        #expect(meta.wbState == .settled)
        #expect(meta.exposureState == .converged)
        #expect(meta.settled == true)
    }

    // 4.1 — settled is the conjunction: any single unconverged axis → not settled.
    @Test func anyUnconvergedAxisBreaksSettled() {
        #expect(CameraFrameMetadata(snapshot: snapshot(adjustingWB: true)).settled == false)
        #expect(CameraFrameMetadata(snapshot: snapshot(adjustingExposure: true)).settled == false)
        #expect(CameraFrameMetadata(snapshot: snapshot(adjustingFocus: true)).settled == false)
    }

    // 4.1 — pre-snapshot default is fail-safe: unknown everywhere, not settled.
    @Test func defaultMetadataIsUnknownAndNotSettled() {
        let meta = CameraFrameMetadata()
        #expect(meta.focusState == .unknown)
        #expect(meta.wbState == .unknown)
        #expect(meta.exposureState == .unknown)
        #expect(meta.settled == false)
    }

    // 4.2 — grade params appear ONLY in the 3 Hz JSON diagnostics payload.
    @Test func gradeParamsAreInJSONOnly() {
        let processing = ProcessingParameters(
            brightness: 0.25, contrast: -0.5, saturation: 0.1,
            blackR: 0.02, blackG: 0.03, blackB: 0.04, gamma: 1.2)
        let crop = Rect(x: 240, y: 0, width: 1440, height: 1440)
        let json = FrameDiagnostics.json(
            snapshot: snapshot(), processing: processing, crop: crop)

        // Grade params + crop + WB gains present in the JSON.
        for key in [
            "brightness", "contrast", "saturation", "gamma",
            "blackR", "blackG", "blackB",
            "cropX", "cropY", "cropW", "cropH",
            "wbGainR", "wbGainG", "wbGainB",
            "afAdjusting", "wbAdjusting", "aeAdjusting",
        ] {
            #expect(json.contains("\"\(key)\""), "diagnostics JSON missing key \(key)")
        }
        #expect(json.contains("0.25"))  // brightness value carried
        #expect(json.contains("1440"))  // crop dimension carried

        // The typed per-frame metadata carries NONE of the grade params — only
        // the convergence decision fields. (Compile-time: CameraFrameMetadata has
        // no brightness/contrast/etc. members. This assertion documents intent.)
        let meta = CameraFrameMetadata(snapshot: snapshot())
        let mirror = Mirror(reflecting: meta)
        let fieldNames = Set(mirror.children.compactMap { $0.label })
        #expect(fieldNames == ["settled", "focusState", "wbState", "exposureState"])
        for forbidden in ["brightness", "contrast", "saturation", "gamma", "cropRegion"] {
            #expect(!fieldNames.contains(forbidden))
        }
    }

    // The diagnostics builder is deterministic given equal inputs (stable for
    // assertions / diffing).
    @Test func diagnosticsJSONIsDeterministic() {
        let a = FrameDiagnostics.json(
            snapshot: snapshot(), processing: ProcessingParameters(), crop: nil)
        let b = FrameDiagnostics.json(
            snapshot: snapshot(), processing: ProcessingParameters(), crop: nil)
        #expect(a == b)
    }
}
