import 'dart:async';

import 'package:flutter/services.dart';

import 'camera_exception.dart';
import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

/// The Dart-side CameraEngine facade.
///
/// Mirrors CameraKit's public Swift surface 1:1; methods delegate to the Pigeon
/// HostApi. Caught `PlatformException`s are re-thrown as [CameraException].
///
/// ## Lifecycle convention — prefer one engine per session
///
/// The **strong convention is single-use**: construct a `CameraEngine`,
/// [open] it, use it, then [close] (or [dispose]) it — and create a *fresh*
/// instance for the next session. This mirrors Flutter's official `camera`
/// plugin and keeps lifecycle reasoning simple; it is the recommended pattern.
///
/// Reuse **is** supported — calling [open] again after [close] reopens this
/// same instance and its event streams resume — but it is not the recommended
/// path. Reach for it only when you deliberately hold one long-lived engine
/// (e.g. a shared controller) and want to release the camera between uses.
///
/// Note: app background/foreground does **not** require close/open — that is
/// handled natively (UIScene → CameraKit) and this facade exposes no lifecycle
/// surface.
class CameraEngine {
  final g.CameraEngineHostApi _api;

  /// True for the production constructor (owns the real EventChannel bridges,
  /// re-established on each [open]); false for the testing constructor, where
  /// tests pump the broadcast controllers directly.
  final bool _ownsProductionStreams;

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
  CameraEngine()
      : _api = g.CameraEngineHostApi(),
        _ownsProductionStreams = true {
    _wireProductionStreams();
  }

  /// Internal constructor used by `CameraEngineTesting.create`. Does not wire
  /// production EventChannel streams — tests pump the controllers directly.
  CameraEngine._testing({required g.CameraEngineHostApi api})
      : _api = api,
        _ownsProductionStreams = false;

  /// (Re)establishes the EventChannel->controller bridges. Idempotent (`??=`),
  /// so [open] can call it again after a [close] to support reuse: the broadcast
  /// controllers are never closed, so existing subscribers stay attached across
  /// an open/close/open cycle and simply resume receiving events.
  void _wireProductionStreams() {
    _stateBridge ??= g.streamState().listen(_stateSource.add);
    _errorBridge ??= g.streamErrors().listen(_errorSource.add);
    _cfgBridge ??= g.streamStreamConfigurations().listen(_cfgSource.add);
    _frameBridge ??= g.streamFrameResults().listen(_frameSource.add);
    _recordingBridge ??= g.streamRecordingStates().listen(_recordingSource.add);
  }

  // MARK: - Lifecycle

  /// Opens a camera session and returns its [g.SessionCapabilities].
  ///
  /// May be called again after [close] to reopen this same instance — the
  /// EventChannel bridges are (re)established here first, so the streams keep
  /// delivering across an open/close/open cycle. Prefer a fresh instance per
  /// session, though (see the class-level convention).
  Future<g.SessionCapabilities> open([g.OpenConfiguration? config]) {
    if (_ownsProductionStreams) _wireProductionStreams();
    return _guard(() => _api.open(config));
  }

  /// Releases the camera session. Cancels the EventChannel bridges (the
  /// broadcast controllers stay open, so subscribers survive a later reopen).
  /// The instance may be reopened with [open], though a fresh instance per
  /// session is the recommended convention.
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

  /// A fresh read of the camera's ACTUAL current session state — not a replay.
  ///
  /// Read this once when you start observing (e.g. in a preview widget's
  /// `initState`) to learn the current state immediately, then listen to
  /// [stateStream] for live transitions. Unlike a replaying stream, this can
  /// never surface a stale value: it queries the engine's live state at call
  /// time. Returns [g.SessionState.closed] before [open].
  Future<g.SessionState> currentState() => _guard(_api.currentState);

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

