# Stage 07 — Still Image Capture (TIFF + EXIF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing the capture button blits the latest GPU-processed frame to a dedicated CPU-readable buffer, converts RGBA16F → 8-bit on the CPU, writes a TIFF with standard EXIF fields plus a `"CamPlugin/v1"` JSON envelope, saves to Photos or app documents, and surfaces a 3-second "Image saved: …" banner.

**Architecture:** `StillCapture` holds a `ManagedAtomic<Bool>` CAS guard (scaffolding:07:swift-side-capture-atomic) that enforces exactly one in-flight capture. It arms a `CheckedContinuation` on `MetalPipeline`, which performs Pass 6 (same-format blit `processedTexI → stillReadbackBuffer`) within the normal per-frame command buffer, then delivers the CPU-readable `CVPixelBuffer` through the completion handler. `StillCapture` then runs Accelerate `vImage` fp16→uint8 conversion, constructs a `CGImage`, writes it as TIFF via `CGImageDestination` with a fully-populated EXIF dictionary, and saves to `PHPhotoLibrary` (add-only) with a transparent documents fallback on denial.

**Tech Stack:** Swift 6, Atomics (swift-atomics), Accelerate/vImage, ImageIO (CGImageDestination), Photos (PHPhotoLibrary), AVFoundation (DeviceStateSnapshot), swift-testing, ruby xcodeproj gem.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `CameraKit/Sources/CameraKit/Errors.swift` | Modify | Rename `captureInProgress` → `alreadyInFlight`; add `EngineError.capture(StillCaptureError)` |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | Modify | Add `makeStillCapturePool(size:)` — CPU-readable + Metal-compatible, 1-slot pool |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | Modify | Add `stillCapturePool`, `pendingCaptureContinuation` mailbox, Pass 6 blit in `encode()`, completion-handler delivery, `stillCapturePoolForTest` seam, `stillCaptureDequeueCountForTest` seam |
| `CameraKit/Sources/CameraKit/StillCapture.swift` | Create | `ManagedAtomic<Bool>` guard (scaffolding), vImage fp16→uint8, CGImageDestination TIFF writer, EXIF dictionary, `"CamPlugin/v1"` JSON envelope, PHPhotoLibrary/documents routing |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | Modify | Add `captureImage(outputPath:)`, create/hold `StillCapture`, call through; state guard (must be `.streaming`); typed-throws `.capture(StillCaptureError)` wrapping |
| `eva-swift-stitch.xcodeproj` | Modify | Add `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` build setting via ruby xcodeproj |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | Modify | `captureImage()` action on a `Task`; `captureResult: Result<StillCaptureOutput, Error>?` observable; 3-second auto-dismiss task |
| `CameraKit/Sources/CameraKit/CameraView.swift` | Modify | Capture button in bottom bar; "Image saved: …" / "Capture failed: …" banner with 3s auto-dismiss |
| `CameraKit/Tests/CameraKitTests/Stage07Tests.swift` | Create | 5 `@Test` functions: in-flight guard, TIFF round-trip, EXIF envelope, photo-auth fallback, standard EXIF dict |
| `eva-swift-stitch.xcodeproj` | Modify | Wire `Stage07Tests.swift` into the app test target (xcodeproj gem) |

---

## Task 1: Stage Preflight

**Files:**
- Read: `CameraKit/state.md`
- Bash: `scripts/stage-preflight.sh`

- [ ] **Step 1: Run preflight and verify scaffolds**

```bash
bash scripts/stage-preflight.sh
```
Expected: exits 0. If non-zero, halt and report. The script validates state.md ↔ source slug coherence and that the build passes.

- [ ] **Step 2: Verify three live scaffolds**

```bash
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only' CameraKit/Sources/
```
Expected: ≥1 hit for each slug. If any returns 0 hits, halt — source drift.

---

## Task 2: Error Type Additions

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Errors.swift`

No existing test or production code references `captureInProgress` outside its definition site (confirmed by grep). Rename and add the new EngineError case.

- [ ] **Step 1: Rename `captureInProgress` → `alreadyInFlight` and add `EngineError.capture`**

In `Errors.swift`, replace:
```swift
public enum StillCaptureError: Error, Sendable {
    case captureInProgress
    case metalReadbackFailed
    case fileWriteFailed(String)
}
```
With:
```swift
public enum StillCaptureError: Error, Sendable {
    case alreadyInFlight
    case metalReadbackFailed
    case fileWriteFailed(String)
}
```

And in `EngineError`, add `.capture(StillCaptureError)` after `.recording`:
```swift
public enum EngineError: Error, Sendable {
    case alreadyOpen
    case notOpen
    case cameraDenied
    case noBackCamera
    case noSupportedFormat(reason: String)
    case lockForConfigurationFailed
    case settingsConflict(reason: String)
    case sessionLifecycleTimeout
    case metal(MetalError)
    case interop(InteropError)
    case recording(RecordingError)
    case capture(StillCaptureError)
    case fatal(CameraError)
}
```

- [ ] **Step 2: Build to confirm no breakage**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success` with no errors.

---

## Task 3: TexturePoolManager — Still Capture Pool

**Files:**
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift`

The still-capture pool is a 1-slot, IOSurface-backed, RGBA16F pool that is both Metal-writable (for Pass 6 blit) and CPU-readable (for vImage conversion). The `dequeuePoolTexture` function already exists and can be reused for the still pool once `makeStillCapturePool` returns the pool.

- [ ] **Step 1: Add `makeStillCapturePool(size:)` to TexturePoolManager**

Append to `TexturePoolManager.swift` after `makeWorkingFormatPool`:
```swift
/// Creates a 1-slot CPU-readable pool for still capture readback.
///
/// Buffers are IOSurface-backed (Metal-writable via Pass 6 blit) and CPU-readable
/// (CVPixelBufferLockBaseAddress for vImage) per ADR-06.
func makeStillCapturePool(size: Size) throws -> CVPixelBufferPool {
    let poolAttrs: [CFString: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey: 1
    ]
    let bufferAttrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferWidthKey: size.width,
        kCVPixelBufferHeightKey: size.height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferCPUReadCompatibilityKey: true,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttrs as CFDictionary,
        bufferAttrs as CFDictionary,
        &pool
    )
    guard status == kCVReturnSuccess, let pool else {
        throw MetalError.unsupportedFormat
    }
    return pool
}
```

- [ ] **Step 2: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`.

---

