# 04 — AVFoundation

AVFoundation-specific rules: session management, device state streaming, interruption
handling, orientation.

---

## AVCaptureSession lifecycle (reprise of ADR-07)

All `AVCaptureSession` and `AVCaptureDevice.lockForConfiguration()` operations run on
a dedicated serial queue. The session is created once per `open()`, reused across
pause/resume. See `02-concurrency.md` ADR-07.

### Device capability checks at startup

Never assume a capability; verify against the actual device. At session configuration
time, verify any capability the design depends on and throw a named error if missing.
Examples:

```swift
guard device.activeFormat.isVideoHDRSupported else { /* ... or degrade */ }
guard connection.isVideoRotationAngleSupported(90) else { /* ... */ }
```

The set of supported capabilities varies across device generations and between front
and back cameras on the same device. Hardcoding "A16 supports X" is a trap.

### The view-lifecycle vs interruption split

Two orthogonal signal sources. **Do not conflate them.**

| Source | Signal | Response |
|---|---|---|
| View lifecycle | View appears / disappears (SwiftUI `.task` or UIKit `viewWillAppear`/`viewWillDisappear`) | `startRunning()` / `stopRunning()` on `sessionQueue` |
| System interruptions | `AVCaptureSessionWasInterrupted` / `InterruptionEnded` | Observe, classify, surface UI. Do NOT call `stopRunning()`. |

Calling `stopRunning()` in response to a system interruption races the system and
produces undefined `isRunning`/`isInterrupted` state. Apple's AVCam sample avoids this
by binding start/stop to view lifecycle only.

---

## ADR-30: AVCaptureSession lifecycle via async with timeout; never sessionQueue.sync from MainActor

`AVCaptureSession.startRunning()` and `stopRunning()` block 100–500 ms (G-03). They run
on `sessionQueue` (ADR-07). From `@MainActor`, calling
`sessionQueue.sync { session.stopRunning() }` can deadlock: if `sessionQueue` is
mid-flight in a `sessionQueue.async { startRunning }` dispatched by a scenePhase
transition (ADR-08), the sync call from main waits for the async to finish, and if that
async then dispatches any UI update back to the main actor, we have a two-party deadlock.
The same hazard applies to any `@MainActor` call that `dispatch_sync`s onto a serial
queue that also calls back onto the main actor.

**Correct shape:** dispatch lifecycle calls asynchronously and await completion via a
continuation, bounded by a timeout:

```swift
// correct — from @MainActor
func stopCaptureSession(timeout: Duration = .seconds(2)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.sessionQueue.async {
                    self.session.stopRunning()
                    cont.resume()
                }
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CaptureError.sessionLifecycleTimeout
        }
        _ = try await group.next()
        group.cancelAll()
    }
}
```

```swift
// forbidden — never call sessionQueue.sync from @MainActor
sessionQueue.sync { session.stopRunning() }
```

Cross-references: ADR-07 (sessionQueue), ADR-08 (scenePhase → stops session), G-03
(`startRunning` blocks 100–500 ms).

---

## Interruption reasons

Register for both notifications:

```swift
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionWasInterrupted, ...
)
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionInterruptionEnded, ...
)
```

The `wasInterrupted` `userInfo` carries `AVCaptureSessionInterruptionReasonKey`.
Handling policy by reason:

| Reason | Meaning | Response |
|---|---|---|
| `videoDeviceNotAvailableInBackground` | App backgrounded | No-op. Await `interruptionEnded`. |
| `videoDeviceInUseByAnotherClient` | FaceTime, another camera app | Show **Resume** button. **Do not auto-resume** — user intent required. |
| `audioDeviceInUseByAnotherClient` | Phone call, audio app | Show Resume button (same policy). |
| `videoDeviceNotAvailableWithMultipleForegroundApps` | iPad Slide Over / Split View / PiP | Show "camera unavailable" label. Cannot auto-resume — user must exit multitasking mode. |
| `videoDeviceNotAvailableDueToSystemPressure` | Thermal throttling | Show "camera unavailable" label. Await `interruptionEnded`. |
| `sensitiveContentMitigationActivated` | `SCVideoStreamAnalyzer` detected sensitive content (iOS 26+) | Show "camera unavailable" label. Resume requires calling `SCVideoStreamAnalyzer.continueStream()` — do **not** auto-resume. |

On `interruptionEnded`:
- Auto-resume (call `session.startRunning()` on `sessionQueue`) for
  `videoDeviceNotAvailableInBackground` and `videoDeviceNotAvailableDueToSystemPressure`.
- Wait for user intent (Resume button) for the "in use by another client" reasons.

---

## ADR-17: Camera orientation via AVCaptureConnection

Set `AVCaptureConnection.videoRotationAngle` at session configuration time. The
`CVPixelBuffer` arrives pre-rotated — no Metal shader UV transform needed.

```swift
if connection.isVideoRotationAngleSupported(90) {
    connection.videoRotationAngle = 90  // landscape right
}
```

This supersedes the "manual UV transform matrix in a vertex shader" pattern that's
correct on Android (OpenGL ES) but wrong on iOS. AVFoundation handles sensor mounting
angle — trust it.

