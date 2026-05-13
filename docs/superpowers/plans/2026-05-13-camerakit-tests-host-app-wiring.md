# Wire CameraKitTests as App-Hosted (without losing extractability)

> **Status:** Plan only. No code changes here. To execute, route to
> `superpowers:executing-plans` in a fresh session.

**Goal:** Make `CameraKit/Tests/CameraKitTests/*.swift` actually run via
`xcodebuild test` on the physical iPad, *without* moving the test files
out of the package and *without* breaking the long-term plan to extract
CameraKit into its own repo for use by a Flutter plugin and a stitching
app. The test source files keep living inside the package; we add an
*Xcode-side* test target that compiles the same files with the
`eva-swift-stitch` app as the test host.

The 13 swift-testing tests we wrote in `1470cdc`
(`PhotosLibraryClientTests.swift`) plus the pre-existing Stage07 / Stage10
/ Stage11 suites all start running automatically once this lands. Bug-14
stop-promptness becomes a CI-grade guardrail. CLAUDE.md §8's "tests are
blocked" entry retires.

## Context — why is this a separate workstream

Three constraints collide today:

1. **CLAUDE.md §6 forbids iOS simulators on this machine** (memory).
   Hard rule. Builds and tests must target physical iPad or Mac
   "Designed for iPad."
2. **iOS forbids tool-hosted tests on physical devices.** `xcodebuild
   test` against a tool-hosted target on a `platform=iOS,id=…`
   destination fails with `Tool-hosted testing is unavailable on
   device destinations`.
3. **`CameraKit` is declared as a Swift Package** (`CameraKit/Package.swift`),
   and the `.testTarget(name: "CameraKitTests", …)` declaration there
   produces a tool-hosted test bundle by default. SwiftPM doesn't know
   about Xcode app targets, so it can't make the test bundle app-hosted
   on its own.

Result: every test we've written in `CameraKit/Tests/CameraKitTests/` is
unrunnable on the only device we're allowed to test on. CLAUDE.md §8
documented this as a known blocker rather than fixing it; this plan is
the fix.

The existing `eva-swift-stitchTests/` Xcode target is *already* app-hosted
(`TEST_HOST = $(BUILT_PRODUCTS_DIR)/eva-swift-stitch.app/…/eva-swift-stitch`)
but contains only a single 1.2 KB Xcode template stub
(`eva_swift_stitchTests.swift`, two empty `testExample` /
`testPerformanceExample` methods, never edited since project scaffold on
2026-04-14). It tests nothing today. We can repurpose it to compile the
package's test files directly — no new target needed.

## Why we are NOT moving the test files into `eva-swift-stitchTests/`

The naive fix would be `git mv CameraKit/Tests/CameraKitTests/*.swift
eva-swift-stitchTests/` and delete the `.testTarget` declaration. That
works today but breaks the long-term plan:

- CameraKit is intended to be **extracted** into its own repo and consumed
  by (a) a Flutter plugin wrapping it for cross-platform iOS use and
  (b) a future stitching app. Both consumers should pull tests in with
  the package — that's the whole point of `Tests/<TargetName>/` living
  inside the package directory.
- If we move tests out, the package becomes testless, and at extraction
  time we'd have to move them back. Net friction.

The dual-membership pattern (below) keeps tests inside the package while
giving Xcode a way to compile and host them today.

## The dual-membership pattern

Each `.swift` test file in `CameraKit/Tests/CameraKitTests/` is referenced
by **two** compilation units:

1. **The package's `.testTarget`** in `CameraKit/Package.swift`. SwiftPM
   auto-discovers any `.swift` file in `Tests/CameraKitTests/`. This
   testTarget is the package's portability contract — when the package
   is extracted, this is what travels with it. It produces a tool-hosted
   bundle. It's only runnable on macOS / simulators (neither of which we
   use here), so in practice it's a static contract, not an everyday
   runner.

