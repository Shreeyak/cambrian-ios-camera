import CameraKit
import Foundation

/// Routes engine errors to the correct UI surface (toast vs blocking dialog).
///
/// Domain `09-ui-behaviors.md` §Error display:
///   - Non-fatal `CameraError` → `currentToast`, auto-dismiss after `≥3 s`.
///   - Fatal (`isFatal == true`) `CameraError` → `fatalDialog`, no auto-dismiss
///     until user picks Retry or Dismiss.
///
/// Brief §8 TESTABLEs `11:non-fatal-error-shows-toast` /
/// `11:fatal-error-shows-blocking-dialog`. The `_feedErrorForTest` seam exists
/// so tests don't need to drive the engine's error stream.
@Observable @MainActor
final class ErrorPresenterViewModel {

    /// Non-fatal — auto-dismisses after `≥3 s`.
    var currentToast: CameraError?
    /// Fatal — stays until user dismisses or retries.
    var fatalDialog: CameraError?

    @ObservationIgnored private var errorConsumerTask: Task<Void, Never>?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
    }

    /// Subscribe to `engine.errorStream()`; route by `isFatal`.
    func start() async {
        errorConsumerTask?.cancel()
        errorConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await err in await self.engine.errorStream() {
                await MainActor.run { self.handleError(err) }
            }
        }
    }

    func stop() async {
        errorConsumerTask?.cancel()
        errorConsumerTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
    }

    // MARK: - Public actions for the fatal-dialog UI

    /// Just clear the dialog — invoked from the alert's "Dismiss" button.
    ///
    /// "Retry" in the alert hops to the parent `ViewModel.retryFromFatal()`
    /// because lifecycle orchestration (close+reopen + display re-attach)
    /// belongs there, not here.
    func dismissFatal() {
        fatalDialog = nil
    }

    /// Route an error to the correct surface (toast vs blocking dialog).
    ///
    /// For errors raised by sibling view models (e.g. `RecordingViewModel`'s
    /// caught `startRecording` / `stopRecording` failures) that never reach the
    /// engine's `errorStream()`.
    func present(_ err: CameraError) {
        handleError(err)
    }

    // MARK: - Test seam

    /// Test-only: feed an error directly without touching the engine stream.
    ///
    /// Brief §8 TESTABLEs `11:non-fatal-error-shows-toast` /
    /// `11:fatal-error-shows-blocking-dialog` rely on this.
    func _feedErrorForTest(_ err: CameraError) {
        present(err)
    }

    // MARK: - Private

    private func handleError(_ err: CameraError) {
        if err.isFatal {
            fatalDialog = err
        } else {
            currentToast = err
            toastDismissTask?.cancel()
            toastDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.currentToast = nil }
            }
        }
    }
}
