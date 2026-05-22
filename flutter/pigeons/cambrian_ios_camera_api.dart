// Pigeon DSL for cambrian_ios_camera.
//
// Regenerate with:
//   cd flutter && dart run pigeon --input pigeons/cambrian_ios_camera_api.dart
//
// Output locations:
//   - Dart:   lib/src/pigeon/cambrian_ios_camera_api.g.dart
//   - Swift:  ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift
//   - Kotlin: android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt
//
// All generated files are committed to git for review on bumps.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/cambrian_ios_camera_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/cambrian_ios_camera/Sources/cambrian_ios_camera/Pigeon/cambrian_ios_camera_api.g.swift',
    swiftOptions: SwiftOptions(),
    kotlinOut: 'android/src/main/kotlin/com/cambrian/cambrian_ios_camera/cambrian_ios_camera_api.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.cambrian.cambrian_ios_camera'),
    dartPackageName: 'cambrian_ios_camera',
  ),
)
// ─── ENUMS ──────────────────────────────────────────────────────────────────

enum SessionState {
  opening,
  streaming,
  recovering,
  paused,
  error,
  closed,
  interrupted,
}

enum StreamId { natural, processed, tracker }

enum CameraPermissionStatus { notDetermined, denied, restricted, authorized }

enum PhotosDestination { none, copy, move }

// Mirrors CameraKit `CameraMode` exactly (Capabilities.swift:127). The Pigeon
// enum must not declare cases the Swift target lacks — the adapter mapper
// would have no destination to map them to.
enum CameraMode { auto, manual }

// Mirrors CameraKit `WhiteBalanceMode` exactly (Capabilities.swift:132).
enum WhiteBalanceMode { auto, locked, manual }

enum RecordingStateKind { idle, recording, finalizing }

enum CameraErrorCode {
  cameraNotFound,
  cameraInUse,
  permissionDenied,
  cameraAccessError,
  cameraDisconnected,
  configurationFailed,
  captureFailure,
  recordingStartFailed,
  recordingFailed,
  recordingTruncated,
  frameStall,
  maxRetriesExceeded,
  unknownError,
  settingsConflict,
  invalidFormat,
  fpsDegraded,
  aeConvergenceTimeout,
  invalidState,
  hardwareError,
  notOpen, // Adapter-injected — represents EngineError.notOpen, not an ErrorCode.
}

// ─── VALUE TYPES ────────────────────────────────────────────────────────────

class PSize {
  PSize(this.width, this.height);
  final int width;
  final int height;
}

class PRect {
  PRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
}

class OpenConfiguration {
  OpenConfiguration({
    this.cameraId,
    this.captureResolution,
    this.cropRegion,
    this.initialSettings,
  });
  String? cameraId;
  PSize? captureResolution;
  PRect? cropRegion;
  CameraSettings? initialSettings;
}

// Pigeon-flattened mirror of CameraKit `SessionCapabilities`. Min/Max pairs
// replace `ClosedRange<…>` (Pigeon has no Range type). Float ranges
// (`isoRange`, `evCompensationRange`) widen losslessly to `double` here.
class SessionCapabilities {
  SessionCapabilities({
    required this.supportedSizes,
    required this.previewTextureId,
    required this.naturalTextureId,
    required this.activeCaptureResolution,
    required this.activeCropRegion,
    required this.streamPixelFormat,
    required this.isoMin,
    required this.isoMax,
    required this.exposureDurationMinNs,
    required this.exposureDurationMaxNs,
    required this.focusMin,
    required this.focusMax,
    required this.zoomMin,
    required this.zoomMax,
    required this.evMin,
    required this.evMax,
  });
  List<PSize?> supportedSizes;
  int previewTextureId;
  int naturalTextureId;
  PSize activeCaptureResolution;
  PRect activeCropRegion;
  String streamPixelFormat;
  double isoMin;
  double isoMax;
  int exposureDurationMinNs;
  int exposureDurationMaxNs;
  double focusMin;
  double focusMax;
  double zoomMin;
  double zoomMax;
  double evMin;
  double evMax;
}

class CameraSettings {
  CameraSettings({
    this.isoMode,
    this.iso,
    this.exposureMode,
    this.exposureTimeNs,
    this.focusMode,
    this.focusDistance,
    this.wbMode,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
    this.zoomRatio,
    this.evCompensation,
  });
  CameraMode? isoMode;
  int? iso;
  CameraMode? exposureMode;
  int? exposureTimeNs;
  CameraMode? focusMode;
  double? focusDistance;
  WhiteBalanceMode? wbMode;
  double? wbGainR;
  double? wbGainG;
  double? wbGainB;
  double? zoomRatio;
  int? evCompensation;
}

class ProcessingParameters {
  ProcessingParameters({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.blackR,
    required this.blackG,
    required this.blackB,
    required this.gamma,
  });
  double brightness;
  double contrast;
  double saturation;
  double blackR;
  double blackG;
  double blackB;
  double gamma;
}

class StreamConfiguration {
  StreamConfiguration({
    required this.activeCaptureResolution,
    required this.activeCropRegion,
  });
  PSize activeCaptureResolution;
  PRect activeCropRegion;
}

class FrameResult {
  FrameResult({
    this.iso,
    this.exposureTimeNs,
    this.focusDistance,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
  });
  int? iso;
  int? exposureTimeNs;
  double? focusDistance;
  double? wbGainR;
  double? wbGainG;
  double? wbGainB;
}

class RecordingOptions {
  RecordingOptions({
    this.bitrateBps,
    this.fps,
    this.outputPath,
    required this.photosDestination,
  });
  int? bitrateBps;
  int? fps;
  String? outputPath;
  PhotosDestination photosDestination;
}

class RecordingStart {
  RecordingStart({required this.uri, required this.displayName});
  String uri;
  String displayName;
}

// Discriminated mirror of CameraKit `RecordingState` (idle has an associated
// `lastUri: String?`; recording/finalizing carry no payload).
class RecordingStateValue {
  RecordingStateValue({required this.kind, this.lastUri});
  RecordingStateKind kind;
  String? lastUri;
}

class RgbSample {
  RgbSample({required this.r, required this.g, required this.b});
  double r;
  double g;
  double b;
}

class CalibrationResult {
  CalibrationResult({
    required this.before,
    required this.after,
    required this.converged,
    required this.iterations,
  });
  RgbSample before;
  RgbSample after;
  bool converged;
  int iterations;
}

class CameraError {
  CameraError({required this.code, required this.message, required this.isFatal});
  CameraErrorCode code;
  String message;
  bool isFatal;
}
