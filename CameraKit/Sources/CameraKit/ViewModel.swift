import SwiftUI
import Metal

/// Main-actor view model for CameraView.
///
/// ADR-21: UI state is owned by @Observable @MainActor ViewModel; actor-isolated
/// engine state flows in via an async for-await loop on stateStream().
@Observable @MainActor
final class ViewModel {

    // MARK: - Observable state

    var sessionState: SessionState = .closed
    var capabilities: SessionCapabilities?
    var error: EngineError?

    // MARK: - Texture handoff

    /// Set once after open() succeeds. Read by MTKViewCoordinator.draw(in:) on the
    /// Metal thread. @ObservationIgnored skips @Observable's tracking rewrite so the
    /// property is a plain stored field; nonisolated(unsafe) allows cross-isolation reads
    /// (naturalTex is written exactly once per session, before the coordinator calls draw).
    @ObservationIgnored
    nonisolated(unsafe) var naturalTex: MTLTexture?

    // MARK: - Engine

    let engine: CameraEngine

    // MARK: - Init

    init() {
        engine = CameraEngine()
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            let caps = try await engine.open()
            capabilities = caps
            // Grab naturalTex once after open — it's stable for the session lifetime.
            naturalTex = engine.currentTexture()
        } catch let e as EngineError {
            error = e
            sessionState = .error
        } catch {
            sessionState = .error
        }

        // Observe state stream (ADR-22).
        for await state in await engine.stateStream() {
            sessionState = state
        }
    }

    func stop() async {
        await engine.close()
    }
}
