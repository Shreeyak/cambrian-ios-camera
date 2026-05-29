# Stage 09 — HITL recovery evidence

## 09:recovery-banner-on-simulated-capture-failure
Device: iPad Pro M1 (iOS 26.x).
- Triggered via LLDB pause (5s frame delivery gap fired capture watchdog).
- FRAME_STALL banner appeared correctly with code + message.
- Non-fatal banner path (errorStream → ViewModel → CameraView) confirmed live.
PASS / FAIL: PASS
Date: 2026-04-24

## 09:camera-in-use-self-heal-device
Device: iPad Pro M1 (iOS 26.x).
- Switched to system Camera app while eva-swift-stitch was in foreground.
- CAMERA_IN_USE interruption notification did not fire in time (or not at all).
- Watchdogs timed out instead: GPU stall banner at ~3s, capture stall at ~5s.
- Recovery loop entered and attempted open() while camera was locked.
- App crashed before MAX_RETRIES_EXCEEDED alert could render.
PASS / FAIL: FAIL
Date: 2026-04-24
Bug: recovery loop does not detect camera-in-use during retry; exhausts retries
and crashes rather than emitting fatal alert cleanly. Logged as open issue for
Stage 10. CAMERA_IN_USE notification path unreliable on this device/iOS version.
