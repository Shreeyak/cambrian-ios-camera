# Flutter Plugin Monorepo Restructure — Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure this repo so CameraKit ships as a top-level Swift package, a Flutter plugin (`cambrian_ios_camera`) lives under `flutter/` (placeholder only in Phase A; built in Phase B), the native dev-harness app is renamed `eva-swift-stitch` → `ios_example_app`, and the GitHub repo is renamed `eva-swift-stitch` → `cambrian-ios-camera`. No code changes to CameraKit; pure restructure.

**Architecture:** Phase A is a physical restructure. `Package.swift` moves from `CameraKit/` to the repo root using SPM `path:` parameters so the source-dir layout is unchanged. The Xcode project, scheme, targets, source-dirs, and bundle ID rename in a single commit so git rename detection holds. `.githooks/pre-push` is deleted because the synthetic-branch hook would force-push broken content after the manifest moves. The `camerakit-only` branch on origin stays frozen as a safety-net snapshot.

**Tech Stack:** Swift 6 / iOS 26, Swift Package Manager (path-based targets), Xcode 16+, `xcodeproj` Ruby gem (for project surgery), XcodeBuildMCP (for builds + tests on physical iPad — no simulators), bash, git, GitHub CLI.

**Reference:** Spec at `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. Read it once before starting; it has the full target architecture and rationale.

---

## File Structure

### Files created in this plan

| Path | Responsibility | Lifecycle |
|---|---|---|
| `Package.swift` (at repo root) | CameraKit SPM manifest. Targets `CameraKit`, `CameraKitInterop`, `CameraKitCxx` use `path:` pointing into `CameraKit/Sources/X`. One `SPMTestStub` testTarget for `swift test` informational error. | Permanent |
| `CameraKit/Tests/SPMTestStub/StubMessage.swift` | Single file containing `#error("CameraKit tests cannot run via `swift test`...")` — gives developers a clear message instead of compile errors. | Permanent |
| `flutter/README.md` | Placeholder noting "Phase B" — Flutter plugin implementation lands here later. | Permanent |
| `README.md` (at repo root) | Two-personality repo documentation: Swift package consumption + Flutter plugin consumption + example app comparison. | Permanent |
| `scripts/rename-project.rb` | One-time `xcodeproj` Ruby gem helper that mutates `project.pbxproj`. | Deleted after use |
| `scripts/check-legacy-names.sh` | One-time verification helper consolidating grep-sweeps for legacy `eva-swift-stitch`/`eva_swift_stitch` refs. | Deleted after use |
| `docs/superpowers/plans/archive/` | New subdir holding archived Phase 3 plan files. | Permanent |
| `docs/superpowers/specs/archive/` | New subdir holding archived Phase 3 spec. | Permanent |

### Files modified

| Path | What changes |
|---|---|
| `project.pbxproj` (becomes `ios_example_app/ios_example_app.xcodeproj/project.pbxproj`) | Target names, PRODUCT_NAME, PRODUCT_MODULE_NAME, PRODUCT_BUNDLE_IDENTIFIER, INFOPLIST_FILE, SWIFT_OBJC_BRIDGING_HEADER, HEADER_SEARCH_PATHS, FRAMEWORK_SEARCH_PATHS, LIBRARY_SEARCH_PATHS, XCLocalSwiftPackageReference relativePath, source-group container paths. |
| `.swiftlint.yml` | Excluded type-name patterns: `eva_swift_stitch{,App,Tests}` → `ios_example_app{,App,Tests}` (lines 57–62 in current file). |
| `xcshareddata/xcschemes/eva-swift-stitch.xcscheme` | Renamed to `ios_example_app.xcscheme`; BlueprintName, BuildableName, BlueprintIdentifier inside the XML updated. |
| `xcshareddata/xcschemes/CameraKit.xcscheme` | DELETED. |
| `scripts/*.sh` (11 files) | sed-replace `eva-swift-stitch.xcodeproj` → `ios_example_app/ios_example_app.xcodeproj`; `eva-swift-stitchTests` → `ios_example_appTests`; `eva-swift-stitchUITests` → `ios_example_appUITests`; `eva-swift-stitch` → `ios_example_app`; `eva_swift_stitch` → `ios_example_app`. |
| `fastlane/Appfile`, `fastlane/Fastfile` | Manual edit of any `app_identifier` / scheme / xcodeproj refs. |
| `CLAUDE.md` | Major rewrite of §1, §2, §3, §5, §6, §6.0, §8, §10. |
| `CameraKit/state.md` | Add "Restructure 2026-05-20" entry; update `docs/measurements/` path refs. |
| `CameraKit/DECISIONS.md` | Update `docs/measurements/` path refs (if any). |
| Various source-code comments | Update `docs/measurements/` refs in `CameraKit/Sources/`, `CameraKit/Tests/`. |
| App entry-point Swift file | `eva_swift_stitchApp.swift` → `ios_example_appApp.swift`; `@main struct eva_swift_stitchApp` → `@main struct ios_example_appApp`. |
| 5 test files | `@testable import eva_swift_stitch` → `@testable import ios_example_app`. |
| `eva_swift_stitchTests.swift` | File renamed to `ios_example_appTests.swift`; class renamed to match. |

### Files moved (via `git mv` for history preservation)

| From | To |
|---|---|
| `eva-swift-stitch.xcodeproj` | `ios_example_app/ios_example_app.xcodeproj` |
| `eva-swift-stitch/` | `ios_example_app/ios_example_app/` |
| `eva-swift-stitchTests/` | `ios_example_app/Tests/` |
| `eva-swift-stitchUITests/` | `ios_example_app/UITests/` |
| `docs/measurements/` | `docs/docs/measurements/` |
| `docs/superpowers/plans/2026-05-18-phase-3-plan-{1,2,3,4}-*.md` | `docs/superpowers/plans/archive/` |
| `docs/superpowers/specs/2026-05-18-phase-3-design.md` | `docs/superpowers/specs/archive/` |

### Files deleted

| Path | Reason |
|---|---|
| `CameraKit/Package.swift` | Replaced by root `Package.swift`. |
| `.githooks/pre-push` | Would force-push broken content (missing Package.swift) over `camerakit-only` branch after A1. |
| `CameraKit/.build/`, `CameraKit/.swiftpm/` | Stale gitignored leftovers. |

---

## Pre-flight (do this before Task 1)

- [ ] **Pre-flight 1: Read the spec.**

Read `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` (810 lines). It has the full target architecture, the rationale for each step, the Locked Phase A→B decisions, and the Future cleanup gates.

- [ ] **Pre-flight 2: Verify branch.**

Run: `git branch --show-current`
Expected: `flutter-monorepo-restructure`. If different, stop and switch.

- [ ] **Pre-flight 3: Verify working tree is clean.**

Run: `git status --short`
Expected: One modified file `docs/superpowers/plans/2026-05-18-phase-3-plan-3-ios-only-calibration.md` (pre-existing). No other modifications. If other modifications exist, stash them or stop.

- [ ] **Pre-flight 4: Verify XcodeBuildMCP session defaults.**

Run: `mcp__XcodeBuildMCP__session_show_defaults`
Expected: shows current project = `eva-swift-stitch.xcodeproj`, scheme = `eva-swift-stitch`, deviceId = the iPad UDID. If unset, ask the user before continuing.

- [ ] **Pre-flight 5: Verify `xcodeproj` Ruby gem is installed.**

Run: `gem list xcodeproj`
Expected: shows `xcodeproj (X.Y.Z)`. If not installed: `gem install xcodeproj` (may need sudo or `--user-install`).

---

## Task 1: A0 — Safety-net tag on current main

**Files:**
- None (creates a git tag).

- [ ] **Step 1: Verify current main commit.**

Run: `git log -1 --oneline main`
Expected: shows the latest commit on main. Note the SHA for reference.

- [ ] **Step 2: Create annotated tag.**

Run:
```bash
git tag -a pre-restructure-2026-05-20 -m "Pre-restructure snapshot of CameraKit + eva-swift-stitch native app"
```

- [ ] **Step 3: Verify the tag exists locally.**

Run: `git tag -l 'pre-restructure-*'`
Expected: `pre-restructure-2026-05-20`

- [ ] **Step 4: Push the tag to origin.**

Run: `git push origin pre-restructure-2026-05-20`
Expected: `* [new tag]         pre-restructure-2026-05-20 -> pre-restructure-2026-05-20`

- [ ] **Step 5: Verify the tag on remote.**

Run: `git ls-remote origin refs/tags/pre-restructure-2026-05-20`
Expected: returns a SHA matching the local tag.

(No commit — tags are independent of commits.)

---

## Task 2: A1 — Move `Package.swift` to repo root + add `SPMTestStub`

**Files:**
- Create: `Package.swift` (at repo root)
- Create: `CameraKit/Tests/SPMTestStub/StubMessage.swift`
- Delete: `CameraKit/Package.swift`
- Delete: `CameraKit/.build/`, `CameraKit/.swiftpm/` (gitignored anyway, but tidy)

- [ ] **Step 1: Read the current `CameraKit/Package.swift` to capture every detail.**

Run: `cat CameraKit/Package.swift`
Capture: `swift-tools-version`, `platforms`, all `dependencies`, all `targets` with their `path:`/`dependencies:`/`resources:`/`swiftSettings:`/`cxxSettings:`/`publicHeadersPath:` values, `cxxLanguageStandard`. This becomes the source for Step 2.

- [ ] **Step 2: Write the new `Package.swift` at repo root.**

