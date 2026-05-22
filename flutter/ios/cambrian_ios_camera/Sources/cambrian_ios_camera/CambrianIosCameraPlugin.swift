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
        registrar.addApplicationDelegate(instance)
    }

    // MARK: - Stored state

    let registrar: FlutterPluginRegistrar
    var engine: (any CameraEngineProtocol)?
    var textures: [Int64: (FlutterTexture, Task<Void, Never>)] = [:]
    var streamTasks: [Task<Void, Never>] = []

    /// Constructor injection point used by `RunnerTests/`.
    ///
    /// Production code uses `register(with:)`.
    init(registrar: FlutterPluginRegistrar, engine: (any CameraEngineProtocol)? = nil) {
        self.registrar = registrar
        self.engine = engine
        super.init()
    }
}

// MARK: - FlutterPlugin + UIWindowSceneDelegate

extension CambrianIosCameraPlugin: FlutterPlugin, UIWindowSceneDelegate {

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
