# Phase 1A — UI Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate CameraKit's SwiftUI surface (10 source files + 5 UI-coupled test suites) out of the `CameraKit` SwiftPM package and into the `eva-swift-stitch` app target so the package builds with zero SwiftUI imports, while every existing test keeps passing on device.

**Architecture:** Pure file relocation gated by three small enabling edits, then physical moves wired through `xcodeproj`, then test split. The three enabling edits are:
1. Promote three `internal` `CameraEngine` helpers (`setGate`, `drainSubmittedFrame`, `dumpDeviceFormats`) to `public` — the relocated `ViewModel` still calls them cross-module.
2. Inline `Constants.wbCompletedDisplayMs` (a UI display-timing constant) into `CalibrationViewModel.swift` so `Constants` itself stays `internal`.
3. Temporarily export `CameraKitInterop` as a package product so the relocated `DisplayViewModel` (which uses `CppCannyStub` for the DEBUG Canny edge-count overlay) can `import CameraKitInterop` from the app target. Phase 1B will un-export it.

The 10 files keep their content; only `import CameraKit` is added at the top (and `import CameraKitInterop` is preserved for `DisplayViewModel`). `Stage11Tests.swift` is **split**: 4 suites that test CameraKit internals (`MetalPipeline`, `SettingsPersistence`, `Constants`, `MetalError`) stay dual-membered in the package test directory; 5 UI-coupled suites move to a new `Stage11UITests.swift` in the app-test-target's group (single-target).

**Tech stack:** Swift 6.0 strict concurrency, iOS 26, SwiftPM local package consumed by `eva-swift-stitch.xcodeproj`, `xcodeproj` Ruby gem for project edits, XcodeBuildMCP for all builds and tests on a physical iPad. **No simulators on this machine** (CLAUDE.md §6).

**Reference reading before starting:**
- `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` §§ Phase 1A and 2e (harness-only surface)
- `CLAUDE.md` §§4–8 (scaffold convention, target shape, common operations, coordinator discipline, load-bearing invariants — especially §8 dual-membership rules and §6 device-only destination order)
- `CameraKit/state.md` (current stage, post-Stage-12)
- `CameraKit/CONTRACTS.md` (current public surface — auto-generated; read first per CLAUDE.md §6.1)

**Hard rule: never use iOS simulators.** Every build/test must target a physical iPad via XcodeBuildMCP `*_device` tools, with Mac "Designed for iPad" as fallback. Fail with an explicit error otherwise.

---

## File map

**Files modified:**
- `CameraKit/Sources/CameraKit/CameraEngine.swift` (3 `public` promotions at lines 575, 1123, 1131)
- `CameraKit/Sources/CameraKit/Constants.swift` (remove `wbCompletedDisplayMs`)
- `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` (inline `wbCompletedDisplayMs`; later relocated)
- `CameraKit/Package.swift` (add `CameraKitInterop` library product)
- `eva-swift-stitch.xcodeproj/project.pbxproj` (group + target + source-build-phase wiring; never hand-edit — use the `xcodeproj` gem)
- `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` (trim to 4 internals suites + helpers used only by them)
- `CameraKit/state.md` (record Phase 1A landing)
- `CameraKit/DECISIONS.md` (rationale entries)

**Files moved (with `git mv`, then `import CameraKit` added at top):**

| From | To |
|---|---|
| `CameraKit/Sources/CameraKit/CameraView.swift` | `eva-swift-stitch/UI/CameraView.swift` |
| `CameraKit/Sources/CameraKit/ViewModel.swift` | `eva-swift-stitch/UI/ViewModel.swift` |
| `CameraKit/Sources/CameraKit/DisplayViewModel.swift` | `eva-swift-stitch/UI/DisplayViewModel.swift` |
| `CameraKit/Sources/CameraKit/RecordingViewModel.swift` | `eva-swift-stitch/UI/RecordingViewModel.swift` |
| `CameraKit/Sources/CameraKit/HardwareControlsViewModel.swift` | `eva-swift-stitch/UI/HardwareControlsViewModel.swift` |
| `CameraKit/Sources/CameraKit/ProcessingViewModel.swift` | `eva-swift-stitch/UI/ProcessingViewModel.swift` |
| `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` | `eva-swift-stitch/UI/CalibrationViewModel.swift` |
| `CameraKit/Sources/CameraKit/ErrorPresenterViewModel.swift` | `eva-swift-stitch/UI/ErrorPresenterViewModel.swift` |
| `CameraKit/Sources/CameraKit/ControlEnablement.swift` | `eva-swift-stitch/UI/ControlEnablement.swift` |
| `CameraKit/Sources/CameraKit/SliderDebouncer.swift` | `eva-swift-stitch/UI/SliderDebouncer.swift` |

**Files created:**
- `eva-swift-stitch/UI/` (directory)
- `eva-swift-stitchTests/Stage11UITests.swift` (5 UI suites extracted from Stage11Tests.swift)

**Files unchanged (verify with `grep`):**
- `eva-swift-stitch/eva_swift_stitchApp.swift` — already does `CameraView()`; the entry point itself does not change. `import CameraKit` stays (still needed for `CameraKitLog`, `OrientationLock`).
- `CameraKit/Tests/CameraKitTests/Stage10Tests.swift` — its "single UI reference" turned out to be a doc-comment mentioning `RecordingViewModel` at line 366; no code coupling, nothing to split.
- `scripts/sync-test-target.sh` — re-run as-is for the trimmed `Stage11Tests.swift`; not used for the new app-test-target file.

---

## Pre-task — orientation (REQUIRED before Task 1)

