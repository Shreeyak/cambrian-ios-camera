# ISP Photo-Output Natural Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-implement `captureNaturalPicture` as an `AVCapturePhotoOutput` one-shot (ISP-processed) run through the live Metal crop + grade, saved as a cropped TIFF — identical to `captureImage` except for its source.

**Architecture:** Attach one `AVCapturePhotoOutput` at `open()`. On capture: shoot a `420f` one-shot on `sessionQueue`, bridge the buffer to the engine actor, run a new `MetalPipeline.gradeOneShot` (Pass-1 crop + Pass-2 grade → BGRA8 `outputSize`), then `StillCapture.encode(... .tiff, laneTag:"natural")`. Errors cleanly when the session isn't running.

**Tech Stack:** Swift 6 / iOS 26, AVFoundation (`AVCapturePhotoOutput`), Metal compute, swift-testing. Builds/tests via XcodeBuildMCP `test_device` (device-only; no simulators).

**Spec:** `docs/superpowers/specs/2026-05-22-isp-natural-capture-design.md`

**Conventions (apply to every task):**
- Build/test: `mcp__XcodeBuildMCP__test_device` with `-only-testing:eva-swift-stitchTests/<SuiteStructName>` in `extraArgs` (session default scheme `eva-swift-stitch`, projectPath = this worktree's `.xcodeproj`). Never `*_sim`.
- New test file → run `scripts/sync-test-target.sh` once before testing it.
- swift-format gate: after editing any `Sources/**.swift`, run `swift-format -i` then `swift-format lint --strict` on the file.
- Do not commit without the user's OK (CLAUDE.md §7). "Commit" steps below mean *stage + propose*; ask before running.
- Read `CameraKit/CONTRACTS.md` + the target file before editing (coordinator discipline).

---

### Task 1: `MetalPipeline.gradeOneShot(pixelBuffer:)`

The one-shot Metal path: YUV `CVPixelBuffer` → Pass-1 (crop) → Pass-2 (grade) → BGRA8 `outputSize`. Reuses live PSOs/uniforms; grade snapshotted at call time. Independent of AVFoundation — fully unit-testable.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`
- Modify: `CameraKit/Sources/CameraKit/Errors.swift` (add `MetalError` case if a distinct dimension-mismatch error is wanted; otherwise reuse `.unsupportedFormat`)
- Test: `CameraKit/Tests/CameraKitTests/IspNaturalCaptureTests.swift` (new)

- [ ] **Step 1: Write failing tests**

```swift
import CoreMedia
import CoreVideo
import Metal
import Testing
@testable import CameraKit

@Suite("ISP natural capture — one-shot Metal grade")
struct IspGradeOneShotTests {

    // Reuses the YUV pixel buffer behind a solid sample buffer (R≈210,G≈129,B≈101).
    private func solidYUVBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let sb = try makeSolidYUVSampleBufferForRgba8Tests(width: w, height: h, y: 150, cb: 100, cr: 170)
        return CMSampleBufferGetImageBuffer(sb)!
    }

    @Test("gradeOneShot applies the live grade (gray on full desaturate) at outputSize BGRA8")
    func gradeOneShotAppliesGrade() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { Issue.record("no metal device"); return }
        let pipeline = try MetalPipeline(device: device, captureSize: Size(width: 64, height: 64), gateOpen: true)
        var params = ProcessingParameters.identity
        params.saturation = -1.0
        pipeline.setColorUniformsForTest(params)

        let out = try await pipeline.gradeOneShot(pixelBuffer: try solidYUVBuffer(64, 64))

        #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(out) == 64 && CVPixelBufferGetHeight(out) == 64)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let idx = (CVPixelBufferGetHeight(out)/2) * CVPixelBufferGetBytesPerRow(out) + (CVPixelBufferGetWidth(out)/2)*4
        let b = Int(p[idx]), g = Int(p[idx+1]), r = Int(p[idx+2])
        #expect(abs(r - b) <= 4 && abs(r - g) <= 4, "desaturated grade ⇒ gray; got R=\(r) G=\(g) B=\(b)")
    }

    @Test("gradeOneShot errors cleanly when buffer dims != captureSize")
    func gradeOneShotDimensionGuard() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { Issue.record("no metal device"); return }
        let pipeline = try MetalPipeline(device: device, captureSize: Size(width: 64, height: 64), gateOpen: true)
        await #expect(throws: (any Error).self) {
            _ = try await pipeline.gradeOneShot(pixelBuffer: try solidYUVBuffer(32, 32))
        }
    }
}
```

- [ ] **Step 2: Wire the new test file into the Xcode target, run, verify FAIL**

Run: `scripts/sync-test-target.sh` then `test_device` with `-only-testing:eva-swift-stitchTests/IspGradeOneShotTests`.
Expected: FAIL — `gradeOneShot` does not exist.

- [ ] **Step 3: Implement `gradeOneShot`**

Add to `MetalPipeline`. Mirrors `encode()`'s Pass-1 + Pass-2, plus the proven `rgba16fToBgra8` convert; dequeues its own buffers; snapshots the grade at call time.

```swift
/// One-shot crop+grade of an arbitrary YUV buffer (e.g. an AVCapturePhotoOutput
/// still) into a BGRA8 `outputSize` buffer — the saved natural-capture path.
/// Reuses the live crop uniform + current ColorUniform so the result matches the
/// graded preview. Input dims MUST equal `captureSize` (1:1 crop mapping).
func gradeOneShot(pixelBuffer: CVPixelBuffer) async throws -> CVPixelBuffer {
    guard CVPixelBufferGetWidth(pixelBuffer) == captureSize.width,
          CVPixelBufferGetHeight(pixelBuffer) == captureSize.height else {
        throw MetalError.unsupportedFormat
    }
    let yTex = try texturePool.makeYTexture(from: pixelBuffer)
    let cbcrTex = try texturePool.makeCbCrTexture(from: pixelBuffer)
    let nat = try texturePool.dequeuePoolTexture(pool: naturalPool, width: outputSize.width, height: outputSize.height)
    let proc = try texturePool.dequeuePoolTexture(pool: processedPool, width: outputSize.width, height: outputSize.height)
    let out = try texturePool.dequeueEightBitPoolTexture(pool: eightBitNaturalPool, width: outputSize.width, height: outputSize.height)

    let (color, crop) = uniforms.withLock { ($0.color, $0.crop) }
    let cb = commandQueue.makeCommandBuffer()!
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    let groups = MTLSize(width: (outputSize.width + 15)/16, height: (outputSize.height + 15)/16, depth: 1)

    let p1 = cb.makeComputeCommandEncoder()!          // Pass-1: YUV→RGB + crop
    p1.setComputePipelineState(yuvToRgbaPSO)
    p1.setTexture(yTex, index: 0); p1.setTexture(cbcrTex, index: 1); p1.setTexture(nat.texture, index: 2)
    var cropLocal = crop; p1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
    p1.dispatchThreadgroups(groups, threadsPerThreadgroup: tg); p1.endEncoding()

    let p2 = cb.makeComputeCommandEncoder()!          // Pass-2: grade
    p2.setComputePipelineState(colorTransformPSO)
    p2.setTexture(nat.texture, index: 0); p2.setTexture(proc.texture, index: 1)
    var colorLocal = color; p2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
    p2.dispatchThreadgroups(groups, threadsPerThreadgroup: tg); p2.endEncoding()

    let p3 = cb.makeComputeCommandEncoder()!          // convert RGBA16F→BGRA8
    p3.setComputePipelineState(rgba16fToBgra8PSO)
    p3.setTexture(proc.texture, index: 0); p3.setTexture(out.texture, index: 1)
    p3.dispatchThreadgroups(groups, threadsPerThreadgroup: tg); p3.endEncoding()

    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        cb.addCompletedHandler { b in
            b.status == .error ? c.resume(throwing: MetalError.commandBufferFailed(code: (b.error as NSError?)?.code ?? -1))
                               : c.resume()
        }
        cb.commit()
    }
    return out.buffer
}
```

(Verify the exact `texturePool` helper signatures in `TexturePoolManager.swift` before writing — `makeYTexture` / `makeCbCrTexture` / `dequeuePoolTexture` / `dequeueEightBitPoolTexture` are used identically in `encode()`.)

- [ ] **Step 4: Run tests, verify PASS**

Run: `test_device -only-testing:eva-swift-stitchTests/IspGradeOneShotTests`. Expected: PASS (2 tests).

- [ ] **Step 5: swift-format + stage**

`swift-format -i CameraKit/Sources/CameraKit/MetalPipeline.swift && swift-format lint --strict CameraKit/Sources/CameraKit/MetalPipeline.swift`. Stage; propose commit `feat(camerakit): MetalPipeline.gradeOneShot one-shot crop+grade`.

---

### Task 2: Photo settings builder + `StillPhotoCapture`

The `AVCapturePhotoSettings` builder is a pure function (unit-testable). The delegate + continuation bridge is structural.

**Files:**
- Create: `CameraKit/Sources/CameraKit/StillPhotoCapture.swift`
- Test: `CameraKit/Tests/CameraKitTests/IspNaturalCaptureTests.swift` (add suite)

- [ ] **Step 1: Write failing test**

```swift
import AVFoundation

