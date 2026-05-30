# iOS Platform Guide

Platform-level architectural decisions and gotchas behind **CameraKit**, this
repo's iOS camera package — an app pipeline of the shape: real-time camera →
Metal → optional C++ consumers → SwiftUI.

This guide is the reference for the `ADR-##` (architectural decision) and `G-##`
(gotcha) identifiers cited in comments throughout CameraKit's Swift sources. When
a comment says `// ADR-30` or `G-25`, this is where you look up what it means and
why it's done that way. The two index tables below map every ID to its decision
and the chapter that explains it in full.

## Scope

Covers the platform-level "how iOS behaves" rules that any app of this shape must
follow: AVFoundation capture, Metal rendering, zero-copy bridges, Swift–C++
interop, Swift 6 concurrency, scenePhase/lifecycle, and interruption handling.

Does NOT cover CameraKit's own API surface, module layout, or product-specific
decisions (`D-##`). For those, read `CameraKit/CONTRACTS.md` (current public +
internal shape), `CameraKit/DECISIONS.md` (decision log), and `CameraKit/state.md`
(build history).

## Files

| File | Contains |
|---|---|
| `01-architecture.md` | Two-file baseline; direct GPU outputs vs async consumers; per-frame command graph |
| `02-concurrency.md` | Isolation topology, Sendable rules, Metal background submission, scenePhase, approachable concurrency, AsyncStream buffering, Task cancellation |
| `03-metal.md` | Zero-copy via `CVMetalTextureCache`, working pixel format, GPU→encoder path, command-buffer error handling |
| `04-avfoundation.md` | `AVCaptureSession` serial queue, KVO → `AsyncStream`, interruption reasons, orientation |
| `05-interop.md` | Swift ↔ C++ direct interop, exception discipline, `SWIFT_SHARED_REFERENCE` |
| `06-gotchas.md` | Quick-reference failure modes and API pitfalls |
| `07-code-style.md` | Swift naming, golden-path, self-omission, trailing-closure rules; error type discipline |
| `08-ios26-and-ui.md` | iOS 26 deployment target, no custom Liquid Glass, SwiftUI `.task` lifecycle rule |
| `09-opencv.md` | OpenCV is the CV framework; Vision framework is not used; consumer integration pattern |

## ADR Index

Every architectural decision has a stable `ADR-##` identifier, cited by ID in
CameraKit's Swift source comments (and in `CameraKit/CONTRACTS.md` / `state.md`).
The `File` column points to the chapter with the full rationale.

