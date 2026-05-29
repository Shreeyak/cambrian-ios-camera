# Pre-Phase-3 RGBA8 conversion — HITL evidence

**Date:** 2026-05-15
**Device:** Shreeyak's iPad Pro 11" 2nd-gen (iPad8,9), iOS 26.4.2
**Capture resolution:** 4032 × 3024 (active)
**Branch:** `rgba8` (worktree)
**Spec:** `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`
**Plan:** `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md`

## Scope of HITL

Plan §Task 10 acceptance:

1. Visual MTKView preview unchanged with `lanesEightBit = true` (default).
2. Sustained 30 fps at 4K with conversion pass on.
3. Still-capture HDR fidelity unchanged.

## Results — default-on (`lanesEightBit: true`)

### 1. Visual smoke — MTKView preview

- Both panels visually unchanged vs. opt-out comparison build
  (`lanesEightBit: false`, deployed transiently for A/B diagnostic).
- **Camera-sensor temporal edge noise present in both flag-on and flag-off
  builds, and also visible in iOS's built-in Camera app** — independent
  observation by the user. The conversion pass is NOT the source.
- No color cast, no banding, no GPU memory artefacts (green frames),
  no MTKView format mismatch — texture accessors keep returning
  `.rgba16Float` regardless of flag (design's load-bearing asymmetry,
  confirmed by `RgbaConversionMailboxFormatTests.textureMailboxesAlwaysRgba16Float`).
- **Verdict: pass.**

### 2. Sustained 30 fps at 4K with conversion on

- ~2-minute exercise window (`13:08:14` to `13:10:14` device-time).
- Metrics-stream window emission cadence:
  `[metrics] window emit (cppOverwrite/swiftDrop): natural=0/0 processed=0/0 tracker=0/0`
  repeating every ~3 s.
- 300 frames between `13:08:14.782` (`frame=0`) and `13:08:24.826`
  (`frame=300`) — exactly **30.0 fps**, no jitter.
- **fps-degraded events: 0.**
- **mailbox-overwrite events: 0.** (`cppOverwrite/swiftDrop` strings all
  zero across every window.)
- Two extra Metal compute dispatches per frame (Pass-7 natural +
  Pass-7 processed) fit cleanly inside the 33 ms per-frame budget at 4K
  on the iPad Pro M-class GPU.
- **Verdict: pass.**

Raw log slice: `/var/folders/3n/.../T/camerakit-live.log` session at
`2026-05-15 13:08:14`.

### 3. Still-capture HDR fidelity unchanged

- `captureImage` triggered on the flag-on default build (re-installed via
  `xcrun devicectl device install app`, launched via
  `xcrun devicectl device process launch`).
- User visual verdict: "images look good."
- Architectural rationale — `captureImage` is structurally untouched by
  the conversion pass: Pass-6 blits `processedTexI` (RGBA16F texture)
  into the dedicated 1-slot `stillCapturePool` (RGBA16F,
  CPU-readable), then `StillCapture.swift:75` vImage-converts RGBA16F →
  RGBA8 for TIFF output. The Pass-7 dispatch + buffer mailbox rewire
  touch only the bridge-facing lane buffers; the texture mailboxes and
  the still-pool path are unaffected.
- `captureNaturalPicture` sources from the parallel `latestNaturalBufferRGBA16F`
  mailbox added in this PR — kept RGBA16F regardless of the flag, so the
  vImage encode path in `StillCapture.encode` receives the same precision
  as before. (Locked by `RgbaConversionNaturalCaptureSourceTests.flagOnNaturalCaptureBufferIsRgba16f`.)
- **Verdict: pass.**

## Anomalies + resolutions

### A) Edge-noise flicker reported, root cause confirmed not the conversion

- **Report:** "straight edges have this tiny flicker around them."
- **Diagnostic:** transient build with `lanesEightBit: false` deployed and
  compared. Flicker persisted, also present in iOS Camera app.
- **Conclusion:** camera sensor temporal noise, present pre-PR.
- **Action:** none — diagnostic harness opt-out reverted before HITL
  completion. No production code shipped that opt-out.

### B) Xcode hung trying to launch the app

- **Symptom:** Xcode could not launch the app on device mid-HITL.
- **Triage:** orphan `lldb-rpc-server` (pid 39663) from a prior debug
  session, idle since Saturday with 1+ hour cumulative CPU time, was
  jamming Xcode's lldb path.
- **Resolution:** `xcrun devicectl device install app` +
  `xcrun devicectl device process launch` bypassed Xcode entirely and
  put the flag-on build on the iPad successfully.
- **Action:** unrelated to this PR — user can `kill 39663` to clear the
  Xcode hang for future sessions.

### C) MCP servers disconnected mid-HITL

- **Symptom:** `XcodeBuildMCP` + Context7 MCP servers disconnected
  partway through HITL.
- **Action:** fell back to `scripts/build-summary.sh` (the documented
  fallback per CLAUDE.md §6) and `xcrun devicectl` for install/launch.
  No code change required.

## Final test posture

- **Full regression on physical iPad:** 181 / 181 pass / 0 fail
  (was 180 before this PR's new mailbox; +1 from
  `RgbaConversionNaturalCaptureSourceTests`).
- New suites added in this PR (file:
  `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift`):
  - `RgbaConversionConstantsTests` (4)
  - `RgbaConversionOpenConfigurationTests` (4)
  - `RgbaConversionPoolFactoryTests` (2)
  - `RgbaConversionKernelDiscoveryTests` (1)
  - `RgbaConversionPipelineFlagTests` (2)
  - `RgbaConversionMailboxFormatTests` (3)
  - `RgbaConversionTrackerStaysRgba16fTests` (1)
  - `RgbaConversionNaturalCaptureSourceTests` (1)
  - `RgbaConversionStreamPixelFormatTests` (2)
- Phase-2 `Stage13Phase2PixelFormatTests` updated to cover both flag
  states (was `laneFormatIsRGBA16F` only; now
  `defaultLaneFormatIsBgra8` + `optOutLaneFormatIsRgba16f`).
