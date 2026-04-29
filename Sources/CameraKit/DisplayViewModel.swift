import CameraKitInterop
import CoreMedia
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

    /// Set once after `engine.open()` succeeds; stable for session lifetime.
    ///
    /// `@ObservationIgnored` skips `@Observable`'s tracking rewrite so the property
    /// is a plain stored field; `nonisolated(unsafe)` allows cross-isolation reads
    /// from `MTKViewCoordinator.draw(in:)`.
    @ObservationIgnored
    nonisolated(unsafe) var naturalTex: MTLTexture?

    @ObservationIgnored
    nonisolated(unsafe) var processedTex: MTLTexture?

    @ObservationIgnored
    nonisolated(unsafe) var trackerTex: MTLTexture?

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

    /// Grab session-stable textures and register the DEBUG Canny stub.
    ///
    /// Called once from the parent's `start()` after `engine.open()` succeeds.
    func attachAfterOpen() async {
        naturalTex = engine.currentTexture()
        processedTex = engine.currentProcessedTexture()
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
            for await fs in await self.engine.consumers.subscribe(stream: .natural) {
                guard fs.frameNumber % 10 == 0 else { continue }
                let processed = self.cannyStub.processedCount
                let edgeCount: UInt32? =
                    processed > 0 ? self.cannyStub.edgeCount(at: Int((processed - 1) % 64)) : nil
                let overlay = DebugOverlay(
                    frameNumber: fs.frameNumber,
                    captureTimeMs: Int64(CMTimeGetSeconds(fs.captureTime) * 1000),
                    edgeCount: edgeCount)
                await MainActor.run { self.debugOverlay = overlay }
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
                    await MainActor.run { self.trackerTex = tex }
                }
                await MainActor.run { self.trackerTex = nil }
            }
        } else {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = nil
            trackerTex = nil
        }
    }
}
