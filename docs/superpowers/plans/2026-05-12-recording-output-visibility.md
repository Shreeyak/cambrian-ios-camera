# Recording Output Visibility — Plan

> **Status:** **Done — 2026-05-13.** Piece 1 in commit `d8ecfc0`; Piece 2
> follows in the next commit on `stage-01`. Definition of done satisfied
> with three architectural deviations versus the original plan, captured
> below at the end of the doc.

**Goal:** Make recorded videos discoverable to the user. Today they
land in the app's private `<Documents>/<timestamp>.mp4` and are
invisible to both the Files app and Photos app. The Bug 14 fix
(2026-05-12, commit `5270575`) reduces stop latency to ~70 ms but
does not address the visibility gap — which surfaced during the same
HITL session and was filed as "I can't see the videos anywhere".

**Trigger context:** `docs/handoff-bugs-10-14.md` and the original
Bug 14 description in `docs/stage-11-pre-existing-bugs.md` both
phrased the save path as "MP4 saves to Photos". The current code
does not do that — it writes only to private Documents. Decoupled
from Bug 14's state-machine fix and out of scope for that commit.

---

## Two-piece scope

The two pieces are independent and can land in either order, but
both are user-visible and should land before Stage 12 sign-off if
recording is to feel complete.

### Piece 1 — `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`

Makes the app's Documents directory show up in the Files app under
"On My iPad → eva-swift-stitch". Lets the user inspect / share / move
videos without needing Xcode or `devicectl`. Smallest possible patch.

**Changes:**
- `eva-swift-stitch.xcodeproj`: add two `INFOPLIST_KEY_*` build
  settings to the `eva-swift-stitch` target's Debug + Release
  configurations:
  - `INFOPLIST_KEY_UIFileSharingEnabled = YES`
  - `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES`
  Use the Ruby `xcodeproj` gem per CLAUDE.md §6 (never hand-edit
  `project.pbxproj`).

**Verification:**
- Build + install on iPad.
- Files app → On My iPad → confirm "eva-swift-stitch" folder appears.
- Confirm recorded `.mp4`s are listed; tap one to preview inline.

**Risk:** Negligible. These flags are well-trodden and don't change
recording semantics. The only downside is that *every* file in
Documents becomes user-visible (including `camerakit.log`,
`capabilities.txt`). For a development build this is fine; for
release a follow-up could relocate the log to `Library/Caches`.

---

### Piece 2 — `PHPhotoLibrary` save for recorded video

Mirrors `StillCapture.swift:280-300` for video, so finished
recordings land in Photos automatically. This is the path the
handoff doc actually described.

**Changes:**

1. **Info.plist (build setting)** —
   `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` already exists
   for stills (`Save still captures to Photos`) — extend the wording
   to cover video, or leave it as-is if Apple's review treats the
   single description as sufficient (it usually does).

2. **Engine surface** — `CameraEngine.stopRecording()` currently
   returns the file URI string. Add an optional post-stop step that
   delegates the saved file to a Photos-save helper. Two designs:
   - **(a) In-engine:** mirror `StillCapture.saveToPhotoLibrary(url:)`
     pattern. The engine performs the save after `await rec.stop()`
     returns, before returning the URI. Simple, but couples the
     engine to Photos.
   - **(b) Hook seam:** add `var onRecordingSaved: (URL) async -> Void`
     to the engine; let the app (`eva_swift_stitchApp` /
     `CameraView`) install a Photos-save handler. Cleaner separation,
     matches the existing hook-style for recording errors.

   Recommend (b) — preserves CameraKit's library-side purity and
   leaves the Photos decision to the app.

3. **Authorization** — reuse the existing
   `PHPhotoLibrary.requestAuthorization(for: .addOnly)` flow at app
   launch. `StillCapture` already does this; piggyback on its
   permission grant.

4. **Error surface** — if the Photos save fails (no permission, disk
   full, asset rejected) emit a non-fatal `CameraError` via the
   existing recording-error hook so the UI can surface a toast. Do
   not delete the source `.mp4` — keep it in Documents as fallback.

5. **Optional: delete-after-save** — once the video lands in Photos,
   removing the Documents copy reduces container bloat. Out of scope
   for the first cut; add behind a settings toggle later.

**Verification:**
- Build + install on iPad.
- Grant Photos permission on first cold-launch.
- Record → stop → confirm video appears in Photos app within seconds.
- Confirm `camerakit.log` has a `[recording] saved-to-photos` notice
  log on success / `[recording] save failed` error log on failure.

**Risk:** Medium. Photos authorization is reliable but the
`performChanges` callback runs on a Photos-internal thread and the
existing recording teardown is already async-heavy. The save should
happen **after** `Recording.stop` returns the URI — not inside
`Recording.stop` itself — to keep the recording-state-machine fast.

**Regression test:** add to `Stage10Tests.swift` — verify the
recording-saved hook fires exactly once per `start → stop` cycle
with the correct URI. Photos itself can't be unit-tested (Photos
isn't injectable); the hook is the seam.

