> **SUPERSEDED 2026-05-20** by `docs/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`. This plan targeted cam2fd integration which is no longer the architecture. Phase B's plan will be written fresh.

# Phase 3 — Plan 1: Plugin Scaffold + Pigeon Contract Amendments

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up cam2fd's iOS plugin scaffold (SPM-based, brownfield migration from the current pre-SPM stub), embed CameraKit as a `git subtree` pinned at `camerakit-v1.0.0`, and apply every §5 Pigeon contract amendment with cross-platform sweeps (Android Kotlin + Dart). Exit state: plugin builds clean on iOS with stub `notImplemented` HostApi bodies; Android side compiles + passes Android-side tests after the renames; Dart side compiles; example app launches and registers the plugin successfully.

**Architecture:** Brownfield migration. The cam2fd plugin today is pre-SPM (`ios/Classes/CambrianCameraPlugin.swift` no-op stub + `ios/cambrian_camera.podspec` globbing `Classes/**/*`). Phase 3's target layout is `ios/cambrian_camera/Sources/cambrian_camera/*.swift` next to a new `ios/cambrian_camera/Package.swift` (the SPM-spike-verified shape). CameraKit lives at `ios/CameraKit/` via `git subtree add` from the `camerakit-only` synthetic branch at tag `camerakit-v1.0.0`. The podspec stays as the CocoaPods fallback but its `source_files` glob is repointed to the new SPM-resident location. Pigeon amendments are applied one §5 sub-item at a time, each with its own `dart run pigeon` regen and Android + Dart sweep, so any single amendment's blast radius is localized.

**Tech Stack:**
- **cam2fd:** Flutter 3.35.7, Dart 3.9.2+, Pigeon 22, Swift 5 (plugin layer), Kotlin (Android side)
- **CameraKit (subtreed snapshot):** Swift 6.2, iOS 26, swift-atomics 1.2.0
- **Build:** SPM-flutter (enabled via `flutter config --enable-swift-package-manager`), `flutter build ios`, `flutter run -d <udid>`, Pigeon CLI via `dart run pigeon --input <file>`
- **Verification:** `flutter analyze`, `flutter build ios --debug --no-codesign`, on-device smoke via `flutter run -d <udid>` (physical iPad)

**Spec source:** `docs/superpowers/specs/2026-05-18-phase-3-design.md` §1 (subtree), §2 (SPM packaging), §5.1–§5.7 (contract amendments).

**Working repos:**
- `eva-swift-stitch` — plan lives here; **read-only** for Plan 1 (no source changes). Tag verification only.
- `camera2_flutter_demo` — **all writes happen here**, under `packages/cambrian_camera/`.

**Cross-repo invariant:** This plan never edits `packages/cambrian_camera/ios/CameraKit/` after the subtree-add. That directory is a release-artifact snapshot. Any CameraKit-side fix surfaces as a Plan-1 blocker → escalate back to eva-swift-stitch → tag a new release → re-subtree-pull. Per spec §11.

**Decisions baked in (from the spec):**
- **Tag pinning, not branch tracking.** Subtree pulls `camerakit-v1.0.0`; branch-tip is dev-only.
- **Hand-build SPM scaffold, not `flutter create --template=plugin`** — destructive over existing `lib/`, `android/`, `pigeons/`.
- **Podspec stays in dual-mode** — `source_files` repointed to the SPM location; CocoaPods fallback is documented but unexercised in Phase 3.
- **Plugin class name = `CambrianCameraPlugin`** — `cambrian_camera` doesn't end in `_plugin`, so the suffix is appended; today's stub already uses this; keep it.
- **One pigeon regen per §5 amendment.** Each sub-task ends with a `flutter analyze` + `flutter build` smoke so a bad amendment doesn't cascade.
- **Android Kotlin sweeps are mechanical renames + adapters.** Field rename: search + replace; signature changes: callsite update guided by compile errors.
- **iOS HostApi impls are stubs in Plan 1.** Every method body is `completion(.failure(PigeonError(code: "not_implemented", ...)))`. Plan 2 fills them in.

---

## File Inventory — Plan 1

### Created (cam2fd)

- `packages/cambrian_camera/ios/CameraKit/` — entire subtree, ~50 files; not hand-edited
- `packages/cambrian_camera/ios/cambrian_camera/Package.swift` — SPM Flutter-plugin package
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift` — registrar (stub: registers `CameraHostApiImpl` only; no methods working)
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift` — stub HostApi impl with every method returning `PigeonError("not_implemented")`
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/Messages.g.swift` — Pigeon-generated, after each B-task regen

### Modified (cam2fd)

- `packages/cambrian_camera/ios/cambrian_camera.podspec` — `s.platform` → `:ios, '26.0'`; `s.source_files` repointed
- `packages/cambrian_camera/example/ios/Runner.xcodeproj/project.pbxproj` — `IPHONEOS_DEPLOYMENT_TARGET` → `26.0` (all configs)
- `packages/cambrian_camera/example/ios/Podfile` — `platform :ios, '26.0'`
- `packages/cambrian_camera/pigeons/camera_api.dart` — §5.1, §5.2, §5.4, §5.5, §5.6, §5.7 amendments
- `packages/cambrian_camera/lib/src/messages.g.dart` — regenerated each B-task
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/Messages.g.kt` — regenerated each B-task
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt` — rename sweeps, permission method impls
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt` — rename sweeps
- `packages/cambrian_camera/android/src/main/cpp/GpuRenderer.cpp` — `rawStream*` rename (Task B1)
- `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` — rename sweeps; capture-result shape update
- `packages/cambrian_camera/lib/src/camera_settings.dart` — `enableNaturalStream` / `naturalStreamHeight` field rename
- `packages/cambrian_camera/lib/src/camera_state.dart` — `CameraCapabilities` field renames + `streamPixelFormat` addition
- `packages/cambrian_camera/lib/cambrian_camera.dart` — export surface unchanged unless a public type renames

### Deleted (cam2fd)

- `packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift` — the no-op stub. Replaced by the SPM-resident plugin file.

### Read-only (eva-swift-stitch)

- `CameraKit/CONTRACTS.md`, `CameraKit/state.md`, `CameraKit/DECISIONS.md` — read for context; no edits.

---

## Decisions taken at plan time

- **Feature branch name in cam2fd:** `phase-3-plan-1-scaffold-and-contract`. Branched from cam2fd's main (or whatever the project's default is — verified in Task 0).
- **Cluster ordering — A before B.** Scaffold first because every B-task needs a building plugin to regen Pigeon Swift output into. Doing B first would mean Pigeon Swift output lives in the legacy `Classes/` location and would need a second move.
- **§5 amendments in number order** — they're nearly independent, but doing them in spec order makes the diff log easy to follow.
- **Android Kotlin stub for `notImplemented`-style methods** — the spec's §5.6 permission methods land in Plan 1 with real Android impls (mechanical; the existing plugin already does `ContextCompat.checkSelfPermission` for the camera permission). For methods that need iOS-only Plan-2 work (e.g. the broadened captureImage signature), Android's existing impl is updated to handle the new signature; the *iOS-side stub* throws `notImplemented`.
- **No commits until each Cluster ends** — at end of Cluster A (one commit), at end of each B task (one commit each), at end of Cluster C (one commit). Lets the executor undo a single amendment by reverting one commit.

---

## Pre-flight

### Task 0: Verify tag, branch cam2fd, baseline-build the example app

**Files:** N/A (read-only orientation).

- [ ] **Step 0.1: Verify `camerakit-v1.0.0` exists on origin and points at the right SHA**

Run from `eva-swift-stitch`:

```bash
cd /Users/shrek/work/cambrian/eva-swift-stitch
git ls-remote --tags origin camerakit-v1.0.0
```

Expected output:
```
61044f842358669710db2d0e8c58b5934cbfcbb7	refs/tags/camerakit-v1.0.0
6fbdc6b6256b5a3f2d86e2ca130041663aaaf1f8	refs/tags/camerakit-v1.0.0^{}
```