The exact angle is hardware-dependent. Verify empirically during bring-up (display a
test card with known orientation and confirm the preview matches). Don't hardcode
`90` without checking `isVideoRotationAngleSupported(_:)` — the supported set varies
by device.

---

## ADR-14: KVO → AsyncStream for device state

`AVCaptureDevice` publishes live state via KVO:

- `iso`
- `exposureDuration`
- `whiteBalanceGains`
- `lensPosition`
- `isAdjustingExposure`
- `systemPressureState`

Wrap these as an `AsyncStream` rather than using Combine `@Published`:

```swift
final class DeviceStateStream: @unchecked Sendable {
    // Box for the KVO observation tokens. Lifetime of the observations is tied
    // to this box's ARC lifetime — deinit is the single authoritative point
    // where KVO detaches. Robust to future edits that rewrite or move the
    // cont.onTermination assignment.
    private final class Tokens {
        var values: [NSKeyValueObservation] = []
        deinit { values.forEach { $0.invalidate() } }
    }

    func states(for device: AVCaptureDevice) -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { cont in
            let box = Tokens()
            box.values = [
                device.observe(\.iso) { _, _ in cont.yield(Self.snapshot(device)) },
                device.observe(\.exposureDuration) { _, _ in cont.yield(Self.snapshot(device)) },
                // ... other keypaths ...
            ]
            // Retain the box until the stream terminates (finished or cancelled).
            // When the continuation state releases this closure, box goes out of
            // scope and its deinit invalidates every observation at once.
            cont.onTermination = { _ in _ = box }
        }
    }

    private static func snapshot(_ device: AVCaptureDevice) -> DeviceStateSnapshot {
        DeviceStateSnapshot(
            iso: device.iso,
            exposureDuration: device.exposureDuration,
            // ...
        )
    }
}
```

**Why the `Tokens` box.** The original pattern (`let tokens = [...]` local to
the build closure, invalidated inside `onTermination`) works only as long as
the `onTermination` line is exactly what invalidates them. Any later refactor
that moves, rewrites, or conditionally skips that line silently leaks
observers on a dead device. Wrapping the tokens in a small class shifts the
invariant "observations die when the stream dies" from "a specific line must
stay correct" to "ARC frees the box when the last reference drops, and its
deinit invalidates" — enforced by the compiler, not by convention.

`@unchecked Sendable` is retained on `DeviceStateStream` for consistency with
the project's isolation conventions; the class holds no mutable state today,
but the annotation is kept so that future additions don't need to reintroduce
it.

### Strict-concurrency requirements

Under Swift 6 strict concurrency, the KVO-to-AsyncStream adapter must satisfy three
invariants — all of which the `Tokens`-box pattern above already satisfies:

1. **No strong `self` capture in observer closures.** KVO observers and their target
   retain each other; a strong `self` capture inside the stream-producer closure creates
   a cycle that never invalidates. The pattern above uses `Self.snapshot(device)` (a
   static call — no `self` at all). If you refactor to an instance method, use
   `[weak self]` explicitly.

2. **`onTermination` must release the observation-owning reference.** When a consumer
   ends its `for await` loop the stream must tear down the KVO registration promptly,
   not wait for the containing actor's `deinit`. The `cont.onTermination = { _ in _ = box }`
   line achieves this: the continuation's storage drops the last reference to `box`, whose
   `deinit` calls `invalidate()` on every token. Ensure `onTermination` is always set
   before the first `yield` to avoid a race on immediate cancellation.

