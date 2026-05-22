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

  test('captureImage returns the path, defaults photosDestination to none',
      () async {
    when(api.captureImage(null, g.PhotosDestination.none))
        .thenAnswer((_) async => '/var/mobile/.../img-001.heic');
    final path = await engine.captureImage();
    expect(path, '/var/mobile/.../img-001.heic');
    verify(api.captureImage(null, g.PhotosDestination.none)).called(1);
  });

  test('captureImage passes outputPath through', () async {
    when(api.captureImage('/tmp/x.heic', g.PhotosDestination.copy))
        .thenAnswer((_) async => '/tmp/x.heic');
    await engine.captureImage(
      outputPath: '/tmp/x.heic',
      photosDestination: g.PhotosDestination.copy,
    );
    verify(api.captureImage('/tmp/x.heic', g.PhotosDestination.copy)).called(1);
  });

  test('captureNaturalPicture delegates', () async {
    when(api.captureNaturalPicture(null, g.PhotosDestination.none))
        .thenAnswer((_) async => '/var/mobile/natural.heic');
    expect(await engine.captureNaturalPicture(), '/var/mobile/natural.heic');
  });

  test('captureImage rewraps PlatformException', () async {
    when(api.captureImage(any, any)).thenThrow(
      PlatformException(code: 'captureFailure', message: 'shutter glitch'),
    );
    expect(
      () => engine.captureImage(),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.captureFailure)),
    );
  });
}
