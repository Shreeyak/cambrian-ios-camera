# Phase 3 — Plan 4 HITL Matrix Results

- **Date:** 2026-05-20
- **Device:** Shreeyak's iPad (`00008027-000539EA0184402E`), iOS 26.4.2
- **App:** `cambrian_camera_example` (`com.cambrian.cambrianCameraExample`), debug
- **Harness:** `packages/cambrian_camera/example/lib/hitl_screen.dart`
- **Headline:** Preview **renders** on iOS in this example app — the Plan-3
  blank-preview blocker did **not** reproduce. Likely cause: the example uses
  Flutter 3.41's scene-based lifecycle (both `AppDelegate.swift` and
  `SceneDelegate.swift` present), unlike the repo-root app.

## §8.4 matrix

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| 1 | Cold launch + permissions | PASS | `cameraPermissionStatus` updates panel; `requestCameraPermission` fires the prompt and returns the granted status. |
| 2 | `open(null, settings)` | PASS | `opened handle=1 1600×1200`, `fmt=bgra8` (✓ BGRA8 acceptance); state→streaming; **left (processed) lane renders**. On *first* open the raw lane is black (`naturalStreamTextureId=0`) — but see #16: it allocates after a close→open cycle, so this is a first-open ordering bug, not a permanent gap. |
| 3 | Preview 30 fps (processed lane) | PARTIAL | Preview renders, but frame rate is **exposure-limited**: 60 ms auto exposure caps fps at ~16.6 (1/0.06s), so the watchdog spams `fpsDegraded: 16.6 fps`. Not a pipeline fault — 30 fps untestable at this light level. Retest under bright light / short exposure. |
| 4 | `updateSettings` manual ISO/exposure/WB | PASS (with usage note) | Manual **WB pinned ✓**. Independent manual ISO / manual exposure calls did **not** pin. **Combined-call retest CONFIRMED the cause:** one `updateSettings(iso: manual(400), exposureTimeNs: manual(10ms))` pinned both — frame reported `iso=399`, `exp=9984000` (hardware-quantized to nearest sensor step; correct). **Classification: not an engine bug — an iOS usage requirement.** Manual ISO and exposure map to `setExposureModeCustom(duration:iso:)`, which needs both together; sending them in separate `updateSettings` calls leaves the device in auto. **Doc/API implication:** callers must set ISO+exposure in a single `CameraSettings` on iOS. |
| 5 | `setResolution` × sizes | PASS | Cycled 3840×2160 → 3264×2448 → 2592×1944 → 1920×1440 → 1920×1080 → 1440×1080. Each emitted `streamConfigurationChanged capture=WxH crop=WxH`; preview tears down + regenerates (visible flicker). Clean. |
| 6 | `setCropRegion` set + clear | FAIL (iOS no-op) | Calls dispatched (`updateSettings crop=1600x1200` set, `crop=4032x3024` clear) with no error, but **no visual change in the processed (left) lane** — the crop *should* zoom the processed preview. `cropOutputSize` (GPU center-crop) appears unimplemented on the iOS engine; works on Android (repo-root CROP button). |
| 7 | `captureImage(saveToLibrary: true)` | PASS | Returns `phAssetLocalId`; image visible in iOS Photos at 1440×1080 (matches last `setResolution`). |
| 8 | `captureImage(saveToLibrary: false)` | PASS | Returns `filePath=/var/mobile/Containers/Data/Application/…/Documents/IMG_….jpg`. |
| 9 | `captureNaturalPicture` both modes | PASS | After relaunch: file mode returns `filePath`; Photos mode returns `phAssetLocalId`. Note: capture momentarily cycled state paused→error→streaming in the log but returned a valid result. |
| 10 | `calibrateWhiteBalance` (iOS host method) | PASS | Gray-world convergence: `before=(r:0.65,g:0.57,b:0.45)` (imbalanced) → `after=(r:0.56,g:0.57,b:0.57)` (neutral). gains `(r:1.208,g:1.0,b:3.179)`. Preview color shifts. NB: calibrating WB on a *covered* lens produces garbage gains (green tint) — operator condition, not a fault. |
| 11 | `calibrateBlackBalance` | PASS | offsets `(r:0.00136,g:0.0060,b:0.001944)` with lens covered. |
| 12 | App background ↔ foreground | **FAIL — engine crash** | `pause`/`resume` *buttons* work (paused→streaming). But backgrounding to the Photos app **crashed the app**: iOS interrupted the `AVCaptureSession`, the engine attempted `interrupted → recovering`, and hit a hard `assertionFailure` at `CameraEngine.swift:1562` ("off-map SessionState transition"). App froze → white screen → would not relaunch. **Contributing harness gap:** `HitlScreen` had no `didChangeAppLifecycleState` pause/resume (repo-root app does); fixed in harness. **Root cause is the engine FSM** — see Engine bugs below. |
| 13 | Control Center pull-down + restore | BLOCKED | Same `interrupted` route as #12 — will crash via the same engine FSM bug until it's fixed. Re-test after the engine fix. |
| 14 | `startRecording` / `stopRecording` | PASS | `recording:` flips recording→idle; returns `uri=file:///var/mobile/…`. |
| 15 | `getNativePipelineHandle` round-trip | PASS | Returns non-null `0x12a15eb80`. (FFI consumer registration not exercised — pointer round-trip only.) |
| 16 | `close` → `open` cycle | PASS (+finding) | Reopens cleanly: `stream=1600x1200 fmt=bgra8`, preview returns. **Bonus:** the RIGHT/raw lane — black on first open (`naturalStreamTextureId=0`) — **starts rendering after this close→open cycle**. So the raw-lane gap is a *first-open texture-allocation ordering bug*, not a permanent absence. |
| 17 | Two concurrent `open(...)` | DEFERRED | Open button disables while open; can't stage concurrent open from the UI without bespoke machinery. Not built. |
| 18 | Hot restart (`r`) during preview | DEFERRED | `flutter run` stdin not drivable from the backgrounded process; not tested. |

