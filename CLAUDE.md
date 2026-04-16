# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running & Testing

Three ways to run the app. Pick the highest-preference option that's available right now:

1. **Physical iPad (highest preference when connected).** Required for R-21 (camera-indicator policy) and R-22 (off-main `startRunning`) acceptance criteria. Use whenever a device is plugged in.
2. **MacBook via "Designed for iPad" (preferred for day-to-day dev).** Gives the app access to the Mac's built-in camera, so capture code paths actually exercise hardware — much tighter loop than the device path. Requires `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES` on the app target (already set).
3. **iOS Simulator (iPad).** Fastest, but **no camera hardware**. Good for logic, state machines, unit tests, UI layout. Skip for anything that touches capture — R-21 and R-22 do not fire on the simulator.

**Prefer XcodeBuildMCP** for build/run/test. Call `session_show_defaults` first each session; if project/scheme/destination are set, go straight to `build_run_sim` (or the device/Mac equivalent). Only fall back to raw `xcodebuild` when MCP can't express what you need.

Reference destinations (MCP still preferred):

```bash
# Simulator
-destination 'platform=iOS Simulator,name=iPad (A16)'
# If that sim isn't installed: XcodeBuildMCP list_sims, or `xcrun simctl list devices available`

# Mac ("Designed for iPad")
-destination 'platform=macOS,arch=arm64,variant=Designed for iPad'

# Physical iPad — discover UDID via `xcrun xctrace list devices`
-destination 'platform=iOS,id=<udid>'
```

Raw commands (use MCP instead when possible):

```bash
xcodebuild -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch \
  -destination '<one of the above>' build

xcodebuild test -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch \
  -destination '<one of the above>' \
  -only-testing:eva-swift-stitchTests/ClassName/testMethodName  # single test

swiftlint lint --config .swiftlint.yml          # lint
swiftlint lint --fix --config .swiftlint.yml    # auto-fix
```

The build enforces `SWIFT_STRICT_CONCURRENCY = complete` across all targets — treat concurrency warnings as errors.

## Project Configuration

- Target device: iPad only. Mac ("Designed for iPad" mode) is used for local testing only — no Mac-native code.
- Deployment target: iOS 26.0
- Swift strict concurrency: `complete` (enforced at build time)
- Camera usage description: set in Xcode build settings (`INFOPLIST_KEY_NSCameraUsageDescription`), not in `Info.plist`
- Bundle ID: `com.cambrian.eva-swift-stitch`

## MCP Tools

Prefer MCP tools over raw `xcodebuild` shell calls. Default to **XcodeBuildMCP** for everything:

| Task | Tool |
|------|------|
| Build & run (dev) | XcodeBuildMCP |
| Tests | XcodeBuildMCP |
| Simulator control | XcodeBuildMCP |
| LLDB / UI automation | XcodeBuildMCP |
| Project inspection (schemes, build settings) | XcodeBuildMCP |
| Signing, IPA, TestFlight | Fastlane |

The Xcode official MCP is only needed for actions that require Xcode itself to be running (rare). Fastlane is for the release pipeline only (`match` → `gym` → `pilot`).

## Architecture

This app is the **integration target** for a 6-phase iOS camera library port. The port will live in a `CamPlugin/` module alongside the existing skeleton app. Refer to `docs/design/05-implementation-phases.md` for the plan and `docs/progress-report.md` for current progress.

### Sandwich pattern (from design)

```
SwiftUI views (top)
    ↕
Metal / UIKit renderers (middle)
    ↕
CameraEngine actor — runs off-main (bottom)
```

`CameraEngine` is a Swift actor. All camera session operations run off the main thread. `CameraViewModel` is `@MainActor` and bridges to SwiftUI via `AsyncStream`. `SessionStateMachine` drives lifecycle; `PermissionManager` must be initialised before the session opens.

### Phase structure

Implementation proceeds in 6 discrete phases. **No forward-porting**: Phase 1a has no Metal code, no OpenCV, no still capture. Each phase has an exhaustive file tree in `docs/design/05-implementation-phases.md`; files not listed do not exist yet.

Phase 1a adds a temporary `PreviewLayerWrapper.swift` (`AVCaptureVideoPreviewLayer` scaffold) that is **explicitly removed in Phase 2**.

### Design source of truth

**Design lives at `docs/design/`. It is read-only.** `docs/design` is a symlink into a separate pinned repo (`~/work/cambrian/ios-translation/design`). Read through `docs/design/...` — **do not read or edit the symlink target directly from this repo.** If something in `design/` looks missing, wrong, or contradictory, STOP and report. Fixes happen upstream in the ios-translation pipeline, not here. The pinned commit is tracked in `DESIGN_SOURCE.md` — don't restate it elsewhere.

**Read order before touching `CamPlugin/`** (paths relative to `docs/design/`):

1. `README.md` — orientation & file index
2. `01-architecture.md` — sandwich pattern
3. `02-concurrency.md` — 11 concurrency invariants (actors, `@MainActor`, `AsyncStream`); read before writing any actor code
4. `03-metal-pipeline.md` — Metal compute, zero-copy, frame budget (Phase 2+)
5. `04-opencv-integration.md` — C++ interface & ObjC++ bridge (Phase 3+)
6. `05-implementation-phases.md` §current phase — file tree + acceptance criteria
7. `06-decisions-log.md` — design alternatives with reversibility notes
8. `07-ios-specific-risks.md` — 27 risks; **R-21 and R-22 are P0 for Phase 1a**
9. `09-architecture-diagrams.md` — 20 diagrams

#### When `design/` doesn't answer the question

Escalate in this order. The friction goes up each step — that is intentional.

- **First: `~/work/cambrian/ios-translation/domain/`** — platform-neutral behavioural requirements (what the app must *do*, independent of iOS/Android). This is the right place for questions like "what should happen if the user rotates during capture" or "what's the retry policy on permission denial". It is the same pinned repo as `design/`, just not symlinked into `docs/`.

- **Last resort: `~/work/cambrian/ios-translation/audit/`** — the raw factual audit of the original Android `cambrian_camera` Flutter plugin. It documents Android implementation details: class names, threading models, Camera2 state machines, platform-channel shapes. **Treat it like a hazardous reference.** The design in `docs/design/` has already translated the *intent* of those details into idiomatic Swift (actors, `AsyncStream`, Metal). If you start mirroring what you read in `audit/` you will pollute the Swift port with Android-shaped structures that fight the sandwich architecture.

  Rules for touching `audit/`:
  - Only when you have a **specific, narrow** "why did the original do X" question that neither `design/` nor `domain/` answers.
  - Read the minimum amount to answer that question, then close the file.
  - Never name a Swift type, method, or protocol after something you saw in `audit/`.
  - Never replicate an Android threading model, lifecycle, or state machine — translate intent, don't copy structure.
  - If you find yourself taking notes on Android class hierarchies, stop: you're using it wrong.

- **Android framework questions (not project-specific):** use the `camera2-docs` skill. Don't reach for `audit/` for generic Camera2 API questions.

### Rules

- Deferred findings F-02, F-04, F-06, F-08 are per-phase checklist items; they are not current-phase problems unless you are in the phase they belong to.
- NEEDS INVESTIGATION items (U-10 `videoRotationAngle`, U-11 diopter, U-16 AE FPS range, R-17 EXIF JSON schema, R-20 noise/edge mapping) are documented in `docs/design/07-ios-specific-risks.md` with the phase that resolves them.
