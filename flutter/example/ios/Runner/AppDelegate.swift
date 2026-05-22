import CameraKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Mirror CameraKit's os.Logger output to <Documents>/camerakit.log so the
    // ipad-logs skill can pull it off-device (CLAUDE.md §8). Must precede plugin
    // registration so the forwarder onListen diagnostics are captured.
    CameraKitLog.isEnabled = true
    CameraKitLog.enableFileLogging()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
