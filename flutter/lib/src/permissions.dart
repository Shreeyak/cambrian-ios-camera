import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

typedef CameraPermissionStatus = g.CameraPermissionStatus;

/// Static permissions API — no engine instance required.
///
/// Use before opening the engine; if `cameraPermissionStatus()` returns
/// `.notDetermined`, call `requestCameraPermission()` to surface the iOS system
/// prompt.
class Permissions {
  Permissions._();

  static g.PermissionsHostApi _api = g.PermissionsHostApi();

  static Future<CameraPermissionStatus> cameraPermissionStatus() =>
      _api.cameraPermissionStatus();

  static Future<CameraPermissionStatus> requestCameraPermission() =>
      _api.requestCameraPermission();
}

/// Internal test seam — accessed only via `lib/testing.dart`'s
/// `PermissionsTesting.setHostApi(...)`.
void permissionsSetHostApiForTest(g.PermissionsHostApi api) {
  Permissions._api = api;
}

/// Internal test seam — rebuilds the default production HostApi.
g.PermissionsHostApi permissionsDefaultHostApiForTest() =>
    g.PermissionsHostApi();
