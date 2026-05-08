# Family B (Bugs 8, 13) + Calibration Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the open Family-B pre-existing bugs (8, 13) and rebuild the calibration surface around correctness:
- WB Calibrate sources its sample from the natural lane (pre-tonemap RGB), stacks the reciprocal correction onto AVFoundation's current device gains, normalizes so `min == 1.0`, and clamps each channel to `[1.0, maxWhiteBalanceGain]`.
- "Auto WB" and "Lock WB" become first-class user actions backed by `wbMode = .auto` and `wbMode = .locked` respectively.
- BB sampling reads from a one-shot scratch texture rendered with **current BCSG params and BB zeroed** — so the sample reflects the user's brightness/contrast/saturation/gamma but not the prior pedestal (the value BB will operate on, with no feedback loop). BB application moves to the *end* of the color pipeline (per user direction) and the public API documents the new order.
- Calibration becomes a per-session intent: `SettingsPersistence.load()` strips `wbMode = .manual` plus the gain triple so each launch starts in continuous AWB.

**Bug-12 status note:** the multi-minute black-preview freeze documented in `docs/stage-11-pre-existing-bugs.md` §Bug 12 is no longer reproducing on `stage-01` HEAD as of 2026-05-08 — preview is black for ~1 s of normal init latency, then live. Most likely closed by side effect of Bug 4 (live mailbox forwarding), Bug 6 (`sessionPreset = .inputPriority`), or Bug 15 (scenePhase / session-resume) fixes. We do not chase it here. The persistence policy (Task 5) also makes any latent recurrence harmless.

**Architecture:**
- **Three WB actions:** WB Calibrate (sample-and-compute, resolution-scaled center patch (96 px at default 4160×3120; floor of 16)), Lock WB (freeze whatever AVFoundation continuous AWB has converged on), Auto WB (return to `.continuousAutoWhiteBalance`).
- **Two BB actions:** BB Calibrate (sample-and-write per-channel pedestal), Reset BB (zero the pedestal).
- **WB math correctness (research-driven):** the sample comes from a Metal texture *after* AVCaptureDevice has already applied its WB gains, so the gray-world reciprocal is a *delta* correction. New absolute gain = `currentDeviceGain × (mean / channel)`. Normalize so min == 1.0 (Apple does this internally too — making it explicit keeps clamping predictable). Clamp each channel to `[1.0, maxWhiteBalanceGain]`. Linearize the gamma-encoded sample first via sRGB EOTF before computing the reciprocal — `naturalTex` is BT.601 full-range YCbCr→RGB which is gamma-encoded. Source: `AVCaptureDevice.h` lines 1244–1434, WWDC 2014 §508.
- **Pipeline reorder:** `ColorShaders.metal` moves BB from step 1 to step 5. BB now subtracts the pedestal from the *graded* output, behaving like a final shadow lift rather than a noise-floor compensation. This contradicts `architecture/07-settings.md §Processing order`; per CLAUDE.md §8 user instructions override architecture and we log the decision in `CameraKit/state.md`.
- **AE/AWB convergence signal:** WB Calibrate awaits `device.isAdjustingWhiteBalance == false` via KVO with a 2-second timeout, instead of a magic-millisecond sleep.

**Tech Stack:** Swift 6.2 (strict concurrency), Swift Testing framework, SwiftUI, MetalKit, AVFoundation, iOS 26.

---

## File Manifest

**Modify:**
- `CameraKit/Sources/CameraKit/MetalPipeline.swift` (`dispatchCenterPatch` parameterized over texture lane)
- `CameraKit/Sources/CameraKit/CameraEngine.swift` (`sampleCenterPatchOnNatural`, `currentDeviceWBGains`, `maxWhiteBalanceGain`, `awaitWBSettled`)
- `CameraKit/Sources/CameraKit/CameraSession.swift` (LiveCaptureDevice forwarding for the new methods)
- `CameraKit/Sources/CameraKit/CalibrationCompute.swift` (gain math rewrite)
- `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` (5 actions + protocol expansion)
- `CameraKit/Sources/CameraKit/SettingsPersistence.swift` (strip manual WB on load)
- `CameraKit/Sources/CameraKit/CameraView.swift` (5 buttons in sidebar + reticle overlay)
- `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal` (reorder BB to step 5)
- `CameraKit/Sources/CameraKit/ProcessingViewModel.swift` (doc-comment on `applyBlackBalance`)
- `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` (math + VM tests)
- `CameraKit/state.md` (decision log entry)

**Create:** none.

---

## Task 1: Parameterize `MetalPipeline.dispatchCenterPatch` over the source texture

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:600-657`

The existing `dispatchCenterPatch()` always reads `latestProcessedTex`. Calibration needs to also read `latestNaturalTex`. Cleanest refactor: add a private overload that takes an explicit texture, leave the existing public method as a wrapper, add a new `dispatchCenterPatchOnNatural()` wrapper.

- [ ] **Step 1.1: Refactor `dispatchCenterPatch` over an injected texture**

Replace `MetalPipeline.swift:597-657` with:

```swift
    /// Returns the center-patch sample size in pixels, scaled with capture
    /// resolution and clamped to a 16-pixel minimum.
    ///
    /// `Constants.centerPatchSizePx` (96) is the baseline at the default
    /// 4160×3120 capture; below that, the patch shrinks proportionally with
    /// the shorter texture dimension so we don't over-sample on a downsized
    /// lane. Floor of 16 keeps a 16×16 threadgroup viable.
    static func scaledCenterPatchSize(captureSize: Size) -> Int {
        let baseShorter = min(
            Constants.captureDefaultWidthPx,
            Constants.captureDefaultHeightPx
        )
        let curShorter = min(captureSize.width, captureSize.height)
        let scaled = Int((Double(Constants.centerPatchSizePx)
            * Double(curShorter) / Double(baseShorter)).rounded())
        return max(16, scaled)
    }

    /// Encodes the center-patch sampler over a caller-supplied texture and returns one RgbSample.
    private func dispatchCenterPatch(on tex: MTLTexture) async throws -> RgbSample {
        let patchSize = Self.scaledCenterPatchSize(captureSize: captureSize)
        let texW = tex.width
        let texH = tex.height
        guard texW >= patchSize, texH >= patchSize else {
            throw MetalError.unsupportedFormat
        }

        var uniform = PatchUniform(
            patchSize: UInt32(patchSize),
            patchOriginX: UInt32((texW - patchSize) / 2),
            patchOriginY: UInt32((texH - patchSize) / 2)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }

        encoder.setComputePipelineState(centerPatchPSO)
        encoder.setTexture(tex, index: 0)
        encoder.setBuffer(patchBufferR, offset: 0, index: 0)
        encoder.setBuffer(patchBufferG, offset: 0, index: 1)
        encoder.setBuffer(patchBufferB, offset: 0, index: 2)
        encoder.setBytes(&uniform, length: MemoryLayout<PatchUniform>.stride, index: 3)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (patchSize + 15) / 16,
            height: (patchSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        let bufR = patchBufferR
        let bufG = patchBufferG
        let bufB = patchBufferB
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }

        let count = patchSize * patchSize
        let trimCount = (count * Constants.centerPatchTrimPercent) / 100
        let r = trimmedMean(buffer: bufR, count: count, trim: trimCount)
        let g = trimmedMean(buffer: bufG, count: count, trim: trimCount)
        let b = trimmedMean(buffer: bufB, count: count, trim: trimCount)
        return RgbSample(r: Double(r), g: Double(g), b: Double(b))
    }

    /// Public entry point — samples the latest **processed** texture (post Pass-2 grade).
    ///
    /// Used for diagnostic / metric paths. Calibration paths should prefer
    /// `dispatchCenterPatchOnNatural()` so the sample isn't biased by the
    /// previously-applied calibration state.
    func dispatchCenterPatch() async throws -> RgbSample {
        try await dispatchCenterPatch(on: currentProcessedTex())
    }

    /// WB calibration entry point — samples the latest **natural** texture (Pass-1 output).
    ///
    /// `naturalTex` is BT.601 full-range YCbCr→RGB conversion only — no GPU-side
    /// brightness/contrast/saturation/gamma/black-balance applied. Used for WB
    /// calibration because WB gains operate on the AVCaptureDevice's raw sensor
    /// path, so the sample must be in the same color space (pre-grade).
    func dispatchCenterPatchOnNatural() async throws -> RgbSample {
        try await dispatchCenterPatch(on: currentTexture())
    }

    /// BB calibration entry point — samples a one-shot scratch render of
    /// **current BCSG with BB zeroed**.
    ///
    /// Why this lane: BB is applied at the end of the GPU color pipeline (post
    /// brightness/contrast/saturation/gamma) per `Shaders/ColorShaders.metal`.
    /// For BB to correctly subtract a dark patch in the *graded* image, the
    /// sample must be read from the same color space — i.e. with BCSG
    /// applied — but without the previously-written BB pedestal feeding back
    /// into the math.
    ///
    /// Implementation: snapshot the current `ColorUniform`, zero its BB
    /// triple, dispatch a one-shot Pass-2 encode from `naturalTex` into a
    /// scratch texture, then run the center-patch sampler on the scratch.
    /// Visually invisible to the user — the live `processedTex` mailbox is
    /// not touched.
    func dispatchBBCalibrationSample() async throws -> RgbSample {
        guard let naturalTex = latestNaturalTex else {
            throw MetalError.unsupportedFormat
        }

        // Allocate scratch texture (released at function exit).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: captureSize.width,
            height: captureSize.height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        guard let scratchTex = device.makeTexture(descriptor: desc) else {
            throw MetalError.commandBufferFailed(code: -10)
        }

        // Snapshot current BCSG uniforms; zero BB.
        //
        // Correctness: `uniforms.withLock { $0.color }` returns a *value copy*
        // of the ColorUniform struct. Mutating `params.blackR/G/B` writes to
        // the local copy only — the live Mutex is unmodified, so the regular
        // encode loop continues to use the user's actual BB. The shader below
        // reads from `&params` via setBytes (not from the Mutex), so it sees
        // the zeroed BB. Integration test in Stage11Tests proves this.
        var params = uniforms.withLock { $0.color }
        params.blackR = 0
        params.blackG = 0
        params.blackB = 0

        guard let cb = commandQueue.makeCommandBuffer(),
            let encoder = cb.makeComputeCommandEncoder()
        else {
            throw MetalError.commandBufferFailed(code: -11)
        }
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(naturalTex, index: 0)
        encoder.setTexture(scratchTex, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (scratchTex.width + 15) / 16,
            height: (scratchTex.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cb.addCompletedHandler { c in
                if c.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -12))
                } else {
                    cont.resume()
                }
            }
            cb.commit()
        }

        return try await dispatchCenterPatch(on: scratchTex)
    }