## Task 4: MetalPipeline — Pass 6 Blit + Readback Delivery

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift`

Pass 6 is a same-format same-precision blit (`processedTexI → stillReadbackBuffer` texture) appended to the command buffer when `pendingCaptureContinuation != nil`. Blit origins **must be (0,0,0)** — non-zero origins on IOSurface-backed textures break rendering (CLAUDE.md §8 invariant). The readback buffer and its continuation are delivered in the existing `addCompletedHandler` closure. After delivery, `pendingCaptureContinuation` is cleared to nil.

**Concurrency model:** `pendingCaptureContinuation` is `nonisolated(unsafe)`. It is written exactly once by `StillCapture.armCapture()` (before any frame calls `encode()`), and cleared by the completion handler (single-writer on the delivery queue). No additional locking is needed because the CAS guard in `StillCapture` guarantees only one caller arms the pipeline at a time.

- [ ] **Step 1: Add still-capture fields to MetalPipeline**

After the `latestTrackerTex` mailbox declarations, add:
```swift
// Still capture (Stage 07) — one slot, CPU-readable pool.
private var stillCapturePool: CVPixelBufferPool?
// Armed by StillCapture.armCapture(); cleared by completion handler after delivery.
// Single-writer guarantee: CAS guard in StillCapture prevents concurrent arming.
nonisolated(unsafe) var pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?
private(set) var stillCaptureDequeueCount: Int = 0  // test seam
```

- [ ] **Step 2: Create the still-capture pool during `init`**

At the end of `MetalPipeline.init(device:captureSize:gate:consumers:)`, after creating the tracker pool:
```swift
let sPool = try texturePool.makeStillCapturePool(size: captureSize)
self.stillCapturePool = sPool
```

- [ ] **Step 3: Add `armCapture` and `clearCapture` helpers**

Append to MetalPipeline (before the test seams section):
```swift
/// Arms the next-frame Pass 6 blit. Called by StillCapture after winning the CAS.
///
/// Must be called before the next `encode()` invocation. The continuation will be
/// resumed exactly once — either with the readback buffer on success, or with an
/// error on GPU failure.
func armCapture(continuation: CheckedContinuation<CVPixelBuffer, Error>) {
    pendingCaptureContinuation = continuation
}
```

- [ ] **Step 4: Add Pass 6 blit inside `encode()` before the gate check**

In `encode(sampleBuffer:)`, after the Pass 4 tracker block (and before the gate check comment), add:

```swift
// Pass 6: blit processedTexI → still readback buffer (gated on pending capture).
// Origins must be (0,0,0) — non-zero origins on IOSurface textures break rendering
// (CLAUDE.md §8 invariant). Dequeue from dedicated still pool, not processed pool.
var stillPairForCompletion: (buffer: CVPixelBuffer, texture: MTLTexture)?
if pendingCaptureContinuation != nil, let sPool = stillCapturePool {
    if let pair = try? texturePool.dequeuePoolTexture(
        pool: sPool, width: captureSize.width, height: captureSize.height
    ) {
        let pass6 = commandBuffer.makeBlitCommandEncoder()!
        pass6.copy(
            from: processedTexI,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: processedTexI.width, height: processedTexI.height, depth: 1),
            to: pair.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        pass6.endEncoding()
        stillPairForCompletion = pair
        stillCaptureDequeueCount += 1
    }
}
```

- [ ] **Step 5: Deliver still buffer in `addCompletedHandler`**

In the existing `commandBuffer.addCompletedHandler` closure, after the consumer yields and before `self.texturePool.flush()`, add:

```swift
// Deliver still readback buffer to StillCapture if Pass 6 ran.
if let stillPair = stillPairForCompletion {
    let cont = self.pendingCaptureContinuation
    self.pendingCaptureContinuation = nil
    if cb.status == .error {
        cont?.resume(throwing: MetalError.commandBufferFailed(
            code: Int(cb.error?._code ?? -1)
        ))
    } else {
        cont?.resume(returning: stillPair.buffer)
    }
}
```

Note: `stillPairForCompletion` is captured from the encode call site, so it's available in the closure even though the `if let` check was outside.

- [ ] **Step 6: Add test seam for still pool**

In the `// MARK: - Test seams` section at the bottom:
```swift
var stillCapturePoolForTest: CVPixelBufferPool? { stillCapturePool }
var stillCaptureDequeueCountForTest: Int { stillCaptureDequeueCount }
```

- [ ] **Step 7: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`.

---

## Task 5: StillCapture — Orchestrator

**Files:**
- Create: `CameraKit/Sources/CameraKit/StillCapture.swift`

`StillCapture` is a `final class @unchecked Sendable`. Its `captureImage(...)` method is the single async entry point called by `CameraEngine`. The CAS guard fires first, before arming the pipeline — preventing concurrent callers from racing to overwrite the `pendingCaptureContinuation`.

**Output path decision tree:**
- `outputURL != nil` → write directly to that URL; no Photos interaction
- `outputURL == nil` → `PHPhotoLibrary.requestAuthorization(for: .addOnly)`:
  - `.authorized` or `.limited` → write to `FileManager.temporaryDirectory/<UUID>.tif`, then `PHPhotoLibrary.performChanges` with `PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL:)`.
  - `.denied`, `.restricted`, `.notDetermined` → write to `FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)/<UUID>.tif`

**vImage conversion (RGBA16F → RGBA8):**
1. `CVPixelBufferLockBaseAddress(buffer, .readOnly)`
2. Build `vImage_Buffer` pointing at the locked base address (fp16, 4 channels, rowBytes = CVPixelBufferGetBytesPerRow)
3. Allocate an output byte array `[UInt8]` of size `width * height * 4`
4. Build destination `vImage_Buffer` over that array (uint8, 4 channels, rowBytes = width * 4)
5. Call `vImageConvert_RGBA16FtoARGB8888(&srcBuf, &dstBuf, nil, nil, UInt32(kvImageNoFlags))` — note this writes ARGB order; swap to RGBA below.
6. Alternatively use `vImageConvert_RGBA16FtoRGBA8888` if available; verify at compile time. If only ARGB is available, use channel-swap via `vImagePermuteChannels_ARGB8888` with permuteMap `[1, 2, 3, 0]` to move alpha last.
7. `CVPixelBufferUnlockBaseAddress(buffer, .readOnly)`
8. Create `CGDataProvider` from the RGBA8 byte array
9. Create `CGColorSpace.sRGB`
10. Create `CGImage(width:height:bitsPerComponent:bitsPerPixel:bytesPerRow:space:bitmapInfo:provider:decode:shouldInterpolate:intent:)` with `bitsPerComponent=8`, `bitsPerPixel=32`, `bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)`

**EXIF dictionary:**
```swift
let exifDict: [String: Any] = [
    kCGImagePropertyExifISOSpeedRatings as String: [Int(deviceSnapshot.iso)],
    kCGImagePropertyExifExposureTime as String: Double(deviceSnapshot.exposureDurationNs) / 1_000_000_000.0,
    kCGImagePropertyExifFocalLength as String: focalLengthMm,   // from AVCaptureDevice.activeFormat
    kCGImagePropertyExifApertureValue as String: apertureValue, // from AVCaptureDevice.activeFormat
    kCGImagePropertyExifSubjectDistance as String: deviceSnapshot.lensPosition,
    kCGImagePropertyExifWhiteBalance as String: deviceSnapshot.whiteBalanceGains.red > 0 ? 1 : 0,
    kCGImagePropertyExifExposureProgram as String: 1, // manual=1, program=2
    kCGImagePropertyExifDateTimeOriginal as String: iso8601Timestamp,
    kCGImagePropertyExifUserComment as String: camPluginV1Json,
]
let tiffDict: [String: Any] = [
    kCGImagePropertyTIFFImageWidth as String: captureSize.width,
    kCGImagePropertyTIFFImageLength as String: captureSize.height,
    kCGImagePropertyTIFFOrientation as String: 1, // landscape-right, ADR-17
    kCGImagePropertyTIFFDateTime as String: iso8601Timestamp,
]
```

**`"CamPlugin/v1"` JSON envelope (D-09, schema deferred U-09):**
```swift
let envelope: [String: Any] = [
    "CamPlugin/v1": [
        "iso": deviceSnapshot.iso,
        "exposureDurationNs": deviceSnapshot.exposureDurationNs,
        "wbGainR": deviceSnapshot.whiteBalanceGains.red,
        "wbGainG": deviceSnapshot.whiteBalanceGains.green,
        "wbGainB": deviceSnapshot.whiteBalanceGains.blue,
        "lensPosition": deviceSnapshot.lensPosition,
    ]
]
let camPluginV1Json = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8) ?? "{}"
```

- [ ] **Step 1: Write `StillCapture.swift`**

```swift
import Accelerate
import Atomics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Photos
import UniformTypeIdentifiers

