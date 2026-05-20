# 8-bit BGRA End-to-End — Implementation Handoff (Tasks 2–8)

> **You are picking up a partially-executed plan.** Task 1 is done and reviewed.
> Implement Tasks 2–8. This doc is self-contained: it carries the operating
> rules, the gotchas already discovered, and per-task implementation insights so
> you don't rediscover them. Read it fully before starting.

## Where everything is

- **Worktree (work here):** `/Users/shrek/work/cambrian/eva-swift-stitch/.claude/worktrees/bugfix-flutter-crash`
- **Branch:** `worktree-bugfix-flutter-crash` (already checked out). **Do not push.**
- **Design doc:** `docs/superpowers/specs/2026-05-20-8bit-bgra-end-to-end-delivery-design.md`
- **Full task plan (the authoritative task list + steps):** `docs/superpowers/plans/2026-05-20-8bit-bgra-end-to-end-delivery.md` — read each task's section there; this handoff augments it with insights, it does not replace it.
- **Project rules:** `CLAUDE.md` (root). **First read each task:** `CameraKit/CONTRACTS.md`.

## The goal (mental model)

Commit CameraKit to **BGRA8 (`kCVPixelFormatType_32BGRA` / `.bgra8Unorm`) as the single delivery format** for every consumer (Flutter bridge, native Metal preview, C++ tracker, still capture). Keep **RGBA16F internal** to the Metal math passes only (Pass-1 YUV→RGB, Pass-2 color, Pass-4 tracker downsample, Pass-5 NV12 encode) plus WB calibration. The camera is hard-locked to 8-bit, so 16F buys nothing at the boundary — it's only useful as float headroom for the in-shader math.

Per-lane conversion strategy:
- **natural / processed** → standalone `rgba16fToBgra8` convert (the existing "Pass-7"), because their 16F is read downstream.
- **tracker** → *fused*: its 16F has no downstream reader, so make its pool BGRA8 and let Pass-4 write 8-bit directly (no shader edit).

Delivery shape: **one IOSurface per lane**, exposed as both a `CVPixelBuffer` (`currentPixelBuffer(stream:)`) and a `.bgra8Unorm` `MTLTexture` (`currentTexture()`/`currentProcessedTexture()`/`currentTrackerTexture()`). The old texture(16F)/buffer(8-bit) asymmetry is being deleted.

## Current state (commits already on the branch)

```
fdf777d  Task 1 review nits (comments + non-vacuous test seams)
cd90523  regen CONTRACTS.md for Task 1
8ace0db  Task 1: remove lanesEightBit flag — BGRA8 conversion unconditional
c5a18be  docs: design + plan
```

**Task 1 = DONE & reviewed.** `OpenConfiguration.lanesEightBit` is gone; natural+processed convert to BGRA8 unconditionally; pools/PSO non-optional; `Constants.streamPixelFormatString = "BGRA8"` (single constant); `streamPixelFormat` reports `"BGRA8"`. **Tracker is still RGBA16F** (Task 2). Still-capture path is untouched (Task 5). The `_latestNaturalBufferRGBA16F` mailbox still exists — it is removed only in Task 5; keep it through Tasks 2–4.

## OPERATING RULES — follow exactly (these bit us already)

