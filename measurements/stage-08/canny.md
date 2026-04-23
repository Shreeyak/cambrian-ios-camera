# Stage 08 HITL Evidence

## 08:external-canny-stub-runs-on-device

Status: PASS

Device: iPad Pro M1 (Shreeyak's iPad, DAD37FD5-685B-50E0-911E-F9BC40BBDBE5)
OpenCV version: v4.13 (Frameworks/opencv2.xcframework, static library)
Date: 2026-04-23
Observer: Shreeyak

### Protocol
1. Build and install app on device
2. `CppCannyStub` registered automatically on `.tracker` stream at session open (DEBUG build)
3. Debug overlay (top-left) shows `edges=NNNN` updating every 10 `.natural` frames
4. Natural/processed preview unaffected — Canny runs only on tracker stream

### Evidence
- Edge count range observed: non-zero, time-varying as camera panned across scene
- Natural/processed preview undisturbed during Canny operation: YES
- No crashes over session: YES (confirmed via log — no process termination in crash logs)
- Log confirms: `registerCallback: stream=2 token=1 cppCount=1` at startup; `stream=2 cppConsumers=1` on every sampled tracker frame

### Notes
- Tracker pool format is `kCVPixelFormatType_64RGBAHalf`; Canny stub converts via:
  `CV_16FC4 → CV_32FC4 → CV_32FC1 (cvtColor RGBA2GRAY) → CV_8UC1 (×255) → Canny`
- Debug overlay shows edge count as text (`edges=N`); full edge bitmap render is out of scope for Stage 08