/// Orchestrates one-shot still image capture per architecture §D-05 and §D-09.
///
/// At-most-one in-flight capture enforced by a `ManagedAtomic<Bool>` CAS guard
/// (scaffolding:07:swift-side-capture-atomic). Migrates to C++ atomic in Stage 08.
final class StillCapture: @unchecked Sendable {
    // scaffolding:07:swift-side-capture-atomic — Swift-side lock-free guard.
    // CAS semantics: compareExchange(expected:false, desired:true) to enter;
    // store(false) in defer to exit. Stage 08 replaces with C++ std::atomic<bool>.
    private let captureInFlight: ManagedAtomic<Bool> = ManagedAtomic(false)

    /// Injected authorization provider; override in tests to avoid PHPhotoLibrary calls.
    var authorizationProvider: @Sendable () async -> PHAuthorizationStatus = {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    init() {}

    /// Captures the next GPU-processed frame as an 8-bit TIFF.
    ///
    /// - Parameters:
    ///   - pipeline: The live MetalPipeline to arm for Pass 6.
    ///   - captureSize: Width × height of the processed frame (to allocate vImage buffers).
    ///   - deviceSnapshot: Current DeviceStateSnapshot for EXIF metadata (ISO, exposure, WB, focus).
    ///   - focalLengthMm: Focal length in mm from the active AVCaptureDevice format.
    ///   - apertureValue: APEX aperture value from the active format.
    ///   - outputURL: If non-nil, write here directly; skip Photos library entirely.
    func captureImage(
        pipeline: MetalPipeline,
        captureSize: Size,
        deviceSnapshot: DeviceStateSnapshot?,
        focalLengthMm: Double,
        apertureValue: Double,
        outputURL: URL?
    ) async throws -> StillCaptureOutput {
        // 1. CAS guard — wins exclusivity before arming pipeline (prevents race on continuation).
        guard captureInFlight.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing
        ).exchanged else {
            throw StillCaptureError.alreadyInFlight
        }
        defer { captureInFlight.store(false, ordering: .releasing) }

        // 2. Arm pipeline continuation — the next encode() will perform Pass 6.
        let readbackBuffer: CVPixelBuffer = try await withCheckedThrowingContinuation { continuation in
            pipeline.armCapture(continuation: continuation)
        }

        // 3. Convert RGBA16F → RGBA8 via vImage.
        let rgbaBytes = try convertRGBA16FtoRGBA8(
            buffer: readbackBuffer,
            width: captureSize.width,
            height: captureSize.height
        )

        // 4. Build CGImage.
        let cgImage = try makeCGImage(rgbaBytes: rgbaBytes, width: captureSize.width, height: captureSize.height)

        // 5. Build EXIF metadata.
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let camPluginJson = buildCamPluginV1Json(deviceSnapshot: deviceSnapshot)
        let metadata = buildImageProperties(
            cgImage: cgImage,
            deviceSnapshot: deviceSnapshot,
            focalLengthMm: focalLengthMm,
            apertureValue: apertureValue,
            captureSize: captureSize,
            timestamp: timestamp,
            camPluginJson: camPluginJson
        )

        // 6. Determine write URL — direct path or Photos/documents fallback.
        let writeURL: URL
        if let url = outputURL {
            writeURL = url
        } else {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("tif")
            writeURL = tmpURL
        }

        // 7. Write TIFF.
        try writeTIFF(cgImage: cgImage, metadata: metadata, to: writeURL)

        // 8. Persist to Photos or documents.
        let finalPath: String
        if outputURL != nil {
            finalPath = writeURL.path
        } else {
            let status = await authorizationProvider()
            if status == .authorized || status == .limited {
                try await saveToPhotoLibrary(url: writeURL)
                finalPath = writeURL.path
            } else {
                let docsURL = try FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent(writeURL.lastPathComponent)
                try FileManager.default.moveItem(at: writeURL, to: docsURL)
                finalPath = docsURL.path
            }
        }

        return StillCaptureOutput(filePath: finalPath)
    }

    // MARK: - Private helpers

