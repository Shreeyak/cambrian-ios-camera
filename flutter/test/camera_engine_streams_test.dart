import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'package:cambrian_ios_camera/testing.dart';
import 'package:cambrian_ios_camera/src/pigeon/cambrian_ios_camera_api.g.dart'
    as g;
import 'mocks/mocks.mocks.dart';

void main() {
  late CameraEngine engine;

  setUp(() {
    final api = MockCameraEngineHostApi();
    engine = CameraEngineTesting.create(api: api);
  });

  group('stateStream()', () {
    test('returns a broadcast Stream', () {
      final s = engine.stateStream();
      expect(s.isBroadcast, isTrue);
    });

    test('subsequent calls return the same Stream instance', () {
      expect(identical(engine.stateStream(), engine.stateStream()), isTrue);
    });

    test('SessionState.error passes through 1:1', () async {
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final values = <g.SessionState>[];
      final sub = engine.stateStream().listen(values.add);
      ctrl.add(g.SessionState.error);
      await pumpEventQueue();
      expect(values, [g.SessionState.error]);
      await sub.cancel();
    });

    test('two subscribers both receive events', () async {
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final a = <g.SessionState>[];
      final b = <g.SessionState>[];
      final subA = engine.stateStream().listen(a.add);
      final subB = engine.stateStream().listen(b.add);
      ctrl.add(g.SessionState.streaming);
      await pumpEventQueue();
      expect(a, [g.SessionState.streaming]);
      expect(b, [g.SessionState.streaming]);
      await subA.cancel();
      await subB.cancel();
    });

    test('error on subscriber A does not terminate subscriber B', () async {
      // A broadcast subscriber whose onData throws raises an uncaught zone
      // error (onError only catches stream error *events*, not onData throws),
      // so we run inside a guarded zone and assert B still received its event.
      final ctrl = CameraEngineStreamsTesting.stateSource(engine);
      final b = <g.SessionState>[];
      Object? subscriberAError;
      await runZonedGuarded(() async {
        final subA =
            engine.stateStream().listen((_) => throw StateError('A throws'));
        final subB = engine.stateStream().listen(b.add);
        ctrl.add(g.SessionState.streaming);
        await pumpEventQueue();
        await subA.cancel();
        await subB.cancel();
      }, (error, _) => subscriberAError = error);
      expect(subscriberAError, isA<StateError>());
      expect(b, [g.SessionState.streaming]);
    });
  });

  group('errorStream()', () {
    test('emits CameraException, not Pigeon CameraError', () async {
      final ctrl = CameraEngineStreamsTesting.errorSource(engine);
      final values = <CameraException>[];
      final sub = engine.errorStream().listen(values.add);
      ctrl.add(g.CameraError(
        code: g.CameraErrorCode.frameStall,
        message: 'watchdog fired',
        isFatal: false,
      ));
      await pumpEventQueue();
      expect(values, hasLength(1));
      expect(values.first.code, CameraErrorCode.frameStall);
      expect(values.first.message, 'watchdog fired');
      await sub.cancel();
    });
  });

  group('recordingStateStream()', () {
    test('decodes idle / recording / finalizing', () async {
      final ctrl = CameraEngineStreamsTesting.recordingSource(engine);
      final values = <g.RecordingStateValue>[];
      final sub = engine.recordingStateStream().listen(values.add);
      ctrl.add(g.RecordingStateValue(
          kind: g.RecordingStateKind.idle, lastUri: '/tmp/x.mp4'));
      ctrl.add(g.RecordingStateValue(kind: g.RecordingStateKind.recording));
      ctrl.add(g.RecordingStateValue(kind: g.RecordingStateKind.finalizing));
      await pumpEventQueue();
      expect(values.map((v) => v.kind), [
        g.RecordingStateKind.idle,
        g.RecordingStateKind.recording,
        g.RecordingStateKind.finalizing,
      ]);
      expect(values.first.lastUri, '/tmp/x.mp4');
      await sub.cancel();
    });
  });
}
