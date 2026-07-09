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

  test('calibrateWhite passes whitePoint and returns result', () async {
    final r = _fakeResult();
    when(api.calibrateWhite(any)).thenAnswer((_) async => r);
    expect(await engine.calibrateWhite(whitePoint: false), r);
    verify(api.calibrateWhite(false)).called(1);
    // Default is brightfield (white point on).
    expect(await engine.calibrateWhite(), r);
    verify(api.calibrateWhite(true)).called(1);
  });
  test('calibration toggles forward to the host api', () async {
    when(api.enableWhiteBalance()).thenAnswer((_) async {});
    when(api.disableWhiteBalance()).thenAnswer((_) async {});
    when(api.enableWhitePoint()).thenAnswer((_) async {});
    when(api.disableWhitePoint()).thenAnswer((_) async {});
    when(api.clearWhiteBalance()).thenAnswer((_) async {});
    when(api.enableBlackPoint()).thenAnswer((_) async {});
    when(api.disableBlackPoint()).thenAnswer((_) async {});
    when(api.clearBlackPoint()).thenAnswer((_) async {});
    await engine.enableWhiteBalance();
    await engine.disableWhiteBalance();
    await engine.enableWhitePoint();
    await engine.disableWhitePoint();
    await engine.clearWhiteBalance();
    await engine.enableBlackPoint();
    await engine.disableBlackPoint();
    await engine.clearBlackPoint();
    verify(api.enableWhiteBalance()).called(1);
    verify(api.disableWhiteBalance()).called(1);
    verify(api.enableWhitePoint()).called(1);
    verify(api.disableWhitePoint()).called(1);
    verify(api.clearWhiteBalance()).called(1);
    verify(api.enableBlackPoint()).called(1);
    verify(api.disableBlackPoint()).called(1);
    verify(api.clearBlackPoint()).called(1);
  });
  test('enableWhitePoint surfaces not-calibrated as invalidState', () async {
    when(api.enableWhitePoint()).thenThrow(
      PlatformException(
        code: 'invalidState',
        message: 'White balance has not been calibrated.',
      ),
    );
    await expectLater(
      engine.enableWhitePoint(),
      throwsA(
        isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.invalidState),
      ),
    );
  });
  test('calibrateBlack completes on success', () async {
    when(api.calibrateBlack()).thenAnswer((_) async {});
    await engine.calibrateBlack();
    verify(api.calibrateBlack()).called(1);
  });
  test('calibrateBlack surfaces failure as CameraException', () async {
    when(api.calibrateBlack()).thenThrow(
      PlatformException(
        code: 'calibrationFailed',
        message: 'Only 5% of the sampled patch was near-black (need ≥ 40%).',
      ),
    );
    await expectLater(
      engine.calibrateBlack(),
      throwsA(
        isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.calibrationFailed),
      ),
    );
  });
}