```

`currentTexture()` is the existing accessor for `latestNaturalTex`. Verify the field name and the Pass-2 PSO name (likely `colorTransformPSO`) match the existing `MetalPipeline` declarations — adapt the symbol names if they differ. The `device` and `uniforms` properties are already on `MetalPipeline`.

**Buffer capacity check:** confirm `patchBufferR/G/B` are allocated at `Constants.centerPatchSizePx²` elements (i.e. 96² = 9216 floats). Variable `patchSize` from `scaledCenterPatchSize` is always ≤ 96, so the existing buffers hold any scaled patch. If the current allocation derives the size dynamically, change it to use the constant maximum so a smaller capture lane doesn't get a smaller buffer that the next resize would underrun.

- [ ] **Step 1.2: Build to confirm it compiles**

```text
mcp__XcodeBuildMCP__build_device  (defaults already set)
```
Or fallback: `scripts/build-summary.sh`

Expected: `BUILD: success`. Existing call sites of `dispatchCenterPatch()` (no-arg) still compile because the no-arg variant remains.

- [ ] **Step 1.3: Add integration test for the BB-zero property + the patch-size scaling**

Append this suite to `Stage11Tests.swift`. The first test proves that `dispatchBBCalibrationSample` ignores the live BB triple in `ColorUniform`; the second pins the scaling formula.

```swift
@Suite("Stage 11 — BB calibration scratch encode")
struct Stage11BBCalibrationScratchTests {

    @Test("dispatchBBCalibrationSample ignores live BB pedestal (sample = BCSG-only)")
    func bbScratchZeroesPedestal() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Identity BCSG with a NON-zero BB pedestal in the live uniforms.
        // If the scratch path failed to zero BB, the sample would read
        // 0.5 - 0.2 = 0.3 per channel. With BB zeroed in the scratch, sample
        // should be 0.5 (identity BCSG passes the input through).
        pipeline.setProcessingForTest(ProcessingParameters(
            brightness: 0,
            contrast: 1,
            saturation: 0,
            blackR: 0.2,
            blackG: 0.2,
            blackB: 0.2,
            gamma: 1
        ))

        // Inject a uniform 0.5 into naturalTex.
        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

        let sample = try await pipeline.dispatchBBCalibrationSample()

        // BB = 0 in the scratch → sample equals the BCSG-passthrough value.
        #expect(abs(sample.r - 0.5) < 1e-2)
        #expect(abs(sample.g - 0.5) < 1e-2)
        #expect(abs(sample.b - 0.5) < 1e-2)
    }

    @Test("scaledCenterPatchSize: default → 96, fallback → ≥16, tiny → clamped to 16")
    func scaledCenterPatchSize() {
        // 4160×3120 default → exact 96 (no scaling).
        #expect(MetalPipeline.scaledCenterPatchSize(
            captureSize: Size(width: 4160, height: 3120)) == 96)
        // 1280×960 fallback → ~30 (96 × 960/3120 ≈ 29.5).
        let s2 = MetalPipeline.scaledCenterPatchSize(
            captureSize: Size(width: 1280, height: 960))
        #expect(s2 >= 16 && s2 <= 32)
        // Tiny 480×360 → would compute ~11; clamps to 16 minimum.
        #expect(MetalPipeline.scaledCenterPatchSize(
            captureSize: Size(width: 480, height: 360)) == 16)
    }
}
```

This requires three test seams on `MetalPipeline`:
- `setProcessingForTest(_ params: ProcessingParameters)` — write through the same path `setProcessingParameters` uses (mutate uniforms via `Mutex`). If a similar seam doesn't exist, add it as `internal` next to `setLatestProcessedForTest`.
- `setLatestNaturalForTest(buffer:texture:)` — symmetric to the existing `setLatestProcessedForTest`. Add if missing.
- `naturalPoolForTest: CVPixelBufferPool` — already exists per `MetalPipeline.swift:730`.

`fillBufferUniform` is the helper used by Stage 04 tests in the same file — reuse.

- [ ] **Step 1.4: Run the integration test**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage11BBCalibrationScratchTests
```

Expected: both tests PASS. If `bbScratchZeroesPedestal` reads ~0.3 instead of ~0.5 the BB-zero invariant is broken — investigate the `setBytes` call site.

- [ ] **Step 1.5: Commit**

```bash
git add CameraKit/Sources/CameraKit/MetalPipeline.swift
git commit -m "$(cat <<'EOF'
feat(metal): two calibration sampling paths + resolution-scaled patch

dispatchCenterPatchOnNatural() reads naturalTex (no BCSG, no BB) for WB
calibration where the sample must be in raw-sensor color space.

dispatchBBCalibrationSample() snapshots current BCSG uniforms with BB
zeroed, runs a one-shot Pass-2 encode into a scratch texture, samples
the center patch from there. Result: BB sample reflects current
BCSG transformations but not the prior pedestal. Live uniforms are
untouched (value-copy + setBytes); integration test in Stage11Tests
asserts a known-input BB=0 invariant on real Metal.

scaledCenterPatchSize(captureSize:) replaces the fixed 96-px patch with
96 × shorter_dim / 3120, clamped to a 16-pixel minimum — patch shrinks
proportionally on smaller capture lanes without going below a viable
threadgroup size.

The default no-arg dispatchCenterPatch() still reads processedTex for
diagnostic / metric callers.
EOF
)"
```

---

## Task 2: Engine surface — `currentDeviceWBGains`, `maxWhiteBalanceGain`, `awaitWBSettled`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` (add 3 public methods near the existing `sampleCenterPatch`)
- Modify: `CameraKit/Sources/CameraKit/CameraSession.swift` (LiveCaptureDevice forwarding)

These give the calibration flow read-access to the device's current WB state and a KVO-backed convergence signal — replacing the magic-ms `awaitAutoWBSettle()` from prior plan revisions.

- [ ] **Step 2.1: Add device-side accessors and KVO wait on `LiveCaptureDevice`**

Find the `LiveCaptureDevice` declaration in `CameraSession.swift` (search for `final class LiveCaptureDevice` or `actor LiveCaptureDevice` — currently around line 100–160 area). Add these methods inside the type body:

