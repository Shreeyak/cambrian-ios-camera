# Stage 10 — HITL recording evidence

## 10:mp4-plays-in-photos
Device: iPad Pro M1 (iOS 26.x).
- Record 10s.
- Confirm `.mp4` appears in Photos.
- Playback works.
- `mediainfo` on the file reports `HEVC` codec + `MP4` container.
PASS / FAIL: ________
Date: ________

## 10:low-light-ae-drops-below-30fps
Device: iPad Pro M1 (iOS 26.x).
- Start recording, cover camera sensor.
- Observe FPS drop below 30 (toward 15) in live instrumentation or post-hoc mediainfo.
- Remove occlusion; FPS returns to 30.
PASS / FAIL: ________
Date: ________

## 10:empirical-format-fps-range-fallback (DEFERRED)
Device: iPad Pro M1 (iOS 26.x).
- If target active format does not natively support (1/30, 1/30), record the fallback:
  closest supported range, or which error the device returns.
Observations: ________
Date: ________
