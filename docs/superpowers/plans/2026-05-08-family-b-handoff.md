# Family B Implementation — Handoff for Fresh Session

This is the handoff for executing `2026-05-08-family-b-calibrate-ux-persistence.md` via the **superpowers:subagent-driven-development** skill in a fresh Claude Code session.

---

## TL;DR

- Plan file: `docs/superpowers/plans/2026-05-08-family-b-calibrate-ux-persistence.md` (13 tasks).
- Branch: `stage-01`. Base SHA at handoff: `87e6a7b3d26279867172be9b4771c214fffd56af`.
- Uncommitted at handoff: 1 modified doc + 3 new docs (no source changes).
- Workflow: subagent-driven-development — fresh subagent per task, spec-compliance review + code-quality review per task.
- Model rule: **haiku** for tasks 3–12 (simple/mechanical), **sonnet** for tasks 1, 2 (multi-file or concurrency).
- Subagent type: `general-purpose` per skill template; `swift-code-reviewer` for code-quality review.
- Task 13 is HITL — requires physical iPad. Cannot be delegated to a subagent.

---

## Read this before starting

1. `CLAUDE.md` (project instructions) — especially:
   - §6 — **no iOS simulators**; device-only via XcodeBuildMCP or `scripts/build-summary.sh` / `scripts/test-summary.sh`.
   - §6.1 — coordinator discipline (no Read-after-Edit, build log is ground truth, swift-format `--strict` hook will fail commits with multi-sentence doc-comments lacking the blank `///` line break).
   - §8 — load-bearing invariants (Metal drawable rules, MainActor / sessionQueue boundaries, `withThrowingTaskGroup` ban for non-blocking timeout, etc).
2. `docs/superpowers/plans/2026-05-08-family-b-calibrate-ux-persistence.md` — the plan being executed. Self-contained; includes file manifest, all 13 tasks with code blocks, commit messages, and HITL steps.
3. `docs/stage-11-pre-existing-bugs.md` — bug catalogue. Family B (Bugs 8, 13) is what we're fixing.
4. `docs/pre-stage-12-handoff.md` — broader bug-sweep context.

---

## Workflow

Use the **superpowers:subagent-driven-development** skill. Skill base directory:
`/Users/shrek/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/subagent-driven-development/`

Per task:

1. **Dispatch implementer** — Agent tool with:
   - `subagent_type: "general-purpose"`
   - `model:` `"haiku"` or `"sonnet"` per the table below.
   - Prompt built from `implementer-prompt.md`. Paste **full task text** from the plan; do NOT make the subagent read the plan file.
   - `description`: short summary.
2. **Handle status:**
   - `DONE` → spec compliance review.
   - `DONE_WITH_CONCERNS` → read concerns; if substantive, address; otherwise note and proceed.
   - `BLOCKED` / `NEEDS_CONTEXT` → provide context or re-dispatch with sonnet/escalate.
3. **Dispatch spec compliance review** — `subagent_type: "general-purpose"`, `model: "haiku"`. Prompt from `spec-reviewer-prompt.md`. Includes full task text + implementer's report. Reviewer reads code, verifies match.
4. **If spec issues:** re-dispatch implementer to fix; re-review; loop until ✅.
5. **Dispatch code-quality review** — `subagent_type: "swift-engineering:swift-code-reviewer"` if available, else `"general-purpose"` with `model: "sonnet"`. Prompt from `code-quality-reviewer-prompt.md`. Pass base/head SHAs.
6. **If quality issues:** re-dispatch implementer to fix; re-review; loop until approved.
7. **Mark task complete in TaskList**, move on.
8. **No check-ins between tasks.** Continuous execution per skill instructions.

After all 12 implementation tasks (1–12), task 13 is HITL — present steps 13.1–13.11 to the user; they run on iPad.

After HITL passes, dispatch a final code review for the entire branch via `superpowers:finishing-a-development-branch`.

---

## Task list with model recommendations

