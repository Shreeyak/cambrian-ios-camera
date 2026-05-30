# Progress Report

Single source of truth for where the CamPlugin port stands. **Append to the log; don't rewrite history.** Update the status block as state changes.

## Current status

- **Active phase:** pre-Phase 1a (skeleton app only; `CamPlugin/` does not exist)
- **Build targets green:** iOS Simulator (iPad), Mac "Designed for iPad" (verified launching via Xcode GUI)
- **Physical device:** not currently connected
- **Swift language mode:** 6.0 on all targets
- **Open items:** 1 delegated, 0 broken — see log

## Log

Tag legend: `[impl]` work landed · `[broken]` known broken, needs fix · `[delegated]` deferred to a later phase or owner · `[note]` context worth remembering.

- **2026-04-16** `[note]` Progress report created. No `CamPlugin/` implementation work has started — Phase 1a file tree and acceptance criteria live in `docs/design/05-implementation-phases.md`.
- **2026-04-16** `[impl]` Enabled `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES` on the `eva-swift-stitch` app target (Debug + Release). Unblocks the Mac-as-dev-target workflow so camera code paths can run against the Mac's built-in camera without a physical iPad. Setting verified via `xcodebuild -showdestinations` (lists `My Mac (Designed for iPad)`). End-to-end launch verified by running from Xcode GUI against that destination — app launched cleanly; only noise in the console was stock launchservices / Gatekeeper translocation logs (`LSPrefs: ... proceeding on the assumption it is not translocated`, `ViewBridge ... benign unless unexpected`) which are cosmetic and appear on every macOS app launch.
- **2026-04-16** `[delegated]` Mac "Designed for iPad" path cannot currently be driven by XcodeBuildMCP. The `macos` workflow's `build_run_macos` tool emits `-destination 'platform=macOS,arch=arm64'` without a `variant=Designed for iPad` clause and exposes no knob to override it; xcodebuild then fails because the target's `SUPPORTED_PLATFORMS` is `iphoneos iphonesimulator` only. Workaround: run from the Xcode GUI, or shell out to `xcodebuild -destination 'platform=macOS,arch=arm64,variant=Designed for iPad'` directly. Simulator and device workflows via MCP are unaffected. Revisit if XcodeBuildMCP adds a DFIP-aware path tool, or if we decide to drive Mac builds via the Xcode MCP's `BuildProject` after setting the run destination through the Xcode UI first.
- **2026-04-16** `[impl]` Flipped `SWIFT_VERSION` from 5.0 to 6.0 on all six build configs (app Debug/Release, tests Debug/Release, UI tests Debug/Release). Verified via Xcode MCP `BuildProject` — clean build in 6.5s. Xcode issue navigator shows 0 warnings, 0 errors at `warning`-or-higher severity. The skeleton app (`ContentView.swift`, `eva_swift_stitchApp.swift`) needed no source changes to satisfy Swift 6 language mode because it was already MainActor-isolated by default and had no cross-actor references. The concurrency invariants in `docs/design/02-concurrency.md` now hold at compile time, not just by convention.
