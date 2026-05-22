import Flutter
import XCTest

@testable import cambrian_ios_camera

/// Pre-`open()` HostApi calls fail with `PigeonError(code: "notOpen")`.
/// `CameraSettings` / `PhotosDestination` here are the Pigeon types (CameraKit
/// is not imported). The adapter throws `PigeonError` (not Flutter's
/// `FlutterError`, which does not conform to Swift's `Error`); Pigeon's
/// `wrapError` maps both to the same Dart `PlatformException`.
final class NotOpenGuardTests: XCTestCase {

    func test_updateSettings_before_open_returns_notOpen() {
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: nil)
        let exp = expectation(description: "completion")
        plugin.updateSettings(settings: CameraSettings()) { result in
            if case .failure(let err) = result, let pe = err as? PigeonError {
                XCTAssertEqual(pe.code, "notOpen")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }

    func test_captureImage_before_open_returns_notOpen() {
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: nil)
        let exp = expectation(description: "completion")
        plugin.captureImage(outputPath: nil, photosDestination: .none) { result in
            if case .failure(let err) = result, let pe = err as? PigeonError {
                XCTAssertEqual(pe.code, "notOpen")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }

    // currentState() does NOT guard — it reports the actual state, which is
    // `.closed` before open() (no engine yet). Fresh read, never a failure.
    func test_currentState_before_open_returns_closed() {
        let plugin = CambrianIosCameraPlugin(registrar: StubRegistrar(), engine: nil)
        let exp = expectation(description: "completion")
        plugin.currentState { result in
            if case .success(let state) = result {
                XCTAssertEqual(state, .closed)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
}