The second line (`^{}`) dereferences the annotated tag to its commit SHA — `6fbdc6b` is the RGBA8 conversion commit (CameraKit's current `camerakit-only` tip). If the output differs, **STOP** and escalate.

- [ ] **Step 0.2: Confirm cam2fd state**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git status
git branch --show-current
```

Expected: clean working tree, on `main` (or whatever cam2fd's default branch is). If the branch differs from `main`, note the actual default branch name — Step 0.3 branches off it.

- [ ] **Step 0.3: Create the Plan-1 feature branch**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git checkout -b phase-3-plan-1-scaffold-and-contract
```

Expected: `Switched to a new branch 'phase-3-plan-1-scaffold-and-contract'`.

- [ ] **Step 0.4: Baseline `flutter pub get` + analyze**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera
flutter pub get
flutter analyze
```

Expected: `Got dependencies!` then `No issues found!`. Save this clean state — every Cluster A/B task's verification ends with the same commands; any new analyzer warning is task-introduced, not pre-existing.

- [ ] **Step 0.5: Inventory the connected iPad UDID (xctrace + devicectl)**

Per CLAUDE.md §8 (eva-swift-stitch) and the "two iPads" rule:

```bash
xcrun xctrace list devices 2>&1 | grep -iE "ipad"
xcrun devicectl list devices 2>&1 | grep -iE "ipad"
```

Record both the **xctrace UDID** (for `flutter run -d <udid>` later in this plan) and the **devicectl UDID** (for any device-file pulls). Save them in a scratch note for use in Task A5 and beyond.

- [ ] **Step 0.6: Enable SPM in Flutter — once per workstation**

```bash
flutter config --enable-swift-package-manager
flutter config | grep -i swift
```

Expected output includes `enable-swift-package-manager: true`. If it was already true, no harm — this is idempotent.

---

## Cluster A — Plugin scaffold (SPM brownfield migration)

### Task A1: `git subtree add` CameraKit at `camerakit-v1.0.0`

**Files:**
- Create: `packages/cambrian_camera/ios/CameraKit/` (entire subtree, populated by command)

- [ ] **Step A1.1: Verify no `ios/CameraKit/` directory exists yet**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
ls packages/cambrian_camera/ios/CameraKit 2>&1
```

Expected: `No such file or directory`. If present, **STOP** and escalate (someone may have already done this).

- [ ] **Step A1.2: Subtree-add the tagged release**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git subtree add \
  --prefix=packages/cambrian_camera/ios/CameraKit \
  https://github.com/Shreeyak/cambrian-ios-camera.git camerakit-v1.0.0 --squash
```

Expected: a single squash commit added to `phase-3-plan-1-scaffold-and-contract`, message like `Squashed 'packages/cambrian_camera/ios/CameraKit/' content from commit 6fbdc6b`.

- [ ] **Step A1.3: Verify subtree contents at the expected root**

```bash
ls packages/cambrian_camera/ios/CameraKit/
```

Expected (in some order):
```
CONTRACTS.md
DECISIONS.md
Package.resolved
Package.swift
Sources/
Tests/
state.md
```

If `Sources/CameraKit/CameraEngine.swift` or `Package.swift` is missing at the top level (e.g. you see a nested `CameraKit/` directory), the synthetic-branch shape is wrong — **STOP**.

- [ ] **Step A1.4: Quick read of the subtreed `Package.swift`**

```bash
head -30 packages/cambrian_camera/ios/CameraKit/Package.swift
```

Expected: `name: "CameraKit"`, `platforms: [.iOS(.v26)]`, three targets (`CameraKitCxx`, `CameraKitInterop`, `CameraKit`), `cxxLanguageStandard: .cxx20`. This is what the new plugin's `Package.swift` (Task A2) references via `.package(path: "../CameraKit")`.

- [ ] **Step A1.5: Commit the subtree add — already committed by `subtree add`**

`git subtree add --squash` makes its own commit; nothing more to do here. Verify with:

```bash
git log --oneline -3
```

Expected: top commit is the squash, message references `6fbdc6b` (CameraKit's tip).

---

### Task A2: Hand-build the SPM scaffold under `ios/cambrian_camera/`

**Files:**
- Create: `packages/cambrian_camera/ios/cambrian_camera/Package.swift`
- Create: `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift` (real, replaces stub)
- Create: `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift` (stub HostApi)
- Delete (after move): `packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift`

- [ ] **Step A2.1: Create the new directory structure**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
mkdir -p packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera
```

- [ ] **Step A2.2: Write `ios/cambrian_camera/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cambrian_camera",
    platforms: [.iOS("26.0")],
    products: [
        // Kebab-case product name — Flutter's auto-generated
        // FlutterGeneratedPluginSwiftPackage umbrella references it as
        // .product(name: "cambrian-camera", ...). Mismatch breaks discovery.
        .library(name: "cambrian-camera", targets: ["cambrian_camera"]),
    ],
    dependencies: [
        // Local sibling — checked-in via git subtree from camerakit-only.
        .package(path: "../CameraKit"),
    ],
    targets: [
        .target(
            name: "cambrian_camera",
            dependencies: [
                .product(name: "CameraKit", package: "CameraKit"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                // Plugin layer stays at Swift 5 to dodge the
                // FlutterMethodNotImplemented Sendable warning under strict Swift 6.
                // CameraKit's three internal targets stay Swift 6.
                .swiftLanguageMode(.v5),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
```

Path: `packages/cambrian_camera/ios/cambrian_camera/Package.swift`.

- [ ] **Step A2.3: Write the registrar at the new location**

Path: `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift`.

```swift
import Flutter
import CameraKit

/// Cambrian camera iOS plugin — registrar.
///
/// Plan 1 wires only the HostApi-implementation registration. Method bodies
/// are stubs throwing `not_implemented`. Plan 2 fills in real impls; Plan 4
/// HITL-verifies on device.
public class CambrianCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let api = CameraHostApiImpl()
        CameraHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)
    }
}
```

The `import CameraKit` is what makes the subtreed package's public surface
visible. If this `import` fails at build time, the SPM linkage is wrong
(go back to A2.2).

- [ ] **Step A2.4: Write the stub `CameraHostApiImpl`**

Path: `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift`.

```swift
import Flutter
import Foundation

/// Stub HostApi impl — Plan 1 deliverable. Every method returns
/// `PigeonError(code: "not_implemented", ...)`. Plan 2 replaces each body
/// with a real CameraEngine call via the handle registry.
final class CameraHostApiImpl: CameraHostApi {

    // All HostApi methods follow the same shape — each returns a Pigeon
    // not_implemented error. The exact list is regenerated at the end of
    // Cluster B (every §5 amendment that adds a method updates this file).
    // For Plan 1's initial commit, populate with the methods that exist in
    // the current pigeons/camera_api.dart before any §5 amendment is
    // applied. Cluster B tasks each add their new methods here as
    // additional stubs.

    func open(cameraId: String?, settings: CamSettings?,
              completion: @escaping (Result<Int64, Error>) -> Void) {
        completion(.failure(notImplemented("open")))
    }

    func getCapabilities(handle: Int64,
                         completion: @escaping (Result<CamCapabilities, Error>) -> Void) {
        completion(.failure(notImplemented("getCapabilities")))
    }

    func updateSettings(handle: Int64, settings: CamSettings) throws {
        throw notImplemented("updateSettings")
    }

    func setResolution(handle: Int64, width: Int64, height: Int64,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("setResolution")))
    }

    func setProcessingParams(handle: Int64, params: CamProcessingParams) throws {
        throw notImplemented("setProcessingParams")
    }

    func captureNaturalPicture(handle: Int64,
                               completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("captureNaturalPicture")))
    }

    func captureImage(handle: Int64, outputDirectory: String?, fileName: String?,
                      completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("captureImage")))
    }

    func getNativePipelineHandle(handle: Int64,
                                 completion: @escaping (Result<Int64?, Error>) -> Void) {
        completion(.failure(notImplemented("getNativePipelineHandle")))
    }

    func startRecording(handle: Int64, outputDirectory: String?, fileName: String?,
                        bitrate: Int64?, fps: Int64?,
                        completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("startRecording")))
    }

    func stopRecording(handle: Int64,
                       completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("stopRecording")))
    }

    func close(handle: Int64,
               completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("close")))
    }

    func pause(handle: Int64,
               completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("pause")))
    }

    func resume(handle: Int64,
                completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("resume")))
    }

    func getPersistedProcessingParams(handle: Int64) throws -> CamProcessingParams? {
        throw notImplemented("getPersistedProcessingParams")
    }

    func sampleCenterPatch(handle: Int64,
                           completion: @escaping (Result<CamRgbSample, Error>) -> Void) {
        completion(.failure(notImplemented("sampleCenterPatch")))
    }

    private func notImplemented(_ name: String) -> PigeonError {
        PigeonError(code: "not_implemented",
                    message: "\(name) is not yet implemented in Phase 3 Plan 1.",
                    details: nil)
    }
}
```

**Note:** The exact method list MUST match what's in
`packages/cambrian_camera/ios/Classes/Messages.g.swift` *after* Task B1's
regen rewrites it to the new location. If a method is missing here, the
Swift compiler will error "type 'CameraHostApiImpl' does not conform to
protocol 'CameraHostApi'" — at which point look at the generated
`Messages.g.swift` for the required signatures and add the stubs.

- [ ] **Step A2.5: Delete the old `ios/Classes/CambrianCameraPlugin.swift` stub**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git rm packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift
```

Expected: `rm 'packages/cambrian_camera/ios/Classes/CambrianCameraPlugin.swift'`.

- [ ] **Step A2.6: Repoint Pigeon's `swiftOut` to the SPM source tree**

The existing `Messages.g.swift` lives at `packages/cambrian_camera/ios/Classes/Messages.g.swift` (from a previous pigeon run). The SPM-resident layout needs the generated file inside `Sources/cambrian_camera/` so the target's automatic source glob picks it up. The cleanest path is to repoint Pigeon's `swiftOut` config now, then regenerate in Task B1.

Edit `packages/cambrian_camera/pigeons/camera_api.dart` — find the `@ConfigurePigeon` block at the top:

```diff
 @ConfigurePigeon(
   PigeonOptions(
     dartOut: 'lib/src/messages.g.dart',
     dartOptions: DartOptions(),
     kotlinOut: 'android/src/main/kotlin/com/cambrian/camera/Messages.g.kt',
     kotlinOptions: KotlinOptions(package: 'com.cambrian.camera'),
-    swiftOut: 'ios/Classes/Messages.g.swift',
+    swiftOut: 'ios/cambrian_camera/Sources/cambrian_camera/Messages.g.swift',
     swiftOptions: SwiftOptions(),
     copyrightHeader: 'pigeons/copyright.txt',
   ),
 )
```

**Don't regenerate yet** — Task B1.2 runs the first post-A2 regen as part of the rename amendment. Until B1.2, the SPM target has no `Messages.g.swift` and the build will fail with `cannot find 'CameraHostApi' in scope`. That's expected and resolves at B1.2.

- [ ] **Step A2.7: Delete the stale `ios/Classes/Messages.g.swift`**

Since the new Pigeon swiftOut puts the file in the SPM tree, the legacy `Classes/` copy is dead weight. Delete it (Task B1.2 won't regenerate to the old path):

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git rm packages/cambrian_camera/ios/Classes/Messages.g.swift
```

If `git rm` complains that the file is not tracked (e.g. it's gitignored in a generated-files pattern), use plain `rm`. Expected after: nothing left under `ios/Classes/` (the directory itself can stay empty; the podspec source_files glob now ignores it).

Update the podspec source_files glob (Task A3 sets the final state — for now just be aware that `'Classes/**/*'` no longer matches anything).

- [ ] **Step A2.8: Quick smoke compile — expected to fail with missing-symbol error**

```bash
cd packages/cambrian_camera/ios/cambrian_camera
xcodebuild -scheme cambrian-camera -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -30
```

Expected failure: `cannot find 'CameraHostApi' in scope` (or similar) — because `Messages.g.swift` was deleted in A2.7 and hasn't been regenerated to the new SPM path yet. This is EXPECTED at this stage. Task B1.2's `dart run pigeon` fills the gap.

What you should NOT see:
- `no such module 'CameraKit'` → SPM linkage broken; re-check A2.2's `dependencies` block.
- A successful build → A2.7's delete didn't take; verify with `find . -name "Messages.g.swift"`.

The Cluster B sequence is the only way to make this build succeed; that's by design. Proceed to A3, then A4, then A5 (which will likely also fail at the build stage until B1.2 runs), then begin Cluster B.

**Alternative if you want a clean intermediate build before Cluster B:**
Run `dart run pigeon --input packages/cambrian_camera/pigeons/camera_api.dart` early (between A2 and A3) to populate the new `Messages.g.swift` location *before* any §5 amendment. The build then succeeds, and Cluster B's per-amendment regens just rewrite the file in place. This is fine; the only reason the plan defers regen to B1.2 is to keep "regenerate" colocated with its amendment for the commit log.

---

### Task A3: Update `cambrian_camera.podspec` — repoint `source_files`, bump iOS 26

**Files:**
- Modify: `packages/cambrian_camera/ios/cambrian_camera.podspec`

- [ ] **Step A3.1: Read the current podspec**

Path: `packages/cambrian_camera/ios/cambrian_camera.podspec`.

Current content (already known — captured during Phase 3 spec):

```ruby
Pod::Spec.new do |s|
  s.name             = 'cambrian_camera'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for Cambrian camera with Camera2 backend.'
  s.homepage         = 'https://cambrian.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Cambrian' => 'dev@cambrian.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
```

- [ ] **Step A3.2: Rewrite to the post-Plan-1 shape**

Replace the file contents with:

```ruby
Pod::Spec.new do |s|
  s.name             = 'cambrian_camera'
  s.version          = '0.1.0'
  s.summary          = 'Flutter plugin for Cambrian camera (iOS + Android).'
  s.homepage         = 'https://cambrian.ai'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Cambrian' => 'dev@cambrian.ai' }
  s.source           = { :path => '.' }

  # Plan 1 (2026-05-18): repointed from 'Classes/**/*' (legacy pre-SPM layout)
  # to the SPM-resident sources under ios/cambrian_camera/Sources/. The plugin
  # registrar, HostApi impl, AND the Pigeon-generated Messages.g.swift all
  # live under the new SPM source tree (Pigeon swiftOut was repointed in
  # A2.6). The legacy ios/Classes/ directory is no longer used.
  s.source_files = 'cambrian_camera/Sources/cambrian_camera/**/*.swift'

  s.dependency 'Flutter'
  s.platform         = :ios, '26.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Match the SPM target's Swift settings — the podspec fallback compiles
    # the same source under CocoaPods. Cxx-interop is required to import
    # CameraKit's swiftmodule.
    'OTHER_SWIFT_FLAGS' => '$(inherited) -cxx-interoperability-mode=default'
  }
  s.swift_version = '5.0'
end
```

- [ ] **Step A3.3: Validate the podspec syntax**

```bash
cd packages/cambrian_camera/ios
pod lib lint cambrian_camera.podspec --no-clean 2>&1 | tail -40
```

Expected: warnings about missing `summary` length or similar cosmetic items are OK; **no `ERROR`**. If a hard error appears, fix it before continuing.

If `pod` is not installed (`command not found: pod`), skip this step — the podspec only matters for the CocoaPods fallback path, which Plan 3/4 doesn't exercise. Document the skip in the commit message.

---

### Task A4: Bump example app to iOS 26 + run `flutter build` for umbrella migration

**Files:**
- Modify: `packages/cambrian_camera/example/ios/Runner.xcodeproj/project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET` for all configurations)
- Modify: `packages/cambrian_camera/example/ios/Podfile`

- [ ] **Step A4.1: Bump `IPHONEOS_DEPLOYMENT_TARGET` to 26.0 in all build configurations**

Use the Xcode-aware `xcodeproj` Ruby gem (per eva-swift-stitch CLAUDE.md §6, the safe path for programmatic project edits):

```bash
cd packages/cambrian_camera/example/ios
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('Runner.xcodeproj')
count = 0
p.targets.each do |t|
  t.build_configurations.each do |c|
    c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    count += 1
  end
end
p.save
puts \"Updated #{count} build configurations.\""
```

Expected: `Updated 6 build configurations.` (or similar; depends on Runner + RunnerTests configs).

If `xcodeproj` is not installed (`LoadError: cannot load such file -- xcodeproj`):

```bash
sudo gem install xcodeproj
```

Then re-run the ruby block.

- [ ] **Step A4.2: Bump `platform :ios, '26.0'` in the example app's Podfile**

Path: `packages/cambrian_camera/example/ios/Podfile`.

Find the `platform :ios, '<X>'` line near the top; replace with `platform :ios, '26.0'`. If the line is currently commented (`# platform :ios, '12.0'`), uncomment and set to `26.0`.

If no Podfile exists yet (fresh Flutter SPM setup), it will be generated on first `flutter build`. Note this and proceed to A4.3.

- [ ] **Step A4.3: Run `flutter pub get` + `flutter build ios` to trigger the SPM umbrella migration**

```bash
cd packages/cambrian_camera/example
flutter pub get
flutter build ios --debug --no-codesign 2>&1 | tee /tmp/phase3-plan1-A4-build.log | tail -40
```

Expected output ends with: `Built build/ios/iphoneos/Runner.app`. The full log goes to `/tmp/phase3-plan1-A4-build.log` for inspection on failure.

**Known migration step:** Flutter's tooling runs a one-time umbrella platform bump (from iOS 13 to iOS 26) when it detects the project target is higher. This shows in the log as the umbrella's `Package.swift` updating. If you see:

```
error: The package product 'cambrian-camera' requires minimum platform
       version 26.0 for the iOS platform, but this target supports 13.0
```

…it means the migration didn't fire. Force-trigger by deleting Flutter's ephemeral package cache and re-building:

```bash
rm -rf ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage
flutter build ios --debug --no-codesign 2>&1 | tail -20
```

The migration should fire on the second build.

- [ ] **Step A4.4: Verify the SPM artifacts are present**

```bash
ls -la build/ios/Debug-iphoneos/cambrian_camera_cambrian_camera.bundle/ 2>&1
ls -la build/ios/iphoneos/Runner.app/Frameworks/ 2>&1
```

Expected: the plugin's resource bundle is built (if any resources exist; CameraKit ships its own `default.metallib`); `Runner.app/Frameworks/` contains either nothing for the plugin (static-linked into `Runner.debug.dylib`) or `cambrian-camera.framework` (if dynamic).

Additional sanity probe:

```bash
nm build/ios/iphoneos/Runner.app/Runner | grep -i CambrianCameraPlugin | head -5
```

Expected: at least one match. If empty, the plugin Swift code didn't link — re-check A2.7's symlink and A4.3's build log.

---

### Task A5: On-device smoke — example app launches, plugin registers, all methods throw `not_implemented`

**Files:** N/A (run-only).

- [ ] **Step A5.1: Pick the connected iPad UDID**

Use the xctrace UDID recorded in Step 0.5. For documentation purposes the rest of this plan uses `<IPAD_UDID>` as a placeholder — substitute the real UDID.

Verify the device is connected:

```bash
xcrun xctrace list devices 2>&1 | grep "$IPAD_UDID"
```

Expected: one line for the connected iPad, no "(unavailable)" suffix.

- [ ] **Step A5.2: Run on device with `flutter run`**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera/example
flutter run -d <IPAD_UDID> --debug 2>&1 | tee /tmp/phase3-plan1-A5-run.log
```

Expected: app launches; the Flutter splash and the example UI appear; no immediate crash.

`r` in the running session triggers hot-reload; `q` quits.

- [ ] **Step A5.3: Verify the plugin is registered**

Look for these lines in `/tmp/phase3-plan1-A5-run.log`:

- A `Compiling cambrian_camera for iOS` or similar from the Flutter tooling.
- No `MissingPluginException` errors from any of the example's existing Dart code (the example app uses the plugin's Dart layer; method calls without an iOS impl will throw `MissingPluginException`).
- If the example app calls any HostApi method on startup, the iOS plugin must respond with the `PigeonError(code: "not_implemented", ...)` that the stub throws — NOT a `MissingPluginException` (the latter means the registrar didn't run).

If `MissingPluginException` appears for `CameraHostApi.*` methods, the plugin's `register(with:)` is not running. Common causes:
1. Plugin class name mismatch in `pubspec.yaml` (`pluginClass: CambrianCameraPlugin` must match the Swift class).
2. SPM linkage broken — `CambrianCameraPlugin.swift` didn't compile into `cambrian-camera`.
3. Flutter's plugin registrant didn't pick up the SPM plugin — re-check Task A4's umbrella migration.

- [ ] **Step A5.4: Trigger one HostApi call from the running app (if the example exposes a button)**

If the example app has a "Initialize Camera" button or similar, tap it. Expected behavior: the call returns `not_implemented` error to Dart. Acceptable Dart-side responses (any of these is fine):

- Error dialog showing "PlatformException: not_implemented"
- Console log: `Unhandled Exception: PlatformException(not_implemented, open is not yet implemented in Phase 3 Plan 1., null, null)`
- Any visible indication that the method ran iOS-side and returned an error

The point of A5 is to prove the **wire is connected**, not that the impl works.

- [ ] **Step A5.5: Quit and commit the Cluster A scaffold**

In the `flutter run` session: press `q` to quit.

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git add packages/cambrian_camera/ios/CameraKit/  # was added by subtree but verify
git add packages/cambrian_camera/ios/cambrian_camera/
git add packages/cambrian_camera/ios/cambrian_camera.podspec
git add packages/cambrian_camera/example/ios/Runner.xcodeproj/project.pbxproj
git add packages/cambrian_camera/example/ios/Podfile  # if modified
git status
```

Expected `git status`: the modifications above are staged; the old `ios/Classes/CambrianCameraPlugin.swift` is staged for deletion. No other modifications.

Commit (per cam2fd's commit convention — verify with `git log --oneline -5` first; the eva-swift-stitch convention may not apply here):

```bash
git commit -m "feat(ios): Phase 3 Plan 1 Cluster A — SPM scaffold + CameraKit subtree

- git subtree add CameraKit at camerakit-v1.0.0 →
  packages/cambrian_camera/ios/CameraKit/ (snapshot, not hand-edited)
- New SPM Flutter-plugin scaffold at ios/cambrian_camera/Package.swift +
  Sources/cambrian_camera/ (CambrianCameraPlugin + stub CameraHostApiImpl)
- Old pre-SPM stub at ios/Classes/CambrianCameraPlugin.swift removed
- Podspec source_files repointed to SPM location; platform → iOS 26
- Example app iOS deployment target bumped to 26.0
- flutter build triggered umbrella migration to iOS 26
- On-device smoke: example app launches; HostApi calls return
  not_implemented via the stub

Spec: docs/superpowers/specs/2026-05-18-phase-3-design.md §1, §2.
Plan: docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md.

Phase 2 in CameraKit is consumed verbatim from camerakit-v1.0.0; no
edits to the subtreed contents.
"
```

**Note:** if cam2fd's commit convention requires a `Co-Authored-By:` trailer (eva-swift-stitch does), include it; otherwise omit. Verify with `git log -3 --format='%B' | tail -20`.

---

## Cluster B — Pigeon contract amendments (§5)

### Task B1: §5.1 — `rawStream*` → `naturalStream*`

**Files:**
- Modify: `packages/cambrian_camera/pigeons/camera_api.dart`
- Regenerated: `lib/src/messages.g.dart`, `ios/Classes/Messages.g.swift`, `android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`
- Sweep: `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`, `CameraController.kt`, `GpuRenderer.cpp` (if any)
- Sweep: `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart`, `lib/src/camera_settings.dart`, `lib/src/camera_state.dart`
- Sweep: `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift`

- [ ] **Step B1.1: Edit `pigeons/camera_api.dart` — 5 field renames**

In `pigeons/camera_api.dart`, find class `CamSettings` and rename:

```diff
-    this.enableRawStream,
-    this.rawStreamHeight,
+    this.enableNaturalStream,
+    this.naturalStreamHeight,
```

And in the field declarations within `CamSettings`:

```diff
-  /// Enable GPU raw (passthrough) stream. Null = don't change.
-  bool? enableRawStream;
+  /// Enable GPU natural (unprocessed/passthrough) stream. Null = don't change.
+  bool? enableNaturalStream;

-  /// Requested height of the GPU raw stream in pixels. Null = don't change. 0 = use default.
-  int? rawStreamHeight;
+  /// Requested height of the GPU natural stream in pixels. Null = don't change. 0 = use default.
+  int? naturalStreamHeight;
```

In class `CamCapabilities` constructor and fields:

```diff
-    required this.rawStreamTextureId,
-    required this.rawStreamWidth,
-    required this.rawStreamHeight,
+    required this.naturalStreamTextureId,
+    required this.naturalStreamWidth,
+    required this.naturalStreamHeight,
```

```diff
-  /// Flutter texture ID for the GPU raw stream (passthrough, no color adjustments).
-  /// 0 if raw stream is disabled.
-  int rawStreamTextureId;
+  /// Flutter texture ID for the GPU natural stream (passthrough, no color adjustments).
+  /// 0 if natural stream is disabled.
+  int naturalStreamTextureId;

-  /// Actual computed width of the GPU raw stream (pixels). 0 if raw stream is disabled.
-  int rawStreamWidth;
+  /// Actual computed width of the GPU natural stream (pixels). 0 if natural stream is disabled.
+  int naturalStreamWidth;

-  /// Requested height of the GPU raw stream (pixels). 0 if raw stream is disabled.
-  int rawStreamHeight;
+  /// Requested height of the GPU natural stream (pixels). 0 if natural stream is disabled.
+  int naturalStreamHeight;
```

- [ ] **Step B1.2: Regenerate Pigeon outputs**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```

Expected output ends with the generated files listed:
```
lib/src/messages.g.dart
android/src/main/kotlin/com/cambrian/camera/Messages.g.kt
ios/Classes/Messages.g.swift
```

If `dart run pigeon` fails with `Could not find package "pigeon"`:

```bash
dart pub get
dart run pigeon --input pigeons/camera_api.dart
```

- [ ] **Step B1.3: Verify the regenerated outputs contain the new names**

```bash
grep -n "enableNaturalStream\|naturalStreamHeight\|naturalStreamTextureId" \
  lib/src/messages.g.dart \
  android/src/main/kotlin/com/cambrian/camera/Messages.g.kt \
  ios/Classes/Messages.g.swift
```

Expected: hits in all three files (Dart, Kotlin, Swift). If any file has zero hits, the regen didn't take — re-run B1.2.

- [ ] **Step B1.4: Sweep Android Kotlin (`CambrianCameraPlugin.kt`, `CameraController.kt`)**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera
grep -rn "rawStream\b\|enableRawStream\|rawStreamHeight\|rawStreamTextureId\|rawStreamWidth" android/src/
```

For every match in `*.kt` files, replace the symbol:
- `enableRawStream` → `enableNaturalStream`
- `rawStreamHeight` → `naturalStreamHeight`
- `rawStreamTextureId` → `naturalStreamTextureId`
- `rawStreamWidth` → `naturalStreamWidth`

(Note: the simple word `rawStream` may also appear in `GpuRenderer.cpp` or comments; rename accordingly. Use editor's "rename symbol" or sed where appropriate.)

Verify:
```bash
grep -rn "rawStream\b\|enableRawStream" android/src/ packages/cambrian_camera/android/src/
```

Expected: zero hits.

- [ ] **Step B1.5: Sweep Dart**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera
grep -rn "rawStream\b\|enableRawStream\|rawStreamHeight\|rawStreamTextureId\|rawStreamWidth" lib/
```

Apply the same renames in every match (excluding regenerated `messages.g.dart`, which is already correct):

- `lib/src/cambrian_camera_controller.dart` — every callsite
- `lib/src/camera_settings.dart` — the public `CameraSettings` field if exposed
- `lib/src/camera_state.dart` — `CameraCapabilities` field rename
- `lib/cambrian_camera.dart` — if any exports reference these

Verify:
```bash
grep -rn "rawStream\b\|enableRawStream" lib/ --exclude=messages.g.dart
```

Expected: zero hits.

- [ ] **Step B1.6: Sweep iOS stub `CameraHostApiImpl.swift`**

The stub from Task A2 doesn't actually reference `rawStream*` field names (it uses `CamSettings` opaquely as a parameter). No edit needed unless the regen changed a signature. Verify:

```bash
grep -n "rawStream" packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift
```

Expected: zero hits.

- [ ] **Step B1.7: Build smoke — Android + iOS + Dart**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo/packages/cambrian_camera
flutter analyze 2>&1 | tail -10
```

Expected: `No issues found!`. If there are issues, fix them per the analyzer output (likely missed Dart callsites).

```bash
cd example
flutter build ios --debug --no-codesign 2>&1 | tail -5
```

Expected: `Built build/ios/iphoneos/Runner.app`.

```bash
flutter build apk --debug 2>&1 | tail -10
```

Expected: `Built build/app/outputs/flutter-apk/app-debug.apk` (or platform-specific success line). If Kotlin compile fails, the Android sweep missed a callsite — find via `flutter build apk` error output, fix, re-run.

- [ ] **Step B1.8: Commit Task B1**

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git add packages/cambrian_camera/pigeons/camera_api.dart
git add packages/cambrian_camera/lib/
git add packages/cambrian_camera/android/
git add packages/cambrian_camera/ios/Classes/Messages.g.swift
git commit -m "refactor(pigeon): §5.1 rename rawStream* → naturalStream* (Phase 3 §5.1)

Renames in pigeons/camera_api.dart:
- CamSettings.enableRawStream → enableNaturalStream
- CamSettings.rawStreamHeight → naturalStreamHeight
- CamCapabilities.rawStreamTextureId → naturalStreamTextureId
- CamCapabilities.rawStreamWidth → naturalStreamWidth
- CamCapabilities.rawStreamHeight → naturalStreamHeight

Aligns the wire vocabulary with CameraKit's 'natural' terminology (Phase 2
already uses .natural everywhere on the engine side). 'Raw' was an
Android-derived name from the Camera2 era.

Regenerated lib/src/messages.g.dart, android Messages.g.kt, ios
Messages.g.swift. Swept Android Kotlin (CambrianCameraPlugin.kt,
CameraController.kt, GpuRenderer.cpp) and Dart
(cambrian_camera_controller.dart, camera_settings.dart, camera_state.dart).

flutter analyze: clean. iOS + Android builds: pass.
"
```

---

### Task B2: §5.2 — `onCapabilitiesChanged` → `onStreamConfigurationChanged` + `CamStreamConfiguration`

**Files:**
- Modify: `packages/cambrian_camera/pigeons/camera_api.dart`
- Regenerated: same 3 outputs as B1
- Sweep: Android `CameraController.kt` (callsites of `onCapabilitiesChanged`); Dart `cambrian_camera_controller.dart`

- [ ] **Step B2.1: Add the new `CamStreamConfiguration` type in `pigeons/camera_api.dart`**

After the existing `CamCapabilities` class declaration, add:

```dart
/// Lean payload for the active stream-configuration change callback.
///
/// Emitted on the active selection changing (after [CameraHostApi.setResolution]
/// resolves or after [CamSettings.cropOutputSize] is set/cleared) — distinct
/// from the heavier [CamCapabilities] which is a one-time bootstrap surface
/// retrieved via [CameraHostApi.getCapabilities].
///
/// The texture-ID fields ([naturalTextureId], [previewTextureId]) are stable
/// across the open session — they are minted at [CameraHostApi.open] time and
/// carried on every change emission so a Dart consumer never needs a
/// separate getCapabilities round-trip after a configuration change.
class CamStreamConfiguration {
  CamStreamConfiguration({
    required this.captureWidth,
    required this.captureHeight,
    this.cropWidth,
    this.cropHeight,
    required this.naturalTextureId,
    required this.previewTextureId,
  });

  /// Width of the active capture stream (sensor output before any GPU crop).
  int captureWidth;

  /// Height of the active capture stream.
  int captureHeight;

  /// Width of the active GPU center crop. Null = no crop (full capture).
  int? cropWidth;

  /// Height of the active GPU center crop. Null = no crop (full capture).
  int? cropHeight;

  /// Flutter texture ID for the natural-stream lane. Stable across the open session.
  int naturalTextureId;

  /// Flutter texture ID for the processed (post-color-pipeline) preview lane.
  /// Stable across the open session.
  int previewTextureId;
}
```

- [ ] **Step B2.2: Replace the `onCapabilitiesChanged` callback in `CameraFlutterApi`**

In `pigeons/camera_api.dart`, find class `CameraFlutterApi`:

```diff
-  /// Called when the effective post-GPU output dimensions change — e.g.
-  /// after `cropOutputSize` is set or cleared, or after `setResolution`
-  /// resolves to a new camera stream size. Dart consumers should replace
-  /// their cached [CamCapabilities] with the new value.
-  void onCapabilitiesChanged(int handle, CamCapabilities capabilities);
+  /// Called when the active stream configuration changes — after
+  /// `cropOutputSize` is set or cleared, or after `setResolution` resolves
+  /// to a new camera stream size. The payload's texture-ID fields are
+  /// stable across the open session and are repeated on every change so
+  /// Dart consumers do not need a separate `getCapabilities` round-trip.
+  void onStreamConfigurationChanged(int handle, CamStreamConfiguration configuration);
```

- [ ] **Step B2.3: Regenerate**

```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```

Expected: regenerates 3 outputs without errors.

- [ ] **Step B2.4: Sweep Android Kotlin emit sites**

```bash
grep -rn "onCapabilitiesChanged" android/src/
```

Every match in `*.kt` is a call into the (now-removed) FlutterApi method. Replace each with a `CamStreamConfiguration` construction + `onStreamConfigurationChanged` call:

```kotlin
// BEFORE:
flutterApi.onCapabilitiesChanged(handle, latestCapabilities)
// AFTER (build the lean type from already-known fields):
val cfg = CamStreamConfiguration(
    captureWidth  = sensorStreamWidth.toLong(),
    captureHeight = sensorStreamHeight.toLong(),
    cropWidth     = activeCropOutputSize?.width?.toLong(),
    cropHeight    = activeCropOutputSize?.height?.toLong(),
    naturalTextureId = naturalSurfaceProducer.id(),
    previewTextureId = processedSurfaceProducer.id(),
)
flutterApi.onStreamConfigurationChanged(handle, cfg) { /* completion ignored */ }
```

Exact local-variable names depend on `CameraController.kt`'s existing fields — adapt to what's there. Verify:

```bash
grep -rn "onCapabilitiesChanged" android/src/
```

Expected: zero hits.

- [ ] **Step B2.5: Sweep Dart**

```bash
grep -rn "onCapabilitiesChanged" lib/ --exclude=messages.g.dart
```

Every match is a Dart-side consumer of the old callback (likely in `cambrian_camera_controller.dart`'s state notifier or a stream subscription). Replace per:

```dart
// BEFORE:
void onCapabilitiesChanged(int handle, CamCapabilities capabilities) {
  _capabilities = capabilities;  // cache update
  notifyListeners();
}
// AFTER:
void onStreamConfigurationChanged(int handle, CamStreamConfiguration configuration) {
  // Apply the lean update; the full CamCapabilities cache stays unchanged
  // (only re-fetched via getCapabilities() if needed). The texture-ID and
  // active-size fields carry the change.
  _activeCaptureSize = CameraSize(width: configuration.captureWidth, height: configuration.captureHeight);
  _activeCropSize = configuration.cropWidth != null
      ? CameraSize(width: configuration.cropWidth!, height: configuration.cropHeight!)
      : null;
  _naturalTextureId = configuration.naturalTextureId;
  _previewTextureId = configuration.previewTextureId;
  notifyListeners();
}
```

Adapt to the controller's actual state shape. Verify:

```bash
grep -rn "onCapabilitiesChanged" lib/ --exclude=messages.g.dart
```

Expected: zero hits.

- [ ] **Step B2.6: iOS stub — no edit needed**

The stub doesn't implement `CameraFlutterApi` (it only implements `CameraHostApi`); `CameraFlutterApi` is *called from* native, not *implemented* in native. Skip.

- [ ] **Step B2.7: Build smoke**

```bash
cd packages/cambrian_camera
flutter analyze 2>&1 | tail -10
cd example
flutter build ios --debug --no-codesign 2>&1 | tail -5
flutter build apk --debug 2>&1 | tail -5
```

Expected: all three succeed.

- [ ] **Step B2.8: Commit Task B2**

```bash
git add packages/cambrian_camera/pigeons/camera_api.dart
git add packages/cambrian_camera/lib/
git add packages/cambrian_camera/android/
git add packages/cambrian_camera/ios/Classes/Messages.g.swift
git commit -m "refactor(pigeon): §5.2 onCapabilitiesChanged → onStreamConfigurationChanged

Replaces the heavy CamCapabilities-payload callback with a lean
CamStreamConfiguration payload (capture size, crop size, both texture
IDs). The texture-ID fields are stable across the open session — minted
by Plan 2's texture bridge at open() time and carried on every emission
so consumers never need a separate getCapabilities round-trip after a
configuration change.

CamCapabilities stays as the one-time bootstrap surface via
CameraHostApi.getCapabilities; only the change callback narrows.

Regenerated 3 outputs. Swept Android emit sites (CameraController.kt)
and Dart consumers (cambrian_camera_controller.dart).
"
```

---

### Task B3: §5.4 — `captureImage` / `captureNaturalPicture` broadened with `CamPhotosDestination` + `CamCaptureResult` return type

**Files:** as B2.

**⚠️ This task includes a return-type breaking change.** Existing Dart callers chained `.then((path) => ...)` on the old `String` return; they now read `result.filePath ?? throw`. Spec §5.4 explicitly flags this.

- [ ] **Step B3.1: Add `CamPhotosDestination` + `CamCaptureResult` types in `pigeons/camera_api.dart`**

After the existing `CamRgbSample` class declaration, add:

```dart
/// Destination for image-capture output on iOS Photos / Android MediaStore.
///
/// When [saveToLibrary] is true: iOS writes through PHPhotoLibrary and yields
/// a PHAsset local identifier (no filesystem path); Android writes through
/// MediaStore and yields a content URI / file path. When false: both
/// platforms write to filesystem at the [CameraHostApi.captureImage]
/// `outputDirectory` + `fileName` arguments and yield the filesystem path.
class CamPhotosDestination {
  CamPhotosDestination({this.albumName, required this.saveToLibrary});

  /// Optional album name on iOS Photos. Ignored on Android.
  String? albumName;

  /// If true, save to the platform photo library (Photos / MediaStore).
  /// If false, write to filesystem at the host method's outputDirectory + fileName.
  bool saveToLibrary;
}

/// Result of an image capture.
///
/// One of [filePath] / [phAssetLocalId] is non-null depending on the
/// [CamPhotosDestination.saveToLibrary] flag and platform:
/// - iOS + saveToLibrary == true: [phAssetLocalId] populated; [filePath] null.
/// - iOS + saveToLibrary == false (or null destination): [filePath] populated.
/// - Android (any destination): [filePath] populated; [phAssetLocalId] null.
class CamCaptureResult {
  CamCaptureResult({this.filePath, this.phAssetLocalId});
  String? filePath;
  String? phAssetLocalId;
}
```

- [ ] **Step B3.2: Broaden the two capture methods in `CameraHostApi`**

```diff
   /// Captures a still JPEG image using Camera2's hardware ISP. (iOS: natural-lane tap.)
-  @async
-  String captureNaturalPicture(int handle);
+  @async
+  CamCaptureResult captureNaturalPicture(
+    int handle,
+    String? outputDirectory,
+    String? fileName,
+    CamPhotosDestination? destination,
+  );

   /// Captures the next GPU post-processed frame and saves it.
-  @async
-  String captureImage(int handle, String? outputDirectory, String? fileName);
+  @async
+  CamCaptureResult captureImage(
+    int handle,
+    String? outputDirectory,
+    String? fileName,
+    CamPhotosDestination? destination,
+  );
```

Update the doc comments above each method to mention the destination + return shape.

- [ ] **Step B3.3: Regenerate**

```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```

- [ ] **Step B3.4: Sweep Android Kotlin impls**

```bash
grep -rn "captureImage\|captureNaturalPicture" android/src/main/kotlin/
```

For each callsite, update the signature + return type:

```kotlin
// BEFORE:
override fun captureImage(
    handle: Long, outputDirectory: String?, fileName: String?,
    callback: (Result<String>) -> Unit
) { ... callback(Result.success(absPath)) ... }

// AFTER:
override fun captureImage(
    handle: Long, outputDirectory: String?, fileName: String?,
    destination: CamPhotosDestination?,
    callback: (Result<CamCaptureResult>) -> Unit
) {
    // Existing capture path produces absPath. New behavior:
    // - destination?.saveToLibrary == true → write through MediaStore, set filePath = content URI (Android has no PHAsset);
    // - destination null or saveToLibrary == false → write to filesystem path as before.
    val absPath = /* existing capture logic */
    val result = if (destination?.saveToLibrary == true) {
        // TODO Plan-1 mechanical sweep: implement MediaStore branch.
        // For now, write-to-disk path is the only Android impl until
        // Phase-3 Android-side polish covers MediaStore. This is acceptable
        // because the §5.4 change is a wire-contract reshape; the runtime
        // saveToLibrary == true path on Android can land in Plan 2 cluster
        // alongside the iOS side.
        CamCaptureResult(filePath = absPath, phAssetLocalId = null)
    } else {
        CamCaptureResult(filePath = absPath, phAssetLocalId = null)
    }
    callback(Result.success(result))
}
```

Same shape for `captureNaturalPicture`. **The TODO above is acceptable to leave in Plan 1** — the Android MediaStore path is iso-orthogonal to the contract change; Plan 2 (or a separate Android-polish plan) implements it.

Verify:

```bash
grep -rn "captureImage\|captureNaturalPicture" android/src/main/kotlin/ | grep -v "CamCaptureResult"
```

Should show only the new signatures, not any lingering `String` return.

- [ ] **Step B3.5: Sweep Dart — public API + internal callsites**

```bash
grep -rn "captureImage\|captureNaturalPicture" lib/ --exclude=messages.g.dart
```

Update each callsite:

```dart
// BEFORE:
final String path = await _hostApi.captureImage(_handle, dir, name);
// ... use path

// AFTER:
final CamCaptureResult result = await _hostApi.captureImage(_handle, dir, name, destination);
final String path = result.filePath ?? (throw StateError(
    'captureImage(saveToLibrary: true) yielded no filePath; check phAssetLocalId on iOS.'));
// ... use path  (or use result.phAssetLocalId for Photos path)
```

Update the public Dart surface (`CambrianCamera.captureImage`, `CambrianCamera.captureNaturalPicture`) to accept the new optional `CamPhotosDestination` parameter and return a Dart wrapper type (or pass the Pigeon type through — designer's choice; the simpler path is to expose the Pigeon type directly via re-export).

- [ ] **Step B3.6: Update iOS stub `CameraHostApiImpl.swift`**

The compiler will tell you what's wrong — the existing stubs no longer satisfy the protocol. Update both `captureImage` and `captureNaturalPicture` stubs to the new signatures:

```swift
func captureImage(handle: Int64, outputDirectory: String?, fileName: String?,
                  destination: CamPhotosDestination?,
                  completion: @escaping (Result<CamCaptureResult, Error>) -> Void) {
    completion(.failure(notImplemented("captureImage")))
}

func captureNaturalPicture(handle: Int64, outputDirectory: String?, fileName: String?,
                           destination: CamPhotosDestination?,
                           completion: @escaping (Result<CamCaptureResult, Error>) -> Void) {
    completion(.failure(notImplemented("captureNaturalPicture")))
}
```

- [ ] **Step B3.7: Build smoke**

Same as B2.7. Expected: all three succeed. If Android build fails with a missing `MediaStore` import or similar, the TODO in B3.4 is OK to leave; the Kotlin should still compile because we're using only what's in scope.

- [ ] **Step B3.8: Commit Task B3**

```bash
git add packages/cambrian_camera/pigeons/camera_api.dart
git add packages/cambrian_camera/lib/
git add packages/cambrian_camera/android/
git add packages/cambrian_camera/ios/Classes/Messages.g.swift
git add packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift
git commit -m "refactor(pigeon): §5.4 broaden capture* signatures + CamCaptureResult

Adds CamPhotosDestination + CamCaptureResult types. captureImage and
captureNaturalPicture both gain an optional destination parameter and
return CamCaptureResult { filePath, phAssetLocalId } instead of String.

This is a RETURN-TYPE BREAKING CHANGE — Dart callers that used
\`captureImage(...).then((path) => ...)\` now read
\`result.filePath ?? throw\`. The optional destination parameter
preserves callsite ergonomics on the input side but does not preserve
return shape. Per spec §5.4.

Android Kotlin signatures updated; MediaStore branch left as TODO to be
filled in alongside iOS Photos library impl (Plan 2 / Android polish).
iOS stub updated to satisfy the new protocol; impl is still
not_implemented.
"
```

---

### §5.3 — Android-only fields and error codes: **no Plan 1 work**

Spec §5.3 keeps `CamSettings.noiseReductionMode` / `edgeMode` and the six Android-only `CamErrorCode` values in the contract; iOS no-ops them. **This requires no Pigeon change** — the contract stays as-is — and **no Plan 1 task**: the iOS adapter's silent-ignore on read + pass-through on write happens in Plan 2's `PigeonValueMapping`. Plan 4's HITL matrix verifies that none of the six Android-only error codes are ever emitted by the iOS pump.

If during Cluster B you find yourself wondering whether to touch these — don't. They're explicitly kept. Skip straight from B3 to B4.

---

### Task B4: §5.5 — Document `"interrupted"` `SessionState` (doc-only)

**Files:**
- Modify: `packages/cambrian_camera/pigeons/camera_api.dart`

- [ ] **Step B4.1: Edit the `CamStateUpdate` doc**

Find:

```dart
class CamStateUpdate {
  CamStateUpdate({required this.state});

  /// One of: "closed", "opening", "streaming", "recovering", "error"
  String state;
}
```

Replace with:

```dart
class CamStateUpdate {
  CamStateUpdate({required this.state});

  /// One of: "closed", "opening", "streaming", "recovering", "paused", "error",
  /// "interrupted".
  ///
  /// - "paused" — pipeline gate closed (explicit `pause()` or app scenePhase
  ///   inactive); resumes on `resume()` / scenePhase active.
  /// - "interrupted" — iOS-only — AVCaptureSession was interrupted by a
  ///   routine iOS event (Control Center claim, Split View / Stage Manager
  ///   peer, phone call). Auto-resumes when the system clears the
  ///   interruption; not an error.
  /// - "error" — fatal or recoverable hardware/configuration error; see
  ///   `onError` for code + isFatal.
  ///
  /// Android never emits "interrupted" (no equivalent route on the platform).
  /// All other values are emitted on both platforms.
  String state;
}
```

- [ ] **Step B4.2: Regenerate (doc only, but keeps generated files in sync)**

```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```

- [ ] **Step B4.3: No sweep needed** — doc only.

- [ ] **Step B4.4: Quick analyze**

```bash
flutter analyze 2>&1 | tail -5
```

Expected: `No issues found!`.

- [ ] **Step B4.5: Commit Task B4**

```bash
git add packages/cambrian_camera/pigeons/camera_api.dart packages/cambrian_camera/lib/ packages/cambrian_camera/android/ packages/cambrian_camera/ios/Classes/Messages.g.swift
git commit -m "docs(pigeon): §5.5 document 'interrupted' SessionState

Adds 'paused' + 'interrupted' to the CamStateUpdate.state documented set.
Both states are CameraKit-side emissions; 'interrupted' is iOS-only
(AVCaptureSession routine interruption — Control Center, Split View /
Stage Manager, phone call). Android never emits 'interrupted'.

No code change; no impl impact. Generated files regen for doc parity.
"
```

---

### Task B5: §5.6 — Permission query/request host methods

**Files:**
- Modify: `pigeons/camera_api.dart`, regen, `CambrianCameraPlugin.kt` (Android impls), iOS stub.

- [ ] **Step B5.1: Add 4 host methods to `CameraHostApi`**

In `pigeons/camera_api.dart`, inside `abstract class CameraHostApi { ... }`, after `sampleCenterPatch`, add:

```dart
  /// Returns the current camera permission status:
  /// "notDetermined" | "denied" | "restricted" | "authorized".
  ///
  /// Callers should query this before invoking [open] so they can present
  /// a permission rationale UI rather than discovering denial as an open
  /// failure. iOS-style four-value status; Android maps PERMISSION_GRANTED
  /// → "authorized", PERMISSION_DENIED → "denied" (or "restricted" if
  /// don't-ask-again was selected).
  @async
  String cameraPermissionStatus();

  /// Triggers the system permission prompt for camera access; returns the
  /// resulting status (same four values as [cameraPermissionStatus]).
  ///
  /// No-op (returns current status) if already authorized.
  @async
  String requestCameraPermission();

  /// Status query for Photos add-only permission (iOS) or WRITE_EXTERNAL_STORAGE
  /// (Android pre-API 29) / no-op (Android API 29+, MediaStore handles it).
  @async
  String photosAddPermissionStatus();

  /// Trigger Photos add-only permission prompt (iOS) / WRITE_EXTERNAL_STORAGE
  /// (Android pre-API 29) / no-op (Android API 29+).
  @async
  String requestPhotosAddPermission();
```

- [ ] **Step B5.2: Regenerate**

```bash
dart run pigeon --input pigeons/camera_api.dart
```

- [ ] **Step B5.3: Implement on Android Kotlin**

Path: `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`.

Find the `CameraHostApi` impl class (or wherever the plugin implements it). Add the four methods:

```kotlin
override fun cameraPermissionStatus(callback: (Result<String>) -> Unit) {
    val status = if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                     == PackageManager.PERMISSION_GRANTED) "authorized" else "notDetermined"
    callback(Result.success(status))
}

override fun requestCameraPermission(callback: (Result<String>) -> Unit) {
    // The existing plugin already brokers this inside open() — reuse that flow,
    // or, if open()'s flow isn't directly callable, replicate:
    //   ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.CAMERA), REQUEST_CODE)
    //   ... wait for onRequestPermissionsResult ...
    //   callback(Result.success(resultingStatus))
    // For Plan 1 a synchronous "return current status" stub is acceptable —
    // the real impl can land in Phase-3 polish. Document the gap:
    val currentStatus = if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                            == PackageManager.PERMISSION_GRANTED) "authorized" else "denied"
    callback(Result.success(currentStatus))
    // TODO(phase-3-android-polish): wire actual ActivityCompat.requestPermissions.
}

override fun photosAddPermissionStatus(callback: (Result<String>) -> Unit) {
    // Android API 29+: MediaStore.Images handles writes without a permission;
    // pre-API 29: WRITE_EXTERNAL_STORAGE required. Plan-1 stub returns
    // "authorized" on API 29+, current status on older.
    val sdk = android.os.Build.VERSION.SDK_INT
    val status = if (sdk >= 29) "authorized"
        else if (ContextCompat.checkSelfPermission(context,
                  Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
              "authorized" else "notDetermined"
    callback(Result.success(status))
}

override fun requestPhotosAddPermission(callback: (Result<String>) -> Unit) {
    photosAddPermissionStatus(callback)  // stub — same as status query for now
}
```

Add `import android.Manifest`, `import android.content.pm.PackageManager`, `import androidx.core.content.ContextCompat` at the top if not already present.

- [ ] **Step B5.4: Add 4 stubs to iOS `CameraHostApiImpl.swift`**

```swift
func cameraPermissionStatus(completion: @escaping (Result<String, Error>) -> Void) {
    completion(.failure(notImplemented("cameraPermissionStatus")))
}

func requestCameraPermission(completion: @escaping (Result<String, Error>) -> Void) {
    completion(.failure(notImplemented("requestCameraPermission")))
}

func photosAddPermissionStatus(completion: @escaping (Result<String, Error>) -> Void) {
    completion(.failure(notImplemented("photosAddPermissionStatus")))
}

func requestPhotosAddPermission(completion: @escaping (Result<String, Error>) -> Void) {
    completion(.failure(notImplemented("requestPhotosAddPermission")))
}
```

- [ ] **Step B5.5: Build smoke**

Same as B2.7.

- [ ] **Step B5.6: Commit Task B5**

```bash
git add packages/cambrian_camera/pigeons/camera_api.dart packages/cambrian_camera/lib/ packages/cambrian_camera/android/ packages/cambrian_camera/ios/Classes/Messages.g.swift packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift
git commit -m "feat(pigeon): §5.6 cameraPermissionStatus / Request + Photos equivalents

Adds 4 host methods so Flutter can query + prompt permissions before
calling open() — iOS-style four-value status mapped to Android's
two-value PERMISSION_GRANTED + don't-ask-again states.

Android Kotlin: cameraPermissionStatus + photosAddPermissionStatus
return real values; the request variants are Plan-1 stubs that return
current status (real ActivityCompat.requestPermissions wiring lands in
phase-3-android-polish).

iOS: stubs throw not_implemented; real impls land in Plan 2 (route to
CameraEngine.cameraPermissionStatus + requestCameraPermission — nonisolated
static, per D-2P-06).
"
```

---

### Task B6: §5.7 — `streamPixelFormat` on `CamCapabilities`

**Files:**
- Modify: `pigeons/camera_api.dart`, regen, Android `CameraController.kt` (capability build site), Dart (`camera_state.dart` if `CameraCapabilities` mirrors the Pigeon type).

- [ ] **Step B6.1: Add the field to `CamCapabilities`**

In `pigeons/camera_api.dart`, in `class CamCapabilities { ... }`, add to the constructor and field list:

```diff
   CamCapabilities({
     required this.supportedSizes,
     ...
     required this.sensorStreamHeight,
+    required this.streamPixelFormat,
   });
```

```diff
   int sensorStreamHeight;
+
+  /// Pixel format of the lane buffers exposed via the texture bridge.
+  /// Values: "BGRA8" (iOS default + Android post-D-2P-09 swizzle),
+  /// "RGBA16F" (iOS opt-out via OpenConfiguration.lanesEightBit: false),
+  /// "RGBA8" (Android pre-D-2P-09 — should not be observed in shipped builds).
+  /// Informational for non-Texture-widget consumers that read buffers raw.
+  String streamPixelFormat;
```

- [ ] **Step B6.2: Regenerate**

```bash
dart run pigeon --input pigeons/camera_api.dart
```

- [ ] **Step B6.3: Wire Android emit site**

```bash
grep -rn "fun.*CamCapabilities\|CamCapabilities(" android/src/main/kotlin/
```

At every `CamCapabilities(...)` constructor call (likely one or two in `CameraController.kt`), add the new field:

```kotlin
CamCapabilities(
    supportedSizes = ...,
    // ... existing fields ...
    sensorStreamHeight = sensorStreamHeight.toLong(),
    streamPixelFormat = "BGRA8",  // post-D-2P-09: Android emits BGRA8 too.
)
```

Per D-2P-09, the Android `GpuRenderer.cpp` swizzle is the *runtime* change that makes this string accurate; it lands in a separate Android-polish task. Setting the string to `"BGRA8"` in Plan 1 is correct because the wire-format goal post-D-2P-09 is BGRA8 on both platforms.

- [ ] **Step B6.4: Sweep Dart `CameraCapabilities` mirror (if present)**

```bash
grep -rn "class CameraCapabilities" lib/
```

If the Dart-side `CameraCapabilities` mirrors the Pigeon type (e.g. in `lib/src/camera_state.dart`), add the new field:

```dart
class CameraCapabilities {
  CameraCapabilities({
    // ... existing fields ...
    required this.streamPixelFormat,
  });

  // ... existing fields ...

  /// Pixel format of lane buffers — "BGRA8" | "RGBA16F" | "RGBA8".
  /// See pigeons/camera_api.dart for the per-value semantics.
  final String streamPixelFormat;
}
```

Update every constructor callsite + every fromPigeon adapter.

- [ ] **Step B6.5: iOS stub — no edit**

The stub doesn't construct `CamCapabilities` (returns `notImplemented` for `getCapabilities`). Skip.

- [ ] **Step B6.6: Build smoke**

Same as B2.7.

- [ ] **Step B6.7: Commit Task B6**

```bash
git add packages/cambrian_camera/pigeons/camera_api.dart packages/cambrian_camera/lib/ packages/cambrian_camera/android/ packages/cambrian_camera/ios/Classes/Messages.g.swift
git commit -m "feat(pigeon): §5.7 streamPixelFormat on CamCapabilities

Informational field describing the lane-buffer wire format. Values:
- 'BGRA8' — iOS default (D-2P-11 lanesEightBit: true) + Android post-D-2P-09 swizzle
- 'RGBA16F' — iOS opt-out via OpenConfiguration.lanesEightBit: false
- 'RGBA8' — Android pre-D-2P-09 (should not be observed in shipped builds)

Android emit site updated to 'BGRA8'. Runtime swizzle in GpuRenderer.cpp
that makes that value byte-accurate lands separately
(phase-3-android-polish).
"
```

---

### Task B7: Integration check — full pigeon regen, every output clean, end-to-end build

**Files:** N/A (verification only).

- [ ] **Step B7.1: Regen one more time to verify idempotence**

```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
git status --short
```

Expected: `git status` shows zero modified files (a no-op regen is the test that B1–B6 left the inputs and outputs consistent). If files change, one of B1–B6's "regenerate" steps was missed.

- [ ] **Step B7.2: Full `flutter analyze`**

```bash
flutter analyze 2>&1 | tail -10
```

Expected: `No issues found!`.

- [ ] **Step B7.3: Full iOS build**

```bash
cd example
flutter build ios --debug --no-codesign 2>&1 | tee /tmp/phase3-plan1-B7-ios.log | tail -10
```

Expected: `Built build/ios/iphoneos/Runner.app`.

- [ ] **Step B7.4: Full Android build**

```bash
flutter build apk --debug 2>&1 | tee /tmp/phase3-plan1-B7-android.log | tail -10
```

Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step B7.5: On-device run smoke (iOS)**

```bash
flutter run -d <IPAD_UDID> --debug 2>&1 | tee /tmp/phase3-plan1-B7-run.log
```

Expected: app launches; the Flutter splash + example UI appear; HostApi calls return `not_implemented` (same as A5.4).

Quit with `q`.

- [ ] **Step B7.6: Validate `Dart` controller's branching surface for §5.4**

If the example app exposes a "capture image" button:

1. Tap it.
2. Expected: a `PlatformException: not_implemented` with message "captureImage is not yet implemented in Phase 3 Plan 1." — the new signature ran through the new pipeline without a parser error.

If the Dart side errors *before* reaching iOS (e.g. `NoSuchMethodError` because the Dart caller's signature is stale), there's an unfixed Dart sweep — go back to B3.5.

- [ ] **Step B7.7: No Android device run required for Plan 1** — Android build success + the existing Android impls compiling clean is enough. Android-side runtime testing is folded into Plan 4.

---

## Cluster C — Plan 1 wrap

### Task C1: Update Plan 1's status in eva-swift-stitch (light doc)

**Files:**
- (Optional) Modify: `docs/superpowers/specs/2026-05-18-phase-3-design.md` — add a "Plan 1 — completed" marker at the top, OR
- (Recommended) Create: `docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md` — append a "Status" section at the bottom.

- [ ] **Step C1.1: Append status section to this plan file**

In `eva-swift-stitch`, append to the bottom of `docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md`:

```markdown
---

## Status — completed YYYY-MM-DD

- Cluster A (subtree + SPM scaffold): commit `<sha-A>` in cam2fd
- Cluster B (Pigeon amendments §5.1–§5.7): commits `<sha-B1>` .. `<sha-B7>` in cam2fd
- Plugin builds clean on iOS (SPM); stub HostApi returns `not_implemented`
- Android side compiles and passes `flutter build apk`
- Dart `flutter analyze`: clean
- On-device iPad smoke: app launches, plugin registers, `not_implemented`
  errors propagate to Dart

**Plan 2** (Adapter + Methods + Bridge) is the next step. Branch in cam2fd:
`phase-3-plan-2-adapter-methods-bridge`, based on this plan's
`phase-3-plan-1-scaffold-and-contract` branch (after merge to cam2fd's main).
```

Substitute the real date + commit SHAs.

- [ ] **Step C1.2: Commit the doc update in eva-swift-stitch**

```bash
cd /Users/shrek/work/cambrian/eva-swift-stitch
git add docs/superpowers/plans/2026-05-18-phase-3-plan-1-scaffold-and-contract.md
git commit -m "docs(plans): Phase 3 Plan 1 — completion status

Plan 1 (scaffold + Pigeon contract amendments §5.1-§5.7) is complete in
cam2fd. Plugin builds clean on iOS (SPM); Android side compiles; Dart
analyzes clean; on-device iPad smoke passes (stub HostApi returns
not_implemented end-to-end).

Plan 2 (adapter + methods + texture bridge) is the next step.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Push only with explicit user approval — see CLAUDE.md §7.

### Task C2: Push the cam2fd branch (with user approval)

- [ ] **Step C2.1: Confirm push approval**

cam2fd's `phase-3-plan-1-scaffold-and-contract` has 9 commits (1 subtree, 1 Cluster A, 6 Cluster B per-amendment, 0 wrap because wrap was eva-swift-stitch). Before pushing, **confirm with the user** — per the project's git discipline.

If approved:

```bash
cd /Users/shrek/work/cambrian/camera2_flutter_demo
git push -u origin phase-3-plan-1-scaffold-and-contract
```

Then either open a PR (if cam2fd uses PR review) or merge to main per cam2fd's convention.

- [ ] **Step C2.2: After merge, re-verify camerakit-only didn't accidentally regenerate**

(This is a paranoid check; the cam2fd push doesn't trigger eva-swift-stitch's hook.)

```bash
cd /Users/shrek/work/cambrian/eva-swift-stitch
git ls-remote --tags origin camerakit-v1.0.0
```

Expected: same SHA as Step 0.1 (`6fbdc6b`). No drift.

---

## Self-Review Checklist (engineer runs before declaring Plan 1 done)

- [ ] Every checkbox in every Task is checked off.
- [ ] `git log --oneline` in cam2fd shows ~9 commits on the feature branch (1 subtree + 1 Cluster A + 6 B-amendments + maybe 1 squash-fix).
- [ ] `git status` in cam2fd is clean.
- [ ] `flutter analyze` in `packages/cambrian_camera/` → `No issues found!`
- [ ] `flutter build ios --debug --no-codesign` in `example/` → `Built ... Runner.app`
- [ ] `flutter build apk --debug` in `example/` → `Built ... app-debug.apk`
- [ ] `dart run pigeon --input pigeons/camera_api.dart` → idempotent (no diff after re-run)
- [ ] On-device run shows the plugin registering (no `MissingPluginException`) and HostApi calls returning `PlatformException(not_implemented, ...)` to Dart.
- [ ] `eva-swift-stitch` has zero source changes from Plan 1 (only the doc-update commit per Task C1).
- [ ] `camerakit-v1.0.0` tag on origin still points at `6fbdc6b`.
- [ ] The subtreed `ios/CameraKit/` directory was not hand-edited.

---

## Carry-forward to Plan 2

Plan 2 picks up the working scaffold and replaces every `not_implemented` stub with a real `CameraEngine` call via the new `HandleRegistry` actor + `FlutterApiPump`. Plan 2 also wires the `CameraLaneTexture` bridge for `.natural` and `.processed` lanes, populates the texture-ID fields in `CamCapabilities` + `CamStreamConfiguration`, and adds the scene-phase lifecycle observer.

Plan 2's first step is creating its own feature branch (`phase-3-plan-2-adapter-methods-bridge`) off cam2fd's main (after Plan 1 merge) and verifying the scaffold from Plan 1 is intact.

Plan 3 (iOS-only calibration via separate Pigeon file) and Plan 4 (HITL + polish) follow.

---

## Plan 1 — execution notes

Optional, for the executor (subagent or human):

- **Task A1's subtree add is the only "import from upstream" step in this plan.** If anything in the subtreed contents looks broken, the bug is in eva-swift-stitch — fix it there, retag, re-subtree-pull. Do not edit `ios/CameraKit/` files directly.
- **Cluster B's amendments are mostly mechanical.** Treat each task as: edit Pigeon input → regen → fix compile errors. The compile errors are your guide to the sweep.
- **The smoke build at the end of each B task is the gate.** Don't move on to the next amendment until the current one builds clean on both platforms.
- **Plan 1 deliberately leaves iOS HostApi as stubs.** Resist the temptation to start filling in real impls (that's Plan 2). The point of Plan 1 is to land a building, registered, end-to-end-wired plugin so Plan 2 can iterate fast.
- **Two iPads, two UDID schemes.** Per eva-swift-stitch CLAUDE.md §8, the project has two iPads with two different UDID conventions (xctrace vs. devicectl). For Plan 1 only the xctrace UDID is needed (`flutter run -d <udid>`); Plan 4's deeper device verification covers both.

---

## Status — completed 2026-05-18

**Branch (cam2fd):** `phase-3-plan-1-scaffold-and-contract` (based on the
fast-forward merge of `dev` into `main` — `dev` carried real engineering
work — GPU readback, Y-flip unification, ISO — that `main` did not yet have).

**Commits on the feature branch:**
- `cd09136` — Squashed CameraKit subtree-add (`camerakit-v1.0.0` → commit `6fbdc6b`)
- `b947678` — Subtree merge commit
- `70ad09f` — Cluster A: SPM scaffold + podspec + iOS-26 bump (`flutter build ios` pass)
- `92ff2e2` — Cluster B1: §5.1 `rawStream*` → `naturalStream*`
- `a1033a2` — Cluster B2: §5.2 `onCapabilitiesChanged` → `onStreamConfigurationChanged` + `CamStreamConfiguration`
- `f3f767e` — Cluster B3: §5.4 capture* broadened with `CamPhotosDestination` + `CamCaptureResult` (return-type breaking)
- `76cef55` — Cluster B4: §5.5 doc `paused` + `interrupted` `SessionState`
- `b7df7a5` — Cluster B5: §5.6 4 permission host methods (Android real status + stub requests; iOS stubs)
- `4beddc1` — Cluster B6: §5.7 `streamPixelFormat` on `CamCapabilities`

**Plan-time deviation from the spec layout (decided during execution):**
Flutter's SPM integration evaluates relative `.package(path:)` from its
ephemeral symlink directory, not the symlink target. The spec's original
sibling layout (`ios/CameraKit/` next to `ios/cambrian_camera/` with
`.package(path: "../CameraKit")`) failed Flutter's SPM resolve. **Resolution:**
the CameraKit subtree was vendored INSIDE the plugin directory at
`packages/cambrian_camera/ios/cambrian_camera/CameraKit/` and the plugin
references it via `.package(path: "CameraKit")`. The "snapshot, not
hand-edited" invariant is unchanged; only the prefix moves.

**Deferred from this plan (carried by the user's instruction):**
- A5 + B7.5 on-device `flutter run` smokes — both iPads showed `unavailable`
  in `devicectl`; the user opted to defer device runs and rely on the
  build/analyze gates (which verify Pigeon shape + plugin link + scaffold
  registration end-to-end).

**Carried over from Cluster A as a plan-time fix not in the original plan:**
- `scripts/regenerate_pigeon.sh` was patched in lock-step with A2.6's
  pigeon `swiftOut` repoint (the script hardcoded the old `ios/Classes/`
  path).
- An `IPHONEOS_DEPLOYMENT_TARGET = 13.0` survived in 3 project-level
  build configurations of `ios/Runner.xcodeproj/project.pbxproj` —
  the original A4.1 ruby block only iterated `p.targets`; project-level
  configs needed a second pass (also iterated in the executed step).

**Verification at end of plan:**
- Plugin `flutter analyze`: 4 pre-existing `curly_braces` info-level
  warnings (carried over from before Plan 1, unchanged) — no errors,
  no new warnings.
- `flutter build ios --debug --no-codesign`: `Built build/ios/iphoneos/Runner.app`.
  Plugin Swift symbols (`CameraHostApi`, `CameraHostApiImpl`,
  `captureImage`, `setResolution`, `stopRecording`, …) link into
  `Runner.debug.dylib`; CameraKit's `default.metallib` bundles correctly.
- `flutter build apk --debug`: `Built build/app/outputs/flutter-apk/app-debug.apk`.
  Required setting up the OpenCV symlink per CLAUDE.md (one-time per worktree).
- `bash scripts/regenerate_pigeon.sh` after B7.1 — idempotent (zero diff).

**Plan 2** (Adapter + Methods + Bridge) is the next step. Branch in cam2fd:
`phase-3-plan-2-adapter-methods-bridge`, based on this plan's
`phase-3-plan-1-scaffold-and-contract` branch (after merge to cam2fd's main).