---

## Order and dependency

Pieces are independent. Suggested order, smallest-first: Piece 1
(Files app visibility), verify, then Piece 2 (Photos save). Each
commit narrowly scoped.

If only one lands before Stage 12: pick Piece 1. Documents
visibility in the Files app gives the user a working access path
immediately and is reversible. Photos save is the more polished
end-state but introduces async permission flow and a new failure
surface.

---

## Non-goals

- Migrating still capture's existing Photos save logic. It works.
- Adding a video gallery to the app itself.
- Changing the Documents-relative file path or naming scheme.
- Adding a permanent share sheet inside the recording UI.

---

## Related docs

- `docs/stage-11-pre-existing-bugs.md` — Bug 14 closure
  (note the "Out of scope" footer pointing here)
- `docs/pre-stage-12-handoff.md` — same closure note, longer form
- `CameraKit/Sources/CameraKit/StillCapture.swift:280-300` — the
  Photos-save reference pattern
- CLAUDE.md §5 — Info.plist via build setting, not Plist key

---

## Definition of done

- ✅ (Piece 1) `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
  set in commit `d8ecfc0`; HITL confirmed Files.app shows the Documents
  folder with recorded `.mp4`s playable inline.
- ✅ (Piece 2) Photos permission granted at launch (eager auth in
  `engine.open()`); HITL on iPad confirmed `.copy` and `.move` paths
  surface the recording in Photos within ~2 s of stop. Failure path:
  no UI toast wired in `eva-swift-stitch` host app yet — the failure
  is non-fatal, the file is preserved at `outputURL`, and a
  `CameraError(.unknownError, isFatal:false)` is published on
  `engine.errorStream()` for a future host-side subscriber. Tracked
  in `2026-05-13-error-surfacing-followups.md`.
- 🟡 Stage10Tests suite — pre-existing CameraKitTests host-app wiring
  blocks `xcodebuild test` (CLAUDE.md §8); regression covered by HITL
  verification of the `Recording.stop` durationMs log (39–69 ms across
  four recordings on 2026-05-13).
- ✅ No regression in Bug 14 — `Recording.stop` durationMs stayed at
  39 / 39 / 69 / 90 ms across HITL recordings (well under 200 ms cap).
  `stopRecording` wall time grows only when `photosDestination != .none`
  (e.g. 634 ms with `.copy`, 481 ms with `.move`), which is the
  Photos-publish round-trip and is acceptable because the caller
  opted in.

## Architectural deviations (post-implementation, 2026-05-13)

Three departures from the original plan, settled during the alignment
session that preceded execution and confirmed during HITL:

1. **Unified `outputURL` + `PhotosDestination` API replaces the
   "hook seam" recommendation.** The plan §Piece 2 proposed a public
   `onRecordingSaved` hook so host apps could shuttle the file into
   Photos themselves. We chose a library-side dispatch instead:
   `RecordingOptions.photosDestination` and the matching
   `captureImage(photosDestination:)` parameter. Host apps drop in
   `CameraView()` with just the two usage-description Info.plist keys
   — no Photos plumbing required. Lives in
   `CameraKit/Sources/CameraKit/PhotosLibraryClient.swift`.

2. **Photos is opt-in (`.none` default), not always-save.** The plan
   said "save to Photos by default". We made `.none` the default so
   the recording lives only at the on-disk `outputURL` (which is
   `<Documents>/<timestamp>.mp4` by default and now visible via
   Files.app via Piece 1). The caller passes `.copy` to publish a
   copy, or `.move` to hand ownership to Photos. The default policy
   matches the project's privacy-leaning posture: nothing leaves the
   sandbox without an explicit opt-in.

3. **API break to `RecordingOptions`.** The plan preserved
   `outputDirectory` + `fileName`. We replaced both with
   `outputURL: URL?` (resolved per `PhotosLibraryClient.resolve`) +
   `photosDestination`. Stage 11 is unshipped — this was the right
   moment for a clean break. Existing in-tree callsites
   (`RecordingViewModel.swift:66` and `Stage10Tests.swift` 10 sites)
   all use defaults and kept compiling. `CameraEngine.captureImage`
   also broke its signature: `outputPath: String?` →
   `outputURL: URL?` + `photosDestination`. The lone caller
   (`ViewModel.swift:190`) used the zero-arg form and was unaffected.

Plus one unplanned-but-needed addition during HITL:

4. **`PhotosLibraryClient.describe(_:)` for typed PHPhotosError
   messages.** Apple's `NSError.localizedDescription` for PHPhotosError
   is often null or "(null)"; the caller had to know that code 3311 =
   `accessUserDenied`. `describe` maps known cases (accessUserDenied,
   accessRestricted, invalidResource, networkAccessRequired, etc.) to
   a human-readable string with a suggested user action. Falls back to
   the bare NSError fields for unrecognised codes.