```swift
    /// Current WB gains applied by AVCaptureDevice — whatever continuous AWB or a
    /// prior manual lock most recently set. Reads `avDevice.deviceWhiteBalanceGains`.
    var currentDeviceWBGains: WhiteBalanceGains {
        let g = avDevice.deviceWhiteBalanceGains
        return WhiteBalanceGains(red: g.redGain, green: g.greenGain, blue: g.blueGain)
    }

    /// Awaits `isAdjustingWhiteBalance == false` via KVO. Returns immediately if
    /// already settled. Times out after 2 s (defensive — a rarely-stalled AWB
    /// shouldn't hang calibration). Source: WWDC 2014 §508 manual-controls flow.
    func awaitWBSettled() async {
        if !avDevice.isAdjustingWhiteBalance { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [avDevice] in
                await withCheckedContinuation { cont in
                    var done = false
                    let lock = NSLock()
                    var observation: NSKeyValueObservation?
                    observation = avDevice.observe(
                        \.isAdjustingWhiteBalance, options: [.new]
                    ) { _, change in
                        guard change.newValue == false else { return }
                        lock.lock(); defer { lock.unlock() }
                        if done { return }
                        done = true
                        observation?.invalidate()
                        cont.resume()
                    }
                    // Race: if already settled by the time the observer is wired up,
                    // resume immediately.
                    if !avDevice.isAdjustingWhiteBalance {
                        lock.lock(); defer { lock.unlock() }
                        if !done {
                            done = true
                            observation?.invalidate()
                            cont.resume()
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
            }
            await group.next()
            group.cancelAll()
        }
    }
```

If `LiveCaptureDevice` is an `actor`, the `var currentDeviceWBGains` and `func awaitWBSettled()` go on the actor (callers `await` them). The KVO observer lives outside the actor isolation — `avDevice.observe(...)` runs on the AVCaptureDevice's KVO scheduler, so `avDevice` must be captured into the inner closure (already done above).

If your `LiveCaptureDevice` wrapper exposes `avDevice` only via an internal-isolated field, add a `nonisolated` accessor or move the `awaitWBSettled` helper to a free function that takes `AVCaptureDevice` directly.

- [ ] **Step 2.2: Add engine-level forwarders**

In `CameraEngine.swift`, find the `sampleCenterPatch` method (around line 628). Add right after it:

```swift
    /// WB-calibration sampler — reads from `naturalTex` (Pass-1 output). See
    /// `MetalPipeline.dispatchCenterPatchOnNatural` for the rationale.
    public func sampleCenterPatchOnNatural() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchCenterPatchOnNatural()
    }

    /// BB-calibration sampler — reads from a one-shot scratch render of current
    /// BCSG with BB zeroed. See `MetalPipeline.dispatchBBCalibrationSample` for
    /// the rationale.
    public func sampleCenterPatchForBBCalibration() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchBBCalibrationSample()
    }

    /// Current AVCaptureDevice WB gains — whatever continuous AWB or a prior
    /// manual lock most recently set. Used by `CalibrationViewModel.calibrateWB`
    /// to *stack* the gray-world reciprocal correction onto the active gains.
    public func currentDeviceWBGains() async throws -> WhiteBalanceGains {
        guard let device = cameraSession?.device as? LiveCaptureDevice else {
            throw EngineError.notOpen
        }
        return await device.currentDeviceWBGains
    }

    /// Device's max legal WB gain — feeds the per-channel clamp at the end of
    /// `CalibrationCompute.grayWorldGains`.
    public func maxWhiteBalanceGain() async throws -> Float {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        return await device.maxWhiteBalanceGain
    }

    /// Awaits AE/AWB convergence after a mode switch (KVO-backed, 2s timeout).
    /// Used by `CalibrationViewModel.calibrateWB` between writing `.auto` and
    /// reading `currentDeviceWBGains`.
    public func awaitWBSettled() async {
        guard let device = cameraSession?.device as? LiveCaptureDevice else { return }
        await device.awaitWBSettled()
    }
```

- [ ] **Step 2.3: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`.

- [ ] **Step 2.4: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraSession.swift \
        CameraKit/Sources/CameraKit/CameraEngine.swift
git commit -m "$(cat <<'EOF'
feat(engine): expose currentDeviceWBGains, maxWhiteBalanceGain, awaitWBSettled

Plumbing for the rewritten WB Calibrate flow. KVO-backed convergence
signal replaces the magic-ms sleep in prior plan revisions; 2s timeout
keeps a stalled AWB from hanging the calibrate path. Source: WWDC 2014
§508, AVCaptureDevice.h lines 1244–1434.
EOF
)"
```

---

## Task 3: `CalibrationCompute.grayWorldGains` rewrite

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CalibrationCompute.swift:8-34`
- Modify: `CameraKit/Sources/CameraKit/FrameSet.swift:129-138` (drop or update the convenience init)

The new signature takes the sample, the current gains, and the device max. It linearizes the sample (sRGB EOTF approximation), computes the reciprocal correction, *stacks* it onto the current gains by multiplication, normalizes so min == 1.0, then per-channel clamps to `[1.0, maxGain]`.

- [ ] **Step 3.1: Replace `grayWorldGains` and add an internal sRGB linearization helper**

Replace `CalibrationCompute.swift:8-34` with:

```swift
public enum CalibrationCompute {

    /// Gray-world reciprocal gains, linearized + stacked onto current device gains.
    ///
    /// Source: WWDC 2014 §508 + `AVCaptureDevice.h` lines 1244–1434.
    ///
    /// - Parameter sample: per-channel trimmed-mean read from `naturalTex`
    ///   (BT.601 full-range gamma-encoded RGB).
    /// - Parameter current: WB gains applied by `AVCaptureDevice` at the moment
    ///   the sample was taken — `device.deviceWhiteBalanceGains`.
    /// - Parameter maxGain: `device.maxWhiteBalanceGain` — used for the final
    ///   per-channel clamp.
    ///
    /// Steps:
    ///   1. Linearize the gamma-encoded sample channels (sRGB EOTF).
    ///   2. Compute reciprocal correction `mean / channel` per channel.
    ///   3. Stack onto current gains: `newGain = current × reciprocal` (the
    ///      sample is post-WB, so the reciprocal is a *delta* not an absolute).
    ///   4. Normalize to `min == 1.0` (Apple does this internally too —
    ///      making it explicit keeps clamping predictable).
    ///   5. Per-channel clamp to `[1.0, maxGain]`.
    public static func grayWorldGains(
        sample: RgbSample,
        current: WhiteBalanceGains,
        maxGain: Float
    ) -> WhiteBalanceGains {
        let lr = srgbLinearize(sample.r)
        let lg = srgbLinearize(sample.g)
        let lb = srgbLinearize(sample.b)

        let eps = 1e-4
        let r = max(eps, lr)
        let g = max(eps, lg)
        let b = max(eps, lb)
        let mean = (r + g + b) / 3.0

        var newR = current.red   * Float(mean / r)
        var newG = current.green * Float(mean / g)
        var newB = current.blue  * Float(mean / b)

        let m = min(newR, min(newG, newB))
        if m > 0 {
            newR /= m
            newG /= m
            newB /= m
        }

        return WhiteBalanceGains(
            red:   min(maxGain, max(1.0, newR)),
            green: min(maxGain, max(1.0, newG)),
            blue:  min(maxGain, max(1.0, newB))
        )
    }

    /// Black-balance pedestal: per-channel dark-patch sample passes through as offsets.
    ///
    /// **Important:** the BB pedestal is subtracted at the *end* of the GPU color
    /// pipeline (after brightness/contrast/saturation/gamma) per `ColorShaders.metal`
    /// step 5. The sample fed in here MUST come from a render where **BCSG is
    /// applied and BB is zeroed** — typically `CameraEngine.sampleCenterPatchForBBCalibration`,
    /// which runs a one-shot Pass-2 encode into a scratch texture with BB
    /// temporarily zeroed. This satisfies two requirements simultaneously:
    /// the sample is in the same color space the pedestal will operate on
    /// (BCSG applied), and it isn't biased by the prior pedestal (BB zeroed).
    /// Caller writes these into `ProcessingParameters.blackR/G/B`.
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        (sample.r, sample.g, sample.b)
    }

    /// sRGB EOTF — converts a gamma-encoded channel value to linear light.
    ///
    /// Why sRGB specifically (research-backed, 2026-05-08):
    ///   - `naturalTex` is `MTLPixelFormat.rgba16Float` with no `_sRGB` suffix,
    ///     so Metal performs no implicit transform on read/write — values are
    ///     stored exactly as written.
    ///   - The Y'CbCr → R'G'B' BT.601 matrix in `YUVToRGBA.metal` is linear
    ///     applied to already-gamma-encoded Y' (the prime denotes gamma) so
    ///     the output is gamma-encoded R'G'B'.
    ///   - `CameraView.swift` sets `(mtkView.layer as? CAMetalLayer)?.colorspace = sRGB`,
    ///     asserting to the compositor "interpret these values as sRGB-encoded".
    ///     For math intended to match what's on screen, sRGB EOTF is the
    ///     consistent inverse.
    ///
    /// Skipping this step biases gains by 5–15% depending on the scene
    /// mid-tone level (per research dispatched in this session).
    private static func srgbLinearize(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }
}
```

- [ ] **Step 3.2: Drop the `WhiteBalanceGains.init(fromGrayWorld:)` convenience init**

Remove `FrameSet.swift:129-138` entirely — the old single-arg init no longer matches the new signature, and the only caller in tests can use `CalibrationCompute.grayWorldGains` directly.

```swift
// Remove this entire extension:
//
// extension WhiteBalanceGains {
//     public init(fromGrayWorld sample: RgbSample) {
//         self = CalibrationCompute.grayWorldGains(sample: sample)
//     }
// }
```

- [ ] **Step 3.3: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`. The test file may now have a compile error in `whiteBalanceGainsFromGrayWorldConvenience` — that's expected; Task 4 fixes it.

