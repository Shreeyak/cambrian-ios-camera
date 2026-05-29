package com.cambrian.cambrian_ios_camera

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * iOS-only plugin. The Android side registers the Pigeon HostApis but every
 * method fails with FlutterError(code = "iOSOnly") — which Pigeon surfaces on
 * the Dart side as PlatformException(code: "iOSOnly"). Each EventChannel emits
 * one error event and closes.
 *
 * This exists so `flutter pub get` accepts the multi-platform plugin and
 * `flutter run` doesn't error on a missing Android implementation. There is no
 * camera functionality on Android.
 */
class CambrianIosCameraPlugin :
    FlutterPlugin,
    CameraEngineHostApi,
    PermissionsHostApi {

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        CameraEngineHostApi.setUp(messenger, this)
        PermissionsHostApi.setUp(messenger, this)

        // EventChannels: each emits one iOSOnly error and ends the stream.
        StreamStateStreamHandler.register(
            messenger,
            object : StreamStateStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<SessionState>) =
                    sink.failIosOnly("state")
            },
        )
        StreamErrorsStreamHandler.register(
            messenger,
            object : StreamErrorsStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<CameraError>) =
                    sink.failIosOnly("errors")
            },
        )
        StreamStreamConfigurationsStreamHandler.register(
            messenger,
            object : StreamStreamConfigurationsStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<StreamConfiguration>) =
                    sink.failIosOnly("streamConfigurations")
            },
        )
        StreamFrameResultsStreamHandler.register(
            messenger,
            object : StreamFrameResultsStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<FrameResult>) =
                    sink.failIosOnly("frameResults")
            },
        )
        StreamRecordingStatesStreamHandler.register(
            messenger,
            object : StreamRecordingStatesStreamHandler() {
                override fun onListen(p0: Any?, sink: PigeonEventSink<RecordingStateValue>) =
                    sink.failIosOnly("recordingStates")
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraEngineHostApi.setUp(binding.binaryMessenger, null)
        PermissionsHostApi.setUp(binding.binaryMessenger, null)
    }

    // CameraEngineHostApi — every method fails.

    override fun open(configuration: OpenConfiguration?, callback: (Result<SessionCapabilities>) -> Unit) =
        callback(Result.failure(iosOnly("open")))

    override fun close(callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("close")))

    override fun currentSettings(callback: (Result<CameraSettings?>) -> Unit) =
        callback(Result.failure(iosOnly("currentSettings")))

    override fun currentProcessingParameters(callback: (Result<ProcessingParameters?>) -> Unit) =
        callback(Result.failure(iosOnly("currentProcessingParameters")))

    override fun updateSettings(settings: CameraSettings, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("updateSettings")))

    override fun setResolution(size: PSize, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("setResolution")))

    override fun setProcessingParams(params: ProcessingParameters, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("setProcessingParams")))

    override fun setCropRegion(rect: PRect, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("setCropRegion")))

    override fun captureImage(outputPath: String?, photosDestination: PhotosDestination, callback: (Result<String>) -> Unit) =
        callback(Result.failure(iosOnly("captureImage")))

    override fun captureNaturalPicture(outputPath: String?, photosDestination: PhotosDestination, callback: (Result<String>) -> Unit) =
        callback(Result.failure(iosOnly("captureNaturalPicture")))

    override fun startRecording(options: RecordingOptions, callback: (Result<RecordingStart>) -> Unit) =
        callback(Result.failure(iosOnly("startRecording")))

    override fun stopRecording(callback: (Result<String>) -> Unit) =
        callback(Result.failure(iosOnly("stopRecording")))

    override fun calibrateWhiteBalance(callback: (Result<CalibrationResult>) -> Unit) =
        callback(Result.failure(iosOnly("calibrateWhiteBalance")))

    override fun calibrateBlackBalance(callback: (Result<CalibrationResult>) -> Unit) =
        callback(Result.failure(iosOnly("calibrateBlackBalance")))

    override fun createPreviewTexture(stream: StreamId, callback: (Result<Long>) -> Unit) =
        callback(Result.failure(iosOnly("createPreviewTexture")))

    override fun destroyPreviewTexture(textureId: Long, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(iosOnly("destroyPreviewTexture")))

    // PermissionsHostApi — every method fails.

    override fun cameraPermissionStatus(callback: (Result<CameraPermissionStatus>) -> Unit) =
        callback(Result.failure(iosOnly("cameraPermissionStatus")))

    override fun requestCameraPermission(callback: (Result<CameraPermissionStatus>) -> Unit) =
        callback(Result.failure(iosOnly("requestCameraPermission")))
}

/** A FlutterError that Pigeon surfaces to Dart as PlatformException(code: "iOSOnly"). */
private fun iosOnly(method: String): FlutterError =
    FlutterError(
        code = "iOSOnly",
        message = "cambrian_ios_camera is iOS-only; $method has no Android implementation",
        details = null,
    )

/** Emits a single iOSOnly error on an event channel, then closes the stream. */
private fun <T> PigeonEventSink<T>.failIosOnly(streamName: String) {
    error(
        "iOSOnly",
        "cambrian_ios_camera is iOS-only; $streamName stream has no Android implementation",
        null,
    )
    endOfStream()
}
