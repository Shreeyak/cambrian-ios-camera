# `captureNaturalPicture` — design

## Problem

The Pigeon contract names two still-capture methods:

- **`captureImage`** — captures the *processed* lane (post-color-transform). Already
  shipped in Stage 7 as `CameraEngine.captureImage(outputURL:photosDestination:)`
  (`CameraEngine.swift:1133`, implemented in `StillCapture.swift`). Arms a Pass-6
  readback continuation on `MetalPipeline`, blits the RGBA16F render-target back to
  the CPU, runs vImage RGBA16F → RGBA8, encodes via `CGImageDestination`, attaches
  EXIF synthesised from `DeviceStateSnapshot`, saves to disk or Photos library.

- **`captureNaturalPicture`** — captures the *natural* (unprocessed) lane. Not yet
  implemented in CameraKit. The Flutter migration spec
  (`2026-05-14-camerakit-flutter-migration-design.md` §2c) deferred it to Phase 3 as
  "a genuinely new capture path, not vocabulary work."

That deferral framing was wrong. CameraKit already produces the natural lane (Pass-1
output of `MetalPipeline`: YUV → RGBA16F, IOSurface-backed); the Phase-2 accessor
`currentPixelBuffer(stream: .natural)` already exposes its latest frame. The "new
capture path" CameraKit needs is just an encode + save built on existing primitives.
This doc lands `captureNaturalPicture` in CameraKit before Phase 3 begins, at the
simplest scope that satisfies the contract — Phase 3's adapter then wraps it as a
one-line Pigeon handler.

## Goal

One additive `async throws` method on `CameraEngine`:

```swift
public func captureNaturalPicture(
    outputURL: URL?,
    photosDestination: PhotosDestination
) async throws -> StillCaptureOutput
```

Shape-isomorphic to the existing `captureImage`. Production behaviour: one new public
method, ~50 lines of new code in `CameraEngine` plus a small refactor of
`StillCapture`'s encode helper to accept an arbitrary `CVPixelBuffer` source. No new
`AVCaptureOutput` attached to the session, no new delegate type, no
`CaptureAtomic` integration, no new `MetalPipeline` pass.

## Why not `AVCapturePhotoOutput`

The first-pass design assumed `captureNaturalPicture` required `AVCapturePhotoOutput`
— a separate hardware-photo capture path with its own delegate-driven lifecycle. That
assumption is wrong for this codebase:

1. **CameraKit already produces the natural lane** as a continuous IOSurface-backed
   stream (`MetalPipeline` Pass-1: YUV → RGBA16F). The Phase-2 accessor
   `currentPixelBuffer(stream: .natural)` returns the latest frame as a retained
   `CVPixelBuffer` reference. No additional capture machinery needed.
2. **The contract method's purpose is "capture the unprocessed image"** — not
   "capture from `AVCapturePhotoOutput` specifically." Tapping the natural lane
   satisfies the contract with the existing pipeline.
3. **`AVCapturePhotoOutput` brings real complexity** — additional `AVCaptureOutput`
   attached to the session inside `CameraSession.configure()`, photo-codec /
   format negotiation, `AVCapturePhotoCaptureDelegate` lifecycle bridged to
   async/await via continuations, possible interaction with the existing
   `AVCaptureVideoDataOutput` on resource-constrained sessions. None of it is
   necessary for the contract method this doc implements.
4. **Quality is equivalent for the use case.** The natural lane is the camera's
   sensor output post-ISP, pre-CameraKit color transform. That's the same data
   `AVCapturePhotoOutput` would deliver, sampled at the same cadence the Phase-3
   bridge sees. Resolution is the active capture format's resolution — full-sensor
   when `captureResolution` is set to `Size(4032, 3024)`.

If a future requirement emerges that strictly needs `AVCapturePhotoOutput`'s features
(RAW DNG, HEIF, embedded depth data, Live Photo, system shutter sound, bracketed
exposure, per-capture `AVCapturePhotoSettings` overrides), it can be added then as a
separate method. This design deliberately scopes to the simplest path that meets the
contract; the rejected alternative is recorded in `CameraKit/DECISIONS.md` D-2P-10.

## Design

### Capture path

1. Engine method `captureNaturalPicture(outputURL:photosDestination:)` is called.
2. Validate session state: throw `StillCaptureError.notStreaming` (or equivalent —
   pin in plan) if `stateMachine.current` is not `.streaming` / `.paused` (a paused
   engine still has a valid latest-frame in the lane mailbox).
3. Read the latest natural-lane buffer:
   `pipeline.currentPixelBuffer(stream: .natural)` returns a retained
   `CVPixelBuffer` (RGBA16F, IOSurface-backed). If `nil` (engine just opened, no
   frames yet), throw `StillCaptureError.bufferUnavailable`.
4. JPEG-encode the buffer via the refactored `StillCapture` encode helper (RGBA16F
   → RGBA8 vImage conversion → `CGImageDestination` JPEG). Output a `Data`.