- [ ] **Step 3.4: Commit**

```bash
git add CameraKit/Sources/CameraKit/CalibrationCompute.swift \
        CameraKit/Sources/CameraKit/FrameSet.swift
git commit -m "$(cat <<'EOF'
fix(calibration): rewrite grayWorldGains — linearize + stack + clamp (Bug 13)

The sample comes from naturalTex AFTER AVCaptureDevice has already applied
its WB gains, so the gray-world reciprocal is a delta correction —
new absolute gain = currentGain × (mean / channel). Linearize the
gamma-encoded sample (sRGB EOTF) before the math, normalize so min == 1.0,
and per-channel clamp to [1.0, maxWhiteBalanceGain]. Drops the now-broken
WhiteBalanceGains.init(fromGrayWorld:) convenience init. Source:
WWDC 2014 §508, AVCaptureDevice.h lines 1244–1434.
EOF
)"
```

---

## Task 4: `grayWorldGains` test update

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage11Tests.swift:7-49`

- [ ] **Step 4.1: Replace the `Stage11CalibrationComputeTests` suite**

Replace lines 7-49 (the entire `Stage11CalibrationComputeTests` suite) with:

```swift
// MARK: - Stage 11 — Calibration compute (pure helpers)

@Suite("Stage 11 — calibration compute")
struct Stage11CalibrationComputeTests {

    // Identity gains — useful for tests that want the reciprocal-only behavior
    // without the stacking multiplier.
    private let unityGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    private let typicalMax: Float = 4.0

    @Test("neutral linear sample with unity current gains returns unity (no-op)")
    func grayWorldNeutralLinearSampleIsNoOp() {
        // Linear value 0.5 maps via sRGB EOTF to ~0.214 — but for r==g==b the mean
        // ratio is exactly 1, so newGain == current regardless of linearization.
        let sample = RgbSample(r: 0.5, g: 0.5, b: 0.5)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(abs(gains.red   - 1.0) < 1e-5)
        #expect(abs(gains.green - 1.0) < 1e-5)
        #expect(abs(gains.blue  - 1.0) < 1e-5)
    }

    @Test("bluish sample produces gains all ≥ 1.0 with B anchored (no pink-tint regression)")
    func grayWorldBluishSampleAnchorsBlue() {
        // B is the brightest channel — its corrected gain ends up at min after
        // normalization → exactly 1.0. R/G are scaled up correspondingly.
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.8)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(gains.red   >= 1.0)
        #expect(gains.green >= 1.0)
        #expect(abs(gains.blue - 1.0) < 1e-5)
        #expect(gains.red > gains.green)
        #expect(gains.green > gains.blue)
    }

    @Test("stacks reciprocal onto non-unity current gains (delta correction semantics)")
    func grayWorldStacksOntoCurrentGains() {
        // Same sample, two different current gains — the *ratio* between channels
        // in the result must reflect the multiplied product (current × reciprocal).
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.6)
        let unityResult = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        let scaledCurrent = WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5)
        let scaledResult = CalibrationCompute.grayWorldGains(
            sample: sample, current: scaledCurrent, maxGain: typicalMax)

        // The unity result has ratios r:g:b == reciprocal ratios.
        // The scaled result has ratios r:g:b == (current × reciprocal) ratios.
        // After min-normalization both are normalized — but their channel ratios
        // diverge because the inputs do.
        let unityRG = unityResult.red / unityResult.green
        let scaledRG = scaledResult.red / scaledResult.green
        #expect(unityRG != scaledRG, "stacking must change the per-channel ratio")
    }

    @Test("clamps each channel to [1.0, maxGain]")
    func grayWorldClampsToMaxGain() {
        // Severe correction case: very dim red channel + already-high red current
        // gain → product blows past maxGain.
        let sample = RgbSample(r: 0.05, g: 0.5, b: 0.5)
        let aggressiveCurrent = WhiteBalanceGains(red: 3.5, green: 1.0, blue: 1.0)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: aggressiveCurrent, maxGain: typicalMax)
        #expect(gains.red   <= typicalMax)
        #expect(gains.green >= 1.0)
        #expect(gains.blue  >= 1.0)
    }

    @Test("near-zero channels are clamped to epsilon (no division by zero)")
    func grayWorldClampsZeroChannel() {
        let sample = RgbSample(r: 0.0, g: 0.5, b: 0.5)
        let gains = CalibrationCompute.grayWorldGains(
            sample: sample, current: unityGains, maxGain: typicalMax)
        #expect(gains.red.isFinite)
        #expect(gains.red >= 1.0)
    }

    @Test("black-balance offsets are per-channel sample values")
    func blackBalanceOffsetsPassthrough() {
        let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
        let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
        #expect(offsets.r == 0.02)
        #expect(offsets.g == 0.03)
        #expect(offsets.b == 0.05)
    }
}
```

- [ ] **Step 4.2: Run tests to verify they pass**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage11CalibrationComputeTests
```

Expected: all six tests PASS.

- [ ] **Step 4.3: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "$(cat <<'EOF'
test(calibration): rewrite grayWorldGains tests for new signature

Covers: linear-neutral no-op, bluish-sample anchors blue (pink-tint
regression), stacking semantics over non-unity current gains, max-gain
clamp, zero-channel epsilon, BB pass-through.
EOF
)"
```

---

## Task 5: Persistence policy — strip manual WB on load

**Files:**
- Modify: `CameraKit/Sources/CameraKit/SettingsPersistence.swift:15-18`
- Modify: `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` (append new suite)

- [ ] **Step 5.1: Append the test suite**

Append to the bottom of `Stage11Tests.swift`:

```swift
// MARK: - Stage 11 — Settings persistence WB policy

@Suite("Stage 11 — settings persistence WB policy")
struct Stage11SettingsPersistenceWBTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "CameraKitTests.SettingsPersistence.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test("manual WB + gains are stripped on load (per-session policy)")
    func manualWBStrippedOnLoad() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.iso = 800
        s.wbMode = .manual
        s.wbGainR = 1.5
        s.wbGainG = 1.2
        s.wbGainB = 1.0
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.iso == 800)
        #expect(loaded?.wbMode == nil)
        #expect(loaded?.wbGainR == nil)
        #expect(loaded?.wbGainG == nil)
        #expect(loaded?.wbGainB == nil)
    }

    @Test("auto WB round-trips (only .manual is stripped)")
    func autoWBRoundTrips() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.wbMode = .auto
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded?.wbMode == .auto)
    }

    @Test("locked WB round-trips (only .manual is stripped)")
    func lockedWBRoundTrips() {
        let defaults = makeIsolatedDefaults()
        var s = CameraSettings()
        s.wbMode = .locked
        SettingsPersistence.save(s, defaults: defaults)

        let loaded = SettingsPersistence.load(defaults: defaults)
        #expect(loaded?.wbMode == .locked)
    }
}
```

- [ ] **Step 5.2: Run tests to verify the manual-WB test fails**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage11SettingsPersistenceWBTests
```

Expected: `manualWBStrippedOnLoad` FAILS; the two round-trip tests PASS.

- [ ] **Step 5.3: Implement the strip-on-load policy**

Replace `SettingsPersistence.swift:15-18`:

```swift
    /// Load persisted CameraSettings, stripping `wbMode = .manual` plus the gain triple.
    ///
    /// Calibration is a per-session intent: each launch should start in continuous
    /// AWB so a stale manual lock from a prior session doesn't sticky-tint the
    /// preview. `.auto` and `.locked` round-trip unchanged because those are
    /// explicit user choices.
    static func load(defaults: UserDefaults = .standard) -> CameraSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard var settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else {
            return nil
        }
        if settings.wbMode == .manual {
            settings.wbMode = nil
            settings.wbGainR = nil
            settings.wbGainG = nil
            settings.wbGainB = nil
        }
        return settings
    }
```

- [ ] **Step 5.4: Run tests to verify all three pass**

Same command as 5.2. Expected: all three PASS.

- [ ] **Step 5.5: Commit**

```bash
git add CameraKit/Sources/CameraKit/SettingsPersistence.swift \
        CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "$(cat <<'EOF'
feat(persistence): strip manual WB on load — boot in auto every launch

Calibration is a per-session intent: each launch starts in continuous
AWB. `.auto` and `.locked` round-trip unchanged because those are
explicit user choices. Also makes any latent recurrence of the
historical Bug-12 cold-launch-black symptom harmless.
EOF
)"
```

---

