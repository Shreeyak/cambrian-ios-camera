import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'package:cambrian_ios_camera_example/widgets/permission_gate.dart';

/// Fake host API so the gate never reaches a real platform channel under
/// `flutter test`. Returns `.notDetermined` after a microtask, so the first
/// frame still renders the loading spinner.
class _FakePermissionsApi extends g.PermissionsHostApi {
  @override
  Future<g.CameraPermissionStatus> cameraPermissionStatus() async =>
      g.CameraPermissionStatus.notDetermined;
  @override
  Future<g.CameraPermissionStatus> requestCameraPermission() async =>
      g.CameraPermissionStatus.authorized;
}

void main() {
  setUp(() => PermissionsTesting.setHostApi(_FakePermissionsApi()));
  tearDown(PermissionsTesting.reset);

  testWidgets('renders progress while status unknown', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PermissionGate(granted: const Text('GRANTED'))),
    ));
    // First frame: status is still null (the fake resolves on a later
    // microtask), so the loading spinner is shown.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