3. **Cancel the consuming `Task` deterministically in the owning actor's `close()` path.**
   Do not rely on actor `deinit` ordering to drive stream cancellation. The `Tokens.deinit`
   teardown is fine (it's not an actor), but the `Task { for await ... }` consumer is
   owned by the actor; cancel it explicitly in `close()` so that observation ends at a
   well-defined point in the session lifecycle.

Consume on `@MainActor`:

```swift
Task { @MainActor in
    for await snapshot in deviceStream.states(for: device) {
        viewModel.cameraState = snapshot
    }
}
```

- Terminate the stream cleanly on device reconfiguration; restart on resume.
- No Combine dependency.
- `.task { }` modifier on the SwiftUI view auto-cancels on disappear.
- KVO runs on the thread that made the mutation; yielding into the stream decouples
  observer lifetime from consumer lifetime.

---

## Device configuration windows

**Invariant: every `AVCaptureDevice` property mutation MUST be wrapped in
`lockForConfiguration()` / `unlockForConfiguration()`. Omitting the lock raises
`NSGenericException` and crashes the app.** This is the most common first-launch
crash for camera apps — it passes in Simulator (lock is a no-op there) but fails
on device at the first ISO or exposure change.

```swift
// Every applySettings call must follow this pattern — no exceptions.
try device.lockForConfiguration()
defer { device.unlockForConfiguration() }

// ISO and exposure duration are a coupled commit — always set together via
// setExposureModeCustom(duration:iso:completionHandler:).
// Setting device.iso or device.exposureDuration directly is not supported;
// those are read-only observation properties.
device.setExposureModeCustom(
    duration: CMTimeMake(value: 1, timescale: 33),
    iso: 400,
    completionHandler: nil
)

// Focus, WB, zoom are each independent commits inside the same lock window.
device.setFocusModeLocked(lensPosition: 0.5, completionHandler: nil)
device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
device.videoZoomFactor = 2.0
```

Required properties of the lock pattern:
- Runs on `sessionQueue`, never on `@MainActor` — `lockForConfiguration` blocks and
  cannot be called from the main thread without a purple warning.
- `defer { device.unlockForConfiguration() }` placed immediately after the `try` —
  if any subsequent call throws, the lock is still released. Do not unlock manually
  at the end of the function; a thrown error skips it.
- Coalesce slider input in the UI (e.g. 60 Hz debouncer) before dispatching to
  `sessionQueue`. Holding the lock per-pixel-dragged is wasteful.
- Mode toggles (auto ↔ manual) are UI state only; switching to auto calls
  `continuousAutoExposure` / `continuousAutoFocus` / `continuousAutoWhiteBalance`
  and stops committing manual values. A mode toggle and a manual-value commit must
  not race inside the same lock window.

**Bounds are always read from the device, never hardcoded:**

| Control | Read from |
|---|---|
| ISO | `device.activeFormat.minISO ... .maxISO` |
| Exposure duration | `device.activeFormat.minExposureDuration ... .maxExposureDuration` |
| Lens position | `0.0 ... 1.0` (normalized; see G-11) |
| White balance gain (per channel) | `1.0 ... device.maxWhiteBalanceGain` (see G-10) |

---

## Photo library authorization

`PHPhotoLibrary.performChanges` without authorization crashes on iOS 14+. Before
calling:

```swift
let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
switch status {
case .authorized, .limited:
    break
case .notDetermined:
    let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard granted == .authorized || granted == .limited else { return .denied }
case .denied, .restricted:
    return .denied
@unknown default:
    return .denied
}
// now safe to call performChanges
```

Photo library denial is NOT fatal for the camera session — unlike camera permission
denial. Fall back to a temp file path and surface a non-fatal error.

---

## No-audio as a deliberate constraint

For camera-only apps that don't record audio (scientific imaging, silent video,
surveillance preview), **omit audio entirely**. This is not just an optimization —
it's a policy and UX requirement.

- Do not attach `AVCaptureAudioDataOutput` to the session.
- Do not configure `AVAudioSession`. The system default session is untouched, so
  starting a recording does NOT interrupt the user's music or podcast.
- Do not add `NSMicrophoneUsageDescription` to `Info.plist`. Adding the key without
  actually accessing the microphone is grounds for App Store rejection ("misleading
  usage description").
- Recording writer has a single `AVAssetWriterInput` of media type `.video`. No
  audio input.

If audio is later added, `NSMicrophoneUsageDescription` is required, the audio
session category must be chosen carefully (`.playAndRecord` vs `.ambient`), and
conflict handling with phone calls / music apps becomes a new risk.

---

## systemPressureState KVO

`AVCaptureDevice.systemPressureState` reports thermal / power conditions that affect
capture quality. Observe via KVO (can be integrated into the same
`DeviceStateStream` as other device state):

```swift
device.observe(\.systemPressureState) { device, _ in
    switch device.systemPressureState.level {
    case .nominal, .fair:
        // normal operation
    case .serious:
        // reduce capture preset, drop to lower fps, disable HDR, etc.
    case .critical:
        // stop recording if active; consider full session suspend
    case .shutdown:
        // session already being shut down by the system
    default: break
    }
}
```

Orthogonal to `ProcessInfo.thermalState` — the device's own view of its pressure.
Both should be observed; the intersection drives degradation policy.

---

## Background recording drain (ADR-16 integration)

### Background during active recording

When `scenePhase → .background` fires with an active `AVAssetWriter`:

1. Request a background-execution extension via
   `UIApplication.shared.beginBackgroundTask(expirationHandler:)`.
2. The expiration handler **always calls `cancelWriting`**, never `finishWriting`. An
   interrupted `finishWriting` produces a corrupt MP4 with no `moov` atom (G-08).
3. `finishWriting` has exactly two legitimate call sites: (a) the user stops recording
   before any backgrounding, and (b) the recording was paused pre-background and a
   foreground-resume continuation explicitly drives the `finishWriting`. It is never
   allowed to race the expiration handler.
4. UX consequence: a recording interrupted by OS backgrounding produces no file. The
   user-facing language is "recording cancelled by system"; partial files are not surfaced.

```swift
let bgTask = UIApplication.shared.beginBackgroundTask(withName: "recording-drain") {
    // expiration handler — always cancel, never finishWriting (G-08)
    assetWriter.cancelWriting()
    UIApplication.shared.endBackgroundTask(bgTask)
}
await recorder.stop()           // drives finishWriting with a timeout deadline (see ADR-16)
UIApplication.shared.endBackgroundTask(bgTask)
```

Cancelling on expiration produces a clean (empty) file rather than a partial corrupt one.
See G-08, ADR-16 (`03-metal.md`).
