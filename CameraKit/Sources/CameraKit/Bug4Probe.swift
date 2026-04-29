// Bug 4 instrumentation — `processedTex` long-session freeze investigation.
//
// TEMPORARY. Pre-Stage-12 HITL. Revert by deleting this file plus the
// `Bug4Probe.*` call sites in `MetalPipeline.swift` and `CameraView.swift`.
//
// See `docs/stage-11-pre-existing-bugs.md` Bug 4. The right-side preview
// (processed lane) was observed to freeze for 2-3 minutes during the Stage 11
// regression run while natural and tracker streams kept flowing. Hypotheses
// (silent Pass 2 fail / processed pool exhaustion / uniforms.withLock
// contention / mailbox race) are unverified. This probe collects the
// time-series data needed to discriminate.

import Atomics
import Foundation

enum Bug4Probe {

    // Master switch — flip to `false` to make every entry point a no-op.
    nonisolated(unsafe) static var enabled: Bool = true

    // Halt flag — when true, MetalPipeline.encode() skips Pass 2 dispatch.
    static let halted = ManagedAtomic<Bool>(false)

    // Counters (delivery queue + completion-handler queue both touch them).
    static let frameSeen = ManagedAtomic<UInt64>(0)
    static let pass2OkCount = ManagedAtomic<UInt64>(0)
    static let pass2ErrCount = ManagedAtomic<UInt64>(0)
    static let processedDequeueFailCount = ManagedAtomic<UInt64>(0)
    static let lastPass2OkFrame = ManagedAtomic<UInt64>(0)
    static let lastHeartbeatFrame = ManagedAtomic<UInt64>(0)

    // Heartbeat cadence — every N frames, log a snapshot. ~1 s @ 30 fps.
    static let heartbeatStrideFrames: UInt64 = 30

    /// Called per-frame at the top of `encode()` (delivery queue).
    static func noteEncodeEntered(frame: UInt64) {
        guard enabled else { return }
        frameSeen.store(frame, ordering: .relaxed)
    }

    /// Called when the processed pool dequeue throws.
    static func noteProcessedDequeueFailed() {
        guard enabled else { return }
        processedDequeueFailCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Called from the command-buffer completion handler after a successful encode.
    ///
    /// Pass 2 counts as "OK" only if the halt flag is not set — a halted Pass 2
    /// did not actually run.
    static func notePass2OkInCompletion(frame: UInt64) {
        guard enabled else { return }
        if halted.load(ordering: .acquiring) { return }
        pass2OkCount.wrappingIncrement(ordering: .relaxed)
        lastPass2OkFrame.store(frame, ordering: .relaxed)
    }

    /// Called from the command-buffer completion handler when `cb.status == .error`.
    static func notePass2Err(frame: UInt64, code: Int) {
        guard enabled else { return }
        pass2ErrCount.wrappingIncrement(ordering: .relaxed)
        let line = "[bug4][pass-err] frame=\(frame) code=\(code)"
        CameraKitLog.write(line)
        CameraKitLog.metal.warning("\(line, privacy: .public)")
    }

    /// Heartbeat — call after the FrameSet publish in the completion handler.
    ///
    /// Logs a snapshot every `heartbeatStrideFrames` frames; cheap otherwise.
    static func tickHeartbeat(frame: UInt64) {
        guard enabled else { return }
        let last = lastHeartbeatFrame.load(ordering: .relaxed)
        if frame &- last < heartbeatStrideFrames { return }
        lastHeartbeatFrame.store(frame, ordering: .relaxed)
        let okN = pass2OkCount.load(ordering: .relaxed)
        let errN = pass2ErrCount.load(ordering: .relaxed)
        let lastOk = lastPass2OkFrame.load(ordering: .relaxed)
        let dqFail = processedDequeueFailCount.load(ordering: .relaxed)
        let stale = frame &- lastOk
        let isHalted = halted.load(ordering: .acquiring)
        let line =
            "[bug4][heartbeat] frame=\(frame) p2ok=\(okN) p2err=\(errN) "
            + "lastP2OkFrame=\(lastOk) staleFrames=\(stale) "
            + "procDequeueFail=\(dqFail) halted=\(isHalted)"
        CameraKitLog.write(line)
        CameraKitLog.metal.info("\(line, privacy: .public)")
    }

    /// Manual halt — called from the DEBUG button in `CameraView`.
    ///
    /// Logs full state at the moment of declared freeze and flips the halt flag
    /// so subsequent encodes skip Pass 2. The visible processed preview will
    /// then stay frozen on whatever the latest mailbox texture pointed to.
    static func dumpAndHalt(reason: String) {
        guard enabled else { return }
        let frame = frameSeen.load(ordering: .relaxed)
        let okN = pass2OkCount.load(ordering: .relaxed)
        let errN = pass2ErrCount.load(ordering: .relaxed)
        let lastOk = lastPass2OkFrame.load(ordering: .relaxed)
        let dqFail = processedDequeueFailCount.load(ordering: .relaxed)
        let stale = frame &- lastOk
        let line =
            "[bug4][halt reason=\(reason)] frame=\(frame) "
            + "p2ok=\(okN) p2err=\(errN) lastP2OkFrame=\(lastOk) "
            + "staleFrames=\(stale) procDequeueFail=\(dqFail)"
        CameraKitLog.write(line)
        CameraKitLog.metal.warning("\(line, privacy: .public)")
        halted.store(true, ordering: .releasing)
    }

    /// Resume Pass 2 (clears the halt flag).
    ///
    /// DEBUG-only utility.
    static func resume() {
        halted.store(false, ordering: .releasing)
        let line = "[bug4][resume] halt cleared"
        CameraKitLog.write(line)
        CameraKitLog.metal.info("\(line, privacy: .public)")
    }
}