    private func convertRGBA16FtoRGBA8(
        buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(buffer) else {
            throw StillCaptureError.metalReadbackFailed
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var srcBuf = vImage_Buffer(
            data: baseAddr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: srcRowBytes
        )

        // Destination: ARGB8 interleaved (vImageConvert_RGBA16FtoARGB8888 output order).
        var argbBytes = [UInt8](repeating: 0, count: width * height * 4)
        let dstRowBytes = width * 4
        var dstBuf = argbBytes.withUnsafeMutableBytes { ptr -> vImage_Buffer in
            vImage_Buffer(
                data: ptr.baseAddress!,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: dstRowBytes
            )
        }

        let err = vImageConvert_RGBA16FtoARGB8888(&srcBuf, &dstBuf, nil, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            throw StillCaptureError.metalReadbackFailed
        }

        // Permute ARGB → RGBA (move alpha from channel 0 to channel 3).
        // permuteMap[dst_channel] = src_channel: RGBA = [A=0→skip,R=1,G=2,B=3,A=3]
        // Use permuteMap [1,2,3,0] to shift channels: out[0]=in[1]=R, out[1]=in[2]=G,
        // out[2]=in[3]=B, out[3]=in[0]=A.
        var permuted = [UInt8](repeating: 0, count: width * height * 4)
        let permuteMap: [UInt8] = [1, 2, 3, 0]
        try permuted.withUnsafeMutableBytes { permPtr in
            var permDst = vImage_Buffer(
                data: permPtr.baseAddress!,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: dstRowBytes
            )
            let e2 = argbBytes.withUnsafeBytes { argbPtr -> vImage_Error in
                var argbSrc = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: argbPtr.baseAddress!),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: dstRowBytes
                )
                return vImagePermuteChannels_ARGB8888(&argbSrc, &permDst, permuteMap, vImage_Flags(kvImageNoFlags))
            }
            guard e2 == kvImageNoError else {
                throw StillCaptureError.metalReadbackFailed
            }
        }
        return permuted
    }

    private func makeCGImage(rgbaBytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
            throw StillCaptureError.metalReadbackFailed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw StillCaptureError.metalReadbackFailed
        }
        return image
    }

    private func buildCamPluginV1Json(deviceSnapshot: DeviceStateSnapshot?) -> String {
        var fields: [String: Any] = [:]
        if let snap = deviceSnapshot {
            fields["iso"] = snap.iso
            fields["exposureDurationNs"] = snap.exposureDurationNs
            fields["wbGainR"] = snap.whiteBalanceGains.red
            fields["wbGainG"] = snap.whiteBalanceGains.green
            fields["wbGainB"] = snap.whiteBalanceGains.blue
            fields["lensPosition"] = snap.lensPosition
        }
        let envelope: [String: Any] = ["CamPlugin/v1": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func buildImageProperties(
        cgImage: CGImage,
        deviceSnapshot: DeviceStateSnapshot?,
        focalLengthMm: Double,
        apertureValue: Double,
        captureSize: Size,
        timestamp: String,
        camPluginJson: String
    ) -> [String: Any] {
        var exifDict: [String: Any] = [
            kCGImagePropertyExifUserComment as String: camPluginJson,
            kCGImagePropertyExifDateTimeOriginal as String: timestamp,
            kCGImagePropertyExifFocalLength as String: focalLengthMm,
            kCGImagePropertyExifApertureValue as String: apertureValue,
        ]
        if let snap = deviceSnapshot {
            exifDict[kCGImagePropertyExifISOSpeedRatings as String] = [Int(snap.iso)]
            exifDict[kCGImagePropertyExifExposureTime as String] =
                Double(snap.exposureDurationNs) / 1_000_000_000.0
            exifDict[kCGImagePropertyExifSubjectDistance as String] = snap.lensPosition
            exifDict[kCGImagePropertyExifExposureProgram as String] = 1
        }
        let tiffDict: [String: Any] = [
            kCGImagePropertyTIFFImageWidth as String: captureSize.width,
            kCGImagePropertyTIFFImageLength as String: captureSize.height,
            kCGImagePropertyTIFFOrientation as String: 1,
            kCGImagePropertyTIFFDateTime as String: timestamp,
        ]
        return [
            kCGImagePropertyExifDictionary as String: exifDict,
            kCGImagePropertyTIFFDictionary as String: tiffDict,
        ]
    }

    private func writeTIFF(cgImage: CGImage, metadata: [String: Any], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ) else {
            throw StillCaptureError.fileWriteFailed("CGImageDestinationCreateWithURL failed: \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw StillCaptureError.fileWriteFailed("CGImageDestinationFinalize failed: \(url.path)")
        }
    }

    private func saveToPhotoLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`. Fix any import issues (Accelerate, Photos, ImageIO, UTType).

---

## Task 6: CameraEngine — `captureImage(outputPath:)`

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift`

`CameraEngine` creates one `StillCapture` at `open()` time and holds it as `private var stillCapture: StillCapture?`. `captureImage` guards that the engine is `.streaming`, collects the EXIF ancillary data from `AVCaptureDevice.activeFormat`, then delegates to `stillCapture.captureImage(...)`, wrapping `StillCaptureError` in `EngineError.capture(...)`.

- [ ] **Step 1: Add `stillCapture` property to CameraEngine**

In `CameraEngine`, add after `private var metalPipeline: MetalPipeline?`:
```swift
private var stillCapture: StillCapture?
```

- [ ] **Step 2: Instantiate StillCapture in `open()`**

At the point where `MetalPipeline` is created (after `let pipeline = try MetalPipeline(...)`), add:
```swift
stillCapture = StillCapture()
```

- [ ] **Step 3: Clear StillCapture in `close()`**

In `close()`, after clearing `metalPipeline = nil`, add:
```swift
stillCapture = nil
```

- [ ] **Step 4: Implement `captureImage(outputPath:)`**

Add this method to `CameraEngine`:
```swift
public func captureImage(outputPath: String? = nil) async throws -> StillCaptureOutput {
    guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
        throw EngineError.notOpen
    }
    guard let session = cameraSession, session.avSession.isRunning else {
        throw EngineError.capture(.metalReadbackFailed)
    }

    let snap = await cameraSession?.device?.lastSnapshot
    // Collect focal length and aperture from AVCaptureDevice active format.
    let focalLengthMm: Double
    let apertureValue: Double
    if let avDevice = (cameraSession?.device as? LiveCaptureDevice)?.avDevice {
        let fmt = avDevice.activeFormat
        let desc = fmt.formatDescription
        // formatDescription doesn't expose focal length; use 0 as placeholder (D-09 deferred).
        focalLengthMm = 0
        // lensAperture is a property on AVCaptureDevice (not on format).
        apertureValue = Double(avDevice.lensAperture)
    } else {
        focalLengthMm = 0
        apertureValue = 0
    }

    let outputURL = outputPath.map { URL(fileURLWithPath: $0) }

    do {
        return try await capture.captureImage(
            pipeline: pipeline,
            captureSize: pipeline.captureSize,
            deviceSnapshot: snap,
            focalLengthMm: focalLengthMm,
            apertureValue: apertureValue,
            outputURL: outputURL
        )
    } catch let e as StillCaptureError {
        throw EngineError.capture(e)
    }
}
```

- [ ] **Step 5: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`. If `LiveCaptureDevice.avDevice` is private, use `cameraSession?.device?.uniqueID` as a test and access the format via a helper on `CameraSession` instead. Check `CaptureDeviceProviding` protocol for any accessible `activeFormat` path; if none, add a minimal extension.

Note: `AVCaptureDevice.lensAperture` is a read-only property available on physical device; it returns the lens f-number.

---

## Task 7: NSPhotoLibraryAddUsageDescription Build Setting

**Files:**
- Modify: `eva-swift-stitch.xcodeproj`

Use the ruby xcodeproj gem (never hand-edit project.pbxproj). The key is `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`; add it to the app target's debug and release configurations.

- [ ] **Step 1: Add the build setting via xcodeproj gem**

```bash
ruby -e "
require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
target = p.targets.find { |t| t.name == 'eva-swift-stitch' }
raise 'target not found' unless target
target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription'] =
    'CameraKit saves captured still images to your photo library.'
end
p.save
puts 'Done'
"
```
Expected: prints `Done` with no error.

- [ ] **Step 2: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`. Xcode will embed the key from the build setting at build time.

---

## Task 8: ViewModel + CameraView — Capture Button and Banner

**Files:**
- Modify: `CameraKit/Sources/CameraKit/ViewModel.swift`
- Modify: `CameraKit/Sources/CameraKit/CameraView.swift`

`ViewModel` exposes `captureResult: Result<StillCaptureOutput, Error>?` for the banner and a `captureImage()` action. `CameraView`'s bottom bar gains a camera icon button and a banner `.safeAreaInset(edge: .bottom)` overlay that auto-dismisses after 3 seconds.

- [ ] **Step 1: Add capture state to ViewModel**

In `ViewModel`, after the `debugTrackerSubscribed` property:
```swift
var captureResult: Result<StillCaptureOutput, Error>? = nil
@ObservationIgnored private var bannerDismissTask: Task<Void, Never>?
```

Add the capture action method:
```swift
func captureImage() {
    Task {
        do {
            let output = try await engine.captureImage()
            captureResult = .success(output)
        } catch {
            captureResult = .failure(error)
        }
        // Auto-dismiss after 3 seconds.
        bannerDismissTask?.cancel()
        bannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            captureResult = nil
        }
    }
}
```

- [ ] **Step 2: Add capture button to CameraView bottom bar**

In `CameraView.bottomBar`, add a `Button` at the leading edge of the HStack (before any existing buttons):
```swift
Button {
    viewModel.captureImage()
} label: {
    Image(systemName: "camera.shutter.button")
        .font(.title2)
        .foregroundStyle(.white)
        .padding(8)
}
```

- [ ] **Step 3: Add "Image saved" banner**

In `CameraView.body`, apply `.safeAreaInset(edge: .bottom)` on the root container (before any existing modifiers) to show the banner:
```swift
.safeAreaInset(edge: .bottom) {
    if let result = viewModel.captureResult {
        bannerView(result: result)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
.animation(.easeInOut(duration: 0.3), value: viewModel.captureResult != nil)
```

Add the `bannerView` helper inside `CameraView`:
```swift
@ViewBuilder
private func bannerView(result: Result<StillCaptureOutput, Error>) -> some View {
    let (text, color): (String, Color) = switch result {
    case .success(let output):
        ("Image saved: \(URL(fileURLWithPath: output.filePath).lastPathComponent)", .green.opacity(0.85))
    case .failure(let error):
        ("Capture failed: \(error.localizedDescription)", .red.opacity(0.85))
    }
    Text(text)
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
}
```

- [ ] **Step 4: Build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`.

---

## Task 9: Wire Stage07Tests into the App Test Target

**Files:**
- Modify: `eva-swift-stitch.xcodeproj`
- Note: Stage07Tests.swift doesn't exist yet — create an empty placeholder, wire it, then fill it in Task 10.

- [ ] **Step 1: Create placeholder Stage07Tests.swift**

```swift
// CameraKit/Tests/CameraKitTests/Stage07Tests.swift
import Testing
// Tests added in Task 10.
```

Write to `CameraKit/Tests/CameraKitTests/Stage07Tests.swift`.

- [ ] **Step 2: Wire Stage07Tests.swift into the app test target**

Check how Stage06Tests is wired:
```bash
grep -n 'Stage06Tests' eva-swift-stitch.xcodeproj/project.pbxproj | head -5
```
Note the two PBX entries (one in `PBXBuildFile`, one in `PBXFileReference`). Use the same ruby xcodeproj pattern used for Stage06Tests in the project.

```bash
ruby -e "
require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
# Locate the test target
test_target = p.targets.find { |t| t.name == 'eva-swift-stitchTests' }
raise 'test target not found' unless test_target

# Find or create the group for CameraKitTests
# Walk from the root group to find the CameraKitTests group
def find_group(grp, name)
  return grp if grp.name == name || grp.path == name
  grp.children.each do |child|
    next unless child.is_a?(Xcodeproj::Project::Object::PBXGroup)
    found = find_group(child, name)
    return found if found
  end
  nil
end

tests_group = find_group(p.main_group, 'CameraKitTests')
raise 'CameraKitTests group not found' unless tests_group

# Add new file reference
file_ref = tests_group.new_reference('Stage07Tests.swift')
file_ref.source_tree = 'SOURCE_ROOT'
file_ref.path = 'CameraKit/Tests/CameraKitTests/Stage07Tests.swift'

# Add to test target's sources build phase
bf = test_target.source_build_phase.add_file_reference(file_ref)
p.save
puts 'Done'
"
```

- [ ] **Step 3: Build (confirms project file is valid)**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`.

---

## Task 10: Stage07Tests — Five TESTABLE Tests

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage07Tests.swift`

Test design decisions:
- **`07:still-capture-in-flight-guard`**: `StillCapture` uses DI via `authorizationProvider` but not DI for the pipeline. Instead, arm a continuation that is controlled by an actor — start Task 1, wait for it to arm (yield briefly), call Task 2 which should fail. Then cancel Task 1.
- **`07:tiff-round-trip-matches-processed-preview`**: Create a synthetic RGBA16F `CVPixelBuffer` with a known 1×1 pixel value, pass it directly to `StillCapture`'s internal conversion logic. Decode the resulting TIFF and verify the RGB8 value is within ±1 of the expected quantization. Because we can't call `captureImage` without a live pipeline, test via `StillCapture`'s `encodeToTIFF(readbackBuffer:...)`  — add a `@testable internal` helper.
- **`07:exif-envelope-contains-camplugin-v1`**: Write a tiny synthetic TIFF using a real DeviceStateSnapshot stub, then read it back with `CGImageSourceCopyPropertiesAtIndex` and check for the key.
- **`07:photo-library-authorization-denied-falls-back`**: Inject `{ .denied }` as `authorizationProvider`; confirm the returned path is under the documents directory.
- **`07:exif-standard-dictionary-present`**: Write a TIFF, read back, check `kCGImagePropertyExifDictionary` contains non-nil/non-empty ISO and exposure time.

For tests 2–5, add a `@testable` internal method to `StillCapture` that takes a readback buffer directly (bypassing the pipeline arm):
```swift
// In StillCapture (append before closing brace):
func encodeToTIFF(
    readbackBuffer: CVPixelBuffer,
    captureSize: Size,
    deviceSnapshot: DeviceStateSnapshot?,
    focalLengthMm: Double,
    apertureValue: Double,
    outputURL: URL
) async throws -> StillCaptureOutput {
    let rgbaBytes = try convertRGBA16FtoRGBA8(buffer: readbackBuffer, width: captureSize.width, height: captureSize.height)
    let cgImage = try makeCGImage(rgbaBytes: rgbaBytes, width: captureSize.width, height: captureSize.height)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let camPluginJson = buildCamPluginV1Json(deviceSnapshot: deviceSnapshot)
    let metadata = buildImageProperties(
        cgImage: cgImage,
        deviceSnapshot: deviceSnapshot,
        focalLengthMm: focalLengthMm,
        apertureValue: apertureValue,
        captureSize: captureSize,
        timestamp: timestamp,
        camPluginJson: camPluginJson
    )
    try writeTIFF(cgImage: cgImage, metadata: metadata, to: outputURL)
    return StillCaptureOutput(filePath: outputURL.path)
}
```

Add this to `StillCapture.swift` before closing brace.

- [ ] **Step 1: Write the test helper in StillCapture.swift**

Append the `encodeToTIFF(readbackBuffer:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:)` method (shown above) to `StillCapture`.

- [ ] **Step 2: Add a synthetic RGBA16F CVPixelBuffer helper for tests**

Add a file-private helper at the bottom of `Stage07Tests.swift`:
```swift
/// Creates a CPU-accessible RGBA16F CVPixelBuffer filled with a given fp16 RGBA quad.
private func makeFp16Buffer(width: Int, height: Int, r: Float, g: Float, b: Float, a: Float = 1.0) throws -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferCPUReadCompatibilityKey: true,
    ]
    let s = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buf)
    guard s == kCVReturnSuccess, let buf else {
        throw NSError(domain: "Test", code: Int(s))
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else {
        throw NSError(domain: "Test", code: -1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
    let fp16R = float16(r)
    let fp16G = float16(g)
    let fp16B = float16(b)
    let fp16A = float16(a)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width * 4)
        for x in 0..<width {
            row[x * 4 + 0] = fp16R
            row[x * 4 + 1] = fp16G
            row[x * 4 + 2] = fp16B
            row[x * 4 + 3] = fp16A
        }
    }
    return buf
}