2. **The `eva-swift-stitchTests` Xcode target** in
   `eva-swift-stitch.xcodeproj`. We add explicit per-file references
   pointing at `CameraKit/Tests/CameraKitTests/Stage07Tests.swift` etc.
   from a virtual group inside the project. The target is already
   app-hosted via `TEST_HOST`. This is what `xcodebuild test` runs on
   the physical iPad.

Same files, two compilations, two bundle outputs. The build settings
differ (the Xcode target needs Swift 6 + C++ interop matching the
package's testTarget), but the source code is identical.

When CameraKit is extracted later:
- `CameraKit/` (with `Sources/`, `Tests/`, `Package.swift`) becomes its
  own repo. Tests travel with it.
- The OLD `eva-swift-stitch.xcodeproj` will have dangling path references
  to the now-moved files. ~10 minutes of cleanup at extraction time:
  either update the paths to the new package's downloaded location, or
  remove the references and accept that this app no longer runs the
  package's tests directly.
- New consumers (Flutter plugin, stitching app) decide for themselves
  whether to set up their own equivalent Xcode wrapper for device runs.

This is the standard library-vs-consumer split. Big iOS SDKs (Firebase,
Lottie, etc.) all do something similar.

## Files to modify

1. **`eva-swift-stitch.xcodeproj/project.pbxproj`** — add file
   references for each existing test source under
   `CameraKit/Tests/CameraKitTests/`, add them to
   `eva-swift-stitchTests`'s Sources build phase, link the CameraKit
   package product so `@testable import CameraKit` resolves. Use the
   `xcodeproj` Ruby gem (CLAUDE.md §6 — never hand-edit `.pbxproj`).

2. **NEW: `scripts/sync-test-target.sh`** — small bash wrapper that
   re-runs the dual-membership wiring. Reads
   `CameraKit/Tests/CameraKitTests/*.swift` and adds any missing files
   to `eva-swift-stitchTests`'s compile sources. Idempotent. Run after
   adding a new test file in a future stage.

3. **`CLAUDE.md`** — update §8 invariant ("Tests use a host app, not
   tool-hosted"). Replace the "tests are blocked" wording with the new
   pattern: "tests live in `CameraKit/Tests/CameraKitTests/` and are
   compiled by both the SwiftPM testTarget and the dual-membership
   Xcode `eva-swift-stitchTests` target. Run via `xcodebuild test
   -scheme eva-swift-stitch -only-testing:eva-swift-stitchTests/<Suite>`
   on the physical iPad. To add a new test file, create it in the
   package directory then run `scripts/sync-test-target.sh`."
   Update §6 wrapper-script table to point at the app scheme for tests.

4. **`scripts/test-summary.sh`** — change the default `SCHEME` from
   `CameraKit` to `eva-swift-stitch` so the wrapper picks up the
   newly-runnable test path. Adjust the helpful error messages.

5. **(Optional cleanup)** — delete `eva-swift-stitchTests/eva_swift_stitchTests.swift`
   and the two `eva-swift-stitchUITests/*.swift` template stubs. They
   assert nothing and clutter test-runner output. Or keep them; they're
   harmless. Beginner-friendly note: if you delete `eva_swift_stitchTests.swift`
   you must also remove its file reference from the
   `eva-swift-stitchTests` target's Sources build phase via the
   `xcodeproj` gem, otherwise `xcodebuild` complains about the missing
   file.

## Implementation outline

### Pre-flight (do every time before editing)

```bash
# Confirm current state of the test target
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
t = p.targets.find { |x| x.name == 'eva-swift-stitchTests' }
puts \"TEST_HOST: #{t.build_configurations.first.build_settings['TEST_HOST']}\"
puts \"Source files:\"
t.source_build_phase.files.each { |f| puts \"  - #{f.file_ref&.path}\" }
puts \"Package deps:\"
t.package_product_dependencies.each { |d| puts \"  - #{d.product_name}\" }"

# Inventory what we need to add
ls CameraKit/Tests/CameraKitTests/*.swift
```

Expected today: TEST_HOST is set; source files lists only
`eva_swift_stitchTests.swift`; no package deps; four `.swift` files
visible in the package's test directory (Stage07Tests, Stage10Tests,
Stage11Tests, PhotosLibraryClientTests).

### Step 1: ruby script that adds the test files

Write inline (no permanent script — that's step 2):

```ruby
require 'xcodeproj'

PROJECT = 'eva-swift-stitch.xcodeproj'
TEST_TARGET_NAME = 'eva-swift-stitchTests'
APP_TARGET_NAME = 'eva-swift-stitch'
SOURCE_DIR = 'CameraKit/Tests/CameraKitTests'   # relative to project root
GROUP_NAME = 'CameraKitTests'

project = Xcodeproj::Project.open(PROJECT)
test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }
app_target  = project.targets.find { |t| t.name == APP_TARGET_NAME }

# 1. Create or reuse a project-tree group whose physical path is the
#    package's Tests directory. Files added below are referenced by name
#    only; the group resolves them via its path.
group = project.main_group[GROUP_NAME]
unless group
  group = project.main_group.new_group(GROUP_NAME, SOURCE_DIR)
end

# 2. Add each .swift file to the group AND to the test target's source
#    build phase. Skip files already wired (idempotent).
existing_paths = test_target.source_build_phase.files
                            .map { |f| f.file_ref&.real_path&.to_s }
                            .compact
Dir.glob("#{SOURCE_DIR}/*.swift").sort.each do |path|
  filename = File.basename(path)
  ref = group.files.find { |f| f.path == filename } ||
        group.new_reference(filename)
  abs = File.expand_path(path)
  next if existing_paths.include?(abs)
  test_target.source_build_phase.add_file_reference(ref)
end

# 3. Add the CameraKit package product as a dependency of the test
#    target. The app already depends on it; we mirror that.
#    PER CLAUDE.md §8 LOAD-BEARING INVARIANT: SPM package products use
#    product_ref, NOT file_ref. The two-step pattern below is the only
#    one that works.
camerakit_dep = app_target.package_product_dependencies
                          .find { |d| d.product_name == 'CameraKit' }
unless camerakit_dep
  abort "CameraKit package product not found on app target; aborting."
end
unless test_target.package_product_dependencies
                  .any? { |d| d.product_name == 'CameraKit' }
  test_target.package_product_dependencies << camerakit_dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = camerakit_dep
  test_target.frameworks_build_phase.files << bf
end

# 4. Match the package's testTarget Swift settings on the Xcode target.
#    Critical: SWIFT_VERSION must be 6.0+ and the test target must use
#    the same C++ interop mode as the package, otherwise @testable import
#    won't resolve generic-context types.
test_target.build_configurations.each do |cfg|
  cfg.build_settings['SWIFT_VERSION'] = '6.0'
  cfg.build_settings['SWIFT_OBJC_INTEROP_MODE'] = 'objcxx'  # C++ interop
  cfg.build_settings['ENABLE_TESTABILITY'] = 'YES'
end

project.save
puts "Wiring done. Run xcodebuild build-for-testing to verify."
```

Run it once. Confirm via the pre-flight script that source files now
include the four CameraKit test files.

### Step 2: persist the script as `scripts/sync-test-target.sh`

```bash
#!/usr/bin/env bash
# sync-test-target.sh — re-run dual-membership wiring for CameraKitTests.
#
# Idempotent: any new .swift file in CameraKit/Tests/CameraKitTests/
# is added to eva-swift-stitchTests' compile sources. Existing files
# are left alone.
#
# Run after adding a new test file in a future stage.
set -euo pipefail
ruby -e '<paste step-1 ruby here>'
```

`chmod +x scripts/sync-test-target.sh`. Commit it alongside the .pbxproj
change so future contributors can re-sync without re-deriving the script.

### Step 3: build-for-testing verification

Use the wrapper-script fallback path; XcodeBuildMCP doesn't have a
build-for-testing tool surfaced today.

```bash
# Build for testing on physical iPad. This compiles the test bundle
# and packages it with the app, but does not run any tests yet.
xcodebuild -project eva-swift-stitch.xcodeproj \
  -scheme eva-swift-stitch \
  -destination "platform=iOS,id=00008027-000539EA0184402E" \
  build-for-testing > /tmp/bfor-test.log 2>&1
echo "EXIT=$?"
tail -20 /tmp/bfor-test.log
```

Expected: `BUILD SUCCEEDED`. Any Swift compile errors against the
CameraKit test files mean the package-product dep or interop mode isn't
right; re-check step 1.

### Step 4: run the PhotosLibraryClient tests on iPad

```bash
mcp__XcodeBuildMCP__test_device   # via session_set_defaults scheme=eva-swift-stitch
# or wrapper:
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/PhotosLibraryClientResolveTests
```

Expected: 6 tests pass. None should require physical hardware (resolve
is pure FileManager + URL).

Then expand to all four suites:

```bash
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/PhotosLibraryClientResolveTests
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/PhotosLibraryClientDescribeTests
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/RecordingPhotosDestinationTests
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/Stage10
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/Stage11
scripts/test-summary.sh --scheme eva-swift-stitch \
  --filter eva-swift-stitchTests/Stage07
```

Some Stage07 / Stage11 tests may have device-only dependencies (Metal,
camera) — note any failures and decide whether to fix in this plan or
log as Stage 12+ work. The PhotosLibraryClient + RecordingPhotos suites
should pass cleanly.

### Step 5: documentation updates

- `CLAUDE.md` §8: rewrite the "Tests use a host app, not tool-hosted"
  bullet. New text emphasises the dual-membership pattern, the
  `scripts/sync-test-target.sh` workflow for adding new test files,
  and the canonical run command.
- `CLAUDE.md` §6 toolchain table: change "Run CameraKit or app tests"
  row to reference the `eva-swift-stitch` scheme.
- `CameraKit/state.md`: add Decision #63 documenting the dual-membership
  decision, the rationale (long-term extractability), and the
  consequences (extraction-time cleanup of dangling Xcode references in
  the OLD project).
- `docs/superpowers/plans/2026-05-13-error-surfacing-followups.md`: no
  change; the host-app gap there is independent of test infrastructure.

## Risks and gotchas

- **`@testable import CameraKit` may fail at first build.** The Xcode
  test target needs `ENABLE_TESTABILITY=YES` (set in step 1) AND the
  CameraKit package product needs to have been built with the same
  flag. Xcode usually does this for the test build action automatically,
  but SwiftPM packages have been known to ignore it in older Xcode
  versions. If you see "module is not testable" errors, also set
  `ENABLE_TESTABILITY=YES` on the CameraKit target via Package.swift's
  `swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]`
  — but **only if needed**, since `unsafeFlags` blocks SwiftPM
  publication. First try without.

- **C++ interop mode mismatch.** The package's testTarget declares
  `.interoperabilityMode(.Cxx)` because it imports `CameraKitInterop`.
  The Xcode test target must match (`SWIFT_OBJC_INTEROP_MODE = objcxx`).
  Step 1 sets this; verify in the resulting build settings if errors
  appear during build-for-testing.

- **Duplicate symbol risk if both bundles are in the same scheme's test
  action.** If a future scheme accidentally lists both the SwiftPM
  CameraKitTests bundle AND the new Xcode-side dual-membership bundle,
  swift-testing's runtime registration may collide. Mitigation: only
  the `eva-swift-stitch` scheme runs tests; the `CameraKit` scheme's
  test action stays empty (or runs nothing). Verify schemes after
  step 1.

- **Build time grows slightly.** Each test file is now compiled twice
  per `swift build` + `xcodebuild build-for-testing` cycle. In practice
  ~5-10 seconds extra per full test build. Acceptable.

- **Stage07Tests has known pre-existing format violations** auto-fixed
  during Piece 2. Nothing in this plan touches them; they should
  compile clean. If they fail under the Xcode target's stricter rules
  (e.g. missing `@testable` access for some symbol), surface that as a
  separate diagnostic, not a plan-execution failure.

- **Auto-cleanup of Stage07's `authorizationProvider` reference.**
  Already done in commit `f9719fc` — non-issue.

- **HITL is not required for this plan.** All verification is `xcodebuild
  test` exit codes against the iPad. No manual UI interaction needed.

## Definition of done

- ✅ `xcodebuild test -scheme eva-swift-stitch -only-testing:eva-swift-stitchTests/PhotosLibraryClientResolveTests -destination "platform=iOS,id=00008027-000539EA0184402E"` exits 0; all 6 cases pass.
- ✅ `xcodebuild test -scheme eva-swift-stitch -only-testing:eva-swift-stitchTests/PhotosLibraryClientDescribeTests …` exits 0; all 6 cases pass.
- ✅ `xcodebuild test -scheme eva-swift-stitch -only-testing:eva-swift-stitchTests/RecordingPhotosDestinationTests …` exits 0; all 4 cases pass.
- ✅ `scripts/sync-test-target.sh` exists, is `chmod +x`, idempotent. Re-running it on a clean tree is a no-op.
- ✅ `CLAUDE.md` §8 + §6 updated; `state.md` Decision #63 added.
- ✅ `Package.swift`'s `.testTarget(name: "CameraKitTests", ...)` declaration is **untouched**. `git diff Package.swift` is empty after this work.
- 🟡 Pre-existing Stage07 / Stage10 / Stage11 suites: any that fail under the new wrapper are diagnosed, but **fixing them is NOT in this plan's scope**. Document failures in state.md as Stage 12+ work and move on.

## Out of scope

- **CameraEngine test harness.** Building protocol abstractions over
  MetalPipeline / StillCapture / etc. so engine-level tests can run
  without a real camera. Multi-stage refactor; separate workstream.
- **Mac "Designed for iPad" signing fix.** Test runs on Mac currently
  fail at provisioning ("profile doesn't include the currently selected
  device 'macpro'"). Not blocking iPad-based testing; address only if
  Mac runs become useful.
- **Removing the SwiftPM `.testTarget`.** Would break the package's
  extractability contract. Keep it.
- **Host-app error stream UI.** Tracked in
  `docs/superpowers/plans/2026-05-13-error-surfacing-followups.md`.
- **Extracting CameraKit to its own repo.** Future work; this plan
  prepares the ground (tests stay inside the package) but doesn't
  trigger the move.
- **Migrating XCTest stubs to swift-testing.** The empty
  `eva_swift_stitchTests.swift` and the two UITest stubs can be deleted
  (optional step in §Files to modify); migrating them isn't valuable.

## Estimated effort

- Step 1 (ruby script run): 10 min including iteration on any errors.
- Step 2 (persist sync script): 5 min.
- Step 3 (build-for-testing verify): 10 min including any compile-error
  fixup.
- Step 4 (run all four suites): 20 min including triage of any
  pre-existing test failures.
- Step 5 (docs): 15 min.
- One commit for the .pbxproj + script + CLAUDE.md edits, one commit
  for any stage-NN test fixups if needed.

Total: ~1 hour for an experienced executor; ~2 hours for a beginner.
No HITL required. Single fresh session.

## After this lands

- The 13 PhotosLibraryClient tests start gating regressions automatically.
- Adding a new test file in a future stage becomes:
  `touch CameraKit/Tests/CameraKitTests/Stage12NewThingTests.swift &&
  scripts/sync-test-target.sh && git add ...`
- CLAUDE.md §8's "Tests use a host app, not tool-hosted" invariant
  becomes a *positive* statement of how things work, not a known-issue
  workaround.
- The recording-output-visibility plan's "🟡 Stage10Tests suite —
  pre-existing CameraKitTests host-app wiring blocks `xcodebuild test`"
  caveat resolves; you can run those tests for real.
- You're closer to extractability: the package's test contract is intact,
  and the only outside-the-package piece of test infrastructure is the
  per-app Xcode wrapper, which is exactly what each future consumer
  (Flutter plugin, stitching app) will set up for themselves anyway.
