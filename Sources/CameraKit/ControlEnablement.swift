import Foundation

/// Derived UI gating: which controls are enabled and whether the scanning spinner shows.
///
/// Single source of truth per domain `09-ui-behaviors.md` §State-Driven UI. View code
/// derives one `ControlEnablement` from `(sessionState, recordingState)` and reads
/// individual booleans — prevents scattered `if sessionState ==` checks across the view.
///
/// `showScanningAnimation` binds to `SessionState` (J4 resolution), NOT to
/// `focusDistance == nil` — that earlier signal had ambiguous UX during `.streaming`
/// with fast autofocus.
public struct ControlEnablement: Sendable, Hashable {

    public let isRecordEnabled: Bool
    /// Record button switches to "Stop" mode while recording — enabled only then.
    public let isStopEnabled: Bool
    public let isCaptureEnabled: Bool
    public let isResolutionEnabled: Bool
    public let isSettingsEnabled: Bool
    public let isCalibrateEnabled: Bool
    public let showScanningAnimation: Bool

    public init(sessionState: SessionState, recordingState: RecordingState) {
        let isStreaming = sessionState == .streaming
        let isRecording: Bool = {
            if case .recording = recordingState { return true }
            return false
        }()
        let isScanning = (sessionState == .opening || sessionState == .recovering)

        self.showScanningAnimation = isScanning
        self.isSettingsEnabled = isStreaming && !isRecording
        self.isCalibrateEnabled = isStreaming  // sidebar usable during recording
        self.isCaptureEnabled = isStreaming && !isRecording
        self.isResolutionEnabled = isStreaming && !isRecording
        self.isRecordEnabled = isStreaming && !isRecording
        self.isStopEnabled = isStreaming && isRecording
    }
}