@Suite("ISP natural capture — photo settings")
struct IspPhotoSettingsTests {
    @Test("photo settings: flash off, .balanced, no high-res override")
    func settingsKnobs() {
        let s = StillPhotoCapture.makeSettings()
        #expect(s.flashMode == .off)
        #expect(s.photoQualityPrioritization == .balanced)
        #expect(s.isHighResolutionPhotoEnabled == false)
        // 420f requested as the (only) preview pixel format when available.
        #expect(s.availablePreviewPhotoPixelFormatTypes.isEmpty || s.format != nil)
    }
}
```

- [ ] **Step 2: Run, verify FAIL** (`StillPhotoCapture` undefined). Run: `test_device -only-testing:eva-swift-stitchTests/IspPhotoSettingsTests`.

- [ ] **Step 3: Implement `StillPhotoCapture`**

```swift
import AVFoundation
import CoreVideo

/// One-shot still photo via AVCapturePhotoOutput. `capture(...)` runs on
/// sessionQueue (ADR-07); the delegate callback (nonisolated) bridges the
/// resulting CVPixelBuffer back through a continuation. Settings honor the
/// device's live exposure/ISO/WB — there is no separate photo-settings surface.
final class StillPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    /// Builds the fixed photo settings (R4, R7). Requests 420f to match the
    /// video format so MetalPipeline.gradeOneShot consumes it directly.
    static func makeSettings() -> AVCapturePhotoSettings {
        let fmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let s = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
        s.flashMode = .off
        s.photoQualityPrioritization = .balanced
        s.isHighResolutionPhotoEnabled = false
        return s
    }

    private var continuation: CheckedContinuation<CVPixelBuffer, Error>?

    /// Must be called on sessionQueue. Returns the captured pixel buffer.
    func capture(using output: AVCapturePhotoOutput) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            output.capturePhoto(with: Self.makeSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { continuation = nil }
        if let error { continuation?.resume(throwing: error); return }
        guard let pb = photo.pixelBuffer else {
            continuation?.resume(throwing: StillCaptureError.bufferUnavailable); return
        }
        continuation?.resume(returning: pb)
    }
}
```

(If `AVCapturePhotoSettings(format:)` with only the pixel-format key trips a runtime requirement, fall back to `AVCapturePhotoSettings()` + adjust; verify on device in Task 5. `photo.pixelBuffer` requires the uncompressed format requested above.)

- [ ] **Step 4: Run, verify PASS.** Run: `test_device -only-testing:eva-swift-stitchTests/IspPhotoSettingsTests`.

- [ ] **Step 5: swift-format + stage.** Propose commit `feat(camerakit): StillPhotoCapture one-shot photo delegate + settings`.

---

### Task 3: Attach `AVCapturePhotoOutput` at open + sessionQueue capture entry

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift` (init + `configure()` step 4; add a `photoOutput` property + a `capturePhoto()` async entry on sessionQueue)

