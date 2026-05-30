# 03 — Metal Pipeline

Metal-specific decisions: zero-copy bridges, working pixel format, GPU→encoder
zero-copy, command-buffer error handling.

---

## ADR-04: CVMetalTextureCache lifecycle

Create **one** `CVMetalTextureCache` at pipeline initialization. Reuse it for every
frame. Creation is expensive; do it once per engine, not per frame.

```swift
var cache: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache)
```

Per-frame use for biplanar YUV (the typical iOS camera format — see ADR-05), create
**two** `CVMetalTexture`s, one per plane:

```swift
// Plane 0: Y (luma) — full resolution, single-channel
var yCV: CVMetalTexture?
CVMetalTextureCacheCreateTextureFromImage(
    nil, cache!, pixelBuffer, nil,
    .r8Unorm, width, height, 0,        // plane index 0
    &yCV
)

// Plane 1: CbCr (chroma) — half resolution in each axis, two-channel interleaved
var cbcrCV: CVMetalTexture?
CVMetalTextureCacheCreateTextureFromImage(
    nil, cache!, pixelBuffer, nil,
    .rg8Unorm, width / 2, height / 2, 1,   // plane index 1
    &cbcrCV
)
```

Sample both in a YUV→RGB compute kernel (Pass 1 in the per-frame graph). Apply the
BT.709 matrix with full-range or video-range coefficients matching the capture
format's range (`..._FullRange` vs `..._VideoRange` in the pixel format name).

**Flush (do not recreate) on `UIApplication.didReceiveMemoryWarningNotification`:**

```swift
CVMetalTextureCacheFlush(cache!, 0)
```

Recreating the cache is expensive (~50ms on older hardware); flushing just evicts
retained CVMetalTexture wrappers while keeping the cache object alive.

---

## ADR-15: CVMetalTextureGetTexture nil-check

Under memory pressure, `CVMetalTextureCacheCreateTextureFromImage` can return
`kCVReturnSuccess` **and** produce a `CVMetalTexture` whose `CVMetalTextureGetTexture()`
returns `nil`. Force-unwrapping crashes the app silently under pressure.

Always use the guarded pattern:

```swift
guard result == kCVReturnSuccess,
      let cvTexture = cvTexture,
      let mtlTexture = CVMetalTextureGetTexture(cvTexture)
else {
    metalWrapFailureCount += 1
    return  // drop frame
}
```

### MTLCommandBuffer errors are silent

`MTLCommandBuffer` errors are silent unless you install an `addCompletedHandler` and
check `buffer.status == .error`. Without the check, GPU faults surface only via the
3-second stall watchdog — too slow.

```swift
commandBuffer.addCompletedHandler { cb in
    if cb.status == .error, let err = cb.error {
        // log err, emit non-fatal error to state machine, tear down command queue
    }
}
```

Install this handler on **every** command buffer in the pipeline.

---

## ADR-05: Working format RGBA16F for multi-stage color pipelines

For apps that apply multi-stage color transforms (black balance, brightness, contrast,
saturation, gamma — three or more stages compounded), use `.rgba16Float`
(`kCVPixelFormatType_64RGBAHalf`) as the working texture format inside the GPU passes.

| Format | When |
|---|---|
| 8-bit biplanar YUV | Camera input — almost always what the device delivers. Convert in Pass 1. |
| `.rgba16Float` | Working format through the color-transform chain, tracker, preview composite |
| `.bgra8Unorm` or 8-bit YUV | Final encoder output (convert in a dedicated pass; encoders want 8-bit or 10-bit YUV) |

Reason: 8-bit quantization compounds across a 3+-stage chain and produces visible
banding. Half-float math runs full-rate on Apple Silicon — no throughput penalty.
Storage cost is 2× 8-bit, mitigated by IOSurface-backed pools.

**On capture format (verified against A16 hardware):** the device does NOT support
half-float or 10-bit output on `AVCaptureVideoDataOutput`. Capture format is 8-bit
biplanar YUV. Prefer the lossless variant when available —
`kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange` — which is
hardware-compressed with no fidelity loss and reduces memory bandwidth vs uncompressed
8-bit YUV. Fall back to `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`.

Convert to half-float in the first Metal pass (Pass 1 of the per-frame graph), not
at capture configuration.

Enumerate `device.formats` at startup; filter for biplanar 8-bit YUV at 30fps at
your target resolution; pick the highest that meets constraints. Don't hardcode.

### Channel-order discipline through the pipeline

