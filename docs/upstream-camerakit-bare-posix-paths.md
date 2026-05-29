# Upstream task: CameraKit recording APIs must return bare POSIX paths

**Target repo:** `cambrian-ios-camera`
**Target branch:** `main` (the source of truth — do **not** edit `camerakit-only`; it is generated from `main` by a git hook and any hand-edit there is clobbered on regeneration).
**Audience:** a coding agent in `cambrian-ios-camera` with no prior context on this change.

---

## 1. Goal

Make CameraKit's recording API return a **bare POSIX path** (e.g. `/var/mobile/.../clip.mp4`)
instead of a `file://` URL string (e.g. `file:///var/mobile/.../clip.mp4`).

Concretely: every place that currently builds the returned recording URI string from
`URL.absoluteString` must use `URL.path` instead.

### Why

The Flutter/Dart consumer passes this string straight into `dart:io`'s `File(path)`, which
expects a filesystem path, **not** a URL. With `absoluteString` the Dart side has to strip the
`file://` scheme itself; returning `url.path` removes that footgun and makes
`startRecording()` / `stopRecording()` return values directly usable.

## 2. Background — why this lands on `main` and not in the consumer

This change was originally (and incorrectly) made downstream, directly inside the **vendored
copy** of CameraKit in the `camera2-flutter-demo` repo
(commit `c501de7`, "fix(ios): recording and capture return bare POSIX paths, expose Documents
to Files app", authored against CameraKit `0132b84`).

The dependency chain is strictly top-down:

```
cambrian-ios-camera@main   (source of truth)
        │  git hook generates ↓
   camerakit-only branch    (generated; do not hand-edit)
        │  git subtree pull ↓
   camera2-flutter-demo  packages/cambrian_camera/ios/cambrian_camera/CameraKit/  (vendored)
```

Editing the vendored copy created a fork that fights every future `subtree pull`. The fix is to
put the change at the **top** (`main`), let the hook regenerate `camerakit-only`, and then the
demo restores its vendored copy to pristine and pulls cleanly. **Your job is only the `main`
part.**

## 3. ⚠️ `main` has diverged — re-implement, do not blind-apply

The original change was made against CameraKit `0132b84`. Since then `main` has moved
(notably `b0f5412` "derive output file format from filename extension", which added
`OutputPathResolution.swift` and reworked path/format handling, plus test-seam refactors that
renamed shared test helpers). **Do not `git apply` the patch in §6 blindly** — use it as a
reference and re-implement against the *current* code on `main`. Line numbers will not match;
find the equivalent code by behavior.

## 4. Scope — exactly three files in CameraKit

### 4a. `Sources/CameraKit/Recording.swift` — the production change (the contract)

Find the three places that produce the returned recording-path string and change
`.absoluteString` → `.path`. As of the base version they were:

1. In `start(...)`, when constructing the success result:
   ```swift
   // before
   return RecordingStart(uri: url.absoluteString, displayName: url.lastPathComponent)
   // after
   return RecordingStart(uri: url.path, displayName: url.lastPathComponent)
   ```

2. In `stop()`, the early-exit branch:
   ```swift
   // before
   return outputURL?.absoluteString ?? ""
   // after
   return outputURL?.path ?? ""
   ```

3. In `stop()`, the normal completion branch:
   ```swift
   // before
   let url = outputURL?.absoluteString ?? ""
   // after
   let url = outputURL?.path ?? ""
   ```

> If `main` has additional/renamed sites that return a recording or capture URI built from a
> `URL`, apply the same `.path` treatment so the contract is uniform. (Note: at the base
> version, **still-capture** was already correct in CameraKit — `StillCapture.swift` returns
> `StillCaptureOutput(filePath: outputURL.path)`, a bare path, so no change was needed there.
> But if `main`'s `StillCapture` has since started returning a `file://` string where a bare path
> is wanted, fix it here too for consistency and add a matching assertion.)

### 4b. `Tests/CameraKitTests/PhotosLibraryClientTests.swift` — update one assertion

In the test that checks `Recording.start` display name for a custom output URL
(`recordingDisplayNameMatchesResolvedFilename`, or its equivalent on `main`):

```swift
// before
#expect(start.uri == custom.absoluteString)
// after
#expect(start.uri == custom.path)
```

> Caveat: `b0f5412` migrated path-resolution tests **out** of `PhotosLibraryClientTests` into
> `OutputPathResolutionTests`. The recording-display-name test may have moved. Locate the
> assertion that compares `start.uri` to a custom URL and flip it to `.path` wherever it now
> lives.

### 4c. `Tests/CameraKitTests/Stage10Tests.swift` — add a new test suite

Add the suite below. It guards the bare-path contract directly. **It depends on shared test
helpers** — `FakeAssetWriter`, `FakeAdaptor`, `makeFakeFactory`, `FastClock`, and the
`.progressLogged` trait. At the base version these were defined **inside `Stage10Tests.swift`
itself** (`FakeAssetWriter`/`FakeAdaptor`/`makeFakeFactory`/`FastClock`) and in
`TestProgressLog.swift` (`.progressLogged`) — i.e. the helpers live in the very file you are
appending to, so same-module visibility is guaranteed. Do **not** assume a separate
"TestSupport" target exists. The test-seam refactor on `main` may have **moved or renamed**
some of these ("drop misleading ForTest names" / "gate test seams behind `#if DEBUG`) —
`grep` the current tree for each symbol and use whatever name resolves; the structure of the
suite stays the same.

File header already has: `import AVFoundation`, `import Foundation`, `import Testing`,
`@testable import CameraKit`.

```swift
// MARK: - Suite 6: recording URI format

/// Guards the wire-format contract that `RecordingStart.uri` is a bare POSIX
/// path — not a `file://` URL string — so Dart consumers can pass it directly
/// to `dart:io.File` without stripping the scheme.  Symmetric: `stop()` must
/// return the same bare path so `startRecording()` and `stopRecording()` are
/// consistent on the Dart side.
@Suite("Stage 10 — recording URI format", .progressLogged)
struct Stage10URIFormatTests {

    private func makeRecording() -> Recording {
        Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: FakeAssetWriter(), adaptor: FakeAdaptor())
        )
    }

    @Test("start.uri is a bare POSIX path, not a file:// URL")
    func uriIsBarePathNotFileURL() async throws {
        let rec = makeRecording()
        let start = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        #expect(
            !start.uri.hasPrefix("file://"),
            "uri must not carry file:// scheme; got \(start.uri)"
        )
        #expect(start.uri.hasPrefix("/"), "uri must be an absolute path; got \(start.uri)")
        #expect(start.uri.hasSuffix(".mp4"))
    }

    @Test("start.displayName is the last path component of start.uri")
    func displayNameIsLastPathComponent() async throws {
        let rec = makeRecording()
        let start = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        let expected = URL(fileURLWithPath: start.uri).lastPathComponent
        #expect(
            start.displayName == expected,
            "displayName '\(start.displayName)' must equal last path component '\(expected)'"
        )
        #expect(!start.displayName.isEmpty)
    }

    @Test("stop() returns the same bare path as start.uri")
    func stopReturnsSamePathAsStartURI() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        let start = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        let stopURI = await rec.stop()
        #expect(stopURI == start.uri, "stop() URI '\(stopURI)' must equal start.uri '\(start.uri)'")
        #expect(!stopURI.hasPrefix("file://"))
    }

    @Test("custom outputURL produces uri equal to url.path")
    func customOutputURLProducesPathURI() async throws {
        // Use a sandbox-valid path (Documents dir passes PhotosLibraryClient.resolve).
        let customURL = URL.documentsDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mp4")
        let rec = makeRecording()
        let start = try await rec.start(
            options: RecordingOptions(outputURL: customURL),
            captureSize: Size(width: 256, height: 256)
        )
        #expect(
            start.uri == customURL.path,
            "uri '\(start.uri)' must equal url.path '\(customURL.path)'"
        )
        #expect(start.displayName == customURL.lastPathComponent)
    }
}
```

> `customOutputURLProducesPathURI` references `PhotosLibraryClient.resolve` in its comment.
> If `b0f5412` moved sandbox validation into `OutputPathResolver`, the comment is stale but the
> test still works as long as `URL.documentsDirectory` is an accepted output location — adjust
> the comment if you wish.

## 5. Out of scope (handled in the demo, NOT in `cambrian-ios-camera`)

The original commit `c501de7` also changed files that are **not** part of CameraKit and must
**not** be ported here. This is the *complete* set of non-CameraKit files in that commit (verify
with `git show --stat c501de7`):

- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraHostApiImpl.swift`
  — the **consumer counterpart** to this whole change. `startRecording` now returns
  `"\(start.uri)|\(start.displayName)"` (Android's `uri|displayName` wire format) so the Dart
  side splits it into `(filePath, displayName)`. This is the Flutter plugin glue *above*
  CameraKit, not part of the library — it stays downstream. (It is the "consumer/plugin side"
  referenced from §4a.)
- `ios/Runner/Info.plist` and `packages/cambrian_camera/example/ios/Runner/Info.plist` —
  the "expose Documents to Files app" part (`UIFileSharingEnabled` /
  `LSSupportsOpeningDocumentsInPlace`). Example/demo-app configuration, unrelated to the
  CameraKit package.
- `packages/cambrian_camera/example/integration_test/recording_path_test.dart` — on-device
  Dart integration tests asserting bare-path returns. Lives in the demo's example app.
- `packages/cambrian_camera/example/pubspec.yaml` — example-app dependency bump for the
  integration test.
- `docs/reference/ios-vs-android.md` — a reference doc added in the demo repo.

> Note: the commit did **not** touch `lib/main.dart` (an earlier draft of this handoff listed it
> — that was wrong; the Dart-side consumer change lived in `CameraHostApiImpl.swift`'s wire
> format, not `main.dart`).

Only the three CameraKit files in §4 belong upstream.

## 6. Acceptance criteria

- All three `.absoluteString` → `.path` sites in `Recording.swift` changed; no behavioral
  regressions elsewhere.
- **Breaking contract change — call it out in the PR description.** Any existing consumer that
  treats the returned `uri` as a URL string (e.g. `URL(string: returnedUri)`) will break and must
  switch to `URL(fileURLWithPath: returnedUri)`. The change is intentional (see §1) but it is not
  backward-compatible for scheme-relying callers.
- The `PhotosLibraryClientTests` assertion (wherever it now lives) compares to `.path`.
- The new `Stage10URIFormatTests` suite compiles (using `main`'s current TestSupport helper
  names) and passes.
- **CameraKit is iOS-only** (`platforms: [.iOS(.v26)]`) — `swift test` on the macOS host will
  not build it. Run the suite with `xcodebuild test` against an **iOS 26 simulator**, e.g.:
  ```
  xcodebuild test -scheme CameraKit-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
  ```
  (Schemes for a bare SwiftPM package: the test target lives in `CameraKit-Package`, not the
  `CameraKit` library scheme.)
- Open a PR into `main`; after merge, regenerate `camerakit-only` via the hook so the demo can
  pull the change down cleanly.

## 7. Reference diff (ground truth — for orientation only, do not blind-apply)

From `camera2-flutter-demo` commit `c501de7`, CameraKit-prefix files only:

```diff
--- a/Sources/CameraKit/Recording.swift
+++ b/Sources/CameraKit/Recording.swift
@@ start(...)
-        return RecordingStart(uri: url.absoluteString, displayName: url.lastPathComponent)
+        return RecordingStart(uri: url.path, displayName: url.lastPathComponent)
@@ stop() early exit
-            return outputURL?.absoluteString ?? ""
+            return outputURL?.path ?? ""
@@ stop() normal completion
-        let url = outputURL?.absoluteString ?? ""
+        let url = outputURL?.path ?? ""

--- a/Tests/CameraKitTests/PhotosLibraryClientTests.swift
+++ b/Tests/CameraKitTests/PhotosLibraryClientTests.swift
@@ recordingDisplayNameMatchesResolvedFilename
         #expect(start.displayName == "custom-recording.mp4")
-        #expect(start.uri == custom.absoluteString)
+        #expect(start.uri == custom.path)

--- a/Tests/CameraKitTests/Stage10Tests.swift
+++ b/Tests/CameraKitTests/Stage10Tests.swift
@@ append after the existing Stage10 suites
+   (entire Stage10URIFormatTests suite — see §4c above)
```
