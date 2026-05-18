# Phase 3 — Plan 3: iOS-only Calibration via Separate Pigeon File

> **For agentic workers (opus or similar):** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. This plan is **lean by design** — task boundaries + acceptance metrics, not exhaustive code blocks.

**Goal:** Add `calibrateWhiteBalance` + `calibrateBlackBalance` Pigeon host methods that exist on iOS only. Android's existing Dart calibration loop (`cambrian_camera_controller.dart`) stays unchanged; Android Kotlin gets zero new calibration code. iOS routes to the Phase-2 engine methods.

**Architecture:** Per spec §6. Separate pigeon input file `pigeons/camera_api_ios.dart` with `@ConfigurePigeon` declaring only `dartOut` + `swiftOut` (no `kotlinOut`); generates `lib/src/messages_ios.g.dart` + `ios/cambrian_camera/Sources/cambrian_camera/Messages_ios.g.swift`. Defines `@HostApi() abstract class CameraIosHostApi` with the two calibration methods. iOS plugin registers `CameraIosHostApi` alongside `CameraHostApi`. Dart `CambrianCamera.calibrateWhiteBalance/BlackBalance` branches on `Platform.isIOS` — iOS routes to the new HostApi; Android continues to call its existing Dart loop.

**Tech Stack:** Pigeon 22 multi-input pattern (canonical: `flutter/packages/interactive_media_ads`); Dart `defaultTargetPlatform`; Swift HostApi impl following Plan 2's adapter pattern.

**Spec source:** `docs/superpowers/specs/2026-05-18-phase-3-design.md` §6; `CameraKit/DECISIONS.md` D-2P-08, D-2P-02, D-2P-03, D-2P-05.

**Prerequisite:** Plan 2 merged in cam2fd — `CameraHostApiImpl` is real, `HandleRegistry` exists, `FlutterApiPump` runs.

**Working branch (cam2fd):** `phase-3-plan-3-ios-only-calibration`.

---

## Decisions taken (per spec; do not relitigate)

