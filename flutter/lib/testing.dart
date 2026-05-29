import 'dart:async';

import 'src/camera_engine.dart'
    show
        CameraEngine,
        cameraEngineMakeForTest,
        cameraEngineStateSourceForTest,
        cameraEngineErrorSourceForTest,
        cameraEngineCfgSourceForTest,
        cameraEngineFrameSourceForTest,
        cameraEngineRecordingSourceForTest;
import 'src/permissions.dart'
    show permissionsSetHostApiForTest, permissionsDefaultHostApiForTest;
import 'src/pigeon/cambrian_ios_camera_api.g.dart' as g;

/// Test seam for `Permissions`. Production code never imports `lib/testing.dart`.
abstract final class PermissionsTesting {
  PermissionsTesting._();
  static void setHostApi(g.PermissionsHostApi api) =>
      permissionsSetHostApiForTest(api);
  static void reset() =>
      permissionsSetHostApiForTest(permissionsDefaultHostApiForTest());
}

/// Test seam for `CameraEngine`.
///
/// Production code never imports `lib/testing.dart`. The factory builds a
/// CameraEngine wired against `api` instead of the default
/// `CameraEngineHostApi()`, and does not wire production EventChannel streams.
abstract final class CameraEngineTesting {
  CameraEngineTesting._();
  static CameraEngine create({required g.CameraEngineHostApi api}) =>
      cameraEngineMakeForTest(api: api);
}

/// Test seam exposing the engine's per-stream broadcast controllers so unit
/// tests can hand-pump events without a real EventChannel.
abstract final class CameraEngineStreamsTesting {
  CameraEngineStreamsTesting._();
  static StreamController<g.SessionState> stateSource(CameraEngine e) =>
      cameraEngineStateSourceForTest(e);
  static StreamController<g.CameraError> errorSource(CameraEngine e) =>
      cameraEngineErrorSourceForTest(e);
  static StreamController<g.StreamConfiguration> cfgSource(CameraEngine e) =>
      cameraEngineCfgSourceForTest(e);
  static StreamController<g.FrameResult> frameSource(CameraEngine e) =>
      cameraEngineFrameSourceForTest(e);
  static StreamController<g.RecordingStateValue> recordingSource(
          CameraEngine e) =>
      cameraEngineRecordingSourceForTest(e);
}
