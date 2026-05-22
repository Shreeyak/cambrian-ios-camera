import Flutter
import UIKit

/// Host scene delegate.
///
/// `FlutterSceneDelegate` is the base that fans `UIScene` lifecycle out to
/// plugins registered via `addSceneDelegate` (their `FlutterSceneLifeCycleDelegate`
/// methods) — that wiring is automatic and needs no override. The ONLY reason
/// this is a subclass is the XCTest guard below.
class SceneDelegate: FlutterSceneDelegate {

    // App-hosted RunnerTests (TEST_HOST = Runner.app) launch this app under
    // `xcodebuild test` with NO flutter tooling attached. Letting
    // FlutterSceneDelegate run its normal scene setup then initializes the debug
    // Flutter engine, which crashes the host before the test runner can connect
    // ("Early unexpected exit … test runner crashed before establishing
    // connection").
    //
    // Verified 2026-05-22 by experiment:
    //   • Debug, no guard      → host crashes, 0/9 tests bootstrap (that error).
    //   • Debug, with guard    → 9/9 pass.
    //   • Release, no guard    → `@testable import cambrian_ios_camera` fails
    //     ("module not compiled for testing"): ENABLE_TESTABILITY is off in
    //     Release and the plugin is an SPM module with no testability hook.
    // So the tests MUST run in Debug (for @testable), and Debug MUST have this
    // guard. There is no Release escape hatch.
    //
    // The adapter unit tests don't need a live engine (stub registrars + a mock
    // CameraEngine), so under XCTest we present a bare window and skip Flutter's
    // scene setup. `XCTestConfigurationFilePath` is set only under XCTest, so
    // `flutter run` and normal launches fall through to `super` untouched.
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            guard let windowScene = scene as? UIWindowScene else { return }
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            self.window = window
            return
        }
        super.scene(scene, willConnectTo: session, options: connectionOptions)
    }
}
