# Flutter Plugin Monorepo Restructure — Design

**Status:** 2026-05-20
**Branch:** `flutter-monorepo-restructure`

**Supersedes (Phase 3 work only):**
- `docs/superpowers/specs/2026-05-18-phase-3-design.md` — superseded fully.
- `docs/superpowers/plans/2026-05-18-phase-3-plan-{1,2,3,4}-*.md` — superseded fully.
- `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` — Phase 3 portion only.

**Not superseded — historical record of shipped work this restructure builds on:**
- Phase 1A + 1B (CameraKit decoupling).
- Phase 2 (CameraKit API vocabulary alignment). Phase B re-uses this curated public surface (`setProcessingParams`, `OpenConfiguration.initialSettings`, capability ranges, `streamConfigurationStream`, `currentPixelBuffer(stream:)`, calibration methods returning `CalibrationResult`, `SessionState.interrupted`, etc.) as the basis for its Pigeon definitions.

**Carries forward (authoritative measurement results):** `docs/measurements/flutter-spm-spike/2026-05-15.md`, `docs/measurements/texture-bridge/2026-05-15/notes.md`, `docs/measurements/phase-3-prep/rgba8-conversion.md`.

---

## Scope

Restructure this repo so that:

1. **`CameraKit` ships as a top-level Swift package** consumable by any Swift app via SPM URL (no synthetic-branch indirection). Package name `CameraKit` preserved; rename deferred — see §"Future cleanup".
2. **A Flutter plugin (`cambrian_ios_camera`) lives inside the same repo** at `flutter/` and ships as a `git: + path:` pub dependency.
3. **Two example apps coexist:** native SwiftUI app (`ios_example_app/`, replacing today's `eva-swift-stitch` harness) and the standard Flutter plugin example (`flutter/example/`).
4. **`CameraKit` and the plugin develop in lockstep** — no version pinning between them; Swift API breaks surface as plugin build errors in the same commit.
5. **Code-level relationship with `camera2_flutter_demo` (cam2fd) is severed.** cam2fd is the Android-only sibling plugin in its own repo. No shared code, Pigeon, or interface package. Surface vocabulary stays similar by convention only.
6. **Synthetic-branch handling:**
   - `.githooks/pre-push` is DELETED in Phase A. After A1 deletes `CameraKit/Package.swift`, the hook's `git subtree split --prefix=CameraKit` produces an invalid Swift package (no root `Package.swift`); without deletion, the hook would force-push broken content over the currently-valid `camerakit-only` branch on origin.
   - `camerakit-only` branch on `origin` is LEFT ALONE in Phase A. Stays frozen at its current valid state.
   - Decide whether to `git push origin --delete camerakit-only` at merge time — see §"Future cleanup" merge-gate.

This spec covers **the physical restructure only — "Phase A".** Phase B (Flutter plugin implementation — Pigeon, HostApi, FlutterTexture bridge, Dart API, example app) is a follow-up spec. Phase B does NOT carry forward the superseded Phase 3 plan files. `flutter/` ships with a placeholder README at end of Phase A.

---

## Target architecture

```
cambrian-ios-camera/  (repo root — renamed from eva-swift-stitch)
│
├── Package.swift                          ← NEW: CameraKit SPM manifest at root
│                                            targets use path: "CameraKit/Sources/X"
│                                            NO .testTarget — tests run via Xcode app-hosted target only
├── CameraKit/                             ← source layout UNCHANGED (name preserved; rename deferred to later cleanup)
│   ├── Sources/
│   │   ├── CameraKit/                       (Swift package — iOS 26, strict concurrency)
│   │   ├── CameraKitInterop/                (Swift ↔ C++ boundary)
│   │   └── CameraKitCxx/                    (C++ PixelSink pool, atomics)
│   ├── Tests/CameraKitTests/                (Swift Testing — referenced ONLY by ios_example_appTests Xcode target)
│   ├── CONTRACTS.md, DECISIONS.md, state.md (auto-regen + append-only logs)
│   └── Package.swift                        ← DELETED (root Package.swift replaces it)
│
├── ios_example_app/                       ← RENAMED from eva-swift-stitch native app
│   ├── ios_example_app.xcodeproj
│   ├── ios_example_app/                   (was: eva-swift-stitch/)
│   │   ├── ios_example_appApp.swift       (was: eva_swift_stitchApp.swift)
│   │   ├── Info.plist, Assets.xcassets/
│   │   └── UI/, …                         (dev-harness SwiftUI code, moved verbatim)
│   ├── Tests/                             ← was: eva-swift-stitchTests/
│   │   └── Info.plist                       (bundle plist; test source files at CameraKit/Tests/CameraKitTests/ referenced via pbxproj)
│   └── UITests/                           ← was: eva-swift-stitchUITests/
│       └── Info.plist
│
├── flutter/                               ← NEW: Flutter plugin (placeholder README only in Phase A)
│   └── README.md                            (notes "Phase B" — fresh design, no cam2fd carry-over)
│
├── docs/
│   ├── docs/measurements/                      ← MOVED from /docs/measurements/
│   │   ├── stage-NN/, texture-bridge/, flutter-spm-spike/, phase-3-prep/
│   └── superpowers/
│       ├── specs/, plans/
│
├── implementation/                        ← UNCHANGED (read-only symlinks to ios-translation)
├── scripts/                               ← UPDATED (path constants for new project name; pigeon regen added in Phase B)
├── fastlane/                              ← UPDATED (project + scheme name)
├── .githooks/                             ← `pre-push` hook DELETED in Phase A (would corrupt camerakit-only post-A1)
├── CLAUDE.md                              ← MAJOR REWRITE (§1, §2, §3, §5, §6, §8, §10)
└── .swiftlint.yml, Gemfile, Gemfile.lock

camerakit-only branch on origin           ← UNCHANGED (left frozen at current valid state; pending merge-gate decision)
```

### Three deliverable surfaces

1. **`CameraKit` Swift package.** Root `Package.swift`. Targets `CameraKit`, `CameraKitInterop`, `CameraKitCxx`. No real `.testTarget`. Public products: `.library(CameraKit)` and `.library(CameraKitInterop)`. Imported by Swift apps as `import CameraKit`. Name preserved in Phase A; rename deferred.
2. **`cambrian_ios_camera` Flutter plugin.** Root at `flutter/`. Standard Flutter plugin shape (built in Phase B): `pubspec.yaml`, `lib/`, `ios/cambrian_ios_camera/Package.swift` (referencing root `Package.swift` via `.package(path: "../../..")`), Android stub (no-op `MethodCallHandler` rejecting all calls), `example/` Flutter app. Placeholder README only in Phase A.
3. **`ios_example_app` native iOS app.** SwiftUI dev harness importing `CameraKit` via the local SPM package at the repo root. Bundle ID: `com.cambrian.ios-example-app` (hyphens per Apple's reverse-DNS convention).

### Test architecture (replaces dual-membership)

Test source files live at `CameraKit/Tests/CameraKitTests/` (unchanged location), referenced **only** from the Xcode `ios_example_appTests` target via `PBXBuildFile` entries in `ios_example_app.xcodeproj/project.pbxproj`. The root `Package.swift` does NOT declare a real `.testTarget` — `swift test` fails against CameraKit anyway (host-triple problem: SPM defaults to macOS, CameraKit uses iOS-only AVFoundation).

Dropping the SPM-side real `.testTarget` removes the dual-membership hack from CLAUDE.md §8. `scripts/sync-test-target.sh` continues to wire new test files into the Xcode target (idempotent pbxproj updates).

#### Informational stub test target — `SPMTestStub`

Keep one tiny SPM `.testTarget` whose only purpose is to fail compilation with a clear message pointing at the correct test path:

```
CameraKit/Tests/SPMTestStub/
└── StubMessage.swift
```

Content of `StubMessage.swift`:

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

And in `Package.swift`:

```swift
.testTarget(
    name: "SPMTestStub",
    path: "CameraKit/Tests/SPMTestStub"
)
```

Effect: `swift test` compiles `SPMTestStub`, hits the `#error`, prints the message verbatim. No runtime overhead, no impact on Xcode-side testing.

---

## Naming domains

| Domain | Name | Convention rule |
|---|---|---|
| GitHub repo | `cambrian-ios-camera` | hyphens (GitHub convention) |
| Swift package | `CameraKit` (preserved; rename deferred) | PascalCase |
| Flutter plugin | `cambrian_ios_camera` | snake_case (pubspec.yaml requirement) |
| Native example app | `ios_example_app` | snake_case |
| Example app bundle ID | `com.cambrian.ios-example-app` | reverse-DNS with hyphens (Apple convention) |
| Xcode target names | `ios_example_app`, `ios_example_appTests` | valid Swift identifiers (underscores, no hyphens) |

---

## Restructure plan (Phase A)

### A0. Safety net — tag current `main`

Before any moves, tag the current state. If anything goes wrong, this is the rollback target.

```bash
git tag -a pre-restructure-2026-05-20 -m "Pre-restructure snapshot of CameraKit + eva-swift-stitch native app"
git push origin pre-restructure-2026-05-20
```

### A1. Move `Package.swift` to repo root

- Create new `Package.swift` at repo root. Each target uses explicit `path:` pointing at `CameraKit/Sources/{CameraKit,CameraKitInterop,CameraKitCxx}`. Preserve every detail from `CameraKit/Package.swift` verbatim:
  - `dependencies`: `apple/swift-atomics` from `1.2.0`
  - `cxxLanguageStandard: .cxx20`
  - `swiftSettings`: `.swiftLanguageMode(.v6)`, `.interoperabilityMode(.Cxx)` per target
  - `cxxSettings`: `.define("CPP_POOL_THREAD_COUNT", to: "4")`, `.headerSearchPath("include")`
  - `publicHeadersPath: "include"` on `CameraKitCxx` (resolves to `CameraKit/Sources/CameraKitCxx/include`)
  - `resources: [.process("Shaders")]` on `CameraKit` (resolves to `CameraKit/Sources/CameraKit/Shaders`)
  - Public products: `.library(name: "CameraKit", ...)` and `.library(name: "CameraKitInterop", ...)`
- Drop the real `.testTarget`; add the `SPMTestStub` test target (see §"Test architecture").
- Delete `CameraKit/Package.swift`, `CameraKit/.build/`, `CameraKit/.swiftpm/`.
- Package + target + source-dir names unchanged.
- **No build verification at the end of A1.** A build fails because the Xcode project's `XCLocalSwiftPackageReference relativePath = CameraKit` no longer points at a valid package. Verification happens at end of A2 once the relativePath is corrected.

### A2. Rename eva-swift-stitch native app → `ios_example_app`

Eight sub-parts (A2.1–A2.8), all landing in **one commit** so git rename detection holds (pbxproj content-similarity drops below the default 50% threshold after A2.1's mutations; single-commit + `--find-renames=30%` preserves history).

#### A2.1. Pbxproj surgery via `xcodeproj` Ruby gem

Never hand-edit `project.pbxproj` (CLAUDE.md §6). Ruby helper updates every affected key in every build configuration:

```ruby
# scripts/rename-project.rb (one-time helper, deleted after use)
require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')

# Targets
p.targets.each do |t|
  case t.name
  when 'eva-swift-stitch'         then t.name = 'ios_example_app'
  when 'eva-swift-stitchTests'    then t.name = 'ios_example_appTests'
  when 'eva-swift-stitchUITests'  then t.name = 'ios_example_appUITests'
  end
end

# Build settings (every configuration of every target) — explicit enumeration:
p.targets.each do |t|
  t.build_configurations.each do |c|
    s = c.build_settings
    # Identity
    s['PRODUCT_NAME']                    = t.name
    s['PRODUCT_MODULE_NAME']              = t.name           # critical — affects @testable import
    s['PRODUCT_BUNDLE_IDENTIFIER']        &&= 'com.cambrian.ios-example-app'  # app target only
    # File-plist reference
    if s['INFOPLIST_FILE']
      s['INFOPLIST_FILE'] = s['INFOPLIST_FILE'].sub(/eva-swift-stitch/, 'ios_example_app/ios_example_app')
    end
    # INFOPLIST_KEY_* values are usage strings (no path interp) — leave content alone,
    # but verify the key SURVIVES (memory: project_xcode_infoplist_key_quirk).
    # Bridging header
    if s['SWIFT_OBJC_BRIDGING_HEADER']
      s['SWIFT_OBJC_BRIDGING_HEADER'] = s['SWIFT_OBJC_BRIDGING_HEADER'].sub(
        %r{^eva-swift-stitch/},
        'ios_example_app/ios_example_app/'
      )
    end
    # Header / framework search paths
    %w[HEADER_SEARCH_PATHS FRAMEWORK_SEARCH_PATHS LIBRARY_SEARCH_PATHS].each do |key|
      v = s[key]
      next unless v
      s[key] = (v.is_a?(Array) ? v : [v]).map { |p|
        p.sub(%r{(\$\(SRCROOT\)/)?eva-swift-stitch/}, '\1ios_example_app/ios_example_app/')
      }
    end
  end
end

# XCLocalSwiftPackageReference relativePath:
# Pre-move: "CameraKit"   (project at repo root → /repo/CameraKit)
# Post-move: ".."         (project at /repo/ios_example_app/ → /repo)
p.root_object.package_references.each do |ref|
  if ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
     ref.relative_path == 'CameraKit'
    ref.relative_path = '..'
  end
end

# File references — pbxproj path strings for source-group containers
# (need to update group paths after the git mv in A2.2)
# Use Xcodeproj::Project#group_with_name or main_group traversal to fix
# eva-swift-stitch/* group paths → ios_example_app/ios_example_app/*

p.save
```

This script is one-time, lives in `scripts/`, deleted after use.

#### A2.2. Filesystem moves — single commit for rename detection

Single `git mv` per item (not two-step `git mv` + `mv`); stage A2.1 + A2.2 into the SAME commit:

```bash
# Create the destination dir first; git mv requires the parent to exist.
mkdir ios_example_app

# Move project bundle to final location in one operation.
git mv eva-swift-stitch.xcodeproj  ios_example_app/ios_example_app.xcodeproj

# Move source dirs.
git mv eva-swift-stitch            ios_example_app/ios_example_app
git mv eva-swift-stitchTests       ios_example_app/Tests
git mv eva-swift-stitchUITests     ios_example_app/UITests
```

A2.2 includes moving `eva-swift-stitch/AppCxx/` (→ `ios_example_app/ios_example_app/AppCxx/`) and the gitignored host-machine symlink `Frameworks/opencv2.xcframework -> /Users/shrek/software/opencv2.xcframework`. The symlink stays at repo root (referenced by `FRAMEWORK_SEARCH_PATHS = "$(SRCROOT)/Frameworks"`); verify build settings before assuming this.

#### A2.3. Swift source-level renames

`PRODUCT_MODULE_NAME` change cascades into Swift source:

```bash
# 1. App entry-point file + struct rename
git mv ios_example_app/ios_example_app/eva_swift_stitchApp.swift \
       ios_example_app/ios_example_app/ios_example_appApp.swift
# Inside file: `@main struct eva_swift_stitchApp` → `@main struct ios_example_appApp`

# 2. @testable imports — five known sites + any new:
#    CABIParityTests.swift, Stage08CannyTests.swift, eva_swift_stitchTests.swift,
#    Stage11UITests.swift. Enumerate:
grep -rln '@testable import eva_swift_stitch' ios_example_app/
find ios_example_app -name '*.swift' -exec \
  sed -i '' 's/@testable import eva_swift_stitch/@testable import ios_example_app/g' {} +

# 3. XCTestCase subclass rename
git mv ios_example_app/Tests/eva_swift_stitchTests.swift \
       ios_example_app/Tests/ios_example_appTests.swift
# Inside: `class eva_swift_stitchTests` → `class ios_example_appTests`

# 4. .swiftlint.yml (lines 57–62): replace excluded type-name patterns
#    eva_swift_stitch{,App,Tests} → ios_example_app{,App,Tests}
```

Verify:
```bash
grep -rln 'eva_swift_stitch\|eva-swift-stitch' ios_example_app/ .swiftlint.yml
# Should be zero. Any survivors are bugs.
```

#### A2.4. Bundle identifier and provisioning

Bundle ID: `com.cambrian.eva-swift-stitch` → `com.cambrian.ios-example-app`.

Apple Developer portal must register the new bundle ID before first build. Two paths:
- **Automatic signing:** open project in Xcode signed in as `ss.shrek7@gmail.com`; Xcode auto-registers the bundle ID + regenerates the profile on first build.
- **Manual / fastlane match:** register at developer.apple.com → Identifiers, then `fastlane match` for the new profile. Stranded `com.cambrian.eva-swift-stitch` profile may be left alone.

`fastlane/Appfile` + `fastlane/Fastfile` are mostly template content with no live match config. Update any `app_identifier` references to `com.cambrian.ios-example-app`.

#### A2.5. Schemes — delete `CameraKit.xcscheme`, rename the other

Current xcodeproj has TWO shared schemes:
- `xcshareddata/xcschemes/eva-swift-stitch.xcscheme` — app scheme; renamed.
- `xcshareddata/xcschemes/CameraKit.xcscheme` — references `BlueprintIdentifier = "CameraKitTests"` and `ReferencedContainer = "container:CameraKit"`. After A1, the `container:CameraKit` reference is invalid (no longer a Swift package), and `CameraKitTests` blueprint is gone (no SPM `.testTarget`). Delete it.

```bash
git rm ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/CameraKit.xcscheme
git mv ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/eva-swift-stitch.xcscheme \
       ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme
# Then update XML contents — BlueprintName, BuildableName, BlueprintIdentifier:
# eva-swift-stitch → ios_example_app, eva-swift-stitchTests → ios_example_appTests.
# xcodeproj gem does NOT write .xcscheme files; manual string-replace in the XML.
```

Test functionality (running CameraKit tests from Xcode UI) is preserved through the `ios_example_app` scheme's `ios_example_appTests` target.

#### A2.6. Scripts — exhaustive enumeration

Current `scripts/` inventory:

```
scripts/build-summary.sh
scripts/device-log-live.sh
scripts/dump-interface.sh
scripts/lsp-symbol.sh
scripts/regen-contracts.sh
scripts/regen-contracts-partial.sh
scripts/scaffold-inventory.sh
scripts/stage-preflight.sh
scripts/sync-test-target.sh
scripts/test-summary.sh
scripts/watch-contracts.sh
```

Sweep + replace:

```bash
grep -rln 'eva-swift-stitch\|eva_swift_stitch' scripts/
find scripts -type f -exec sed -i '' \
  -e 's/eva-swift-stitch.xcodeproj/ios_example_app\/ios_example_app.xcodeproj/g' \
  -e 's/eva-swift-stitchTests/ios_example_appTests/g' \
  -e 's/eva-swift-stitchUITests/ios_example_appUITests/g' \
  -e 's/eva-swift-stitch/ios_example_app/g' \
  -e 's/eva_swift_stitch/ios_example_app/g' \
  {} +
grep -rln 'eva-swift-stitch\|eva_swift_stitch' scripts/   # must be zero
```

Per-script notes:
- `device-log-live.sh`: hardcoded UDID for Shreeyak's iPad — unchanged. `Documents/camerakit.log` filename is package-named (CameraKit module), not app-named — unchanged.
- `regen-contracts.sh`: paths to `CameraKit/CONTRACTS.md` and `CameraKit/Sources/CameraKit/**/*.swift` unchanged (sources didn't move).
- `dump-interface.sh`: scheme reference updated.
- `lsp-symbol.sh`: scheme + buildServer reference updated.
- `stage-preflight.sh`: picks up update transitively via `build-summary.sh`.

#### A2.7. `buildServer.json` — at repo root

`xcode-build-server config` writes `buildServer.json` to CWD. Run from repo root:

```bash
cd "$(git rev-parse --show-toplevel)"
xcode-build-server config \
    -project ios_example_app/ios_example_app.xcodeproj \
    -scheme  ios_example_app
# Produces ./buildServer.json at repo root.
```

Sourcekit-lsp walks up from a source file looking for `buildServer.json`. Must be at repo root (reachable from both `CameraKit/Sources/` and `ios_example_app/`), NOT at `ios_example_app/buildServer.json` (unreachable from `CameraKit/Sources/`). Document in §6.0 of rewritten CLAUDE.md.

#### A2.8. fastlane + final cleanup

```bash
grep -rln 'eva-swift-stitch\|eva_swift_stitch' fastlane/
# Manual edit per finding (app_identifier / scheme / xcodeproj refs in Appfile + Fastfile).
```

After A2.1–A2.8 commit, verify:
- `mcp__XcodeBuildMCP__build_run_device` (or `scripts/build-summary.sh`) — `ios_example_app` builds successfully.
- `grep -rln 'eva-swift-stitch\|eva_swift_stitch' --exclude-dir=.git --exclude-dir=implementation --exclude-dir=docs` — only matches under `docs/superpowers/specs/2026-05-{14,18}-*.md` and `CameraKit/state.md`. No live-code matches.

### A3. Move `docs/measurements/` to `docs/docs/measurements/`

```bash
git mv measurements docs/measurements
```

Exhaustive path-reference sweep:
- `CameraKit/state.md` (per-stage HITL pointers)
- `CameraKit/DECISIONS.md` (decision entries referencing measurement files)
- `CameraKit/Sources/**/*.swift` and `CameraKit/Tests/**/*.swift` source comments — `grep -rln 'docs/measurements/' CameraKit/Sources/ CameraKit/Tests/`
- `docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md`
- `scripts/` (`grep -rn docs/measurements/ scripts/` to confirm)
- `README.md` at repo root (if present)
- **Do NOT edit `implementation/briefs/*.md`** — read-only symlinks to upstream. Flag as upstream-patch needed under "Open questions" in `state.md`; brief refs work against upstream's own root.

Verify:
```bash
grep -rn 'docs/measurements/' \
  --exclude-dir=.git --exclude-dir=docs/measurements --exclude-dir=implementation \
  --include='*.swift' --include='*.md' --include='*.sh' --include='*.rb' \
  .
# Zero hits, or only paths already updated to docs/docs/measurements/.
```

### A4. Scaffold new top-level docs

#### A4.1. Empty `flutter/` directory + placeholder

```bash
mkdir flutter
cat > flutter/README.md <<EOF
# cambrian_ios_camera (Phase B)

Flutter plugin wrapping CameraKit for iOS-only camera access. Phase B implementation
lands here per docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md.

For Android camera in Flutter, use cam2fd's cambrian_camera plugin separately.
EOF
git add flutter/README.md
```

#### A4.2. Root-level `README.md`

Without an explicit README, newcomers see `Package.swift` at the root and miss the Flutter plugin under `flutter/`. Write a README that documents both consumer surfaces:

````bash
cat > README.md <<'EOF'
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
EOF
git add README.md
````

A6's CLAUDE.md rewrite happens in the same general pass — keep README + CLAUDE.md consumption examples in sync.

### A5. Delete `.githooks/pre-push`; leave `camerakit-only` branch on origin alone

```bash
# Delete the hook outright (no exit-0 stub; file is not load-bearing beyond its
# now-broken subtree-split logic).
git rm .githooks/pre-push

# Don't unset core.hooksPath — it's a per-developer setting (CLAUDE.md §6.0).
# .githooks/ may now be empty; that's fine.
```

`camerakit-only` branch on `origin` is NOT deleted in Phase A; stays frozen at its current valid state.

Verify: `ls .githooks/` empty (or sentinel-only); `git ls-remote origin camerakit-only` still returns a SHA.

### A5b. Rename GitHub repo (user-driven)

```bash
gh repo rename cambrian-ios-camera
# Or web UI: Settings → General → Repository name → "cambrian-ios-camera"
```

GitHub auto-redirects the old URL indefinitely. Update local remote:

```bash
git remote set-url origin https://github.com/Shreeyak/cambrian-ios-camera.git
```

User-driven (needs GitHub admin auth). After rename, sweep literal old URLs:
- `CLAUDE.md`
- `README.md`
- `docs/superpowers/specs/*`, `docs/superpowers/plans/*`

### A6. Archive Phase 3 plans + spec; rewrite affected `CLAUDE.md` sections

Archive Phase 3 files so future sessions don't treat them as live work:

```bash
mkdir -p docs/superpowers/plans/archive
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md      docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-2-adapter-methods-bridge.md     docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-3-ios-only-calibration.md       docs/superpowers/plans/archive/
git mv docs/superpowers/plans/2026-05-18-phase-3-plan-4-hitl-and-polish.md            docs/superpowers/plans/archive/

mkdir -p docs/superpowers/specs/archive
git mv docs/superpowers/specs/2026-05-18-phase-3-design.md  docs/superpowers/specs/archive/
```

Prepend each archived file with a SUPERSEDED banner:
```markdown
> **SUPERSEDED 2026-05-20** by `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. This plan targeted cam2fd integration which is no longer the architecture. Phase B's plan will be written fresh.
```

Phase 1+2 plan files and `2026-05-14-camerakit-flutter-migration-design.md` are NOT archived (record shipped work).

**CLAUDE.md rewrite** — affected sections:

- **§1 (What this repo is):** new framing — Swift package producer + Flutter plugin producer + dev-harness apps. Drop "Swift iOS 26 implementation target for the CameraKit library" framing as primary.
- **§2 (Repo layout):** new directory tree.
- **§3 (Pipeline role and stage discipline):** mostly unchanged. Note Phase 3 superseded by this restructure; Stage 12 is the last clean-room translation stage; Phase B builds the Flutter plugin on top.
- **§4 (Scaffold-slug convention):** unchanged.
- **§5 (Target shape):** new bundle ID, renamed project, new SPM root.
- **§6 (Common operations):** path/scheme/target name updates. `swift test` rule updated — produces an informational `SPMTestStub` `#error`. Real workflow remains XcodeBuildMCP on device. Expand §6.0 with `xcode-build-server` explanation (below).
- **§6.0 (One-time host setup) — expand:**

  > **What `xcode-build-server` does and why we need it.** Sourcekit-lsp (Apple's Language Server, used by VS Code, neovim, Helix, Sublime Text, etc.) needs to know how Xcode would compile each Swift file to provide semantic features — type-resolution, jump-to-definition, find-references, hover docs, completions across file boundaries. Xcode itself uses an undocumented internal protocol to talk to its build system; sourcekit-lsp can't replicate that. The `xcode-build-server` (Homebrew: `brew install xcode-build-server`) is a third-party tool that translates between the two: it runs `xcodebuild -showBuildSettings` to learn the project's compile flags, then exposes them via the standard Build Server Protocol that sourcekit-lsp understands.
  >
  > Concretely: `xcode-build-server config -project ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app` writes a file `buildServer.json` in the current directory. That file contains the workspace path, the scheme name, and a build_root pointing at the project's DerivedData. Sourcekit-lsp walks up from a source file's path looking for `buildServer.json` — so the file must be at the repo root (not in `ios_example_app/`) to be reachable from sources in `CameraKit/Sources/`.
  >
  > Without this setup, sourcekit-lsp falls back to a (limited) heuristic resolver that can't track cross-module imports cleanly — you'll see "cannot find type X in scope" in your editor on Swift files that obviously compile fine. The file is gitignored (host-specific DerivedData paths); each developer regenerates after cloning, after switching schemes, or after Xcode bumps DerivedData hash. Inside Xcode itself, none of this matters — Xcode uses its own build system. This is purely for external editors.

- **§8 (Load-bearing invariants):** test target naming updated (`eva-swift-stitchTests` → `ios_example_appTests`); dual-membership invariant REMOVED (replaced by single-membership Xcode-target + `SPMTestStub`); CameraKit source location unchanged.
- **§10 (Flutter plugin consumption via synthetic branch):** DELETED. Replaced with new §10 documenting in-repo `flutter/` plugin layout — empty in Phase A, populated in Phase B, consumption instructions mirroring README.

### A7.0. One-time verification helper — `scripts/check-legacy-names.sh`

Create a one-time helper consolidating the grep-sweeps used by A7's checks. Deleted after A7 passes; NOT for CI, NOT committed long-term:

```bash
cat > scripts/check-legacy-names.sh <<'EOF'
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
EOF
chmod +x scripts/check-legacy-names.sh
```

After A7 passes, delete the script as part of the final state.md update commit:

```bash
git rm scripts/check-legacy-names.sh
```

### A7. Verification

Phase A is done when **all** of the following pass:

1. `ios_example_app` builds cleanly via `mcp__XcodeBuildMCP__build_run_device` (physical iPad or Mac "Designed for iPad" — never simulator, per CLAUDE.md §6).
2. Complete CameraKit test suite (Stages 01–12) runs and passes via `mcp__XcodeBuildMCP__test_device` with scheme `ios_example_app`. Tests compile only via Xcode `ios_example_appTests` (no SPM `.testTarget`). Stage08CannyTests builds and runs — proves the C++ scaffolding A2.1+A2.2 moved correctly.
3. `scripts/stage-preflight.sh` exits 0 against renamed structure (state.md ↔ source slug coherence, CONTRACTS.md freshness, build success).
4. `swiftlint lint --config .swiftlint.yml` is clean (with renamed type-name exclusion patterns from A2.3).
5. Pre-commit hooks (swift-format `--strict`, contracts regen) pass on a representative commit. `scripts/regen-contracts.sh` exits 0; CONTRACTS.md up-to-date.
6. `camerakit-only` branch on `origin` still present (`git ls-remote origin camerakit-only` returns SHA); `.githooks/pre-push` gone (`ls -la .githooks/` empty or sentinel-only).
7. **Scratch-consumption test.** A scratch downstream Swift package outside this repo resolves `.package(url: "<this repo>", branch: "flutter-monorepo-restructure")` and successfully:
   (a) `import CameraKit` — basic product resolves.
   (b) `import CameraKitInterop` — C++-interop product resolves (consumer target needs `.interoperabilityMode(.Cxx)`).
   (c) Instantiates something that triggers a shader load (e.g., `MetalPipeline`) — proves `resources: [.process("Shaders")]` survived the `path:` rewrite.
   (d) Calls into `CameraKitCxx` headers — proves `publicHeadersPath: "include"` resolves through the new target `path:`.
   Trial dep is NOT committed.
8. **Info.plist verification.** PlistBuddy verifies the built `ios_example_app.app/Info.plist` contains:
   - `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription` (from `INFOPLIST_KEY_*` build settings — Xcode silently drops some keys on first build after target renames; memory: `project_xcode_infoplist_key_quirk`)
   - `UIFileSharingEnabled`, `UIRequiresFullScreen`, landscape orientation keys (from `ios_example_app/ios_example_app/Info.plist`, located via `INFOPLIST_FILE`)
   ```bash
   /usr/libexec/PlistBuddy -c "Print" "$BUILT_APP/Info.plist" | \
     grep -E 'NSCameraUsageDescription|NSPhotoLibraryAddUsageDescription|UIFileSharingEnabled|UIRequiresFullScreen|UISupportedInterfaceOrientations'
   ```
   Must return all five.
9. **LSP / sourcekit-lsp verification.** `buildServer.json` at repo root (not in `ios_example_app/`). `scripts/lsp-symbol.sh outline CameraKit/Sources/CameraKit/CameraEngine.swift` returns non-empty.
10. After A5b, `git remote -v` shows new URL; `git push origin flutter-monorepo-restructure` succeeds.
11. **`state.md` update with pinned minimum content:**
    ```markdown
    ## Restructure 2026-05-20 — Flutter monorepo
    - Package.swift moved to repo root; CameraKit/Package.swift deleted; .testTarget dropped (see spec).
    - eva-swift-stitch renamed to ios_example_app (project, scheme, targets, source dirs, bundle ID).
    - docs/measurements/ moved to docs/docs/measurements/.
    - flutter/ scaffolded (placeholder README; Phase B will populate).
    - .githooks/pre-push deleted; camerakit-only branch on origin frozen.
    - Phase 3 plans + spec archived to docs/superpowers/{plans,specs}/archive/.
    - GitHub repo renamed: eva-swift-stitch → cambrian-ios-camera.
    - Verifications 1–10 of spec A7 all passed (date, commit SHA).
    ```
    Implementer fills in date + SHA.
12. Repo-wide grep returns ONLY historical refs in append-only logs and archived specs:
    ```bash
    grep -rn 'eva-swift-stitch\|eva_swift_stitch' \
      --exclude-dir=.git --exclude-dir=implementation .
    # Allowed: docs/superpowers/{plans,specs}/archive/*, CameraKit/state.md, CameraKit/DECISIONS.md.
    # No source files, no scripts, no live docs.
    ```
13. `Package.resolved` (if present) committed with swift-atomics version pinned. Likely at repo root or `ios_example_app/ios_example_app.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
14. **`swift test` from repo root produces the `SPMTestStub` `#error`**, not a generic compilation error. (`swift test 2>&1 | grep 'CameraKit tests cannot run'` matches.)
15. **`scripts/check-legacy-names.sh` exits 0.** After this passes, delete the script as part of A7's final commit.

---

## Future cleanup — explicit gates and deferred work

### Merge gate (before merging `flutter-monorepo-restructure` → `main`)

- **`camerakit-only` branch on `origin`.** Recommendation: `git push origin --delete camerakit-only` at merge time (no derivation mechanism keeps it fresh post-merge; becomes a stale fossil). Document the decision in the merge commit/PR.
- **`.githooks/` directory.** A5 deleted only `pre-push`. Directory survives; `git config core.hooksPath .githooks` is per-developer and remains a no-op if directory empty. No action.

### Deferred: Swift package rename `CameraKit` → `CambrianCamera`

Deferred because the rename is pervasive (every `import CameraKit`, all target/product names, source-dir + test-dir names, refs in CONTRACTS.md, state.md, CLAUDE.md, scripts, downstream docs). Doing it concurrently with Phase A inflates the diff. Real problems being deferred: (a) Snap Inc. ships a public "CameraKit" SDK in our exact domain (mobile camera SDKs) — naming collision; (b) the name is the un-branded surface in an otherwise-branded repo.

Concrete rename when done:

| Old | New |
|---|---|
| Package name | `CameraKit` | `CambrianCamera` |
| Targets | `CameraKit`, `CameraKitInterop`, `CameraKitCxx` | `CambrianCamera`, `CambrianCameraInterop`, `CambrianCameraCxx` |
| Test target | `CameraKitTests` | `CambrianCameraTests` |
| Source directory | `CameraKit/` | `CambrianCamera/` |
| Source subdirs | `CameraKit/Sources/CameraKit{,Interop,Cxx}/` | `CambrianCamera/Sources/CambrianCamera{,Interop,Cxx}/` |
| Test subdir | `CameraKit/Tests/CameraKitTests/` | `CambrianCamera/Tests/CambrianCameraTests/` |
| Imports | `import CameraKit{,Interop}` | `import CambrianCamera{,Interop}` |

Not renamed even then: upstream `implementation/` symlinks (read-only briefs use `CameraKit` as proper noun); historical entries in `state.md`, `CameraKit/DECISIONS.md`; git history.

Out of scope for Phase A; NOT in A7. Track as future TODO with its own spec/plan.

---

## Locked Phase A → B decisions — Flutter example app + plugin constraints

The native dev-harness app (`ios_example_app/`) keeps the existing OpenCV/Canny demo (its `AppCxx/` directory + the `Frameworks/opencv2.xcframework` symlink). CameraKit is consumer-agnostic; the Canny consumer lives in the app.

**Flutter example app (Phase B inherits as constraint):**

- **Lean.** ONE preview stream: the **processed lane** (after CameraKit's Metal shader passes). No natural-lane preview, no side-by-side, no Canny overlay.
- **No C++ consumer.** No `AppCxx/`-equivalent inside `flutter/example/ios/Runner/`. No bridging header, no `.cpp` files.
- **No OpenCV.** No `opencv2.xcframework` link from `flutter/example/`'s pbxproj.

**Hard invariant Phase B inherits:** neither the plugin (`flutter/ios/cambrian_ios_camera/`) nor CameraKit itself links OpenCV. OpenCV stays consumer-side.

**Other Phase B constraints (not open design questions):**

1. **Relative-path SPM dep from plugin to CameraKit.** `flutter/ios/cambrian_ios_camera/Package.swift` uses `.package(path: "../../..")`. Forces co-checkout + joint versioning.
2. **Joint git-tag versioning.** Single `v1.0.0` tag = both Swift package and Flutter plugin at v1.0.0 simultaneously. Changing requires amendment to this spec.
3. **`flutter/ios/<plugin_name>/` SPM layout** per Flutter convention.
4. **Pigeon vocabulary inherited from Phase 2 CameraKit public surface** (`setProcessingParams`, `OpenConfiguration.initialSettings`, capability ranges, `streamConfigurationStream`, `currentPixelBuffer(stream:)`, `cameraPermissionStatus`/`requestCameraPermission`, `SessionState.interrupted`, `calibrateWhiteBalance`/`calibrateBlackBalance` returning `CalibrationResult { before, after, converged, iterations }`). Each plugin's Pigeon is independently maintained — no shared interface package with cam2fd.

---

## Versioning

Single version tag for both Swift and Flutter consumers. Swift: `.package(url: ..., from: "1.0.0")`. Flutter: `git: { url: ..., ref: "v1.0.0" }`. Trade-off: can't ship CameraKit-only fix without tagging the plugin (consistent with tight-coupling requirement). If independent versioning later needed, introduce `camerakit-v1.4` / `flutter-v0.2` tag families.

Tags pushed via `git push origin <tag>`. No synthetic-branch propagation (hook deleted).

---

## Risks and mitigations

Real ongoing risks the plan execution might still hit:

| Risk | Mitigation |
|---|---|
| Xcode project rename breaks code-signing / provisioning profile resolution. | `xcodeproj` gem (A2.1); bundle ID via Xcode automatic signing on first build OR `fastlane match` (A2.4). A7.1 catches failure. |
| Apple Developer portal must register new bundle ID before first build (user step). | User-driven Xcode sign-in OR manual registration at developer.apple.com (A2.4). |
| Path moves break `state.md` ↔ source slug coherence checks. | `scripts/stage-preflight.sh` (A7.3). Source files don't move. |
| `swift test` against package fails after dropping `.testTarget`. | `SPMTestStub` `#error` reports a useful message instead. A7.14 verifies. |
| `buildServer.json` regenerated from wrong CWD becomes unreachable from `CameraKit/Sources/`. | A2.7 specifies CWD = repo root; A7.9 verifies. Each developer regenerates locally (gitignored). |
| Single-commit rename loses git history if rename detection fails. | A2.1+A2.2 staged together; `--find-renames=30%` works because content-similarity stays above threshold. |
| GitHub repo rename invalidates external links / clones. | GitHub auto-redirects indefinitely. A5b sweeps literal old URLs. |
| Preserving `CameraKit` package name — Snap-SDK naming collision. | Discoverability/branding only; package imports cleanly. Resolved in deferred rename. |

---

## Implementation order summary

| Step | Action | Owner |
|---|---|---|
| A0 | Tag current `main` as `pre-restructure-2026-05-20` | Coordinator |
| A1 | Create root `Package.swift` (no real `.testTarget`; `SPMTestStub` instead); delete `CameraKit/Package.swift`. No build verification in A1. | Coordinator |
| A2 | Eight sub-parts (A2.1–A2.8): pbxproj surgery via xcodeproj gem; single-commit filesystem moves (incl. `AppCxx/`, `Frameworks/` symlink); Swift source renames; bundle ID change + Apple Dev console step; `CameraKit.xcscheme` deletion + remaining scheme rename; `scripts/` sweep; `buildServer.json` at repo root; fastlane sweep. Then build verification. | Coordinator + subagent |
| A3 | Move `docs/measurements/` → `docs/docs/measurements/`; exhaustive path-ref sweep | Coordinator |
| A4 | Scaffold `flutter/` placeholder README + root `README.md` | Coordinator |
| A5 | Delete `.githooks/pre-push`. Leave `camerakit-only` branch on origin alone | Coordinator |
| A5b | User renames GitHub repo to `cambrian-ios-camera`; update local remote URL | User + Coordinator |
| A6 | Archive Phase 3 plans + spec to `docs/superpowers/{plans,specs}/archive/`; rewrite affected CLAUDE.md sections | Coordinator + subagent |
| A7 | Create one-time `scripts/check-legacy-names.sh` (A7.0); run 15-check verification suite; update `state.md`; delete helper script in the final commit | Coordinator |

Each step is small, individually committable, reversible against the A0 tag. Detailed implementation plan in follow-up `2026-05-20-flutter-plugin-monorepo-plan.md`.
