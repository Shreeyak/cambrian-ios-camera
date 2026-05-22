import 'dart:async';

import 'package:flutter/services.dart';

import 'camera_exception.dart';
import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

/// The Dart-side CameraEngine facade.
///
/// Mirrors CameraKit's public Swift surface 1:1; methods delegate to the Pigeon
/// HostApi. Caught `PlatformException`s are re-thrown as `CameraException`.
class CameraEngine {
  final g.CameraEngineHostApi _api;

  // Per-stream broadcast controllers. In production these are fed by listening
  // to the Pigeon EventChannel streams (top-level g.streamX() functions). In
  // tests, the CameraEngineStreamsTesting seam exposes them directly.
  //
  // Deliberately NON-replaying broadcast: what Dart observes is the camera's own
  // live state, never a cached/stale value. A replay (BehaviorSubject) would
  // re-emit the last value to every new subscriber, masking a stalled pipeline —
  // a frozen camera would look alive because a fresh subscriber gets the stale
  // cached frame. With broadcast, a stall surfaces as the absence of new events.
  // The current state for a late subscriber comes from the engine's live
  // lifecycle transitions (native scene-lifecycle → CameraEngine), not a replay.
  final StreamController<g.SessionState> _stateSource =
      StreamController<g.SessionState>.broadcast();
  final StreamController<g.CameraError> _errorSource =
      StreamController<g.CameraError>.broadcast();
  final StreamController<g.StreamConfiguration> _cfgSource =
      StreamController<g.StreamConfiguration>.broadcast();
  final StreamController<g.FrameResult> _frameSource =
      StreamController<g.FrameResult>.broadcast();
  final StreamController<g.RecordingStateValue> _recordingSource =
      StreamController<g.RecordingStateValue>.broadcast();

  late final Stream<g.SessionState> _stateStream = _stateSource.stream;
  late final Stream<CameraException> _exceptionStream =
      _errorSource.stream.map(_cameraErrorToException);
  late final Stream<g.StreamConfiguration> _cfgStream = _cfgSource.stream;
  late final Stream<g.FrameResult> _frameStream = _frameSource.stream;
  late final Stream<g.RecordingStateValue> _recordingStream =
      _recordingSource.stream;

  StreamSubscription<g.SessionState>? _stateBridge;
  StreamSubscription<g.CameraError>? _errorBridge;
  StreamSubscription<g.StreamConfiguration>? _cfgBridge;
  StreamSubscription<g.FrameResult>? _frameBridge;
  StreamSubscription<g.RecordingStateValue>? _recordingBridge;

  /// Production constructor — wires the default Pigeon HostApi and bridges each
  /// EventChannel stream into its broadcast controller.
  CameraEngine() : _api = g.CameraEngineHostApi() {
    _wireProductionStreams();
  }

  /// Internal constructor used by `CameraEngineTesting.create`. Does not wire
  /// production EventChannel streams — tests pump the controllers directly.
  CameraEngine._testing({required g.CameraEngineHostApi api}) : _api = api;

  void _wireProductionStreams() {
    _stateBridge = g.streamState().listen(_stateSource.add);
    _errorBridge = g.streamErrors().listen(_errorSource.add);
    _cfgBridge =
        g.streamStreamConfigurations().listen(_cfgSource.add);
    _frameBridge = g.streamFrameResults().listen(_frameSource.add);
    _recordingBridge =
        g.streamRecordingStates().listen(_recordingSource.add);
  }

  // MARK: - Lifecycle

  Future<g.SessionCapabilities> open([g.OpenConfiguration? config]) =>
      _guard(() => _api.open(config));

  Future<void> close() async {
    await _stateBridge?.cancel();
    await _errorBridge?.cancel();
    await _cfgBridge?.cancel();
    await _frameBridge?.cancel();
    await _recordingBridge?.cancel();
    _stateBridge = null;
    _errorBridge = null;
    _cfgBridge = null;
    _frameBridge = null;
    _recordingBridge = null;
    await _guard(_api.close);
  }

