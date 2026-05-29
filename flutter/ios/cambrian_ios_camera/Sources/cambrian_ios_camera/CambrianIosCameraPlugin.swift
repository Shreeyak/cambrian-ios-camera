import CameraKit
import Flutter
import UIKit

/// The Flutter plugin entry point.
///
/// Owns one `CameraEngine`, observes UIScene lifecycle natively, and bridges
/// CameraKit ⇄ Pigeon. Per Phase B spec §5, all HostApi protocol method
/// bodies live in extensions in sibling files (`HostApi+CameraEngine.swift`,
/// `HostApi+Permissions.swift`, `TextureBridge.swift`, `StreamForwarding.swift`).
public final class CambrianIosCameraPlugin: NSObject {

    // MARK: - Plugin registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CambrianIosCameraPlugin(registrar: registrar)
        CameraEngineHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        PermissionsHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        // Register the EventChannel stream handlers NOW, before any Dart code
        // subscribes. The Dart facade subscribes in its constructor (before
        // open()); if the native handler isn't registered yet, Flutter drops the
        // "listen" and onListen never fires — the sink stays nil and no events
        // ever reach Dart (symptom: preview never leaves the "No signal" state).
        instance.registerStreamHandlers(messenger: registrar.messenger())
        // App lifecycle is observed natively and forwarded to CameraEngine — Dart
        // forwards nothing (a method-channel round-trip would add latency that can
        // let a backgrounding outrun a recording's finalize). The scene-phase
        // signal arrives via FlutterSceneLifeCycleDelegate, which the host's
        // FlutterSceneDelegate fans out only to delegates registered with
        // addSceneDelegate — NOT addApplicationDelegate (which is app-delegate
        // callbacks). addApplicationDelegate is kept solely to retain the plugin
        // instance for the engine's lifetime.
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }

    // MARK: - Stored state

    let registrar: FlutterPluginRegistrar
    var engine: (any CameraEngineProtocol)?
    var textures: [Int64: (EnginePixelBufferTexture, Task<Void, Never>)] = [:]
    var streamTasks: [Task<Void, Never>] = []

    // The five EventChannel forwarders. Created and registered once at
    // `register(with:)` (before any Dart subscription) so that the Dart facade's
    // constructor-time `.listen(...)` finds a live native handler and `onListen`
    // fires — capturing the `PigeonEventSink`. The engine-iterating Tasks that
    // pump these sinks are spawned later, at `open()` (see startStreamForwarders).
    let stateForwarder = StateForwarder()
    let errorForwarder = ErrorForwarder()
    let streamConfigForwarder = StreamConfigForwarder()
    let frameResultForwarder = FrameResultForwarder()
    let recordingStateForwarder = RecordingStateForwarder()

    /// Constructor injection point used by `RunnerTests/`.
    ///
    /// Production code uses `register(with:)`.
    init(registrar: FlutterPluginRegistrar, engine: (any CameraEngineProtocol)? = nil) {
        self.registrar = registrar
        self.engine = engine
        super.init()
    }
}

// MARK: - FlutterPlugin + FlutterSceneLifeCycleDelegate

extension CambrianIosCameraPlugin: FlutterPlugin, FlutterSceneLifeCycleDelegate {

    public func sceneDidBecomeActive(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.active) }
    }

    public func sceneWillResignActive(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.inactive) }
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        let engine = self.engine
        Task { await engine?.setLifecyclePhase(.background) }
    }
    // sceneWillEnterForeground intentionally not implemented — sceneDidBecomeActive
    // carries the .active transition (see CameraKit/README.md).
}

// MARK: - Helpers used by other extensions

extension CambrianIosCameraPlugin {

    /// Returns the current scene's `AppLifecyclePhase`, or `.background` if no
    /// scene is connected.
    ///
    /// Used at engine construction time to seed `initialPhase`. MainActor-hopped
    /// because `UIApplication.shared.connectedScenes` is MainActor-isolated.
    @MainActor
    static func currentScenePhase() -> AppLifecyclePhase {
        for scene in UIApplication.shared.connectedScenes {
            switch scene.activationState {
            case .foregroundActive: return .active
            case .foregroundInactive: return .inactive
            case .background: return .background
            case .unattached: continue
            @unknown default: continue
            }
        }
        return .background
    }
}
