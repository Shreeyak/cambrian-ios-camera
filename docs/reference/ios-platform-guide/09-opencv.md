# 09 — OpenCV Integration

OpenCV (C++, via direct Swift↔C++ interop per ADR-11) is the computer-vision
framework for this app. Do not reach for Apple's Vision framework — OpenCV is
not a fallback or a PoC choice here, it is the chosen tool.

---

## ADR-29: OpenCV is the CV framework; Vision framework is not used

**Decision.** All CV work in this app uses OpenCV. The edge-detection consumer
proves the Swift↔C++ integration path end-to-end on a real workload
(`cv::Canny`). Future CV consumers follow the same `PixelSink`-shaped C++
pattern established here.

**No Vision.** Do not substitute Vision framework APIs for any task this app
needs. Do not suggest Vision as an alternative or a simpler path. The C++
integration path is the product requirement, not a workaround.

### Consumer integration pattern

A C++ CV consumer subscribes to a frame stream via the `PixelSink` fanout
(ADR-13). It receives IOSurface-backed frames from `FrameSet` (ADR-18),
processes them in C++, and publishes results via a C-ABI callback (ADR-11).

The edge-detection consumer is the reference shape:

1. Subscribe to the tracker stream (~480p — fits the Canny budget of 2–4ms on
   A16; see G-23).
2. `IOSurfaceLock` the buffer, construct a zero-copy `cv::Mat` view using
   `IOSurfaceGetBytesPerRow(surface)` as the stride argument (`width * bpp` is wrong
   under hardware alignment padding — see `06-gotchas.md` G-34), run `cv::Canny`,
   `IOSurfaceUnlock`.
3. Write the composited result into the pre-allocated shared `MTLTexture`.
4. Fire the C-ABI write-complete callback; Swift schedules a Metal blit pass
   (`generateMipmaps(for:)`).

The mailbox discipline (drop-on-busy, `overwriteCount_` counter per ADR-13 and
ADR-19) applies to every C++ consumer identically.

### When to add another C++ consumer

- The algorithm is not achievable in Metal compute alone.
- The algorithm has a C++ implementation shared across iOS, Android, or backend.
- The consumer joins the existing `PixelSink` fanout — IOSurface-backed textures
  are already in place per ADR-20; the incremental cost of a new consumer is low.

---

## Cross-refs

- Swift↔C++ interop pattern: ADR-11, `05-interop.md`.
- Consumer contract (drop-on-busy, mailbox, observability): ADR-13, ADR-19.
- IOSurface-backed texture storage: ADR-20, G-25.
- Tracker stream sizing and CV budget: G-23.
- `cv::Mat` over IOSurface — stride must be `IOSurfaceGetBytesPerRow`, not `width * bpp`: G-34, `06-gotchas.md`.