  /// Captures the current **processed**-lane frame to a file and returns its
  /// on-disk path.
  ///
  /// **The image format is derived from [outputPath]'s file extension**
  /// (case-insensitive) — CameraKit never guesses:
  /// - `.png` → PNG, `.jpg`/`.jpeg` → JPEG, `.tif`/`.tiff` → TIFF.
  /// - `null` (the default) writes `<Documents>/<timestamp>.png` (PNG).
  /// - A name with **no** extension, or an **unsupported** one (e.g. `.gif`),
  ///   is rejected — the capture throws rather than picking a format.
  ///
  /// [outputPath] may be a bare filename (lands in the app's `Documents`
  /// directory) or a full path inside the app sandbox; parent directories are
  /// created as needed. A path outside the sandbox is rejected.
  ///
  /// Throws [CameraException] on failure. Note: in the current bridge the
  /// path/format violations above (missing extension, unsupported extension,
  /// out-of-sandbox path) all surface as [CameraErrorCode.unknownError] with a
  /// diagnostic [CameraException.message] — they are not (yet) a distinct typed
  /// error code, so branch on the message if you must distinguish them.
  Future<String> captureImage({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureImage(outputPath, photosDestination));

  /// Captures the current **natural**-lane frame (the ISP image, before
  /// CameraKit's processing shaders) to a file and returns its on-disk path.
  ///
  /// [outputPath]'s format/path rules and the error behavior are **identical to
  /// [captureImage]**: the extension picks the format
  /// (`.png`/`.jpg`/`.jpeg`/`.tif`/`.tiff`), `null` → a timestamped `.png`, and
  /// a missing/unsupported extension or out-of-sandbox path throws.
  Future<String> captureNaturalPicture({
    String? outputPath,
    g.PhotosDestination photosDestination = g.PhotosDestination.none,
  }) =>
      _guard(() => _api.captureNaturalPicture(outputPath, photosDestination));

  // MARK: - Recording

  /// Starts recording the processed lane and returns a [g.RecordingStart]; stop
  /// with [stopRecording].
  ///
  /// **Only MP4 is supported.** If [g.RecordingOptions.outputPath] is set it
  /// must end in `.mp4`; a name with no extension or a non-`.mp4` extension is
  /// rejected (the recording fails to start). When `outputPath` is `null`,
  /// recording writes `<Documents>/<timestamp>.mp4`. As with [captureImage],
  /// format/path violations currently surface as [CameraErrorCode.unknownError]
  /// with a diagnostic [CameraException.message].
  Future<g.RecordingStart> startRecording(g.RecordingOptions options) =>
      _guard(() => _api.startRecording(options));

  Future<String> stopRecording() => _guard(_api.stopRecording);

  // MARK: - Calibration

  /// Calibrate white balance from a white field.
  ///
  /// Locks the hardware gains and derives + enables the WB chroma residual and,
  /// when [whitePoint] is true (brightfield, the default), the white-point level.
  /// Throws a [CameraException] with [CameraErrorCode.calibrationFailed] when the
  /// field isn't bright enough.
  Future<g.CalibrationResult> calibrateWhite({bool whitePoint = true}) =>
      _guard(() => _api.calibrateWhite(whitePoint));

  /// Calibrate the linear black point from a dark field.
  ///
  /// Point the camera at a uniformly dark/black field, then call this. Completes
  /// with no value on success. Throws a [CameraException] with
  /// [CameraErrorCode.calibrationFailed] (the message explains why — e.g. the
  /// field wasn't dark enough) when a valid black point can't be derived.
  /// Replaces the removed `calibrateBlackBalance`.
  Future<void> calibrateBlack() => _guard(_api.calibrateBlack);

  // Calibration toggles — flip the stored coefficients without resampling.
  // `enable*` throw a [CameraException] ([CameraErrorCode.invalidState]) when the
  // matching calibration hasn't run; `disable*`/`clear*` never throw. White point
  // is gated to white balance (enable white point needs WB active;
  // [disableWhiteBalance] also turns the white point off).

  /// Re-enable the stored WB chroma correction (throws if never calibrated).
  Future<void> enableWhiteBalance() => _guard(_api.enableWhiteBalance);

  /// Disable the WB chroma correction (also disables the white point).
  Future<void> disableWhiteBalance() => _guard(_api.disableWhiteBalance);

  /// Enable the stored white-point level (requires WB active; throws otherwise).
  Future<void> enableWhitePoint() => _guard(_api.enableWhitePoint);

  /// Disable the white-point level (keeps the WB chroma correction).
  Future<void> disableWhitePoint() => _guard(_api.disableWhitePoint);

  /// Discard the stored WB coefficients (a re-calibrate is then required).
  Future<void> clearWhiteBalance() => _guard(_api.clearWhiteBalance);

  /// Re-enable the stored black point (throws if never calibrated).
  Future<void> enableBlackPoint() => _guard(_api.enableBlackPoint);

  /// Disable the black point (keeps the stored offsets).
  Future<void> disableBlackPoint() => _guard(_api.disableBlackPoint);

  /// Discard the stored black point (a re-calibrate is then required).
  Future<void> clearBlackPoint() => _guard(_api.clearBlackPoint);

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