## Task 6: `CalibrationViewModel` — five actions

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` (entire file)

Five actions: `calibrateWB`, `resetToAutoWB`, `lockCurrentWB`, `calibrateBB`, `resetBlackBalance`. Protocol expansion: 4 new methods.

- [ ] **Step 6.1: Rewrite the file**

Replace the entire contents of `CalibrationViewModel.swift`:

```swift
import Foundation

/// Engine surface used by `CalibrationViewModel`.
///
/// Test-injection seam: production wires `CameraEngine` directly via the
/// extension below. Tests substitute a stub that records inputs/outputs without
/// requiring an `AVCaptureSession`.
protocol CalibrationEngineProtocol: Sendable {
    /// WB-calibration sample: naturalTex (no BCSG, no BB).
    func sampleCenterPatchOnNatural() async throws -> RgbSample
    /// BB-calibration sample: scratch render with current BCSG and BB zeroed.
    func sampleCenterPatchForBBCalibration() async throws -> RgbSample
    func updateSettings(_ settings: CameraSettings) async throws
    func currentDeviceWBGains() async throws -> WhiteBalanceGains
    func maxWhiteBalanceGain() async throws -> Float
    func awaitWBSettled() async
}

extension CameraEngine: CalibrationEngineProtocol {}

/// White-balance + black-balance calibrate / reset / lock actions.
///
/// Five user-facing actions:
///   1. `calibrateWB()`     — sample-and-compute (resolution-scaled center patch (96 px at default 4160×3120; floor of 16) on naturalTex)
///   2. `resetToAutoWB()`   — return to AVFoundation continuous AWB
///   3. `lockCurrentWB()`   — freeze whatever AVF currently has (`.locked` mode)
///   4. `calibrateBB()`     — sample dark patch on naturalTex; write per-channel pedestal
///   5. `resetBlackBalance()` — zero the BB pedestal
///
/// Holds a reference to `ProcessingViewModel` so BB writes the per-channel
/// pedestal into the same `currentProcessing` source the sliders read from
/// (single owner per the MVVM-decomposition ownership rules).
@Observable @MainActor
final class CalibrationViewModel {

    private let engine: any CalibrationEngineProtocol
    private let processingVM: ProcessingViewModel

    init(engine: any CalibrationEngineProtocol, processingVM: ProcessingViewModel) {
        self.engine = engine
        self.processingVM = processingVM
    }

    /// Bug 13 (revised) — re-baseline + custom-patch gray-world calibration.
    ///
    /// Steps:
    ///   1. Switch device to `.auto` so the next sample is taken from a known baseline.
    ///   2. Await `isAdjustingWhiteBalance == false` via KVO (2s timeout).
    ///   3. Read `currentDeviceWBGains` — the gains AVF converged on.
    ///   4. Sample 96-px patch from `naturalTex` (pre-tonemap, no GPU-side WB).
    ///   5. Compute new manual gains via `CalibrationCompute.grayWorldGains`
    ///      (linearize → stack onto current → normalize → clamp).
    ///   6. Write `wbMode = .manual` with the computed gains.
    func calibrateWB() {
        let engine = self.engine
        Task {
            do {
                var resetDelta = CameraSettings()
                resetDelta.wbMode = .auto
                try await engine.updateSettings(resetDelta)
                await engine.awaitWBSettled()
                let current = try await engine.currentDeviceWBGains()
                let maxGain = try await engine.maxWhiteBalanceGain()
                let sample = try await engine.sampleCenterPatchOnNatural()
                let gains = CalibrationCompute.grayWorldGains(
                    sample: sample, current: current, maxGain: maxGain)
                var manual = CameraSettings()
                manual.wbMode = .manual
                manual.wbGainR = Double(gains.red)
                manual.wbGainG = Double(gains.green)
                manual.wbGainB = Double(gains.blue)
                try await engine.updateSettings(manual)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }

    /// Returns to AVFoundation continuous auto white balance.
    func resetToAutoWB() {
        let engine = self.engine
        Task {
            var delta = CameraSettings()
            delta.wbMode = .auto
            try? await engine.updateSettings(delta)
        }
    }

    /// Freezes whatever WB gains AVFoundation currently has — useful for
    /// "stop the colors from shifting" without sample-and-compute calibration.
    func lockCurrentWB() {
        let engine = self.engine
        Task {
            var delta = CameraSettings()
            delta.wbMode = .locked
            try? await engine.updateSettings(delta)
        }
    }

    /// Black balance: sample a dark patch through the current BCSG with BB
    /// temporarily zeroed, write per-channel pedestal into
    /// `ProcessingParameters.blackR/G/B`. The pedestal is subtracted at the
    /// *end* of the GPU color pipeline (after BCSG) per `ColorShaders.metal`.
    /// The sampling path mirrors that order: BCSG applied (so the sample is
    /// in the same color space the pedestal will subtract from), BB zeroed
    /// (so the sample isn't biased by the previously-applied pedestal). See
    /// `MetalPipeline.dispatchBBCalibrationSample` for the implementation.
    func calibrateBB() {
        let engine = self.engine
        let processingVM = self.processingVM
        Task {
            do {
                let sample = try await engine.sampleCenterPatchForBBCalibration()
                await processingVM.applyBlackBalance(sample: sample)
            } catch {
                // Errors surface through errorStream → ErrorPresenterViewModel.
            }
        }
    }

    /// Zeroes the BB pedestal so the GPU pipeline subtracts nothing.
    func resetBlackBalance() {
        let processingVM = self.processingVM
        Task {
            await processingVM.applyBlackBalance(sample: RgbSample(r: 0, g: 0, b: 0))
        }
    }
}
```

- [ ] **Step 6.2: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`. The existing `CalibrationEngineStub` in tests will fail to compile against the expanded protocol — Task 7 fixes it.

- [ ] **Step 6.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CalibrationViewModel.swift
git commit -m "$(cat <<'EOF'
feat(calibration): five WB/BB actions backed by the new engine surface

calibrateWB rebaseliness via .auto + KVO-wait, samples natural lane,
stacks onto current device gains via the rewritten grayWorldGains.
resetToAutoWB / lockCurrentWB write .auto / .locked respectively.
calibrateBB samples naturalTex (no prior pedestal in the loop).
resetBlackBalance zeroes the pedestal.
EOF
)"
```

---

## Task 7: VM tests for all five actions

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` — replace the existing `Stage11CalibrationVMTests` suite and the `CalibrationEngineStub`.

- [ ] **Step 7.1: Replace `CalibrationEngineStub` and the VM suite**

Find the existing `CalibrationEngineStub` declaration (search `class CalibrationEngineStub` or `actor CalibrationEngineStub`) and the `@Suite("Stage 11 — calibration view model")`. Replace both with:

```swift
// MARK: - Stage 11 — Calibration view model

actor CalibrationEngineStub: CalibrationEngineProtocol {
    let sample: RgbSample
    let bbSample: RgbSample
    let stubCurrent: WhiteBalanceGains
    let stubMaxGain: Float
    var recordedDeltas: [CameraSettings] = []

    init(
        sample: RgbSample,
        bbSample: RgbSample? = nil,
        currentGains: WhiteBalanceGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0),
        maxGain: Float = 4.0
    ) {
        self.sample = sample
        // Default: BB sample == WB sample. Tests that need divergent values
        // pass an explicit `bbSample`.
        self.bbSample = bbSample ?? sample
        self.stubCurrent = currentGains
        self.stubMaxGain = maxGain
    }

    func sampleCenterPatchOnNatural() async throws -> RgbSample { sample }
    func sampleCenterPatchForBBCalibration() async throws -> RgbSample { bbSample }
    func updateSettings(_ settings: CameraSettings) async throws {
        recordedDeltas.append(settings)
    }
    func currentDeviceWBGains() async throws -> WhiteBalanceGains { stubCurrent }
    func maxWhiteBalanceGain() async throws -> Float { stubMaxGain }
    func awaitWBSettled() async { /* no-op for tests */ }
}

@Suite("Stage 11 — calibration view model")
struct Stage11CalibrationVMTests {

    /// Helper: poll until the stub has recorded at least `count` deltas, or timeout.
    @MainActor
    private func awaitDeltas(_ stub: CalibrationEngineStub, count: Int) async -> [CameraSettings] {
        let deadline = ContinuousClock.now + .seconds(1)
        var deltas: [CameraSettings] = []
        while ContinuousClock.now < deadline {
            deltas = await stub.recordedDeltas
            if deltas.count >= count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return deltas
    }

    @Test("calibrateWB rebaselines (.auto) then writes manual with stacked gains")
    @MainActor
    func wbCalibrateRebaselinesAndStacks() async {
        let sample = RgbSample(r: 0.4, g: 0.5, b: 0.8)
        let stub = CalibrationEngineStub(sample: sample)
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.calibrateWB()
        let deltas = await awaitDeltas(stub, count: 2)

        #expect(deltas.count >= 2, "expected .auto pre-sample then .manual write")
        #expect(deltas.first?.wbMode == .auto)
        #expect(deltas.last?.wbMode == .manual)
        let expected = CalibrationCompute.grayWorldGains(
            sample: sample,
            current: WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0),
            maxGain: 4.0)
        #expect(abs((deltas.last?.wbGainR ?? 0) - Double(expected.red))   < 1e-5)
        #expect(abs((deltas.last?.wbGainG ?? 0) - Double(expected.green)) < 1e-5)
        #expect(abs((deltas.last?.wbGainB ?? 0) - Double(expected.blue))  < 1e-5)
    }

    @Test("resetToAutoWB writes wbMode=.auto")
    @MainActor
    func resetToAutoWBWritesAuto() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.resetToAutoWB()
        let deltas = await awaitDeltas(stub, count: 1)

        #expect(deltas.last?.wbMode == .auto)
        #expect(deltas.last?.wbGainR == nil)
    }

    @Test("lockCurrentWB writes wbMode=.locked")
    @MainActor
    func lockCurrentWBWritesLocked() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.lockCurrentWB()
        let deltas = await awaitDeltas(stub, count: 1)

        #expect(deltas.last?.wbMode == .locked)
        #expect(deltas.last?.wbGainR == nil)
    }

    @Test("calibrateBB writes per-channel BB pedestal from natural-lane sample")
    @MainActor
    func bbCalibrateUpdatesProcessingParams() async {
        let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
        let stub = CalibrationEngineStub(sample: sample)
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        vm.calibrateBB()

        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline,
            processingVM.currentProcessing.blackR != 0.02
        {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(abs(processingVM.currentProcessing.blackR - 0.02) < 1e-9)
        #expect(abs(processingVM.currentProcessing.blackG - 0.03) < 1e-9)
        #expect(abs(processingVM.currentProcessing.blackB - 0.05) < 1e-9)
    }

    @Test("resetBlackBalance zeroes the pedestal")
    @MainActor
    func resetBlackBalanceZeroesPedestal() async {
        let stub = CalibrationEngineStub(sample: RgbSample(r: 0.02, g: 0.03, b: 0.05))
        let processingVM = ProcessingViewModel(engine: CameraEngine())
        let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

        // Set a non-zero pedestal first.
        vm.calibrateBB()
        let deadline1 = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline1,
            processingVM.currentProcessing.blackR != 0.02
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(processingVM.currentProcessing.blackR > 0)

        // Reset.
        vm.resetBlackBalance()
        let deadline2 = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline2,
            processingVM.currentProcessing.blackR != 0
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(processingVM.currentProcessing.blackR == 0)
        #expect(processingVM.currentProcessing.blackG == 0)
        #expect(processingVM.currentProcessing.blackB == 0)
    }
}
```

- [ ] **Step 7.2: Run all VM tests**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage11CalibrationVMTests
```

Expected: all five tests PASS.

- [ ] **Step 7.3: Commit**

```bash
git add CameraKit/Tests/CameraKitTests/Stage11Tests.swift
git commit -m "$(cat <<'EOF'
test(calibration): VM tests for five actions + expanded stub

CalibrationEngineStub now satisfies the 5-method protocol; suite covers
calibrateWB rebaseline-and-stack, resetToAutoWB, lockCurrentWB,
calibrateBB pedestal write, resetBlackBalance zero.
EOF
)"
```

---

## Task 8: Sidebar — five buttons (WB Calibrate · Lock WB · Auto WB · BB Calibrate · Reset BB)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift:319-377`

