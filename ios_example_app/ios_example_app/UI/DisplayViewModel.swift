import CameraKit
import CoreMedia
import CoreVideo
import Metal
import SwiftUI

/// Display-only view model owning Metal texture mailboxes and the DEBUG overlay.
///
/// Stage 11 split-out from the monolithic `ViewModel` (ADR-21 pattern, decomposed):
/// preview-render texture handoff is the single responsibility here. The MTKView
/// coordinator reads `naturalTex` / `processedTex` on the Metal rendering thread
/// via `nonisolated(unsafe)` mailboxes; the parent never touches the texture path.
///
/// `attachAfterOpen()` is called once after `engine.open()` succeeds; it grabs
/// stable session-lifetime texture references and registers the DEBUG Canny stub
/// on the tracker stream. `detachBeforeClose()` is called before `engine.close()`.
@Observable @MainActor
final class DisplayViewModel {

    /// Stage 06 — DEBUG overlay payload (frame number, capture time, edge count).
    struct DebugOverlay: Equatable {
        var frameNumber: UInt64
        var captureTimeMs: Int64
        /// Stage 08 HITL — most-recent Canny edge pixel count from tracker stream.
        var edgeCount: UInt32?
    }

    // MARK: - Texture mailboxes (read on Metal rendering thread, never enter SwiftUI tracking)

    /// Live forwarders to the engine's pipeline mailboxes.
    ///
    /// `nonisolated` so `MTKViewCoordinator.draw(in:)` can read them off the
    /// MainActor without an actor hop. Each call returns the *current* value
    /// of the engine's `.bgra8Unorm` natural/processed lane textures — never a
    /// captured pointer (Bug 4: pool rotation strands cached pointers).
    nonisolated var naturalTex: MTLTexture? { engine.currentTexture() }
    nonisolated var processedTex: MTLTexture? { engine.currentProcessedTexture() }

    /// Tracker texture mailbox.
    ///
    /// Single writer (engine delivery via the tracker subscription task on
    /// MainActor), reader from the SwiftUI `MTKView` representable. See
    /// `Mailbox<T>` (declared in CameraKit).
    @ObservationIgnored
    let trackerTex = Mailbox<MTLTexture>()

    // MARK: - DEBUG state (auto-stripped in release)

    var debugOverlay: DebugOverlay?
    var debugTrackerSubscribed: Bool = false

    @ObservationIgnored private var naturalSubscriberTask: Task<Void, Never>?
    @ObservationIgnored private var trackerSubscriberTask: Task<Void, Never>?
    @ObservationIgnored private let cannyStub: CppCannyStub = CppCannyStub()
    @ObservationIgnored private var cannyToken: ConsumerToken?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Register the DEBUG Canny stub on the tracker stream.
    ///
    /// Called once from the parent's `start()` after `engine.open()` succeeds.
    /// Bug 4: `naturalTex`/`processedTex` are now live computed forwarders; no
    /// session-time capture is needed (or correct).
    func attachAfterOpen() async {
        #if DEBUG
        let cbs = PixelSinkCallbacks(
            onFrame: cannyStub.onFrameCallback(),
            onOverwrite: { _, _ in },
            onError: nil,
            context: cannyStub.nativeContext)
        cannyToken = try? await engine.consumers.registerCallback(stream: .tracker, callbacks: cbs)
        startDebugOverlay()
        #endif
    }

    /// Cancel subscription tasks and unregister the Canny stub before engine close.
    func detachBeforeClose() async {
        naturalSubscriberTask?.cancel()
        naturalSubscriberTask = nil
        trackerSubscriberTask?.cancel()
        trackerSubscriberTask = nil
        #if DEBUG
        if let t = cannyToken {
            await engine.consumers.unregister(token: t)
            cannyToken = nil
        }
        #endif
    }

    // MARK: - DEBUG overlay (every 10th frame to avoid 30 Hz SwiftUI re-renders)

    #if DEBUG
    private func startDebugOverlay() {
        naturalSubscriberTask?.cancel()
        naturalSubscriberTask = Task { [weak self] in
            guard let self else { return }
            var sanityHealthyLogged = false
            for await fs in await self.engine.consumers.subscribe(stream: .natural) {
                // ~1 Hz delivered-frame sanity check on the natural lane.
                if fs.frameNumber % 30 == 0 {
                    sanityHealthyLogged = checkNaturalFrameSanity(
                        fs.natural, frame: fs.frameNumber, healthyLogged: sanityHealthyLogged)
                }
                guard fs.frameNumber % 10 == 0 else { continue }
                let processed = self.cannyStub.processedCount
                let edgeCount: UInt32? =
                    processed > 0 ? self.cannyStub.edgeCount(at: Int((processed - 1) % 64)) : nil
                let overlay = DebugOverlay(
                    frameNumber: fs.frameNumber,
                    captureTimeMs: Int64(CMTimeGetSeconds(fs.captureTime) * 1000),
                    edgeCount: edgeCount)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.debugOverlay = overlay
                }
            }
        }
    }
    #endif

    // MARK: - DEBUG tracker thumbnail toggle

    func toggleDebugTrackerSubscription() async {
        debugTrackerSubscribed.toggle()
        if debugTrackerSubscribed {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = Task { [weak self] in
                guard let self else { return }
                for await _ in await self.engine.consumers.subscribe(stream: .tracker) {
                    let tex = self.engine.currentTrackerTexture()
                    await MainActor.run { self.trackerTex.store(tex) }
                }
                await MainActor.run { self.trackerTex.store(nil) }
            }
        } else {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = nil
            trackerTex.store(nil)
        }
    }
}

#if DEBUG
/// DEBUG-only delivered-frame sanity check on the natural BGRA8 lane.
///
/// Samples the center pixel and warns if it's degenerate — alpha ≠ 255 or an
/// all-zero pixel — which would signal lane-buffer corruption in the BGRA8
/// delivery path. Logs one positive "healthy" line the first time it sees a
/// good frame (returns `true` so the caller suppresses further positives), then
/// stays quiet unless something goes wrong. Runs off the delivery hot path
/// (the DEBUG natural subscription, ~1 Hz) and writes to `camerakit.log`.
///
/// This deliberately does NOT try to detect on-screen "green frames": those are
/// an uninitialized-drawable artifact, not lane-buffer content —
/// the lane buffer is always fully written by Pass-7, so sampling it can't see
/// them. Detecting that needs a screen capture, which iOS 26.4 doesn't provide.
private func checkNaturalFrameSanity(
    _ buffer: CVPixelBuffer, frame: UInt64, healthyLogged: Bool
) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
        let base = CVPixelBufferGetBaseAddress(buffer)
    else { return healthyLogged }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let offset = (height / 2) * bytesPerRow + (width / 2) * 4
    let px = base.assumingMemoryBound(to: UInt8.self)
    let b = px[offset], g = px[offset + 1], r = px[offset + 2], a = px[offset + 3]

    if a != 255 || (b == 0 && g == 0 && r == 0) {
        CameraKitLog.warning(
            .consumers,
            "[sanity] degenerate natural frame=\(frame) BGRA=[\(b),\(g),\(r),\(a)]")
        return healthyLogged
    }
    if !healthyLogged {
        CameraKitLog.notice(
            .consumers,
            "[sanity] natural delivery healthy frame=\(frame) BGRA=[\(b),\(g),\(r),\(a)]")
        return true
    }
    return healthyLogged
}
#endif
