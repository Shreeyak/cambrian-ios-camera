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

**If the user instructs you to use XcodeBuildMCP or the xcode MCP and those tools are unavailable**, stop and say so explicitly. Offer to use context7 instead or ask the user to reconnect the MCP. Never silently substitute another tool when a specific one was requested.

## Architecture

This app is the **integration target** for a 6-phase iOS camera library port. The port will live in a `CamPlugin/` module alongside the existing skeleton app. Refer to `docs/design/05-implementation-phases.md` for the plan and `docs/progress-report.md` for current progress.
