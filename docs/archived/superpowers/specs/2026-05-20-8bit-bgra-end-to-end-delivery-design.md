# 8-bit BGRA end-to-end lane delivery — design

> Status: approved design, pre-implementation. Pre-Phase-3 capabilities work,
> outside per-stage brief discipline (same track as the pre-Phase-3 RGBA8
> conversion and `captureNaturalPicture`).
>
> **Supersedes** the approach in
> `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md`
> (D-2P-11) — the texture/buffer asymmetry and the `lanesEightBit` flag it
> introduced are removed here. **Keeps** D-2P-09 (BGRA8 is the wire format).

## Problem

The camera delivers **8-bit** frames: `CameraSession` is hard-locked to
`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (`Constants.swift:6`), and the
format-selection loops reject anything else (`CameraSession.swift:181`, `:319`).
Despite an 8-bit source, the pipeline carries every lane internally at RGBA16F
(half-float) and the pre-Phase-3 RGBA8 work then converts *some* lanes back to
8-bit for the Flutter bridge while leaving others at 16F. The result:

- **Empty precision.** A 16F container cannot hold more than the 8 bits the ISP
  produced (less for chroma, which is 4:2:0 subsampled). Doc-comments across the
  code claim "HDR-grade precision" — that claim is false for an 8-bit source.
- **A load-bearing asymmetry.** Texture accessors return RGBA16F; buffer
  accessors return BGRA8. `DECISIONS.md` D-2P-11 marks the asymmetry "do not
  refactor away," entrenching the over-engineering.
- **A default-on flag** (`OpenConfiguration.lanesEightBit`) whose opt-out path
  has no real consumer, plus a parallel `latestNaturalBufferRGBA16F` mailbox and
  a separate still-capture pipeline (Pass-6 + vImage 16F→8) — all to round-trip
  8-bit-origin data through a 16-bit representation.

## Goal

Commit to **8-bit BGRA8 as the single delivery format for every consumer**, and
keep RGBA16F **only** as an internal compute detail for the Metal math passes
that benefit from float headroom. One representation crosses the boundary; one
representation does the math.

Non-goals: changing capture bit depth (stays 8-bit), changing the lane *content*
(natural/processed/tracker semantics unchanged), or adding new public API.

## Background: the three lanes

| Lane | Meaning | Produced by | Resolution | Consumers |
|---|---|---|---|---|
| **Natural** | Sensor image after YUV→RGB + crop, **before** color grading. Also the source for the other two lanes. | Pass-1 (`yuvToRgba`) | full capture (e.g. 4032×3024) | native preview, Flutter `.natural`, `captureNaturalPicture`, WB calibration (internal) |
| **Processed** | Natural **+** CameraKit color/white-balance transform — the graded main view. | Pass-2 (`colorTransform`) | full capture | native preview, Flutter `.processed`, `captureImage`, NV12 video encode (internal) |
| **Tracker** | Natural, downsampled to 480p for cheap computer vision (Canny edges). | Pass-4 (`trackerDownsample`, sampler resample) | 640×480 (`trackerHeightPx = 480`, capture aspect) | native tracker overlay, C++ `CannyConsumer` |

## Design

### Format: BGRA8 everywhere; no RGBA8 anywhere

`kCVPixelFormatType_32BGRA` / `MTLPixelFormat.bgra8Unorm` for all delivery.
Audit of every consumer confirms BGRA8 and **no RGBA8 preference**:

- **Flutter** — *requires* BGRA8: zero-copy via
  `CVMetalTextureCacheCreateTextureFromImage` works only for `_32BGRA`
  (migration design §7).
- **Tracker** (`CannyConsumer.cpp:86-89`) — already has a
  `_32BGRA → COLOR_BGRA2GRAY` path; OpenCV is BGR-native. Today it takes the
  slower half-float path (`:90-98`) only because the tracker lane is fed RGBA16F.
- **Native preview** — consumes Metal textures (`DisplayViewModel.swift:35,36,127`);
  `.bgra8Unorm` is the canonical IOSurface-wrappable 8-bit Metal format.
- **Still capture** — the only RGBA today is `makeCGImage`'s `noneSkipLast` byte
  order, an artifact of vImage emitting RGBA. CGImage consumes BGRA natively via
  `byteOrder32Little | noneSkipFirst`.

RGBA survives only as the internal compute format `kCVPixelFormatType_64RGBAHalf`
/ `.rgba16Float`.

> Caveat: Flutter's BGRA requirement is confirmed from the migration design §7
> and Flutter iOS's documented external-texture behavior, not from reading the
> Dart plugin in the separate `camera2_flutter_demo` repo. Re-verify there if
> desired before release.

### Internal 16F vs delivery BGRA8

```
Camera ISP → 8-bit YUV NV12 (full res)
                 │
   ╔═════════════▼═══════════════════════════════════════════╗
   ║  INTERNAL COMPUTE — RGBA16F (float headroom for math)    ║
   ║  Pass1 YUV→RGB ─► naturalTex16F ─┬─► Pass2 color ─► processedTex16F ─► Pass5 NV12 (internal)
   ║                                  ├─► Pass4 downsample ──────────────────────────────┐
   ║                                  └─► WB calibration (samples natural 16F, internal)  │
   ╚══════════════╤═══════════════════════════╤══════════════════════════════════════════╪═══════╝
        standalone convert            standalone convert                           Pass4 writes
                  ▼                            ▼                                     BGRA8 (fused)
   ╔══════════════╧════════════════════════════╧════════════════════════════════════════╧═══════╗
   ║  DELIVERY — BGRA8, one IOSurface per lane = CVPixelBuffer + .bgra8Unorm MTLTexture          ║
   ║    natural (full)            processed (full)               tracker (640×480)               ║
   ╚════════════════════════════════════╤═══════════════════════════════════════════════════════╝
                                         ▼
        Flutter bridge · native preview · C++ tracker · still capture   (all BGRA8)