| # | Task | Files touched | Implementer model | Notes |
|---|------|---------------|---------|-------|
| 1 | MetalPipeline calibration sampling paths + scaling + integration tests | 2 (`MetalPipeline.swift`, `Stage11Tests.swift`) | **sonnet** | Touches Metal compute encoding, value-copy + setBytes correctness, real-Metal integration test. May need new test seams (`setLatestNaturalForTest`, `setProcessingForTest`) on `MetalPipeline`. |
| 2 | Engine surface + KVO-backed `awaitWBSettled` | 2 (`CameraEngine.swift`, `CameraSession.swift`) | **sonnet** | KVO via `NSKeyValueObservation` + `withTaskGroup` race for 2s timeout. Swift 6 strict concurrency — verify Sendable cleanly. |
| 3 | `CalibrationCompute.grayWorldGains` rewrite | 2 (`CalibrationCompute.swift`, `FrameSet.swift`) | haiku | Single function rewrite + drop `WhiteBalanceGains.init(fromGrayWorld:)`. |
| 4 | `grayWorldGains` tests | 1 (`Stage11Tests.swift`) | haiku | 6 tests; pure-Swift. |
| 5 | `SettingsPersistence` strip-on-load + tests | 2 (`SettingsPersistence.swift`, `Stage11Tests.swift`) | haiku | One-method change + 3 tests. |
| 6 | `CalibrationViewModel` — five actions | 1 (`CalibrationViewModel.swift`) | haiku | Class rewrite with new protocol. Plan provides full file body. |
| 7 | VM tests for five actions | 1 (`Stage11Tests.swift`) | haiku | Replace existing suite + stub. |
| 8 | Sidebar — five buttons | 1 (`CameraView.swift`) | haiku | SwiftUI button-row swap. |
| 9 | `ColorShaders.metal` reorder (BB → step 5) | 1 (`Shaders/ColorShaders.metal`) | haiku | Move BB block from step 1 to step 5; rewrite header comment. Build verifies Metal compiler accepts. |
| 10 | Public-API doc-comments — BB ordering | 3 files (`Capabilities.swift`, `CameraEngine.swift`, `ProcessingViewModel.swift`) | haiku | Doc-comments only. **swift-format `--strict` will fail multi-sentence comments without a blank `///` line after the first sentence.** |
| 11 | Reticle overlay | 1 (`CameraView.swift`) | haiku | SwiftUI overlay layer. |
| 12 | `state.md` decision log entry | 1 (`CameraKit/state.md`) | haiku | Markdown append. |
| 13 | HITL verification on iPad | 0 (manual) | n/a | Cannot be subagent — present to user. 11 sub-steps in plan. |

**Model selection rule applied:** simple → haiku; multi-file or concurrency-sensitive → sonnet. The user's directive in this session was: *"select haiku model for simple tasks and sonnet for the other tasks."*

---

## Task ordering

The plan numbering reflects dependency order. Don't reorder.

Critical-path dependencies:
- Task 1 (pipeline) → Task 2 (engine forwarders) → Task 6 (VM uses engine) → Task 7 (VM tests) → Task 8 (UI)
- Task 3 (math) → Task 4 (math tests) → Task 6 (VM uses math)
- Tasks 5, 9, 11, 12 are independent of the WB/BB chain
- Task 10 depends on Task 6 having landed (doc-comments reference the new method names)
- Task 13 last (HITL)

---

## Build & test commands

**Primary path (XcodeBuildMCP):**
- `mcp__XcodeBuildMCP__build_device` — defaults already configured.
- `mcp__XcodeBuildMCP__test_device` with `extraArgs: ["-only-testing:CameraKitTests/<SuiteName>"]` to run a specific suite.
- Verify defaults once per session: `mcp__XcodeBuildMCP__session_show_defaults`.

**Fallback (wrapper scripts):**
- `scripts/build-summary.sh`
- `scripts/test-summary.sh --filter CameraKitTests/<SuiteName>`

Both produce structured JSON in `.build-logs/` and tee raw logs there too.

**Never:**
- Use `xcodebuild` directly (CLAUDE.md §6).
- Use `swift build` / `swift test` (host triple is macOS, fails on iOS-only AVFoundation).
- Use simulators of any kind (CLAUDE.md §6 hard rule).
- Pipe long-running commands through `| tail -N` (CLAUDE.md §6.1, project memory).

---

## State at handoff

Working tree (the `git status --short` output):

```
 M docs/stage-11-pre-existing-bugs.md
?? docs/pre-stage-12-handoff.md
?? docs/superpowers/plans/2026-05-08-family-b-calibrate-ux-persistence.md
?? docs/superpowers/plans/2026-05-08-family-b-handoff.md  (this file)
?? docs/superpowers/plans/2026-05-08-pre-stage-12-bug-sweep.md
```

**No source changes yet.** All Family B work is ahead of the cursor.

Recommended first action of fresh session: commit the plan + handoff together as a single docs commit, then start Task 1. Suggested message:

```
docs(plan): Family B (Bugs 8, 13) calibrate UX + persistence plan + handoff
```

(The unrelated `docs/pre-stage-12-handoff.md` and `docs/superpowers/plans/2026-05-08-pre-stage-12-bug-sweep.md` were pre-existing — leave them or commit separately, your call.)

---

