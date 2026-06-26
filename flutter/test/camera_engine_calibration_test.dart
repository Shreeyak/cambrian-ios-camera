import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'mocks/mocks.mocks.dart';

g.CalibrationResult _fakeResult() => g.CalibrationResult(
      before: g.RgbSample(r: 0.5, g: 0.5, b: 0.5),
      after: g.RgbSample(r: 0.5, g: 0.5, b: 0.5),
      converged: true,
      iterations: 1,
    );

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;
  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  test('calibrateWhiteBalance returns CalibrationResult', () async {
    final r = _fakeResult();
    when(api.calibrateWhiteBalance()).thenAnswer((_) async => r);
    expect(await engine.calibrateWhiteBalance(), r);
  });
  test('calibrateBlackPoint completes on success', () async {
    when(api.calibrateBlackPoint()).thenAnswer((_) async {});
    await engine.calibrateBlackPoint();
    verify(api.calibrateBlackPoint()).called(1);
  });
  test('calibrateBlackPoint surfaces failure as CameraException', () async {
    when(api.calibrateBlackPoint()).thenThrow(
      PlatformException(
        code: 'calibrationFailed',
        message: 'Only 5% of the sampled patch was near-black (need ≥ 40%).',
      ),
    );
    await expectLater(
      engine.calibrateBlackPoint(),
      throwsA(
        isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.calibrationFailed),
      ),
    );
  });
}