Different stages use different formats and channel orders. Wrong order produces
silently bad results — no crash, no error.

| Stage | Format | Channel order | Notes |
|---|---|---|---|
| Capture input | 8-bit YUV biplanar | Y plane + CbCr plane (not interleaved) | Two CVMetalTextures per ADR-04 |
| Working textures (natural/processed/tracker) | `rgba16Float` | **R, G, B, A** | Consumer path is always RGBA |
| Encoder adaptor pool | 8-bit YUV biplanar (or `bgra8Unorm`) | Per encoder spec | Convert in Pass 5 |

BGRA never appears in any stream a consumer touches. A C++ consumer applying BT.709
luma weights must use `(0.2126, 0.7152, 0.0722, 0.0)` in RGBA order. BGRA coefficients
on an RGBA buffer produce grayscale that looks "close enough" in normal scenes but
is subtly wrong — detectable only by golden-fixture tests, not by visual inspection.

---

## ADR-06: GPU→encoder via IOSurface-backed pool (compute conversion)

The domain requirement "encoder receives GPU-processed frames without CPU-side
conversion" is expressed on iOS as:

1. `AVAssetWriterInputPixelBufferAdaptor` configured with `sourcePixelBufferAttributes`
   specifying:
   - `kCVPixelBufferPixelFormatTypeKey` — typically
     `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12, video-range) to match
     VideoToolbox hardware-encoder input. 8-bit BGRA works too but costs extra
     bandwidth; NV12 is the native encoder format.
   - `kCVPixelBufferIOSurfacePropertiesKey: [:]`
   - `kCVPixelBufferMetalCompatibilityKey: true`
2. Dequeue a `CVPixelBuffer` from the adaptor's `pixelBufferPool`.
3. Wrap it as one or two `MTLTexture`s via `CVMetalTextureCache` (the same cache as
   ADR-04). For NV12, create two plane textures: `.r8Unorm` for Y (full res) and
   `.rg8Unorm` for interleaved CbCr (half res).
4. **Compute pass** (`MTLComputeCommandEncoder`) reads the processed `rgba16Float`
   texture and writes directly into the plane textures of the encoder-pool
   `CVPixelBuffer`. The kernel performs:
   - BT.709 RGB → YCbCr matrix (video-range or full-range to match the chosen
     pixel format)
   - Half-float → 8-bit quantization
   - 2×2 chroma downsample into the CbCr plane
   This is **not** a blit. `MTLBlitCommandEncoder` only does copies + mipmap
   generation; it cannot do matrix math, precision conversion, or subsampling.
5. `adaptor.append(pixelBuffer, withPresentationTime: pts)` — VideoToolbox maps the
   same IOSurface for encoding. No CPU copy.

**`MTLTexture.getBytes(_:)` is forbidden on this path.** It copies GPU memory to
CPU and defeats zero-copy — violates the domain invariant.

**If the recording target is BGRA instead of NV12** (e.g. a ProRes-like workflow or
legacy consumer), the pass is still compute, not blit: RGBA16F → BGRA8 is a
precision + channel-swizzle conversion. Only a same-format, same-precision copy
qualifies as a blit, and that's not what's happening here.

### See also

- **G-32** — `MTLBlitCommandEncoder.copy(from:to:)` performs no format conversion;
  both textures must share the same pixel format. Any `rgba16Float` → `bgra8Unorm`
  transition requires a render or compute pass, not a blit. See `06-gotchas.md` G-32.
- **G-33** — Label every `MTLCommandBuffer` (e.g., `commandBuffer.label = "frame.N.pass2"`)
  and wrap each encoder in `pushDebugGroup(...)` / `popDebugGroup()` so Xcode GPU
  Frame Captures are navigable. See `06-gotchas.md` G-33.

---

## ADR-16: AVAssetWriter for Metal recording

Use `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` for video recording that
encodes Metal-processed frames. Two alternatives, both rejected:

- **`AVCaptureMovieFileOutput`:** cannot encode GPU-processed frames — writes the raw
  sensor output, bypassing Metal. Violates the zero-copy invariant by design.
- **`VTCompressionSession` directly:** adds unnecessary complexity (manual sample
  buffer construction, atom/moov management). `AVAssetWriter` handles this.

Minimal configuration:

```swift
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: 1920,
    AVVideoHeightKey: 1080,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 50_000_000,
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = true