- [ ] **Step 1: Add the output (no new unit test — device/HITL verified in Task 5)**

In `init()`: `photoOutput = AVCapturePhotoOutput()` (add `private let photoOutput`). In `configure()`, inside the existing `beginConfiguration`/`commitConfiguration` block, after the video output:

```swift
if avSession.canAddOutput(photoOutput) {
    avSession.addOutput(photoOutput)
}
```

After `commitConfiguration()`, match rotation:

```swift
if let pc = photoOutput.connection(with: .video),
   pc.isVideoRotationAngleSupported(Constants.captureOrientationAngleDeg) {
    pc.videoRotationAngle = Constants.captureOrientationAngleDeg  // ADR-17
}
```

- [ ] **Step 2: Add the sessionQueue capture entry**

```swift
/// Shoots a one-shot still on sessionQueue (ADR-07). Returns the pixel buffer.
func capturePhoto() async throws -> CVPixelBuffer {
    let shooter = StillPhotoCapture()
    return try await withCheckedThrowingContinuation { cont in
        sessionQueue.async {
            Task { do { cont.resume(returning: try await shooter.capture(using: self.photoOutput)) }
                   catch { cont.resume(throwing: error) } }
        }
    }
}
```

(Confirm the `sessionQueue.async` + `Task` bridge against the existing `runOnQueue` helper in `AsyncWithTimeout.swift` — prefer reusing it if it fits, to match house style. Hold a strong ref to `shooter` until completion — the local binding + the `capture` await suffice.)

