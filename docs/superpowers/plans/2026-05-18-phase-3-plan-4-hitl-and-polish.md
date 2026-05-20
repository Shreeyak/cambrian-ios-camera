# Phase 3 — Plan 4: HITL Matrix + Polish

> **For agentic workers (opus or similar):** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Lean by design — acceptance metrics + reference pointers, not exhaustive code blocks.

**Goal:** Make the cam2fd example app a functional HITL harness exercising every Phase-3 host method. Run the 18-case on-device verification matrix from spec §8.4. Land the spec §10 open-question items (Info.plist privacy strings, hot-restart texture handling). Run the loaded-mode regression from spec §8.6. Ship the docs (README, DECISIONS). Optional: the Flutter raster-time signpost follow-up. Exit state: Phase 3 verified shipped; cam2fd's iOS implementation is at parity with Android.

**Architecture:** This is the wrap-up plan. No new architecture; just exercising the end-to-end stack and writing down what passed. Example-app HITL screen is a stack of buttons + result text per host method — UX is deliberately minimal, the point is testability. The loaded-mode regression mirrors the texture-bridge spike's run-2 stressor but inside the real cam2fd pipeline.

**Tech Stack:** Flutter Dart UI for the HITL screen, `PlistBuddy` for Info.plist verification (per the eva-swift-stitch memory note: Xcode silently drops some `INFOPLIST_KEY_*` keys), `flutter run -d <udid>` for device, screen recording (QuickTime / iPad screen record) for visual evidence.

**Spec source:** `docs/superpowers/specs/2026-05-18-phase-3-design.md` §8 (verification), §10 open questions 8 + 9 (Info.plist, hot-restart).

**Prerequisite:** Plans 1, 2, 3 merged in cam2fd. iOS plugin functionally complete; Android side compiles; both Plans-1-2-3 smoke tests passed.

**Working branch (cam2fd):** `phase-3-plan-4-hitl-and-polish`.

---

## Decisions taken (per spec)

- **HITL screen lives in `packages/cambrian_camera/example/lib/`**, not the plugin. The example app is where Flutter consumers see the plugin in action; expanding it for HITL serves both purposes.
- **18-case matrix per spec §8.4 verbatim.** Plus the two added cases (17, 18) for concurrent-open and hot-restart.
- **Two iPads, two UDID schemes.** Per eva-swift-stitch CLAUDE.md §8: the project rotates between iPad Pro 11" 2nd gen and iPad A16. Plan 4 runs the matrix on whichever is connected; cross-iPad parity is opportunistic (a Plan-4 stretch goal, not a gate).
- **Loaded-mode regression threshold per spec §8.6: signal:pull ≥ 0.9 under the 5000-circle stressor.** If lower, the Flutter raster-time signpost becomes mandatory; otherwise it's a follow-up.
- **Photos library acceptance: PHAsset roundtrips end-to-end.** `captureImage(saveToLibrary: true)` returns non-null `phAssetLocalId`; image is openable in iOS Photos.
- **No new Android-side work.** Plan 4 verifies iOS; Android's existing impl (post-Plan-1 contract amendments) is left as-is. Any Android polish (the §5.4 MediaStore TODO, etc.) is a separate plan.

---

## File Inventory (cam2fd)

### Created

- `packages/cambrian_camera/example/lib/hitl_screen.dart` — Flutter HITL screen with buttons + result text per host method
- `packages/cambrian_camera/example/lib/main.dart` — modified to route to the HITL screen (or add a button to it)
- `packages/cambrian_camera/README.md` — major update for SPM enablement, subtree update flow, plugin-class-name convention, troubleshooting
- `packages/cambrian_camera/example/ios/Runner/Info.plist` — `NSCameraUsageDescription` + `NSPhotoLibraryAddUsageDescription` source values (verified via PlistBuddy in built `.app`)

### Created (eva-swift-stitch, for documentation)

- `docs/measurements/phase-3-hitl/2026-MM-DD/` directory:
  - `notes.md` — verbatim HITL matrix results (PASS/FAIL/notes per case)
  - `loaded-mode-regression.csv` — measurements from spec §8.6 rerun
  - `screen-recordings/` — at least one full HITL recording (.mov)

### Modified (cam2fd)

- `packages/cambrian_camera/example/lib/main.dart` — wire HITL screen
- `packages/cambrian_camera/example/ios/Runner.xcodeproj/project.pbxproj` — if Info.plist build-setting route is used instead of source Info.plist

