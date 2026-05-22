import CameraKit
import Flutter

// MARK: - Per-stream forwarder subclasses
//
// Pigeon 22.x generates `Stream<T>StreamHandler` classes the adapter must
// subclass. Each subclass holds the `PigeonEventSink<T>` captured at
// `onListen` and releases it on `onCancel`. The send pattern is
// `forwarder.sink?.success(value)`.
//
// Forwarders are kept alive by the Task closures that hold them
// (subscribeAllStreams below); when the Task ends (close() cancels it),
// the closure is released and the forwarder is deallocated, which
// detaches the FlutterEventChannel handler.

final class StateForwarder: StreamStateStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<SessionState>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<SessionState>) {
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class ErrorForwarder: StreamErrorsStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<CameraError>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<CameraError>) {
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
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

final class FrameResultForwarder: StreamFrameResultsStreamHandler, @unchecked Sendable {
    var sink: PigeonEventSink<FrameResult>?
    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<FrameResult>) {
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
        self.sink = sink
    }
    override func onCancel(withArguments arguments: Any?) {
        self.sink = nil
    }
}

// MARK: - subscribeAllStreams

extension CambrianIosCameraPlugin {

    /// Spawns the five per-stream forwarder Tasks.
    ///
    /// Called from `open()` once the engine has been constructed. Each Task
    /// captures its forwarder strongly so the forwarder lives as long as the
    /// Task is in `streamTasks`. `close()` cancels every task, which releases
    /// the forwarder closures and detaches the FlutterEventChannel handlers.
    ///
    /// If the Dart side subscribes BEFORE `open()` (the broadcast-cached-stream
    /// pattern in the Dart facade does exactly this), `forwarder.sink` is
    /// already set by the time these Tasks start iterating, so no events are
    /// dropped at startup.
    func subscribeAllStreams() {
        guard let engine = self.engine else { return }
        let messenger = registrar.messenger()

        let stateForwarder = StateForwarder()
        StreamStateStreamHandler.register(with: messenger, streamHandler: stateForwarder)
        streamTasks.append(
            Task { [engine, stateForwarder] in
                for await state in await engine.stateStream() {
                    if Task.isCancelled { break }
                    stateForwarder.sink?.success(state.toPigeon())
                }
            })

        let errorForwarder = ErrorForwarder()
        StreamErrorsStreamHandler.register(with: messenger, streamHandler: errorForwarder)
        streamTasks.append(
            Task { [engine, errorForwarder] in
                for await err in await engine.errorStream() {
                    if Task.isCancelled { break }
                    errorForwarder.sink?.success(err.toPigeon())
                }
            })

        let cfgForwarder = StreamConfigForwarder()
        StreamStreamConfigurationsStreamHandler.register(
            with: messenger, streamHandler: cfgForwarder)
        streamTasks.append(
            Task { [engine, cfgForwarder] in
                for await cfg in await engine.streamConfigurationStream() {
                    if Task.isCancelled { break }
                    cfgForwarder.sink?.success(cfg.toPigeon())
                }
            })

        let frameForwarder = FrameResultForwarder()
        StreamFrameResultsStreamHandler.register(with: messenger, streamHandler: frameForwarder)
        streamTasks.append(
            Task { [engine, frameForwarder] in
                for await fr in await engine.frameResultStream() {
                    if Task.isCancelled { break }
                    frameForwarder.sink?.success(fr.toPigeon())
                }
            })

        let recForwarder = RecordingStateForwarder()
        StreamRecordingStatesStreamHandler.register(with: messenger, streamHandler: recForwarder)
        streamTasks.append(
            Task { [engine, recForwarder] in
                for await rs in await engine.recordingStateStream() {
                    if Task.isCancelled { break }
                    recForwarder.sink?.success(rs.toPigeon())
                }
            })
    }
}
