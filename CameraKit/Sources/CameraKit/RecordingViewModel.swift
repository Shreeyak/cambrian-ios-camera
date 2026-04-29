import Foundation

/// Recording-state view model: owns `RecordingState` mirror, the wall-clock timer,
/// and the start/stop action.
///
/// Subscribes to `engine.recordingStateStream()` so external state transitions
/// (e.g. file truncation rolling back to `.idle`) reach the UI without a parent
/// hop. Owns its own elapsed-seconds counter started/stopped by the stream's
/// `.recording` / non-`.recording` transitions.
@Observable @MainActor
final class RecordingViewModel {

    var recordingState: RecordingState = .idle(lastUri: nil)
    var recordingElapsedSeconds: Int = 0

    @ObservationIgnored private var recordingStateTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTimerTask: Task<Void, Never>?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Subscribe to the recording-state stream; auto-start/stop the timer on transitions.
    func start() async {
        recordingStateTask?.cancel()
        recordingStateTask = Task { [weak self] in
            guard let self else { return }
            for await s in await self.engine.recordingStateStream() {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.recordingState = s
                    switch s {
                    case .recording:
                        self.startRecordingTimer()
                    default:
                        self.recordingTimerTask?.cancel()
                        self.recordingTimerTask = nil
                        if case .idle = s { self.recordingElapsedSeconds = 0 }
                    }
                }
            }
        }
    }

    /// Cancel subscription + timer.
    func stop() async {
        recordingStateTask?.cancel()
        recordingStateTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
    }

    /// Toggle between `.idle` → start, `.recording` → stop.
    ///
    /// Other states (e.g. `.finalizing`, `.paused`) no-op.
    func toggleRecording() {
        Task { [weak self] in
            guard let self else { return }
            switch self.recordingState {
            case .idle:
                _ = try? await self.engine.startRecording(options: RecordingOptions())
            case .recording:
                _ = try? await self.engine.stopRecording()
            default:
                break
            }
        }
    }

    // MARK: - Private

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingElapsedSeconds = 0
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { [weak self] in
                    self?.recordingElapsedSeconds += 1
                }
            }
        }
    }
}
