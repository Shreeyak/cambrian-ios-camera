import Metal
import OSLog
import SwiftUI

private let scenePhaseLog = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")

/// Main-actor view model for CameraView.
///
/// ADR-21: UI state is owned by @Observable @MainActor ViewModel; actor-isolated
/// engine state flows in via an async for-await loop on stateStream().
/// ADR-09 / D-06: scenePhase transitions are handled by handleScenePhase(_:), which
/// drives the GPU submission gate and session lifecycle. Strict policy: .inactive
/// always gates regardless of UIApplication.applicationState.
@Observable @MainActor
final class ViewModel {

    // MARK: - Observable state

    var sessionState: SessionState = .closed
    var capabilities: SessionCapabilities?
    var error: EngineError?

    // MARK: - Texture handoff

    /// Set once after open() succeeds.
    ///
    /// Read by MTKViewCoordinator.draw(in:) on the
    /// Metal thread. @ObservationIgnored skips @Observable's tracking rewrite so the
    /// property is a plain stored field; nonisolated(unsafe) allows cross-isolation reads
    /// (naturalTex is written exactly once per session, before the coordinator calls draw).
    @ObservationIgnored
    nonisolated(unsafe) var naturalTex: MTLTexture?

    // MARK: - Engine

    let engine: CameraEngine

    // MARK: - ScenePhase tracking (ADR-09, D-06, 08-ui.md §scenePhase wiring)

    /// Tracks the previous scene phase so handleScenePhase can distinguish
    /// .active-from-.inactive (gate re-open only) from .active-from-.background
    /// (backgroundResume + gate re-open).
    private var previousPhase: ScenePhase = .active

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

    // MARK: - ScenePhase handler (08-ui.md §scenePhase wiring, 02-concurrency.md §Sequence A)

    /// Called by CameraView via .task(id: scenePhase) on every scene phase change.
    ///
    /// Phase mapping (D-06 strict policy):
    ///   .inactive   → close gate; drain last submitted frame.
    ///   .background → backgroundSuspend() (gate-close + drain + session stop).
    ///   .active     → re-open gate; if returning from .background, backgroundResume() first.
    func handleScenePhase(_ phase: ScenePhase) async {
        scenePhaseLog.info("scenePhase: \(String(describing: self.previousPhase)) → \(String(describing: phase))")
        switch phase {
        case .inactive:
            await engine.setGate(false)
            await engine.drainSubmittedFrame()
            scenePhaseLog.info("scenePhase inactive: gate closed, drain complete")

        case .background:
            await engine.backgroundSuspend()
            scenePhaseLog.info("scenePhase background: backgroundSuspend complete")

        case .active:
            if previousPhase == .background {
                await engine.backgroundResume()
            }
            await engine.setGate(true)
            scenePhaseLog.info("scenePhase active: gate open (prevPhase=\(String(describing: self.previousPhase)))")

        @unknown default:
            break
        }
        previousPhase = phase
    }
}