| ID | Decision | File |
|---|---|---|
| ADR-01 | Two-file baseline: `CameraView.swift` + `CameraEngine.swift` | 01 |
| ADR-02 | Single heavy isolation domain: one `actor` for all stateful work | 01, 02 |
| ADR-03 | Distinguish direct GPU outputs from async consumers | 01 |
| ADR-04 | One `CVMetalTextureCache`, created once, flushed on memory warning | 03 |
| ADR-05 | Working format `rgba16Float` for multi-stage color pipelines | 03 |
| ADR-06 | GPU→encoder via IOSurface-backed `CVPixelBufferPool` + compute pass (RGBA16F→NV12) | 03 |
| ADR-07 | Dedicated serial queue for `AVCaptureSession`, not `@MainActor` or the engine actor | 02, 04 |
| ADR-08 | scenePhase: `.background` stops session; `.inactive` gates GPU submission | 02 |
| ADR-09 | Metal background rule: atomic submission gate + `waitUntilScheduled()` | 02 |
| ADR-10 | Sendable strategy: non-Sendable types never cross actors; `sending` where transferred | 02 |
| ADR-11 | Swift ↔ C++ direct interop with `.interoperabilityMode(.Cxx)`; no Objective-C++ | 05 |
| ADR-12 | C++ exceptions caught at the facade; public methods `noexcept` | 05 |
| ADR-13 | Async consumers only: 1-slot mailbox, drop-on-busy; preview is inviolable | 01, 05 |
| ADR-14 | Device state delivered to UI via KVO → `AsyncStream` adapter | 04 |
| ADR-15 | `CVMetalTextureGetTexture` can return nil on success — always nil-check | 03, 06 |
| ADR-16 | `AVAssetWriter` + `InputPixelBufferAdaptor` for Metal recording (not `MovieFileOutput`) | 03 |
| ADR-17 | Orientation via `AVCaptureConnection.videoRotationAngle` (not shader UV transform) | 04 |
| ADR-18 | Frame set publication: one atomic `FrameSet` carries natural + processed + tracker IOSurface refs, capture metadata, processing metadata, and tracker signals | 05 |
| ADR-19 | Pool sizing (`N+1`), latest-wins mailboxes, per-lane drop counters | 05 |
| ADR-20 | PixelSink texture storage mode is dynamic: `.private` by default, flips to `.shared` (IOSurface-backed) on consumer attach, rotates back on all-unsubscribe | 03 |
| ADR-21 | Approachable Concurrency (SE-0466) — default MainActor isolation; engine remains an explicit `actor` | 02 |
| ADR-22 | `AsyncStream` buffering is explicit: `.bufferingNewest(1)` for frame-rate streams, `.bufferingOldest(64)` for state streams; `.unbounded` forbidden | 02 |
| ADR-23 | Task cancellation is enforced: `try Task.checkCancellation()` per iteration; engine-owned tasks stored + cancelled in `close()`/`deinit` | 02 |
| ADR-24 | Swift style: naming, golden-path, self-omission, trailing-closure-single-arg-only, typed empty collections | 07 |
| ADR-25 | Error type discipline: every public-API throwable uses a named module-scoped `enum: Error`; no untyped strings, no `NSError` | 07 |
| ADR-26 | Deployment target iOS 26.0; no `@available` back-deploy scaffolding; no custom Liquid Glass | 08 |
| ADR-28 | SwiftUI `.task` (not `onAppear` + manual `Task`) for async view-lifetime work; pairs with ADR-23 | 08 |
| ADR-29 | OpenCV is the CV framework; Vision framework is not used | 09 |
| ADR-30 | AVCaptureSession lifecycle via async with timeout; never sessionQueue.sync from MainActor | 04 |
| ADR-31 | Swift-subclassing C++ abstract class is unproven; spike first, C-ABI callback struct as fallback | 05 |
| ADR-32 | CaptureDeviceProviding dependency-injection seam for testability | 01 |
| ADR-33 | Testing strategy: Swift Testing for unit, XCTest for integration; CaptureDeviceProviding as seam | 07 |

## Gotchas Index (G-##)

Quick-reference index for `06-gotchas.md`. Each entry is a platform fact that will
crash or silently degrade the app if missed.

See `06-gotchas.md` for full descriptions. Each `G-##` is cited by ID in CameraKit's
Swift source comments and cross-referenced elsewhere in this guide.

| ID | Pitfall |
|---|---|
| G-25 | `.private` texture has nil `.iosurface` → PixelSink fanout silently drops frames (ADR-20) |
| G-26 | PixelSink consumer without per-stream drop counter → overwrite drops invisible under throttling (ADR-13, ADR-19) |
| G-27 | `@unchecked Sendable` silences the diagnostic but not the data race (ADR-10) |
| G-28 | `Task.isCancelled` without `throw` silently ignores cancellation (ADR-23, ADR-28) |
| G-29 | `PhotosPicker` requires no `NSPhotoLibraryUsageDescription`; adding one unnecessarily = review friction (pairs with G-04, G-24) |
| G-30 | Actor re-entrancy across `await` — state can change between suspension points; never assume equality across `await` (ADR-10) |
| G-31 | Raw `Task { @MainActor }` on hot-path delegates is fragile (ADR-22) |
| G-32 | `MTLBlitCommandEncoder.copy` does not format-convert; RGBA16F → BGRA8 must be render/compute (ADR-05, ADR-06) |
| G-33 | Label `MTLCommandBuffer`s and `pushDebugGroup`/`popDebugGroup` for Xcode GPU capture navigability |
| G-34 | `IOSurfaceGetBytesPerRow` may exceed `width * bpp`; `cv::Mat` view requires stride argument (ADR-29) |
