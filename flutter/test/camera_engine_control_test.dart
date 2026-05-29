import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('updateSettings delegates', () async {
    final s = g.CameraSettings(iso: 200);
    when(api.updateSettings(s)).thenAnswer((_) async {});
    await engine.updateSettings(s);
    verify(api.updateSettings(s)).called(1);
  });

  test('setResolution delegates', () async {
    when(api.setResolution(any)).thenAnswer((_) async {});
    await engine.setResolution(g.PSize(width: 1280, height: 720));
    verify(api.setResolution(any)).called(1);
  });

  test('setProcessingParams delegates', () async {
    final p = g.ProcessingParameters(
      brightness: 0,
      contrast: 1,
      saturation: 1,
      blackR: 0,
      blackG: 0,
      blackB: 0,
      gamma: 1,
    );
    when(api.setProcessingParams(p)).thenAnswer((_) async {});
    await engine.setProcessingParams(p);
    verify(api.setProcessingParams(p)).called(1);
  });

  test('setCropRegion delegates', () async {
    when(api.setCropRegion(any)).thenAnswer((_) async {});
    await engine.setCropRegion(g.PRect(x: 0, y: 0, width: 100, height: 100));
    verify(api.setCropRegion(any)).called(1);
  });

  test('per-method PlatformException rewraps to CameraException', () async {
    when(api.updateSettings(any)).thenThrow(
      PlatformException(code: 'settingsConflict', message: 'iso vs manual'),
    );
    expect(
      () => engine.updateSettings(g.CameraSettings()),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.settingsConflict)),
    );
  });

  test('engine stays usable after PlatformException', () async {
    when(api.setCropRegion(any)).thenThrow(
      PlatformException(code: 'invalidState', message: 'no'),
    );
    when(api.setResolution(any)).thenAnswer((_) async {});
    try {
      await engine.setCropRegion(g.PRect(x: 0, y: 0, width: 1, height: 1));
    } catch (_) {}
    await engine
        .setResolution(g.PSize(width: 1280, height: 720)); // must not throw
  });
}
