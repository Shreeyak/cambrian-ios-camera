import CameraKit
import Flutter

extension CambrianIosCameraPlugin: PermissionsHostApi {

    public func cameraPermissionStatus(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        // CameraKit exposes these as `nonisolated static` on `extension CameraEngine`
        // (Permissions.swift) — synchronous status, async request.
        let status = CameraKit.CameraEngine.cameraPermissionStatus().toPigeon()
        completion(.success(status))
    }

    public func requestCameraPermission(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        Task {
            let status = await CameraKit.CameraEngine.requestCameraPermission().toPigeon()
            completion(.success(status))
        }
    }
}
