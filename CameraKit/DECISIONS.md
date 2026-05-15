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

---

## Migration Phase 1A (Flutter migration — UI decoupling)

2026-05-15 [migration-1a task-1] coordinator — CameraEngine.setGate(_:), drainSubmittedFrame(), dumpDeviceFormats() promoted to public. Required by the relocated ViewModel.swift (cross-module). Per spec §2e these are harness-only debug surface (no Pigeon counterpart). Surface curation (demoting other helpers to internal) is gated on Phase 2's calibration move-down and stays deferred.

2026-05-15 [migration-1a task-3] coordinator — CameraKitInterop temporarily exported as a SwiftPM library product so the relocated DisplayViewModel can import CppCannyStub for the DEBUG Canny edge-count overlay. Bridge state; Phase 1B removes the consumer and un-exports. Alternatives rejected: #if DEBUG-stub (regresses overlay between 1A/1B) and 1B-first ordering.

2026-05-15 [migration-1a task-6] coordinator — OrientationLock.swift moved to app target (file #11), not foreseen by the plan-of-record which kept it in package. The file imports SwiftUI for `UIInterfaceOrientationMask` (a UIKit type SwiftUI re-exports). To satisfy the plan's "zero SwiftUI imports in the package" exit gate without weakening Phase 1A's contract, OrientationLock relocates to the app target alongside the SwiftUI files, and its `import SwiftUI` is corrected to `import UIKit` on move. Sole consumer is `eva_swift_stitchApp.swift` (already in app target). User-selected via AskUserQuestion 2026-05-15.

2026-05-15 [migration-1a task-6] coordinator — CameraSettings.merging(onto:) promoted to public alongside the three CameraEngine helpers. Not foreseen by the plan-of-record but caught by the cross-module access audit during Task 6: relocated `HardwareControlsViewModel.swift:47` calls `delta.merging(onto: self.currentSettings)` and would not compile with the method `internal`. CameraSettings is already public; only the extension method needed promotion.

2026-05-15 [migration-1a task-7] coordinator — Stage11Tests.swift split rather than wholesale-relocated (spec §1A said "moves to the app-target test location"). 4 of 9 suites test CameraKit internals (MetalPipeline.*ForTest, SettingsPersistence, Constants.blackBalanceOverscan, MetalError) via @testable import CameraKit and have zero UI refs — they stay dual-membered in CameraKit/Tests/CameraKitTests/Stage11Tests.swift. 5 UI suites + CalibrationEngineStub + ManagedAtomicSafe move to eva-swift-stitchTests/Stage11UITests.swift (single-target — deliberate CLAUDE.md §8 exception). Total test count unchanged: 35 (20 UI + 15 internals). The split itself used sed line-range deletion/extraction rather than the plan's literal `Write` replacement, which had paraphrased the kept suites and would have stripped their inline `//` rationale comments. Per user direction (keep rationale comments).

2026-05-15 [migration-1a task-7] coordinator — CameraKitCxx now explicitly links CoreFoundation (`.linkedFramework("CoreFoundation")`). CannyStubConsumer.cpp references `_kCFAllocatorDefault`. Pre-Phase-1A the app target got CoreFoundation transitively via UIKit and the package test target never linked CameraKitCxx directly, so the gap was latent. Once CameraKitInterop became a direct dependency of `eva-swift-stitchTests` (Task 4 plan addition), the test target's link surfaced the gap as undefined symbols. Alternative considered: remove `CameraKitInterop` from the test target's dependencies (it isn't imported by any test file). Rejected because making CameraKitCxx self-contained for any consumer is the more durable fix.

<!-- new entries go above this line; keep the stage header last -->