Create `/Users/shrek/work/cambrian/eva-swift-stitch/Package.swift` with this content (preserves every setting from the inner manifest; adds explicit `path:` parameters; drops the real `.testTarget(name: "CameraKitTests")`; adds `SPMTestStub`):

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
        // TEMPORARY (Phase 1A): exported so the relocated DisplayViewModel
        // can `import CameraKitInterop` for CppCannyStub. Phase 1B removes
        // the OpenCV/Canny consumer from the package and unexports this.
        .library(name: "CameraKitInterop", targets: ["CameraKitInterop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // C++ PixelSink pool + atomics. No OpenCV — Phase 1B (2026-05-15) moved
        // the Canny consumer + the opencv2 xcframework into the eva-swift-stitch
        // app target (now ios_example_app). The package contains the consumer-join
        // seam only.
        .target(
            name: "CameraKitCxx",
            path: "CameraKit/Sources/CameraKitCxx",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
                .headerSearchPath("include"),
            ]
        ),
        // Thin Swift C++ interop boundary — .interoperabilityMode(.Cxx) confined here (ADR-13).
        .target(
            name: "CameraKitInterop",
            dependencies: ["CameraKitCxx"],
            path: "CameraKit/Sources/CameraKitInterop",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "CameraKit",
            dependencies: [
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "CameraKit/Sources/CameraKit",
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Required to import CameraKitInterop (built with C++ interop).
                // No C++ types appear in CameraKit's public API — containment per ADR-13 is met.
                .interoperabilityMode(.Cxx),
            ]
        ),
        // Informational stub. Produces a clear `#error` for anyone who runs
        // `swift test` reflexively. The real test suite lives in
        // CameraKit/Tests/CameraKitTests/ and is compiled by the Xcode
        // ios_example_appTests target (app-hosted on iPad).
        .testTarget(
            name: "SPMTestStub",
            path: "CameraKit/Tests/SPMTestStub"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
```

- [ ] **Step 3: Create the SPMTestStub directory.**

Run: `mkdir -p CameraKit/Tests/SPMTestStub`

- [ ] **Step 4: Create `CameraKit/Tests/SPMTestStub/StubMessage.swift`.**

Write `/Users/shrek/work/cambrian/eva-swift-stitch/CameraKit/Tests/SPMTestStub/StubMessage.swift` with this content:

```swift
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
```

- [ ] **Step 5: Delete `CameraKit/Package.swift`.**

Run: `git rm CameraKit/Package.swift`
Expected: `rm 'CameraKit/Package.swift'`

- [ ] **Step 6: Clean stale gitignored SPM artifacts.**

Run: `rm -rf CameraKit/.build CameraKit/.swiftpm`
(These are gitignored; they don't need git rm.)

- [ ] **Step 7: Verify `swift test` produces the stub error message.**

Run: `cd /Users/shrek/work/cambrian/eva-swift-stitch && swift test 2>&1 | head -40`
Expected: build fails with the `#error` output starting with `CameraKit tests cannot run via 'swift test'`. The exact path to `StubMessage.swift` appears in the error. Does NOT actually run any tests.

If this fails with a different error (e.g., "no such file"), revisit Steps 2–4. Common mistake: forgetting `path:` parameter on any target.

- [ ] **Step 8: Verify the package resolves cleanly otherwise.**

Run: `swift package resolve 2>&1 | tail -5`
Expected: no errors. `swift-atomics` resolved.

- [ ] **Step 9: Do NOT build the Xcode project yet.**

A1's verification stops here. The Xcode project's `XCLocalSwiftPackageReference relativePath = CameraKit` no longer points at a valid manifest (we deleted `CameraKit/Package.swift`). Build verification happens after Task 10 (A2.7's final build).

- [ ] **Step 10: Stage A1 changes.**

Run: `git add Package.swift CameraKit/Tests/SPMTestStub/`
Run: `git status --short`
Expected: shows `A Package.swift`, `A CameraKit/Tests/SPMTestStub/StubMessage.swift`, `D CameraKit/Package.swift`.

- [ ] **Step 11: Commit A1.**

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(restructure): A1 — move Package.swift to repo root; add SPMTestStub

- Create root Package.swift with explicit path: parameters into
  CameraKit/Sources/X. Preserves all settings from CameraKit/Package.swift
  verbatim. Source files do not move.
- Drop real .testTarget. The real test suite runs only via Xcode-side
  ios_example_appTests target (after A2). Add SPMTestStub testTarget with
  a #error message so `swift test` reports a useful path-pointer instead
  of cryptic compile errors.
- Delete CameraKit/Package.swift.

The Xcode project's XCLocalSwiftPackageReference will not resolve until
A2 fixes the relativePath. Build verification deferred to end of A2.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 12: Verify the commit.**

Run: `git log -1 --stat`
Expected: shows 3 files changed (1 added at root, 1 added in SPMTestStub/, 1 deleted from CameraKit/).

---

## Task 3: A2.1 — Pbxproj surgery via `xcodeproj` Ruby gem

**Files:**
- Create: `scripts/rename-project.rb` (one-time, deleted after use)
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (in-place by the Ruby script)

This task is the FIRST step of A2. A2 spans Tasks 3–10 and lands in ONE commit at Task 10. Do not commit between Tasks 3–10.

- [ ] **Step 1: Verify the xcodeproj-gem is available and the project opens.**

Run:
```bash
ruby -e "require 'xcodeproj'; p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj'); puts p.targets.map(&:name)"
```
Expected: prints `eva-swift-stitch`, `eva-swift-stitchTests`, `eva-swift-stitchUITests` (one per line).

If it fails with "no such file", you're in the wrong directory — `cd` to repo root.

- [ ] **Step 2: Inspect current build settings for sanity-check baselines.**

Run:
```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
p.targets.each do |t|
  puts \"== #{t.name} ==\"
  t.build_configurations.each do |c|
    s = c.build_settings
    puts \"  [#{c.name}]\"
    %w[PRODUCT_NAME PRODUCT_MODULE_NAME PRODUCT_BUNDLE_IDENTIFIER INFOPLIST_FILE SWIFT_OBJC_BRIDGING_HEADER].each do |k|
      puts \"    #{k} = #{s[k]}\" if s[k]
    end
  end
end"
```
Expected output includes (among other things):
- `PRODUCT_NAME = $(TARGET_NAME)` or `PRODUCT_NAME = eva-swift-stitch`
- `PRODUCT_BUNDLE_IDENTIFIER = com.cambrian.eva-swift-stitch`
- `INFOPLIST_FILE = eva-swift-stitch/Info.plist`
- `SWIFT_OBJC_BRIDGING_HEADER = eva-swift-stitch/AppCxx/AppCxx-Bridging-Header.h` (or similar path)

Note these exact values — they're the "before" state.

- [ ] **Step 3: Write `scripts/rename-project.rb`.**

Create `/Users/shrek/work/cambrian/eva-swift-stitch/scripts/rename-project.rb` with this content:

```ruby
#!/usr/bin/env ruby
# One-time pbxproj surgery for the Phase A restructure.
# Deletes itself after a successful run (see end of file).
# Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A2.1.

require 'xcodeproj'

project_path = 'eva-swift-stitch.xcodeproj'
p = Xcodeproj::Project.open(project_path)

# --- 1. Rename targets ---
p.targets.each do |t|
  case t.name
  when 'eva-swift-stitch'         then t.name = 'ios_example_app'
  when 'eva-swift-stitchTests'    then t.name = 'ios_example_appTests'
  when 'eva-swift-stitchUITests'  then t.name = 'ios_example_appUITests'
  end
end

# --- 2. Build settings — every configuration of every target ---
p.targets.each do |t|
  t.build_configurations.each do |c|
    s = c.build_settings

    # Identity
    s['PRODUCT_NAME']         = t.name
    s['PRODUCT_MODULE_NAME']  = t.name   # critical — affects @testable import

    # Bundle ID — only on the app target (test targets don't have it)
    if s['PRODUCT_BUNDLE_IDENTIFIER']
      s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.cambrian.ios-example-app'
    end

    # File-plist reference — was: "eva-swift-stitch/Info.plist"
    # After A2.2 git mv: "ios_example_app/ios_example_app/Info.plist"
    if s['INFOPLIST_FILE']
      s['INFOPLIST_FILE'] = s['INFOPLIST_FILE'].sub(/eva-swift-stitch/, 'ios_example_app/ios_example_app')
    end

    # INFOPLIST_KEY_* values are usage strings (no path interpolation) — content
    # unchanged. But the keys must survive (memory: project_xcode_infoplist_key_quirk).
    # Verification of survival happens in A7.8.

    # Bridging header path
    if s['SWIFT_OBJC_BRIDGING_HEADER']
      s['SWIFT_OBJC_BRIDGING_HEADER'] = s['SWIFT_OBJC_BRIDGING_HEADER'].sub(
        %r{^eva-swift-stitch/},
        'ios_example_app/ios_example_app/'
      )
    end

    # Header / framework / library search paths
    %w[HEADER_SEARCH_PATHS FRAMEWORK_SEARCH_PATHS LIBRARY_SEARCH_PATHS].each do |key|
      v = s[key]
      next unless v
      arr = v.is_a?(Array) ? v : [v]
      s[key] = arr.map do |path|
        path.sub(%r{(\$\(SRCROOT\)/)?eva-swift-stitch/}, '\1ios_example_app/ios_example_app/')
      end
    end
  end
end

# --- 3. XCLocalSwiftPackageReference relativePath ---
# Pre-move: "CameraKit"   (project at repo root → /repo/CameraKit/)
# Post-move: ".."         (project at /repo/ios_example_app/ → /repo/)
p.root_object.package_references.each do |ref|
  if ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
     ref.relative_path == 'CameraKit'
    ref.relative_path = '..'
  end
end

# --- 4. File-group paths ---
# Source-group containers named after the old project. Walk main_group and fix.
def rename_group_paths(group)
  return unless group.respond_to?(:children)
  group.children.each do |child|
    if child.respond_to?(:path) && child.path
      child.path = child.path.sub(%r{^eva-swift-stitch(/|$)}, 'ios_example_app/ios_example_app\1')
                              .sub(%r{^eva-swift-stitchTests(/|$)}, 'ios_example_app/Tests\1')
                              .sub(%r{^eva-swift-stitchUITests(/|$)}, 'ios_example_app/UITests\1')
    end
    rename_group_paths(child) if child.respond_to?(:children)
  end
end
rename_group_paths(p.main_group)

# --- 5. Save ---
p.save

puts "Pbxproj surgery complete. Inspect with:"
puts "  ruby -e \"require 'xcodeproj'; p = Xcodeproj::Project.open('#{project_path}'); puts p.targets.map(&:name)\""
```

- [ ] **Step 4: Make the script executable.**

Run: `chmod +x scripts/rename-project.rb`

- [ ] **Step 5: Run the script.**

Run: `ruby scripts/rename-project.rb`
Expected: prints "Pbxproj surgery complete." with the inspect-command suggestion.

If it errors with "no method `path=`" on some group child, the project structure has groups xcodeproj-gem doesn't expect. Investigate the specific group; may need to extend the recursion or skip that group.

- [ ] **Step 6: Sanity-check the renamed targets.**

Run:
```bash
ruby -e "require 'xcodeproj'; p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj'); puts p.targets.map(&:name)"
```
Expected: `ios_example_app`, `ios_example_appTests`, `ios_example_appUITests`.

- [ ] **Step 7: Sanity-check the build settings changed.**

Run:
```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
p.targets.each do |t|
  c = t.build_configurations.first
  s = c.build_settings
  puts \"#{t.name} (#{c.name}): PRODUCT_BUNDLE_IDENTIFIER=#{s['PRODUCT_BUNDLE_IDENTIFIER']}, INFOPLIST_FILE=#{s['INFOPLIST_FILE']}, SWIFT_OBJC_BRIDGING_HEADER=#{s['SWIFT_OBJC_BRIDGING_HEADER']}\"
end"
```
Expected:
- `ios_example_app (Debug): PRODUCT_BUNDLE_IDENTIFIER=com.cambrian.ios-example-app, INFOPLIST_FILE=ios_example_app/ios_example_app/Info.plist, SWIFT_OBJC_BRIDGING_HEADER=ios_example_app/ios_example_app/AppCxx/AppCxx-Bridging-Header.h`
- Test target rows show the new test target names; their bundle IDs are nil (correct — test bundles don't have bundle IDs of their own).

- [ ] **Step 8: Sanity-check the SPM reference updated.**

Run:
```bash
ruby -e "require 'xcodeproj'; p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj'); p.root_object.package_references.each {|r| puts \"#{r.class.name}: #{r.respond_to?(:relative_path) ? r.relative_path : r.repositoryURL}\"}"
```
Expected: at least one line `XCLocalSwiftPackageReference: ..` (the dots are correct — it'll resolve to `/repo/` once the xcodeproj is moved into `ios_example_app/`).

- [ ] **Step 9: Do NOT commit yet. Move to Task 4.**

A2.1's mutation is in the working tree but unstaged. A2.1 through A2.8 all land in one commit at Task 10 so git rename detection works across the bulk pbxproj diff.

---

## Task 4: A2.2 — Filesystem moves (single-commit prep)

**Files (moved via `git mv`):**
- `eva-swift-stitch.xcodeproj` → `ios_example_app/ios_example_app.xcodeproj`
- `eva-swift-stitch/` → `ios_example_app/ios_example_app/`
- `eva-swift-stitchTests/` → `ios_example_app/Tests/`
- `eva-swift-stitchUITests/` → `ios_example_app/UITests/`

The `AppCxx/` directory (inside `eva-swift-stitch/`) and the `Frameworks/opencv2.xcframework` symlink at the repo root: see Step 6.

- [ ] **Step 1: Create the destination directory.**

Run: `mkdir ios_example_app`
Expected: directory created (or `mkdir: ios_example_app: File exists` if A1 created it — fine).

- [ ] **Step 2: Move the xcodeproj bundle directly to its final location.**

Run: `git mv eva-swift-stitch.xcodeproj ios_example_app/ios_example_app.xcodeproj`
Expected: no output (success). Single git mv in one shot — do NOT do a two-step `git mv` + `mv`.

- [ ] **Step 3: Move the app source directory.**

Run: `git mv eva-swift-stitch ios_example_app/ios_example_app`
Expected: no output. This moves everything inside `eva-swift-stitch/` (including `AppCxx/`) to `ios_example_app/ios_example_app/`.

- [ ] **Step 4: Move the unit-test directory.**

Run: `git mv eva-swift-stitchTests ios_example_app/Tests`
Expected: no output.

- [ ] **Step 5: Move the UI-test directory.**

Run: `git mv eva-swift-stitchUITests ios_example_app/UITests`
Expected: no output.

- [ ] **Step 6: Confirm `AppCxx/` came along with the app source.**

Run: `ls ios_example_app/ios_example_app/AppCxx/`
Expected: `AppCxx-Bridging-Header.h`, `CannyConsumer.cpp`, `CounterConsumer.cpp`, `CppCannyStub.swift`, `include/`. If empty, the previous step failed silently — investigate before continuing.

- [ ] **Step 7: Confirm the `Frameworks/opencv2.xcframework` symlink at repo root is untouched.**

Run: `ls -la Frameworks/`
Expected: `opencv2.xcframework -> /Users/shrek/software/opencv2.xcframework`. The symlink stays at the repo root because the pbxproj's `FRAMEWORK_SEARCH_PATHS` was updated to `ios_example_app/ios_example_app/Frameworks` — wait, actually check this. Run:

```bash
ruby -e "require 'xcodeproj'; p = Xcodeproj::Project.open('ios_example_app/ios_example_app.xcodeproj'); t = p.targets.find{|t| t.name == 'ios_example_app'}; c = t.build_configurations.first; puts c.build_settings['FRAMEWORK_SEARCH_PATHS']"
```

If `FRAMEWORK_SEARCH_PATHS` references `$(SRCROOT)/Frameworks` (repo-root relative), the symlink belongs at repo root and we're done. If it references `$(SRCROOT)/ios_example_app/ios_example_app/Frameworks`, we need to move the symlink inside. Report what you find.

Most likely outcome: `$(SRCROOT)` here is the project-source-root (the directory containing the .xcodeproj) — so `$(SRCROOT)/Frameworks` becomes `ios_example_app/Frameworks` after the move. In that case: `mkdir -p ios_example_app/Frameworks && git mv Frameworks/opencv2.xcframework ios_example_app/Frameworks/opencv2.xcframework && rmdir Frameworks`.

If unsure, don't move the symlink — the build verification at end of A2 will surface the truth.

- [ ] **Step 8: Verify working-tree state.**

Run: `git status --short`
Expected: many `R` (rename) entries showing the four moves, plus an `M` for `project.pbxproj` (from Task 3's surgery). The `R` lines should look like `R  eva-swift-stitch/... -> ios_example_app/ios_example_app/...` etc.

- [ ] **Step 9: Do NOT commit. Move to Task 5.**

---

## Task 5: A2.3 — Swift source-level renames

**Files modified (all under `ios_example_app/` after Task 4):**
- `ios_example_app/ios_example_app/eva_swift_stitchApp.swift` → renamed file + struct rename inside
- 5 test files: `@testable import eva_swift_stitch` → `@testable import ios_example_app`
- `ios_example_app/Tests/eva_swift_stitchTests.swift` → renamed file + class rename inside
- `.swiftlint.yml` — excluded type-name patterns updated

- [ ] **Step 1: Find the app entry-point file.**

Run: `ls ios_example_app/ios_example_app/eva_swift_stitchApp.swift`
Expected: file exists.

- [ ] **Step 2: Rename the app entry-point file.**

Run:
```bash
git mv ios_example_app/ios_example_app/eva_swift_stitchApp.swift \
       ios_example_app/ios_example_app/ios_example_appApp.swift
```

- [ ] **Step 3: Rename the `@main struct` inside the renamed file.**

Edit `ios_example_app/ios_example_app/ios_example_appApp.swift`. Find the line containing `@main struct eva_swift_stitchApp` and replace `eva_swift_stitchApp` with `ios_example_appApp`. Save.

Verify:
```bash
grep -n 'struct.*App' ios_example_app/ios_example_app/ios_example_appApp.swift
```
Expected: shows `struct ios_example_appApp:` (or similar).

- [ ] **Step 4: List the `@testable import` sites.**

Run:
```bash
grep -rln '@testable import eva_swift_stitch' ios_example_app/
```
Expected: list of 5 (give or take) Swift files under `ios_example_app/Tests/` and possibly `ios_example_app/UITests/`. Note the count.

- [ ] **Step 5: Mass-replace `@testable import`.**

Run (BSD sed — macOS):
```bash
find ios_example_app -name '*.swift' -exec sed -i '' \
  's/@testable import eva_swift_stitch/@testable import ios_example_app/g' {} +
```

- [ ] **Step 6: Verify zero survivors.**

Run: `grep -rln '@testable import eva_swift_stitch' ios_example_app/`
Expected: no output (zero matches).

- [ ] **Step 7: Find and rename the XCTestCase file.**

Run: `ls ios_example_app/Tests/eva_swift_stitchTests.swift 2>/dev/null`
If it exists:
```bash
git mv ios_example_app/Tests/eva_swift_stitchTests.swift \
       ios_example_app/Tests/ios_example_appTests.swift
```

Edit `ios_example_app/Tests/ios_example_appTests.swift` and replace any `class eva_swift_stitchTests` with `class ios_example_appTests`. Save.

If the file does not exist, skip this step — the test class may have a different name. List `ios_example_app/Tests/*.swift` to see.

- [ ] **Step 8: Sweep `.swiftlint.yml` for excluded type-name patterns.**

Run: `grep -n 'eva_swift_stitch\|eva-swift-stitch' .swiftlint.yml`
Expected: matches around lines 57–62 (the `type_name.excluded` entries, possibly `included`/`excluded` paths).

Edit `.swiftlint.yml`. Replace every `eva_swift_stitch` → `ios_example_app`, `eva-swift-stitch` → `ios_example_app`. Specifically the excluded type-name patterns like `eva_swift_stitchApp`, `eva_swift_stitchTests`, `eva_swift_stitchUITests` should become `ios_example_appApp`, `ios_example_appTests`, `ios_example_appUITests`.

- [ ] **Step 9: Verify no legacy names remain in the renamed paths.**

Run:
```bash
grep -rln 'eva_swift_stitch\|eva-swift-stitch' ios_example_app/ .swiftlint.yml
```
Expected: no output. If any matches appear, investigate each one — they're bugs.

- [ ] **Step 10: Do NOT commit. Move to Task 6.**

---

## Task 6: A2.4 — Bundle identifier + Apple Developer console (user step)

**Files:** none directly (bundle ID change was already applied by Task 3's Ruby script; this task is about the Apple Developer side and fastlane refs).

- [ ] **Step 1: Re-verify the bundle ID change took effect.**

Run:
```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('ios_example_app/ios_example_app.xcodeproj')
t = p.targets.find{|t| t.name == 'ios_example_app'}
t.build_configurations.each do |c|
  puts \"#{c.name}: #{c.build_settings['PRODUCT_BUNDLE_IDENTIFIER']}\"
end"
```
Expected: `Debug: com.cambrian.ios-example-app` and `Release: com.cambrian.ios-example-app` (or whatever configurations exist).

- [ ] **Step 2: Inform the user about the Apple Developer console step (BLOCKING).**

Stop and tell the user:
> The bundle ID changed from `com.cambrian.eva-swift-stitch` to `com.cambrian.ios-example-app`. On first build, this needs Apple Developer console registration:
>
> - **Automatic signing (recommended):** Open the renamed project in Xcode at `ios_example_app/ios_example_app.xcodeproj`. Sign in with your Apple ID (`ss.shrek7@gmail.com`). Xcode will auto-register the new bundle ID and regenerate the provisioning profile on first build.
> - **Manual signing or fastlane match:** Register the new bundle ID at developer.apple.com → Identifiers, then run `fastlane match` to generate a new profile.
>
> You can do this now (open Xcode, let it provision) or skip — Xcode will prompt at Task 11's build step if it hasn't been done. Stranded `com.cambrian.eva-swift-stitch` profile can be left alone.

Wait for user confirmation before continuing.

- [ ] **Step 3: Sweep fastlane for any legacy refs.**

Run: `grep -rln 'eva-swift-stitch\|eva_swift_stitch' fastlane/`
Expected: probably no matches (Appfile + Fastfile are mostly templates with no live config). If matches found, edit each file manually: replace `app_identifier "com.cambrian.eva-swift-stitch"` → `app_identifier "com.cambrian.ios-example-app"`, replace scheme/xcodeproj refs similarly.

- [ ] **Step 4: Do NOT commit. Move to Task 7.**

---

## Task 7: A2.5 — Schemes (delete `CameraKit.xcscheme`, rename the other)

**Files:**
- Delete: `ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/CameraKit.xcscheme`
- Rename: `ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/eva-swift-stitch.xcscheme` → `ios_example_app.xcscheme`
- Modify: the renamed scheme XML inside

- [ ] **Step 1: List the current schemes.**

Run: `ls ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/`
Expected: `CameraKit.xcscheme`, `eva-swift-stitch.xcscheme`.

- [ ] **Step 2: Delete `CameraKit.xcscheme`.**

The scheme references `ReferencedContainer = "container:CameraKit"` (the package directory) and `BlueprintIdentifier = "CameraKitTests"`. After A1, the inner `CameraKit/Package.swift` is gone and the real `CameraKitTests` test-target no longer exists. The scheme is dead.

Run:
```bash
git rm ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/CameraKit.xcscheme
```

- [ ] **Step 3: Rename the app scheme.**

Run:
```bash
git mv ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/eva-swift-stitch.xcscheme \
       ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme
```

- [ ] **Step 4: Update the scheme XML contents.**

Open `ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme`. Find every `BuildableName`, `BlueprintName`, `BlueprintIdentifier`, and `ReferencedContainer` attribute. Replace:
- `eva-swift-stitch.app` → `ios_example_app.app`
- `eva-swift-stitch` (as standalone value) → `ios_example_app`
- `eva-swift-stitchTests.xctest` → `ios_example_appTests.xctest`
- `eva-swift-stitchTests` → `ios_example_appTests`
- `eva-swift-stitchUITests.xctest` → `ios_example_appUITests.xctest`
- `eva-swift-stitchUITests` → `ios_example_appUITests`
- `container:eva-swift-stitch.xcodeproj` → `container:ios_example_app.xcodeproj` (if it appears)

Use sed for bulk replacement (BSD sed):
```bash
sed -i '' \
  -e 's/eva-swift-stitch\.app/ios_example_app.app/g' \
  -e 's/eva-swift-stitchTests\.xctest/ios_example_appTests.xctest/g' \
  -e 's/eva-swift-stitchUITests\.xctest/ios_example_appUITests.xctest/g' \
  -e 's/eva-swift-stitchTests/ios_example_appTests/g' \
  -e 's/eva-swift-stitchUITests/ios_example_appUITests/g' \
  -e 's/eva-swift-stitch/ios_example_app/g' \
  ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme
```

- [ ] **Step 5: Verify zero legacy refs in the scheme XML.**

Run:
```bash
grep 'eva-swift-stitch\|eva_swift_stitch' \
  ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme
```
Expected: no output.

- [ ] **Step 6: Verify the scheme is valid XML.**

Run:
```bash
xmllint --noout ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme && echo "VALID"
```
Expected: `VALID`. If `xmllint` errors, the sed mangled an attribute — re-inspect and hand-edit.

- [ ] **Step 7: Do NOT commit. Move to Task 8.**

---

## Task 8: A2.6 — Exhaustive scripts/ sweep

**Files modified:** every file in `scripts/` containing `eva-swift-stitch` or `eva_swift_stitch`.

- [ ] **Step 1: Inventory the scripts directory.**

Run: `ls scripts/`
Expected: 11 files (`build-summary.sh`, `device-log-live.sh`, `dump-interface.sh`, `lsp-symbol.sh`, `regen-contracts.sh`, `regen-contracts-partial.sh`, `scaffold-inventory.sh`, `stage-preflight.sh`, `sync-test-target.sh`, `test-summary.sh`, `watch-contracts.sh`) plus the temporary `rename-project.rb` from Task 3.

- [ ] **Step 2: Find legacy-name hits in scripts.**

Run: `grep -rln 'eva-swift-stitch\|eva_swift_stitch' scripts/`
Expected: list of script files with legacy refs. Note which.

- [ ] **Step 3: Mass-replace in scripts (BSD sed — macOS).**

Run:
```bash
find scripts -type f \( -name '*.sh' -o -name '*.rb' \) -exec sed -i '' \
  -e 's|eva-swift-stitch\.xcodeproj|ios_example_app/ios_example_app.xcodeproj|g' \
  -e 's|eva-swift-stitchTests|ios_example_appTests|g' \
  -e 's|eva-swift-stitchUITests|ios_example_appUITests|g' \
  -e 's|eva-swift-stitch|ios_example_app|g' \
  -e 's|eva_swift_stitch|ios_example_app|g' \
  {} +
```

NOTE: order matters. `eva-swift-stitchTests` is replaced first (most specific) before the generic `eva-swift-stitch` substitution would mangle it.

NOTE: this WILL replace strings inside `scripts/rename-project.rb` (the helper itself opens `eva-swift-stitch.xcodeproj`). That's fine — the script's job is done; it gets deleted in a later step.

- [ ] **Step 4: Verify zero survivors.**

Run: `grep -rln 'eva-swift-stitch\|eva_swift_stitch' scripts/`
Expected: no output. If matches remain, inspect each — they may be intentional historical references in comments (rare).

- [ ] **Step 5: Verify `scripts/build-summary.sh` looks right.**

Run: `grep -n 'ios_example_app' scripts/build-summary.sh | head`
Expected: references to `ios_example_app/ios_example_app.xcodeproj` and scheme `ios_example_app`.

- [ ] **Step 6: Verify `scripts/test-summary.sh` looks right.**

Run: `grep -n 'ios_example_app\|scheme' scripts/test-summary.sh | head`
Expected: scheme defaults to `ios_example_app`, references the renamed test targets.

- [ ] **Step 7: Verify `scripts/stage-preflight.sh` looks right.**

Run: `grep -n 'ios_example_app\|scheme' scripts/stage-preflight.sh | head`
Expected: invocations of `build-summary.sh` or scheme refs use `ios_example_app`.

- [ ] **Step 8: Verify `scripts/sync-test-target.sh` looks right.**

Run: `grep -n 'ios_example_app\|Tests' scripts/sync-test-target.sh | head`
Expected: refs to `ios_example_appTests` target, project path `ios_example_app/ios_example_app.xcodeproj`.

- [ ] **Step 9: Note per-script context:**
- `device-log-live.sh`: hardcoded iPad UDID is unchanged. The log file `Documents/camerakit.log` is package-named (CameraKit module — `CameraKitLog.enableFileLogging()`), not app-named — unchanged.
- `regen-contracts.sh`: paths to `CameraKit/CONTRACTS.md` and `CameraKit/Sources/CameraKit/**/*.swift` were unchanged (sources didn't move).

- [ ] **Step 10: Do NOT commit. Move to Task 9.**

---

## Task 9: A2.7 — Regenerate `buildServer.json` at repo root

**Files:**
- Create/modify: `buildServer.json` at repo root (gitignored; per-developer)

- [ ] **Step 1: Verify the old buildServer.json (if any) and its location.**

Run: `cat buildServer.json 2>/dev/null | head`
If file exists, it references the old project/scheme. We will overwrite it.

- [ ] **Step 2: Run `xcode-build-server config` from the REPO ROOT.**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
xcode-build-server config \
    -project ios_example_app/ios_example_app.xcodeproj \
    -scheme  ios_example_app
```

Expected: silent success. Writes `buildServer.json` in the current directory (repo root).

If the command errors with "xcode-build-server: command not found": `brew install xcode-build-server`.

If the command errors with "project not found" or similar: the relative path is wrong. The script needs to be invoked from repo root with the path including the `ios_example_app/` subdirectory.

- [ ] **Step 3: Verify the generated file.**

Run: `cat buildServer.json | python3 -m json.tool | head -10`
Expected: valid JSON with keys like `name`, `workspace`, `scheme`, `build_root`. The `workspace` value should contain `ios_example_app/ios_example_app.xcodeproj/project.xcworkspace`. The `scheme` value should be `ios_example_app`.

- [ ] **Step 4: Confirm `buildServer.json` is at repo root, NOT inside the subdir.**

Run: `ls buildServer.json && ls ios_example_app/buildServer.json 2>/dev/null`
Expected: first ls succeeds; second ls fails with "No such file". Sourcekit-lsp walks up from source files in `CameraKit/Sources/` — the file MUST be at repo root to be reachable from there.

- [ ] **Step 5: Confirm `buildServer.json` is gitignored.**

Run: `git check-ignore buildServer.json && echo "GITIGNORED"`
Expected: `buildServer.json` printed by check-ignore + `GITIGNORED` after. (It's per-developer; not committed.)

If it's NOT gitignored, that's a problem — it has host-machine DerivedData paths and would create merge conflicts. Add to `.gitignore`.

- [ ] **Step 6: Do NOT commit. Move to Task 10.**

---

## Task 10: A2.8 — Final A2 verification + single commit

**Files:** none added; this is the verification + commit step for everything in Tasks 3–9.

- [ ] **Step 1: Sweep for legacy names across the whole repo.**

Run:
```bash
grep -rln 'eva-swift-stitch\|eva_swift_stitch' \
  --exclude-dir=.git \
  --exclude-dir=implementation \
  --exclude='state.md' \
  --exclude='DECISIONS.md' \
  --exclude='2026-05-{14,18}-*.md' \
  --exclude='CLAUDE.md' \
  .
```

Expected: legitimate survivors only:
- `scripts/rename-project.rb` (gets deleted at end of A2)
- `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` (the spec itself documents the rename — references are intentional)
- Possibly `README.md` if it exists already (won't be created until Task 13)
- `Package.resolved` (if it has references — unlikely)

Anything in `ios_example_app/`, `scripts/*.sh`, `.swiftlint.yml`, scheme XML files, or fastlane is a bug — investigate and fix.

- [ ] **Step 2: Delete the one-time `rename-project.rb` helper.**

Run: `git rm scripts/rename-project.rb`
(The script's job is done; not part of long-term `scripts/` inventory.)

- [ ] **Step 3: Stage everything from Tasks 3–10.**

Run: `git add -A`

- [ ] **Step 4: Inspect what's about to be committed.**

Run: `git status --short`
Expected: many `R` (rename) lines for the four directory moves, plus `M` for `project.pbxproj`, `M` for `.swiftlint.yml`, `M` for several `scripts/*.sh`, `D` for `scripts/rename-project.rb`, `D` for `CameraKit.xcscheme`, `R` for the renamed scheme, `R` for the renamed App.swift, `R` for the renamed Tests.swift.

If you see any `??` (untracked) lines except `buildServer.json`, investigate — they should have been added by `git add -A`.

If you see legacy filenames you didn't rename (e.g., a stray `eva_swift_stitch*.swift` you missed), STOP and fix before committing.

- [ ] **Step 5: Check rename detection threshold.**

Run: `git diff --cached --stat | tail -5`
Expected: shows total file change count. If any file shows up as "DELETED" and another as "ADDED" rather than as a rename, git's similarity detection failed for that file. For pbxproj specifically (heavily mutated), this is OK — we'll rely on `--find-renames=30%` for historical traversal.

- [ ] **Step 6: Commit A2.**

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(restructure): A2 — rename eva-swift-stitch → ios_example_app

Eight sub-parts landing in one commit so git rename detection holds
across the heavily-mutated project.pbxproj:

A2.1: pbxproj surgery via xcodeproj Ruby gem — target rename,
      PRODUCT_NAME, PRODUCT_MODULE_NAME, PRODUCT_BUNDLE_IDENTIFIER,
      INFOPLIST_FILE, SWIFT_OBJC_BRIDGING_HEADER, HEADER/FRAMEWORK/
      LIBRARY_SEARCH_PATHS, XCLocalSwiftPackageReference relativePath,
      source-group container paths.
A2.2: filesystem moves — eva-swift-stitch.xcodeproj → ios_example_app/
      ios_example_app.xcodeproj; eva-swift-stitch/ → ios_example_app/
      ios_example_app/ (carrying AppCxx/ along); test dirs renamed.
A2.3: Swift source — @testable import + @main struct + XCTestCase
      class names; .swiftlint.yml exclusion patterns.
A2.4: bundle ID com.cambrian.eva-swift-stitch → com.cambrian.ios-
      example-app; fastlane refs (if any).
A2.5: deleted dead CameraKit.xcscheme (referenced gone-after-A1
      container); renamed app scheme.
A2.6: scripts/ sweep — exhaustive rename across 11 scripts.
A2.7: buildServer.json regenerated at repo root (was at repo root
      with old paths; sourcekit-lsp walks up from source files).
A2.8: one-time rename-project.rb helper deleted.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Verify the commit landed.**

Run: `git log -1 --stat | head -30`
Expected: large commit with many file changes (renames + modifications).

- [ ] **Step 8: Build verification — `ios_example_app` builds cleanly on iPad.**

Update XcodeBuildMCP defaults first:
```
mcp__XcodeBuildMCP__session_set_defaults
  projectPath: /Users/shrek/work/cambrian/eva-swift-stitch/ios_example_app/ios_example_app.xcodeproj
  scheme: ios_example_app
```

Then run:
```
mcp__XcodeBuildMCP__build_run_device
```

Expected: BUILD SUCCEEDED + app launches on the connected iPad. If BUILD FAILED, read the error output carefully:
- "no such file" for any path → A2.1's pbxproj surgery missed a build setting; investigate which path. Could be in `INFOPLIST_FILE`, `SWIFT_OBJC_BRIDGING_HEADER`, or a `HEADER_SEARCH_PATHS` entry not covered by the regex.
- "cannot find module 'eva_swift_stitch'" → A2.3 missed a `@testable import` site, OR `PRODUCT_MODULE_NAME` wasn't updated.
- "provisioning profile" errors → A2.4's user step wasn't completed. Open Xcode, sign in, let it provision.
- Linker errors against OpenCV → A2.2 step 7's framework symlink decision was wrong. Move the symlink to match `FRAMEWORK_SEARCH_PATHS`.

If verification fails, do NOT amend the commit. Investigate, write a fix commit, repeat the build.

---

## Task 11: A3 — Move `docs/measurements/` to `docs/docs/measurements/`

**Files moved:** `docs/measurements/` → `docs/docs/measurements/`
**Files modified:** `CameraKit/state.md`, `CameraKit/DECISIONS.md`, source comments under `CameraKit/Sources/` and `CameraKit/Tests/`, internal docs pointers.

- [ ] **Step 1: Verify current docs/measurements/ location.**

Run: `ls docs/measurements/ | head -5`
Expected: `phase-3-prep/`, `stage-08/`, `stage-09/`, `texture-bridge/`, etc.

- [ ] **Step 2: Move the directory.**

Run: `git mv measurements docs/measurements`
Expected: no output. Verify: `ls docs/docs/measurements/ | head -5`.

- [ ] **Step 3: Find references to the old path in source code.**

Run:
```bash
grep -rln 'docs/measurements/' CameraKit/Sources/ CameraKit/Tests/
```
Expected: zero or a small list. Note files.

- [ ] **Step 4: Update source-code references.**

For each file from Step 3, edit and replace `docs/measurements/` with `docs/docs/measurements/`. Most occurrences will be in doc comments — verify by inspecting the context (don't accidentally rewrite a string literal that means something else).

If only doc comments are affected, mass-replace:
```bash
find CameraKit/Sources CameraKit/Tests -name '*.swift' -exec sed -i '' \
  's|docs/measurements/|docs/docs/measurements/|g' {} +
```

- [ ] **Step 5: Update references in state.md and DECISIONS.md.**

Run:
```bash
grep -n 'docs/measurements/' CameraKit/state.md CameraKit/DECISIONS.md
```
For each match, edit the file and prefix with `docs/`. Or mass-replace:
```bash
sed -i '' 's|docs/measurements/|docs/docs/measurements/|g' CameraKit/state.md CameraKit/DECISIONS.md
```

- [ ] **Step 6: Update references in docs/superpowers/.**

Run:
```bash
grep -rln 'docs/measurements/' docs/superpowers/
```
Don't touch files under `docs/superpowers/specs/archive/` or `docs/superpowers/plans/archive/` (these are historical — leave as-is). For other matches, mass-replace:
```bash
find docs/superpowers/specs docs/superpowers/plans -name '*.md' \
  -not -path '*/archive/*' \
  -exec sed -i '' 's|docs/measurements/|docs/docs/measurements/|g' {} +
```

- [ ] **Step 7: Confirm scripts/ has no docs/measurements/ refs.**

Run: `grep -rn docs/measurements/ scripts/`
Expected: no output. If matches, update each.

- [ ] **Step 8: Note that `implementation/briefs/*.md` are READ-ONLY symlinks.**

Run: `ls -la implementation/`
Expected: symlinks to `/Users/shrek/work/cambrian/ios-translation/...`. Brief refs work against upstream's own root layout — they don't need editing here. Flag this for the state.md update at Task 19 ("upstream briefs reference `docs/measurements/stage-NN/` which resolves against upstream's own layout, not this repo's").

- [ ] **Step 9: Final verification grep.**

Run:
```bash
grep -rn 'docs/measurements/' \
  --exclude-dir=.git \
  --exclude-dir=docs/measurements \
  --exclude-dir=implementation \
  --exclude-dir=docs/superpowers/specs/archive \
  --exclude-dir=docs/superpowers/plans/archive \
  --include='*.swift' --include='*.md' --include='*.sh' --include='*.rb' \
  .
```
Expected: zero hits, or only paths that already say `docs/docs/measurements/`.

- [ ] **Step 10: Stage and commit.**

Run: `git add -A`
Run: `git status --short`
Expected: shows `R` lines for the directory move and `M` lines for the updated files.

Commit:
```bash
git commit -m "$(cat <<'EOF'
chore(restructure): A3 — move docs/measurements/ to docs/docs/measurements/

Exhaustive sweep of path references: CameraKit/state.md, DECISIONS.md,
source-code comments under CameraKit/Sources/ and Tests/, internal docs
pointers under docs/superpowers/.

implementation/briefs/*.md are upstream READ-ONLY symlinks — their
docs/measurements/ refs resolve against upstream's own layout, not affected
by this move.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: A4.1 — Scaffold empty `flutter/` directory

**Files:**
- Create: `flutter/README.md`

- [ ] **Step 1: Create the flutter directory.**

Run: `mkdir flutter`
Expected: directory created (or `File exists` if from prior — fine).

- [ ] **Step 2: Write `flutter/README.md`.**

Create `/Users/shrek/work/cambrian/eva-swift-stitch/flutter/README.md` with this content:

```markdown
# cambrian_ios_camera (Phase B)

Flutter plugin wrapping CameraKit for iOS-only camera access. Phase B implementation
lands here per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md.

For Android camera in Flutter, use cam2fd's cambrian_camera plugin separately.
```

- [ ] **Step 3: Stage and commit.**

Run:
```bash
git add flutter/README.md
git commit -m "$(cat <<'EOF'
chore(restructure): A4.1 — scaffold flutter/ with placeholder README

Phase B (the Flutter plugin implementation) lands here later. Empty
flutter/ + README in Phase A. Per docs/superpowers/specs/
2026-05-20-flutter-plugin-monorepo-design.md A4.1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: A4.2 — Root-level `README.md`

**Files:**
- Create: `README.md` (at repo root)

- [ ] **Step 1: Verify there's no existing README at repo root.**

Run: `ls README.md 2>/dev/null`
Expected: no file. If there IS one, read it first and decide whether to merge or replace.

- [ ] **Step 2: Write `README.md` at repo root.**

Create `/Users/shrek/work/cambrian/eva-swift-stitch/README.md` with this content (preserves the spec's A4.2 README content verbatim; if you find yourself wanting to "improve" it, don't — the spec is the source of truth):

````markdown
# cambrian-ios-camera

iOS camera library, shipped as **both a Swift package and a Flutter plugin** from a single repo.

> **Two-personality repo.** The same source ships under two consumer APIs:
> - Swift apps depend on the `CameraKit` Swift package at the repo root (via SPM).
> - Flutter apps depend on the `cambrian_ios_camera` Flutter plugin under `flutter/` (via pub `git: + path: flutter`).
>
> They share underlying code; you don't pick one. If you write Swift, use SPM. If you write Flutter, use the plugin.
> **No Android support** in this repo — for Android camera in Flutter, use [cam2fd's `cambrian_camera`](https://github.com/.../camera2_flutter_demo) as a separate dependency.

## For Swift apps — consume via SPM

Add to your `Package.swift`:

```swift
let package = Package(
    name: "MyApp",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "CameraKit", package: "cambrian-ios-camera"),
            ]
        ),
    ]
)
```

Or in Xcode: File → Add Package Dependencies → paste `https://github.com/Shreeyak/cambrian-ios-camera.git` → choose a version.

Then in your Swift code:

```swift
import CameraKit
let engine = try await CameraEngine(...)
```

> The package's internal name is `CameraKit` for historical reasons. It will be renamed to `CambrianCamera` in a future pass to avoid collision with [Snap's CameraKit SDK](https://docs.snap.com/camera-kit/) — see `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` §"Future cleanup".

## For Flutter apps — consume via pub `git: + path: flutter`

The Flutter plugin lives under the `flutter/` subdirectory, not at the repo root. Pub supports this via the `path:` parameter inside a `git:` dependency:

```yaml
# In your Flutter app's pubspec.yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter        # ← important: plugin is at flutter/, not the repo root
      ref: v1.0.0          # ← pin to a tag; main is for development
```

Then run `flutter pub get` and import in Dart:

```dart
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

final engine = await CameraEngine.open(...);
```

**For Android camera in the same app:** add `cambrian_camera` (cam2fd's Android-only plugin) as a separate dependency. Both plugins maintain similar API surfaces by convention, so platform-conditional code in Dart is straightforward. Phase B (the plugin implementation itself) is being built now — see `docs/superpowers/specs/`.

## Two example apps in this repo

| Path | What it is | Use it when |
|---|---|---|
| `ios_example_app/` | Native SwiftUI app. Imports `CameraKit` directly via the local SPM package. Demonstrates camera lanes, processing, and Canny edge detection (via the OpenCV consumer in `ios_example_app/ios_example_app/AppCxx/`). The primary dev harness for CameraKit work. | You're developing CameraKit itself, or want a full-featured iOS-native demo. |
| `flutter/example/` | Standard Flutter plugin example. Lean — shows one preview stream (the processed lane, after CameraKit's Metal shader passes). No OpenCV, no C++ consumer in the Flutter side. | You're developing the `cambrian_ios_camera` plugin, or want a minimal Flutter consumer demo. |

Neither CameraKit (the Swift package) nor `cambrian_ios_camera` (the Flutter plugin) link OpenCV. OpenCV is a consumer-side dep — `ios_example_app/` brings it in for the Canny demo; downstream consumers bring their own if they need it.

## Development

See `CLAUDE.md` for project conventions (build/test commands, scaffold discipline, test-on-iPad invariants, the `xcode-build-server` LSP bridge setup, etc.).
````

NOTE: when copying this content into the file, the inner triple-backtick fences (```swift, ```yaml, ```dart) must be literal triple backticks — they're code blocks inside the markdown README. The file itself is plain markdown (no outer fence).

- [ ] **Step 3: Stage and commit.**

Run:
```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(restructure): A4.2 — add root README documenting two-personality repo

Swift + Flutter consumption examples, two-example-apps table, OpenCV
explainer (consumer-side dep, not in package or plugin). Pin the
git: + path: flutter syntax prominently so Flutter consumers don't miss
that the plugin lives in a subdirectory.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A4.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: A5 — Delete `.githooks/pre-push`

**Files:**
- Delete: `.githooks/pre-push`

- [ ] **Step 1: Confirm the hook file exists.**

Run: `ls .githooks/pre-push`
Expected: file exists.

- [ ] **Step 2: Read the file briefly to confirm it's just the synthetic-branch hook.**

Run: `head -10 .githooks/pre-push`
Expected: shebang + comment block about `camerakit-only synthetic branch`. If there's other unrelated logic, STOP — that needs to be preserved.

- [ ] **Step 3: Delete the file.**

Run: `git rm .githooks/pre-push`

- [ ] **Step 4: Verify `.githooks/` directory state.**

Run: `ls -la .githooks/`
Expected: empty directory (or contains only `.gitkeep` or similar sentinel). If other files remain, that's fine — they're separate hooks unaffected by this delete.

- [ ] **Step 5: Do NOT unset `core.hooksPath`.**

That config is per-developer (not in the repo). Leave it pointing at `.githooks/`; if the dir is empty, it's a no-op until future hooks land. Documented in §6.0 of the CLAUDE.md rewrite (Task 18).

- [ ] **Step 6: Verify `camerakit-only` branch on origin is still intact.**

Run: `git ls-remote origin camerakit-only`
Expected: returns a SHA (the pre-restructure snapshot is preserved on the remote).

- [ ] **Step 7: Commit.**

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(restructure): A5 — delete .githooks/pre-push

A1 deleted CameraKit/Package.swift. The pre-push hook's
`git subtree split --prefix=CameraKit` would produce a synthetic branch
with no root Package.swift — an invalid Swift package. Without
deletion, the hook would force-push that broken content over the
currently-valid camerakit-only branch on origin, eliminating the
recoverable state we want to preserve.

The camerakit-only branch on origin is LEFT ALONE; stays frozen at its
current valid pre-restructure state. Merge-gate reminder in the spec:
decide whether to `git push origin --delete camerakit-only` at PR time.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: A5b — Rename GitHub repo (user-driven step)

**Files:** none directly — this is a remote rename + local remote URL update + sweep of literal URL refs.

- [ ] **Step 1: Inform the user (BLOCKING) about the GitHub rename step.**

Stop and tell the user:
> The GitHub repo needs to be renamed from `eva-swift-stitch` to `cambrian-ios-camera`. This is a user-driven step (requires GitHub admin auth).
>
> Two ways:
> - **CLI:** Run `gh repo rename cambrian-ios-camera` from the repo root.
> - **Web UI:** github.com → repo → Settings → General → Repository name → `cambrian-ios-camera` → Rename.
>
> GitHub auto-redirects the old URL (`Shreeyak/eva-swift-stitch`) indefinitely; existing clones/pins do not break.
>
> Please rename now and confirm when done.

Wait for user confirmation.

- [ ] **Step 2: Update the local clone's remote URL.**

Run:
```bash
git remote set-url origin https://github.com/Shreeyak/cambrian-ios-camera.git
```

- [ ] **Step 3: Verify the remote URL.**

Run: `git remote -v`
Expected: both fetch and push lines show `https://github.com/Shreeyak/cambrian-ios-camera.git`.

- [ ] **Step 4: Verify push still works (the auto-redirect handles backward compat).**

Run: `git push origin flutter-monorepo-restructure`
Expected: push succeeds. If it fails with auth issues, the GitHub rename hasn't fully propagated yet — wait 30 seconds and retry.

- [ ] **Step 5: Sweep for literal old-URL strings in committed docs.**

Run:
```bash
grep -rln 'Shreeyak/eva-swift-stitch' \
  --exclude-dir=.git \
  --exclude-dir=implementation \
  --exclude-dir=docs/superpowers/specs/archive \
  --exclude-dir=docs/superpowers/plans/archive \
  .
```
Expected: maybe `CLAUDE.md` (per §10's pinned URL note), README.md (just created — should already have new URL), and possibly some plans/specs.

For each finding, edit the file: replace `Shreeyak/eva-swift-stitch` with `Shreeyak/cambrian-ios-camera`.

- [ ] **Step 6: Verify zero literal-old-URL survivors.**

Run: `grep -rln 'Shreeyak/eva-swift-stitch' --exclude-dir=.git --exclude-dir=implementation --exclude-dir=docs/superpowers/specs/archive --exclude-dir=docs/superpowers/plans/archive .`
Expected: no output.

- [ ] **Step 7: Stage any doc edits + commit.**

Run: `git add -A && git status --short`

If anything was modified:
```bash
git commit -m "$(cat <<'EOF'
docs(restructure): A5b — sweep literal old GitHub URL refs

GitHub repo renamed eva-swift-stitch → cambrian-ios-camera. Old URL
auto-redirects, but literal-string refs in docs are updated for clarity.
Local remote URL also updated (not in commit — git config is per-clone).

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A5b.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If nothing was modified (Step 5 returned no findings), skip the commit.

---

## Task 16: A6.1 — Archive superseded Phase 3 files

**Files moved:**
- 4 plan files under `docs/superpowers/plans/` → `docs/superpowers/plans/archive/`
- 1 spec file under `docs/superpowers/specs/` → `docs/superpowers/specs/archive/`

- [ ] **Step 1: Create archive subdirectories.**

Run:
```bash
mkdir -p docs/superpowers/plans/archive
mkdir -p docs/superpowers/specs/archive
```

- [ ] **Step 2: Move the 4 Phase 3 plan files.**

Run:
```bash
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md   docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-2-adapter-methods-bridge.md  docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-3-ios-only-calibration.md    docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-4-hitl-and-polish.md         docs/superpowers/plans/archive/
```

Note: `2026-05-18-phase-3-plan-3-ios-only-calibration.md` may have uncommitted modifications from before this session. If so: `git status --short` will show the move + the modification together. Stage both: `git add docs/superpowers/plans/archive/2026-05-18-phase-3-plan-3-ios-only-calibration.md`. The archived file lands with its pre-existing modifications intact.

- [ ] **Step 3: Move the Phase 3 design spec.**

Run:
```bash
git mv docs/superpowers/specs/2026-05-18-phase-3-design.md docs/superpowers/specs/archive/
```

- [ ] **Step 4: Prepend the SUPERSEDED banner to each archived file.**

For each of the 5 archived files, prepend this exact line at the very top (before the existing first line):

```markdown
> **SUPERSEDED 2026-05-20** by `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. This plan targeted cam2fd integration which is no longer the architecture. Phase B's plan will be written fresh.
```

The simplest way per file:
```bash
for f in docs/superpowers/plans/archive/2026-05-18-phase-3-plan-*.md docs/superpowers/specs/archive/2026-05-18-phase-3-design.md; do
  printf '%s\n\n' '> **SUPERSEDED 2026-05-20** by `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. This plan targeted cam2fd integration which is no longer the architecture. Phase B'"'"'s plan will be written fresh.' | cat - "$f" > "$f.new" && mv "$f.new" "$f"
done
```

(The escaping handles the single quote in "Phase B's".)

- [ ] **Step 5: Verify the banner landed.**

Run: `head -2 docs/superpowers/plans/archive/2026-05-18-phase-3-plan-1-scaffold-and-contract.md`
Expected: first line is the SUPERSEDED banner; second line is blank.

Repeat-spot-check for `head -2 docs/superpowers/specs/archive/2026-05-18-phase-3-design.md`.

- [ ] **Step 6: Stage and commit.**

Run: `git add -A && git status --short`
Expected: 5 `R` (rename) lines + 5 `M` (banner prepend) entries — git may show this as combined renames-with-modifications.

Commit:
```bash
git commit -m "$(cat <<'EOF'
docs(restructure): A6.1 — archive superseded Phase 3 plans + spec

Move Phase 3 plan files (1-4) and the Phase 3 design spec to
docs/superpowers/{plans,specs}/archive/. Prepend SUPERSEDED banner so
future Claude sessions browsing plans/ don't treat them as live work.

Phase 1+2 plan files and 2026-05-14-camerakit-flutter-migration-
design.md are NOT archived (record shipped work).

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: A6.2 — Rewrite affected CLAUDE.md sections

**Files modified:** `CLAUDE.md` (sections §1, §2, §3 partial, §5, §6, §6.0 expanded, §8, §10).

This task has the most prose. The spec provides specific guidance per section; the implementer must produce coherent rewrites — not just sed-replace.

- [ ] **Step 1: Read current CLAUDE.md sections to be rewritten.**

Read `/Users/shrek/work/cambrian/eva-swift-stitch/CLAUDE.md` carefully. Focus on:
- §1 (What this repo is)
- §2 (Repo layout)
- §3 (Pipeline role and stage discipline)
- §5 (Target shape)
- §6 (Common operations) + §6.0 (One-time host setup) + §6.1 (Coordinator discipline) + §6.2 (Tools)
- §8 (Load-bearing invariants)
- §10 (Flutter plugin consumption — currently about the synthetic branch)

This is a lot of content. Don't try to rewrite everything at once.

- [ ] **Step 2: Rewrite §1 (What this repo is).**

Replace the current §1 framing. New framing:

> This repo is the home of **CameraKit** (a Swift package for iOS camera access) and **`cambrian_ios_camera`** (a Flutter plugin wrapping CameraKit for use from Flutter apps). Two examples live alongside: `ios_example_app/` (native SwiftUI) and `flutter/example/` (Flutter — populated in Phase B).
>
> CameraKit was produced via a clean-room translation from cam2fd's Android camera implementation (see upstream pipeline at `/Users/shrek/work/cambrian/ios-translation/`). That translation pipeline reached Stage 12 (last clean-room translation stage) on 2026-05-15. The 2026-05-20 restructure moved Package.swift to the repo root and added the Flutter plugin scaffold; Phase B will fill in the Flutter plugin implementation.

- [ ] **Step 3: Rewrite §2 (Repo layout).**

Replace the directory tree to match the post-restructure state. Use the tree from the spec's "Target architecture" section as the source:

```
cambrian-ios-camera/  (repo root)
│
├── Package.swift                          ← CameraKit SPM manifest at root
│                                            (uses path: pointing into CameraKit/Sources/X)
├── CameraKit/
│   ├── Sources/{CameraKit,CameraKitInterop,CameraKitCxx}/
│   ├── Tests/CameraKitTests/              (referenced ONLY by ios_example_appTests Xcode target)
│   ├── Tests/SPMTestStub/                 (SPM stub with #error directing to Xcode path)
│   ├── CONTRACTS.md, DECISIONS.md, state.md
│   └── (no Package.swift here — root replaces it)
│
├── ios_example_app/
│   ├── ios_example_app.xcodeproj
│   ├── ios_example_app/                   (app sources, AppCxx/ here too)
│   ├── Tests/                             (XCTest target Info.plist; sources referenced from CameraKit/Tests/)
│   └── UITests/
│
├── flutter/                               (Phase B will populate)
│   └── README.md
│
├── docs/
│   ├── docs/measurements/                      (per-stage HITL + spike notes)
│   └── superpowers/{specs,plans}/         (+ archive/ for superseded Phase 3)
│
├── implementation/                        (READ-ONLY symlinks to ios-translation)
├── scripts/                               (build wrappers, contract regen, etc.)
├── fastlane/                              (release pipeline; preserve as-is)
├── README.md                              (two-personality repo intro)
└── CLAUDE.md
```

- [ ] **Step 4: Lightly amend §3 (Pipeline role and stage discipline).**

Most of §3 still applies (Stages 01–12 are the clean-room translation; their discipline is unchanged). Add at the end:

> **Stage 12 was the last clean-room translation stage.** Subsequent work (Phase 1A/1B/2/3 in CameraKit's history, and the 2026-05-20 restructure documented in `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`) does not follow the stage briefs-and-pre-flight pattern. Phase B (Flutter plugin implementation) is fresh design, not a continuation of the clean-room stages.

- [ ] **Step 5: Rewrite §5 (Target shape).**

Update for the new structure. Key points:
- Root `Package.swift`; no longer at `CameraKit/Package.swift`.
- `ios_example_app.xcodeproj` (was `eva-swift-stitch.xcodeproj`); bundle ID `com.cambrian.ios-example-app`.
- `INFOPLIST_KEY_NSCameraUsageDescription` + `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` set as build settings on the renamed target.
- iOS 26 deployment target unchanged. Swift 6 language mode unchanged. `SWIFT_STRICT_CONCURRENCY = complete` unchanged.
- C++ targets (`CameraKitCxx`) + OpenCV: OpenCV lives in `ios_example_app/ios_example_app/AppCxx/` + `Frameworks/opencv2.xcframework` (the symlink — repo root unless A2.2 Step 7 moved it). CameraKit package never links OpenCV.

- [ ] **Step 6: Rewrite §6 (Common operations).**

Update all path/scheme/target name references throughout. Specifically:
- "Builds and tests go through XcodeBuildMCP" — unchanged in principle, but scheme is now `ios_example_app`.
- `scripts/build-summary.sh`, `scripts/test-summary.sh`: unchanged interface; underlying defaults reference `ios_example_app`.
- The "`swift build`/`swift test` rule" — keep the host-triple rule, but UPDATE: `swift test` against this package now produces an informational `SPMTestStub` `#error` pointing to the Xcode path. That's better than the previous behavior (compilation errors). Note: the rule "use XcodeBuildMCP on device" still applies.

- [ ] **Step 7: Expand §6.0 (One-time host setup) with `xcode-build-server` explanation.**

Replace or expand §6.0 to include this content verbatim (from the spec):

> **What `xcode-build-server` does and why we need it.** Sourcekit-lsp (Apple's Language Server, used by VS Code, neovim, Helix, Sublime Text, etc.) needs to know how Xcode would compile each Swift file to provide semantic features — type-resolution, jump-to-definition, find-references, hover docs, completions across file boundaries. Xcode itself uses an undocumented internal protocol to talk to its build system; sourcekit-lsp can't replicate that. The `xcode-build-server` (Homebrew: `brew install xcode-build-server`) is a third-party tool that translates between the two: it runs `xcodebuild -showBuildSettings` to learn the project's compile flags, then exposes them via the standard Build Server Protocol that sourcekit-lsp understands.
>
> Concretely: `xcode-build-server config -project ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app` writes a file `buildServer.json` in the current directory. That file contains the workspace path, the scheme name, and a build_root pointing at the project's DerivedData. Sourcekit-lsp walks up from a source file's path looking for `buildServer.json` — so the file must be at the repo root (not in `ios_example_app/`) to be reachable from sources in `CameraKit/Sources/`.
>
> Without this setup, sourcekit-lsp falls back to a (limited) heuristic resolver that can't track cross-module imports cleanly — you'll see "cannot find type X in scope" in your editor on Swift files that obviously compile fine. The file is gitignored (host-specific DerivedData paths); each developer regenerates after cloning, after switching schemes, or after Xcode bumps DerivedData hash. Inside Xcode itself, none of this matters — Xcode uses its own build system. This is purely for external editors.

Also update §6.0's setup commands:
```bash
brew install xcode-build-server fswatch swift-format ripgrep repomix xcsift jq
cd "$(git rev-parse --show-toplevel)"
xcode-build-server config -project ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app
git config core.hooksPath .githooks   # currently a no-op (hook deleted in restructure 2026-05-20)
```

- [ ] **Step 8: Rewrite §8 (Load-bearing invariants).**

Update test-target naming and remove the dual-membership invariant.

Replace the "Tests use a host app, not tool-hosted; CameraKitTests is dual-membered" invariant with:

> **Tests use a host app, not tool-hosted; single-membership Xcode-only.** iOS forbids tool-hosted tests on physical-device destinations, and simulators are disallowed on this machine (§6). So every `.swift` file in `CameraKit/Tests/CameraKitTests/` is compiled exclusively by the Xcode `ios_example_appTests` target (`TEST_HOST=ios_example_app.app`, runs on iPad). The SPM-side `.testTarget(name: "CameraKitTests")` was removed during the 2026-05-20 restructure (it was an aspirational portability contract that never worked due to the macOS-host-triple AVFoundation problem); in its place is `SPMTestStub` whose only purpose is to make `swift test` emit a clear `#error` pointing to the Xcode path. Canonical run command: `mcp__XcodeBuildMCP__test_device` with scheme `ios_example_app`. To add a new test file, create it in `CameraKit/Tests/CameraKitTests/` then run `scripts/sync-test-target.sh` (idempotent — writes pbxproj entries).

Keep the rest of §8's invariants.

- [ ] **Step 9: Replace §10 entirely.**

The current §10 documents the synthetic-branch mechanism for cam2fd consumption. That's all obsolete. New §10:

> ## 10. Flutter plugin layout — `cambrian_ios_camera` under `flutter/`
>
> This repo ships a Flutter plugin in addition to the Swift package. The plugin lives at `flutter/` and follows standard Flutter plugin conventions:
>
> ```
> flutter/
> ├── pubspec.yaml                          (Phase B)
> ├── lib/                                  (Phase B — Dart-facing API + Pigeon-generated bindings)
> ├── pigeons/                              (Phase B — Pigeon DSL inputs)
> ├── ios/cambrian_ios_camera/Package.swift (Phase B — depends on root via .package(path: "../../.."))
> ├── android/                              (Phase B — no-op stub, throws PlatformException)
> ├── test/                                 (Phase B — Dart unit tests)
> └── example/                              (Phase B — standard Flutter plugin example app)
> ```
>
> **Phase A status (2026-05-20):** `flutter/` exists with placeholder README only. Phase B (a separate spec + plan, written fresh — does NOT consult the superseded Phase 3 plans now in `docs/superpowers/plans/archive/`) will populate it.
>
> **Downstream Flutter consumption:**
>
> ```yaml
> dependencies:
>   cambrian_ios_camera:
>     git:
>       url: https://github.com/Shreeyak/cambrian-ios-camera.git
>       path: flutter        # plugin is at flutter/, not the repo root
>       ref: v1.0.0          # pin to a tag
> ```
>
> See README.md for the full consumer-facing version.

- [ ] **Step 10: Verify CLAUDE.md syntax + reasonable length.**

Run: `wc -l CLAUDE.md`
Note the line count. Should be similar to before (within 10–20% — we're rewriting, not adding bulk).

Run: `grep '^## ' CLAUDE.md | head -20`
Expected: same section headers as before (§1–§10 plus subsections); no orphaned content.

- [ ] **Step 11: Commit.**

Run:
```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(restructure): A6.2 — rewrite CLAUDE.md for new layout

Affected sections:
- §1: new framing (Swift package + Flutter plugin producer)
- §2: new repo layout
- §3: light amend (Stage 12 = last clean-room stage)
- §5: new bundle ID, renamed project, new SPM root
- §6: path/scheme name updates throughout; swift test rule updated
       (SPMTestStub #error path)
- §6.0: expanded with xcode-build-server explanation
- §8: dual-membership invariant removed (single Xcode-target only)
- §10: rewritten — synthetic-branch / cam2fd consumption replaced
       by in-repo flutter/ plugin layout

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: A7.0 — Create one-time `scripts/check-legacy-names.sh` helper

**Files:**
- Create: `scripts/check-legacy-names.sh` (one-time, deleted in Task 20)

- [ ] **Step 1: Write the script.**

Create `/Users/shrek/work/cambrian/eva-swift-stitch/scripts/check-legacy-names.sh` with this content:

```bash
#!/usr/bin/env bash
# One-time Phase A verification helper. Deleted after the restructure is confirmed
# clean. NOT part of CI; NOT a permanent part of scripts/.
#
# Purpose: surface any lingering eva-swift-stitch / eva_swift_stitch references in
# live code, scripts, fastlane, or current docs that the restructure missed.
# Allowed survivors: append-only historical logs (state.md, DECISIONS.md) and
# archived superseded specs/plans.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FAIL=0

echo "=== Legacy app/repo name sweep (eva-swift-stitch | eva_swift_stitch) ==="
hits=$(grep -rln 'eva-swift-stitch\|eva_swift_stitch' \
    --exclude-dir=.git \
    --exclude-dir=implementation \
    --exclude-dir=docs/superpowers/specs/archive \
    --exclude-dir=docs/superpowers/plans/archive \
    --exclude='state.md' \
    --exclude='DECISIONS.md' \
    --exclude='2026-05-{14,18}-*.md' \
    . || true)
if [ -n "$hits" ]; then
    echo "FAIL: legacy name found in:"
    echo "$hits"
    FAIL=1
fi

echo "=== Legacy docs/measurements/ path sweep (should be docs/docs/measurements/) ==="
hits=$(grep -rln 'docs/measurements/' \
    --exclude-dir=.git \
    --exclude-dir=docs/measurements \
    --exclude-dir=implementation \
    --include='*.swift' --include='*.md' --include='*.sh' --include='*.rb' \
    . || true)
# Filter: allow already-updated docs/docs/measurements/ refs
hits=$(echo "$hits" | xargs -I{} grep -L 'docs/docs/measurements/' {} 2>/dev/null || true)
if [ -n "$hits" ]; then
    echo "FAIL: unprefixed docs/measurements/ found in:"
    echo "$hits"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: no legacy names in live content."
fi
exit "$FAIL"
```

- [ ] **Step 2: Make it executable.**

Run: `chmod +x scripts/check-legacy-names.sh`

- [ ] **Step 3: Run it now (smoke test — should pass).**

Run: `scripts/check-legacy-names.sh`
Expected: prints two `=== ... ===` sweep headers and ends with `PASS: no legacy names in live content.` Exit code 0.

If it FAILS at this point, fix the surfaced issues before continuing. Don't commit a failing check.

- [ ] **Step 4: Stage but DO NOT COMMIT yet.**

Run: `git add scripts/check-legacy-names.sh`

The script gets deleted in Task 20 (after the verification suite passes). It will be committed together with the deletion + state.md update — single final commit at A7.

---

## Task 19: A7 — Run the 15-check verification suite

**Files:** none (read-only verification + smoke tests).

For each check below, run the command and confirm the expected outcome. If a check fails, do NOT proceed — investigate and fix.

- [ ] **Check 1: `ios_example_app` builds cleanly.**

Run: `mcp__XcodeBuildMCP__build_run_device`
Expected: BUILD SUCCEEDED + app launches on iPad.

- [ ] **Check 2: CameraKit test suite runs and passes.**

Run: `mcp__XcodeBuildMCP__test_device` (scheme `ios_example_app`)
Expected: all Stage01Tests–Stage12Tests pass. Specifically confirm `Stage08CannyTests` passes — that proves the C++ scaffolding (AppCxx + OpenCV link) moved correctly.

If a test fails for reasons unrelated to the restructure (test flakiness), retry once. If still failing, investigate.

- [ ] **Check 3: `scripts/stage-preflight.sh` exits 0.**

Run: `scripts/stage-preflight.sh`
Expected: exit code 0; output reports state.md ↔ source slug coherence, CONTRACTS.md fresh, build success.

- [ ] **Check 4: SwiftLint is clean.**

Run: `swiftlint lint --config .swiftlint.yml`
Expected: no errors, no warnings (or only pre-existing acceptable warnings — compare against pre-restructure baseline if needed).

- [ ] **Check 5: Pre-commit hooks pass on a representative no-op commit.**

Run: `scripts/regen-contracts.sh`
Expected: exits 0; `CameraKit/CONTRACTS.md` is up-to-date.

Then create a trivial empty commit to trigger hooks:
```bash
git commit --allow-empty -m "test: verify pre-commit hooks pass post-restructure"
```
Expected: hooks run (swift-format --strict, contracts regen); commit completes. Then immediately undo: `git reset --soft HEAD~1`.

- [ ] **Check 6: `camerakit-only` branch still present; `.githooks/pre-push` gone.**

Run: `git ls-remote origin camerakit-only`
Expected: returns a SHA.

Run: `ls -la .githooks/`
Expected: empty (or sentinel-only).

- [ ] **Check 7: Scratch downstream Swift package consumption test.**

In a tmp directory outside this repo, create a scratch package:
```bash
mkdir -p /tmp/scratch-consumer && cd /tmp/scratch-consumer
swift package init --type executable --name ScratchConsumer
```

Edit `/tmp/scratch-consumer/Package.swift`:
```swift
// swift-tools-version:6.2
import PackageDescription
let package = Package(
    name: "ScratchConsumer",
    platforms: [.iOS(.v26)],
    dependencies: [
        .package(url: "<absolute path to this repo>", branch: "flutter-monorepo-restructure"),
    ],
    targets: [
        .executableTarget(
            name: "ScratchConsumer",
            dependencies: [
                .product(name: "CameraKit", package: "cambrian-ios-camera"),
                .product(name: "CameraKitInterop", package: "cambrian-ios-camera"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)
```

(`<absolute path to this repo>` is the file:// URL or local path of this repo; the user pre-rename or post-rename URL also works since GitHub redirects.)

Replace `Sources/ScratchConsumer/ScratchConsumer.swift` with:
```swift
import CameraKit
import CameraKitInterop

@main
struct App {
    static func main() async throws {
        // (a) import CameraKit resolves
        // (b) import CameraKitInterop resolves
        // (c) Trigger shader load — proves resources: [.process("Shaders")] survived
        _ = MetalPipeline.self
        // (d) C++ header reference — proves publicHeadersPath resolves
        // (uses CameraKitInterop's exposed C++ types)
    }
}
```

Run: `cd /tmp/scratch-consumer && swift package resolve`
Expected: package resolves cleanly.

NOTE: this scratch consumer doesn't have to actually BUILD (it targets iOS but you may be on macOS host). It only needs to (a) resolve, (b) the references to product names are valid. If `swift package describe` shows the products, this check passes.

Trial dep is NOT committed.

Run: `rm -rf /tmp/scratch-consumer`

- [ ] **Check 8: Info.plist verification — all required keys survive.**

After Check 1's build, locate the built `.app`:
```bash
BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'ios_example_app.app' -path '*Debug-iphoneos*' -print -quit)
echo "Built app: $BUILT_APP"
```

Then:
```bash
/usr/libexec/PlistBuddy -c "Print" "$BUILT_APP/Info.plist" | \
  grep -E 'NSCameraUsageDescription|NSPhotoLibraryAddUsageDescription|UIFileSharingEnabled|UIRequiresFullScreen|UISupportedInterfaceOrientations'
```
Expected: all five keys present with non-empty values.

If any key is missing — particularly the `INFOPLIST_KEY_*`-derived ones (camera, photos) — that's the documented quirk (memory: `project_xcode_infoplist_key_quirk`). Investigate the renamed target's build settings via Xcode (Target → Build Settings → search for `INFOPLIST_KEY`). The values may have been silently dropped during the target rename.

- [ ] **Check 9: LSP / sourcekit-lsp verification.**

Run: `ls -la buildServer.json`
Expected: file exists at repo root.

Run: `scripts/lsp-symbol.sh outline CameraKit/Sources/CameraKit/CameraEngine.swift`
Expected: returns non-empty (a list of symbols defined in CameraEngine.swift). Proves the LSP can find buildServer.json from a `CameraKit/Sources/` source path and resolve symbols there.

- [ ] **Check 10: GitHub repo rename + push verification.**

Run: `git remote -v`
Expected: shows `https://github.com/Shreeyak/cambrian-ios-camera.git`.

Run: `git push origin flutter-monorepo-restructure`
Expected: pushes successfully (the branch already exists on remote from earlier pushes).

- [ ] **Check 11: state.md update.**

Edit `CameraKit/state.md`. Find the top of the file (after any "Current stage" header). Add a new section at the top:

```markdown
## Restructure 2026-05-20 — Flutter monorepo

- Package.swift moved to repo root; CameraKit/Package.swift deleted; .testTarget dropped (see spec).
- eva-swift-stitch renamed to ios_example_app (project, scheme, targets, source dirs, bundle ID).
- docs/measurements/ moved to docs/docs/measurements/.
- flutter/ scaffolded (placeholder README; Phase B will populate).
- .githooks/pre-push deleted; camerakit-only branch on origin frozen.
- Phase 3 plans + spec archived to docs/superpowers/{plans,specs}/archive/.
- GitHub repo renamed: eva-swift-stitch → cambrian-ios-camera.
- Verifications 1–10 of spec A7 all passed.
- Date: 2026-05-20. Commit: <fill in at Task 20>.
```

The commit SHA will be filled in at Task 20 once the final commit is made.

- [ ] **Check 12: Repo-wide grep returns only historical refs.**

Run:
```bash
grep -rn 'eva-swift-stitch\|eva_swift_stitch' \
  --exclude-dir=.git --exclude-dir=implementation .
```
Expected output is limited to:
- `docs/superpowers/plans/archive/*` (archived Phase 3 plans)
- `docs/superpowers/specs/archive/*` (archived Phase 3 spec)
- `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` (older overarching spec with historical refs)
- `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md` (this spec — intentionally documents the rename)
- `docs/superpowers/plans/2026-05-20-flutter-plugin-monorepo-plan.md` (this plan)
- `CameraKit/state.md` (historical entries pre-restructure)
- `CameraKit/DECISIONS.md` (historical entries)

If any other path matches (source files, scripts, CLAUDE.md, README.md, fastlane), that's a bug — investigate.

- [ ] **Check 13: Package.resolved committed if present.**

Run: `find . -name 'Package.resolved' -not -path './.git/*'`
Expected: shows zero or one file (under `ios_example_app/ios_example_app.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` if Xcode has resolved).

If present, ensure it's staged:
```bash
git status --short | grep Package.resolved
```
If shown as untracked or modified, stage it.

- [ ] **Check 14: `swift test` produces the SPMTestStub `#error`.**

Run: `swift test 2>&1 | grep -i 'CameraKit tests cannot run'`
Expected: matches the `#error` message line.

Full run for sanity:
```bash
swift test 2>&1 | head -30
```
Expected: build fails at `StubMessage.swift` with the `#error`-formatted message. No real tests run.

- [ ] **Check 15: `scripts/check-legacy-names.sh` exits 0.**

Run: `scripts/check-legacy-names.sh`
Expected: prints `PASS: no legacy names in live content.` and exits 0.

If FAIL, investigate the surfaced legacy refs and fix before proceeding.

---

## Task 20: Final A7 commit — state.md update + delete check-legacy-names.sh

**Files:**
- Modify: `CameraKit/state.md` (filled in at Check 11)
- Delete: `scripts/check-legacy-names.sh`

- [ ] **Step 1: Verify state.md was updated in Check 11.**

Run: `head -15 CameraKit/state.md`
Expected: top section is `## Restructure 2026-05-20 — Flutter monorepo` with the 9 bullet items.

- [ ] **Step 2: Delete the one-time check script.**

Run: `git rm scripts/check-legacy-names.sh`

- [ ] **Step 3: Stage any other pending changes.**

Run: `git add -A`
Run: `git status --short`
Expected: shows `M CameraKit/state.md`, `D scripts/check-legacy-names.sh`, possibly `M scripts/...` if any other minor sweeps happened during verification. Also possibly `Package.resolved` from Check 13.

- [ ] **Step 4: Commit (final commit of Phase A).**

Run:
```bash
git commit -m "$(cat <<'EOF'
chore(restructure): A7 — verification pass; state.md updated; helper deleted

15-check verification suite passes (build, test, stage-preflight,
swiftlint, pre-commit hooks, branch+hook state, downstream SPM
consumption, Info.plist keys, LSP, remote push, state.md, legacy-name
sweep, Package.resolved, swift-test stub, check-legacy-names).

state.md gains "Restructure 2026-05-20" entry. scripts/
check-legacy-names.sh was the one-time verification helper; deleted now
that it has served its purpose.

Per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md A7.

Phase A restructure complete. Merge-gate reminder for the eventual
PR-to-main: decide whether to `git push origin --delete camerakit-only`
at merge time (see spec §Future cleanup).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Fill in the commit SHA in state.md.**

The state.md entry from Check 11 has a placeholder `Commit: <fill in at Task 20>`. Fill it in:
```bash
SHA=$(git rev-parse --short HEAD)
sed -i '' "s|Commit: <fill in at Task 20>|Commit: $SHA|" CameraKit/state.md
```

- [ ] **Step 6: Amend the final commit with the SHA fix.**

Run:
```bash
git add CameraKit/state.md
git commit --amend --no-edit
```

This is acceptable per CLAUDE.md §7 — the amend is to add the SHA into the state.md entry that documents this exact commit. Not amending around a hook failure.

- [ ] **Step 7: Push the final state of the branch.**

Run: `git push origin flutter-monorepo-restructure --force-with-lease`
Expected: push succeeds (force-with-lease because of the amend).

- [ ] **Step 8: Confirm everything landed.**

Run: `git log --oneline main..HEAD`
Expected: shows all the A1–A7 commits on this branch since main, in order.

Run: `git remote -v`
Expected: origin URL is `https://github.com/Shreeyak/cambrian-ios-camera.git`.

Run: `git ls-remote origin camerakit-only`
Expected: returns a SHA (the branch is preserved per design).

---

## Self-Review (against the spec)

**1. Spec coverage check:**
- A0: Task 1 ✓
- A1: Task 2 ✓
- A2.1–A2.8: Tasks 3–10 ✓
- A3: Task 11 ✓
- A4.1: Task 12 ✓; A4.2: Task 13 ✓
- A5: Task 14 ✓
- A5b: Task 15 ✓
- A6.1 (Phase 3 archival): Task 16 ✓; A6.2 (CLAUDE.md rewrite): Task 17 ✓
- A7.0 (helper script create): Task 18 ✓
- A7 (15-check verification): Task 19 ✓
- A7 final commit (state.md + helper delete): Task 20 ✓

All spec sections covered.

**2. Placeholder scan:** no "TBD", "TODO", or "implement later" placeholders. Every code/command step has exact content.

**3. Type consistency:** target names (`ios_example_app`, `ios_example_appTests`, `ios_example_appUITests`), bundle ID (`com.cambrian.ios-example-app`), package name (`CameraKit`), and product names (`CameraKit`, `CameraKitInterop`) are used consistently across all tasks. SPM `SPMTestStub` target name + `StubMessage.swift` file name match across Task 2 (creation) and Task 19 Check 14 (verification).

**4. Ordering:** A1 explicitly skips build verification because the package reference in pbxproj is broken until A2.1's relativePath update; this is called out in Task 2 Step 9 and Task 10 Step 8. Tasks 3–10 land in one commit so git rename detection works; explicitly noted in Tasks 3, 4, 5, 6, 7, 8, 9 ("Do NOT commit") and Task 10 (the single commit).

**5. Dependencies between tasks:**
- Task 6 (Apple Developer console) blocks Task 10 Step 8 (build verification). User must complete the Apple Developer step OR Xcode auto-handles it on first build.
- Task 15 (GitHub repo rename) blocks Task 19 Check 10 (verify remote URL).
- All other tasks are sequential per spec design.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-20-flutter-plugin-monorepo-plan.md`.