  /// Dart convention alias for `close()` — symmetric with most Dart classes
  /// that hold platform resources.
  Future<void> dispose() => close();

  // MARK: - Snapshots

  Future<g.CameraSettings?> currentSettings() => _guard(_api.currentSettings);

  Future<g.ProcessingParameters?> currentProcessingParameters() =>
      _guard(_api.currentProcessingParameters);

  // MARK: - Streams

  Stream<g.SessionState> stateStream() => _stateStream;
  Stream<CameraException> errorStream() => _exceptionStream;
  Stream<g.StreamConfiguration> streamConfigurationStream() => _cfgStream;
  Stream<g.FrameResult> frameResultStream() => _frameStream;
  Stream<g.RecordingStateValue> recordingStateStream() => _recordingStream;

  // MARK: - Control

  Future<void> updateSettings(g.CameraSettings settings) =>
      _guard(() => _api.updateSettings(settings));

  Future<void> setResolution(g.PSize size) =>
      _guard(() => _api.setResolution(size));

  Future<void> setProcessingParams(g.ProcessingParameters params) =>
      _guard(() => _api.setProcessingParams(params));

  Future<void> setCropRegion(g.PRect rect) =>
      _guard(() => _api.setCropRegion(rect));

  // MARK: - Capture

  Future<String> captureImage({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureImage(outputPath, photosDestination));

  Future<String> captureNaturalPicture({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureNaturalPicture(outputPath, photosDestination));

  // MARK: - Recording

  Future<g.RecordingStart> startRecording(g.RecordingOptions options) =>
      _guard(() => _api.startRecording(options));

  Future<String> stopRecording() => _guard(_api.stopRecording);

  // MARK: - Calibration

  Future<g.CalibrationResult> calibrateWhiteBalance() =>
      _guard(_api.calibrateWhiteBalance);

  Future<g.CalibrationResult> calibrateBlackBalance() =>
      _guard(_api.calibrateBlackBalance);

  // MARK: - Texture bridge

  Future<int> createPreviewTexture({required g.StreamId stream}) =>
      _guard(() => _api.createPreviewTexture(stream));

  Future<void> destroyPreviewTexture(int textureId) =>
      _guard(() => _api.destroyPreviewTexture(textureId));

  // MARK: - Internal helpers

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (pe) {
      throw CameraException.fromPlatformException(pe);
    }
  }

  static CameraException _cameraErrorToException(g.CameraError e) =>
      CameraException(code: e.code, message: e.message, isFatal: e.isFatal);

  // Test seams — used by lib/testing.dart's CameraEngineStreamsTesting helpers.
  StreamController<g.SessionState> get _stateSourceForTest => _stateSource;
  StreamController<g.CameraError> get _errorSourceForTest => _errorSource;
  StreamController<g.StreamConfiguration> get _cfgSourceForTest => _cfgSource;
  StreamController<g.FrameResult> get _frameSourceForTest => _frameSource;
  StreamController<g.RecordingStateValue> get _recordingSourceForTest =>
      _recordingSource;
}

/// Internal: factory for the testing seam. Returns a CameraEngine wired against
/// the given api. Not exposed via the main library.
CameraEngine cameraEngineMakeForTest({required g.CameraEngineHostApi api}) =>
    CameraEngine._testing(api: api);

StreamController<g.SessionState> cameraEngineStateSourceForTest(
        CameraEngine e) =>
    e._stateSourceForTest;
StreamController<g.CameraError> cameraEngineErrorSourceForTest(
        CameraEngine e) =>
    e._errorSourceForTest;
StreamController<g.StreamConfiguration> cameraEngineCfgSourceForTest(
        CameraEngine e) =>
    e._cfgSourceForTest;
StreamController<g.FrameResult> cameraEngineFrameSourceForTest(
        CameraEngine e) =>
    e._frameSourceForTest;
StreamController<g.RecordingStateValue> cameraEngineRecordingSourceForTest(
        CameraEngine e) =>
    e._recordingSourceForTest;
