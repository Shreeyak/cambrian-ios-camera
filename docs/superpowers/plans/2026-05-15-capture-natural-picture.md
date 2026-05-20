# `captureNaturalPicture` — implementation plan

Design: `docs/superpowers/specs/2026-05-15-capture-natural-picture-design.md`.
Rationale ledger: `CameraKit/DECISIONS.md` D-2P-10.

## Scope

One additive `async throws` method on `CameraEngine`, plus a small refactor of
`StillCapture`'s encode helper so both lanes share one encode path.

```swift
public func captureNaturalPicture(
    outputURL: URL? = nil,
    photosDestination: PhotosDestination = .none
) async throws -> StillCaptureOutput
```

Production-shape contract — mirrors `captureImage(outputURL:photosDestination:)`
exactly (`CameraEngine.swift:1133`): same parameter names, same defaults, same
return type `StillCaptureOutput`, same throws taxonomy
(`EngineError.notOpen`, `EngineError.invalidOutputPath`,
`EngineError.capture(StillCaptureError)`), same optional Photos publish with
non-fatal failure routed through `errorStream()`. The plan deliberately follows
the existing flat `StillCaptureOutput { filePath: String }` (not a sum type with
`.path`/`.assetId` — the design doc's strawman was wrong about the existing
shape); the file always lands on disk first, Photos publish is then a side
effect of `photosDestination != .none`.

## Open Questions — pinned

### 1. New `bufferUnavailable` error case — yes, add it

Add `StillCaptureError.bufferUnavailable` (additive). The existing taxonomy is:

```swift
public enum StillCaptureError: Error, Sendable {
    case alreadyInFlight
    case metalReadbackFailed
    case fileWriteFailed(String)
}
```

`metalReadbackFailed` is reused by `captureImage` to mean "the GPU readback path
broke" — the Pass-6 continuation, the CVPixelBuffer lock, the vImage
conversion, the `CGImage` build. Overloading it to also mean "the mailbox is
empty because no frame has arrived yet" is a step backwards on diagnosability.
A distinct case lets callers (Phase-3 Pigeon adapter, tests, UI) discriminate
"truly broken" from "called too early — try again in a few ms".

The case carries no associated value. The "why empty" detail goes into the log
line at the call site.

### 2. Test-suite naming — `CaptureNaturalPictureTests.swift`, no stage prefix

Match the post-Stage-12 hardening cadence (`MailboxTests`,
`SessionStateMachineTests`), not the legacy `Stage07Tests` style. The repo is
past stage discipline; further test files are organised by feature, not stage
index. The other parallel efforts (RGBA conversion, texture bridge) should
adopt the same convention when they land.

File: `CameraKit/Tests/CameraKitTests/CaptureNaturalPictureTests.swift`. After
creation, run `scripts/sync-test-target.sh` to add to the Xcode test target
(dual-membership rule, §8 of CLAUDE.md).

Each `@Suite` is its own struct — filter is
`-only-testing:eva-swift-stitchTests/CaptureNaturalPictureTests` (the struct
name, not the filename). The suite displays as
`"CaptureNaturalPictureTests — captureNaturalPicture"`.

### 3. Encode-helper signature — promote test seam, parameterize format

Today `StillCapture` has:

- private production path `captureImage(pipeline:captureSize:deviceSnapshot:…)`
  which arms the pipeline continuation, then sequentially calls private
  `convertRGBA16FtoRGBA8`, `makeCGImage`, `buildCamPluginV1Json`,
  `buildImageProperties`, `writeTIFF`.
- internal test seam `encodeToTIFF(readbackBuffer:captureSize:…)` which does
  *everything except* the pipeline arming — already accepts any
  `CVPixelBuffer`.

The "small refactor" is to:

1. Rename `encodeToTIFF` → `encode(buffer:captureSize:deviceSnapshot:focalLengthMm:apertureValue:outputURL:format:laneTag:)`.
   Internal visibility unchanged.
2. Add two new parameters at the end of that signature:
   - `format: UTType` — `.tiff` or `.jpeg`. Threaded into the
     `CGImageDestinationCreateWithURL` UTI argument.
   - `laneTag: String?` — `"natural"` for `captureNaturalPicture`, `"processed"`
     for `captureImage`, `nil` from legacy/encode-only tests. Threaded into the
     `CamPlugin/v1` JSON envelope as a `"lane"` field. See Open Question 5.
3. Rename private `writeTIFF(cgImage:metadata:to:)` →
   `writeImage(cgImage:metadata:format:to:)`. Same body, format passed to
   `CGImageDestinationCreateWithURL`.
