# HITL evidence — 8-bit BGRA end-to-end delivery (Task 8)

Verification for `docs/superpowers/plans/2026-05-20-8bit-bgra-end-to-end-delivery.md`
(D-2P-12). Branch `worktree-bugfix-flutter-crash`.

## Environment

- **Device:** Shreeyak's iPad Pro 11" 2nd-gen (`iPad8,9`), iOS 26.4.2
  - xctrace/xcodebuild UDID `00008027-000539EA0184402E`
  - devicectl UDID `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`
- **Capture resolution:** 4032×3024 (device-selected 4:3, 4K-class)
- **Build:** Debug, `eva-swift-stitch` scheme, physical device (no simulator)
- **Date:** 2026-05-20

## Step 1 — Full automated test sweep (objective) ✅

`mcp__XcodeBuildMCP__test_device`, scheme `eva-swift-stitch`, no filter
(all CameraKitTests via app-hosted dual-membership):

```
176 passed, 0 failed, 0 skipped
```

Includes the new/retargeted 8-bit assertions: tracker BGRA8 + Pass-4
channel-order/clamp; natural/processed preview BGRA8 + calibration-16F
isolation; FrameSet all-lanes BGRA8; still-capture BGRA8 byte-order
round-trip (TIFF exact, JPEG ±8); natural-capture-source BGRA8.

## Step 2 — On-device runtime evidence

### fps + delivery stability at 4K, all three lanes (objective) ✅

From `<Documents>/camerakit.log`, session `2026-05-20 04:32:40`
(pulled via the `ipad-logs` skill / `devicectl`):

```
04:32:40  open: pipeline ready — 4032×3024
04:32:41.015  yield: frame=0   stream=0/1/2  surface=true   (natural/processed/tracker)
04:32:51.064  yield: frame=300 stream=0/1/2  surface=true
04:33:01.073  yield: frame=600 stream=0/1/2  surface=true
[metrics] every window: natural=0/0 processed=0/0 tracker=0/0  (cppOverwrite/swiftDrop)
```

- frame 0→300: 10.049 s ⇒ **29.85 fps**
- frame 300→600: 10.009 s ⇒ **29.97 fps**
- Repeatable via `scripts/hitl-fps-smoke.sh [seconds]` — launches the app,
  pulls the log, parses fps from the frame counters, and asserts fps ∈ [27,31]
  with 0 drops/overwrites (exit 0/1). Re-run 2026-05-20: `✓ PASS — ~29.93 fps,
  0 drops/overwrites`.
- **~30 fps sustained**, all three lanes delivering BGRA8 IOSurfaces
  (`surface=true`), **0 frame-drop windows, 0 mailbox overwrites** across the
  run. Matches the rgba8 baseline (30 fps, 0 degraded windows). No errors,
  no crashes in the session log.

### Live-frame sanity logger (DEBUG, objective) ✅

`DisplayViewModel` (DEBUG) samples the delivered natural BGRA8 center pixel
~1 Hz and logs to `camerakit.log`: one "healthy" line on the first good frame,
then warns only if a frame is degenerate (alpha ≠ 255 or all-zero). Observed:

```
[sanity] natural delivery healthy frame=0 BGRA=[1,0,1,255]
```

alpha = 255 confirms correct BGRA delivery on real frames. (It cannot detect
on-screen green frames — those are a drawable artifact, not lane-buffer
content; see the function's doc-comment.)

### Visual correctness (subjective — user-confirmed on device 2026-05-20) 

The XcodeBuildMCP `screenshot` tool is simulator-only and cannot capture a
physical-device frame, so these were confirmed by direct observation on the
iPad (app running, pid 1746):

- [x] **Native preview correct** — both natural + processed panels show the
      real scene, correct colors, **no green/garbage frames**. (MTKView drawable
      + lane textures are both `.bgra8Unorm`; a format mismatch would render
      green — CLAUDE.md §8.)
- [x] **`captureImage` (processed, TIFF)** visually correct, no R/B swap.
- [n/a] **`captureNaturalPicture` (natural, JPEG)** — not wired into the dev
      harness UI (no button), so not on-glass testable here. The encode path is
      covered by automated tests (BGRA8 JPEG round-trip ±8, natural-source
      BGRA8). UI wiring is a separate concern, untouched by this work.
- [x] **Tracker overlay colors correct** — DEBUG tracker thumbnail renders the
      downsampled scene (BGRA8 fused Pass-4) with correct colors.

> Channel order / clamp is additionally guarded by automated tests
> (Pass-4 + convert-kernel value tests, still-capture file round-trip), so a
> R/B swap would already fail Step 1.

### Observation — tracker thumbnail tearing (pre-existing, not a regression)

The user noted the DEBUG tracker thumbnail shows tearing / appears to skip
frames / refreshes below the preview's rate. Assessment: **not introduced by
this work.**

- `makeBgra8LanePool` and the previous `makeWorkingFormatPool` are byte-for-byte
  identical in pool attributes (`poolMinBufferCount = 3`, same max-age, same
  IOSurface/Metal compatibility) — only the pixel format differs. Buffer
  count / rotation cadence is unchanged.
- The tracker thumbnail's delivery path (DEBUG `.tracker` subscription →
  `await MainActor.run { trackerTex.store(...) }` → MTKView reads the mailbox)
  hops through MainActor and is inherently laggier than the always-on previews,
  which read `currentTexture()` directly each draw. This cadence predates the
  8-bit migration.
- Colors are correct (the migration's concern); fps/delivery metrics show 0
  drops / 0 overwrites at ~30 fps.

⇒ Out of scope for the 8-bit delivery work; logged here as a candidate
follow-up for the DEBUG tracker-thumbnail render path if desired.
