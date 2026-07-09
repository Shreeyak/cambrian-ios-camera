import Testing

@testable import CameraKit

/// Device coverage for the focus-await-settle change (v2.2.0).
///
/// `updateSettings` with a manual focus distance now `await`s the AVFoundation
/// focus completion handler (with a 1 s timeout fallback in `focusApplyAwait`)
/// before returning, so the call resolves only once the lens has physically
/// settled. Every other `setFocusModeLocked` caller in the test suite is a mock
/// (`Stage03Tests`) or a synchronous stub (`Stage01Tests`), so the real
/// completion-handler path only runs here, on hardware.
///
/// Device-only; serialized to avoid camera contention with the other device
/// suites.
@Suite("FocusSettleDeviceTests", .serialized)
struct FocusSettleDeviceTests {

    /// A manual-focus `updateSettings` returns without throwing and resolves via
    /// the real focus completion handler — i.e. **well under** the 1 s timeout
    /// fallback.
    ///
    /// The read-back snapshot only echoes the requested value, so it can't prove
    /// the lens settled (tautological). Timing is the non-tautological signal:
    /// if the completion handler never fired, the awaited call would only return
    /// at the ~1 s deadline. A sub-second return on a full near→far rack proves
    /// the settle path works on device. A real lens rack is typically
    /// <600 ms, so 950 ms cleanly separates "completion fired" from the 1000 ms
    /// timeout fallback.
    @Test func manualFocusAwaitsLensSettleUnderTimeout() async throws {
        let engine = CameraEngine(initialPhase: .active)
        _ = try await engine.open(configuration: OpenConfiguration())

        // Seed the lens at the near end so the timed change is a genuine rack.
        var near = CameraSettings()
        near.focusMode = .manual
        near.focusDistance = 0.0
        try await engine.updateSettings(near)

        // Time a manual focus change to the far end. The awaited call must
        // resolve via the completion handler, not the 1 s timeout fallback.
        var far = CameraSettings()
        far.focusMode = .manual
        far.focusDistance = 1.0
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.updateSettings(far)
        let elapsed = clock.now - start

        #expect(elapsed < .milliseconds(950))

        await engine.close()
    }
}