## Research already done (don't re-do)

Two background research agents ran during plan authoring; findings are already folded into the plan. Don't dispatch them again.

1. **WB gain math (`AVCaptureDevice` semantics):** sources `AVCaptureDevice.h` lines 1244–1434, WWDC 2014 §508. Verdict: gains amplify only (floor 1.0); Apple normalizes to min == 1.0 internally; the sample is post-WB-device-applied so the reciprocal is a *delta* — must stack onto current gains. Plan's `grayWorldGains` does exactly this.
2. **Metal-buffer color format:** sources Apple `MTLPixelFormat` reference, `AVCaptureDevice.activeColorSpace`, CoreVideo `kCVImageBufferTransferFunctionKey`. Verdict: both `naturalTex` and `processedTex` are `MTLPixelFormat.rgba16Float` (IEEE-754 binary16, no implicit transform), gamma-encoded R'G'B' inherited from Y'CbCr. `CAMetalLayer.colorspace = sRGB` asserts this to the compositor. Confirms plan's choice of sRGB EOTF in `srgbLinearize`. Skipping linearization biases gains 5–15%.

---

## Known caveats / things the implementer subagent should be told

- **Test seams in `MetalPipeline`:** Task 1 integration test calls `setLatestNaturalForTest` and `setProcessingForTest`. The first may not exist yet — `setLatestProcessedForTest` does (per CONTRACTS line ~730 area). Add the symmetric natural-side seam if missing. The processing seam may need adding too — write through the same `Mutex<UniformStorage>` path that `setProcessingParameters` uses.
- **Symbol-name verification:** Task 1 references `colorTransformPSO`, `latestNaturalTex`, `device`, `uniforms`, `commandQueue` — these are likely names but the implementer should grep the existing `MetalPipeline.swift` for the exact identifiers and adapt the snippet.
- **`LiveCaptureDevice` shape:** Task 2 adds methods to `LiveCaptureDevice`. The class/actor declaration and field name (`avDevice`) need verification; the plan code assumes that's the AVCaptureDevice handle.
- **swift-format `--strict` hook:** all multi-sentence doc-comments must have a blank `///` line after the first sentence. The hook fails the commit otherwise. Plan code already follows this; verify after edits.
- **SourceKit phantom errors:** if cross-file diagnostics complain after edits ("Cannot find type X"), trust the build log over the navigator (CLAUDE.md §6.1). `BUILD: success` ⇒ ignore SourceKit complaints from that run.
- **Two-iPad UDID scheme:** if the implementer's tests target a device, they should use XcodeBuildMCP's session default `deviceId` (xctrace UDID), not the devicectl UDID. CLAUDE.md §8 notes the dual scheme.
- **Pre-existing instrumentation:** `Bug4Probe.swift` and the DEBUG "Halt Pass 2 (bug4)" buttons should NOT be touched by Family B work. Stage 12 will revert them per `docs/pre-stage-12-handoff.md` §Cleanup pending.

---

## HITL prerequisites

For Task 13:
- Physical iPad (Shreeyak's iPad Pro 11" 2nd-gen `iPad8,9` is the primary). xctrace UDID `00008027-000539EA0184402E`; devicectl UDID `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`.
- Wi-Fi tunnel working. If wedged: USB plug + Mac/iPad reboot per `docs/pre-stage-12-handoff.md`.
- For log capture during HITL: `scripts/device-log-live.sh` (the `ipad-logs` skill).
- Test scenes ready: a neutral grey card / wall (WB calibrate); a warm tungsten lamp (second-tap re-baseline); a dark patch (BB calibrate).

---

## Final completion

After Task 13 passes HITL:

1. Dispatch a final code review for the entire branch (per skill workflow):
   - `subagent_type: "general-purpose"`, `model: "sonnet"`.
   - Reviews all commits from base SHA `87e6a7b` to HEAD against the plan.
2. Use `superpowers:finishing-a-development-branch` skill to wrap up.
3. The user closes Bugs 8 and 13 in `docs/stage-11-pre-existing-bugs.md`; closes the Family B row in `docs/pre-stage-12-handoff.md`.

That clears the pre-Stage-12 punch-list down to Bugs 11 and 14 (Families D and E in the handoff doc) — separate work, not part of this plan.

---

## What this handoff is *not*

- Not a re-derivation of the plan. The plan is self-contained at `2026-05-08-family-b-calibrate-ux-persistence.md`. Read that.
- Not a replacement for `CLAUDE.md`. Project rules still apply.
- Not a Stage 12 entry plan. Stage 12 is upstream-defined in `implementation/briefs/stage-12.md` and gated on the bug sweep clearing.