- [ ] **Read every file listed under "Modify" above before writing any of them.** Per CLAUDE.md §6.1, `CameraKit/CONTRACTS.md` is first.
  - `cat CameraKit/CONTRACTS.md` (or `Read` it via the tool — it is large, ~70 KB)
  - `Read` `CameraKit/Sources/CameraKit/CameraEngine.swift` around lines 575, 1123, 1131 (and the surrounding context for each — the surrounding doc comments inform the `public` promotion)
  - `Read` `CameraKit/Sources/CameraKit/Constants.swift` fully (134 lines)
  - `Read` `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` fully (205 lines)
  - `Read` `CameraKit/Package.swift` fully (it's short)
  - `Read` `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` fully (754 lines) — this drives Task 7

- [ ] **Confirm working tree is clean and stage-preflight passes.**

  ```bash
  git status
  ./scripts/stage-preflight.sh
  ```

  Expected: `git status` clean, `stage-preflight.sh` exits 0 reporting "state.md ↔ source coherence OK, CONTRACTS.md fresh, build succeeded."

- [ ] **Create a branch for the migration.**

  ```bash
  git checkout -b migration/phase-1a-ui-decoupling
  ```

---

## Task 1: Promote three `CameraEngine` helpers to `public`

**Why:** `ViewModel.swift` (which moves to the app target in Task 6) calls `engine.dumpDeviceFormats()` (line 575), `engine.setGate(_:)` (line 1123), and `engine.drainSubmittedFrame()` (line 1131). All three are currently `internal` (Swift's default — no access modifier shown). Cross-module access fails after the move; promote first so the package still compiles green before any file moves.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift` lines 575, 1123, 1131

- [ ] **Step 1: Edit line 575 — `dumpDeviceFormats`.**

  Replace:

  ```swift
  func dumpDeviceFormats() async -> [String] {
  ```

  With:

  ```swift
  public func dumpDeviceFormats() async -> [String] {
  ```

- [ ] **Step 2: Edit line 1123 — `setGate`.**

  Replace:

  ```swift
  func setGate(_ open: Bool) {
  ```

  With:

  ```swift
  public func setGate(_ open: Bool) {
  ```

- [ ] **Step 3: Edit line 1131 — `drainSubmittedFrame`.**

  Replace:

  ```swift
  func drainSubmittedFrame() async {
  ```

  With:

  ```swift
  public func drainSubmittedFrame() async {
  ```

- [ ] **Step 4: Build via XcodeBuildMCP.**

  Verify session defaults first (CLAUDE.md "Simulator run flow"):

  ```
  mcp__XcodeBuildMCP__session_show_defaults
  ```

  Expect `scheme: eva-swift-stitch`, `deviceId: <iPad UDID>`. If unset:

  ```
  mcp__XcodeBuildMCP__session_set_defaults { scheme: "eva-swift-stitch", deviceId: "<udid from xcrun xctrace list devices>" }
  ```

  Then:

  ```
  mcp__XcodeBuildMCP__build_run_device
  ```

  Expected: `BUILD SUCCEEDED` and app launches. No warnings about the three newly-public funcs (they have doc-comments; no new diagnostics).

- [ ] **Step 5: Run the existing test bundle to confirm zero regressions.**

  ```
  mcp__XcodeBuildMCP__test_device
  ```

  Expected: 125 passed / 0 failed (matches `CameraKit/state.md` Stage 12 baseline).

- [ ] **Step 6: Commit.**

  ```bash
  git add CameraKit/Sources/CameraKit/CameraEngine.swift
  git commit -m "refactor(camera-engine): promote setGate/drainSubmittedFrame/dumpDeviceFormats to public

Phase 1A enabling edit. These three helpers are called by ViewModel.swift,
which moves to the app target. Cross-module callers need them public; the
relocation itself happens in a later commit."
  ```

  The pre-commit hook will run `swift-format lint --strict` and regenerate `CONTRACTS.md`. Both must pass; if either fails, fix the underlying issue (CLAUDE.md §7 — never `--no-verify`).

---

## Task 2: Inline `wbCompletedDisplayMs` into `CalibrationViewModel.swift`

**Why:** `Constants.wbCompletedDisplayMs: Int = 1500` is a UI display-timing constant — how long the "Calibrated ✓" badge shows before the sidebar button reverts to idle. Its only caller is `CalibrationViewModel` (which moves). Inlining keeps `Constants` (the package's internal grab-bag) from needing a `public` promotion just for one UI value. Per spec §1A surface-curation note — minimise public surface where avoidable.

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Constants.swift` line 41 (remove)
- Modify: `CameraKit/Sources/CameraKit/CalibrationViewModel.swift` line 123 (use new constant) + add the constant declaration

- [ ] **Step 1: Add a file-private constant at the top of `CalibrationViewModel.swift`.**

  After the `import Foundation` line, before the protocol declaration, add:

  ```swift
  /// How long the Calibrate-WB button shows the "Calibrated ✓" confirmation
  /// before the sidebar button reverts to its idle label. UI display timing —
  /// kept here so `Constants` (a package-internal grab-bag) does not need to
  /// become public for this one UI value. Phase 1A migration: moved from
  /// `Constants.wbCompletedDisplayMs`.
  private let wbCompletedDisplayMs: Int = 1500
  ```

- [ ] **Step 2: Replace the `Constants.wbCompletedDisplayMs` reference at line 123.**

  Edit `CalibrationViewModel.swift` line 123:

  Replace:

  ```swift
                  try? await Task.sleep(for: .milliseconds(Constants.wbCompletedDisplayMs))
  ```

  With:

  ```swift
                  try? await Task.sleep(for: .milliseconds(wbCompletedDisplayMs))
  ```

- [ ] **Step 3: Update the two doc-comments at lines 73 and 96.**

  These reference `wbCompletedDisplayMs` symbolically (not `Constants.wbCompletedDisplayMs`) so they read correctly after the rename. Verify they still read sensibly. Quote the existing text:

  - Line 73: `` /// after `wbCompletedDisplayMs`. ``
  - Line 96: `` /// `.idle` after `wbCompletedDisplayMs`. ``

  Both are fine as-is — leave them.

- [ ] **Step 4: Remove the declaration from `Constants.swift`.**

  In `CameraKit/Sources/CameraKit/Constants.swift`, delete lines 39–41 (the doc comment and the `static let`):

  ```swift
      /// How long the Calibrate-WB button shows the "Calibrated ✓" confirmation
      /// before the sidebar button reverts to its idle label.
      static let wbCompletedDisplayMs: Int = 1500
  ```

- [ ] **Step 5: Verify no other references.**

  ```bash
  grep -rn 'wbCompletedDisplayMs' CameraKit/Sources/ CameraKit/Tests/
  ```

  Expected: exactly 3 hits — the doc-comment at `CalibrationViewModel.swift:73`, the doc-comment at `CalibrationViewModel.swift:96`, and the new declaration + use at lines added in steps 1–2. No hits in `Constants.swift` or anywhere else.

- [ ] **Step 6: Build + tests.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  mcp__XcodeBuildMCP__test_device
  ```

  Expected: BUILD SUCCEEDED; 125 passed.

- [ ] **Step 7: Commit.**

  ```bash
  git add CameraKit/Sources/CameraKit/CalibrationViewModel.swift CameraKit/Sources/CameraKit/Constants.swift
  git commit -m "refactor(constants): inline wbCompletedDisplayMs into CalibrationViewModel

Phase 1A enabling edit. wbCompletedDisplayMs is a UI display-timing
constant used in exactly one place; inlining it removes the need to
promote Constants (a package-internal grab-bag) to public when
CalibrationViewModel relocates to the app target."
  ```

---

## Task 3: Temporarily export `CameraKitInterop` as a SwiftPM product

**Why:** `DisplayViewModel.swift` does `import CameraKitInterop` and uses `CppCannyStub` for the DEBUG Canny edge-count overlay. `CameraKitInterop` is currently a package *target* (no product), so the app target cannot import it. Phase 1B removes the Canny consumer from the package (and from `DisplayViewModel`) and un-exports this product. Until then, Phase 1A keeps it visible so the relocation is a pure file move.

**Files:**
- Modify: `CameraKit/Package.swift` (add one line in the `products:` array)

- [ ] **Step 1: Add the product entry.**

  In `CameraKit/Package.swift`, locate the `products` block:

  ```swift
      products: [
          .library(name: "CameraKit", targets: ["CameraKit"]),
      ],
  ```

  Replace with:

  ```swift
      products: [
          .library(name: "CameraKit", targets: ["CameraKit"]),
          // TEMPORARY (Phase 1A): exported so the relocated DisplayViewModel
          // can `import CameraKitInterop` for CppCannyStub. Phase 1B removes
          // the OpenCV/Canny consumer from the package and unexports this.
          .library(name: "CameraKitInterop", targets: ["CameraKitInterop"]),
      ],
  ```

- [ ] **Step 2: Build to confirm the package still resolves.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  ```

  Expected: BUILD SUCCEEDED. The new product is exposed but not yet consumed.

- [ ] **Step 3: Commit.**

  ```bash
  git add CameraKit/Package.swift
  git commit -m "build(package): temporarily export CameraKitInterop product (Phase 1A bridge)

The relocated DisplayViewModel uses CppCannyStub for the DEBUG Canny
overlay and needs to import CameraKitInterop from the app target.
Phase 1B will remove the Canny consumer from the package and un-export
this product — at that point CameraKitInterop returns to package-internal."
  ```

---

## Task 4: Add `CameraKitInterop` product dependency to the app target

**Why:** Establishing the dependency before any files move keeps each step independently buildable. Pattern follows the existing `CameraKit` dependency on the same target.

**Files:**
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (via `xcodeproj` gem)

- [ ] **Step 1: Apply the dependency via Ruby.**

  Per CLAUDE.md §6 "load-bearing invariants", SwiftPM products use `product_ref`, not `fileRef`.

  ```bash
  ruby <<'RUBY'
  require 'xcodeproj'

  PROJECT          = 'eva-swift-stitch.xcodeproj'
  APP_TARGET_NAME  = 'eva-swift-stitch'
  TEST_TARGET_NAME = 'eva-swift-stitchTests'
  PRODUCT_NAME     = 'CameraKitInterop'
  PACKAGE_REF_ID   = '4CDE782646D8B196D0549C1F'  # XCLocalSwiftPackageReference for CameraKit

  project = Xcodeproj::Project.open(PROJECT)
  pkg_ref = project.objects[PACKAGE_REF_ID]
  abort "package ref #{PACKAGE_REF_ID} not found" unless pkg_ref

  [APP_TARGET_NAME, TEST_TARGET_NAME].each do |target_name|
    target = project.targets.find { |t| t.name == target_name }
    abort "target #{target_name} not found" unless target

    if target.package_product_dependencies.any? { |d| d.product_name == PRODUCT_NAME }
      puts "#{target_name}: #{PRODUCT_NAME} already depended on; skipping."
      next
    end

    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.product_name = PRODUCT_NAME
    dep.package = pkg_ref
    target.package_product_dependencies << dep

    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = dep
    target.frameworks_build_phase.files << bf

    puts "#{target_name}: added #{PRODUCT_NAME} as package product dependency."
  end

  project.save
  RUBY
  ```

  Expected output: `eva-swift-stitch: added CameraKitInterop as package product dependency.` and similar for `eva-swift-stitchTests`.

- [ ] **Step 2: Build to confirm the project still parses and the target links.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  ```

  Expected: BUILD SUCCEEDED. The dependency is wired but no app code imports it yet.

- [ ] **Step 3: Commit.**

  ```bash
  git add eva-swift-stitch.xcodeproj/project.pbxproj
  git commit -m "build(xcodeproj): add CameraKitInterop dep to app + test targets (Phase 1A bridge)

Wired ahead of file relocation so DisplayViewModel (relocating to the
app target) can import CameraKitInterop without a transient build break."
  ```

---

## Task 5: Create the destination directory and Xcode group

**Why:** The 10 files land under a new `eva-swift-stitch/UI/` directory (filesystem) and a matching `UI` PBXGroup nested under the existing `eva-swift-stitch` app group (xcodeproj).

**Files:**
- Create: `eva-swift-stitch/UI/` (directory — created implicitly by the first `git mv`)
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (add `UI` PBXGroup)

- [ ] **Step 1: Create the directory.**

  ```bash
  mkdir -p eva-swift-stitch/UI
  ```

  Git tracks files, not directories — the directory becomes real once a file lands in it (Task 6).

- [ ] **Step 2: Create the `UI` group in the xcodeproj.**

  ```bash
  ruby <<'RUBY'
  require 'xcodeproj'

  PROJECT         = 'eva-swift-stitch.xcodeproj'
  APP_GROUP_NAME  = 'eva-swift-stitch'
  NEW_GROUP_NAME  = 'UI'

  project   = Xcodeproj::Project.open(PROJECT)
  app_group = project.main_group.children.find { |c| c.display_name == APP_GROUP_NAME }
  abort "app group #{APP_GROUP_NAME} not found" unless app_group

  existing = app_group.children.find { |c| c.display_name == NEW_GROUP_NAME }
  if existing
    puts "#{NEW_GROUP_NAME} group already exists under #{APP_GROUP_NAME}; skipping."
  else
    group = app_group.new_group(NEW_GROUP_NAME, NEW_GROUP_NAME)  # path == name relative to parent
    puts "Created group #{NEW_GROUP_NAME} (path=#{group.path}) under #{APP_GROUP_NAME}."
  end

  project.save
  RUBY
  ```

  Expected: `Created group UI (path=UI) under eva-swift-stitch.`

- [ ] **Step 3: Build to confirm the project still loads.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  ```

  Expected: BUILD SUCCEEDED (no source-file change yet).

- [ ] **Step 4: Commit.**

  ```bash
  git add eva-swift-stitch.xcodeproj/project.pbxproj
  git commit -m "build(xcodeproj): add UI group under eva-swift-stitch target (Phase 1A)

Destination group for the 10 SwiftUI source files relocating from
the CameraKit package."
  ```

---

## Task 6: Relocate the 10 UI files

**Why:** The core of Phase 1A. Each file moves with `git mv`, gains `import CameraKit` at the top of its imports block, and is added to the app target's `UI` group + Sources build phase in the xcodeproj. SwiftPM auto-globs `CameraKit/Sources/CameraKit/` — moving a file out of that directory drops it from the package automatically.

**Files:**
- Move: each of the 10 files listed in the File map above
- Modify: each file (add `import CameraKit`; `DisplayViewModel` also keeps its existing `import CameraKitInterop`)
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (add 10 file references + 10 source-build-phase entries)

Execute the steps in order. Do **not** commit between sub-steps within this task — the package is in an inconsistent state until all 10 files have been moved and the xcodeproj has been wired. One commit at the end.

- [ ] **Step 1: Move all 10 files with `git mv`.**

  ```bash
  git mv CameraKit/Sources/CameraKit/CameraView.swift              eva-swift-stitch/UI/CameraView.swift
  git mv CameraKit/Sources/CameraKit/ViewModel.swift               eva-swift-stitch/UI/ViewModel.swift
  git mv CameraKit/Sources/CameraKit/DisplayViewModel.swift        eva-swift-stitch/UI/DisplayViewModel.swift
  git mv CameraKit/Sources/CameraKit/RecordingViewModel.swift      eva-swift-stitch/UI/RecordingViewModel.swift
  git mv CameraKit/Sources/CameraKit/HardwareControlsViewModel.swift eva-swift-stitch/UI/HardwareControlsViewModel.swift
  git mv CameraKit/Sources/CameraKit/ProcessingViewModel.swift     eva-swift-stitch/UI/ProcessingViewModel.swift
  git mv CameraKit/Sources/CameraKit/CalibrationViewModel.swift    eva-swift-stitch/UI/CalibrationViewModel.swift
  git mv CameraKit/Sources/CameraKit/ErrorPresenterViewModel.swift eva-swift-stitch/UI/ErrorPresenterViewModel.swift
  git mv CameraKit/Sources/CameraKit/ControlEnablement.swift       eva-swift-stitch/UI/ControlEnablement.swift
  git mv CameraKit/Sources/CameraKit/SliderDebouncer.swift         eva-swift-stitch/UI/SliderDebouncer.swift
  ```

  Verify:

  ```bash
  ls eva-swift-stitch/UI/ | wc -l    # expect 10
  ls CameraKit/Sources/CameraKit/*ViewModel*.swift 2>/dev/null | wc -l   # expect 0
  ls CameraKit/Sources/CameraKit/CameraView.swift 2>/dev/null   # expect: No such file or directory
  ```

- [ ] **Step 2: Add `import CameraKit` to each relocated file.**

  Each file needs a single `import CameraKit` line added to its imports block. Existing imports stay. For files whose first import is `Foundation`, place `import CameraKit` after `import Foundation` so the result is alphabetical-ish (Apple's idiom). For files whose imports already include `CameraKitInterop` (DisplayViewModel), place `import CameraKit` immediately before `import CameraKitInterop`.

  Final per-file imports blocks (the entire block — replace whatever is there with exactly this for each file):

  **`eva-swift-stitch/UI/CameraView.swift`:**

  ```swift
  import CameraKit
  import MetalKit
  import SwiftUI
  ```

  **`eva-swift-stitch/UI/ViewModel.swift`:**

  ```swift
  import CameraKit
  import SwiftUI
  ```

  **`eva-swift-stitch/UI/DisplayViewModel.swift`:**

  ```swift
  import CameraKit
  import CameraKitInterop
  import CoreMedia
  import Metal
  import SwiftUI
  ```

  **`eva-swift-stitch/UI/RecordingViewModel.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/HardwareControlsViewModel.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/ProcessingViewModel.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/CalibrationViewModel.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/ErrorPresenterViewModel.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/ControlEnablement.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  **`eva-swift-stitch/UI/SliderDebouncer.swift`:**

  ```swift
  import CameraKit
  import Foundation
  ```

  Use the `Edit` tool's `old_string`/`new_string` against the existing import block in each file. Do **not** touch anything below the imports — file contents are preserved.

- [ ] **Step 3: Add the 10 file references to the xcodeproj `UI` group and the app target's Sources build phase.**

  ```bash
  ruby <<'RUBY'
  require 'set'
  require 'xcodeproj'

  PROJECT         = 'eva-swift-stitch.xcodeproj'
  APP_TARGET_NAME = 'eva-swift-stitch'
  APP_GROUP_NAME  = 'eva-swift-stitch'
  UI_GROUP_NAME   = 'UI'
  SOURCE_DIR      = 'eva-swift-stitch/UI'

  project    = Xcodeproj::Project.open(PROJECT)
  app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
  abort "app target not found" unless app_target

  app_group  = project.main_group.children.find { |c| c.display_name == APP_GROUP_NAME }
  abort "app group not found" unless app_group
  ui_group   = app_group.children.find { |c| c.display_name == UI_GROUP_NAME }
  abort "UI group not found — run Task 5 first" unless ui_group

  existing = app_target.source_build_phase.files
                       .map { |f| f.file_ref&.real_path&.to_s }
                       .compact.map { |s| File.expand_path(s) }.to_set

  added = []
  Dir.glob("#{SOURCE_DIR}/*.swift").sort.each do |path|
    abs = File.expand_path(path)
    next if existing.include?(abs)
    filename = File.basename(path)
    ref = ui_group.files.find { |f| f.path == filename } || ui_group.new_reference(filename)
    app_target.source_build_phase.add_file_reference(ref)
    added << filename
  end

  project.save
  puts "Added: #{added.empty? ? '(nothing — already in sync)' : added.join(', ')}"
  RUBY
  ```

  Expected: `Added: CalibrationViewModel.swift, CameraView.swift, ControlEnablement.swift, DisplayViewModel.swift, ErrorPresenterViewModel.swift, HardwareControlsViewModel.swift, ProcessingViewModel.swift, RecordingViewModel.swift, SliderDebouncer.swift, ViewModel.swift`

- [ ] **Step 4: Confirm the package is SwiftUI-free.**

  ```bash
  grep -rn 'import SwiftUI' CameraKit/Sources/CameraKit/
  ```

  Expected: zero hits.

  ```bash
  ls CameraKit/Sources/CameraKit/ | sort
  ```

  Expected list (29 items — the original 39 minus the 10 moved): `AssetWriting.swift`, `AsyncWithTimeout.swift`, `CalibrationCompute.swift`, `CameraEngine.swift`, `CameraKitLog.swift`, `CameraSession.swift`, `Capabilities.swift`, `CaptureDelegate.swift`, `CaptureDeviceProviding.swift`, `Clock.swift`, `Constants.swift`, `Errors.swift`, `FrameSet.swift`, `KVOAsyncStream.swift`, `MetalPipeline.swift`, `OrientationLock.swift`, `PhotosLibraryClient.swift`, `PixelSink.swift`, `ProcessingMetadata.swift`, `Recording.swift`, `RecoveryCoordinator.swift`, `SessionState.swift`, `Settings.swift`, `SettingsPersistence.swift`, `Shaders/`, `StillCapture.swift`, `TexturePoolManager.swift`, `UniformStorage.swift`, `Watchdog.swift`.

- [ ] **Step 5: Build via XcodeBuildMCP.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  ```

  Expected: BUILD SUCCEEDED. The package builds with no SwiftUI references; the app builds with the relocated `UI/` group; the app launches on the iPad and `CameraView()` from the app target renders.

  **If the build fails with `Cannot find type X in scope` errors**, check first whether `(SourceKit)` lag is masking a real success (CLAUDE.md §6.1: build log is ground truth, navigator issues are advisory). If the build truly failed:
  - A symbol the relocated files use is still `internal` — re-run the access-control audit (Task 1 covered three; if anything else surfaces, promote it to `public`, restart this task's Step 5 only after rebuilding green at the package level).
  - The xcodeproj wiring is wrong — re-run Step 3 and verify the file references appear in the app target's Sources build phase.

- [ ] **Step 6: Do NOT run tests yet.**

  After this task, the test target temporarily fails to **compile**: `Stage11Tests.swift` references `ControlEnablement`, `SliderDebouncer`, `ViewModel`, the 6 view models, `_feedErrorForTest`, etc. — all now in the app target — but the file only does `@testable import CameraKit`. `TEST_HOST` is a runtime mechanism that loads the host's binary; it does NOT make app-target types visible at compile time. The test target would need `@testable import eva_swift_stitch` to see them, which the trimmed `Stage11Tests.swift` (Task 7) does not need at all (UI suites move out) and which `Stage11UITests.swift` (Task 7) will add.

  This is the deliberate intermediate state. Tests run again in Task 7 Step 5. **Do not invoke `mcp__XcodeBuildMCP__test_device` between this commit and Task 7's completion** — it will fail with compile errors, not test failures.

- [ ] **Step 7: Commit (single commit for the whole task).**

  ```bash
  git add -A
  git commit -m "feat(migration): relocate 10 SwiftUI files to app target (Phase 1A)

Moves CameraView, ViewModel, 6 view models, ControlEnablement, and
SliderDebouncer from CameraKit/Sources/CameraKit/ to
eva-swift-stitch/UI/. Each file gains \`import CameraKit\` at the top;
DisplayViewModel keeps its CameraKitInterop import (temp-exported in
Phase 1A; Phase 1B will remove the consumer entirely).

The CameraKit package now builds with zero SwiftUI imports. The app
target presents CameraView() from its own source — eva_swift_stitchApp
is unchanged (CameraKit import still needed for CameraKitLog and
OrientationLock).

Known intermediate state: the test target does not compile until the
companion Stage11Tests split lands (next commit). Tests are intentionally
not run between these two commits."
  ```

  The pre-commit hook regenerates CONTRACTS.md via `repomix` (source-text-only, no `swift build`) — confirmed safe with the test target broken.

---

## Task 7: Split `Stage11Tests.swift`

**Why:** `Stage11Tests.swift` is a mix. 4 suites test CameraKit internals (`MetalPipeline.*ForTest`, `SettingsPersistence`, `Constants.blackBalanceOverscan`, `MetalError`) via `@testable import CameraKit` — these must stay dual-membered to preserve the package's portability test coverage. 5 suites reference UI types (`ControlEnablement`, `SliderDebouncer`, the VMs) — these must move to a single-target file in `eva-swift-stitchTests/` so the SwiftPM `.testTarget` can compile again. `CalibrationEngineStub` and `ManagedAtomicSafe` are helpers used only by UI suites; they move too.

**Files:**
- Modify: `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` (trim to 4 internals suites + nothing else)
- Create: `eva-swift-stitchTests/Stage11UITests.swift` (5 UI suites + `CalibrationEngineStub` + `ManagedAtomicSafe`)
- Modify: `eva-swift-stitch.xcodeproj/project.pbxproj` (add `Stage11UITests.swift` to the `eva-swift-stitchTests` group + target's Sources build phase)

- [ ] **Step 1: Create `eva-swift-stitchTests/Stage11UITests.swift`.**

  This file is the destination for the 5 UI suites + `CalibrationEngineStub` + `ManagedAtomicSafe`. Use `Write` with the following exact content (the suite bodies are copied verbatim from the current `Stage11Tests.swift` lines 97–542 + 544–557; the imports include both `@testable` targets):

  ```swift
  import CoreVideo
  import Foundation
  import Metal
  import Testing

  @testable import CameraKit
  @testable import eva_swift_stitch

  // MARK: - Stage 11 — ControlEnablement (state-driven UI matrix)

  @Suite("Stage 11 — control enablement matrix", .progressLogged)
  struct Stage11ControlEnablementTests {

      @Test("closed state disables everything; no scanning")
      func closedDisablesAll() {
          let e = ControlEnablement(sessionState: .closed, recordingState: .idle(lastUri: nil))
          #expect(!e.isRecordEnabled)
          #expect(!e.isCaptureEnabled)
          #expect(!e.isSettingsEnabled)
          #expect(!e.isCalibrateEnabled)
          #expect(!e.isResolutionEnabled)
          #expect(!e.showScanningAnimation)
      }

      @Test("opening shows scanning, disables inputs")
      func openingShowsScanning() {
          let e = ControlEnablement(sessionState: .opening, recordingState: .idle(lastUri: nil))
          #expect(!e.isRecordEnabled)
          #expect(e.showScanningAnimation)
      }

      @Test("streaming idle enables every control")
      func streamingEnablesAll() {
          let e = ControlEnablement(sessionState: .streaming, recordingState: .idle(lastUri: nil))
          #expect(e.isRecordEnabled)
          #expect(e.isCaptureEnabled)
          #expect(e.isSettingsEnabled)
          #expect(e.isCalibrateEnabled)
          #expect(e.isResolutionEnabled)
          #expect(!e.showScanningAnimation)
      }

      @Test("paused disables capture/record; resolution disabled")
      func pausedDisablesAll() {
          let e = ControlEnablement(sessionState: .paused, recordingState: .idle(lastUri: nil))
          #expect(!e.isRecordEnabled)
          #expect(!e.isCaptureEnabled)
          #expect(!e.isSettingsEnabled)
          #expect(!e.isResolutionEnabled)
      }

      @Test("recovering shows scanning and disables inputs")
      func recoveringShowsScanning() {
          let e = ControlEnablement(sessionState: .recovering, recordingState: .idle(lastUri: nil))
          #expect(!e.isRecordEnabled)
          #expect(!e.isCaptureEnabled)
          #expect(e.showScanningAnimation)
      }

      @Test("recording disables capture and resolution per U-18")
      func recordingDisablesCaptureResolution() {
          let e = ControlEnablement(sessionState: .streaming, recordingState: .recording)
          #expect(!e.isCaptureEnabled)
          #expect(!e.isResolutionEnabled)
          #expect(!e.isRecordEnabled)
          #expect(e.isStopEnabled)
          #expect(e.isCalibrateEnabled)
      }

      /// Brief §8 TESTABLE `11:state-driven-control-enable-disable` — full matrix sweep.
      @Test("enablement matrix covers every state the brief calls out")
      func stateDrivenControlEnableDisable() {
          let cases:
              [(
                  SessionState, RecordingState,
                  (record: Bool, capture: Bool, resolution: Bool, settings: Bool, calibrate: Bool)
              )] = [
                  (.closed, .idle(lastUri: nil), (false, false, false, false, false)),
                  (.opening, .idle(lastUri: nil), (false, false, false, false, false)),
                  (.streaming, .idle(lastUri: nil), (true, true, true, true, true)),
                  (.paused, .idle(lastUri: nil), (false, false, false, false, false)),
                  (.error, .idle(lastUri: nil), (false, false, false, false, false)),
                  (.streaming, .recording, (false, false, false, false, true)),
              ]
          for (ss, rs, expected) in cases {
              let e = ControlEnablement(sessionState: ss, recordingState: rs)
              #expect(e.isRecordEnabled == expected.record, "record for \(ss)/\(rs)")
              #expect(e.isCaptureEnabled == expected.capture, "capture for \(ss)/\(rs)")
              #expect(e.isResolutionEnabled == expected.resolution, "resolution for \(ss)/\(rs)")
              #expect(e.isSettingsEnabled == expected.settings, "settings for \(ss)/\(rs)")
              #expect(e.isCalibrateEnabled == expected.calibrate, "calibrate for \(ss)/\(rs)")
          }
      }

      /// Brief §8 TESTABLE `11:scanning-animation-binds-to-session-state` — J4 resolution.
      @Test("scanning animation binds to SessionState, not focusDistance")
      func scanningAnimationBindsToSessionState() {
          let scanningStates: [SessionState] = [.opening, .recovering]
          let nonScanningStates: [SessionState] = [.streaming, .paused, .error, .closed]
          for ss in scanningStates {
              let e = ControlEnablement(sessionState: ss, recordingState: .idle(lastUri: nil))
              #expect(e.showScanningAnimation, "expected scanning for \(ss)")
          }
          for ss in nonScanningStates {
              let e = ControlEnablement(sessionState: ss, recordingState: .idle(lastUri: nil))
              #expect(!e.showScanningAnimation, "expected NO scanning for \(ss)")
          }
      }
  }

  // MARK: - Stage 11 — Slider debouncer

  @Suite("Stage 11 — slider coalescing", .progressLogged)
  struct Stage11SliderDebouncerTests {

      /// Brief §8 TESTABLE `11:slider-coalescing-60hz`.
      @Test("240 Hz input over ~1 s is coalesced to < 100 Hz; final value committed")
      func sliderCoalescing60Hz() async {
          let count = ManagedAtomicSafe(0)
          let last = ManagedAtomicSafe(0.0)
          let deb = SliderDebouncer(intervalMs: 16) { v in
              await count.increment()
              await last.set(v)
          }
          await deb.start()

          let t0 = ContinuousClock.now
          var i = 0
          while ContinuousClock.now < t0 + .seconds(1) && i < 240 {
              deb.push(Double(i) / 240.0)
              try? await Task.sleep(for: .microseconds(4_166))
              i += 1
          }
          try? await Task.sleep(for: .milliseconds(50))
          await deb.stop()

          let dispatched = await count.get()
          let lastValue = await last.get()
          #expect(dispatched < 240, "expected coalescing; got \(dispatched) dispatches for \(i) inputs")
          #expect(dispatched < 100, "dispatch rate too high: \(dispatched) Hz")
          #expect(abs(lastValue - Double(i - 1) / 240.0) < 1e-6, "final value mismatch")
      }
  }

  // MARK: - Stage 11 — Calibration view model

  actor CalibrationEngineStub: CalibrationEngineProtocol {
      let sample: RgbSample
      let bbSample: RgbSample
      var currentGains: WhiteBalanceGains
      let stubMaxGain: Float
      var recordedDeltas: [CameraSettings] = []
      var appliedGainsLog: [WhiteBalanceGains] = []

      init(
          sample: RgbSample,
          bbSample: RgbSample? = nil,
          currentGains: WhiteBalanceGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0),
          maxGain: Float = 4.0
      ) {
          self.sample = sample
          self.bbSample = bbSample ?? sample
          self.currentGains = currentGains
          self.stubMaxGain = maxGain
      }

      func sampleCenterPatchOnNatural() async throws -> RgbSample { sample }
      func sampleCenterPatchForBBCalibration() async throws -> RgbSample { bbSample }
      func updateSettings(_ settings: CameraSettings) async throws {
          recordedDeltas.append(settings)
      }
      func currentDeviceWBGains() async throws -> WhiteBalanceGains { currentGains }
      func maxWhiteBalanceGain() async throws -> Float { stubMaxGain }
      func awaitWBSettled() async { }
      func grayWorldDeviceWBGains() async throws -> WhiteBalanceGains { currentGains }
      func freshGrayWorldDeviceWBGains() async throws -> WhiteBalanceGains { currentGains }
      func setWBPreset(_ preset: WhiteBalancePreset) async throws { }
      func applyManualGainsAndAwait(_ gains: WhiteBalanceGains) async throws {
          currentGains = gains
          appliedGainsLog.append(gains)
      }
      func awaitAESettled() async { }
  }

  @Suite("Stage 11 — calibration view model", .progressLogged)
  struct Stage11CalibrationVMTests {

      @MainActor
      private func awaitDeltas(_ stub: CalibrationEngineStub, count: Int) async -> [CameraSettings] {
          let deadline = ContinuousClock.now + .seconds(1)
          var deltas: [CameraSettings] = []
          while ContinuousClock.now < deadline {
              deltas = await stub.recordedDeltas
              if deltas.count >= count { break }
              try? await Task.sleep(for: .milliseconds(10))
          }
          return deltas
      }

      @Test("calibrateWB applies Apple gray-world (single-shot) and writes one .manual delta")
      @MainActor
      func wbCalibrateAppliesAppleGrayWorld() async {
          let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

          vm.calibrateWB()
          let deltas = await awaitDeltas(stub, count: 1)

          #expect(deltas.count == 1, "expected single .manual write")
          #expect(deltas.last?.wbMode == .manual)

          let applies = await stub.appliedGainsLog.count
          #expect(applies == 1, "expected single apply (single-shot); got \(applies)")

          let r = deltas.last?.wbGainR ?? 0
          let g = deltas.last?.wbGainG ?? 0
          let b = deltas.last?.wbGainB ?? 0
          #expect((1.0...4.0).contains(r))
          #expect((1.0...4.0).contains(g))
          #expect((1.0...4.0).contains(b))
      }

      @Test("calibrateWB sets wbCalibrationStatus to .completed after success")
      @MainActor
      func wbCalibrationStatusReachesCompleted() async {
          let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

          vm.calibrateWB()
          _ = await awaitDeltas(stub, count: 1)
          let status = vm.wbCalibrationStatus
          #expect(status == .completed || status == .idle,
              "expected .completed or .idle (auto-reverted); got \(status)")
      }

      @Test("resetToAutoWB writes wbMode=.auto")
      @MainActor
      func resetToAutoWBWritesAuto() async {
          let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

          vm.resetToAutoWB()
          let deltas = await awaitDeltas(stub, count: 1)

          #expect(deltas.last?.wbMode == .auto)
          #expect(deltas.last?.wbGainR == nil)
      }

      @Test("lockCurrentWB writes wbMode=.locked")
      @MainActor
      func lockCurrentWBWritesLocked() async {
          let stub = CalibrationEngineStub(sample: RgbSample(r: 0.5, g: 0.5, b: 0.5))
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

          vm.lockCurrentWB()
          let deltas = await awaitDeltas(stub, count: 1)

          #expect(deltas.last?.wbMode == .locked)
          #expect(deltas.last?.wbGainR == nil)
      }

      @Test("calibrateBB writes per-channel BB pedestal from natural-lane sample")
      @MainActor
      func bbCalibrateUpdatesProcessingParams() async {
          let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
          let stub = CalibrationEngineStub(sample: sample)
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)
          let k = Constants.blackBalanceOverscan

          vm.calibrateBB()

          let deadline = ContinuousClock.now + .seconds(1)
          while ContinuousClock.now < deadline,
              processingVM.currentProcessing.blackR == 0
          {
              try? await Task.sleep(for: .milliseconds(10))
          }

          #expect(abs(processingVM.currentProcessing.blackR - 0.02 * k) < 1e-9)
          #expect(abs(processingVM.currentProcessing.blackG - 0.03 * k) < 1e-9)
          #expect(abs(processingVM.currentProcessing.blackB - 0.05 * k) < 1e-9)
      }

      @Test("resetBlackBalance zeroes the pedestal")
      @MainActor
      func resetBlackBalanceZeroesPedestal() async {
          let stub = CalibrationEngineStub(sample: RgbSample(r: 0.02, g: 0.03, b: 0.05))
          let processingVM = ProcessingViewModel(engine: CameraEngine())
          let vm = CalibrationViewModel(engine: stub, processingVM: processingVM)

          vm.calibrateBB()
          let deadline1 = ContinuousClock.now + .seconds(1)
          while ContinuousClock.now < deadline1,
              processingVM.currentProcessing.blackR == 0
          {
              try? await Task.sleep(for: .milliseconds(10))
          }
          #expect(processingVM.currentProcessing.blackR > 0)

          vm.resetBlackBalance()
          let deadline2 = ContinuousClock.now + .seconds(1)
          while ContinuousClock.now < deadline2,
              processingVM.currentProcessing.blackR != 0
          {
              try? await Task.sleep(for: .milliseconds(10))
          }
          #expect(processingVM.currentProcessing.blackR == 0)
          #expect(processingVM.currentProcessing.blackG == 0)
          #expect(processingVM.currentProcessing.blackB == 0)
      }
  }

  // MARK: - Stage 11 — Error presenter view model

  @Suite("Stage 11 — error presenter", .progressLogged)
  struct Stage11ErrorPresenterTests {

      /// Brief §8 TESTABLE `11:non-fatal-error-shows-toast`.
      @Test("non-fatal error shows toast and auto-clears after the 3-second window")
      @MainActor
      func nonFatalErrorShowsToast() async {
          let vm = ErrorPresenterViewModel(engine: CameraEngine())
          let err = CameraError(code: .unknownError, message: "transient", isFatal: false)
          vm._feedErrorForTest(err)

          #expect(vm.currentToast == err)
          #expect(vm.fatalDialog == nil)

          try? await Task.sleep(for: .milliseconds(500))
          #expect(vm.currentToast == err)

          try? await Task.sleep(for: .milliseconds(3000))
          #expect(vm.currentToast == nil)
      }

      /// Brief §8 TESTABLE `11:fatal-error-shows-blocking-dialog`.
      @Test("fatal error shows blocking dialog and does not auto-dismiss")
      @MainActor
      func fatalErrorShowsBlockingDialog() async {
          let vm = ErrorPresenterViewModel(engine: CameraEngine())
          let err = CameraError(code: .hardwareError, message: "device gone", isFatal: true)
          vm._feedErrorForTest(err)

          #expect(vm.fatalDialog == err)
          #expect(vm.currentToast == nil)

          try? await Task.sleep(for: .milliseconds(50))
          #expect(vm.fatalDialog == err, "fatal dialog should not auto-clear")
      }
  }

  // MARK: - Stage 11 — Error routing (unified top-toast surface)

  @Suite("Stage 11 — error routing", .progressLogged)
  struct Stage11ErrorRoutingTests {

      @MainActor
      private func awaitToast(_ presenter: ErrorPresenterViewModel) async {
          let deadline = ContinuousClock.now + .seconds(2)
          while ContinuousClock.now < deadline, presenter.currentToast == nil {
              try? await Task.sleep(for: .milliseconds(20))
          }
      }

      @Test("toggleRecording start-failure routes a non-fatal error to the presenter")
      @MainActor
      func startFailureRoutesToPresenter() async {
          let engine = CameraEngine()
          let presenter = ErrorPresenterViewModel(engine: engine)
          let vm = RecordingViewModel(engine: engine, errorPresenter: presenter)

          vm.toggleRecording()

          await awaitToast(presenter)
          #expect(presenter.currentToast != nil, "start-failure should surface a toast")
          #expect(presenter.currentToast?.isFatal == false)
          #expect(presenter.fatalDialog == nil)
      }

      @Test("toggleRecording stop-failure routes a non-fatal error to the presenter")
      @MainActor
      func stopFailureRoutesToPresenter() async {
          let engine = CameraEngine()
          let presenter = ErrorPresenterViewModel(engine: engine)
          let vm = RecordingViewModel(engine: engine, errorPresenter: presenter)

          vm.recordingState = .recording
          vm.toggleRecording()

          await awaitToast(presenter)
          #expect(presenter.currentToast != nil, "stop-failure should surface a toast")
          #expect(presenter.currentToast?.isFatal == false)
      }

      @Test("captureImage failure routes a non-fatal error to the presenter")
      @MainActor
      func captureFailureRoutesToPresenter() async {
          let vm = ViewModel()
          vm.captureImage()

          await awaitToast(vm.errors)
          #expect(vm.errors.currentToast != nil, "capture failure should surface a toast")
          #expect(vm.errors.currentToast?.isFatal == false)
          #expect(vm.captureConfirmation == nil, "failure must not populate the success banner")
      }
  }

  /// Test-only thread-safe wrapper.
  ///
  /// Avoids `import Atomics` — the `eva-swift-stitchTests` target does not link
  /// `swift-atomics`, so `ManagedAtomic` causes a linker error.
  actor ManagedAtomicSafe<T: Sendable> {
      private var value: T
      init(_ v: T) { self.value = v }
      func get() -> T { value }
      func set(_ v: T) { value = v }
  }

  extension ManagedAtomicSafe where T == Int {
      func increment() { value += 1 }
  }
  ```

  Note: the body of every suite, `CalibrationEngineStub`, and `ManagedAtomicSafe` is copied verbatim from the existing `Stage11Tests.swift` lines 97–542 and 544–557. Cross-check by diffing if you want — the only line-level changes are the imports at the top.

- [ ] **Step 2: Trim `Stage11Tests.swift` to the 4 internals suites.**

  Use `Write` to replace the entire contents of `CameraKit/Tests/CameraKitTests/Stage11Tests.swift` with the following. This is the existing file with suites 2–6 (lines 97–542) and the `ManagedAtomicSafe` helper (lines 544–557) removed; suites 1, 7, 8, 9 and their `MARK:` headers preserved verbatim:

  ```swift
  import CoreVideo
  import Foundation
  import Metal
  import Testing

  @testable import CameraKit

  // MARK: - Stage 11 — Calibration compute (pure helpers)

  @Suite("Stage 11 — calibration compute", .progressLogged)
  struct Stage11CalibrationComputeTests {

      private let unityGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
      private let typicalMax: Float = 4.0

      @Test("neutral linear sample with unity current gains returns unity (no-op)")
      func grayWorldNeutralLinearSampleIsNoOp() {
          let sample = RgbSample(r: 0.5, g: 0.5, b: 0.5)
          let gains = CalibrationCompute.grayWorldGains(
              sample: sample, current: unityGains, maxGain: typicalMax)
          #expect(abs(gains.red   - 1.0) < 1e-5)
          #expect(abs(gains.green - 1.0) < 1e-5)
          #expect(abs(gains.blue  - 1.0) < 1e-5)
      }

      @Test("bluish sample produces gains all ≥ 1.0 with B anchored (no pink-tint regression)")
      func grayWorldBluishSampleAnchorsBlue() {
          let sample = RgbSample(r: 0.4, g: 0.5, b: 0.8)
          let gains = CalibrationCompute.grayWorldGains(
              sample: sample, current: unityGains, maxGain: typicalMax)
          #expect(gains.red   >= 1.0)
          #expect(gains.green >= 1.0)
          #expect(abs(gains.blue - 1.0) < 1e-5)
          #expect(gains.red > gains.green)
          #expect(gains.green > gains.blue)
      }

      @Test("stacks reciprocal onto non-unity current gains (delta correction semantics)")
      func grayWorldStacksOntoCurrentGains() {
          let sample = RgbSample(r: 0.4, g: 0.5, b: 0.6)
          let unityResult = CalibrationCompute.grayWorldGains(
              sample: sample, current: unityGains, maxGain: typicalMax)
          let scaledCurrent = WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5)
          let scaledResult = CalibrationCompute.grayWorldGains(
              sample: sample, current: scaledCurrent, maxGain: typicalMax)

          let unityRG = unityResult.red / unityResult.green
          let scaledRG = scaledResult.red / scaledResult.green
          #expect(unityRG != scaledRG, "stacking must change the per-channel ratio")
      }

      @Test("clamps each channel to [1.0, maxGain]")
      func grayWorldClampsToMaxGain() {
          let sample = RgbSample(r: 0.05, g: 0.5, b: 0.5)
          let aggressiveCurrent = WhiteBalanceGains(red: 3.5, green: 1.0, blue: 1.0)
          let gains = CalibrationCompute.grayWorldGains(
              sample: sample, current: aggressiveCurrent, maxGain: typicalMax)
          #expect(gains.red   <= typicalMax)
          #expect(gains.green >= 1.0)
          #expect(gains.blue  >= 1.0)
      }

      @Test("near-zero channels are clamped to epsilon (no division by zero)")
      func grayWorldClampsZeroChannel() {
          let sample = RgbSample(r: 0.0, g: 0.5, b: 0.5)
          let gains = CalibrationCompute.grayWorldGains(
              sample: sample, current: unityGains, maxGain: typicalMax)
          #expect(gains.red.isFinite)
          #expect(gains.red >= 1.0)
      }

      @Test("black-balance offsets scale per-channel sample by overscan multiplier")
      func blackBalanceOffsetsOverscan() {
          let sample = RgbSample(r: 0.02, g: 0.03, b: 0.05)
          let offsets = CalibrationCompute.blackBalanceOffsets(sample: sample)
          let k = Constants.blackBalanceOverscan
          #expect(abs(offsets.r - 0.02 * k) < 1e-9)
          #expect(abs(offsets.g - 0.03 * k) < 1e-9)
          #expect(abs(offsets.b - 0.05 * k) < 1e-9)
      }
  }

  // MARK: - Stage 11 — BB calibration scratch encode

  @Suite("Stage 11 — BB calibration scratch encode", .progressLogged)
  struct Stage11BBCalibrationScratchTests {

      @Test("dispatchBBCalibrationSample ignores live BB pedestal (sample = BCSG-only)")
      func bbScratchZeroesPedestal() async throws {
          let device = try #require(MTLCreateSystemDefaultDevice())
          let size = Size(width: 256, height: 256)
          let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

          pipeline.setColorUniformsForTest(
              ProcessingParameters(
                  brightness: 0,
                  contrast: 1,
                  saturation: 0,
                  blackR: 0.2,
                  blackG: 0.2,
                  blackB: 0.2,
                  gamma: 1
              ))

          let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
              pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
          try fillBufferUniform(nBuf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
          pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

          let sample = try await pipeline.dispatchBBCalibrationSample()

          #expect(abs(sample.r - 0.5) < 1e-2)
          #expect(abs(sample.g - 0.5) < 1e-2)
          #expect(abs(sample.b - 0.5) < 1e-2)
      }

      @Test("scaledCenterPatchSize: default → 96, fallback → ≥16, tiny → clamped to 16")
      func scaledCenterPatchSize() {
          #expect(
              MetalPipeline.scaledCenterPatchSize(
                  captureSize: Size(width: 4160, height: 3120)) == 96)
          let s2 = MetalPipeline.scaledCenterPatchSize(
              captureSize: Size(width: 1280, height: 960))
          #expect(s2 == 30)
          #expect(
              MetalPipeline.scaledCenterPatchSize(
                  captureSize: Size(width: 480, height: 360)) == 16)
      }

      // Pixel helpers (`fillBufferUniform`, `packHalfRGBA`, `HalfPixel`) live in
      // `TestPixelHelpers.swift` and are shared with `Stage04Tests`.
  }

  // MARK: - Stage 11 — Family B follow-ups (calibration "no frame yet" semantics)

  @Suite("Stage 11 — Family B follow-ups: calibration no-frame semantics", .progressLogged)
  struct Stage11FamilyBFollowupCalibrationTests {

      @Test("dispatchCenterPatchOnNatural throws .noFrameAvailable before any frame")
      func centerPatchOnNaturalThrowsBeforeFirstFrame() async throws {
          let device = try #require(MTLCreateSystemDefaultDevice())
          let pipeline = try MetalPipeline(
              device: device,
              captureSize: Size(width: 256, height: 256),
              gateOpen: true
          )

          await #expect(throws: MetalError.noFrameAvailable) {
              _ = try await pipeline.dispatchCenterPatchOnNatural()
          }
      }

      @Test("dispatchBBCalibrationSample throws .noFrameAvailable before any frame")
      func bbCalibrationSampleThrowsBeforeFirstFrame() async throws {
          let device = try #require(MTLCreateSystemDefaultDevice())
          let pipeline = try MetalPipeline(
              device: device,
              captureSize: Size(width: 256, height: 256),
              gateOpen: true
          )

          await #expect(throws: MetalError.noFrameAvailable) {
              _ = try await pipeline.dispatchBBCalibrationSample()
          }
      }

      @Test("dispatchCenterPatchOnNatural samples installed natural texture")
      func centerPatchOnNaturalSamplesInstalledTexture() async throws {
          let device = try #require(MTLCreateSystemDefaultDevice())
          let size = Size(width: 256, height: 256)
          let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

          let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
              pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
          try fillBufferUniform(nBuf, r: 0.4, g: 0.6, b: 0.2, a: 1.0)
          pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

          let sample = try await pipeline.dispatchCenterPatchOnNatural()
          #expect(abs(sample.r - 0.4) < 1e-2)
          #expect(abs(sample.g - 0.6) < 1e-2)
          #expect(abs(sample.b - 0.2) < 1e-2)
      }

      @Test("new MetalError cases are distinguishable")
      func newMetalErrorCasesDistinguishable() {
          let alloc: MetalError = .textureAllocationFailed
          let noFrame: MetalError = .noFrameAvailable

          switch alloc {
          case .textureAllocationFailed: break
          default: Issue.record("textureAllocationFailed did not match its own case")
          }
          switch noFrame {
          case .noFrameAvailable: break
          default: Issue.record("noFrameAvailable did not match its own case")
          }
      }
  }

  // MARK: - Stage 11 — Settings persistence WB policy

  @Suite("Stage 11 — settings persistence WB policy", .progressLogged)
  struct Stage11SettingsPersistenceWBTests {

      private func makeIsolatedDefaults() -> UserDefaults {
          let suiteName = "CameraKitTests.SettingsPersistence.\(UUID().uuidString)"
          return UserDefaults(suiteName: suiteName)!
      }

      @Test("manual WB + gains are stripped on load (per-session policy)")
      func manualWBStrippedOnLoad() {
          let defaults = makeIsolatedDefaults()
          var s = CameraSettings()
          s.iso = 800
          s.wbMode = .manual
          s.wbGainR = 1.5
          s.wbGainG = 1.2
          s.wbGainB = 1.0
          SettingsPersistence.save(s, defaults: defaults)

          let loaded = SettingsPersistence.load(defaults: defaults)
          #expect(loaded != nil)
          #expect(loaded?.iso == 800)
          #expect(loaded?.wbMode == nil)
          #expect(loaded?.wbGainR == nil)
          #expect(loaded?.wbGainG == nil)
          #expect(loaded?.wbGainB == nil)
      }

      @Test("auto WB round-trips (only .manual is stripped)")
      func autoWBRoundTrips() {
          let defaults = makeIsolatedDefaults()
          var s = CameraSettings()
          s.wbMode = .auto
          SettingsPersistence.save(s, defaults: defaults)

          let loaded = SettingsPersistence.load(defaults: defaults)
          #expect(loaded?.wbMode == .auto)
      }

      @Test("locked WB round-trips (only .manual is stripped)")
      func lockedWBRoundTrips() {
          let defaults = makeIsolatedDefaults()
          var s = CameraSettings()
          s.wbMode = .locked
          SettingsPersistence.save(s, defaults: defaults)

          let loaded = SettingsPersistence.load(defaults: defaults)
          #expect(loaded?.wbMode == .locked)
      }
  }
  ```

- [ ] **Step 3: Wire `Stage11UITests.swift` into the `eva-swift-stitchTests` target (single-target).**

  ```bash
  ruby <<'RUBY'
  require 'set'
  require 'xcodeproj'

  PROJECT          = 'eva-swift-stitch.xcodeproj'
  TEST_TARGET_NAME = 'eva-swift-stitchTests'
  TEST_GROUP_NAME  = 'eva-swift-stitchTests'
  FILE_PATH        = 'eva-swift-stitchTests/Stage11UITests.swift'

  project     = Xcodeproj::Project.open(PROJECT)
  test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }
  abort "test target not found" unless test_target

  test_group = project.main_group.children.find { |c| c.display_name == TEST_GROUP_NAME }
  abort "test group not found" unless test_group

  existing = test_target.source_build_phase.files
                        .map { |f| f.file_ref&.real_path&.to_s }
                        .compact.map { |s| File.expand_path(s) }.to_set
  abs = File.expand_path(FILE_PATH)

  if existing.include?(abs)
    puts "Stage11UITests.swift already wired; skipping."
  else
    filename = File.basename(FILE_PATH)
    ref = test_group.files.find { |f| f.path == filename } || test_group.new_reference(filename)
    test_target.source_build_phase.add_file_reference(ref)
    puts "Added: #{filename} to #{TEST_TARGET_NAME}."
  end

  project.save
  RUBY
  ```

  Expected: `Added: Stage11UITests.swift to eva-swift-stitchTests.`

- [ ] **Step 4: Re-run `sync-test-target.sh` to keep the trimmed `Stage11Tests.swift` wired.**

  ```bash
  ./scripts/sync-test-target.sh
  ```

  Expected: `Added: (nothing — already in sync)` — `Stage11Tests.swift` was already in the test target; trimming its contents doesn't change membership.

- [ ] **Step 5: Build + run the relocated test suites first (fast feedback before the full bundle).**

  Run only the new UI suites:

  ```
  mcp__XcodeBuildMCP__test_device { testFilter: ["eva-swift-stitchTests/Stage11ControlEnablementTests", "eva-swift-stitchTests/Stage11SliderDebouncerTests", "eva-swift-stitchTests/Stage11CalibrationVMTests", "eva-swift-stitchTests/Stage11ErrorPresenterTests", "eva-swift-stitchTests/Stage11ErrorRoutingTests"] }
  ```

  Expected: all 5 suites pass with the same test counts as before the split. Test counts per suite (verify against the original file): ControlEnablement = 8, SliderDebouncer = 1, CalibrationVM = 6, ErrorPresenter = 2, ErrorRouting = 3. Total UI = 20.

  Then the kept internals suites:

  ```
  mcp__XcodeBuildMCP__test_device { testFilter: ["eva-swift-stitchTests/Stage11CalibrationComputeTests", "eva-swift-stitchTests/Stage11BBCalibrationScratchTests", "eva-swift-stitchTests/Stage11FamilyBFollowupCalibrationTests", "eva-swift-stitchTests/Stage11SettingsPersistenceWBTests"] }
  ```

  Expected: all 4 suites pass. Test counts: CalibrationCompute = 6, BBCalibrationScratch = 2, FamilyBFollowup = 4, SettingsPersistenceWB = 3. Total internals = 15. **20 + 15 = 35 — the original Stage11Tests.swift had 35 tests; the count must match.**

- [ ] **Step 6: Run the full test bundle.**

  ```
  mcp__XcodeBuildMCP__test_device
  ```

  Expected: 125 passed / 0 failed. Same total as the Stage 12 baseline.

- [ ] **Step 7: Commit.**

  ```bash
  git add -A
  git commit -m "test(stage-11): split Stage11Tests into internals (package) + UI (app target)

5 UI-coupled suites (ControlEnablement, SliderDebouncer, CalibrationVM,
ErrorPresenter, ErrorRouting) + CalibrationEngineStub + ManagedAtomicSafe
move to eva-swift-stitchTests/Stage11UITests.swift (single-target).

4 internals suites (CalibrationCompute, BBCalibrationScratch,
FamilyBFollowup, SettingsPersistenceWB) stay in
CameraKit/Tests/CameraKitTests/Stage11Tests.swift (dual-membered).

Total tests unchanged: 35 (20 UI + 15 internals). Full bundle 125 passes."
  ```

---

## Task 8: Audit + verify the relocation is complete

**Why:** Guard rails before declaring done. These are the spec's verification checklist (§Verification → Phase 1A) cross-checked against grep evidence.

- [ ] **Step 1: Confirm no SwiftUI import remains in the package.**

  ```bash
  grep -rn 'import SwiftUI' CameraKit/Sources/CameraKit/
  ```

  Expected: zero hits.

- [ ] **Step 2: Confirm the 10 files no longer exist in the package directory.**

  ```bash
  for f in CameraView ViewModel DisplayViewModel RecordingViewModel HardwareControlsViewModel ProcessingViewModel CalibrationViewModel ErrorPresenterViewModel ControlEnablement SliderDebouncer; do
    test -e "CameraKit/Sources/CameraKit/${f}.swift" && echo "STILL PRESENT: $f"
    test -e "eva-swift-stitch/UI/${f}.swift" || echo "MISSING IN UI: $f"
  done
  ```

  Expected: no output (both inverted checks fall through).

- [ ] **Step 3: Confirm the scaffold inventory hasn't drifted.**

  ```bash
  ./scripts/scaffold-inventory.sh
  ```

  Expected: empty (post-Stage-12 baseline — no active scaffolds). Phase 1A introduces none.

- [ ] **Step 4: Confirm the app launches and `CameraView` renders.**

  Already covered by `mcp__XcodeBuildMCP__build_run_device` in Task 6, but worth a manual check on device — open the app, see the live preview, exercise: capture button, record toggle, sidebar calibrate, slider input. None should regress relative to Stage 12.

  If working without the iPad in hand, snapshot the post-launch state via `mcp__XcodeBuildMCP__screenshot` (the device target — never the simulator) and inspect.

- [ ] **Step 5: Confirm CONTRACTS.md regenerated and the public surface matches expectations.**

  The pre-commit hook regenerates it on every commit. If you want to confirm out-of-band:

  ```bash
  ./scripts/regen-contracts.sh
  git diff CameraKit/CONTRACTS.md   # only the relocated-file deletions and the 3 newly-public funcs should appear
  ```

---

## Task 9: Update `state.md` and `DECISIONS.md`

**Why:** `state.md` is the per-stage ledger; subsequent sessions read it first. `DECISIONS.md` is the append-only rationale log.

**Files:**
- Modify: `CameraKit/state.md`
- Modify: `CameraKit/DECISIONS.md`

- [ ] **Step 1: Append a new top-level section to `CameraKit/state.md` describing Phase 1A.**

  Open the file, locate the current "## Current stage" block (today: "Stage 12 complete"). Add a new section *above* it (state.md is reverse-chronological) titled `## Current stage` for Phase 1A, and demote the existing Stage-12 section to a history-style "## Stage 12" heading.

  Suggested wording for the new "## Current stage" block:

  ```markdown
  ## Current stage

  Phase 1A complete (Flutter migration — UI decoupling).
  CameraKit package now builds with **zero SwiftUI imports**; 10 UI files
  (CameraView, ViewModel, 6 view models, ControlEnablement, SliderDebouncer)
  live under `eva-swift-stitch/UI/` in the app target. `Stage11Tests.swift`
  was split — 4 internals suites stayed dual-membered, 5 UI suites moved
  to `eva-swift-stitchTests/Stage11UITests.swift` (single-target, deliberate
  exception to CLAUDE.md §8 dual-membership default). Full test bundle:
  **125 passed / 0 failed** — unchanged from the Stage 12 baseline.

  Bridge state: `CameraKitInterop` is **temporarily exported as a SwiftPM
  product** so the relocated `DisplayViewModel` can import `CppCannyStub`
  for the DEBUG Canny edge-count overlay. Phase 1B removes the OpenCV
  consumer and un-exports this product.

  Public-surface promotions (Phase 1A enabling edits):
  - `CameraEngine.dumpDeviceFormats()` → public
  - `CameraEngine.setGate(_:)` → public
  - `CameraEngine.drainSubmittedFrame()` → public
  - `Constants.wbCompletedDisplayMs` removed (inlined into `CalibrationViewModel`)

  ## Scaffolding still live

  _None._ Phase 1A added no scaffolds; the post-Stage-12 empty scaffold corpus is preserved.
  ```

- [ ] **Step 2: Append decision entries to `CameraKit/DECISIONS.md`.**

  The file uses one-line entries in the format `YYYY-MM-DD [stage-NN task-M] agent-id — text` (see the existing entries at the bottom of the file before the `<!-- new entries go above this line -->` marker). Add a new stage header `## Migration Phase 1A` if not present, then append the three lines below it, *above* the `<!-- new entries go above this line; keep the stage header last -->` marker:

  ```markdown
  ## Migration Phase 1A

  YYYY-MM-DD [migration-1a task-3] coordinator — CameraKitInterop temporarily exported as a SwiftPM library product so the relocated DisplayViewModel can import CppCannyStub for the DEBUG Canny edge-count overlay. Bridge state; Phase 1B removes the consumer and un-exports. Alternatives rejected: #if DEBUG-stub (regresses overlay between 1A/1B) and 1B-first ordering.

  YYYY-MM-DD [migration-1a task-7] coordinator — Stage11Tests.swift split rather than wholesale-relocated (spec §1A said "moves to the app-target test location"). 4 of 9 suites test CameraKit internals (MetalPipeline.*ForTest, SettingsPersistence, Constants.blackBalanceOverscan, MetalError) via @testable import CameraKit and have zero UI refs — they stay dual-membered in CameraKit/Tests/CameraKitTests/Stage11Tests.swift. 5 UI suites + CalibrationEngineStub + ManagedAtomicSafe move to eva-swift-stitchTests/Stage11UITests.swift (single-target — deliberate CLAUDE.md §8 exception). Total test count unchanged: 35.

  YYYY-MM-DD [migration-1a task-1] coordinator — CameraEngine.setGate(_:), drainSubmittedFrame(), dumpDeviceFormats() promoted to public. Required by the relocated ViewModel.swift (cross-module). Per spec §2e these are harness-only debug surface (no Pigeon counterpart). Surface curation (demoting other helpers to internal) is gated on Phase 2's calibration move-down and stays deferred.
  ```

  Replace `YYYY-MM-DD` on each line with the actual date these commits land. (Stage tag `migration-1a` is the convention this plan adopts since there is no `stage-NN` brief for migration work.)

- [ ] **Step 3: Build + tests one more time to make sure nothing regressed.**

  ```
  mcp__XcodeBuildMCP__build_run_device
  mcp__XcodeBuildMCP__test_device
  ```

  Expected: BUILD SUCCEEDED; 125 passed.

- [ ] **Step 4: Commit.**

  ```bash
  git add CameraKit/state.md CameraKit/DECISIONS.md
  git commit -m "docs(migration): record Phase 1A landing — UI decoupling complete

state.md: new current-stage section for Phase 1A.
DECISIONS.md: D-65 (interop product bridge), D-66 (Stage11 split), D-67
(CameraEngine public-helper promotions)."
  ```

---

## Task 10: Hand off to user

**Why:** Branch is ready; user needs to decide whether to merge to `main`, open a PR, or chain into Phase 1B (separate plan).

- [ ] **Step 1: Summary report (write into the chat, not the repo).**

  Quote: total test pass count, files moved (10 source + 1 test split), files modified (CameraEngine + Constants + CalibrationViewModel + Package.swift + state.md + DECISIONS.md + pbxproj), branch name, what's next (Phase 1B plan separately).

- [ ] **Step 2: Ask the user about integration.**

  "Phase 1A is on branch `migration/phase-1a-ui-decoupling`, all tests green on iPad. Options: (a) leave on the branch for review; (b) merge to `main`; (c) open a PR. Which?"

  Per CLAUDE.md §7, no git op beyond the commits above happens without explicit user approval.

---

## Verification — Phase 1A exit gate

Pulled verbatim from the spec (§Verification → Phase 1A). Re-check before declaring done:

- [ ] CameraKit builds headless via XcodeBuildMCP (`build_run_device`) — no SwiftUI import in the package. (`grep -rn 'import SwiftUI' CameraKit/Sources/CameraKit/` → 0 hits.)
- [ ] App builds and presents `CameraView()` from the app target on a physical iPad.
- [ ] All non-UI Stage01–Stage10 tests pass unchanged (the 4 internals suites of the original Stage11Tests included).
- [ ] Relocated `Stage11UITests.swift` (5 suites + `CalibrationEngineStub` + `ManagedAtomicSafe`) pass in the app target.
- [ ] Total test count = 125 passed / 0 failed.
- [ ] `CameraKit/CONTRACTS.md` regenerates clean.
- [ ] Scaffold inventory unchanged (`./scripts/scaffold-inventory.sh` → empty).

If any of the above does not hold, stop and surface — do not paper over.

---

## Risks + watch-outs

- **SourceKit cross-file phantoms.** After moving 10 files, expect Xcode's Issue Navigator to flag "Cannot find type X" for a minute. CLAUDE.md §6.1 covers this: build log is ground truth. If `BUILD SUCCEEDED`, ignore navigator entries. Persistent phantoms across rebuilds → nuke `~/Library/Developer/Xcode/DerivedData/eva-swift-stitch-*` and rebuild.
- **Two `CameraKitTests` groups in the pbxproj.** One at root level (dual-membered files), one nested under `CameraKit/Tests/CameraKitTests` (mostly redundant). Task 7's Ruby touches the dual-membership group only — verify post-edit with `mcp__XcodeBuildMCP__test_device` that all 4 retained internals suites still appear.
- **`extension CameraEngine: CalibrationEngineProtocol {}` after relocation.** Once `CalibrationViewModel.swift` moves to the app target, this extension declares a foreign type's conformance to a local protocol. Swift 6's `@retroactive` warning only fires when *both* are foreign — it doesn't fire here. If a compiler diagnostic surfaces anyway (e.g. Swift version skew), the fix is to write `extension CameraEngine: @retroactive CalibrationEngineProtocol {}`.
- **pre-commit hook regenerating CONTRACTS.md.** Every commit triggers a regen. If the regen detects nothing changed in the public surface (e.g. between intermediate task commits), it no-ops. After Task 1 and Task 6 commits, expect real diffs.
- **swift-format `--strict`.** New doc comments in Tasks 2 and 9 must be one-sentence-per-paragraph (CLAUDE.md §8 invariant: `BeginDocumentationCommentWithOneLineSummary` cannot be auto-fixed by `-i`). If the hook fails on a doc comment, split the first sentence onto its own line with a blank `///` separator.

---

## Out of scope (Phase 1B and Phase 2 — separate plans)

- Removing the OpenCV consumer from the package (`PixelSinkPool.cpp` stays; `CannyStubConsumer.cpp` + `CppCannyStub` relocate; `opencv2.xcframework` becomes app-side).
- Un-exporting the `CameraKitInterop` product. Phase 1B does this after rewriting `DisplayViewModel.attachAfterOpen()` so the app registers the Canny consumer via `engine.consumers.registerCallback(stream: .tracker, callbacks:)`.
- Vocabulary alignment, calibration orchestration move-down, capability range fields, `OpenConfiguration.initialSettings`, `SessionState.interrupted`, permission methods, `currentPixelBuffer(stream:)`, the `onStreamConfigurationChanged` stream, the contract amendments. All Phase 2.
- Surface curation (demoting helpers to `internal`) — gated on Phase 2's calibration move-down. Phase 1A leaves the public surface as-is plus the three deliberate promotions in Task 1.