### Modified (eva-swift-stitch)

- `CameraKit/DECISIONS.md` — optional: append `D-2P-12` (or next) if any new decisions were made during HITL
- `CameraKit/state.md` — optional Phase-3 completion entry

---

## Pre-flight

### Task 0: State check + branch

- [ ] cam2fd on main; Plans 1, 2, 3 merged
- [ ] Plan 3 smoke (iOS calibration works) verified by re-running on device
- [ ] Branch: `git checkout -b phase-3-plan-4-hitl-and-polish`
- [ ] One iPad connected; record xctrace + devicectl UDIDs

---

## Cluster A — Info.plist privacy strings (spec §10 OQ #8)

### Task A1: Add privacy strings to example app Info.plist

**File:** `packages/cambrian_camera/example/ios/Runner/Info.plist`

**Goal:** Ensure two strings are present:
- `NSCameraUsageDescription` = a user-facing reason (e.g. "Cambrian Camera needs access to the camera to capture and process images.")
- `NSPhotoLibraryAddUsageDescription` = "Cambrian Camera needs permission to save images to your photo library."

If the cam2fd example uses a source `Info.plist`, add the keys directly there. If it uses `INFOPLIST_KEY_*` build settings (Phase-3 spec §10 OQ #8 flags this — Xcode silently drops some keys), set both via the recommended route AND verify in the built `.app`.

### Task A2: Verify with PlistBuddy in built app

```bash
cd packages/cambrian_camera/example
flutter build ios --debug --no-codesign
/usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" build/ios/iphoneos/Runner.app/Info.plist
/usr/libexec/PlistBuddy -c "Print :NSPhotoLibraryAddUsageDescription" build/ios/iphoneos/Runner.app/Info.plist
```

**Acceptance:** Both commands print the expected strings. If either errors with `Does Not Exist`, the source/build-setting route didn't land — fix and rebuild (per the eva-swift-stitch memory note: build settings can silently drop).

---

## Cluster B — HITL screen

### Task B1: Build the HITL screen

**File:** `packages/cambrian_camera/example/lib/hitl_screen.dart`

**Goal:** A Flutter screen with one button per host method + a results panel showing the latest call's outcome. Minimal UX; testability is the point.

Coverage:
- Permission: status query, request (both camera + photos)
- Lifecycle: open, close, pause, resume
- Capabilities: getCapabilities, getPersistedProcessingParams
- Settings: updateSettings with a few preset toggles (manual ISO, manual exposure, manual WB), setProcessingParams, setResolution (cycle through 4 sizes), setCropRegion (set + clear)
- Capture: captureImage (file path), captureImage (Photos), captureNaturalPicture (file path), captureNaturalPicture (Photos)
- Recording: startRecording → stopRecording with file-path display
- Calibration: calibrateWhiteBalance, calibrateBlackBalance
- Diagnostics: sampleCenterPatch, getNativePipelineHandle (display hex)
- Texture: `Texture(textureId: previewTextureId)` + `Texture(textureId: naturalStreamTextureId)` side-by-side

Display:
- Latest state from `onStateChanged` stream
- Latest error from `onError` stream (color-coded)
- Latest `onFrameResult` values (live-updating ~3 Hz)
- Latest `onStreamConfigurationChanged` payload
- Recording state label

**Acceptance:** Buttons exist for every host method. Display panels update from the FlutterApi streams. Texture widgets show the live preview.

### Task B2: Wire HITL screen into `main.dart`

**File:** `packages/cambrian_camera/example/lib/main.dart`

**Goal:** Default route → HITL screen (or a launcher with one button to navigate to it).

**Acceptance:** `flutter run -d <udid>` lands on the HITL screen.

---

## Cluster C — 18-case on-device matrix (spec §8.4 + §10 OQ additions)

Execute on physical iPad. Each case yields PASS / FAIL / NOTES, recorded in `eva-swift-stitch/docs/measurements/phase-3-hitl/<date>/notes.md`.

### Task C1: Run all 18 cases

Per spec §8.4 table (cases 1-16) + spec §10 OQ-derived (cases 17-18). Recap inline so the executor doesn't need to flip back:

| # | Scenario | Acceptance |
|---|---|---|
| 1 | Cold launch + permissions | `cameraPermissionStatus` returns `notDetermined` (fresh) / `authorized` (subsequent); request triggers prompt |
| 2 | `open(null, settings)` with non-null `initialSettings` | First 2 frames at requested ISO/exposure (no defaults-then-snap); `streamPixelFormat == "BGRA8"`; both texture-IDs non-zero |
| 3 | Preview rendering (processed lane) | 30 fps in `Texture(previewTextureId)` widget; no tearing under bare load |
| 4 | `updateSettings` manual ISO/exposure/WB | `onFrameResult` reports requested values within ~3 frames |
| 5 | `setResolution` × 4 sizes | Each emits `onStreamConfigurationChanged` with new dims; preview swaps cleanly |
| 6 | `setCropRegion` set + clear | Stream cfg emits both times; preview reflects crop |
| 7 | `captureImage(saveToLibrary: true)` | Returns `phAssetLocalId`; image in iOS Photos |
| 8 | `captureImage(saveToLibrary: false)` | Returns `filePath`; file exists on disk |
| 9 | `captureNaturalPicture` both modes | Same shape; HDR fidelity unchanged from RGBA8 baseline |
| 10 | `calibrateWhiteBalance` (iOS host method) | Returns `CamCalibrationResult { converged: true, iterations: 1 }`; preview WB adjusts |
| 11 | `calibrateBlackBalance` | Returns shape; preview pedestal adjusts |
| 12 | App background ↔ foreground | `onStateChanged` emits `paused` → `streaming`; preview resumes without rebuild |
| 13 | Control Center pull-down + restore | scenePhase route: `paused` → `streaming`; AVF route (Stage Manager peer): `interrupted` if achievable (else note as deferred) |
| 14 | `startRecording` / `stopRecording` | Valid HEVC MP4 at returned path |
| 15 | `getNativePipelineHandle` round-trip | Non-null `Int64`; Flutter-side FFI consumer registered against it observes the same frame sequence as the engine's tracker stream |
| 16 | `close` → `open` cycle | New handle; new texture IDs; `malloc_history` clean across 2 cycles (or visual inspection of Instruments allocations) |
| 17 | Two concurrent `open(...)` from Dart | Second throws `open_in_flight`; first completes; subsequent `open` works after `close` |
| 18 | Hot restart (`r`) during preview | Example app cleanly disposes texture IDs in Dart; first frame after restart shows new IDs |

Per case: capture log slice + (where applicable) screen-recording clip.

**Acceptance:** All 18 cases pass. Any FAIL → STOP, escalate, log a Plan-4 blocker before proceeding.

### Task C2: Failure-mode rehearsal

Per spec §8.5:
- Camera permission denied in iOS Settings before `open` → `cameraPermissionStatus` returns `denied`; `open` throws `permissionDenied`
- `updateSettings` during `calibrateWhiteBalance` → throws `calibration_in_progress`
- `setResolution` during calibration → throws `calibration_in_progress`
- `close` during calibration → calibration cancels; WB restored to `.auto` per D-2P-05

**Acceptance:** All four scenarios produce the expected errors / state.

---

## Cluster D — Loaded-mode regression (spec §8.6)

### Task D1: Run the 5000-circle stressor inside the cam2fd example app

**Goal:** Replicate the texture-bridge spike's run-2 stressor (5000-circle `CustomPainter` driven by continuous `Ticker`) on the HITL screen — overlay it on top of the preview Texture widget. Run for 60 seconds.

**Instrumentation:** Capture (via Dart side):
- `producedCount` (engine frame count — read from `onFrameResult` if it has a sequence, or count `onFrameResult` events)
- `widgetFrameCount` (Flutter `SchedulerBinding.addPostFrameCallback` count)
- Estimated `signal:pull` ratio (no direct iOS hook; approximate from observable jitter)

**Acceptance threshold:** Per spec §8.6, `signal:pull ≥ 0.9` under stressor on connected iPad. If lower → Flutter raster-time signpost becomes mandatory (Cluster F).

Record results to `docs/measurements/phase-3-hitl/<date>/loaded-mode-regression.csv` with columns matching texture-bridge spike's `results.csv` where applicable.

---

## Cluster E — Documentation

### Task E1: cam2fd `README.md` major update

**File:** `packages/cambrian_camera/README.md`

**Goal:** Adoption section covering:
- SPM enablement: `flutter config --enable-swift-package-manager`
- iOS 26 deployment-target requirement (host app side)
- Plugin class name convention recap (`<PascalCase> + "Plugin"`; `cambrian_camera` → `CambrianCameraPlugin`)
- `flutter build` (not `flutter pub get`) triggers umbrella iOS-platform migration on first build — common gotcha
- Subtree update flow: how to pull a new `camerakit-vX.Y.Z` when CameraKit ships a release (point at eva-swift-stitch CLAUDE.md §10 for the producer-side mechanism)
- iOS-only calibration host methods — note for cross-platform implementers
- Troubleshooting:
  - `MissingPluginException` on iOS → plugin class name mismatch
  - `cannot find type 'CameraEngine'` → SPM linkage broken; check the `Package.swift`
  - Preview is green → likely `lanesEightBit: false` with the wrong texture-wrap format (BGRA bridge expects BGRA buffers)
  - Calibration `calibration_in_progress` → another `updateSettings` or `setResolution` is in flight; debounce in Dart

### Task E2: Update DECISIONS / state in eva-swift-stitch

**Files:** `CameraKit/DECISIONS.md`, `CameraKit/state.md` (optional)

**Goal:**
- If HITL surfaced a new decision (e.g. a Plan-4 mitigation chosen), append a new `D-2P-N` entry.
- `state.md`: add a brief "Phase 3 — completed YYYY-MM-DD" section pointing at the four plans + the HITL measurements directory.

These edits are docs-only → no `camerakit-only` synthetic-branch regeneration (CLAUDE.md §10 pre-push hook ignores non-`CameraKit/` paths).

### Task E3: Status doc in eva-swift-stitch plans

Append "Status — completed YYYY-MM-DD" to each of Plans 1, 2, 3, 4 (or write a single rollup at the top of the spec). Either way, durable record of completion.

---

## Cluster F — Optional: Flutter raster-time signpost

Triggered only if Cluster D shows `signal:pull < 0.9` under the stressor.

### Task F1: Add Dart-side raster-time signpost

**Goal:** Per spec §4 "Loaded-mode jitter follow-up". One `Timeline.timeSync`-wrapped frame callback on the Flutter side, surfaced via the existing metrics stream (or a new one) so ops/QA can detect raster saturation in production.

The exact surface depends on whether cam2fd already exposes a metrics stream — check `cambrian_camera_controller.dart`. If not, add one.

**Acceptance:** Under the stressor, the signpost reports >32ms frame budgets when widget rebuild is heavy; under bare load it reports <16ms.

If Cluster D passed (`signal:pull ≥ 0.9`), skip Cluster F. Mention it in the plan status as "deferred per measurement".

---

## Cluster G — Plan 4 wrap

### Task G1: Final regression sweep

- [ ] All 18 HITL cases passing
- [ ] All 4 failure-mode scenarios passing
- [ ] Loaded-mode regression at or above `signal:pull ≥ 0.9` (or Cluster F implemented)
- [ ] `flutter analyze` clean
- [ ] iOS + Android builds clean
- [ ] README updated
- [ ] HITL evidence checked in under `docs/measurements/phase-3-hitl/<date>/`

### Task G2: Push branch + final commits

- [ ] cam2fd: `git push -u origin phase-3-plan-4-hitl-and-polish` (with user approval)
- [ ] eva-swift-stitch: commit docs updates (DECISIONS, state.md, plan status); push with user approval

### Task G3: Announce Phase 3 complete

Update the Phase 3 spec's status header to "Implemented YYYY-MM-DD". Carry-forward items (Android MediaStore polish per Plan 1 TODO, deeper interrupted-state device test per spec §8.4 case 13) become their own backlog items.

---

## Self-review checklist

- [ ] HITL screen exercises every host method (one button each)
- [ ] Both texture widgets render live preview
- [ ] FlutterApi streams visibly update (state, error, frame-result, stream-cfg, recording-state)
- [ ] 18-case matrix recorded in `docs/measurements/phase-3-hitl/<date>/notes.md` — every case PASS
- [ ] Failure-mode rehearsals recorded
- [ ] Loaded-mode regression CSV saved
- [ ] Info.plist privacy strings verified in built `.app` via PlistBuddy
- [ ] Hot-restart case (#18) observably handles texture-ID staleness
- [ ] README updated; iOS-26 + SPM enablement + plugin class name convention all documented
- [ ] eva-swift-stitch DECISIONS / state updated if any new decisions surfaced
- [ ] All four Plans (1, 2, 3, 4) have a "Status — completed" footer
- [ ] cam2fd branch pushed; eva-swift-stitch docs pushed (with user approval)

---

## Phase 3 — DONE

After Plan 4 wraps, Phase 3 is shipped:

- cam2fd has a working iOS implementation of every Pigeon contract method
- Preview renders zero-copy via the texture bridge (BGRA8 wire)
- Calibration host methods work on iOS via the separate-Pigeon-file pattern; Android Dart loop unchanged
- Lifecycle is observed via scene-phase + AVF interruption routes
- HITL verified on physical iPad
- Documentation reflects the SPM packaging + subtree consumption model
- The `camerakit-only` synthetic branch + tag mechanism remains the producer-consumer interface for future CameraKit releases

Future work (out of Phase 3 scope; not part of any of these four plans):
- Android MediaStore branch for `captureImage(saveToLibrary: true)` — Plan 1's TODO
- Iterative WB calibration on iOS (the spec'd Dart-port future work — separate plan)
- Multi-camera support
- Deeper `interrupted` SessionState device verification (Stage Manager peer scenario)
- Cross-iPad parity sweep on iPad A16
- The `captureNaturalPicture` AVCapturePhotoOutput path (deferred per D-2P-10)

---

## Status — landed + matrix run 2026-05-20 (branch `phase-3-plan-4-hitl-and-polish`)

**Surprise:** the texture-bridge blank-preview blocker did **NOT** reproduce in
the fresh example app — the processed preview rendered immediately. Likely cause:
the example uses Flutter 3.41's scene-based lifecycle (`AppDelegate.swift` +
`SceneDelegate.swift`), unlike the older repo-root app. So Cluster C actually ran
on a physical iPad. Full results: `docs/measurements/phase-3-hitl/2026-05-20/notes.md`.

**Landed (code + docs):**
- **Cluster A** — example `Info.plist` privacy strings; verified in built `.app`
  via PlistBuddy.
- **Cluster B** — HITL harness as a real plugin example app at
  `packages/cambrian_camera/example/`: one button per host method, live stream
  panels, dual texture lanes, app-lifecycle pause/resume, combined ISO+exp
  button. `flutter analyze` clean; widget smoke test passes.
- **Cluster E1** — plugin `README.md` adoption + troubleshooting docs.

**Cluster C — 18-case matrix (ran on iPad, iOS 26.4.2):**
- **PASS (12):** #1 permissions, #2 open (`fmt=bgra8`), #4 manual settings
  (ISO+exp must be set in one call — see below), #5 setResolution, #7/#8
  captureImage (Photos/file), #9 captureNaturalPicture, #10 calibrateWhiteBalance
  (gray-world convergence), #11 calibrateBlackBalance, #14 record, #15
  getNativePipelineHandle, #16 close→open.
- **Conditional (1):** #3 preview fps — exposure-limited (~16.6 fps under a 60 ms
  auto exposure); retest under bright light to confirm 30 fps.
- **FAIL — real bugs (3):** #6 setCropRegion is a no-op on iOS; #12/#13
  background/interruption **crash the engine** (off-map SessionState FSM
  transitions, `CameraEngine.swift:1562`).
- **Deferred (2):** #17 concurrent open (UI disables open button); #18 hot
  restart (couldn't drive `flutter run` stdin).

**Engine bugs surfaced (CameraKit / eva-swift-stitch — fix in producer repo):**
1. **HIGH — background-lifecycle FSM crash cluster.** `interrupted → recovering`
   and `recovering → streaming` are off-map and `assertionFailure` in debug. Any
   backgrounding / call / camera-contention crashes. Needs FSM fix.
2. **iOS `cropOutputSize` no-op** (works on Android).
3. **First-open `naturalStreamTextureId=0`** — raw lane black on first open,
   allocates after a close→open cycle (ordering bug, low severity).
4. **Manual ISO/exposure usage gap** — independent calls don't pin; engine
   should fold the current value of the other field when only one manual value is
   passed (`setExposureModeCustom(duration:iso:)`), or document the
   must-set-together constraint.

**Cluster D (loaded-mode regression):** NOT RUN — superseded in priority by the
engine crash findings; rerun once #1 is fixed.

**Cluster F:** deferred — trigger (D `signal:pull < 0.9`) not measured.

**Phase 3 is NOT "DONE":** the iOS implementation is functionally broad (most
host methods verified on device) but the background-lifecycle crash (engine bug
#1) is a shipping blocker. G2 push awaits user approval; G3 "Phase 3 complete"
must wait on the engine FSM fix + Cluster D.
