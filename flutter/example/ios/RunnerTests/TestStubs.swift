import Flutter
import UIKit

// Shared no-op Flutter stubs for the adapter unit tests. Flutter 3.22+ split
// the registrar into FlutterBaseRegistrar + FlutterPluginRegistrar and added
// `addSceneDelegate` and the gesture-policy `registerViewFactory` overload, so
// every required method must be present or the conformance fails to compile.

final class StubBinaryMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
    func setMessageHandlerOnChannel(
        _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?
    ) -> FlutterBinaryMessengerConnection { 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

/// No-op texture registry that hands out monotonic ids.
final class StubTextureRegistry: NSObject, FlutterTextureRegistry {
    func register(_ texture: any FlutterTexture) -> Int64 { 1 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) {}
}

/// Records register/unregister calls so the texture-map tests can assert on them.
final class RecordingTextureRegistry: NSObject, FlutterTextureRegistry {
    var nextId: Int64 = 100
    var registered: [Int64: any FlutterTexture] = [:]
    var unregistered: [Int64] = []

    func register(_ texture: any FlutterTexture) -> Int64 {
        let id = nextId
        nextId += 1
        registered[id] = texture
        return id
    }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) {
        unregistered.append(textureId)
        registered.removeValue(forKey: textureId)
    }
}

final class StubRegistrar: NSObject, FlutterPluginRegistrar {
    private let _messenger: any FlutterBinaryMessenger
    let textureRegistry: any FlutterTextureRegistry

    init(
        messenger: any FlutterBinaryMessenger = StubBinaryMessenger(),
        textures: any FlutterTextureRegistry = StubTextureRegistry()
    ) {
        self._messenger = messenger
        self.textureRegistry = textures
    }

    var viewController: UIViewController? { nil }
    func messenger() -> any FlutterBinaryMessenger { _messenger }
    func textures() -> any FlutterTextureRegistry { textureRegistry }
    func publish(_ value: NSObject) {}
    func register(_ factory: any FlutterPlatformViewFactory, withId factoryId: String) {}
    func register(
        _ factory: any FlutterPlatformViewFactory,
        withId factoryId: String,
        gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicy
    ) {}
    func addMethodCallDelegate(_ delegate: any FlutterPlugin, channel: FlutterMethodChannel) {}
    func addApplicationDelegate(_ delegate: any FlutterPlugin) {}
    func addSceneDelegate(_ delegate: any FlutterSceneLifeCycleDelegate) {}
    func lookupKey(forAsset asset: String) -> String { asset }
    func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
}