4. Update the production `captureImage(pipeline:...)` path to delegate to the
   new `encode(...)` after the Pass-6 readback (`buffer:` is the readback
   `CVPixelBuffer`, `format: .tiff`, `laneTag: "processed"`). Eliminates the
   duplicated inline sequence at `StillCapture.swift:55-79`.
5. Update the three `Stage07Tests` call sites — they currently call
   `encodeToTIFF(readbackBuffer:...)`; rewrite to
   `encode(buffer:..., format: .tiff, laneTag: nil)`.

Net diff for the refactor: one rename of an internal helper, one rename of a
private helper, one new shared call site inside `captureImage(pipeline:)`, three
test-call-site updates. No new public API.

### 4. Capture during `SessionState.paused` — allowed

The natural-lane buffer mailbox holds the last frame written by the delivery
queue. When the session is paused (scenePhase = background), the delivery queue
stops; the mailbox is not cleared. A capture during `.paused` returns
*something* — the last frame from before the pause — and that is the right
semantics for the contract. The caller asked for "the natural picture"; we
hand them the most recent natural-lane frame we have.

Gating is therefore by *buffer availability*, not by state machine:

```swift
guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
    throw EngineError.notOpen
}
guard let buffer = pipeline.latestNaturalBuffer else {
    throw EngineError.capture(.bufferUnavailable)
}
```

`isOpen` (state machine `!= .closed`) ensures `metalPipeline` exists.
`latestNaturalBuffer == nil` cleanly handles two cases: (a) just opened, no
frame yet; (b) `_metalPipeline.latest` cleared during close — both surface as
the same diagnosable error.

Unlike `captureImage`, we do **not** gate on `cameraSession.avSession.isRunning`:
the natural buffer reflects past delivery, not current hardware state. The
buffer's existence is the truth.

### 5. EXIF marker distinguishing natural vs. processed — add to CamPlugin JSON

Distinguish, low cost:

```jsonc
// EXIF UserComment field
{
  "CamPlugin/v1": {
    "lane": "natural",       // or "processed" — new
    "iso": 100,
    "exposureDurationNs": 33333333,
    "wbGainR": 1.5, "wbGainG": 1.0, "wbGainB": 1.8,
    "lensPosition": 0.5
  }
}
```

Plumbed through the new `laneTag:` parameter on `encode(...)`. Existing
processed-lane captures get `"lane": "processed"`. Natural captures get
`"lane": "natural"`. `nil` from tests / legacy callers omits the field —
backwards-compatible for any consumer that wasn't expecting it (Phase-3 adapter
hasn't shipped yet).

Standard EXIF `Software` / `ImageDescription` fields are *not* used for this —
keeping the lane marker in the CameraKit-owned `CamPlugin/v1` envelope is
cleaner than overloading a generic EXIF field.

## Files

**New:**
- `CameraKit/Tests/CameraKitTests/CaptureNaturalPictureTests.swift` — see §Testing.

**Modified:**
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — add
  `captureNaturalPicture(outputURL:photosDestination:)`. ~50 lines new.
- `CameraKit/Sources/CameraKit/StillCapture.swift` — promote and rename
  `encodeToTIFF` to `encode(buffer:..., format:laneTag:)`. Rename `writeTIFF`
  to `writeImage(format:)`. Re-thread `captureImage(pipeline:...)` to use the
  new helper. Add `"lane"` field to `buildCamPluginV1Json(laneTag:)`. Net ~20
  lines new + ~10 lines moved.
- `CameraKit/Sources/CameraKit/Errors.swift` — add
  `StillCaptureError.bufferUnavailable`. One line.
- `CameraKit/Tests/CameraKitTests/Stage07Tests.swift` — three call sites change
  from `encodeToTIFF(readbackBuffer:...)` to `encode(buffer:..., format: .tiff, laneTag: nil)`.
- `CameraKit/state.md` — capabilities-ledger entry pointing at the design +
  plan. Same pattern as the existing post-Stage-12 hardening entries.
- `CameraKit/DECISIONS.md` — entry already appended (D-2P-10).

**Not changed:**
- `CameraSession.swift` — no new `AVCaptureOutput`.
- `MetalPipeline.swift` — no new pass, no new readback continuation.
- `CaptureAtomic.cpp/.hpp` — natural-lane tap doesn't need the guard. The
  existing `CppCaptureAtomic` in `StillCapture` continues to guard
  `captureImage` only.
- `PhotosLibraryClient.swift` — `resolve` / `publish` reused as-is. Default
  extension is `"jpg"` for the new method.

## Implementation order

1. `Errors.swift` — add `StillCaptureError.bufferUnavailable`. Smallest unit,
   compile-safe immediately.
2. `StillCapture.swift` — refactor encode helper (rename, parameterize format,
   thread `laneTag`). Update `captureImage(pipeline:)` to delegate.
