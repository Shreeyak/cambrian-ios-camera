# Stage 09 — HITL recovery evidence

## 09:recovery-banner-on-simulated-capture-failure
Device: iPad Pro M1 (iOS 26.x).
- Force CAPTURE_FAILURE via test-only debug toggle.
- Observe orange recovery banner with code + message.
- Observe backoff sequence: retries at ~500ms, 1s, 2s, 4s, 8s.
- On 6th failure, fatal alert appears; state stays in .error.
PASS / FAIL: ________
Date: ________

## 09:camera-in-use-self-heal-device
Device: iPad Pro M1 (iOS 26.x).
- Open FaceTime while app is in foreground.
- Observe fatal CAMERA_IN_USE error alert.
- Close FaceTime.
- Observe app auto-returns to .closed (no host action).
- Tap Resume → preview returns.
PASS / FAIL: ________
Date: ________