- [ ] **Step 8.1: Replace the WB / BB button rows**

Find the calibration sidebar at `CameraView.swift:319-377`. Replace the `HStack(spacing: 10) { Button("WB Calibrate") ... Button("BB Calibrate") ... }` row plus the surrounding structure with two clearly-labeled rows:

```swift
    private func calibrationSidebar(enablement: ControlEnablement) -> some View {
        let processing = viewModel.processing.currentProcessing
        return VStack(alignment: .leading, spacing: 12) {
            Text("Color Calibration").foregroundStyle(.white).font(.headline)

            // White balance row — three actions.
            VStack(alignment: .leading, spacing: 6) {
                Text("White Balance").foregroundStyle(.white.opacity(0.7)).font(.caption)
                HStack(spacing: 8) {
                    Button("Calibrate") { viewModel.calibration.calibrateWB() }
                        .buttonStyle(.borderedProminent)
                    Button("Lock") { viewModel.calibration.lockCurrentWB() }
                        .buttonStyle(.bordered)
                    Button("Auto") { viewModel.calibration.resetToAutoWB() }
                        .buttonStyle(.bordered)
                }
            }

            // Black balance row — two actions.
            VStack(alignment: .leading, spacing: 6) {
                Text("Black Balance").foregroundStyle(.white.opacity(0.7)).font(.caption)
                HStack(spacing: 8) {
                    Button("Calibrate") { viewModel.calibration.calibrateBB() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset") { viewModel.calibration.resetBlackBalance() }
                        .buttonStyle(.bordered)
                }
            }

            Divider().background(.white.opacity(0.5))

            sliderRow(
                label: "Brightness",
                current: processing.brightness,
                range: -1.0...1.0,
                push: viewModel.processing.pushBrightness
            )
            sliderRow(
                label: "Contrast",
                current: processing.contrast,
                range: 0.0...2.0,
                push: viewModel.processing.pushContrast
            )
            sliderRow(
                label: "Saturation",
                current: processing.saturation,
                range: -1.0...1.0,
                push: viewModel.processing.pushSaturation
            )
            sliderRow(
                label: "Gamma",
                current: processing.gamma,
                range: 0.1...4.0,
                push: viewModel.processing.pushGamma
            )
            Divider().background(.white.opacity(0.5))
            sliderRow(
                label: "Black R", current: processing.blackR, range: 0.0...0.5,
                push: viewModel.processing.pushBlackR)
            sliderRow(
                label: "Black G", current: processing.blackG, range: 0.0...0.5,
                push: viewModel.processing.pushBlackG)
            sliderRow(
                label: "Black B", current: processing.blackB, range: 0.0...0.5,
                push: viewModel.processing.pushBlackB)
            Spacer()
            Button("Reset All Sliders") {
                Task { await viewModel.processing.resetProcessing() }
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(!enablement.isCalibrateEnabled)
        .opacity(enablement.isCalibrateEnabled ? 1.0 : 0.4)
    }
```

The bottom button is renamed "Reset All Sliders" to disambiguate from the targeted "Reset" actions in the WB/BB rows.

- [ ] **Step 8.2: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`.

- [ ] **Step 8.3: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "$(cat <<'EOF'
feat(ui): five calibration buttons (WB Calibrate/Lock/Auto + BB Calibrate/Reset)

Two labeled rows in the sidebar: White Balance with Calibrate/Lock/Auto,
Black Balance with Calibrate/Reset. The "Reset" at the bottom is renamed
"Reset All Sliders" to disambiguate from the targeted resets.
EOF
)"
```

---

## Task 9: `ColorShaders.metal` — reorder BB to step 5

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal:1-71`

- [ ] **Step 9.1: Move BB block from step 1 to step 5; rewrite the header comment**

Replace the entire file contents:

```c++
#include <metal_stdlib>
using namespace metal;

// Stage 04 — color-transform compute kernel operating in RGBA16F.
//
// Order (user-directed; overrides architecture/07-settings.md §Processing order
// — see CameraKit/state.md "Decisions taken that weren't in briefs"):
//   1. Brightness     (positive: power curve; negative: linear scale)
//   2. Contrast       (linear around 0.5 midpoint)
//   3. Saturation     (luma-based mix, COLOR_LUMA_WEIGHT R/G/B per G-18)
//   4. Gamma          (pow(x, 1/gamma))
//   5. Black balance  (subtract per channel, clamp ≥ 0) — applied to graded output
//
// Identity when ColorUniform = { brightness:0, contrast:1, saturation:0,
// gamma:1, blackR:0, blackG:0, blackB:0 } — verified per channel below.
//
struct ColorUniform {
    float brightness;
    float contrast;
    float saturation;
    float blackR;
    float blackG;
    float blackB;
    float gamma;
};

// BT.709 luma coefficients in RGBA channel order (G-18: never apply BGRA
// coefficients to RGBA buffers).
constant float3 COLOR_LUMA_WEIGHT = float3(0.2126, 0.7152, 0.0722);

