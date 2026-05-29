# Stage 06 HITL Evidence — Consumer Registry

Date: 2026-04-23  
Device: iPad (00008027-000539EA0184402E)  
Build: Debug, branch stage-01

## Results

| ID | Description | Result |
|----|-------------|--------|
| 06:tracker-thumbnail-appears-on-subscribe | Tapping "Show Tracker" renders a 160×120pt yellow-bordered MTKView thumbnail bottom-left showing live camera content | PASS |
| 06:debug-overlay-shows-frame-number-capture-time | Yellow `#N  t=…ms` counter appears top-left; N increments monotonically; t is non-decreasing | PASS |

## Notes

- Root cause of green artifact in tracker thumbnail (right ~50%) and processed preview
  right-edge strip: `captureOrientationAngleDeg` was 90°, causing AVFoundation to deliver
  portrait-rotated buffers while `captureSize` remained landscape (from format description
  before rotation). YUV shader out-of-bounds reads at `gid.x ≥ delivered_width` returned
  `(Y=0, Cb=0, Cr=0)` → RGB `(0, 154, 0)` = green. Fixed by setting angle to 0°.
- Debug overlay throttled to every 10th frame (~3 fps) to eliminate 30 SwiftUI
  re-renders/sec; MTKView preview remains GPU-direct at 30 fps.
- App orientation locked to landscape-right via `UIApplicationDelegateAdaptor` +
  Info.plist `UISupportedInterfaceOrientations~ipad`; `UIRequiresFullScreen = true`
  disables Split View / Slide Over.
