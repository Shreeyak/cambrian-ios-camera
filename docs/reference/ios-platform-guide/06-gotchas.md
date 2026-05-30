# 06 — Gotchas

Quick-reference table of iOS failure modes and API pitfalls. These are stable
platform facts, not architectural decisions. Every entry is something that will
crash or silently degrade an app if missed.

---

## API pitfalls

| # | Pitfall | Correct handling |
|---|---|---|
| G-01 | `CVMetalTextureCacheCreateTextureFromImage` returns `kCVReturnSuccess` + nil texture under memory pressure | Nil-check `CVMetalTextureGetTexture` return; drop frame on nil (see ADR-15) |
| G-02 | `MTLCommandBuffer` errors are silent without `addCompletedHandler` status check | Always install handler; check `cb.status == .error` |
| G-03 | `AVCaptureSession.startRunning()` blocks 100–500ms | Never call on `@MainActor`; use `sessionQueue` (ADR-07) |
| G-04 | `PHPhotoLibrary.performChanges` crashes without authorization on iOS 14+ | Check + request `.addOnly` before `performChanges` |
| G-05 | Metal command submission in background → process termination (`MTLCommandBufferErrorNotPermitted`, IOAF code 6) | Atomic gate + `waitUntilScheduled()` on `scenePhase == .inactive` (ADR-09) |
| G-06 | Stopping `AVCaptureSession` in response to system interruption races the system | Only stop on view-lifecycle signals; observe `wasInterrupted` without acting |
| G-07 | Recreating `AVCaptureSession()` on every scene appearance incurs full hardware re-init | Create once per `open()`, reuse across pause/resume |
| G-08 | `AVAssetWriter.finishWriting` mid-backgrounding → corrupt MP4 (no `moov` atom) | `beginBackgroundTask` + expiration handler calls `cancelWriting`. See ADR-16's `Background during active recording` subsection in `04-avfoundation.md` for the full lifecycle rule and the two legitimate `finishWriting` call sites. |
| G-09 | `AVCapturePhotoOutput` attached concurrently with `AVCaptureVideoDataOutput` at max resolution can silently downgrade video output resolution | Verify `CVPixelBufferGetWidth/Height` on sample buffers after adding photo output |
| G-10 | White balance gains passed outside `[1.0, device.maxWhiteBalanceGain]` → `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains` fails | Clamp before setting |
| G-11 | `lensPosition` is 0.0–1.0 normalized, **not** diopters | Don't display as diopters without per-device calibration; label as relative focus |
| G-12 | Camera-only apps shouldn't claim audio — avoids conflict with phone calls, music | If not capturing audio, don't attach `AVCaptureAudioDataOutput`; no `NSMicrophoneUsageDescription` needed |
| G-13 | `CVPixelBuffer` is not `Sendable` as of iOS 26 | Confine to one isolation domain; `sending` where transferred (ADR-10) |
| G-14 | `sessionQueue.async { session.startRunning() }` then immediately reading `session.isRunning` from main — race | Use a state stream or completion callback from `sessionQueue` |
| G-15 | `CVMetalTextureCache` holds onto textures beyond current frame → steady memory growth | Release the `CVMetalTexture` object each frame (not just the Metal texture); or `CVMetalTextureCacheFlush` on memory warning |
| G-16 | `AVCaptureDevice.authorizationStatus` returns `.notDetermined` on first launch | Call `requestAccess(for: .video)` and await result before configuring session |
| G-17 | Capture format 10-bit / half-float not supported on most iOS camera outputs | Enumerate `device.formats` at startup; convert to working format in first Metal pass (ADR-05) |
| G-18 | BGRA channel-order coefficients applied to RGBA buffers → silently wrong grayscale (no crash, no error) | Consumer path is always RGBA; BT.709 weights must be `(0.2126, 0.7152, 0.0722, 0.0)` in that order. See channel-order table in `03-metal.md`. |
| G-19 | Status-bar camera indicator remains active >1s after backgrounding → App Store rejection (policy, not just runtime bug) | `session.stopRunning()` must complete before the view-layer task returns on `.background` |
| G-20 | Between `commandBuffer.commit()` and `addCompletedHandler` firing, the engine may have run `close()` / `backgroundSuspend()` / `setResolution()` → handler touches released buffers | Capture `sessionState` at commit; check equality + `.streaming` in handler before acting. See `02-concurrency.md §Completion-handler re-entrancy guard`. |
| G-21 | `VTFrameProcessor` looked like a fit for custom color transforms, isn't | Does system-defined effects only (motion blur, super-res, denoise, optical flow, frame rate conversion). Use custom Metal compute for app-owned color pipelines. See `03-metal.md §VTFrameProcessor`. |
| G-22 | Device capability assumed, not verified → silent malfunction on other device models | Check `isVideoHDRSupported`, `isVideoRotationAngleSupported(_:)`, and similar per-capability flags at session config; throw named errors on missing capability. |
| G-23 | Running CV on the full-resolution processed stream instead of the tracker stream → 15–25ms per frame, misses budget | Subscribe CV consumers to tracker stream (~480p, ~0.3M px). Canny budget 2–4ms at that resolution on A16. |
| G-24 | Adding `NSMicrophoneUsageDescription` without using the mic → App Store rejection ("misleading usage description") | Only declare usage keys for permissions actually requested at runtime. |
| G-25 | `MTLTexture` allocated with `.private` storage mode has a nil `.iosurface` property — publishing to PixelSink via `texture.iosurface` silently passes nil, dropping all frames to C++ consumers with no error | When any PixelSink subscriber is attached to the natural or processed stream, TexturePoolManager must allocate `.shared` textures (IOSurface-backed). Default `.private` only when no consumer is present (ADR-20). |
| G-26 | PixelSink consumer without a per-stream drop counter exposes no signal when the mailbox is overwriting — EdgeDetector can degrade from 30 Hz to 5 Hz under thermal throttling with the pipeline appearing healthy | Every C++ PixelSink consumer must expose `std::atomic<uint64_t> overwriteCount_[3]` and a C-ABI `drainStats(StreamId) -> StreamStats` getter; poll at 1 Hz and surface alongside thermal state (ADR-13, ADR-19). |
| G-27 | `@unchecked Sendable` silences the compile-time diagnostic but **does not fix the underlying data race** — the warning was the symptom, not the bug | Never use `@unchecked Sendable` to "make the error go away." Either (a) make the type actually Sendable (value type with Sendable fields, or `final class` with immutable fields), (b) use `sending` (SE-0430) at the boundary, or (c) redesign so the value never crosses the actor boundary (ADR-10). `@unchecked` is reserved for Apple types that Apple has not yet marked Sendable (e.g. `CVPixelBuffer` as of iOS 26), with a comment naming the specific type and its thread-safety contract. |
| G-28 | `Task.isCancelled` checked inside a loop **without `throw`** silently ignores cancellation — the Task still exits only when its upstream stream closes | Use `try Task.checkCancellation()` per loop iteration. `Task.isCancelled` is permitted only when paired with an explicit early `return`/`throw` on the same iteration — mere observation is not enough (ADR-23). Pair with `.task` modifier (ADR-28) so SwiftUI auto-cancels on view disappear. |
| G-29 | `PhotosPicker` (SwiftUI, iOS 16+) runs **out-of-process** and grants access only to the user's selected items — it requires **no** `NSPhotoLibraryUsageDescription` — shipping that key regardless triggers App Store review friction ("misleading usage description") | Do not add `NSPhotoLibraryUsageDescription` to `Info.plist` unless the app uses `PHPhotoLibrary` for direct fetch or an older picker (`UIImagePickerController`, `PHPickerViewController` with library access). `NSPhotoLibraryAddUsageDescription` is still required when writing captured photos/videos to the library (pairs with G-04, G-24). |
| G-30 | Actor re-entrancy across `await` — an actor method that reads state, `await`s another call, and then acts on the earlier-read state sees state that may have changed between the two steps | Never assume equality across an `await`. Either (a) capture + recheck inside the guard, (b) keep the critical section suspension-free (no `await`), or (c) sequence through a dedicated serial entry point that serializes the compound operation. See the completion-handler re-entrancy guard in `02-concurrency.md` for the canonical pattern. **At-most-once example.** "If `expectedToken == currentToken`, perform the mutation" is a guarded mutation. If any `await` appears between reading `currentToken` and performing the mutation, the guard is invalidated — a second caller could flip `currentToken` during the suspension. Structure the critical section without any `await`: read, compare, mutate, all within the same continuation. If the action genuinely needs an `await`, re-verify the guard after the `await` and no-op on mismatch. The canonical completion-handler guard in `02-concurrency.md` illustrates this pattern for `onFrameComplete`. |
| G-31 | Raw `Task { @MainActor in vm.x = ... }` spawned from a 30 Hz capture delegate is fragile: the Task queue can grow unboundedly under a stalled MainActor, `vm` is captured across an isolation boundary without a `[weak]`, and Task startup cost is paid per frame. Backpressure signals (`.bufferingNewest(1)` on the producer) don't reach these one-off Tasks. | Feed a `Sendable` struct into an `AsyncStream.Continuation` from the delivery queue; consume on `@MainActor` via `for await` with `.bufferingNewest(1)` (ADR-22). The stream's buffering policy then handles overload. Raw `Task` hops from hot-path delegates are forbidden for UI updates; they are permitted only for one-off, bounded side-effects (e.g., a single error toast). |
| G-32 | `MTLBlitCommandEncoder.copy(from:to:)` does not perform pixel-format conversion — the source and destination textures must share `pixelFormat`. A common mistake is blitting an RGBA16F working texture directly to a BGRA8 MTKView drawable; the call will assert at encoder-encode time (or on newer OS versions, render black). | Any pass that changes pixel format is a render or compute pass. Either keep the working format to the drawable (configure `MTKView.colorPixelFormat = .rgba16Float` and let the system tone-map) or add a final render/compute pass that reads RGBA16F and writes BGRA8 before presenting. Pure blit passes are appropriate only for same-format copies (e.g., natural → processed staging). |
| G-33 | Unlabeled `MTLCommandBuffer`s and un-bracketed encoder work produce opaque Xcode GPU captures — every pass is named "Command Buffer 1", every draw "Render Encoder" — which makes shader debugging slow. | Label every command buffer per frame: `commandBuffer.label = "frame.\(frameIndex).pass\(passId)"`. Wrap each encoder's work in `encoder.pushDebugGroup("naturalToProcessed")` / `popDebugGroup()`. The names appear in Xcode's GPU capture navigator and in Instruments' Metal System Trace. Zero runtime cost in release builds. |
| G-34 | `IOSurfaceGetBytesPerRow(surface)` may exceed `width * bytes_per_pixel` due to hardware alignment padding (typically 64- or 128-byte row alignment). Constructing `cv::Mat(height, width, type, basePtr)` without the stride argument assumes tight packing; on a padded IOSurface the resulting `cv::Mat` will misread every row beyond the first. | Always pass the stride: `cv::Mat m(h, w, CV_16FC4, basePtr, IOSurfaceGetBytesPerRow(surface))`. Subsequent `cvtColor`, `resize`, and other OpenCV operations handle stride-padded source matrices correctly; only the initial view construction is the trap. Do not attempt to strip the padding into a new buffer — the view cost is zero, the copy cost is per-frame wasted bandwidth. |
| G-35 | When returning from background, iOS transitions `.background → .inactive → .active` — never `.background → .active` directly. Code that checks `previousPhase == .background` at the `.active` site always sees `.inactive` instead; the backgroundResume path is silently skipped, leaving the session stopped until the stall watchdog fires. | Track a `cameFromBackground: Bool` flag — set it on `.background`, check-and-clear it on `.active`. Do not use `previousPhase` to distinguish a background-return from a notification-dismiss. Expected side-effect: AVFoundation reinitializes auto-exposure on every `startRunning()`, producing a brief brightness shift (~260ms) on the first live frame. |

