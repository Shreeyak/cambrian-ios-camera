# Tasks

Build/test via XcodeBuildMCP `*_device` (fallback `scripts/build-summary.sh` /
`scripts/test-summary.sh`); device-only, never simulators. Independent of the
frame-delivery changes.

## 1. Resolution validation

- [x] 1.1 Validate **and apply** the requested `captureResolution` at `open()` and validate at `setResolution(size:)`. Discovery: `captureResolution` was entirely **unwired** at open (`configure()` ignored it and picked the largest 4:3/30fps format). Wired it into `CameraSession.configure(requestedSize:)` via **exact-dims FullRange selection** — the same list `SessionCapabilities.supportedSizes`/`reconfigureSize` use, so validate and select draw from one set (the advisor's hidden-bug check). Unsupported → `EngineError.settingsConflict` naming request + supported set. `setResolution` already applied via `reconfigureSize`; added the richer `settingsConflict` validation (shared `CameraEngine.validateRequestedResolution(_:supportedSizes:)`). `nil` keeps default.
- [x] 1.2 **Test-passed:** `validateRequestedResolution` accepts `nil` + supported, rejects unsupported (unit); `openRejectsUnsupportedResolution` (device) confirms `open()` throws `settingsConflict` through `configure()` on real hardware. **Verified by construction + production open:** the *apply-a-supported-size* path — `configure()` selects the exact-dims `pick`, sets `activeFormat = pick`, returns it as `captureSize` → `activeCaptureResolution`; `build-launch` confirmed production `open: pipeline ready — 4032×3024`. **App-HITL-pending:** a *measured* assertion (`device.activeFormatSize` after open at a non-default size) — it cannot run under `xcodebuild test` here (see Deviations: open() crashes in that launch context), and asserting the echoed `activeCaptureResolution` would be tautological.

## 2. Center-relative crop API

- [x] 2.1 Added `func setCenterCrop(width:height:offsetX:offsetY:) async throws` to `CameraEngineProtocol` + `CameraEngine`. ROI math extracted to a pure internal static `CameraEngine.centerCropRect(...)` (even-down extents capped at resolution, even-nearest center from resolution-ratio offset, derive origin, clamp in-bounds, even-snap) for deterministic unit testing.
- [x] 2.2 Routes the derived `Rect` through `setCropRegion` (reuses `validateCropRegion` + the shared `rebuildPipelineForCrop` helper).
- [x] 2.3 Tests (`CameraCropConfigTests`, 12/12 on iPad): centered → centered even rect; worked example (100×100, 0.1/0.2) clamps to (0,0); 1440² in 1920×1440 offsetX 0.1 → origin 432; out-of-bounds offset clamps inside; odd/oversized dims normalize to even ≤ resolution.

## 3. Enable/disable + remembered default

- [x] 3.1 Added engine state `cropEnabled: Bool` (default false) + `configuredCrop: Rect?`; full-frame when disabled.
- [x] 3.2 Added `func setCropEnabled(_:) async throws`: enable applies `configuredCrop` or a centered `Constants.cropDefault*` clamped to the active resolution (`centeredDefaultCrop(in:)`); disable rebuilds full-frame via the shared `rebuildPipelineForCrop`.
- [x] 3.3 `setCropRegion`/`setCenterCrop` set `configuredCrop` and imply `cropEnabled = true`.
- [x] 3.4 Added `OpenConfiguration.cropEnabled: Bool = false`; `true` + `cropRegion == nil` → centered default at open (first frame cropped); `cropRegion != nil` → that rect (enabled). `currentCropRegion`/`configuredCrop`/`cropEnabled` set from the resolved open-time crop.
- [x] 3.5 Wired `Constants.cropDefault*` (1440×1440) as the `centeredDefaultCrop` source (no longer vestigial).
- [x] 3.6 **Test-passed (unit):** default-crop math matches the constant on a large sensor + clamps to a smaller resolution; engine entry-point `notOpen` guards. **Verified by construction:** default-full-frame, crop-on-open (`open()` sets `configuredCrop`/`cropEnabled` from the resolved crop; `caps.activeCropRegion` derives from pipeline state), and disable→re-enable (reuses the proven `setCropRegion`/`rebuildPipelineForCrop` path). **App-HITL-pending:** the open-session *delivery* of these (frames actually cropped, geometry restored on a live pipeline) — same `xcodebuild test` open() crash blocks an automated device test.

## 4. Docs + verify

- [x] 4.1 Updated DocC guide `06-controlling-the-camera.md` (Resolution: select-at-open/live + validate-and-apply; Crop: `setCenterCrop` worked example + full-size no-op note, enable/disable, 1440×1440 default, crop-on-open). Regenerated `Documentation/` via `scripts/regen-docs.sh` (drift guard clean).
- [x] 4.2 Build green on iPad (0/0); `CameraCropConfigTests` 12/12, `CameraCropConfigDeviceTests` 1/1, `Stage04Tests` 8/8, `CameraEngineProtocolConformanceTests` 1/1; production `open()` confirmed via `build-launch` (`open: pipeline ready`); `swift-format lint --strict` clean on changed Sources. Independently committable.

## Deviations from artifacts

- **1.1 — validate became validate-AND-apply.** The spec scenario ("configured at that resolution") required apply; the field was unwired. Selection uses exact-dims FullRange matching (consistent with the validation list), not the default 4:3/30fps picker.
- **3.x — `setResolution` clears the remembered crop.** The rebuild is full-frame and a remembered rect may not fit a new (smaller) resolution, so `setResolution` resets `cropEnabled=false`/`configuredCrop=nil` (re-enable uses the default). Design D3 didn't specify the setResolution×crop interaction; documented in guide 06's "Important" note.
- **Testability.** Crop/validation logic extracted to internal static helpers and unit-tested deterministically; apply/delivery paths (camera hardware) are device HITL, matching the existing Stage04 crop-test precedent.
- **Flutter mock.** Added `setCenterCrop`/`setCropEnabled` stubs to `MockCameraEngine` (Flutter RunnerTests) for protocol conformance; Flutter remains red until `flutter-single-preview` (unrelated `naturalTextureId`).
- **Discovered (out of scope, NOT fixed here): `open()` fatal-errors under `xcodebuild test`.** Writing device tests surfaced a pre-existing crash — `Int64(CMTimeGetSeconds(avDevice.activeFormat.maxExposureDuration) * 1e9)` (`CaptureDeviceProviding.swift:254`, via `exposureDurationRangeNs` on every open) fatal-errors when the CMTime is non-finite, which happens in the `xcodebuild test` launch context on this iPad. Production `open()` is unaffected (`build-launch` → `open: pipeline ready — 4032×3024`). This is why the codebase treats open-session behavior as app-HITL and has no real-open unit tests. Unrelated to crop/resolution; worth a separate change (clamp the non-finite CMTime) which would also unblock an `activeFormatSize`-measured device test.
