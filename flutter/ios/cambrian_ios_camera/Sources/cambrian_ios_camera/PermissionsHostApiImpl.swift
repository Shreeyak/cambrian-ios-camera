import CameraKit
import Flutter

extension CambrianIosCameraPlugin: PermissionsHostApi {

    func cameraPermissionStatus(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        // CameraKit exposes these as `nonisolated static` on `extension CameraEngine`
        // (Permissions.swift) — synchronous status, async request.
        let status = CameraKit.CameraEngine.cameraPermissionStatus().toPigeon()
        completion(.success(status))
    }

    func requestCameraPermission(
        completion: @escaping (Result<CameraPermissionStatus, any Error>) -> Void
    ) {
        // Pigeon's reply handler is not `Sendable`; capturing it directly into a
        // `sending` Task closure trips Swift 6's data-race check. It is in fact
        // only ever invoked once, here, so the unchecked capture is safe.
        nonisolated(unsafe) let completion = completion
        Task {
            let status = await CameraKit.CameraEngine.requestCameraPermission().toPigeon()
            completion(.success(status))
        }
    }
}
