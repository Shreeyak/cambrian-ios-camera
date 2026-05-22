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

  test('startRecording returns RecordingStart on success', () async {
    final start =
        g.RecordingStart(uri: 'file:///tmp/x.mp4', displayName: 'x.mp4');
    when(api.startRecording(any)).thenAnswer((_) async => start);
    final s = await engine.startRecording(g.RecordingOptions(
      photosDestination: g.PhotosDestination.none,
    ));
    expect(s.uri, 'file:///tmp/x.mp4');
    expect(s.displayName, 'x.mp4');
  });

  test('stopRecording returns the uri string', () async {
    when(api.stopRecording()).thenAnswer((_) async => 'file:///tmp/x.mp4');
    expect(await engine.stopRecording(), 'file:///tmp/x.mp4');
  });

  test('startRecording rewraps PlatformException', () async {
    when(api.startRecording(any)).thenThrow(
      PlatformException(
          code: 'recordingStartFailed', message: 'asset writer err'),
    );
    expect(
      () => engine.startRecording(g.RecordingOptions(
        photosDestination: g.PhotosDestination.none,
      )),
      throwsA(isA<CameraException>().having(
          (e) => e.code, 'code', CameraErrorCode.recordingStartFailed)),
    );
  });
}