kernel void colorTransform(texture2d<float, access::read>  inTex  [[texture(0)]],
                           texture2d<float, access::write> outTex [[texture(1)]],
                           constant ColorUniform&          u      [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float4 srgb = inTex.read(gid);
    float3 c = srgb.rgb;

    // 1. Brightness — positive: gamma-style boost; negative: linear scale.
    //    At brightness=0, exponent=1 and scale=1 → identity in both branches.
    if (u.brightness >= 0.0) {
        float exponent = 1.0 / (1.0 + u.brightness);
        c = pow(max(c, 0.0), float3(exponent));
    } else {
        c = c * (1.0 + u.brightness);
    }

    // 2. Contrast — centered linear scale around 0.5. At contrast=1 → identity.
    c = (c - 0.5) * u.contrast + 0.5;

    // 3. Saturation — luma-based mix. At saturation=0, mix factor = 1 → identity.
    //    saturation = -1.0 → fully desaturated (grayscale).
    float luma = dot(c, COLOR_LUMA_WEIGHT);
    c = mix(float3(luma), c, 1.0 + u.saturation);

    // 4. Gamma — power law. At gamma=1, exponent=1 → identity.
    //    Guard against divide-by-zero: shader spec assumes gamma > 0; clamp
    //    defensively in case host passes a stale 0 from an uninitialised slider.
    float safeGamma = max(u.gamma, 1e-3);
    c = pow(max(c, 0.0), float3(1.0 / safeGamma));

    // 5. Black balance — subtract per-channel pedestal from graded output, clamp at 0.
    //    User-directed final-stage subtraction (behaves like a colorist's "lift" on
    //    shadows of the already-graded image rather than a noise-floor compensation).
    c.r = max(0.0, c.r - u.blackR);
    c.g = max(0.0, c.g - u.blackG);
    c.b = max(0.0, c.b - u.blackB);

    outTex.write(float4(c, srgb.a), gid);
}
```

- [ ] **Step 9.2: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`. The Metal shader compiler runs as part of the Xcode build.

- [ ] **Step 9.3: Run Stage 04 color tests**

```bash
scripts/test-summary.sh --filter CameraKitTests/Stage04Tests
```

Expected: all PASS. Stage 04 tests don't assert combined BB+BCSG behavior at non-zero offsets so the reorder doesn't break them. The persistence round-trip test still passes.

- [ ] **Step 9.4: Commit**

```bash
git add CameraKit/Sources/CameraKit/Shaders/ColorShaders.metal
git commit -m "$(cat <<'EOF'
refactor(shaders): apply black balance AFTER brightness/contrast/saturation/gamma

User-directed reorder. Overrides architecture/07-settings.md §Processing
order — logged in CameraKit/state.md (see follow-up commit). BB now
behaves like a final shadow lift on the graded output rather than a
noise-floor pre-compensation; pairs with the calibrate-from-natural-lane
sample path to avoid feedback.
EOF
)"
```

---

## Task 10: Public-API doc-comments — BB ordering

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift` (the `ProcessingParameters` declaration — search for `public var blackR`)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:580-588` (`setProcessingParameters`)
- Modify: `CameraKit/Sources/CameraKit/ProcessingViewModel.swift` (`applyBlackBalance` — search the file)

- [ ] **Step 10.1: Annotate `ProcessingParameters.blackR/G/B`**

Search `Capabilities.swift` for `public var blackR`. Add a single doc-comment above the three properties (or the BB triple if grouped):

```swift
    /// Per-channel black-balance pedestal. The GPU pipeline subtracts these
    /// values from the graded image as the **final** color step, after
    /// brightness, contrast, saturation, and gamma. Range typically `[0, 0.5]`.
    /// See `Shaders/ColorShaders.metal` for the exact order.
    public var blackR: Double
    public var blackG: Double
    public var blackB: Double
```

- [ ] **Step 10.2: Annotate `CameraEngine.setProcessingParameters`**

Replace the doc-comment above `setProcessingParameters` at `CameraEngine.swift:577-580`:

```swift
    /// Stage 05: writes color-transform uniforms through `Mutex<UniformStorage>` (ADR-34, D-17, Inv 6).
    ///
    /// Wholesale replacement (no merge — `ProcessingParameters` is non-nullable per
    /// architecture/07-settings.md §ProcessingParameters).
    ///
    /// **Pipeline order (`Shaders/ColorShaders.metal`):**
    ///   1. Brightness → 2. Contrast → 3. Saturation → 4. Gamma → 5. Black balance.
    ///
    /// Black balance is the **last** step — pedestal is subtracted from the
    /// graded output, behaving like a final shadow lift rather than a
    /// pre-grade noise-floor compensation. Calibration sampling for BB must
    /// therefore read from `naturalTex` (Pass-1 output) so each calibrate
    /// isn't biased by the previously-applied pedestal.
```

- [ ] **Step 10.3: Annotate `ProcessingViewModel.applyBlackBalance`**

Open `ProcessingViewModel.swift`. Find `func applyBlackBalance(sample:)`. Add doc-comment:

```swift
    /// Writes per-channel black-balance pedestal into `currentProcessing`
    /// based on a dark-patch sample. The GPU pipeline subtracts these
    /// pedestals as the **final** color step, after brightness/contrast/
    /// saturation/gamma — see `Shaders/ColorShaders.metal`.
    ///
    /// **Sample lane requirement:** the sample must be read from a render
    /// where **BCSG is applied and BB is zeroed** — typically via
    /// `CameraEngine.sampleCenterPatchForBBCalibration`, which runs a
    /// one-shot Pass-2 encode into a scratch texture with BB temporarily
    /// zeroed. Rationale:
    ///   - BB operates on the graded image, so the sample must be in the
    ///     same color space (BCSG applied) for the offsets to correctly
    ///     subtract a dark patch.
    ///   - The sample must NOT include the previously-written BB pedestal,
    ///     or each calibrate would stack on top of the prior result.
    /// Sampling from `processedTex` would violate the second requirement;
    /// sampling from `naturalTex` would violate the first.
    func applyBlackBalance(sample: RgbSample) async {
        // ... existing implementation
    }
```

- [ ] **Step 10.4: Build to confirm comments compile**

Same command as 1.2. Expected: `BUILD: success`. Doc-comments don't affect codegen but `swift-format --strict` may complain if the comment shape regresses — fix any flagged formatting issue (multi-line summaries need a blank `///` line after the first sentence, per CLAUDE.md §8).

- [ ] **Step 10.5: Commit**

```bash
git add CameraKit/Sources/CameraKit/Capabilities.swift \
        CameraKit/Sources/CameraKit/CameraEngine.swift \
        CameraKit/Sources/CameraKit/ProcessingViewModel.swift
git commit -m "$(cat <<'EOF'
docs(api): document BB pipeline order on ProcessingParameters and the public methods

ProcessingParameters.blackR/G/B, CameraEngine.setProcessingParameters,
and ProcessingViewModel.applyBlackBalance now each call out: BB is the
final color step (after brightness/contrast/saturation/gamma) and the
sample must come from a pre-BB lane. Cross-references the shader.
EOF
)"
```

---

## Task 11: Reticle overlay on the right preview lane

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift` — add `calibrationReticleLayer()` near the calibration sidebar code, compose it into `body`.

- [ ] **Step 11.1: Add the reticle helper**

Insert this helper into `CameraView` before `// MARK: - Calibration sidebar` (around line 303):

```swift
    // MARK: - Calibration reticle (Bug 8 — sample-point indicator)

    /// Reticle pinned to the right (processed) preview lane's center while
    /// the calibration sidebar is open. Indicates the sample area for **both**
    /// WB Calibrate (samples naturalTex) and BB Calibrate (samples a scratch
    /// render of current BCSG with BB zeroed).
    ///
    /// The actual sample patch is `MetalPipeline.scaledCenterPatchSize` square
    /// — 96 px at the default 4160×3120 capture, scaling proportionally on
    /// smaller lanes with a 16-px floor. Patch fraction ≈ 96/3120 ≈ 3% of
    /// the shorter dimension at default; ratio-preserving on smaller lanes
    /// because both numerator and denominator scale together. The 80×80pt
    /// reticle is an approximate visual match — not pixel-perfect, but
    /// gives the user a clear "sample is here" hint.
    ///
    /// After the Bug-6/9 fix (`sessionPreset = .inputPriority`) the texture
    /// fills the lane proportionally, so center-of-lane ≈ center-of-texture.
    @ViewBuilder
    private func calibrationReticleLayer() -> some View {
        if sidebarVisible {
            HStack(spacing: 0) {
                Color.clear
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 80, height: 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
```

- [ ] **Step 11.2: Compose the reticle into `body`**

In `CameraView.body` at line 25, change the inner `ZStack` to add the reticle:

```swift
        return ZStack {
            previewArea
            scanningOverlay(enablement: enablement)
            calibrationReticleLayer()
            #if DEBUG
            debugSurface
            #endif
            calibrationSidebarLayer(enablement: enablement)
        }
```

- [ ] **Step 11.3: Build to confirm it compiles**

Same command as 1.2. Expected: `BUILD: success`.

- [ ] **Step 11.4: Commit**

```bash
git add CameraKit/Sources/CameraKit/CameraView.swift
git commit -m "$(cat <<'EOF'
feat(ui): show calibration reticle on processed lane center (Bug 8)

80×80pt yellow outlined rectangle pinned to the right preview lane's
geometric center while the calibration sidebar is open. Approximate
match for the centerPatchSizePx (96 px) sampling region — texture
fills the lane proportionally post Bug-6/9 fix.
EOF
)"
```

---

## Task 12: `state.md` decision log entry

**Files:**
- Modify: `CameraKit/state.md` — append to the "Decisions taken that weren't in briefs" section (or create the section if missing).

- [ ] **Step 12.1: Read state.md to locate the right section**

```bash
grep -n "Decisions taken\|Open questions\|## " CameraKit/state.md | head -20
```

If a "Decisions taken that weren't in briefs" section exists, append. If not, add it before the "Open questions for next stage" section (or at the bottom).

- [ ] **Step 12.2: Append the entry**

Append:

```markdown
- **2026-05-08 — BB applied AFTER brightness/contrast/saturation/gamma.**
  `Shaders/ColorShaders.metal` was reordered to apply the black-balance
  pedestal as the *final* color step. This contradicts
  `architecture/07-settings.md §Processing order`, which specifies BB as
  the first step (noise-floor pre-compensation). Decision is user-directed:
  BB now behaves like a final shadow lift on the graded image. Pairs with
  the BB calibration sampling path: a one-shot Pass-2 scratch encode
  rendered with current BCSG and BB zeroed (`MetalPipeline.dispatchBBCalibrationSample`),
  so the sample is in the same color space the pedestal subtracts from
  while not feeding the prior pedestal back into the math. Public-API
  doc-comments were updated. Upstream should patch the spec.

- **2026-05-08 — Manual WB is non-persistent across launches.**
  `SettingsPersistence.load` strips `wbMode = .manual` and the gain triple
  on decode. `.auto` and `.locked` round-trip unchanged. Calibration is a
  per-session intent. Side effect: any latent recurrence of the historical
  Bug-12 cold-launch-black symptom is rendered harmless.
```

- [ ] **Step 12.3: Commit**

```bash
git add CameraKit/state.md
git commit -m "$(cat <<'EOF'
docs(state): log BB pipeline reorder + WB persistence policy decisions

User-directed deviations from architecture/07-settings.md and the
implicit "all settings persist" pattern. Upstream should patch the
spec for the BB order; the persistence policy is a calibration-flow UX
decision and stays local.
EOF
)"
```

---

## Task 13: HITL verification on iPad

**Files:** none (manual verification on physical iPad).

- [ ] **Step 13.1: Build, install, launch on iPad**

```text
mcp__XcodeBuildMCP__build_device
mcp__XcodeBuildMCP__install_app_device
mcp__XcodeBuildMCP__launch_app_device
```

Fallback: `scripts/build-summary.sh` then install/launch via Xcode.

- [ ] **Step 13.2: Sanity check — cold-launch preview is live within ~1 s**

Force-quit + relaunch. Both preview lanes should show live frames within ~1 s. (Bug 12's prior multi-minute-freeze is no longer reproducing on `stage-01` HEAD.)

- [ ] **Step 13.3: WB Calibrate produces a neutral result on a grey reference**

Point at a neutral-grey card / wall under indoor lighting. Open Calibrate sidebar. Tap **Calibrate** under "White Balance". Right preview should settle to neutral within ~1s — no pink, magenta, or cyan tint.

- [ ] **Step 13.4: WB Calibrate re-baselines on a second tap**

With WB calibrated from 13.3, point at a different scene (warm tungsten works well). Tap **Calibrate** under "White Balance" again. Preview should re-baseline visibly — warm cast neutralizes within ~1s.

- [ ] **Step 13.5: Lock WB freezes current AVF gains**

Tap **Auto** under "White Balance". Wait 2-3 s for AVF AWB to settle on the current scene. Tap **Lock**. Move iPad to a different lighting source. **Expected:** colors do *not* shift — they stay locked to whatever AVF computed before the Lock tap.

- [ ] **Step 13.6: Auto WB returns to continuous AWB**

With WB still locked from 13.5, tap **Auto**. Move iPad to a different lighting source. **Expected:** white balance shifts smoothly, tracking the new lighting — confirming `.continuousAutoWhiteBalance` is in effect.

- [ ] **Step 13.7: BB Calibrate writes a per-channel pedestal**

Aim the iPad at a dark patch (turn off lights, cover lens partially). Tap **Calibrate** under "Black Balance". The Black R/G/B sliders should jump to the sampled values; the preview's shadow tones should subtract the pedestal — visible darkening of the darkest region.

- [ ] **Step 13.8: Reset BB zeroes the pedestal**

With BB calibrated from 13.7, tap **Reset** under "Black Balance". The Black R/G/B sliders should snap to 0. Preview shadows return to pre-BB.

- [ ] **Step 13.9: Reticle visible during both WB and BB calibration**

Open the Calibrate sidebar. **Expected:** 80×80pt yellow rectangle at the geometric center of the right preview lane — visible whether the user is about to tap WB Calibrate or BB Calibrate (both actions sample the same patch). Close the sidebar — reticle disappears.

- [ ] **Step 13.10: Persistence policy — calibration does not survive relaunch**

WB Calibrate, then force-quit and relaunch. **Expected:** preview boots in continuous AWB; no locked manual WB tint persists.

- [ ] **Step 13.11: Update bug doc + handoff doc**

Mark Bugs 8 and 13 as **FIXED** in `docs/stage-11-pre-existing-bugs.md` with the relevant commit SHAs and date `2026-05-08`. Mark Bug 12 as **CLOSED — no longer reproducing on `stage-01` HEAD**, noting that the persistence policy in Task 5 also makes any latent recurrence harmless. Mark the Family-B row in `docs/pre-stage-12-handoff.md` as resolved.

```bash
git add docs/stage-11-pre-existing-bugs.md docs/pre-stage-12-handoff.md
git commit -m "$(cat <<'EOF'
docs(stage-11-bugs): close Family B — Bugs 8, 13 fixed; Bug 12 no longer reproducing
EOF
)"
```

---

## Self-review notes

- **Spec coverage:** Bug 8 (Task 11); Bug 13 math (Tasks 1, 3, 4); Bug 13 UX (Tasks 6–8); persistence policy (Task 5); BB pipeline reorder + scratch-encode sample lane + reset (Tasks 1, 6, 8, 9, 10, 12); state.md provenance (Task 12); patch-size resolution scaling (Task 1).
- **Bug 12 status:** closed by side effect of prior fixes; not chased here. Task 5 (persistence policy) makes any latent recurrence harmless.
- **WB math research-backing:** Tasks 3 and 6 implement the full Apple-idiomatic flow per WWDC 2014 §508 + `AVCaptureDevice.h` lines 1244–1434 — switch to `.auto` → KVO-await `isAdjustingWhiteBalance == false` → read `device.deviceWhiteBalanceGains` → stack reciprocal → normalize → clamp → write manual.
- **BB-zero correctness:** Task 1 includes both a code-comment explaining the value-copy + setBytes mechanism (live uniforms untouched; shader reads our zeroed bytes via setBytes) and an integration test (`bbScratchZeroesPedestal`) that pins the invariant on real Metal. If the test reads ~0.3 instead of ~0.5, the BB-zero invariant is broken.
- **Patch resolution scaling:** Task 1 adds `MetalPipeline.scaledCenterPatchSize(captureSize:)` (96 × shorter_dim / 3120, floor 16). Tested by `scaledCenterPatchSize` in the same suite. Buffer capacity remains at the constant maximum so a smaller capture lane never under-allocates.
- **Concurrency:** all engine writes go through the existing `updateSettings` actor path. KVO-based `awaitWBSettled` uses `withCheckedContinuation` + `NSKeyValueObservation` with a 2s timeout via `withTaskGroup` racing.
- **No simulators:** all build/test commands use device targets per CLAUDE.md §6.
- **Tests:** every new method is covered. Stage 04 color tests are unaffected (don't assert combined BB + BCSG at non-zero values). Stage 11 calibration suite is rewritten end-to-end + new BB-scratch suite.
- **Format research complete (2026-05-08):** Metal-buffer color-format agent confirmed both `naturalTex` and `processedTex` are `MTLPixelFormat.rgba16Float` (IEEE-754 binary16, no implicit sRGB transform), gamma-encoded R'G'B' inherited from the camera's Y'CbCr delivery + BT.601 conversion. `CAMetalLayer.colorspace = sRGB` asserts the encoding to the compositor, confirming the choice of sRGB EOTF in `grayWorldGains` is the consistent inverse. BB doesn't need linearization (sample and apply both operate in gamma-encoded space, self-consistent). Source: `MTLPixelFormat` overview, `AVCaptureDevice.activeColorSpace`, CoreVideo `kCVImageBufferTransferFunctionKey` (default `ITU_R_709_2`).
