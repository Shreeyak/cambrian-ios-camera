import CameraKit
import Flutter
import UIKit
import XCTest

@testable import cambrian_ios_camera

/// Each UIScene lifecycle callback must forward exactly one
/// `engine.setLifecyclePhase(_:)` with the matching `AppLifecyclePhase`.
/// The callbacks ignore the scene argument, so the host app's live connected
/// scene is reused (UIScene has no public initializer). The callbacks spawn a
/// detached Task, so each test sleeps briefly before reading the actor history.
@MainActor
final class SceneLifecycleTests: XCTestCase {

    private func anyScene() throws -> UIScene {
        try XCTUnwrap(
            UIApplication.shared.connectedScenes.first,
            "app-hosted test expected a connected scene")
    }

    func test_sceneDidBecomeActive_setsPhaseActive() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        plugin.sceneDidBecomeActive(try anyScene())
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.active])
    }

    func test_sceneWillResignActive_setsPhaseInactive() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        plugin.sceneWillResignActive(try anyScene())
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.inactive])
    }

    func test_sceneDidEnterBackground_setsPhaseBackground() async throws {
        let mock = MockCameraEngine()
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: mock)
        plugin.sceneDidEnterBackground(try anyScene())
        try await Task.sleep(for: .milliseconds(50))
        let history = await mock.phaseHistory
        XCTAssertEqual(history, [.background])
    }
}
