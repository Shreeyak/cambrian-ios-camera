// Integration tests for cambrian_ios_camera — run on a physical iPad.
//
// See README.md for prerequisites (pre-granted camera permission, auto-lock
// off, and the manual home-button press for Test 2). Tests 1, 3, and 4 run
// unattended; Test 2 needs a human at the device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The camera is exclusive hardware: a test that ends without close() leaves
  // the AVCaptureSession held, and the next test's open() hangs. tearDown always
  // releases it, even on failure.
  CameraEngine? engine;
  tearDown(() async {
    await engine?.close().timeout(const Duration(seconds: 5), onTimeout: () {});
    engine = null;
  });

  // Polls until the engine reports `.streaming` (via the live stream or a fresh
  // currentState() read), or throws after `within`.
  Future<void> waitForStreaming(CameraEngine e, List<SessionState> log,
      {Duration within = const Duration(seconds: 6)}) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      if (log.contains(SessionState.streaming)) return;
      if (await e.currentState() == SessionState.streaming) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('engine did not reach .streaming within ${within.inSeconds}s');
  }

  test('Test 1 — Smoke: open → frame → capture → close', () async {
    final e = engine = CameraEngine();
    final caps = await e.open();
    expect(caps.streamPixelFormat, 'BGRA8');

    final stateLog = <SessionState>[];
    final stateSub = e.stateStream().listen(stateLog.add);

    final textureId = await e.createPreviewTexture(stream: StreamId.processed);
    // 0 is a valid FlutterTextureRegistry id (first-registered texture gets it
    // on a real device; a failed create throws instead).
    expect(textureId, greaterThanOrEqualTo(0));

    await waitForStreaming(e, stateLog);

    final firstFrame =
        await e.frameResultStream().first.timeout(const Duration(seconds: 5));
    expect(firstFrame, isNotNull);

    // captureImage derives the encoding from the output path's extension
    // (CameraKit's OutputPathResolver) — `.tif` → TIFF.
    final tempPath = '${Directory.systemTemp.path}/integration-capture.tif';
    final path = await e.captureImage(outputPath: tempPath);
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), greaterThan(0));

    await e.destroyPreviewTexture(textureId);
    await stateSub.cancel();
  });

  test('Test 2 — Lifecycle: foreground → background → foreground', () async {
    final e = engine = CameraEngine();
    await e.open();
    final stateLog = <SessionState>[];
    final stateSub = e.stateStream().listen(stateLog.add);
    await waitForStreaming(e, stateLog);

    // Manual prompt — see integration_test/README.md.
    // ignore: avoid_print
    print(
        'INTEGRATION_PROMPT: press the home button now, then bring the app back');

    // Wait up to 30s for .paused or .interrupted.
    final paused = DateTime.now().add(const Duration(seconds: 30));
    while (!stateLog.any((s) =>
            s == SessionState.paused || s == SessionState.interrupted) &&
        DateTime.now().isBefore(paused)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(
        stateLog.any(
            (s) => s == SessionState.paused || s == SessionState.interrupted),
        isTrue,
        reason: 'engine did not pause when app was backgrounded');

    // Wait for return-to-streaming.
    final returned = DateTime.now().add(const Duration(seconds: 30));
    var streamingAfter = false;
    while (DateTime.now().isBefore(returned)) {
      if (stateLog.isNotEmpty && stateLog.last == SessionState.streaming) {
        streamingAfter = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(streamingAfter, isTrue,
        reason: 'engine did not resume to .streaming after foreground');

    await stateSub.cancel();
  },
      timeout: const Timeout(Duration(minutes: 2)),
      // Not viable as a manual flutter-integration test: backgrounding the app
      // (the required home-button press) kills the test-driver connection and
      // terminates the app, and while backgrounded iOS suspends the Dart isolate
      // so the engine's transient `.paused` (published over the non-replaying
      // broadcast) is never observed. Lifecycle is covered instead by
      // RunnerTests/SceneLifecycleTests (scene callback → setLifecyclePhase) and
      // device-log gate open/close verification. v1.1 will re-enable this via
      // XCUIDevice, which can background without dropping the test connection.
      skip: 'requires XCUIDevice automation (v1.1) — see comment');

  test('Test 3 — Recording cycle (2 seconds @ 30fps)', () async {
    final e = engine = CameraEngine();
    await e.open();
    final stateLog = <SessionState>[];
    final stateSub = e.stateStream().listen(stateLog.add);
    await waitForStreaming(e, stateLog);

    final start = await e.startRecording(RecordingOptions(
      fps: 30,
      photosDestination: PhotosDestination.none,
    ));
    expect(start.displayName, isNotEmpty);

    await Future<void>.delayed(const Duration(seconds: 2));

    final mp4Uri = await e.stopRecording();
    expect(mp4Uri, isNotEmpty);

    // stopRecording() returns a bare POSIX filesystem path (CameraKit's
    // bare-path contract) — use it directly, no file:// URL parsing.
    final path = mp4Uri;
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), greaterThan(10000),
        reason: 'mp4 should have substantial bytes for a 2s recording');

    await stateSub.cancel();
  });

  test('Test 4 — Reuse: reopen the same instance keeps event streams alive',
      () async {
    final e = engine = CameraEngine();

    // First session.
    await e.open();
    final log1 = <SessionState>[];
    final sub1 = e.stateStream().listen(log1.add);
    await waitForStreaming(e, log1);
    await sub1.cancel();

    // Release the camera, then reopen the SAME instance.
    await e.close();
    expect(await e.currentState(), SessionState.closed);
    await e.open();

    // Regression guard: the EventChannel bridges were wired only in the
    // constructor, so a reopened engine's streams were silently dead. A frame
    // arriving here proves open() re-established the frameResult bridge — a
    // direct currentState() read would NOT catch the bug (it bypasses streams).
    final frame = await e.frameResultStream().first.timeout(
          const Duration(seconds: 6),
          onTimeout: () => throw StateError(
              'no frame after reopen — EventChannel bridges not re-established'),
        );
    expect(frame, isNotNull);
  });
}