5. Build EXIF dictionary from `latestDeviceStateSnapshot()` — same path as
   `captureImage`, no change.
6. Route per `photosDestination`:
   - `.filesystem(URL)`: write the encoded `Data` to disk; return
     `StillCaptureOutput.path(URL)`
   - `.photosLibrary`: hand off to `PhotosLibraryClient.saveImageData(_:)`; return
     `StillCaptureOutput.assetId(String)`
7. `return` the `StillCaptureOutput`.

### Why no readback continuation

`captureImage` arms a Pass-6 readback continuation because the processed-lane
render-target is owned by the GPU pipeline; we need to wait for the next render and
copy it back to the CPU. The natural lane is different — its IOSurface-backed
`CVPixelBuffer` is already CPU-readable (the GPU writes into it on the
`delivery` queue; the buffer is a stable reference until the next sample replaces
it). We can JPEG-encode the latest frame directly. No continuation, no Pass-N
synchronisation, no `CaptureAtomic` integration.

### What stays from `captureImage`

- `StillCaptureOutput` return type
- `PhotosDestination` parameter type
- `PhotosLibraryClient` save path (filesystem and Photos-library both)
- EXIF dictionary synthesis from `DeviceStateSnapshot`
- Outer error handling shape (sandbox, IO errors, permission errors, `bufferUnavailable`)

### What's new

- One method on `CameraEngine`: `captureNaturalPicture(outputURL:photosDestination:)
  async throws -> StillCaptureOutput`
- A refactor of `StillCapture`'s RGBA16F → JPEG encode helper to accept any
  `CVPixelBuffer` source rather than the Pass-6 readback buffer specifically. The
  signature widens from `func encodeProcessedLaneReadback(...)` to
  `func encode(buffer: CVPixelBuffer, exif: ...)` (or equivalent — pin in plan).
  Existing `captureImage` callers call the same helper through a thin path that
  performs the readback first, then calls the widened encode.
- Possibly one new error case (`bufferUnavailable` if not already present in
  `StillCaptureError`) — the plan picks. Lean: reuse existing `notStreaming`
  / generic `failed` if either covers the scenario.

## Format scope

JPEG only for v1. HEIF, RAW, Apple ProRAW, DNG explicitly out of scope. If a future
consumer needs them, add as a separate path or a `format:` parameter then. Keeping
v1 to JPEG matches `captureImage`'s scope and minimises the test surface.

## Concurrency contract

- `captureNaturalPicture` is `async`; runs on the engine actor. Other engine calls
  serialise behind it (standard actor semantics).
