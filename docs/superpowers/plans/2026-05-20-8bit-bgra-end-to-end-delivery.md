# 8-bit BGRA End-to-End Lane Delivery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Plan style:** *guidance, not transcribed code.* The implementer is opus and
> writes the actual Swift/Metal itself. Each step states the change, the symbols
> and file:line anchors involved, the rationale, and (for tests) what to assert —
> not the literal code. Read the file before editing it (CLAUDE.md §6.1).

**Goal:** Make BGRA8 (`kCVPixelFormatType_32BGRA` / `.bgra8Unorm`) the single delivery format for every CameraKit consumer — Flutter bridge, native Metal preview, C++ tracker, and still capture — while RGBA16F survives only as the internal compute format for the Metal math passes.

**Architecture:** Keep the math passes (Pass-1 YUV→RGB, Pass-2 color, Pass-4 tracker downsample, Pass-5 NV12 encode) on RGBA16F render targets. Convert natural + processed to BGRA8 via the existing standalone `rgba16fToBgra8` pass (now unconditional); the tracker lane is *fused* — its pool becomes BGRA8 so Pass-4 writes 8-bit directly (no extra pass, no shader change). Each lane exposes one IOSurface-backed BGRA8 buffer as both `CVPixelBuffer` and `.bgra8Unorm` MTLTexture, collapsing the old texture(16F)/buffer(8-bit) asymmetry. Still capture reads the latest BGRA8 lane buffer directly, deleting the Pass-6 readback pipeline.

**Tech Stack:** Swift 6.2 (strict concurrency), Metal compute shaders, CoreVideo (`CVMetalTextureCache`, `CVPixelBufferPool`, IOSurface), swift-testing. Builds/tests via XcodeBuildMCP `*_device` (no simulators — CLAUDE.md §6).

**Design doc:** `docs/superpowers/specs/2026-05-20-8bit-bgra-end-to-end-delivery-design.md`

---

## Conventions for every task

- **Read before edit.** First read `CameraKit/CONTRACTS.md`, then every file in the task's *Modify* list (CLAUDE.md §6.1). Do not `Read` after `Edit`.
- **Build/test:** primary `mcp__XcodeBuildMCP__test_device` / `build_run_device` with session default scheme `eva-swift-stitch` (set via `session_set_defaults` once; never pass `-scheme` in extraArgs). Fallback `scripts/build-summary.sh` / `scripts/test-summary.sh`. Device-only order: physical iPad → Mac "Designed for iPad" → error. Never `*_sim`, never raw `xcodebuild`/`swift build`.
- **Test filter caveat:** each `@Suite` is its own struct — filter as `eva-swift-stitchTests/<SuiteStructName>`, not the filename.
- **Commits (CLAUDE.md §7):** the implementer must request user approval before any git operation. Treat each task's "Commit" step as "stage + propose commit, await approval." Never `--no-verify`.
- **Phantom SourceKit errors:** trust the build log over the Issue Navigator (CLAUDE.md §6.1). If types go sideways, `rm -rf CameraKit/.build` + clear DerivedData.

## File map (what changes and why)