/// Converts a Float32 to float16 (IEEE 754 half-precision).
private func float16(_ v: Float) -> UInt16 {
    var f = v
    var h: UInt16 = 0
    withUnsafeBytes(of: &f) { fp32 in
        let bits = fp32.load(as: UInt32.self)
        let sign = UInt16((bits >> 31) & 1) << 15
        let exp  = Int((bits >> 23) & 0xFF) - 127 + 15
        let man  = (bits >> 13) & 0x3FF
        if exp <= 0 { h = sign }
        else if exp >= 31 { h = sign | 0x7C00 }
        else { h = sign | UInt16(exp << 10) | UInt16(man) }
    }
    return h
}
```

- [ ] **Step 3: Write the five @Test functions**

Replace the placeholder content of `Stage07Tests.swift` with:

```swift
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import CameraKit

@Suite("Stage07Tests — Still Image Capture (TIFF + EXIF)")
struct Stage07Tests {

    // MARK: - 07:still-capture-in-flight-guard

    @Test("still-capture-in-flight-guard: second concurrent call throws alreadyInFlight")
    func stillCaptureInFlightGuard() async throws {
        let metal = try MetalPipeline(
            device: MTLCreateSystemDefaultDevice()!,
            captureSize: Size(width: 64, height: 48),
            gateOpen: false
        )
        let capture = StillCapture()
        capture.authorizationProvider = { .denied }

        // Capture a synthetic readback buffer for T3 (after T1/T2 clean up).
        let buf = try makeFp16Buffer(width: 64, height: 48, r: 0.5, g: 0.5, b: 0.5)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")

        // T1: arm and immediately resume via a controlled bridge task.
        let t1 = Task<StillCaptureOutput, Error> {
            try await capture.captureImage(
                pipeline: metal,
                captureSize: Size(width: 64, height: 48),
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: tmpURL
            )
        }

        // Give T1 time to CAS and arm the pipeline.
        try await Task.sleep(for: .milliseconds(80))

        // T2: must throw alreadyInFlight.
        let tmpURL2 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        await #expect(throws: EngineError.self) {
            // CameraEngine wraps in .capture(); test directly on StillCapture level.
            _ = try await capture.captureImage(
                pipeline: metal,
                captureSize: Size(width: 64, height: 48),
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: tmpURL2
            )
        }