- [ ] **Step 3: Build (no device test yet)**

Run: `mcp__XcodeBuildMCP__build_device` (or `test_device` with the Task 1/2 suites to confirm the module still compiles). Expected: BUILD SUCCEEDED.

- [ ] **Step 4: swift-format + stage.** Propose commit `feat(camerakit): attach AVCapturePhotoOutput at open + sessionQueue capture`.

---

### Task 4: Rewrite `captureNaturalPicture`

Drive the ISP path; error cleanly when not streaming.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:1452` (`captureNaturalPicture`)

- [ ] **Step 1: Rewrite the method**

Replace the latest-natural-buffer body with: guard session running (else throw), shoot photo, grade, encode TIFF.

```swift
public func captureNaturalPicture(
    outputURL: URL? = nil,
    photosDestination: PhotosDestination = .none
) async throws -> StillCaptureOutput {
    guard isOpen, let pipeline = metalPipeline, let capture = stillCapture,
          let session = cameraSession else { throw EngineError.notOpen }
    // R6: ISP one-shot needs a running session — no last-frame fallback on pause.
    guard reconciledSessionRunning else { throw EngineError.capture(.bufferUnavailable) }

    let photoBuffer = try await session.capturePhoto()
    let graded = try await pipeline.gradeOneShot(pixelBuffer: photoBuffer)

    let snap = await session.device?.lastSnapshot
    let apertureValue = await (session.device.map { Double(await $0.lensAperture) }) ?? 0
    let writeURL = try PhotosLibraryClient.resolve(outputURL: outputURL, defaultExt: "tif")

    let output: StillCaptureOutput
    do {
        output = try await capture.encode(
            buffer: graded, captureSize: pipeline.outputSize, deviceSnapshot: snap,
            focalLengthMm: 0, apertureValue: apertureValue, outputURL: writeURL,
            format: .tiff, laneTag: "natural")
    } catch let e as StillCaptureError { throw EngineError.capture(e) }

    // Photos publish — unchanged non-fatal contract (copy from current method).
    if photosDestination != .none { /* …existing publish block… */ }
    return output
}
```

Update the doc comment: ISP one-shot, TIFF, errors on pause, no `AVCapturePhotoOutput`-avoidance note. (Verify `reconciledSessionRunning` is the right running-state signal — see `CameraEngine.swift`; it is the engine's tracked session-running bool. The `apertureValue` line must follow the existing two-step `if let device` form if the one-liner trips strict concurrency.)

- [ ] **Step 2: Pause-error test (if seams allow; else defer to HITL)**

If `_markOpenForTest()` + `_setStateForTest(.paused)` leave `metalPipeline`/`stillCapture` nil, this is HITL-only — note it and skip. Otherwise:

```swift
@Suite("ISP natural capture — pause contract")
struct IspPauseContractTests {
    @Test("captureNaturalPicture throws when session not running")
    func pauseErrors() async throws {
        let engine = CameraEngine()           // not open
        await #expect(throws: (any Error).self) { _ = try await engine.captureNaturalPicture() }
    }
}
```

- [ ] **Step 3: Run available tests + build.** Run: `test_device -only-testing:eva-swift-stitchTests/IspPauseContractTests` (if added) and confirm BUILD SUCCEEDED.

- [ ] **Step 4: swift-format + stage.** Propose commit `feat(camerakit): captureNaturalPicture uses ISP photo one-shot (reverses D-2P-10)`.

---

### Task 5: Device verification, HITL, and decision log

**Files:**
- Modify: `CameraKit/DECISIONS.md`
- Create: `measurements/isp-natural-capture/notes.md` (HITL evidence)

- [ ] **Step 1: Full suite on device**

Run: `mcp__XcodeBuildMCP__test_device` (no filter). Expected: all green, 0 failed.

- [ ] **Step 2: HITL on physical iPad**

Run the app; capture a natural picture in a scene with strong color + a non-identity grade. Verify on-device / pull the TIFF (`ipad-logs` skill / `devicectl copy from`): (a) it is ISP-quality (sharper/cleaner than a video frame, native-camera look); (b) it matches the live grade; (c) framing matches the active crop; (d) capture during pause errors. Record results + a sample image path in `measurements/isp-natural-capture/notes.md`.

- [ ] **Step 3: Log the decision**

Append to `CameraKit/DECISIONS.md` (above the marker): `2026-05-DD [trackertex] coordinator — captureNaturalPicture re-implemented as an AVCapturePhotoOutput one-shot (ISP-processed) → MetalPipeline.gradeOneShot (live crop+grade) → TIFF cropped to the active region; identical to captureImage except source. Reverses D-2P-10; supersedes 2026-05-15-capture-natural-picture-design.md. Photo settings: 420f, flash off, .balanced, no high-res/RAW/HDR override (honors device exposure/ISO/WB). Errors cleanly when the session isn't running (no last-frame fallback). Per docs/superpowers/specs/2026-05-22-isp-natural-capture-design.md.`

- [ ] **Step 4: Propose final commit** `docs(camerakit): log ISP natural-capture decision + HITL evidence` (regen CONTRACTS via the pre-commit hook).

---

## Self-Review

**Spec coverage:** R1 ISP source → T2/T3; R2 live grade → T1; R3 TIFF + crop → T1 (crop)/T4 (TIFF); R4 same settings → T2 (settings) + T1 (grade) + T4 (shared device); R5 captureImage untouched → no task modifies it; R6 pause errors → T4; R7 `.balanced` → T2. All covered.

**Placeholders:** The `if photosDestination != .none { /* existing publish block */ }` in T4 references the existing copy in `captureNaturalPicture`/`captureImage` — copy it verbatim. No other gaps.

**Type consistency:** `gradeOneShot(pixelBuffer:) -> CVPixelBuffer` (T1) is consumed in T4; `StillPhotoCapture.makeSettings()` / `.capture(using:)` (T2) consumed by `CameraSession.capturePhoto()` (T3) consumed by T4. `outputSize` used for `encode`'s `captureSize:` arg (the graded buffer is `outputSize`, matching the cropped result). Consistent.