- **Separate-file pattern, not a per-method annotation.** Pigeon has no `@SwiftOnly` annotation; the canonical multi-platform separation is per-input-file `@ConfigurePigeon` with selected outputs omitted. Verified against `flutter/packages` (`interactive_media_ads_{ios,android}.dart`).
- **Android plugin Kotlin is not edited.** No `Messages_ios.g.kt` is generated; Android cannot accidentally implement (or break) the calibration host methods. Android Dart loop unchanged.
- **Public Dart API stays single-method.** `CambrianCamera.calibrateWhiteBalance({...}): Future<WbCalibrationResult>` is one method that branches internally on `Platform.isIOS`. Same for `calibrateBlackBalance`.
- **`CamCalibrationResult` lives in `camera_api_ios.dart`.** Defined there (Dart code-generator may emit a duplicate of `CamRgbSample` if it's referenced — see Fallback below).
- **D-2P-08, D-2P-02, D-2P-03, D-2P-05** govern engine-side semantics (single-shot path, `converged:true/iterations:1` for current iOS impl, concurrency contract). The plugin adapter is mechanical.
- **Fallback path is documented but not implemented first.** If Pigeon 22's per-file output produces unexpected Dart-side type-collision errors (e.g. duplicate `CamRgbSample` deserializers), Plan 3 falls back to single-file + Kotlin throws-`not_implemented`. Decision happens at Task A2's smoke build.

---

## File Inventory (all under `packages/cambrian_camera/`)

> **NOTE (2026-05-19):** This inventory describes the *primary path*
> (separate Pigeon input file). Implementation took the **A2-FALLBACK**
> path instead — see the **Status** section at the end of this file for
> the actual file inventory of what shipped.


### Created

- `pigeons/camera_api_ios.dart` — new Pigeon input file
- `lib/src/messages_ios.g.dart` — Pigeon-generated Dart side
- `ios/cambrian_camera/Sources/cambrian_camera/Messages_ios.g.swift` — Pigeon-generated Swift side
- `ios/cambrian_camera/Sources/cambrian_camera/CameraIosHostApiImpl.swift` — adapter routing to engine

### Modified

- `ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift` — register `CameraIosHostApi` alongside `CameraHostApi`
- `lib/src/cambrian_camera_controller.dart` — `calibrateWhiteBalance` + `calibrateBlackBalance` branch on `Platform.isIOS`

### Not touched

- `pigeons/camera_api.dart` — shared contract; no changes
- Android Kotlin — no changes (the whole point of Option C)
- `ios/CameraKit/**` — subtreed snapshot

---

## Pre-flight

### Task 0: Verify Plan 2 state, branch

- [ ] cam2fd on main; Plan 2 commits merged; `flutter analyze` clean
- [ ] HostApi impl (`CameraHostApiImpl.swift`) has real bodies for every method except the two calibrations (still throwing `not_implemented`)
- [ ] On-device smoke from Plan 2 still passes (preview renders, settings work, capture works)
- [ ] Branch: `git checkout -b phase-3-plan-3-ios-only-calibration`

---

## Cluster A — Pigeon input + generation

### Task A1: Write `pigeons/camera_api_ios.dart`

**File:** `pigeons/camera_api_ios.dart`

**Goal:** Per spec §6.1 — a Pigeon input file with:
- `@ConfigurePigeon` declaring `dartOut: 'lib/src/messages_ios.g.dart'` + `swiftOut: 'ios/cambrian_camera/Sources/cambrian_camera/Messages_ios.g.swift'`; **no `kotlinOut`**
- `@HostApi() abstract class CameraIosHostApi` with two `@async` methods returning `CamCalibrationResult`
- `class CamCalibrationResult { CamRgbSample before; CamRgbSample after; bool converged; int iterations; }`
- `class CamRgbSample` (duplicated from `camera_api.dart` — Pigeon doesn't share types across input files)

The two methods take `(int handle)` and return `CamCalibrationResult`. Doc comments wrap CameraKit engine methods per D-2P-03 / D-2P-05.

**Acceptance:** File created; Dart analyzer accepts it.

### Task A2: Generate + verify no Kotlin output

```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api_ios.dart
```

**Acceptance checks:**
- `lib/src/messages_ios.g.dart` exists
- `ios/cambrian_camera/Sources/cambrian_camera/Messages_ios.g.swift` exists
- **NO new file** under `android/src/main/kotlin/com/cambrian/camera/` (no `Messages_ios.g.kt` generated)
- `git status` confirms: only the two iOS+Dart outputs are new

**Smoke build:**
```bash
cd example
flutter build ios --debug --no-codesign
flutter build apk --debug
```

Both should succeed. If iOS build fails on Dart-side duplicate `CamRgbSample` type collision (the failure mode spec §6.5 anticipates), invoke the **Fallback** (Task A2-FALLBACK).

### Task A2-FALLBACK (only if A2 build fails): single-file + Kotlin throws

If A2 surfaces duplicate-deserializer or duplicate-class errors:

1. Delete `pigeons/camera_api_ios.dart` + the generated `messages_ios.g.dart` + `Messages_ios.g.swift`.
2. Add the two methods + `CamCalibrationResult` (reusing existing `CamRgbSample`) to the main `pigeons/camera_api.dart` instead.
3. Regen the shared pigeon: `dart run pigeon --input pigeons/camera_api.dart`.
4. Add Kotlin stubs in `CambrianCameraPlugin.kt` that throw `FlutterError("not_implemented", "calibrateWhiteBalance is iOS-only", null)`. ~4 lines per method.
5. Document the fallback in this plan's "Status" section + cam2fd commit message.

The rest of Plan 3 (Cluster B onward) continues unchanged regardless of A2 vs A2-FALLBACK path.

**Reference:** Spec §6.5 "Why not the fallback shape".

---

## Cluster B — iOS impl + plugin registration

### Task B1: `CameraIosHostApiImpl.swift`

**File:** `ios/cambrian_camera/Sources/cambrian_camera/CameraIosHostApiImpl.swift`

**Goal:** Adapter per spec §6.3. Holds a weak `HandleRegistry`. Each calibration method:
1. Resolve engine from handle → `PigeonError("not_found")` on miss
2. Call `await engine.calibrateWhiteBalance()` / `await engine.calibrateBlackBalance()`
3. Map `CalibrationResult` → `CamCalibrationResult` (both have `{before, after, converged, iterations}` shape per D-2P-02 — direct field copy plus `RgbSample → CamRgbSample` for the inner samples; if `CamRgbSample` duplicates between `messages.g.dart` and `messages_ios.g.dart`, this conversion targets `messages_ios.g.dart`'s `CamRgbSample`)
4. `EngineError.calibrationInProgress` → `PigeonError("calibration_in_progress")`; `CancellationError` → `PigeonError("cancelled")`; other errors → `PigeonError("unknown", message: error.localizedDescription)`

**Acceptance:** Compiles. Unit test (`example/ios/RunnerTests/CameraIosHostApiImplTests.swift`): stub engine returning a known `CalibrationResult` → adapter returns matching `CamCalibrationResult`; throwing `calibrationInProgress` → returns `PigeonError("calibration_in_progress")`.

### Task B2: Register `CameraIosHostApi` in plugin

**File:** `ios/cambrian_camera/Sources/cambrian_camera/CambrianCameraPlugin.swift`

**Goal:** In `register(with:)`, after the existing `CameraHostApiSetup.setUp(...)`, add:

```swift
let iosApi = CameraIosHostApiImpl(registry: registry)
CameraIosHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: iosApi)
```

Hold `iosApi` in the same static / instance state as the shared `CameraHostApiImpl` so it survives `register` returning.

**Acceptance:** App launches; both APIs are registered; Dart-side `CameraIosHostApi()` construction (in Task C1) works without `MissingPluginException`.

### Task B3: Remove `not_implemented` stubs from `CameraHostApiImpl`

If `CameraHostApiImpl` still has `calibrateWhiteBalance` / `calibrateBlackBalance` stubs (it should, from Plan 1's Step A2.4 if they were ever included — likely they were never added because they were not in the shared contract): no action.

If they exist there incorrectly: remove them. The shared `CameraHostApi` (from `pigeons/camera_api.dart`) does **not** declare these methods; only `CameraIosHostApi` does.

**Acceptance:** `grep "calibrate" CameraHostApiImpl.swift` returns 0 hits.

---

## Cluster C — Dart-side branch

### Task C1: `CambrianCamera.calibrateWhiteBalance` branches on `Platform.isIOS`

**File:** `lib/src/cambrian_camera_controller.dart`

**Goal:** The existing public method (which currently runs the Android Dart loop using `sampleCenterPatch` + `wbStep`) gains an early branch:

```dart
Future<WbCalibrationResult> calibrateWhiteBalance({...}) async {
  if (Platform.isIOS || defaultTargetPlatform == TargetPlatform.iOS) {
    final iosApi = CameraIosHostApi();
    final result = await iosApi.calibrateWhiteBalance(_handle);
    return WbCalibrationResult(
      before: RgbSample(r: result.before.r, g: result.before.g, b: result.before.b),
      after: RgbSample(r: result.after.r, g: result.after.g, b: result.after.b),
      // ... whatever shape WbCalibrationResult has, mapping the four engine fields
    );
  }
  // Existing Android Dart loop continues unchanged:
  final patchBefore = await sampleCenterPatch();
  ...
}
```

Same shape for `calibrateBlackBalance`. The public return type (`WbCalibrationResult` / `BbCalibrationResult`) stays as Dart consumers expect; the iOS branch adapts from `CamCalibrationResult`.

**Acceptance:**
- Dart-side unit test: mock `CameraIosHostApi`, call `calibrateWhiteBalance` on iOS-target platform, assert iOS branch ran.
- Test: on Android-target platform, mock `_hostApi.sampleCenterPatch`, assert existing Dart loop ran (no iOS path).

### Task C2: Public API export check

**File:** `lib/cambrian_camera.dart`

**Goal:** Verify the public surface (`CambrianCamera` class) still exposes `calibrateWhiteBalance` / `calibrateBlackBalance` with the same signatures consumers call today. No new exports needed (the iOS-only HostApi is internal — Dart consumers never call `CameraIosHostApi` directly).

**Acceptance:** `dart pub publish --dry-run` — or equivalent — accepts the public API surface.

---

## Cluster D — On-device verification

### Task D1: iOS calibration smoke

Run example app on iPad:
1. `open(...)` → handle returned
2. Trigger `calibrateWhiteBalance` (Dart-side: call `controller.calibrateWhiteBalance(...)`)
3. **Expected:** preview WB visibly adjusts; method returns `WbCalibrationResult` with `before` ≠ `after` (typical), `converged: true`, `iterations: 1` (single-shot iOS path per D-2P-03)
4. Trigger `calibrateBlackBalance` → preview pedestal visibly adjusts; method returns result

Failure-mode rehearsals:
- Trigger `updateSettings(wbMode: manual)` during a calibration in flight → calling thread sees `PigeonError("calibration_in_progress")`
- Trigger `setResolution` during calibration → same error
- Trigger `close` during calibration → calibration cancels cleanly; subsequent `open` works

**Acceptance:** All scenarios match expected behavior. CameraKit's existing `[wb] calibrate start` / `[wb] calibrate done` log lines (verified during Phase 2) fire end-to-end.

### Task D2: Android regression smoke

Run example app on an Android device or emulator. Trigger `calibrateWhiteBalance`. **Expected:** Android's existing Dart loop runs (it always has — Plan 3 doesn't touch it). `WbCalibrationResult` returned with `iterations > 1` (iterative loop). No `not_implemented` error.

If the Pigeon-method-availability mechanism failed silently (Android Kotlin somehow got the iOS method generated), Android would see `not_implemented` here. If observed: revert Plan 3, escalate.

**Acceptance:** Android calibration works exactly as before Plan 3.

---

## Cluster E — Plan 3 wrap

### Task E1: Status doc

Append "Status — completed YYYY-MM-DD" section to this plan file in eva-swift-stitch. Record which path (A2 primary vs A2-FALLBACK) was taken.

### Task E2: Push cam2fd branch (user approval gate)

Confirm with user → `git push -u origin phase-3-plan-3-ios-only-calibration` → PR/merge.

---

## Self-review checklist

- [ ] `pigeons/camera_api_ios.dart` exists; `dart run pigeon --input ...` is idempotent
- [ ] No `Messages_ios.g.kt` in `android/src/`
- [ ] iOS `CameraIosHostApiImpl` routes to `engine.calibrateWhiteBalance()` / `calibrateBlackBalance()`
- [ ] Dart `CambrianCamera.calibrateWhiteBalance` branches on platform; iOS path returns `WbCalibrationResult` with `iterations == 1` (single-shot); Android path runs the existing iterative Dart loop
- [ ] On-device iOS: both calibrations work; concurrency guards work
- [ ] On-device Android: existing behavior unchanged
- [ ] `flutter analyze` clean; iOS + Android builds clean
- [ ] If Fallback path taken: Kotlin stubs throw `not_implemented`; Dart-side `Platform.isAndroid` branch never calls these methods (they're unreachable in normal use)

---

## Carry-forward to Plan 4

Plan 4 is HITL + polish: 18-case device matrix per spec §8.4 (which includes calibration HITL cases 10 + 11 — now real), loaded-mode regression, README updates, Info.plist privacy strings, example-app HITL screen.

---

## Plan 3 — execution notes

- **A2's smoke build is the load-bearing test.** If Pigeon 22 produces clean Dart + Swift outputs from `camera_api_ios.dart` and the iOS app builds, the separate-file path works and the rest of Plan 3 is mechanical.
- **The duplicate `CamRgbSample` in `messages_ios.g.dart`** is acceptable — Dart treats them as distinct types, and the adapter (`CameraIosHostApiImpl.swift`) explicitly references the `Messages_ios.g.swift` version. If type-collision errors appear, that's the fallback trigger.
- **D2 Android regression smoke is non-optional.** The whole point of Option C is to prove Android is untouched. Verify on a real Android device or emulator — don't skip.
- **No engine surface changes needed.** All four engine method calls (`calibrateWhiteBalance`, `calibrateBlackBalance`, error throws, cancel handling) are Phase-2 deliverables already in the subtreed snapshot.

---

## Status — 2026-05-19 (cam2fd branch `phase-3-plan-3-ios-only-calibration`)

**Path taken: A2-FALLBACK (single shared Pigeon file + Android `not_implemented` stubs).**

### Why the fallback fired

Task A2's smoke build surfaced Pigeon 22's per-input-file behavior:
every emitted Swift file ships its own `class PigeonError`, codec
helpers (`wrapResult` / `wrapError` / `nilOrValue`), and any referenced
data types at module scope. With `pigeons/camera_api_ios.dart`
producing `Messages_ios.g.swift` alongside the shared
`Messages.g.swift`, the iOS Swift module ended up with two
`PigeonError` and two `CamRgbSample` declarations — fatal
"Invalid redeclaration" / "ambiguous for type lookup" errors. Spec
§6.5 anticipated only the Dart-side type-collision failure mode, but
the Swift-side `PigeonError` collision is structurally unavoidable in
Pigeon 22 (the runtime helper class is emitted per output file, not
once per module; users cannot suppress it).

The canonical Pigeon multi-input pattern (`interactive_media_ads_{ios,android}.dart`)
works because their iOS file emits Swift while their Android file
emits Kotlin — no two Swift files end up in the same module. Our
"iOS plus more iOS" use case crosses that boundary.

### Shape of the final implementation in cam2fd

- `pigeons/camera_api.dart` — shared contract now declares
  `calibrateWhiteBalance(int handle)` + `calibrateBlackBalance(int handle)`
  on the existing `@HostApi() CameraHostApi`. Wire result is
  `CamCalibrationResult { CamRgbSample before, after; bool converged;
  int iterations; double? gainR/G/B; double? blackR/G/B; }` — six
  optional fields appended to the spec §6.1 shape so the iOS adapter
  can pass the engine's committed values through to Dart. **See
  spec deviation note below.**
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift` —
  Plan B1 impls live here (NOT in a separate `CameraIosHostApiImpl.swift`).
  Each method calls the engine, then reads
  `engine.currentSettingsSnapshot()` /
  `currentProcessingParametersSnapshot()` to populate the WB-only /
  BB-only optional fields.
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt` —
  two ~4-line stubs: `callback(Result.failure(FlutterError("not_implemented", ...)))`.
- `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` —
  both calibration methods branch on `defaultTargetPlatform ==
  TargetPlatform.iOS` at the top; iOS path routes through the Pigeon
  call and adapts `CamCalibrationResult` → `WbCalibrationResult` /
  `BbCalibrationResult` records. Android path is unchanged — runs the
  existing iterative Dart loop.
- `scripts/regenerate_pigeon.sh` — unchanged from main. The fallback
  path only requires regenerating the shared contract.

### Spec deviation: `CamCalibrationResult` extended fields

Plan task C1 assumed the iOS engine's four-field `CalibrationResult`
shape would be sufficient. Empirically, the example app
(`lib/main.dart:_runWbCalibration` / `_runBbCalibration`) immediately
re-applies `result.gains` / `result.offsets` to the camera after
calibration — so the Dart-side `WbCalibrationResult.gains` /
`BbCalibrationResult.offsets` records must be populated with the
engine's *committed* values. Returning sentinel `(1,1,1)` / `(0,0,0)`
would have caused the example app to overwrite the just-calibrated
gains, silently breaking iOS calibration.

The minimal fix kept inside the Pigeon contract was six optional
fields (three for WB, three for BB) on `CamCalibrationResult`. The
adapter reads them from the engine's existing public
`currentSettingsSnapshot()` / `currentProcessingParametersSnapshot()`
accessors — no CameraKit subtree changes. The spec §6.1 class shape
grew by six nullable fields; the iOS adapter logic is unchanged
otherwise.

### Verification done

- `flutter analyze` clean (4 pre-existing info-level lints unrelated to Plan 3).
- All 50 existing package unit tests pass (`flutter test`).
- `flutter build ios --debug --no-codesign` — built clean (`build/ios/iphoneos/Runner.app`).
- `flutter build apk --debug` — built clean (`build/app/outputs/flutter-apk/app-debug.apk`).
- No `Messages_ios.g.*` files exist in the tree (artifacts deleted post-fallback).
- The shared Kotlin `Messages.g.kt` declares the new iOS-only methods
  (required so the stub `override fun` calls compile against the
  Pigeon-generated interface).

### Verification pending (human gate)

- **D1 — iOS on-device smoke.** Plan §D1 cases (preview WB visibly
  adjusts; `before` ≠ `after`; `converged: true`, `iterations: 1`;
  concurrency-guard error rehearsals from §D1 final paragraph).
  Requires an iPad with the example app deployed.
- **D2 — Android regression smoke.** Plan §D2 — Android still runs
  the iterative Dart loop and returns `iterations > 1` with no
  `not_implemented` surfacing. Requires an Android device or emulator.
- **C1 mock-based unit test.** Plan §C1 wanted a hand-rolled mock
  asserting the iOS branch invokes the HostApi while Android runs the
  Dart loop. Deferred — `cambrian_camera` has no mock framework in
  `dev_dependencies` (`mocktail` / `mockito`), and adding one + a
  `@visibleForTesting` constructor for `CambrianCamera` is out of
  scope for Plan 3's primary goal. Static type checking + smoke
  builds give structural confidence; mock test would only catch a
  caller-routing regression.

### Carry-forward to Plan 4

- HITL device matrix (spec §8.4 cases 10 + 11) is the load-bearing
  validation of the iOS path; the build/test gates above are
  necessary but not sufficient.
- The `not_implemented` Android stub is unreachable in normal use
  (Dart branches before calling), but it surfaces a real Pigeon
  error if a future change accidentally invokes it from Android. No
  monitoring needed — a single integration test or careful manual
  smoke catches any regression.
- If Plan 5 (Pigeon cross-platform cleanup) ever reconsiders the
  separate-file approach, the failure mode documented above is the
  evidence: Pigeon 22's per-Swift-file `PigeonError` emission rules
  out "shared + iOS-extra" cleanly without a Pigeon upstream change.