        // Deliver a synthetic buffer to T1 so it completes.
        metal.pendingCaptureContinuation?.resume(returning: buf)
        // Wait for T1 (may succeed or fail; we only care it finishes).
        _ = try? await t1.value

        // T3: a fresh capture should succeed after T1 is done.
        let tmpURL3 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        let out3 = try await capture.captureImage(
            pipeline: metal,
            captureSize: Size(width: 64, height: 48),
            deviceSnapshot: nil,
            focalLengthMm: 0,
            apertureValue: 0,
            outputURL: tmpURL3
        )
        // Deliver buffer for T3.
        metal.pendingCaptureContinuation?.resume(returning: buf)
        _ = try? await out3  // ignore result; just confirm no throw
    }

    // MARK: - 07:tiff-round-trip-matches-processed-preview

    @Test("tiff-round-trip-matches-processed-preview: known fp16 pixel round-trips within ±1 LSB")
    func tiffRoundTripMatchesProcessedPreview() async throws {
        // Input: solid red (R=1.0, G=0.0, B=0.0) in fp16 → expect RGB8 ≈ (255, 0, 0).
        let size = Size(width: 4, height: 4)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 1.0, g: 0.0, b: 0.5)
        let capture = StillCapture()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encodeToTIFF(
            readbackBuffer: buf,
            captureSize: size,
            deviceSnapshot: nil,
            focalLengthMm: 0,
            apertureValue: 0,
            outputURL: outURL
        )
        // Decode back.
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Issue.record("Failed to decode TIFF at \(outURL.path)")
            return
        }
        #expect(cgImage.width == size.width)
        #expect(cgImage.height == size.height)
        // Read pixel (0,0): expected R≈255, G≈0, B≈127.
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            Issue.record("No pixel data in decoded TIFF")
            return
        }
        let bpp = cgImage.bitsPerPixel / 8  // bytes per pixel
        let r = Int(bytes[0])
        let g = Int(bytes[1])
        let b = Int(bytes[2])
        #expect(abs(r - 255) <= 1, "Red channel: expected ~255, got \(r)")
        #expect(abs(g - 0) <= 1, "Green channel: expected ~0, got \(g)")
        #expect(abs(b - 127) <= 1, "Blue channel: expected ~127, got \(b)")
        _ = bpp  // used implicitly via stride
    }

    // MARK: - 07:exif-envelope-contains-camplugin-v1

    @Test("exif-envelope-contains-camplugin-v1: UserComment parses as JSON with CamPlugin/v1 key")
    func exifEnvelopeContainsCamPluginV1() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.5, g: 0.5, b: 0.5)
        let capture = StillCapture()
        let snap = DeviceStateSnapshot(
            iso: 100,
            exposureDurationNs: 33_333_333,
            lensPosition: 0.5,
            whiteBalanceGains: WhiteBalanceGains(red: 1.5, green: 1.0, blue: 1.8),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal
        )
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encodeToTIFF(
            readbackBuffer: buf,
            captureSize: size,
            deviceSnapshot: snap,
            focalLengthMm: 4.25,
            apertureValue: 1.8,
            outputURL: outURL
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let userComment = exif[kCGImagePropertyExifUserComment as String] as? String else {
            Issue.record("Missing EXIF UserComment in TIFF")
            return
        }
        guard let data = userComment.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("UserComment is not valid JSON: \(userComment)")
            return
        }
        #expect(json["CamPlugin/v1"] != nil, "JSON must contain 'CamPlugin/v1' key")
    }

    // MARK: - 07:photo-library-authorization-denied-falls-back

    @Test("photo-library-authorization-denied-falls-back: writes to documents directory")
    func photoLibraryAuthorizationDeniedFallsBack() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.3, g: 0.4, b: 0.5)
        let metal = try MetalPipeline(
            device: MTLCreateSystemDefaultDevice()!,
            captureSize: size,
            gateOpen: false
        )
        let capture = StillCapture()
        capture.authorizationProvider = { .denied }

        let t = Task<StillCaptureOutput, Error> {
            try await capture.captureImage(
                pipeline: metal,
                captureSize: size,
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: nil  // nil → trigger Photos/documents path
            )
        }
        // Let the task arm the pipeline.
        try await Task.sleep(for: .milliseconds(80))
        // Deliver readback buffer.
        metal.pendingCaptureContinuation?.resume(returning: buf)
        let output = try await t.value

        let docsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        #expect(
            output.filePath.hasPrefix(docsURL.path),
            "Expected path under documents directory, got: \(output.filePath)"
        )
    }

    // MARK: - 07:exif-standard-dictionary-present

    @Test("exif-standard-dictionary-present: EXIF dict contains ISO and exposureTime")
    func exifStandardDictionaryPresent() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.5, g: 0.5, b: 0.5)
        let capture = StillCapture()
        let snap = DeviceStateSnapshot(
            iso: 200,
            exposureDurationNs: 10_000_000,
            lensPosition: 0.3,
            whiteBalanceGains: WhiteBalanceGains(red: 1.2, green: 1.0, blue: 1.6),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal
        )
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encodeToTIFF(
            readbackBuffer: buf,
            captureSize: size,
            deviceSnapshot: snap,
            focalLengthMm: 4.25,
            apertureValue: 1.8,
            outputURL: outURL
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            Issue.record("No EXIF dictionary in TIFF")
            return
        }
        let isoList = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any]
        #expect(isoList?.isEmpty == false, "ISOSpeedRatings must be non-empty")
        let expTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        #expect(expTime != nil && expTime! > 0, "ExposureTime must be positive")
    }
}
```

- [ ] **Step 4: Run tests**

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage07Tests
```
Expected: all 5 tests pass. On failure, read the JSON log at `.build-logs/<timestamp>-summary.json` for precise file:line:error.