| File | Responsibility after change |
|---|---|
| `CameraKit/Sources/CameraKit/Capabilities.swift` | `OpenConfiguration` without `lanesEightBit`; `SessionCapabilities.streamPixelFormat` constant `"BGRA8"`; corrected doc-comments |
| `CameraKit/Sources/CameraKit/Constants.swift` | one lane wire format (`_32BGRA` / `.bgra8Unorm`); drop the flag-conditioned `streamPixelFormatString{EightBit,SixteenBit}` pair (single value) |
| `CameraKit/Sources/CameraKit/MetalPipeline.swift` | tracker pool BGRA8 (Pass-4 direct); natural+processed standalone convert always-on; BGRA8 buffer **and** texture mailboxes per lane; internal 16F natural-texture mailbox retained for calibration; processed/tracker 16F mailboxes + parallel 16F natural buffer + Pass-6/still-pool removed; FrameSet carries BGRA8 |
| `CameraKit/Sources/CameraKit/CameraEngine.swift` | texture accessors + `currentPixelBuffer(.tracker)` return BGRA8; `captureImage`/`captureNaturalPicture` read BGRA8 lane buffers; flag plumbing + parallel-16F sourcing removed; corrected doc-comments |
| `CameraKit/Sources/CameraKit/StillCapture.swift` | `encode` consumes BGRA8 (CGImage BGRA byte order); `convertRGBA16FtoRGBA8` + `armCapture`-based `captureImage` removed |
| `CameraKit/Sources/CameraKit/TexturePoolManager.swift` | tracker pool factory → BGRA8 at `trackerSize`; `makeStillCapturePool` removed; BGRA8 lane-pool factory retained/renamed |
| `CameraKit/Sources/CameraKit/Shaders/Rgba16fToBgra8.metal` | unchanged (natural+processed convert kernel) |
| `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift` | retarget to all-lanes-BGRA8; remove flag-toggle suites |
| `CameraKit/Tests/CameraKitTests/Stage13Phase2Tests.swift` | lane-format regression → all BGRA8 |
| `CameraKit/DECISIONS.md`, `CameraKit/state.md` | record D-2P-12; update ledger |

---

## Task 1: Remove the `lanesEightBit` flag — conversion is unconditional

**Files:**
- Modify: `CameraKit/Sources/CameraKit/Capabilities.swift:100-141` (`OpenConfiguration`, `lanesEightBit` at 128/135/141), `:38-49` (`streamPixelFormat` doc)
- Modify: `CameraKit/Sources/CameraKit/Constants.swift:131-149` (lane format constants + `streamPixelFormatString*`)
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:330-343` (pool alloc gate), `:540-545` (Pass-7 `if lanesEightBit` gate), and the `lanesEightBit` stored property/init param
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:366` (capability format reporting) and any `OpenConfiguration(...)` construction site
- Grep first (in-repo): `grep -rn 'lanesEightBit' CameraKit/ eva-swift-stitch/` — fix every hit (incl. app `ViewModel`/`DisplayViewModel` if present)
- **Downstream audit (verified 2026-05-20):** `lanesEightBit` is `public`, so removal is API-breaking. The only external consumer is cam2fd (`/Users/shrek/work/cambrian/camera2_flutter_demo/`, CLAUDE.md §10). Confirmed: cam2fd's own Dart/plugin code does **not** pass `lanesEightBit` — `hitl_screen.dart:160,331` reads `streamPixelFormat` only as a display string. All `lanesEightBit`/`eightBitLane*`/`streamPixelFormatString*` hits in cam2fd are inside its **embedded CameraKit subtree copy**, which mirrors this repo via `camerakit-only` and receives these edits on sync — not an independent caller. ⇒ hard removal is safe; no deprecation shim needed. Re-run this grep if cam2fd has changed.
- Test: `CameraKit/Tests/CameraKitTests/RgbaConversionTests.swift` (drop the "OpenConfiguration" + "streamPixelFormat reflects flag" suites; keep/repoint "pixel-format constants")

