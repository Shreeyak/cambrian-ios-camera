import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'mocks/mocks.mocks.dart';

g.SessionCapabilities _fakeCaps() => g.SessionCapabilities(
      supportedSizes: [g.PSize(width: 1920, height: 1080)],
      previewTextureId: 1,
      naturalTextureId: 2,
      activeCaptureResolution: g.PSize(width: 1920, height: 1080),
      activeCropRegion: g.PRect(x: 0, y: 0, width: 1920, height: 1080),
      streamPixelFormat: 'BGRA8',
      isoMin: 50,
      isoMax: 3200,
      exposureDurationMinNs: 100000,
      exposureDurationMaxNs: 33000000,
      focusMin: 0,
      focusMax: 1,
      zoomMin: 1,
      zoomMax: 8,
      evMin: -8,
      evMax: 8,
    );

void main() {
  late MockCameraEngineHostApi api;
  late CameraEngine engine;

  setUp(() {
    api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  group('open()', () {
    test('returns capabilities on success', () async {
      when(api.open(any)).thenAnswer((_) async => _fakeCaps());
      final caps = await engine.open();
      expect(caps.streamPixelFormat, 'BGRA8');
      verify(api.open(null)).called(1);
    });

    test('passes OpenConfiguration through', () async {
      when(api.open(any)).thenAnswer((_) async => _fakeCaps());
      final cfg = g.OpenConfiguration(cameraId: 'back');
      await engine.open(cfg);
      verify(api.open(cfg)).called(1);
    });

    test('rethrows PlatformException as CameraException', () async {
      when(api.open(any)).thenThrow(
        PlatformException(code: 'invalidState', message: 'busy'),
      );
      expect(
        () => engine.open(),
        throwsA(isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.invalidState)),
      );
    });
  });

  group('close()', () {
    test('delegates to HostApi', () async {
      when(api.close()).thenAnswer((_) async {});
      await engine.close();
      verify(api.close()).called(1);
    });

    test('dispose() calls close() exactly once', () async {
      when(api.close()).thenAnswer((_) async {});
      await engine.dispose();
      verify(api.close()).called(1);
    });
  });

  group('Snapshots', () {
    test('currentState returns the host value (fresh read, not a replay)',
        () async {
      when(api.currentState())
          .thenAnswer((_) async => g.SessionState.streaming);
      expect(await engine.currentState(), g.SessionState.streaming);
    });

    test('currentState rethrows PlatformException', () async {
      when(api.currentState()).thenThrow(
        PlatformException(code: 'notOpen', message: 'engine not open'),
      );
      expect(
        () => engine.currentState(),
        throwsA(isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.notOpen)),
      );
    });

    test('currentSettings returns null when host returns null', () async {
      when(api.currentSettings()).thenAnswer((_) async => null);
      expect(await engine.currentSettings(), isNull);
    });

    test('currentSettings rethrows PlatformException', () async {
      when(api.currentSettings()).thenThrow(
        PlatformException(code: 'notOpen', message: 'engine not open'),
      );
      expect(
        () => engine.currentSettings(),
        throwsA(isA<CameraException>()
            .having((e) => e.code, 'code', CameraErrorCode.notOpen)),
      );
    });

    test('currentProcessingParameters returns value on success', () async {
      final p = g.ProcessingParameters(
        brightness: 0,
        contrast: 1,
        saturation: 1,
        gamma: 1,
      );
      when(api.currentProcessingParameters()).thenAnswer((_) async => p);
      expect(await engine.currentProcessingParameters(), same(p));
    });
  });
}
