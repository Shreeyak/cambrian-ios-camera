# Stage 02 — ScenePhase HITL Evidence

Device: iPad (A16) — iPad15,7, iOS 26.4.1
Date: 2026-04-21
Build: Stage 02 (eva-swift-stitch, scheme eva-swift-stitch, device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5)

---

## 02:notification-banner-freezes-preview

**Procedure:** Swipe down to open Notification Center / Control Center while camera preview is live. Observe preview. Dismiss. Observe again.

**Result: PASS**

- Preview froze on last frame while Notification Center was visible. ✓
  - Confirms `.inactive` → `setGate(false)` fires, `MetalPipeline.encode()` suppresses `commandBuffer.commit()` per ADR-09 / D-06 strict policy.
- Preview resumed immediately after dismissing Notification Center. ✓
  - Confirms `.active` (returning from `.inactive`) → `setGate(true)` fires, commits resume.
- No crash, no visible artifacts. ✓

---

## 02:background-stops-session-cleanly

**Procedure:** Press Home to background the app. Observe for crash / error. Return to app. Observe preview.

**Result: PASS (with expected Stage 02 limitation)**

- No crash or error popup on backgrounding. ✓
  - Confirms `backgroundSuspend()` correctly closed the gate before stopping `AVCaptureSession`, preventing `MTLCommandBufferErrorNotPermitted IOAF 6` process termination.
- No `MTLCommandBufferErrorNotPermitted` error observed. ✓
- Preview is frozen (black / last frame) after returning to foreground. ✓ (expected)
  - `backgroundResume()` intentionally only re-opens the GPU submission gate. Session restart via `AVCaptureSessionInterruptionEnded` is not wired in Stage 02 (arrives in a later stage). See state.md Decision #9.
  - The brief §8 description ("preview resumes within one frame") describes the eventual-stage behavior once the interruption-ended observer is wired.

---

## Summary

| Test ID | Status | Notes |
|---------|--------|-------|
| `02:notification-banner-freezes-preview` | PASS | Gate closes/opens correctly on Notification Center |
| `02:background-stops-session-cleanly` | PASS (partial) | No crash; preview freeze on return is expected in Stage 02 (no startRunning on resume until later stage) |