- It does **not** compete with `captureImage` for `CaptureAtomic` — they are
  independent paths. A caller invoking both concurrently gets two independent
  captures, one per lane, both valid. (Concurrency is interleaved at the actor
  level; the two captures don't run simultaneously, but neither blocks the other.)
- `close()` while a capture is in flight: the `await` on the encode-and-save path
  is short (~tens of ms — no GPU readback to wait for); not worth a special
  cancellation path. The capture either completes before `close()` lands or returns
  a failure if any step throws.
- During `SessionState.interrupted` / `.recovering`: returns
  `StillCaptureError.notStreaming` (or equivalent). `.paused` is acceptable
  (the latest natural-lane mailbox still holds a valid frame from before the
  pause); plan confirms by reading `MetalPipeline.latestNaturalBuffer` semantics.
- `.calibrationInProgress`: not blocked. Calibration mutates WB gains, not the
  natural lane content; capturing during calibration is harmless.

## Carve-outs (out of scope)

- HEIF / RAW / Apple ProRAW / DNG
- Bracketed capture, burst, Live Photo
- Depth data, camera-calibration-data attachment
- Per-capture `AVCapturePhotoSettings`-equivalent overrides (ISO, exposure, WB)
- System shutter sound (no `AVCapturePhotoOutput` means the OS does not play it)
- Flash configuration (irrelevant on iPad)
- Distinct EXIF metadata for the natural-vs-processed distinction (the natural
  capture uses the same `DeviceStateSnapshot`-derived EXIF; if a consumer needs
  to distinguish "this came from the natural lane" they can read a `Software` /
  `ImageDescription` field — not implemented in v1; pin if Phase 3 needs it)

## Testing

New test suite (filename matches the cadence the parallel RGBA / hardening efforts
land on — pin once across all three; lean: `Stage13PreP3CaptureNaturalPictureTests`
or per-feature `CaptureNaturalPictureTests` without a stage prefix). Run
`scripts/sync-test-target.sh` after creating.

Assertions:

- Method exists and is callable on an opened, streaming engine.
- Returns `StillCaptureOutput.path(URL)` for `.filesystem(URL)` destination; the
  file exists at the URL after the call returns; the file decodes as JPEG.
- Returns `StillCaptureOutput.assetId(String)` for `.photosLibrary` destination
  (with the existing `PhotosLibraryClient` test-injection pattern).
- Throws `bufferUnavailable` (or chosen equivalent) when called on a just-opened
  engine before the first frame arrives (use `_markOpenForTest()` + no
  `MetalPipeline` driving).
- Throws `notStreaming` when called on a `.closed` engine.
- Output JPEG decodes to the natural-lane dimensions (the active capture format's
  resolution — e.g. 4032×3024 when `captureResolution` is at its default).
- Concurrent invocation with `captureImage`: both complete; both produce valid
  output files; the natural-lane file is visually distinguishable from the
  processed-lane file (the latter has color-transform applied).

## Verification & integration

- Build via `mcp__XcodeBuildMCP__build_run_device`; tests via `test_device`
  (scheme `eva-swift-stitch`). Wrapper fallback: `scripts/build-summary.sh` /
  `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStructName>`.
- swift-format `--strict` (commit hook) — multi-sentence doc comments need the
  blank `///` line per CLAUDE.md `BeginDocumentationCommentWithOneLineSummary`
  rule.
- `scripts/regen-contracts.sh` runs on pre-commit; verify `CONTRACTS.md` picks
  up the new `captureNaturalPicture` method.
- `state.md` post-Stage-12 capabilities entry pointing at this doc.
- HITL on iPad: capture both `captureImage` and `captureNaturalPicture` of the
  same scene; visually inspect the difference — natural should be unprocessed
  (no CameraKit color transform), image should be color-transformed. Save both
  to Photos library; confirm both PHAssets exist with correct timestamps and
  expected resolutions.
- HITL evidence: `measurements/capture-natural-picture/<date>/`.
- One PR pending explicit git approval per CLAUDE.md §7.

## File inventory

**New:**
- `CameraKit/Tests/CameraKitTests/CaptureNaturalPictureTests.swift` (or stage-prefixed
  per cadence decision; `scripts/sync-test-target.sh` after creation).

**Modified:**
- `CameraKit/Sources/CameraKit/CameraEngine.swift` — add
  `captureNaturalPicture(outputURL:photosDestination:)`.
- `CameraKit/Sources/CameraKit/StillCapture.swift` — refactor the encode helper
  (RGBA16F → RGBA8 → JPEG) to accept any `CVPixelBuffer` source. Existing
  `captureImage` call site re-targets the widened helper.
- `CameraKit/Sources/CameraKit/Errors.swift` — possibly one new
  `StillCaptureError.bufferUnavailable` case (plan picks vs. reusing existing).
- `CameraKit/state.md` — post-Stage-12 capabilities entry pointing at this doc.
- `CameraKit/DECISIONS.md` — entry already appended (D-2P-10) recording the
  "no `AVCapturePhotoOutput`" rationale.

**Not changed:**
- `CameraSession.swift` — no new `AVCaptureOutput` attached to the session.
- `CaptureAtomic.cpp/.hpp` — natural-lane tap doesn't need the GPU-pipeline guard.
- `MetalPipeline.swift` — no new readback continuation, no new pass; the natural
  lane buffer is already there.
- `PhotosLibraryClient.swift` — reused as-is.
- All Phase-2 surface (calibration, permissions, `SessionState.interrupted`).

## Open questions — pinned for the plan

1. **Error case: new `bufferUnavailable` or reuse existing.** When
   `currentPixelBuffer(stream: .natural)` returns `nil` (engine open but no frames
   yet, e.g. between `open()` and the first sample-buffer-delegate fire), throw a
   new `StillCaptureError.bufferUnavailable` or reuse an existing case
   (`notStreaming` if it covers "open but not yet producing")? Plan picks based on
   caller-side ergonomics and the existing `StillCaptureError` cases.
2. **Test-suite naming cadence.** Match Phase-2's `Stage13Phase2*` style, the
   post-Stage-12 hardening's no-stage-prefix style (`MailboxTests`,
   `SessionStateMachineTests`), or a `Stage14*` / `PreP3*` marker? Same question
   the parallel RGBA conversion + texture-bridge cadence designs face; pin once
   across all three (recommend deciding when the first of the three lands).
3. **Encode-helper signature.** Widening
   `StillCapture.encodeProcessedLaneReadback(...)` (or whatever its current name
   is) to `encode(buffer: CVPixelBuffer, exif: …)` is a small refactor; the plan
   confirms the exact new signature, what `captureImage` calls instead, and
   whether any existing test names need updating.
4. **Capture-during-`.paused`.** Whether to allow capture when `SessionState`
   is `.paused` — the natural-lane mailbox still has the last frame from before
   the pause, so capturing returns *something*, but it's the last-pre-pause
   frame, not "now." Plan decides: allow (caller is responsible for knowing the
   semantics) or block (`StillCaptureError.notStreaming`).
5. **Distinct EXIF marker for natural vs. processed.** Should the EXIF carry a
   field distinguishing this capture from `captureImage`'s output (e.g.
   `Software` = `"CameraKit/captureNaturalPicture"`), or are the two outputs
   indistinguishable in metadata? Lean: distinguish, low cost. Plan pins.
