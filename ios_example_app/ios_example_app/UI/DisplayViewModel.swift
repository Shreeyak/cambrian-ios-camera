import CameraKit
import CoreMedia
import CoreVideo
import FrameTransport
import Metal
import SwiftUI

/// Display-only view model owning Metal texture mailboxes and the DEBUG overlay.
///
/// frame-delivery-rework: the DEBUG Canny stub (C-ABI `PixelSinkCallbacks` /
/// `registerCallback`) and the `.natural`-lane `FrameSet` sanity overlay were
/// removed with the C-ABI path and the natural delivery lane. This demo is
/// intentionally reduced — the texture forwarders and tracker thumbnail toggle
/// (now on the `.tracker` `Frame` stream) remain.
@Observable @MainActor
final class DisplayViewModel {

    /// Stage 06 — DEBUG overlay payload (frame number, capture time, edge count).
    struct DebugOverlay: Equatable {
        var frameNumber: UInt64
        var captureTimeMs: Int64
        var edgeCount: UInt32?
    }

    // MARK: - Texture mailboxes (read on Metal rendering thread)

    // remove-natural-lane: the streaming natural preview texture was removed from
    // CameraKit. This dev-harness pane now has no natural source (nil → cleared).
    nonisolated var naturalTex: MTLTexture? { nil }
    nonisolated var processedTex: MTLTexture? { engine.currentProcessedTexture() }

    @ObservationIgnored
    let trackerTex = Mailbox<MTLTexture>()

    // MARK: - DEBUG state

    var debugOverlay: DebugOverlay?
    var debugTrackerSubscribed: Bool = false

    @ObservationIgnored private var trackerSubscriberTask: Task<Void, Never>?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Called once from the parent's `start()` after `engine.open()` succeeds.
    func attachAfterOpen() async {
        // DEBUG Canny registration removed with the C-ABI path.
    }

    /// Called before engine close.
    func detachBeforeClose() async {
        trackerSubscriberTask?.cancel()
        trackerSubscriberTask = nil
    }

    // MARK: - DEBUG tracker thumbnail toggle

    func toggleDebugTrackerSubscription() async {
        debugTrackerSubscribed.toggle()
        if debugTrackerSubscribed {
            trackerSubscriberTask?.cancel()
            trackerSubscriberTask = Task { [weak self] in
                guard let self else { return }
                let stream = await self.engine.consumers.subscribe(
                    stream: .tracker, buffering: .keepBuffered(depth: 2))
                // The tracker Frame carries its own PixelHandle; this demo just
                // mirrors the engine's current tracker texture on each delivery.
                while !Task.isCancelled {
                    do {
                        for try await _ in stream {
                            let tex = self.engine.currentTrackerTexture()
                            await MainActor.run { self.trackerTex.store(tex) }
                        }
                        break
                    } catch {
                        break  // stream finished (terminal fault) — stop mirroring.
                    }
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
