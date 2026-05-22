# ISP natural-capture — HITL evidence

> Feature: `captureNaturalPicture` → AVCapturePhotoOutput one-shot → Metal crop+grade → TIFF.
> Spec: `docs/superpowers/specs/2026-05-22-isp-natural-capture-design.md`.
> Unit status: 206/206 device suite green, 0 warnings. The checks below need a human + iPad pointed at a real scene.

## Checklist (fill in on-device)

Tested 2026-05-22 on Shreeyak's iPad (iOS 26), via the dev-harness "Natural" button.

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | **Capture returns** — `[natural] ISP capture complete` follows `[natural] ISP capture start` (no hang) | ✅ | ~488 ms start→complete |
| 2 | **Photo dims == captureSize** — no `unsupportedFormat` (dimension guard) | ✅ | Photo came back 4032×3024 == captureSize; guard never fired. **No `maxPhotoDimensions` pin needed.** |
| 3 | **420f accepted** — no delegate format error | ✅ | |
| 4 | **ISP quality** — saved TIFF looks native-camera-processed | ~ | Image valid + rendered; sharper-than-video not yet A/B'd |
| 5 | **Grade match** — TIFF carries the live grade | ✅ | User: "desaturated, just like I set it to" |
| 6 | **Crop framing** — cropped to active region | ⬜ | Not exercised (no crop active; outputSize == captureSize). Same crop-uniform path as the verified live pipeline. |
| 7 | **Orientation** — right-way-up, matches preview | ⬜ | Not explicitly confirmed |
| 8 | **Pause contract** — capturing while paused throws cleanly | ⬜ | Not yet tested |
| 9 | **Latency** — shutter→file delay acceptable | ✅ | ~488 ms |

## Sample output

- `/var/mobile/Containers/Data/Application/<app>/Documents/2026-05-22T04-21-34Z.tif` (4032×3024, desaturated per live grade)
- Pull from device: `xcrun devicectl device copy from --device DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 --domain-type appDataContainer --domain-identifier com.cambrian.eva-swift-stitch --source Documents/<file>.tif --destination /tmp/`

## Findings / follow-ups

- ✅ Core path validated on device: ISP one-shot → grade → TIFF, 4032×3024, grade applied. The flagged #1 risk (photo dims > captureSize) did NOT occur — the photo defaults to the active format's video dims under `.inputPriority`.
- Dev-harness "Natural" button added (`camera.aperture`) in `eva-swift-stitch/UI/` to enable HITL — the library always exposed `captureNaturalPicture()`; only the app UI lacked a trigger.
- Remaining optional checks: orientation (#7), pause-error (#8), crop-active framing (#6).
