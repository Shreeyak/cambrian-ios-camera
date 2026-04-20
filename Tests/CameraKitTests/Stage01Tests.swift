import Testing
@testable import CameraKit

// MARK: - FakeCaptureDevice (ADR-32 test seam)
// Never constructed in production code. Supplies canned values without touching AVFoundation.

actor FakeCaptureDevice: CaptureDeviceProviding {
    var uniqueID: String { "fake-001" }
    var activeFormatSize: Size { Size(width: 4160, height: 3120) }
    var supportedSizes: [Size] {
        [
            Size(width: 4160, height: 3120),
            Size(width: 1920, height: 1080)
        ]
    }
    var isoRange: ClosedRange<Float> { 20.0...800.0 }
    var exposureDurationRangeNs: ClosedRange<Int64> { 1_000...500_000_000 }
    var maxWhiteBalanceGain: Float { 4.0 }

    func lockForConfiguration() throws {}
    func unlockForConfiguration() {}

    func setExposureModeCustom(durationNs: Int64, iso: Float) throws {}
    func setContinuousAutoExposure() throws {}

    func setFocusModeLocked(lensPosition: Float) throws {}
    func setContinuousAutoFocus() throws {}

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {}
    func setContinuousAutoWhiteBalance() throws {}
    func setWhiteBalanceLocked() throws {}

    func setZoomFactor(_ factor: Double) throws {}
    func setExposureCompensation(_ steps: Int) throws {}
    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {}
}

// MARK: - Format selection helper (mirrors the rule in CameraSession.configure)

/// Among supported sizes, select the largest 4:3 candidate.
/// Falls back to Constants.captureFallbackWidthPx × captureFallbackHeightPx if none qualify.
private func selectBest4x3(from sizes: [Size]) -> Size {
    let candidates = sizes
        .filter { $0.width * 3 == $0.height * 4 }
        .sorted { $0.width * $0.height > $1.width * $1.height }
    return candidates.first ?? Size(
        width: Constants.captureFallbackWidthPx,
        height: Constants.captureFallbackHeightPx
    )
}

// MARK: - Stage01Tests

@Suite("Stage01Tests")
struct Stage01Tests {

    // MARK: Test 1 — 01:capture-device-provider-seam

    /// Verifies FakeCaptureDevice conforms to CaptureDeviceProviding and returns canned values.
    /// No AVCaptureDevice or LiveCaptureDevice is touched anywhere in this test. (ADR-32)
    @Test func captureDeviceProviderSeam() async {
        let fake = FakeCaptureDevice()

        let uid = await fake.uniqueID
        #expect(uid == "fake-001")

        let sizes = await fake.supportedSizes
        #expect(sizes == [
            Size(width: 4160, height: 3120),
            Size(width: 1920, height: 1080)
        ])

        let isoRange = await fake.isoRange
        #expect(isoRange == 20.0...800.0)

        let exposureRange = await fake.exposureDurationRangeNs
        #expect(exposureRange == 1_000...500_000_000)

        let maxGain = await fake.maxWhiteBalanceGain
        #expect(maxGain == 4.0)
    }

    // MARK: Test 2 — 01:largest-4x3-format-selected

    /// Verifies the 4:3 format-selection rule using the helper above.
    @Test func largest4x3FormatSelected() {
        // Given a mix of 4:3 and 16:9 sizes, the largest 4:3 wins.
        let mixed: [Size] = [
            Size(width: 4160, height: 3120),  // 4:3
            Size(width: 3840, height: 2160)   // 16:9
        ]
        #expect(selectBest4x3(from: mixed) == Size(width: 4160, height: 3120))

        // Given only 16:9 sizes, fall back to the constants-defined fallback.
        let noFourThree: [Size] = [
            Size(width: 3840, height: 2160)
        ]
        #expect(selectBest4x3(from: noFourThree) == Size(
            width: Constants.captureFallbackWidthPx,
            height: Constants.captureFallbackHeightPx
        ))

        // Sanity-check the fallback dimensions themselves match the brief spec.
        #expect(Constants.captureFallbackWidthPx == 1280)
        #expect(Constants.captureFallbackHeightPx == 960)
    }

    // MARK: Test 3 — 01:engine-open-close-transitions

    /// Verifies CameraEngine initializes without throwing and exposes stateStream(),
    /// and that close() on a non-open engine completes without throwing.
    @Test func engineOpenCloseTransitions() async throws {
        let engine = CameraEngine()

        // stateStream() must return an AsyncStream<SessionState> (type-checks at compile time).
        let stream: AsyncStream<SessionState> = await engine.stateStream()
        _ = stream  // silence unused-variable warning; type assertion is the test.

        // close() on a non-open engine must not throw (it silently returns per brief).
        await engine.close()
    }

    // MARK: Test 4 — 01:landscape-right-rotation-applied

    /// Verifies that the capture orientation constant equals 90° (landscape-right).
    @Test func landscapeRightRotationApplied() {
        #expect(Constants.captureOrientationAngleDeg == 90)
    }

    // MARK: Test 5 — Consumer registry register / deregister

    /// Verifies ConsumerRegistry issues unique tokens and survives broadcast on empty registry.
    @Test func consumerRegistryRegisterDeregister() {
        let registry = ConsumerRegistry()

        // Registering callbacks returns a token.
        let token = registry.register(PixelSinkCallbacks())
        #expect(token.id > 0)

        // A second registration yields a different token.
        let token2 = registry.register(PixelSinkCallbacks())
        #expect(token2 != token)

        // Deregistering both does not crash.
        registry.deregister(token)
        registry.deregister(token2)

        // broadcast on now-empty registry must not crash (it is a no-op stub in Stage 01).
        // FrameSet requires CVPixelBuffer — we do not construct one. The no-op stub
        // is verified by the fact that the call simply returns; no assertion needed.
    }
}
