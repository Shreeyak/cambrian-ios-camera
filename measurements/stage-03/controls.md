# Stage 03 HITL evidence

Device: Shreeyak's iPad (iPad8,9 / iPad Pro 11" 2nd gen, iOS 26.4.1)
Date: 2026-04-21

## 03:iso-slider-updates-exposure-live — DEFERRED

xcodebuild CLI cannot deploy to the physical iPad in this session (iOS 26.4.1 device
with Xcode 26.5 beta active; `build_run_device` uses `generic/platform=iOS` which
requires iOS 26.5 platform components not yet installed). Xcode GUI can build and run.

Run the app from Xcode GUI (eva-swift-stitch scheme → Shreeyak's iPad) and verify:
- Move the ISO slider; confirm preview luminance changes smoothly.
- Move the Shutter slider; confirm ISO readback shifts (Rule 2 visible).
- PASS / FAIL to be recorded here.

## 03:restart-restores-settings — DEFERRED

Same deployment blocker as above.

To verify: set ISO/Shutter/Focus/Zoom sliders to non-default values, force-quit the
app, relaunch, confirm slider positions restored and readback labels match pre-quit state.

UserDefaults dump (LLDB):
```
po UserDefaults.standard.data(forKey: "CameraKit.CameraSettings")
```
Expected: non-nil Data blob.

Result: DEFERRED — to be verified when device deployment is unblocked.

## Device smoke — additional

- Rule 1 (ISO manual → Shutter manual): DEFERRED
- Rule 2 (Shutter manual → ISO manual): DEFERRED
- Landscape-right lock: DEFERRED

## Notes

All 7 Stage 03 automated tests pass on device (via Xcode MCP RunSomeTests, 16/16 total).
HITL evidence is blocked only by the Xcode CLI destination discovery issue, not by the
code itself. Xcode GUI confirmed the project builds and runs on Shreeyak's iPad.