```

The three internal 16F textures are **render targets for the math passes**.
A single internal 16F mailbox — the **natural** texture — is retained because WB
calibration (`dispatchCenterPatch`, `MetalPipeline.swift:831/855`) samples it.
The processed and tracker 16F texture mailboxes are removed (no remaining
reader once still capture and the 16F texture accessors move off them).

### Per-lane conversion strategy

Principle: **fuse when a lane's 16F has no downstream reader; standalone when it
does.**

| Lane | 16F downstream reader? | Strategy |
|---|---|---|
| Natural | yes — Pass-2, Pass-4, calibration | keep 16F render target; **standalone** `rgba16fToBgra8` convert → BGRA8 (full res) |
| Processed | yes — Pass-5 NV12 encode | keep 16F render target; **standalone** `rgba16fToBgra8` convert → BGRA8 (full res) |
| Tracker | **no** — output is delivery only | **fuse**: allocate the tracker pool as `.bgra8Unorm`; Pass-4's existing sampler-downsample writes BGRA8 directly. Zero shader change (unorm clamps [0,1] on write), no extra pass, no extra pool |

No new resize pass: the tracker's resolution change already happens in Pass-4's
sampler resample. The standalone convert kernel (`Rgba16fToBgra8.metal`) is 1:1
(read by grid id), so its output pool matches its input lane's resolution.

### Texture/buffer collapse

Each lane has **one** BGRA8 IOSurface-backed buffer, exposed two ways over the
same surface:

- `currentPixelBuffer(stream:)` → the `CVPixelBuffer` (Flutter, C++ tracker via
  FrameSet)
- `currentTexture()` / `currentProcessedTexture()` / `currentTrackerTexture()` →
  a `.bgra8Unorm` `MTLTexture` view of the same surface (native preview)

This deletes the texture(16F)/buffer(8-bit) asymmetry. `currentTexture()` and
friends move from RGBA16F to BGRA8. The preview Metal renderer needs no change:
`.bgra8Unorm` samples to a correct RGBA `float4`.

The `FrameSet` published on `consumers.yield` / the AsyncStream / the C++
`PixelSink` pool also carries the BGRA8 lane buffers (today it carries 16F).

### Still capture

Both still methods read the latest BGRA8 lane buffer directly (as
`captureNaturalPicture` already does for natural):

- `captureImage` → latest **processed** BGRA8 buffer
- `captureNaturalPicture` → latest **natural** BGRA8 buffer

Removed: Pass-6 blit, the still-capture pool, the `armCapture` continuation, the
`StillCapture.convertRGBA16FtoRGBA8` vImage step, and the parallel
`latestNaturalBufferRGBA16F` mailbox. `encode` reads BGRA8 and builds the
CGImage with BGRA byte order. Capture semantics shift from "next frame after
shutter" to "latest delivered frame" (~1 frame / ~33 ms older) — accepted, and
already the behavior of `captureNaturalPicture`. Output formats unchanged
(processed → TIFF, natural → JPEG); EXIF/Photos paths unchanged.

## Behavior summary

| Consumer | Before | After |
|---|---|---|
| `currentPixelBuffer(.natural / .processed)` | BGRA8 (flag-on) | **BGRA8** |
| `currentPixelBuffer(.tracker)` | RGBA16F | **BGRA8** (640×480) |
| `currentTexture()` / `…Processed()` / `…Tracker()` | RGBA16F | **BGRA8** (`.bgra8Unorm`, same surface) |
| FrameSet (C++ tracker / AsyncStream) | RGBA16F | **BGRA8** |
| `captureImage` | 16F → Pass-6 → vImage → TIFF | latest **BGRA8** processed buffer → TIFF |
| `captureNaturalPicture` | parallel 16F mailbox → JPEG | latest **BGRA8** natural buffer → JPEG |
| `SessionCapabilities.streamPixelFormat` | `"BGRA8"` / `"RGBA16F"` | constant `"BGRA8"` |
| Pass-1/2/4 math, Pass-5 NV12 encode, WB calibration | RGBA16F | **RGBA16F** (unchanged) |

## What's removed

- `OpenConfiguration.lanesEightBit` and its opt-out RGBA16F-buffer path.
- Pass-6 still readback blit, the still-capture pool
  (`makeStillCapturePool`), and `armCapture` / its continuation.
- `StillCapture.convertRGBA16FtoRGBA8` (vImage 16F→8).
- The parallel `latestNaturalBufferRGBA16F` mailbox.
- The `_latestProcessedTex` / `_latestTrackerTex` 16F mailboxes (no readers left).
- The texture/buffer asymmetry and its "don't refactor away" warnings.

## Files affected

| File | Change |
|---|---|
| `Capabilities.swift` | remove `lanesEightBit` from `OpenConfiguration`; `streamPixelFormat` → constant `"BGRA8"`; fix doc-comments |
| `Constants.swift` | single lane format (`_32BGRA` / `.bgra8Unorm`); drop the flag-conditioned `streamPixelFormatString*` pair |
| `MetalPipeline.swift` | tracker pool → BGRA8 (Pass-4 direct); standalone convert for natural + processed always; route buffer **and** texture mailboxes to BGRA8; keep 16F natural-texture mailbox for calibration; drop processed/tracker 16F mailboxes; FrameSet uses BGRA8; remove Pass-6/still-pool/armCapture; fix comments |
| `CameraEngine.swift` | texture accessors return BGRA8; `currentPixelBuffer(.tracker)` BGRA8; `captureImage`/`captureNaturalPicture` read BGRA8 lane buffers; remove flag plumbing + parallel-16F sourcing; fix comments |
| `StillCapture.swift` | remove vImage convert + `armCapture` path; `encode` consumes BGRA8; CGImage BGRA byte order |
| `TexturePoolManager.swift` | tracker pool factory → BGRA8 at `trackerSize`; remove `makeStillCapturePool` |
| `Shaders/Rgba16fToBgra8.metal` | unchanged (still the natural+processed convert kernel) |
| `DECISIONS.md` | append decision superseding D-2P-11 |
| `state.md` | update progress ledger |
| Tests | rework `RgbaConversionTests.swift`, `Stage13Phase2Tests.swift` |

## Testing

- **Unit (Swift Testing):** all three lanes — incl. tracker — emit `_32BGRA` on
  both buffer and texture accessors; internal natural texture stays
  `.rgba16Float`; `streamPixelFormat == "BGRA8"`; both still methods produce
  valid output from the BGRA8 path; tracker BGRA8 buffer is 640×480. Remove the
  flag-toggle suites.
- **On-device HITL** (per established pattern, iPad — never simulator): sustained
  fps at 4K with all three lanes converting; native preview, tracker overlay,
  and both still paths visually correct; record into `measurements/phase-3-prep/`.

## Downstream impact (cam2fd / Pigeon contract)

- **`streamPixelFormat` contract is unchanged for Flutter.** It still reports
  `"BGRA8"` — it simply stops being toggleable. The Pigeon contract is not
  modified; the Dart side (`hitl_screen.dart`) reads it only as a display
  string. No Flutter/Dart code change required.
- **`OpenConfiguration.lanesEightBit` removal is API-breaking but safe.** The
  only external consumer is cam2fd (CLAUDE.md §10); its own code never passes
  the param (verified 2026-05-20). The flag/constant references that exist in
  cam2fd live in its embedded CameraKit subtree copy, which mirrors this repo
  via `camerakit-only` and receives these edits on sync. No deprecation shim.
- **Sync obligation:** after this lands on `main`, the `camerakit-only`
  synthetic branch must regenerate (the `.githooks/pre-push` hook does this on
  push; CLAUDE.md §10) so cam2fd's embedded copy and its mirrored tests stay
  consistent.

## Decisions

- **D-2P-12** (this design): 8-bit BGRA8 is the sole delivery format for all
  consumers; RGBA16F is internal-compute-only. Removes the `lanesEightBit` flag,
  the texture/buffer asymmetry, the parallel 16F still mailbox, and the Pass-6
  still pipeline. Tracker lane converts via fused Pass-4 BGRA8 output; natural
  and processed via standalone `rgba16fToBgra8`. Supersedes D-2P-11; retains
  D-2P-09 (BGRA8 wire format).

## Open questions

- None blocking. Optional: verify BGRA against the Dart plugin in
  `camera2_flutter_demo` before a Phase-3 release.