---

## scenePhase / lifecycle quick reference

| scenePhase | Triggers on | Action |
|---|---|---|
| `.active` | Foreground, receiving events | Resume GPU gate; if `cameFromBackground` flag is set, call `startRunning()` and clear flag |
| `.inactive` | App switcher, notification banner, incoming call, Control Center | **Gate GPU**, do not stop session |
| `.background` | Fully off-screen | Set `cameFromBackground = true`; stop session via `sessionQueue` |

- `UIApplicationDelegate.applicationWillResignActive` ≈ `.inactive`
- `UIApplicationDelegate.applicationDidEnterBackground` ≈ `.background`
- Return from background always goes `.background → .inactive → .active`; the `.inactive` hop is not a new interruption, so do not re-close the gate there.

Full treatment in `02-concurrency.md` ADR-08, ADR-09. See G-35.

---

## Capture format facts (device-dependent)

- Most recent iPhones + A16 iPad: camera emits 8-bit biplanar YUV only. Half-float
  and 10-bit YUV are **not supported** on `AVCaptureVideoDataOutput`.
- Convert to working format in the first Metal pass, not at capture configuration.
- Full-sensor resolutions (~4160×3120 on A16) are typically 30fps-only; 60fps
  requires a smaller format.
- ProRes / ProRAW paths have different rules and are out of scope here.