- [ ] **Step 1: Update tests to the target shape (red).** In `RgbaConversionTests.swift`, delete the flag-construction and flag-toggle suites (`@Suite("RGBA8 conversion — OpenConfiguration")`, `@Suite("RGBA8 conversion — streamPixelFormat reflects flag")`). Add/keep one assertion that `SessionCapabilities.streamPixelFormat == "BGRA8"` unconditionally. Expect compile failure until `lanesEightBit` is gone.
- [ ] **Step 2: Remove the flag.** Delete `lanesEightBit` from `OpenConfiguration` (property + init param + default). Make the eightBit pool allocation (`MetalPipeline.swift:334-343`) and the Pass-7 convert (`:540-545`) unconditional — drop the `if lanesEightBit` guards; the pools and PSO are always created. Collapse `Constants.streamPixelFormatString{EightBit,SixteenBit}` into one constant (e.g. `streamPixelFormatString = "BGRA8"`); rename `eightBitLane{Pixel,Metal}Format` to drop the now-meaningless "eightBit" qualifier (e.g. `laneWirePixelFormat` / `laneWireMetalFormat`) if it reads cleaner.
- [ ] **Step 3: Fix call sites.** Resolve every `lanesEightBit` grep hit (engine capability reporting at `CameraEngine.swift:366`; any app-side `OpenConfiguration` construction).
- [ ] **Step 4: Build + test.** `mcp__XcodeBuildMCP__build_run_device` then `test_device` filtered to the RgbaConversion suites. Expected: BUILD SUCCEEDED; streamPixelFormat test passes; no references to the removed symbol.
- [ ] **Step 5: Commit** (stage + propose, await approval): `refactor(camerakit): drop lanesEightBit flag — 8-bit lanes unconditional`.

## Task 2: Tracker lane → BGRA8 (fused into Pass-4)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/TexturePoolManager.swift` (tracker pool factory; today the trio uses `makeWorkingFormatPool` — give the tracker a BGRA8 pool at `trackerSize`)
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:328` (`trackerPool = makeWorkingFormatPool(size: trackerSize)` → BGRA8 pool), `:463-480` (Pass-4 — no shader change; output texture is now `.bgra8Unorm`), `:587` (`trackerForSet`), tracker mailbox storage (`:675`)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:776-777` (`currentTrackerTexture`), `:799-801` (`currentPixelBuffer(.tracker)` — currently routes to 16F tracker)
- Test: `RgbaConversionTests.swift` (the "tracker lane stays RGBA16F" suite at `:273` **inverts** — tracker is now BGRA8)

> **Shader pre-verified (2026-05-20):** `Shaders/TrackerDownsample.metal:11` declares `outTex` as `texture2d<float, access::write>` and `:23` writes a plain `float4`. So switching the tracker output pool to `.bgra8Unorm` requires **no shader edit** (unorm clamps [0,1] + stores BGRA8 on write). Re-read the file first to confirm it hasn't changed; if the declaration is format-specific, this task grows a shader edit.

- [ ] **Step 0: Confirm the shader.** Read `Shaders/TrackerDownsample.metal` — verify `outTex` is `texture2d<float, access::write>` and the write is `float4`. Proceed only if so.
- [ ] **Step 1: Flip the tracker format test (red).** Rewrite the `@Suite("RGBA8 conversion — tracker lane stays RGBA16F …")` to assert `currentPixelBuffer(stream: .tracker)` and `currentTrackerTexture()` are `kCVPixelFormatType_32BGRA` / `.bgra8Unorm`. Assert the tracker buffer dimensions equal the pipeline's `trackerSizeForTest` (`MetalPipeline.swift:1003`) — **compute from the helper, not the literal 640×480** (640×480 only holds at 4:3 capture). Expect failure.
- [ ] **Step 1b: Tracker channel-order + clamp test (red).** The tracker takes a *different* path than natural/processed (Pass-4 sampler-downsample writing straight into `.bgra8Unorm`, not the convert kernel) — so it needs its own value test. Drive a uniform known color through `encode(sampleBuffer:)`, lock the tracker BGRA8 buffer (`CVPixelBufferLockBaseAddress` … `GetBaseAddress`), and assert byte order `[B,G,R,A]` for a known input (e.g. red → `[0,0,255,255]`). Add one out-of-range input (half-float `1.5`) → assert it clamps to `255` (unorm-write clamp), not wraps. This catches R/B swap and clamp bugs that the format-tag test cannot.
- [ ] **Step 2: Tracker pool → BGRA8.** Reuse the existing BGRA8 lane-pool factory (`TexturePoolManager.makeBgra8LanePool`, from the rgba8 work) at `trackerSize`. In `MetalPipeline.swift:328`, allocate the tracker pool from it (replacing `makeWorkingFormatPool`). Pass-4 (`:463-480`) is unchanged — its output texture is now `.bgra8Unorm`.
- [ ] **Step 3: Route tracker delivery to BGRA8.** This task introduces the per-lane **BGRA8 texture mailbox** pattern (Task 3 applies the same pattern to natural/processed): add `_latestTrackerBgra8Tex` (and reuse the existing `_latestTracker*` buffer mailbox or add one) and store the tracker pair's buffer+texture at `:675`. Point `currentTrackerTexture()` (`CameraEngine.swift:776-777`) and `currentPixelBuffer(.tracker)` (`:799-801`) at them. Ensure `trackerForSet` (`:587`) uses the BGRA8 tracker buffer. Confirm `CannyConsumer.cpp:86-89` (`_32BGRA → COLOR_BGRA2GRAY`) handles it — no C++ edit expected (already format-branched).
- [ ] **Step 4: Build + test.** Build + run the tracker suite on device. Expected: PASS; tracker buffer is 640×480 BGRA8.
- [ ] **Step 5: Commit** (await approval): `feat(camerakit): tracker lane delivers BGRA8 (fused Pass-4)`.

