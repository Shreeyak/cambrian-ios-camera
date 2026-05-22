import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

    // When the app is launched as the host for app-hosted XCTest
    // (RunnerTests), a debug-mode FlutterEngine cannot JIT-init under plain
    // `xcodebuild test` (no Flutter tooling attached) and the process crashes
    // on the `ptrace(PT_TRACE_ME)` check before tests bootstrap. The adapter
    // unit tests don't need a real engine — they use stub registrars and a
    // mock — so during tests we present a bare window and skip Flutter's scene
    // setup entirely. `XCTestConfigurationFilePath` is set only under XCTest, so
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