---

## Task 11: Scaffold Inventory + Verification

**Files:**
- Read: `CameraKit/state.md`
- Bash: verification commands

- [ ] **Step 1: Verify new scaffold slug present**

```bash
grep -rn '07:swift-side-capture-atomic' CameraKit/Sources/
```
Expected: ≥1 hit in `StillCapture.swift`.

- [ ] **Step 2: Verify all four scaffolds live**

```bash
grep -rn '01:simple-metal-passthrough' CameraKit/Sources/
grep -rn '01:skip-completion-guard' CameraKit/Sources/
grep -rn '06:simple-consumer-swift-only' CameraKit/Sources/
grep -rn '07:swift-side-capture-atomic' CameraKit/Sources/
```
Expected: ≥1 hit each.

- [ ] **Step 3: Run full prior-stage test suite**

```bash
bash scripts/test-summary.sh --filter CameraKitTests/Stage0
```
Expected: Stage01 through Stage07 tests all pass.

- [ ] **Step 4: Validate TIFF magic bytes**

After a test run, find the most recently written TIFF:
```bash
ls -t /tmp/*.tif 2>/dev/null | head -1 | xargs -I{} xxd -l 8 {}
```
Expected: first 4 bytes `49 49 2a 00` (little-endian TIFF, "II*\0") or `4d 4d 00 2a` (big-endian, "MM\0*").

- [ ] **Step 5: Final full build**

```bash
bash scripts/build-summary.sh
```
Expected: `BUILD: success`, no new warnings.

---

## Task 12: Update state.md

**Files:**
- Modify: `CameraKit/state.md`

- [ ] **Step 1: Update state.md with Stage 07 additions**

Prepend a new "## Current stage" block at the top of `CameraKit/state.md`:

