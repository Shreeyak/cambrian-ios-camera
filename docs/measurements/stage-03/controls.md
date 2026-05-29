# Stage 03 HITL evidence

Device: iPad (A16) — iPad15,7, iOS 26.4.1
Date: 2026-04-21

## 03:iso-slider-updates-exposure-live — PASS

Deployed via XcodeBuildMCP `build_run_device`. Verified manually on device:
- ISO slider range: 28–1728 (device-reported `isoRange`, now live from `SessionCapabilities`)
- Moving ISO slider changes preview luminance smoothly and continuously
- No lag, freeze, or crash observed

## 03:restart-restores-settings — PASS

Three bugs were found and fixed during verification (all three were silent failures that
cascaded from one root cause):

**Bug A — ISO restore aborted entire settings restore:**
Persisted ISO could exceed the device's current `isoRange` max (e.g. 1720 > 1694),
causing `updateSettings` to throw `settingsConflict` which was silently swallowed in
`open()`. This aborted the entire restore call — zoom and focus never reached the commit
path. Fix: clamp persisted ISO to `device.isoRange` before calling `updateSettings` in
`open()`.

**Bug B — ViewModel never seeded from engine after open():**
`ViewModel.currentSettings` was initialised as `CameraSettings()` (all nil) and never
populated from the engine's restored state. Sliders all showed defaults because their
bindings fell through to `?? default`. Fix: call `engine.currentSettingsSnapshot()` after
`engine.open()` and seed `viewModel.currentSettings`.

**Bug C — ISO slider range hardcoded:**
`CameraView` hardcoded `30...3200` instead of using `capabilities.isoRange`. Fix: drive
slider range from `viewModel.capabilities?.isoRange`.

Post-fix verification:
- Set ISO, Shutter, Focus, Zoom to non-default values
- Force-quit app
- Relaunch: all four sliders restored to pre-quit positions ✓
- ISO slider range shows 28–1728 (device-actual) ✓

## Device smoke — additional

- Shutter slider range: 0–99 ms (readback; sub-1 ms exposures display as 0 — integer truncation of ns/1_000_000)
- Focus slider: 0.0–1.0 ✓
- Zoom slider: 1.00x–5.00x ✓

## Notes

All 7 Stage 03 automated tests pass.
Bugs A/B/C were post-stage fixes found during HITL verification; not scaffolded.