3. `Stage07Tests.swift` — update three call sites.
4. Build + run Stage07Tests to confirm no regression in the existing path.
5. `CameraEngine.swift` — add `captureNaturalPicture(outputURL:photosDestination:)`.
6. `CaptureNaturalPictureTests.swift` — new test file.
7. `scripts/sync-test-target.sh` — wire the new test file into the Xcode test
   target.
8. Build + run full suite, then the new test class explicitly.

This sequence lets the existing Stage 07 suite re-validate the refactor before
the new method's tests come online — separating "did I break captureImage?"
from "does captureNaturalPicture work?".

## Engine method skeleton

```swift
/// Captures the current *natural* (unprocessed) frame as a JPEG.
///
/// Reads the latest Pass-1 natural-lane buffer from `MetalPipeline`
/// (`currentPixelBuffer(stream: .natural)` substrate, RGBA16F, IOSurface-backed),
/// converts RGBA16F → RGBA8 via vImage, encodes as JPEG via `CGImageDestination`,
/// attaches `DeviceStateSnapshot`-derived EXIF (with `"lane": "natural"` in the
/// `CamPlugin/v1` envelope), writes to disk, optionally publishes to Photos.
///
/// Mirrors `captureImage`'s error contract except for the `metalReadbackFailed`
/// case (no GPU readback continuation here) — replaced by `bufferUnavailable`
/// when the natural mailbox is empty (engine open but no frame delivered yet).
///
/// - Parameters: same shape as `captureImage`.
/// - Returns: `StillCaptureOutput` with the on-disk file path.
/// - Throws: `EngineError.notOpen` if the engine is `.closed`.
/// - Throws: `EngineError.invalidOutputPath(_:)` if `outputURL` escapes sandbox.
/// - Throws: `EngineError.capture(.bufferUnavailable)` if no natural frame has been delivered.
/// - Throws: `EngineError.capture(.metalReadbackFailed | .fileWriteFailed)` per `StillCapture.encode`.
public func captureNaturalPicture(
    outputURL: URL? = nil,
    photosDestination: PhotosDestination = .none
) async throws -> StillCaptureOutput {
    guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
        throw EngineError.notOpen
    }
    guard let buffer = pipeline.latestNaturalBuffer else {
        CameraKitLog.warning(.engine, "[natural] no natural-lane buffer available")
        throw EngineError.capture(.bufferUnavailable)
    }
    let snap = await cameraSession?.device?.lastSnapshot
    let apertureValue: Double
    if let device = cameraSession?.device {
        apertureValue = Double(await device.lensAperture)
    } else {
        apertureValue = 0
    }
    let writeURL = try PhotosLibraryClient.resolve(outputURL: outputURL, defaultExt: "jpg")
    let output: StillCaptureOutput
    do {
        output = try await capture.encode(
            buffer: buffer,
            captureSize: pipeline.captureSize,
            deviceSnapshot: snap,
            focalLengthMm: 0,
            apertureValue: apertureValue,
            outputURL: writeURL,
            format: .jpeg,
            laneTag: "natural"
        )
    } catch let e as StillCaptureError {
        throw EngineError.capture(e)
    }
    // Optional Photos publish — non-fatal; on failure file at output.filePath
    // is preserved and the error is published on errorStream() (mirror of
    // captureImage path).
    if photosDestination != .none {
        let url = URL(fileURLWithPath: output.filePath)
        do {
            try await PhotosLibraryClient.publish(
                url: url, kind: .photo, destination: photosDestination
            )
            CameraKitLog.notice(
                .engine,
                "[natural] published-to-photos path=\(output.filePath) destination=\(photosDestination.rawValue)"
            )
        } catch {
            let detail = PhotosLibraryClient.describe(error)
            CameraKitLog.error(
                .engine,
                "[natural] photos publish failed (destination=\(photosDestination.rawValue)): \(detail)"
            )
            publishError(
                CameraError(
                    code: .unknownError,
                    message: "photos publish failed (destination=\(photosDestination.rawValue)): \(detail)",
                    isFatal: false
                )
            )
        }
    }
    return output
}
```

## Testing

`CaptureNaturalPictureTests.swift` — uses the same fp16-buffer fixture as
Stage07Tests (`makeFp16Buffer(width:height:r:g:b:)`) and the new `encode(...)`
helper directly. The Pass-6 continuation arming has no analogue here, so tests
can be simpler: build a fake buffer, call `encode(..., format: .jpeg, laneTag: "natural")`,
decode the JPEG, assert pixels + EXIF.

Test cases (suite struct: `CaptureNaturalPictureTests`):

