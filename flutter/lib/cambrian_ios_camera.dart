// Public exception type + code enum.
export 'src/camera_exception.dart';

// Static permissions API.
export 'src/permissions.dart' show Permissions, CameraPermissionStatus;

// Engine.
export 'src/camera_engine.dart' show CameraEngine;

// Pigeon-generated value types consumers construct or destructure directly.
// The testing seams in lib/testing.dart are hidden because they are internal.
export 'src/pigeon/cambrian_ios_camera_api.g.dart'
    show
        OpenConfiguration,
        SessionCapabilities,
        CameraSettings,
        ProcessingParameters,
        StreamConfiguration,
        FrameResult,
        RecordingOptions,
        RecordingStart,
        RecordingStateValue,
        RecordingStateKind,
        CalibrationResult,
        RgbSample,
        CameraError,
        PSize,
        PRect,
        PFrameRateRange,
        StreamId,
        SessionState,
        PhotosDestination,
        CameraMode,
        WhiteBalanceMode;
