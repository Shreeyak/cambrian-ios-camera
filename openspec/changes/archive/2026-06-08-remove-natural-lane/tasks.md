# Tasks

Lands after `frame-delivery-contract` (edits the new per-lane construction).
Build/test via XcodeBuildMCP `*_device` (fallback `scripts/build-summary.sh` /
`scripts/test-summary.sh`); device-only, never simulators.

## 1. Remove the streaming natural lane

- [x] 1.1 In `MetalPipeline`, remove Pass-7n and the natural BGRA8 streaming mailboxes (`_latestNaturalBuffer` / `_latestNaturalBgra8Tex`) + the `.natural` yield. (`StreamId.natural` + the `.natural` yield were already gone from frame-delivery-rework.) **Kept `naturalPool` (Pass-1/16F) AND `eightBitNaturalPool`** — the latter is the one-shot output pool for `gradeOneShot`/`captureNaturalPicture` (Decision 1: keep the ISP path), so it no longer runs per-frame.
- [x] 1.2 Remove `SessionCapabilities.naturalTextureId` and the natural BGRA8 preview accessor `currentTexture()` + `currentNaturalPixelBuffer()`. (`StreamId.natural` already absent.)
- [x] 1.3 Prune dead references in `Errors.swift` (updated `bufferUnavailable` doc; `noFrameAvailable` kept for calibration). `OutputPathResolution` had no natural-lane references.

## 2. Preserve calibration inputs

- [x] 2.1 Kept Pass-1 and `latestNaturalTex16F` (processed derives from it; calibration samples it). Verified: calibration suites (Stage11 WB/BB) pass — they sample the preserved 16F texture via `setLatestNaturalForTest`.

## 3. captureNaturalPicture

- [x] 3.1 **Decision 1 (user): keep the existing ISP one-shot path** (`session.capturePhoto()` → `gradeOneShot`), which is full-sensor resolution and already on-demand, rather than the 16F-readback the spec originally prescribed. The public signature and the running-session error gating are unchanged; `eightBitNaturalPool`/`gradeOneShot` are retained for this one-shot. Tradeoff: the still is GRADED (matches preview) and the per-frame Pass-7n cost is still genuinely removed. (The 16F-readback alternative — ungraded, preview-res — was rejected.) Artifacts (design §D2, spec) updated to match.

## 4. Tests + docs + verify

- [x] 4.1 Added `RemoveNaturalLaneTests` (StreamId == {primary, tracker}; SessionCapabilities has no `naturalTextureId`). Calibration (WB/BB) covered by passing Stage11 suites; natural still-capture encode by CaptureNaturalPictureTests + `IspGradeOneShotTests` + HITL.
- [x] 4.2 Updated DocC guides (01-overview, 04-preview, 07-image-processing) for the removed natural preview lane; regenerated `Documentation/`.
- [x] 4.3 Build green on device; affected suites pass; `swift-format lint --strict` passes on `CameraKit/Sources`.

## Deviations from artifacts

- **Capture mechanism (3.1):** spec/design prescribed a 16F→BGRA8 readback; user chose to keep the full-res ISP one-shot (`gradeOneShot`). Spec + design §D2 updated to match.
- **Flutter (Decision 2, user):** accept-broken. `naturalTextureId` removed from CameraKit `SessionCapabilities`; the Flutter adapter (`ValueTypeMappers`) and Pigeon side are NOT updated here — that lands in `flutter-single-preview`. `flutter build ios` is red in the interim (per the proposal's "Flutter side deferred").
