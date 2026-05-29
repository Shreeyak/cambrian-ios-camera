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

  test('createPreviewTexture returns the textureId from HostApi', () async {
    when(api.createPreviewTexture(g.StreamId.processed))
        .thenAnswer((_) async => 42);
    expect(await engine.createPreviewTexture(stream: g.StreamId.processed), 42);
  });

  test('createPreviewTexture for natural lane returns its own id', () async {
    when(api.createPreviewTexture(g.StreamId.processed))
        .thenAnswer((_) async => 42);
    when(api.createPreviewTexture(g.StreamId.natural))
        .thenAnswer((_) async => 43);
    final a = await engine.createPreviewTexture(stream: g.StreamId.processed);
    final b = await engine.createPreviewTexture(stream: g.StreamId.natural);
    expect(a, isNot(b));
  });

  test('destroyPreviewTexture delegates', () async {
    when(api.destroyPreviewTexture(7)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(7);
    verify(api.destroyPreviewTexture(7)).called(1);
  });

  test('destroy before create completes — destroy with -1 sentinel is allowed',
      () async {
    when(api.destroyPreviewTexture(-1)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(-1);
    verify(api.destroyPreviewTexture(-1)).called(1);
  });

  test('destroy twice with the same id is idempotent from Dart POV', () async {
    when(api.destroyPreviewTexture(7)).thenAnswer((_) async {});
    await engine.destroyPreviewTexture(7);
    await engine.destroyPreviewTexture(7);
    verify(api.destroyPreviewTexture(7)).called(2); // adapter no-ops the second
  });

  test('createPreviewTexture rewraps unrelated PlatformException', () async {
    when(api.createPreviewTexture(any)).thenThrow(
        PlatformException(code: 'hardwareError', message: 'metal init failed'));
    expect(
      () => engine.createPreviewTexture(stream: g.StreamId.processed),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.hardwareError)),
    );
  });
}