let pba = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
)
```

### Finalize with a timeout deadline

`finishWriting(completionHandler:)` can take several seconds if the encoder queue is
deep. Use a deadline to avoid hanging the UI or losing the file on background
expiration:

```swift
let finishTask = Task { await writer.finishWriting() }
let deadline = Task {
    try? await Task.sleep(for: .seconds(5))
    writer.cancelWriting()  // empty file, not partial corrupt
}
_ = await finishTask.value
deadline.cancel()
```

Cancelling the writer on timeout produces an empty file rather than a
partially-written corrupt one. The user sees "no recording saved" — better than a
file the system can't parse.

Combine with `UIApplication.beginBackgroundTask` if the drain can span a scene
transition — see G-08.

---

## ADR-20: PixelSink texture storage mode is dynamic — flip to `.shared` on consumer attach

### Start-simple default (v1)

Allocate all IOSurface-eligible textures (`naturalTex`, `processedTex`) as
`MTLStorageMode.shared` from the start. On Apple Silicon, unified memory means
`.shared` vs `.private` does not involve a page-table copy — it only affects GPU
private-cache residency. The bandwidth delta is negligible until many textures ×
high frame rates × thermally-constrained conditions compound; we have no Instruments
evidence of that cost on iPad Pro M1 or iPad 11 A16.

Graduation criterion: switch to the dynamic rotation design below only if Instruments
(Memory → IOSurface Bandwidth lane, or a sampled DRAM-bandwidth counter) shows
measurable cost on a target device under production load. Do not pre-optimize.

### Graduated design: dynamic rotation

naturalTex and processedTex default to `.private` (GPU-only) when no PixelSink subscriber
is attached. `.private` textures have a nil `.iosurface` property; any attempt to publish
them to C++ consumers via IOSurface silently drops all frames (see G-25).

When any subscriber for the `.natural` or `.processed` stream is registered,
TexturePoolManager must:

1. Allocate replacement textures with `.storageMode = .shared`, backed by IOSurface.
   Create via `device.makeTexture(descriptor:iosurface:plane:)`, where the IOSurface is
   obtained from a `CVPixelBuffer` dequeued from a `CVPixelBufferPool` configured with:
   ```swift
   kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
   kCVPixelBufferMetalCompatibilityKey: true
   ```
2. Rotate the pool over one frame — allow any in-flight `.private` command buffer to drain
   before swapping to the new `.shared` textures. Do not swap mid-frame.
3. On all-subscriber-unsubscribe, rotate back to `.private` over one frame to recover DRAM
   bandwidth.

trackerTex is always `.shared`: the tracker consumer is designed-in from the start, not
optional. Its `.iosurface` is always non-nil.

**`.private` → `.shared` is not a free operation.** IOSurface-backed textures are coherent
with CPU and other processes, which costs bandwidth. Default `.private` for any stream where
C++ consumers are optional; flip only on attach.

---

## VTFrameProcessor: do not use for custom color pipelines

`VTFrameProcessor` (VideoToolbox, iOS 26+) exposes **system-defined effects only**:
motion blur, super-resolution, noise reduction, frame interpolation, optical flow,
and frame rate conversion. It does not support arbitrary per-channel color-transform
pipelines — the effect enumeration is fixed, not programmable.

Verdict (confirmed against WWDC25 Video Toolbox sessions): **custom Metal compute
shaders are the correct approach for app-owned color pipelines.** VTFrameProcessor
is the right tool for apps that want Apple-authored effects; it is the wrong tool
for apps that own their shader pipeline.

Re-evaluate only if Apple adds programmable color pipeline support in a future SDK.

---

## Profiling strategy

`os_signpost` intervals at these boundaries in the per-frame path:

| Event | Begin | End |
|---|---|---|
| Capture callback | `captureOutput` entry | delegate return |
| Metal encode | `commandBuffer.begin` (conceptual) | `commit()` |
| GPU execution | `commandBuffer.addScheduledHandler` | `addCompletedHandler` |
| Consumer handoff | consumer callback entry | consumer callback return |

Signposts are always available on iOS (`import os.signpost` or modern `OSSignposter`)
and compose with Metal System Trace in Instruments. No runtime extension check needed.

Budget at 30fps = 33ms per frame. Useful buckets:

| Status | Total frame latency (capture callback entry → commit) |
|---|---|
| Acceptable | ≤ 15ms |
| Degraded | 15–25ms |
| Failing | > 25ms |

Fail fast at >25ms — that's the point where consumer back-pressure starts dropping
frames that should've made it through.