Always enumerate `device.formats` at startup and pick the highest-resolution format
meeting your frame-rate and pixel-format requirements. Don't hardcode dimensions.

---

## The forbidden pattern

```swift
// ❌ DO NOT DO THIS
func viewWillAppear() {
    session = AVCaptureSession()   // recreating on every appearance
    configureInputsAndOutputs()
    session.startRunning()
}
```

The "reopen device on every resume" port from Camera2. It:
- Defeats shallow-teardown across pause/resume.
- Incurs full hardware re-initialization latency on every foreground.
- Causes audio/video sync issues if audio is ever added.
- Gives iOS camera apps their "sluggish on foreground" reputation.

Correct: `AVCaptureSession` is created once per `open()` call;
`startRunning()` / `stopRunning()` toggle it across view lifecycle.

---

## Sources

- Apple Developer: "Preparing your Metal app to run in the background"
- Apple Developer: AVCam sample code (`SessionViewController.swift`)
- Apple Developer: AVFoundation Programming Guide — Running and Stopping a Session
- Apple Developer: `AVCaptureSessionInterruptionReason` documentation
- Apple Developer: `MTLCommandBuffer.waitUntilScheduled()` documentation
- Apple Developer: Human Interface Guidelines — Camera
- Swift.org: C++ Interoperability, Safe Interop
- SE-0430: `sending` parameter and result values
