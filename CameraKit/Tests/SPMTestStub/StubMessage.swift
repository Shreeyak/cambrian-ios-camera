// This file exists to give `swift test` a clear, useful error message.
// The real CameraKit tests live at CameraKit/Tests/CameraKitTests/ and
// are compiled by the Xcode `ios_example_appTests` target (app-hosted on iPad),
// not by SPM (which defaults to the macOS host triple and can't link AVFoundation
// against an iOS-only target).
//
// To run the real tests: see CLAUDE.md §6.

#error("""
    CameraKit tests cannot run via `swift test`. The real test suite exercises \
    iOS-only AVFoundation APIs that don't compile on the macOS host triple. \
    \
    To run the test suite: \
      • `mcp__XcodeBuildMCP__test_device` (preferred; runs on physical iPad) \
      • or `scripts/test-summary.sh` (shell fallback wrapping xcodebuild test) \
    \
    Both target the Xcode-side `ios_example_appTests` target. \
    See CLAUDE.md §6 for the full toolchain.
""")