### Builds & tests — device only, via XcodeBuildMCP
- **NEVER iOS simulators** (this machine can't run them), never `*_sim` tools, never raw `xcodebuild`/`swift build`/`swift test`.
- First: `mcp__XcodeBuildMCP__session_show_defaults`. If scheme unset → `mcp__XcodeBuildMCP__session_set_defaults { scheme: "eva-swift-stitch" }`. **Do not** pass `-scheme` via extraArgs (errors "may only be provided once").
- Build: `mcp__XcodeBuildMCP__build_run_device` (or `build_device`). Test: `mcp__XcodeBuildMCP__test_device`.
- Destination order: physical iPad → Mac "Designed for iPad" → error.
- **Test filter:** each `@Suite` is its own struct — filter as `eva-swift-stitchTests/<SuiteStructName>` (the struct name, NOT the filename). CameraKitTests run app-hosted via dual-membership under scheme `eva-swift-stitch`.
- Fallback only if MCP down: `scripts/build-summary.sh` / `scripts/test-summary.sh` (write `.build-logs/*.json` + `.log`). Never pipe through `| tail`.
- **Build log is ground truth.** A `No such module 'Testing'` (SourceKit) diagnostic is a known cross-file phantom — ignore it if BUILD SUCCEEDED. Persistent type phantoms → `rm -rf CameraKit/.build` + clear `~/Library/Developer/Xcode/DerivedData/eva-swift-stitch-*`, rebuild.

### Committing — the pre-commit hook is BYPASSED in this worktree (important)
`core.hooksPath=.githooks`, and `.githooks/` contains only `pre-push`. The real `pre-commit` hook (at `.git/hooks/pre-commit`) is therefore **not run**. It normally does swift-format + SwiftLint + regenerates+stages `CONTRACTS.md`. **You must run those steps manually before every commit:**
1. `swift-format lint --strict` on changed `CameraKit/Sources/**.swift`. The `BeginDocumentationCommentWithOneLineSummary` rule needs a blank `///` line after the first sentence of a multi-sentence doc comment — `swift-format -i` does **not** fix it; split manually.
2. `swiftlint lint --config .swiftlint.yml` on changed files.
3. `scripts/regen-contracts.sh` then `git add CameraKit/CONTRACTS.md` (whenever you changed anything under `CameraKit/Sources/`).
- Commit per task with a Conventional-Commits subject; **end the message with**:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- **NEVER `--no-verify`.** Stay on the branch. Don't push. Commits are pre-approved by the user for this run.

### Discipline
- **TDD per task:** write the failing test first, see it fail, implement minimally, build+test on device (green), then commit. The plan marks where to invert/add tests.
- **One task at a time; no scope creep.** Don't pull a later task's change forward.
- **Read before edit** (CONTRACTS.md first, then every file you'll modify). Don't re-Read a file right after you Edit it.
- Don't echo Android API names in code/comments. Cite `ADR-##`/`D-##` only where the "why" is non-obvious.

## Per-task implementation notes (augmenting the plan)

Line numbers are approximate — locate by content. **Verify each anchor against the current source**, since earlier tasks shift line numbers.

### Task 2 — Tracker lane → BGRA8 (fused Pass-4)
- **Shader is safe to fuse (verified):** `Shaders/TrackerDownsample.metal` declares `outTex` as `texture2d<float, access::write>` and writes a plain `float4`. An `.bgra8Unorm` output clamps [0,1] and stores BGRA8 with **no shader edit**. Re-read to confirm unchanged.
- Change the tracker pool (`MetalPipeline.swift` ~:328, currently `makeWorkingFormatPool(size: trackerSize)`) to the existing BGRA8 factory `makeBgra8LanePool(size: trackerSize)`. Use the BGRA8 dequeue helper (`dequeueEightBitPoolTexture`) for the tracker pair in `encode()` (~:414). Pass-4 (~:463-480) is unchanged.
- **Simplification:** the tracker has no 16F downstream reader, so there's no separate 16F texture to preserve. `_latestTrackerTex` and `_latestTrackerBuffer` both naturally become BGRA8 (Pass-4 writes into the BGRA8 pool's texture, which shares the IOSurface with the buffer). `currentTrackerTexture()` / `currentPixelBuffer(.tracker)` likely need **no code change** — verify they read those mailboxes.
- `trackerForSet` (~:587) now carries the BGRA8 tracker buffer. `CannyConsumer.cpp:86-89` already has the `_32BGRA → COLOR_BGRA2GRAY` path — no C++ edit (confirm by reading).
- **Tests:** invert the "tracker lane stays RGBA16F" suite (`RgbaConversionTests.swift` ~:273) to assert `_32BGRA` / `.bgra8Unorm`; assert dims from `trackerSizeForTest` (~MetalPipeline:1003), **not** a `640×480` literal. Add a channel-order + clamp value test: drive a known color through `encode(sampleBuffer:)` + `waitUntilCompleted`, lock the tracker buffer, assert `[B,G,R,A]` byte order and that out-of-range clamps to 255.

### Task 3 — Collapse texture/buffer to BGRA8 (natural + processed)
- The convert pass already produces a BGRA8 texture per lane (`naturalEightBitPair.texture` / `processedEightBitPair.texture`) but currently only the **buffer** is stored. Add BGRA8 texture mailboxes (e.g. `_latestNaturalBgra8Tex`, `_latestProcessedBgra8Tex`) and store `pair.texture` alongside the buffer in the completion handler.
- Point `currentTexture()` (~CameraEngine:754) and `currentProcessedTexture()` (~:763) at the BGRA8 texture mailboxes.
- **Keep `_latestNaturalTex` (16F)** — WB calibration reads it (`MetalPipeline.swift` ~:831 and ~:855). Consider renaming it `_latestNaturalTex16F` for clarity. **Remove `_latestProcessedTex` (16F)** — after the accessor moves to BGRA8 it has no reader (Pass-5 NV12 reads `processedTexI` within-frame, not the mailbox). Verify with `grep -rn 'latestProcessedTex'`. (`_latestTrackerTex` now holds the BGRA8 tracker texture from Task 2 — leave it.)
- **Tests:** (a) `currentTexture()`/`currentProcessedTexture()` are `.bgra8Unorm` over the same IOSurface as the matching `currentPixelBuffer`; (b) split the old `"Texture mailboxes always return .rgba16Float"` suite (~:246) into a dedicated, named test that the **calibration** natural texture is still `.rgba16Float`; (c) natural/processed channel-order + clamp value test (same technique as Task 2).

### Task 4 — FrameSet / AsyncStream / C++ pool carry BGRA8
- The `FrameSet(...)` construction (`MetalPipeline.swift` ~:632-637) currently passes the **16F** lane buffers (`naturalBuf`/`processedBuf` are the working-pool buffers; `trackerForSet` ~:587). Change it to pass the BGRA8 buffers (`naturalEightBitBuf`/`processedEightBitBuf`, and the BGRA8 tracker buffer). `trackerForSet`'s fallback must be the BGRA8 natural buffer, not the 16F one.
- **Test:** assert the `FrameSet` lane buffers delivered on `consumers.yield`/the AsyncStream are `_32BGRA` for all three streams (`Stage13Phase2Tests.swift` ~:38). `CannyConsumer` already format-branches — no C++ edit.

### Task 5 — Still capture reads BGRA8; delete the Pass-6 pipeline
- `CameraEngine.captureImage` (~:1171): read `pipeline.latestProcessedBuffer` (BGRA8) and call `StillCapture.encode` directly — mirror the existing `captureNaturalPicture` (~:1267) structure (`format: .tiff`, `laneTag: "processed"`).
- `captureNaturalPicture` (~:1267): switch its source from `latestNaturalBufferRGBA16F` to `latestNaturalBuffer` (BGRA8).
- `StillCapture.swift`: delete `captureImage(pipeline:…)` (the armCapture variant) and `convertRGBA16FtoRGBA8` (vImage). In `encode`, drop the vImage step — input is BGRA8; lock base address and build the CGImage with **BGRA byte order** in `makeCGImage` (`byteOrder32Little | CGImageAlphaInfo.noneSkipFirst`, replacing the old RGBA `noneSkipLast`). EXIF/CamPlugin/Photos paths unchanged.
- Delete: Pass-6 blit (`MetalPipeline.swift` ~:481-509), the still-capture pool (`makeStillCapturePool` + its dequeue ~:348), `armCapture`/the still continuation/the completion-handler still delivery (~:621), and `_latestNaturalBufferRGBA16F` (~:134-135) + its store (~:656). Grep to confirm no readers remain.
- **Tests:** invert the "captureNaturalPicture sources RGBA16F" suite (~:293) to BGRA8; add a `captureImage` smoke; **add a still-capture pixel round-trip** — `StillCapture.encode` a known-color BGRA8 buffer, read the file back via ImageIO, assert the color round-trips (this is the guard for the CGImage byte-order change — the riskiest edit). Keep the `bufferUnavailable` (engine-open-no-frame) assertions.

### Task 6 — Comment correction + dead-code sweep
- Rewrite every "HDR-grade precision" / "always RGBA16F (precision)" / asymmetry / "don't refactor away" comment to the true model: input is 8-bit; 16F is internal compute headroom; all delivery is BGRA8. Hot spots: `CameraEngine.swift` (~:744, :760, :793-798, :1274-1276), `MetalPipeline.swift` (some already fixed in Task 1's nits), `Capabilities.swift` (~:38-49, :113-127), `Shaders/Rgba16fToBgra8.metal`. Grep: `grep -rn 'HDR-grade\|asymmetry\|don.t refactor\|regardless of the flag\|RGBA16F' CameraKit/Sources/` and reconcile each surviving mention (leave only the legitimately-internal 16F references).
- Run swift-format/swiftlint; regen CONTRACTS.

### Task 7 — Record D-2P-12 + ledger
- Append **D-2P-12** to `CameraKit/DECISIONS.md` (one line, above the stage-header sentinel, matching existing format): 8-bit BGRA8 sole delivery; RGBA16F internal-compute-only; removed `lanesEightBit`, the texture/buffer asymmetry, the parallel 16F still mailbox, the Pass-6 still pipeline; tracker fused via Pass-4, natural/processed via standalone convert; supersedes D-2P-11, retains D-2P-09. Cite the design + plan paths.
- Update `CameraKit/state.md`.

### Task 8 — Full verification + on-device HITL
- Full suite sweep: `test_device` scheme `eva-swift-stitch`, no filter. All suites pass.
- On-device HITL (physical iPad, never sim): sustained fps at 4K with all three lanes converting (baseline from the rgba8 work: 30 fps, 0 degraded windows); native preview correct (watch the Metal drawable/blit-origin invariants in CLAUDE.md §8 — green frames = a present/blit-origin bug); tracker overlay correct; `captureImage` (TIFF) + `captureNaturalPicture` (JPEG) visually correct. If you need device logs, use the `ipad-logs` skill — not `log collect`/`pymobiledevice3`/`start_device_log_cap`.
- Record evidence in `measurements/phase-3-prep/8bit-bgra-delivery.md` (device + iOS, fps, drop windows, screenshot paths).

## Known gotchas (already hit)
- **CONTRACTS.md won't auto-regenerate** (hook bypass above) — regen + stage manually each task that touches `CameraKit/Sources/`.
- **`No such module 'Testing'` SourceKit phantom** — ignore if the device build succeeded.
- **`_latestNaturalBufferRGBA16F`** stays through Tasks 2–4; removed in Task 5.
- **Test filter** by `@Suite` struct name, not filename.
- **Two test iPads** rotate (Shreeyak's iPad Pro 11" `iPad8,9` and an iPad A16 `iPad15,7`), each with distinct xctrace vs devicectl UDIDs — if a device command fails, look up the connected one (`xcrun xctrace list devices`, `xcrun devicectl list devices`). XcodeBuildMCP session defaults store the xctrace UDID.

## Definition of done (per task & overall)
Per task: red test → implement → **device BUILD SUCCEEDED + affected suites pass** → swift-format/swiftlint clean → regen+stage CONTRACTS → commit (Conventional + Co-Authored-By). Overall: full suite green + HITL evidence recorded. After merge to `main`, the `camerakit-only` synthetic branch must regenerate (pre-push hook) so the cam2fd subtree mirror stays consistent (CLAUDE.md §10).

## Downstream note
`OpenConfiguration.lanesEightBit` was public; removing it is API-breaking, but the only external consumer (cam2fd) doesn't pass it (its Dart side reads `streamPixelFormat` only as a display string; its embedded CameraKit copy is a subtree mirror that receives these edits on sync). No deprecation shim needed. `streamPixelFormat` still reports `"BGRA8"` — the Pigeon contract is unchanged.