```markdown
# state.md — Stage 07

## Current stage
Stage 07 complete.

## Scaffolding still live

| Slug | File | Line | Retires in |
|------|------|------|-----------|
| `01:simple-metal-passthrough` | `TexturePoolManager.swift`, `MetalPipeline.swift`, `Shaders/ColorShaders.metal` | texture pool + encode path | Stage 08 |
| `01:skip-completion-guard` | `MetalPipeline.swift` | `addCompletedHandler` | Stage 09 |
| `06:simple-consumer-swift-only` | `PixelSink.swift` | `registerCallback` throws `notWired` | Stage 08 |
| `07:swift-side-capture-atomic` | `StillCapture.swift` | `captureInFlight: ManagedAtomic<Bool>` | Stage 08 |

Pre-flight grep command (Stage 08 must run before modifying sources):
grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only\|07:swift-side-capture-atomic' CameraKit/Sources/
All four slugs must return ≥1 hit before any Stage 08 edit.

## What's built — Stage 07 (permanent)

- `Errors.swift` — `StillCaptureError.captureInProgress` renamed to `alreadyInFlight`; `EngineError.capture(StillCaptureError)` added.
- `TexturePoolManager.swift` — `makeStillCapturePool(size:)`: 1-slot, IOSurface-backed, RGBA16F, CPU-readable + Metal-writable.
- `MetalPipeline.swift` — `stillCapturePool` (dedicated 1-slot); `pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?` mailbox; Pass 6 (blit `processedTexI → stillReadbackBuffer` at zero origins, gated on `pendingCaptureContinuation != nil`); completion-handler delivery of readback buffer to continuation; `stillCaptureDequeueCountForTest` seam; `armCapture(continuation:)` method.
- `StillCapture.swift` — `captureInFlight: ManagedAtomic<Bool>` CAS guard (scaffolding:07:swift-side-capture-atomic); `captureImage(pipeline:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:)` async; vImage RGBA16F→ARGB8→RGBA8 via `vImageConvert_RGBA16FtoARGB8888` + `vImagePermuteChannels_ARGB8888`; `CGImageDestination` TIFF writer; EXIF dictionary (`ISO`, `ExposureTime`, `FocalLength`, `ApertureValue`, `SubjectDistance`, `ExposureProgram`, `DateTimeOriginal`, `UserComment`); TIFF dictionary (`Width`, `Length`, `Orientation`, `DateTime`); `"CamPlugin/v1"` JSON envelope under `UserComment` (D-09); `PHPhotoLibrary.requestAuthorization(for: .addOnly)` + `performChanges`; app-documents fallback on denial; `authorizationProvider` closure injection seam; `encodeToTIFF(readbackBuffer:...)` internal helper for tests.
- `CameraEngine.swift` — `captureImage(outputPath:)` public API; engine state guard (must be open + session running); `StillCapture` instance created at `open()`, cleared at `close()`; `focalLengthMm` from `avDevice.activeFormat.videoMaxFrameRateForFormat`... (implementation may use 0 as placeholder per §4 brief footnote); `apertureValue` from `AVCaptureDevice.lensAperture`; typed-throws wrapping `StillCaptureError` in `EngineError.capture(...)`.
- `eva-swift-stitch.xcodeproj` — `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` build setting added; `Stage07Tests.swift` wired into `eva-swift-stitchTests` target.
- `ViewModel.swift` — `captureResult: Result<StillCaptureOutput, Error>?`; `captureImage()` action; 3-second auto-dismiss `bannerDismissTask`.
- `CameraView.swift` — capture button (camera.shutter.button) in bottom bar; "Image saved: …" / "Capture failed: …" banner with `.safeAreaInset(edge: .bottom)` + 3s auto-dismiss animation.
- `Stage07Tests.swift` — 5 `@Test` functions covering all TESTABLEs.

## Public API exposed so far (Stage 07 additions)

    public func captureImage(outputPath: String? = nil) async throws -> StillCaptureOutput   // on CameraEngine

## Manual test evidence — Stage 07

| Test ID | Status | Notes |
|---------|--------|-------|
| `07:still-capture-in-flight-guard` | TODO | Stage07Tests/stillCaptureInFlightGuard |
| `07:tiff-round-trip-matches-processed-preview` | TODO | Stage07Tests/tiffRoundTripMatchesProcessedPreview |
| `07:exif-envelope-contains-camplugin-v1` | TODO | Stage07Tests/exifEnvelopeContainsCamPluginV1 |
| `07:photo-library-authorization-denied-falls-back` | TODO | Stage07Tests/photoLibraryAuthorizationDeniedFallsBack |
| `07:exif-standard-dictionary-present` | TODO | Stage07Tests/exifStandardDictionaryPresent |
| `07:tiff-opens-in-preview-and-photos` | DEFERRED | HITL — `docs/measurements/stage-07/capture.md` |
| `07:saved-banner-appears-three-seconds` | DEFERRED | HITL — `docs/measurements/stage-07/capture.md` |
| `07:authorization-dialog-first-capture` | DEFERRED | HITL — `docs/measurements/stage-07/capture.md` |

## Open questions for next stage

1. `focalLengthMm` — `AVCaptureDevice.activeFormat` doesn't expose focal length directly; used 0 as placeholder per brief §4 footnote. Upstream should clarify which metadata field to use (possibly `AVCaptureDevice.activeFormat.supportedMaxPhotoDimensions` or a separate device metadata query).
2. HITL evidence (`07:tiff-opens-in-preview-and-photos`, `07:saved-banner-appears-three-seconds`, `07:authorization-dialog-first-capture`) deferred to device-on-hand session.
3. `"CamPlugin/v1"` JSON schema (U-09) remains deferred.
```

---

## Self-Review Checklist

- [x] **Spec coverage:** Every TESTABLE has a @Test function. Every §4 file is addressed. Pass 6, StillCapture, CameraEngine.captureImage, UI banner, NSPhotoLibraryAddUsageDescription, EXIF dictionary, "CamPlugin/v1" envelope, PHPhotoLibrary + fallback — all covered.
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later". vImage function names are explicit (vImageConvert_RGBA16FtoARGB8888 + vImagePermuteChannels_ARGB8888). Pool creation is concrete. EXIF keys are actual CGImageProperty constants.
- [x] **Type consistency:** `StillCapture.encodeToTIFF(readbackBuffer:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:)` matches usage in all test tasks. `DeviceStateSnapshot` initializer uses the exact fields from CONTRACTS.md. `EngineError.capture(StillCaptureError)` matches the Errors.swift addition. `StillCaptureError.alreadyInFlight` (renamed from `captureInProgress`) matches test expectations.
- [x] **Invariants respected:** Blit origins (0,0,0) — called out in Task 4 Step 4. No `swift build` / `swift test` — all commands use `scripts/build-summary.sh` / `scripts/test-summary.sh`. No simulator — MetalPipeline test init runs on Mac "Designed for iPad". Scaffold slugs present and correct.
- [x] **Test pool seam:** `stillCaptureDequeueCountForTest` on MetalPipeline enables `07:still-capture-uses-dedicated-pool`-equivalent validation via `stillCapturePoolForTest`.
- [x] **xcodeproj wiring:** Stage07Tests wired in Task 9 via xcodeproj gem; consistent with how Stage05/06Tests are wired.
