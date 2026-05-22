# ISP natural-capture — HITL evidence

> Feature: `captureNaturalPicture` → AVCapturePhotoOutput one-shot → Metal crop+grade → TIFF.
> Spec: `docs/superpowers/specs/2026-05-22-isp-natural-capture-design.md`.
> Unit status: 206/206 device suite green, 0 warnings. The checks below need a human + iPad pointed at a real scene.

## Checklist (fill in on-device)

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | **Capture returns** — `[natural] ISP capture complete` follows `[natural] ISP capture start` in the device log (no hang) | ⬜ | |
| 2 | **Photo dims == captureSize** — capture does NOT throw `unsupportedFormat` (the dimension guard). If it throws, pin `photoOutput.maxPhotoDimensions` to the active format's video dims | ⬜ | #1 risk |
| 3 | **420f accepted** — no delegate error about pixel format | ⬜ | |
| 4 | **ISP quality** — saved TIFF looks native-camera-processed (sharper/cleaner than a video frame) | ⬜ | |
| 5 | **Grade match** — TIFF carries the same live grade as the preview at shutter time (move a slider just before capture to confirm snapshot-at-arrival) | ⬜ | |
| 6 | **Crop framing** — TIFF is cropped to the active region, not the full sensor | ⬜ | |
| 7 | **Orientation** — TIFF is right-way-up, matching the preview (no 90° rotation) | ⬜ | |
| 8 | **Pause contract** — capturing while paused throws cleanly (no stale frame) | ⬜ | |
| 9 | **Latency** — shutter→file delay is acceptable UX | ⬜ | |

## Sample output

- Path(s):
- Pull from device: `xcrun devicectl device copy from --device <devicectl-udid> --domain-type appDataContainer --source Documents/<file>.tif --destination /tmp/`

## Findings / follow-ups

-