## §8.5 failure-mode rehearsal

| Scenario | Result | Notes |
|----------|--------|-------|
| Permission denied before `open` → `permissionDenied` | NOT RUN | Permission already granted; would need a settings-level revoke + relaunch. |
| `updateSettings` during calibration → `calibration_in_progress` | NOT TESTABLE (harness) | The harness serializes calls via `_busy`, disabling all buttons while a calibration is in flight — so a conflicting `updateSettings`/`setResolution` can't be issued mid-calibration through this UI. Needs a non-serialized test path. |
| `setResolution` during calibration → `calibration_in_progress` | NOT TESTABLE (harness) | Same `_busy` serialization. |
| `close` during calibration → cancels, WB restored to auto | NOT RUN | Same serialization (close disabled during calibration). |

## Engine bugs surfaced (CameraKit / eva-swift-stitch — report to producer)

1. **Background-lifecycle FSM crash cluster (DEBUG) — `CameraEngine.swift:1562`
   `publishState` `assertionFailure("off-map SessionState transition…")`.**
   Two distinct illegal transitions observed, both triggered by backgrounding
   the app:
   - `interrupted → recovering` (kind=event) from `publishStateAsync(_:)` —
     when iOS interrupts the `AVCaptureSession` on background.
   - `recovering → streaming` (kind=command) from `notifyScenePhasePaused(_:)` —
     after a `frameStall` (gpu no frame in 3000ms while backgrounded) drove the
     engine to `recovering`, the engine's own scene-phase observer tried to
     force `streaming`.
   Both abort the process in debug; the transitions are illegal regardless of
   build. The engine has its **own** scene-phase observation
   (`notifyScenePhasePaused`) in addition to whatever the host app does, and the
   SessionState FSM lacks legal edges for the background/interrupt/stall paths.
   **Severity: high** — any backgrounding / phone call / camera-contention
   crashes. A Dart-side `pause()` on `AppLifecycleState.paused` does NOT prevent
   it (the engine's scene-phase path crashes independently). Needs an engine FSM
   fix.

2. **iOS `cropOutputSize` is a no-op** (case #6) — GPU center-crop not applied on
   the iOS engine; works on Android.

3. **iOS raw/natural preview texture id = 0 on FIRST open only** (cases #2, #16)
   — `naturalStreamTextureId` is 0 immediately after the first `open`, so the raw
   lane is black; it **allocates correctly after a `close`→`open` cycle**. A
   first-open texture-allocation ordering bug, not a permanent absence. Lower
   severity than initially recorded.

## Follow-ups surfaced

- **Case #4 — RESOLVED + recommended engine change.** Confirmed: combined call
  pins. Recommended engine remediation (per device-owner feedback): when a
  caller passes manual ISO *alone*, the engine should read the current
  `exposureDuration` and call `setExposureModeCustom(duration:iso:)` with both
  (and symmetrically for exposure-alone), giving a smooth transition. This keeps
  the plugin's "only send what changed" contract working on iOS instead of
  silently leaving the device in auto. Engine-side (CameraKit) change; out of
  cam2fd Plan 4 scope.
- **Case #3 lighting:** rerun under adequate light to confirm 30 fps (the
  `fpsDegraded` spam at ~16.6 fps was exposure-limited, not a fault).
