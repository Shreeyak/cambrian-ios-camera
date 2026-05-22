import CameraKit
import Flutter

// MARK: - Per-stream forwarder subclasses
//
// Pigeon 22.x generates `Stream<T>StreamHandler` classes the adapter must
// subclass. Each subclass holds the `PigeonEventSink<T>` captured at
// `onListen` and releases it on `onCancel`. The send pattern is
// `forwarder.sink?.success(value)`.
//
// The forwarders are owned by the plugin (stored properties on
// CambrianIosCameraPlugin) and registered once at `register(with:)`, BEFORE any
// Dart code subscribes. The Dart facade subscribes in its constructor (before
// `open()`); registering the handlers eagerly guarantees `onListen` fires and
// captures the sink. The engine-iterating Tasks that pump these sinks are
// spawned later, in `startStreamForwarders()` (called from `open()`).
//
// The one `CameraKitLog.notice` in each `onListen` is the diagnostic that
// confirms the fix: if it appears in camerakit.log before "open: ..." lines,
// the sink was captured before open() and no startup events are dropped.

final class StateForwarder: StreamStateStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<SessionState>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<SessionState>) {
        CameraKitLog.notice(.consumers, "[forwarder] state onListen — sink captured")
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class ErrorForwarder: StreamErrorsStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<CameraError>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<CameraError>) {
        CameraKitLog.notice(.consumers, "[forwarder] errors onListen — sink captured")
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class StreamConfigForwarder: StreamStreamConfigurationsStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<StreamConfiguration>?
    override func onListen(
        withArguments arguments: Any?, sink: PigeonEventSink<StreamConfiguration>
    ) {
        CameraKitLog.notice(.consumers, "[forwarder] streamConfigurations onListen — sink captured")
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class FrameResultForwarder: StreamFrameResultsStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<FrameResult>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<FrameResult>) {
        CameraKitLog.notice(.consumers, "[forwarder] frameResults onListen — sink captured")
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class RecordingStateForwarder: StreamRecordingStatesStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<RecordingStateValue>?
    override func onListen(
        withArguments arguments: Any?, sink: PigeonEventSink<RecordingStateValue>
    ) {
        CameraKitLog.notice(.consumers, "[forwarder] recordingStates onListen — sink captured")
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

// MARK: - Stream handler registration + forwarding

extension CambrianIosCameraPlugin {

    /// Registers the five EventChannel stream handlers.
    ///
    /// Called once from `register(with:)`, on the platform/main thread, BEFORE
    /// any Dart code can subscribe. Registering eagerly is what makes the Dart
    /// facade's constructor-time `.listen(...)` succeed: Flutter only delivers
    /// the "listen" (and fires `onListen`, capturing the sink) when a native
    /// handler is already attached. Register late (e.g. in `open()`) and the
    /// first subscription is silently dropped — the sink never fills and the
    /// preview is stuck on "No signal".
    func registerStreamHandlers(messenger: FlutterBinaryMessenger) {
        assert(Thread.isMainThread, "EventChannel handlers must register on the main thread")
        StreamStateStreamHandler.register(with: messenger, streamHandler: stateForwarder)
        StreamErrorsStreamHandler.register(with: messenger, streamHandler: errorForwarder)
        StreamStreamConfigurationsStreamHandler.register(
            with: messenger, streamHandler: streamConfigForwarder)
        StreamFrameResultsStreamHandler.register(with: messenger, streamHandler: frameResultForwarder)
        StreamRecordingStatesStreamHandler.register(
            with: messenger, streamHandler: recordingStateForwarder)
    }

    /// Spawns the five engine-iterating forwarder Tasks.
    ///
    /// Called from `open()` once the engine exists (on the main thread). Each
    /// Task captures the engine and its forwarder via a local (never `self`, to
    /// avoid a retain cycle through `streamTasks`), pulls from the CameraKit
    /// AsyncStream, and emits on the main thread through the already-captured
    /// sink. `close()` cancels every task; cancellation breaks the loops and the
    /// sinks are cleared on `onCancel` when Dart tears its subscriptions down.
    func startStreamForwarders() {
        guard let engine = self.engine else { return }

        let state = self.stateForwarder
        streamTasks.append(
            Task { [engine, state] in
                for await value in await engine.stateStream() {
                    if Task.isCancelled { break }
                    await MainActor.run { state.sink?.success(value.toPigeon()) }
                }
            })

        let errors = self.errorForwarder
        streamTasks.append(
            Task { [engine, errors] in
                for await value in await engine.errorStream() {
                    if Task.isCancelled { break }
                    await MainActor.run { errors.sink?.success(value.toPigeon()) }
                }
            })

        let cfg = self.streamConfigForwarder
        streamTasks.append(
            Task { [engine, cfg] in
                for await value in await engine.streamConfigurationStream() {
                    if Task.isCancelled { break }
                    await MainActor.run { cfg.sink?.success(value.toPigeon()) }
                }
            })

        let frame = self.frameResultForwarder
        streamTasks.append(
            Task { [engine, frame] in
                for await value in await engine.frameResultStream() {
                    if Task.isCancelled { break }
                    await MainActor.run { frame.sink?.success(value.toPigeon()) }
                }
            })

        let rec = self.recordingStateForwarder
        streamTasks.append(
            Task { [engine, rec] in
                for await value in await engine.recordingStateStream() {
                    if Task.isCancelled { break }
                    await MainActor.run { rec.sink?.success(value.toPigeon()) }
                }
            })
    }
}