## Task 3: Collapse texture/buffer to one BGRA8 surface per lane (natural + processed)

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:106-112` (16F texture mailboxes), `:540-575` (Pass-7 already produces `pair.texture` — currently discarded), `:655-675` (mailbox stores), `:699-725` (`currentTexture`/preview-texture fallback), `:826-855` (calibration reads `latestNaturalTex` — must stay 16F)
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:754-777` (`currentTexture`/`currentProcessedTexture`)
- Test: `RgbaConversionTests.swift` mailbox-format suite (`:182`); **split** the old `"Texture mailboxes always return .rgba16Float"` suite (`:246`) — it tested the now-deleted asymmetry; and a new channel-order round-trip

- [ ] **Step 1: Accessor-format test (red).** Assert `currentTexture()` and `currentProcessedTexture()` return `.bgra8Unorm` textures backed by the same `IOSurface` as the corresponding `currentPixelBuffer(stream:)` (compare `CVPixelBufferGetIOSurface` against the texture's surface, or assert same dimensions + format). Expect failure.
- [ ] **Step 1b: Split the calibration-16F guarantee into its own test (red).** The old `:246` suite asserted *all* texture mailboxes are `.rgba16Float` — that meaning is gone. Replace with a dedicated, named test that the **internal** calibration-facing natural texture is still `.rgba16Float` (via the test seam, e.g. `latestNaturalTex`/a `*ForTest` accessor). This is the load-bearing "16F survives internally for the math" guarantee — keep it isolated so a future edit can't silently erode it.
- [ ] **Step 1c: Natural/processed channel-order + clamp test (red).** Drive a known RGBA16F color through `encode(sampleBuffer:)`, lock the natural and processed BGRA8 buffers, read bytes, assert `[B,G,R,A]` order (e.g. input R=1,G=0,B=0 → `[0,0,255,255]`). Add an out-of-range input (`1.5`) → assert clamp to `255`. Catches the R/B swap that every format-tag test misses.
- [ ] **Step 2: Add BGRA8 texture mailboxes.** Pass-7 already yields `naturalEightBitPair.texture` / `processedEightBitPair.texture` (`:557`, `:569`) but only stores the buffer. Add `_latestNaturalBgra8Tex` / `_latestProcessedBgra8Tex` mailboxes and store `pair.texture` alongside the buffer (`:655`+). Point `currentTexture`/`currentProcessedTexture` (`CameraEngine.swift:754-764` → pipeline) at these.
- [ ] **Step 3: Keep one internal 16F texture mailbox; drop the rest.** Retain `_latestNaturalTex` (16F) **only** for calibration (`:831/:855`); consider renaming to `_latestNaturalTex16F` for clarity. Remove `_latestProcessedTex` and `_latestTrackerTex` (16F) — no readers remain once accessors move to BGRA8 (verify with `grep -rn 'latestProcessedTex\|latestTrackerTex'`). Update `currentTexture()` internal fallback (`:699-725`) accordingly.
- [ ] **Step 4: Build + test.** Device build + RgbaConversion mailbox/texture suites. Expected: PASS; preview textures BGRA8, calibration texture 16F.
- [ ] **Step 5: Commit** (await approval): `refactor(camerakit): collapse lane delivery to single BGRA8 surface (texture+buffer)`.

## Task 4: FrameSet / AsyncStream / C++ pool carry BGRA8

**Files:**
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:582-647` (`naturalBuf`/`processedBuf`/`trackerForSet` locals and the `FrameSet(...)` construction at `:632-637`)
- Test: `Stage13Phase2Tests.swift:38-44` (lane pixel-format regression)

- [ ] **Step 1: Test (red).** In `Stage13Phase2Tests.swift`, assert the `FrameSet` lane buffers delivered on `consumers.yield` / the AsyncStream are `_32BGRA` for all three streams.
- [ ] **Step 2: Point FrameSet at BGRA8 buffers.** Change `:635-637` to pass the BGRA8 lane buffers (natural, processed from Pass-7 output; tracker from the BGRA8 tracker pool). Ensure `trackerForSet` (`:587`) falls back to the BGRA8 natural buffer, not the 16F one. The C++ `PixelSink`/`CannyConsumer` already format-branch — no C++ change expected; confirm by reading `CannyConsumer.cpp:81-108`.
- [ ] **Step 3: Build + test.** Device build + Stage13Phase2 suite. Expected: PASS.
- [ ] **Step 4: Commit** (await approval): `feat(camerakit): FrameSet delivers BGRA8 lanes to C++/stream consumers`.

## Task 5: Still capture reads BGRA8 lane buffers — delete the Pass-6 pipeline

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraEngine.swift:1171-` (`captureImage`), `:1267-` (`captureNaturalPicture` — switch source from `latestNaturalBufferRGBA16F` to `latestNaturalBuffer`)
- Modify: `CameraKit/Sources/CameraKit/StillCapture.swift:31-65` (`captureImage` armCapture method — remove), `:75-145` (`convertRGBA16FtoRGBA8` — remove), `:147-173` (`makeCGImage` — BGRA byte order), `:261-285` (`encode` — consume BGRA8, drop the vImage step)
- Modify: `CameraKit/Sources/CameraKit/MetalPipeline.swift:481-509` (Pass-6 blit — remove), `:348` (`makeStillCapturePool` use — remove), `:134-135` (`_latestNaturalBufferRGBA16F` — remove), `armCapture` + the still continuation + delivery (`~:621`); `TexturePoolManager` `makeStillCapturePool` (remove)
- Test: `RgbaConversionTests.swift` "captureNaturalPicture sources RGBA16F" suite (`:293`) **inverts** to BGRA8; add a `captureImage` smoke

- [ ] **Step 1: Tests (red).** Rewrite the `:293` suite: `captureNaturalPicture` now sources the BGRA8 natural buffer. Add a `captureImage` test that produces a valid file from the BGRA8 processed buffer. Keep the `bufferUnavailable` (engine-open-no-frame) assertion for both. Expect failures/compile errors against the old 16F path.
- [ ] **Step 1b: Still-capture pixel round-trip test (red).** This is the test that guards the riskiest edit in the refactor — the CGImage byte-order change in `makeCGImage` (`byteOrder32Little | noneSkipFirst` replacing the old RGBA `noneSkipLast`). Call `StillCapture.encode` on a known-color BGRA8 buffer, read the written file back via ImageIO (`CGImageSourceCreateWithURL` → `CGImageSourceCreateImageAtIndex` → sample a pixel), and assert the known color round-trips (no R/B swap, correct alpha). Without this, a channel-swapped still encodes as a "valid" file and ships.
- [ ] **Step 2: Engine still methods read BGRA8.** `captureImage` (`:1171`) reads `pipeline.latestProcessedBuffer` (BGRA8) and calls `StillCapture.encode` directly (mirror the existing `captureNaturalPicture` structure, `laneTag: "processed"`, `format: .tiff`). `captureNaturalPicture` (`:1267`) switches its guard from `latestNaturalBufferRGBA16F` to `latestNaturalBuffer`.
- [ ] **Step 3: Simplify `StillCapture`.** Delete `captureImage(pipeline:…)` (the armCapture variant) and `convertRGBA16FtoRGBA8`. In `encode`, drop the vImage conversion — the input buffer is already BGRA8; lock the base address and build the CGImage with BGRA byte order (`byteOrder32Little | premultiplied/​noneSkipFirst`) in `makeCGImage`. EXIF/CamPlugin/Photos paths unchanged.
- [ ] **Step 4: Delete Pass-6 + still pool + parallel mailbox.** Remove the Pass-6 blit (`:481-509`), the still-capture pool dequeue (`:348` + `TexturePoolManager.makeStillCapturePool`), `armCapture`/the still continuation/the completion-handler delivery (`~:621`), and `_latestNaturalBufferRGBA16F` (`:134-135`) + its store (`:656`). Grep to confirm no readers remain.
- [ ] **Step 5: Build + test.** Device build + both still suites. Expected: PASS; valid TIFF (processed) + JPEG (natural) from the 8-bit path.
- [ ] **Step 6: Commit** (await approval): `refactor(camerakit): still capture reads BGRA8 lanes; remove Pass-6 readback pipeline`.

## Task 6: Comment correction + dead-code sweep

**Files:**
- Modify: every "HDR-grade precision" / "always RGBA16F (precision)" doc-comment: `CameraEngine.swift:744`, `:760`, `:793-798`, `:1274-1276`; `MetalPipeline.swift:78-86`, `:117`, `:127-135`, `:653`; `Capabilities.swift:38-49`, `:113-127`; `Shaders/Rgba16fToBgra8.metal:13`
- Grep: `grep -rn 'HDR-grade\|RGBA16F\|lanesEightBit\|eightBit\|RGBA8\|asymmetry\|don.t refactor' CameraKit/Sources/` — reconcile each surviving mention

- [ ] **Step 1: Rewrite comments to the true model.** Input is 8-bit (`CameraSession` locked to `_420YpCbCr8…`); RGBA16F is internal compute headroom for the math passes; **all** delivery is BGRA8; the texture/buffer asymmetry no longer exists. Remove the "do not refactor away" warnings tied to the deleted asymmetry.
- [ ] **Step 2: swift-format compliance.** Multi-sentence doc-comments need a blank `///` line after the first sentence (CLAUDE.md — `BeginDocumentationCommentWithOneLineSummary` blocks the commit; `swift-format -i` will **not** fix it). Run `swiftlint lint --config .swiftlint.yml` and `swift-format lint --strict` on touched files.
- [ ] **Step 3: Verify no stragglers.** Re-run the grep; confirm only intentional internal-compute mentions of RGBA16F remain. `scripts/regen-contracts.sh` then eyeball `CONTRACTS.md` for stale format claims.
- [ ] **Step 4: Build.** Device build clean. Expected: BUILD SUCCEEDED, no swift-format diagnostics.
- [ ] **Step 5: Commit** (await approval): `docs(camerakit): correct precision comments — 8-bit source, BGRA8 delivery`.

## Task 7: Record the decision + update the ledger

**Files:**
- Modify: `CameraKit/DECISIONS.md` (append above the stage-header sentinel), `CameraKit/state.md`

- [ ] **Step 1: DECISIONS.md.** Append **D-2P-12** (one line, matching the existing format): 8-bit BGRA8 sole delivery format; RGBA16F internal-compute-only; removed `lanesEightBit`, the texture/buffer asymmetry, the parallel 16F still mailbox, and the Pass-6 still pipeline; tracker fused via Pass-4 BGRA8, natural/processed via standalone `rgba16fToBgra8`; supersedes D-2P-11, retains D-2P-09. Cite the design + plan paths.
- [ ] **Step 2: state.md.** Note the pre-Phase-3 8-bit-delivery work, what's now permanent, and what was removed.
- [ ] **Step 3: Commit** (await approval): `docs(camerakit): D-2P-12 — 8-bit BGRA end-to-end`.

## Task 8: Full verification + on-device HITL

**Files:**
- Create: `measurements/phase-3-prep/8bit-bgra-delivery.md` (HITL evidence)

- [ ] **Step 1: Full test sweep.** `mcp__XcodeBuildMCP__test_device` scheme `eva-swift-stitch`, no filter (all CameraKitTests via dual-membership). Expected: all suites pass; the prior count (181) holds minus removed flag suites, plus the new/retargeted assertions.
- [ ] **Step 2: On-device HITL** (physical iPad — never simulator; CLAUDE.md §6). Capture: sustained fps at 4K with all three lanes converting (compare against the rgba8 baseline of 30 fps, 0 degraded windows); native preview correct (no green/garbage — watch the Metal drawable + blit-origin invariants in CLAUDE.md §8); tracker overlay correct; `captureImage` (TIFF) and `captureNaturalPicture` (JPEG) visually correct. Pull device logs via the `ipad-logs` skill if needed.
- [ ] **Step 3: Record evidence** in `measurements/phase-3-prep/8bit-bgra-delivery.md` (device model + iOS, fps, frame-drop windows, screenshots/paths).
- [ ] **Step 4: Commit** (await approval): `test(camerakit): 8-bit BGRA delivery — HITL evidence`.

---

## Self-review

- **Spec coverage:** format=BGRA8 (Task 1,2,3,4,5); 16F internal-only (Task 3,6); per-lane convert/fuse (Task 2 tracker, Task 3 natural/processed); texture/buffer collapse (Task 3); FrameSet (Task 4); still capture simplification (Task 5); removals — flag/Pass-6/still-pool/vImage/parallel-mailbox/asymmetry (Tasks 1,3,5); streamPixelFormat constant (Task 1); comments (Task 6); decisions+ledger (Task 7); tests+HITL (all + Task 8). No spec section unmapped.
- **Pixel-correctness coverage:** format-tag tests alone pass on an R/B swap, so every conversion path has a value test — tracker channel-order+clamp (Task 2, Step 1b), natural/processed channel-order+clamp (Task 3, Step 1c), still-capture file round-trip guarding the CGImage byte order (Task 5, Step 1b). The calibration-16F guarantee is isolated in its own named test (Task 3, Step 1b). On-screen color, green-frame artifacts, fps, and real-scene tracker quality remain HITL-only (Task 8).
- **Type/name consistency:** new mailboxes `_latestNaturalBgra8Tex` / `_latestProcessedBgra8Tex` and the renamed `_latestNaturalTex16F` are referenced consistently across Tasks 2-3-5; the BGRA8 lane-pool factory is reused (not re-invented) for the tracker.
- **Ordering:** flag removal first (unblocks unconditional paths), then per-lane delivery (tracker, then natural/processed collapse), then FrameSet, then still capture (depends on BGRA8 buffers existing), then comments/decisions/HITL last.
- **Placeholders:** none — every step names concrete symbols, file:line anchors, and verification commands.
