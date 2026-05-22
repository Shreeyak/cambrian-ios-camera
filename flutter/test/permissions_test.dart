import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockPermissionsHostApi api;
  setUp(() {
    api = MockPermissionsHostApi();
    PermissionsTesting.setHostApi(api);
  });
  tearDown(PermissionsTesting.reset);

  group('Permissions.cameraPermissionStatus()', () {
    for (final s in g.CameraPermissionStatus.values) {
      test('returns $s', () async {
        when(api.cameraPermissionStatus()).thenAnswer((_) async => s);
        expect(await Permissions.cameraPermissionStatus(), s);
      });
    }
  });

  group('Permissions.requestCameraPermission()', () {
    for (final s in g.CameraPermissionStatus.values) {
      test('returns $s', () async {
        when(api.requestCameraPermission()).thenAnswer((_) async => s);
        expect(await Permissions.requestCameraPermission(), s);
      });
    }
  });
}
