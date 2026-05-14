# DECISIONS.md

Append-only stigmergy log. Subagents add one-line entries for decisions or assumptions they don't want to litigate in return text. Coordinator doesn't re-read this file during a stage; the next subagent glances at it before its task.

Format:
```
YYYY-MM-DD [stage-NN task-M] agent-id — one-line decision or assumption
```

Compaction: at stage boundaries, fold entries into `state.md`'s "Decisions taken that weren't in briefs" section, then truncate below the stage separator.

---

## Stage 02 (complete — folded into state.md §Decisions)

No subagent entries this stage; coordinator worked inline.

---

## Stage 08 (complete)

35. **Dual-dispatch yield() chosen over full C++ routing (Stage 08).** Brief D-01 says
    "Swift-side subscribe() is a facade over the same C++ pool." Full C++ routing would
    require reassembling a FrameSet (Swift multi-buffer struct) from per-stream surface
    pointer + metadata in a C-ABI callback — this loses capture/processing metadata
    fidelity and requires a parallel C++ metadata channel. Dual-dispatch (Swift AsyncStream
    subscribers use their existing path; C++ pool consumers are dispatched separately from
    yield()) satisfies all TESTABLE tests including 08:swift-subscribe-is-facade-over-cpp-pool
    (observable equivalence: both paths receive the same frame numbers in order).

36. **CannyStubConsumer uses real OpenCV Canny (Stage 08).** OpenCV v4.13 xcframework
    available at ~/software/opencv2.framework. Converted from versioned macOS-style framework
    to flat iOS-style xcframework (lipo arm64-thin + xcodebuild -create-xcframework).
    CannyStubConsumer.cpp runs cv::Canny with thresholds 50/150 on each tracker frame;
    edge pixel count stored in 64-entry ring buffer per ADR-29.
    HITL 08:external-canny-stub-runs-on-device is PENDING device run.

37. **InteropError.notWired removed; invalidCallbacks is the new guard (Stage 08).**
    notWired existed only as a scaffolding error. Real registerCallback validates both
    onFrame (required per D-03) and onOverwrite and throws invalidCallbacks for nil values.
    Stage06Tests updated accordingly.

38. **ADR-13 C++ interop containment not achievable with current Swift semantics (Stage 08).**
    Swift propagates .interoperabilityMode(.Cxx) transitively to every importer regardless
    of whether C++ types appear in the public API. CameraKit, eva-swift-stitch app, and
    eva-swift-stitchTests all required -cxx-interoperability-mode=default added to
    OTHER_SWIFT_FLAGS. Flag for upstream ADR-13 revision.

---

## Stage 08

2026-04-23 [stage-08 hitl] coordinator — CannyStubConsumer extended to handle kCVPixelFormatType_64RGBAHalf (tracker pool format): CV_16FC4 → CV_32FC4 → cvtColor(RGBA2GRAY) → CV_8UC1 → Canny. Previous else-branch returned 0 for all tracker frames.
2026-04-23 [stage-08 hitl] coordinator — CppCannyStub wired to tracker stream in ViewModel.start() (DEBUG only); edge count read from ring buffer and displayed as text in debug overlay every 10 natural frames.

2026-05-08 [stage-09 bugfix] coordinator — fpsDegradedThresholdFps (fixed 15.0 floor) replaced by fpsDegradedFraction=0.8: threshold = expectedFps×0.8, where expectedFps=min(1e9/exposureNs, targetFps) in manual mode and targetFps in auto mode. Long exposure times are intentional; the 15fps hardcoded floor wrongly fired on valid 13fps delivery from a 75ms shutter setting.

2026-05-14 [stage-11 followup] coordinator — Gap 1 (recording start/stop failures invisible to UI): routed RecordingViewModel's caught errors through ErrorPresenterViewModel.present(_:) → top toast, NOT the plan's suggested bottom-banner (ViewModel.captureResult) pattern. Rationale: single error surface, unified with engine errorStream() failures. RecordingViewModel.init now takes errorPresenter:; ViewModel.init creates `errors` before `recording` to wire it.

2026-05-14 [stage-11 followup] coordinator — Unified error surface (per user): captureImage() failures now route to ErrorPresenterViewModel.present(_:) → top toast too, matching recording failures. `ViewModel.captureResult: Result<StillCaptureOutput,Error>?` narrowed+renamed to `captureConfirmation: StillCaptureOutput?` (success-only) — the `.failure` case is dead. captureBanner is now a success-only green confirmation; the red "Capture failed" bottom banner is gone (errors are top toasts only).

2026-05-14 [stage-11 followup] coordinator — Capture-success confirmation moved from bottom safeAreaInset to a top toast (`captureToast`, green checkmark), stacked in a VStack with `errorToast` under one `.overlay(alignment:.top)`. Kept structurally separate from the error toast per user: own state (`captureConfirmation`), own styling — NOT folded into ErrorPresenterViewModel (which is CameraError-typed). Bottom-edge stack is now expandedBar + bottomBar only. Removed dead `ViewModel.error: EngineError?` (write-only field superseded by ErrorPresenterViewModel).

<!-- new entries go above this line; keep the stage header last -->
