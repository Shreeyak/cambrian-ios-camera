# Bug 6 — back-camera format dump

Captured on Shreeyak's iPad Pro 11" 2nd-gen (`iPad8,9`,
xctrace UDID `00008027-000539EA0184402E`) on 2026-04-30 with
`Bug6Probe.dumpDeviceFormats(avDevice)` called from
`CameraSession.configure()`. Raw lines: `bug6-back-camera-formats.txt`.

## What the dump tells us

48 formats total. Pre-fix bug: `sessionPreset = .high` overrode our
`activeFormat` and silently delivered 1920×1080. Fix: set
`sessionPreset = .inputPriority` before adding the input. Confirmed on
device — `[bug6][incoming][ok] configured=4032x3024 buffer=4032x3024`.

## Format-selection truth table

The current selector (`CameraSession.configure()` §2) picks: largest 4:3
format that supports 30 fps, FullRange before VideoRange. That resolves
to idx 47 (`420f`, 4032×3024, 1–30 fps, FullRange).

Filtered to 4:3 + 30 fps and grouped by binning:

| idx | dims | sub | binned | hqPhoto | maxPhotoDims | fov |
|-----|------|-----|--------|---------|--------------|-----|
| 32  | 1920×1440 | 420v | false | false | …,4032×3024 | 62.3 |
| 33  | 1920×1440 | 420f | false | false | …,4032×3024 | 62.3 |
| 34  | 1920×1440 | 420v | false | false | …,4032×3024 | 62.3 |
| 35  | 1920×1440 | 420f | false | false | …,4032×3024 | 62.3 |
| 36  | 1920×1440 | 420v | **true** | false | …,2016×1512 | 62.3 |
| 37  | 1920×1440 | 420f | **true** | false | …,2016×1512 | 62.3 |
| 38  | 2592×1944 | 420v | false | false | …,4032×3024 | 62.3 |
| 39  | 2592×1944 | 420f | false | false | …,4032×3024 | 62.3 |
| 40  | 3264×2448 | 420v | false | false | …,4032×3024 | 62.3 |
| 41  | 3264×2448 | 420f | false | false | …,4032×3024 | 62.3 |
| **46** | **4032×3024** | **420v** | **false** | **true** | **4032×3024** | **62.3** |
| **47** | **4032×3024** | **420f** | **false** | **true** | **4032×3024** | **62.3** |

Key point: **idx 46/47 are the ONLY formats reporting
`isHighestPhotoQualitySupported = true`**. They are also `binned=false`
at full sensor resolution. The current selector already lands on idx 47.
There is no higher-detail 4:3 video format available on this device.

## Why the still still looks soft vs. the iOS Camera app

User HITL: post-fix still at 4032×3024 has all pixels populated (no green
band) but is visibly less detailed than a Camera-app capture at the same
size.

The Camera app does **not** go through `AVCaptureVideoDataOutput`. It
uses `AVCapturePhotoOutput`, which runs the full ISP photo pipeline:
Deep Fusion, Smart HDR, neural sharpening, noise reduction, possibly
multi-frame fusion. `AVCaptureVideoDataOutput` delivers a less-processed
YUV stream — same pixel count, lower perceived detail. This is by
design and is not fixable by format selection.

## Paths forward (not implemented)

1. **Add `AVCapturePhotoOutput` for stills only.** Live preview / video
   recording / Metal color processing keep using
   `AVCaptureVideoDataOutput` unchanged. On still trigger, fan out to
   `AVCapturePhotoOutput` → ingest the resulting `CVPixelBuffer` into
   the Metal pipeline once for Pass 2 color transform, write the result.
   User-stated constraint: still must go through the Metal pipeline.
   This path satisfies that — it's a single-frame Metal pass, not a
   bypass.

2. **Enable video HDR.** Set `automaticallyAdjustsVideoHDREnabled =
   false` and `isVideoHDREnabled = true` if `format.isVideoHDRSupported`
   (none of the dumped formats expose that flag in the current probe —
   add it to the dump if pursuing this path). Modest detail / dynamic
   range improvement, no architectural change.

3. **Post-process sharpening in Metal.** Add an unsharp-mask or
   Lanczos-equivalent pass to the still-capture path only. Synthetic
   detail recovery. Cheapest; preserves architecture; quality ceiling
   below path 1.

4. **Accept the trade-off.** Document that stills are
   AVCaptureVideoDataOutput frames with Pass 2 color processing applied,
   and are not directly comparable to Camera-app captures.

## Probe revert checklist

When this investigation is closed:

- Delete `CameraKit/Sources/CameraKit/Bug6Probe.swift`.
- `CameraSession.swift` — remove `Bug6Probe.dumpDeviceFormats(avDevice)`
  call.
- `MetalPipeline.swift` — remove the two `Bug6Probe.note*` calls (one
  in `init`, one at the top of `encode()`).
- `CameraView.swift` — remove the `label` parameter from
  `MTKViewRepresentable` / `MTKViewCoordinator` and the
  `Bug6Probe.noteDraw` call. Restore the three call sites to the
  no-label form.

The actual fix (`sessionPreset = .inputPriority` in
`CameraSession.swift`) stays in.