1. **`encode-natural-jpeg-round-trip`** — RGBA(1.0, 0.0, 0.5) fp16 buffer →
   `encode(..., .jpeg, "natural")` → decode JPEG via `CGImageSourceCreateWithURL`
   → assert pixel ~ (255, 0, 127). JPEG is lossy; tolerance bumps from ±1 LSB
   (TIFF) to ±8 LSB (low-resolution test buffer + chroma subsampling).
2. **`exif-camplugin-v1-natural-marker`** — encode with `laneTag: "natural"` →
   parse `EXIF/UserComment` JSON → assert `json["CamPlugin/v1"]["lane"] == "natural"`.
3. **`exif-camplugin-v1-processed-marker`** — same but `laneTag: "processed"`
   → assert `lane == "processed"`. Locks the back-compat behavior of the
   re-threaded `captureImage` path.
4. **`exif-camplugin-v1-nil-omits-lane`** — `laneTag: nil` → `"lane"` key absent.
   Locks the legacy-test path (Stage07Tests calls with nil).
5. **`default-flow-writes-to-documents-jpg`** — `encode(..., .jpeg, ...)` with
   `outputURL: nil` resolves to `<Documents>/<timestamp>.jpg` (uses the
   `defaultExt: "jpg"` from the engine layer). Asserts the path prefix.
6. **`engine-buffer-unavailable-throws`** — open an engine with no frame ever
   delivered (`_markOpenForTest` + no `MetalPipeline` driving), call
   `engine.captureNaturalPicture(...)`, assert throws
   `EngineError.capture(.bufferUnavailable)`. (If `_markOpenForTest` doesn't
   wire `metalPipeline`/`stillCapture` to non-nil, we get `.notOpen` instead;
   plan-time uncertainty — pin to one of the two outcomes during
   implementation by reading `_markOpenForTest`'s actual setup, then assert
   accordingly.)

The "engine harness" test (#6) may need a small test seam — investigate during
implementation. If `_markOpenForTest` is sufficient, no new seam. If not,
prefer asserting only the unit-level `encode(...)` path (#1-5) and treat #6
as device-HITL evidence rather than a CI test.

## Verification

Per CLAUDE.md §6 — device only, no simulators.

- Build: `mcp__XcodeBuildMCP__build_run_device` (XcodeBuildMCP primary).
  Fallback: `scripts/build-summary.sh`.
- Tests: `mcp__XcodeBuildMCP__test_device` with
  `extraArgs: ["-only-testing:eva-swift-stitchTests/CaptureNaturalPictureTests", "-only-testing:eva-swift-stitchTests/Stage07Tests"]`.
  Fallback: `scripts/test-summary.sh --filter eva-swift-stitchTests/CaptureNaturalPictureTests`
  and then the Stage07Tests filter.
- swift-format `--strict` (commit hook) — multi-sentence doc comments need the
  blank `///` line after the first sentence (`BeginDocumentationCommentWithOneLineSummary`).
- `scripts/regen-contracts.sh` runs on pre-commit; the new
  `captureNaturalPicture(outputURL:photosDestination:)` lands in `CONTRACTS.md`.

## HITL (deferred to user)

- Live capture both `captureImage` and `captureNaturalPicture` of the same scene
  on the iPad, save both to disk and to Photos.
- Visually inspect: the natural output should *not* have CameraKit's
  color-transform applied (it's the pre-LUT sensor output post-ISP); the image
  output should have it applied.
- Inspect EXIF of both — confirm `CamPlugin/v1` envelope has
  `"lane": "natural"` vs `"lane": "processed"`.
- Evidence under `docs/measurements/capture-natural-picture/2026-05-15/`.

The HITL is the user's call to run; this plan ships the code and the CI tests.

## What this plan deliberately does NOT do

- No `AVCapturePhotoOutput` — D-2P-10.
- No new `AVCaptureOutput` attached to the session. `CameraSession.configure()`
  unchanged.
- No new `CaptureAtomic` integration. Natural lane tap doesn't need the guard;
  concurrent invocation with `captureImage` is serialised by the engine actor
  but otherwise independent.
- No new Metal pass, no new readback continuation, no new `pendingCapture*` field.
- No RAW / HEIF / DNG / ProRAW / Live Photo / bracketed-capture support. Out
  of scope per design §Carve-outs.
- No per-capture `AVCapturePhotoSettings`-equivalent overrides.
- No "system shutter sound" (no `AVCapturePhotoOutput` means the OS does not play it).
- No format choice exposed on the public API. JPEG is hard-coded for v1.

If any of these are needed later, they land as separate additive paths.

## Stop point

After tests pass on physical iPad, stop. No git operations without explicit
user approval (CLAUDE.md §7).
