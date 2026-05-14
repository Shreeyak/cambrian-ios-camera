# CLAUDE.md

This file orients a fresh Claude Code session working in this repo.

## 1. What this repo is

Swift iOS 26 implementation target for the CameraKit library defined in
`implementation/briefs/`. It **consumes** the upstream brief/architecture corpus
(symlinked from `/Users/shrek/work/cambrian/ios-translation/`) and **produces**
Swift source under `CameraKit/Sources/CameraKit/`, swift-testing unit tests under
`CameraKit/Tests/CameraKitTests/`, and a running `CameraKit/state.md` that records
what scaffolding is live, what is permanent, and what public API has shipped.

This repo is Stage 6 (IMPLEMENT) of an upstream clean-room pipeline; producer
discipline does not apply here. See `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md`
for producer context if needed.

## 2. Repo layout

```
.
├── eva-swift-stitch.xcodeproj        # app host; owns Info.plist, signing, schemes
├── eva-swift-stitch/                 # app target files
│   ├── eva_swift_stitchApp.swift     # app entry point; hosts CameraKit's root view
│   ├── Info.plist                    # (NSCameraUsageDescription via build setting, see §5)
│   └── Assets.xcassets + Preview Content/
├── eva-swift-stitchTests/            # existing XCTest — app-level; library tests live under CameraKit/
├── eva-swift-stitchUITests/          # existing XCUITest
├── CameraKit/                        # local Swift package (library-only)
│   ├── Package.swift                 # swift-tools-version:6.2; iOS 26; strict concurrency
│   ├── Sources/CameraKit/            # library source
│   ├── Tests/CameraKitTests/         # swift-testing suites, one per stage
│   ├── CONTRACTS.md                  # auto-regenerated current shape (§6.2)
│   ├── DECISIONS.md                  # append-only subagent decision log
│   └── state.md                      # per-stage progress ledger — read for current state
├── implementation/                   # READ-ONLY upstream symlinks
│   ├── briefs/             → …/ios-translation/implementation/briefs
│   ├── architecture/       → …/ios-translation/implementation/architecture
│   ├── domain-revised/     → …/ios-translation/domain-revised
│   └── ios-platform-guide/ → …/ios-translation/ios-platform-guide
├── fastlane/                         # release pipeline (match → gym → pilot); preserve as-is
├── Gemfile / Gemfile.lock            # fastlane toolchain pinning
├── .swiftlint.yml
└── docs/                             # progress-report.md + superpowers/
```

For current stage, live scaffolds, and what's shipped, read `CameraKit/state.md` —
that file is the source of truth for project state; CLAUDE.md only documents
structure and rules.

## 3. Pipeline role and stage discipline

Each brief at `implementation/briefs/stage-NN.md` is the authoritative spec for
its stage. Per-stage workflow:

1. Read `CameraKit/state.md` from the prior stage.
2. **Pre-flight inventory**: for every entry under "Scaffolding still live",
   `grep -rn <slug> CameraKit/Sources/` must return ≥1 hit. Mismatch halts the
   session and requires escalation — source drift is not quietly patched.
3. Read `implementation/briefs/stage-NN.md`.
4. Read cited architecture refs (§5), domain refs (§6), and the
   `implementation/architecture/api-skeletons/Sources/CameraKit/` stubs for
   every file named in §4.
5. Implement per §4 in dependency order.
6. Run §11 verification using the method prescribed in §6 (XcodeBuildMCP or
   wrapper scripts — never raw `swift build` / `swift test`): build, test filter,
   scaffold greps, and any device smoke the brief's §11 calls for. Then update
   `state.md` per §12.
7. Stop. Request user approval before any git operation.

**FEATURE** stages add user-visible capability and may introduce scaffolds;
**MIGRATION** stages retire ≥1 scaffold with a production primitive, preserve
every prior test, and add no user-visible capability.

**Stage kickoff rule:** the first action of any new stage is
`scripts/stage-preflight.sh`. It validates state.md ↔ source slug coherence,
freshness of `CameraKit/CONTRACTS.md`, and that the build passes. Don't start
editing sources until it exits 0.

## 4. Scaffold-slug convention

Scaffolds are marked inline by an exact-string code comment `// scaffolding:NN:kebab-slug`,
where `NN` is the stage that introduced them. That comment is the grep target for
the next stage's pre-flight check. Do not paraphrase the slug, do not re-punctuate
it, do not split it across lines. A scaffold may only be retired by the stage
whose §1 `Retires scaffolding from: …` entry names it — early retirement breaks
the stage-index ordering and invalidates `state.md` as proof of progress.

## 5. Target shape

- Package lives in a subdirectory (`CameraKit/`), not at the repo root.
- `eva-swift-stitch.xcodeproj` remains the app host: owns `Info.plist`, signing,
  schemes, and `NSCameraUsageDescription` (via `INFOPLIST_KEY_NSCameraUsageDescription`
  build setting, not a Plist key). `NSPhotoLibraryAddUsageDescription` lands at
  Stage 07 the same way. `CameraKit` is linked as a local SwiftPM dependency; the
  app target imports it and presents `CameraView()`. Bundle ID:
  `com.cambrian.eva-swift-stitch`; iPad only.
- iOS 26 deployment target; Swift 6 language mode; `SWIFT_STRICT_CONCURRENCY =
  complete` is enforced at build time — treat concurrency warnings as errors.
- **`CameraKitCxx` (C++ target) + OpenCV xcframework arrive at Stage 08.** Do not
  scaffold either earlier — stages 01–07 carry pure-Swift fallbacks deliberately.

## 6. Common operations

> **Hard rule: never use iOS simulators on this machine.** The developer
> macbook does not have the memory to run them. Destination order for every
> build, run, and test: **(1) physical iPad; (2) Mac "Designed for iPad"**
> (native — not a simulator); **(3) error out, never fall through to a
> simulator**. This applies to Bash, XcodeBuildMCP (`*_device` variants only,
> never `*_sim`), and any documentation/examples. If a brief or subagent
> asks for a simulator, flag it back — do not comply silently.

**Builds and tests go through XcodeBuildMCP.** Use `mcp__XcodeBuildMCP__build_run_device`,
`..._test_device`, or the Mac-equivalent — **never** the `*_sim` variants. They
return structured JSON directly in-context: no log to tail, no pipe to drain,
no timeout to manage. Call `session_show_defaults` once per session; if
project/scheme/destination are set, subsequent calls can run with empty args.

Fallback — **only** when XcodeBuildMCP is unavailable (MCP not connected,
per-session permission prompt declined) — use the shell wrappers:

```bash
scripts/build-summary.sh                                   # iOS build
scripts/test-summary.sh                                    # CameraKit tests (default)
scripts/test-summary.sh --filter CameraKitTests/Stage01Tests
scripts/test-summary.sh --scheme eva-swift-stitch          # app-level tests
```

Both wrappers pipe `xcodebuild` through `xcsift` (structured JSON output in
`.build-logs/<ts>-*.json`), tee the raw log to `.build-logs/<ts>-*.log`, and
enforce the device-only destination order: physical iPad → Mac "Designed for
iPad" → error. The JSON file is the first thing to read on failure — it has
file/line/message per error, not a grep approximation.

**Never invoke `xcodebuild build` or `xcodebuild test` directly** in a Bash tool
call. `swift build --package-path CameraKit/` and `swift test --package-path …`
are also forbidden: SPM defaults to the host triple (macOS); CameraKit uses
iOS-only AVFoundation APIs, the host build fails, and the failure cascades into
phantom SourceKit "cannot find type Size/WhiteBalanceGains" errors across
unrelated files. If SourceKit goes sideways: `rm -rf CameraKit/.build`, clear
DerivedData for eva-swift-stitch, rebuild via the MCP or wrapper.

Other operations:

```bash
# Scaffold inventory — live slugs must ≥1 hit; retired slugs must 0.
grep -rn 'NN:slug' CameraKit/Sources/

# Destination introspection (when you need to see what xcodebuild considers valid):
xcodebuild -scheme eva-swift-stitch -showdestinations

# Destination string formats (for --destination on wrappers) — DEVICE ONLY:
#   platform=iOS,id=<udid>                                   (physical iPad; from `xcrun xctrace list devices`)
#   platform=macOS,arch=arm64,variant=Designed for iPad      (native Mac fallback)
# NEVER `platform=iOS Simulator,...` — simulators are disallowed on this machine.

swiftlint lint       --config .swiftlint.yml
swiftlint lint --fix --config .swiftlint.yml
```

For programmatic xcodeproj edits (package dependencies, build-setting flips,
orientation locks, untracking user-state), use the system-installed Ruby
`xcodeproj` gem — **never** hand-edit `project.pbxproj`:

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('eva-swift-stitch.xcodeproj')
# ...mutations...
p.save"
```

**MCP ecosystem** — XcodeBuildMCP owns build/run/test/LLDB/UI on device
targets (see above; simulators are disallowed on this machine). The **`xcode` MCP** is only for actions that need Xcode itself running
(navigator issues, preview rendering, the open window) — reach for it rarely.
**Fastlane** is release only (`match` → `gym` → `pilot`). If the user names a
specific MCP and it is unavailable, stop and say so — never silently substitute.

**Apple API reference** — primary is **`mcp__xcode__DocumentationSearch`**:
semantic matching over discussion prose, `frameworks` filter, content returned
inline in one call. If the call fails or the xcode MCP is not connected (the
per-session permission prompt wasn't accepted yet), **tell the user immediately**
before falling back. Fallback is **`dash-api`** (local, offline): docset name
`"Apple API Reference - Swift"`, identifier `tkaubcqb-swift`. Call
`mcp__dash-api__search_documentation` with `docset_identifiers="tkaubcqb-swift"`,
then `mcp__dash-api__load_documentation_page` on the returned `load_url`. FTS is
*not supported* on this docset (`enable_docset_fts` is a no-op), so dash-api
matches titles and symbol declarations only — good enough for signature lookups
when xcode is offline. `context7` covers third-party libraries; xcode
(+ dash-api fallback) covers the Apple SDK.

Run targets, preferred order: **physical iPad** (required for R-21 camera-indicator
and R-22 off-main `startRunning`); **Mac "Designed for iPad"** (day-to-day —
exercises real capture). **Simulators are not an option on this machine** (see
top of §6). Per-stage HITL / DEFERRED evidence lands under `measurements/stage-NN/`;
each brief's §12 names the exact file paths.

### 6.0 One-time host setup

Each development machine needs this once:

```bash
brew install xcode-build-server fswatch swift-format ripgrep repomix xcsift jq
xcode-build-server config -project eva-swift-stitch.xcodeproj \
                          -scheme eva-swift-stitch
```

The second command generates `buildServer.json` at the repo root, bridging
sourcekit-lsp to Xcode's build system. It is gitignored (contains a
machine-specific DerivedData path); re-run after cloning or changing scheme.

### 6.1 Coordinator discipline

When orchestrating subagents, follow these rules. They exist because
coordinator-inlined source and re-reads after edits dominate token burn.

- **Never inline source code in a subagent prompt.** Give file:line pointers
  and let the subagent do its own reads. `Read "CameraEngine.swift:34–100"` is
  a brief; pasting the file contents is not.
- **Read every file listed under "Modify" in the current plan before writing
  any of them.** `CameraKit/CONTRACTS.md` is always first — it is the
  canonical current-shape document, regenerated by `scripts/regen-contracts.sh`.
  Discovering a type shape mismatch (e.g. an associated-value case) after
  writing against it is a read-skip failure. No write before full read.
- **Explore agents use haiku.** When dispatching an `Explore` subagent (codebase
  search, file-pattern discovery, keyword grep, "how is X wired up?" questions),
  pass `model: "haiku"`. Explore tasks are I/O-heavy and don't need opus/sonnet
  reasoning depth — haiku is materially faster and cheaper, and protects the
  coordinator's context from being flooded with Explore's raw search output.
  Reserve sonnet/opus for implementation, review, and reasoning-heavy subagents.
- **Use the toolchain decision tree** (§6.2) for every code-shape query.
  Grep is for literal patterns; LSP is for semantic queries.
- **Never `Read` after `Edit` / `Write`.** The validator already confirmed
  the change; re-reading burns context. Trust the tool.
- **Builds/tests via XcodeBuildMCP; wrappers only when MCP unavailable.**
  `mcp__XcodeBuildMCP__build_run_device` and `..._test_device` return
  structured JSON in-context — no log to tail. **Never** `*_sim` variants
  (top of §6). Fallback wrappers `scripts/build-summary.sh` /
  `scripts/test-summary.sh` pipe xcodebuild through xcsift and persist both
  the raw log and a structured JSON summary under `.build-logs/`. Never
  invoke `xcodebuild build` or `xcodebuild test` directly.
- **Never pipe any long-running command through `| tail -N` inline.** Applies
  to xcodebuild, the summary wrappers, every streaming build/test tool. The
  log is lost, progress can't be monitored, and errors past the tail window
  vanish — you sit staring at a spinner with no idea what's going on. Rule:
  redirect to a file and read the file. `scripts/build-summary.sh` and
  `scripts/test-summary.sh` already persist to `.build-logs/*.log` so you
  can `tail -f` live and grep the file for context on failure. For ad-hoc
  commands, `cmd > /tmp/out.log 2>&1` then `Read`/grep the log.
- **Destination resolution: physical iPad, then Mac "Designed for iPad", then
  error.** Both wrappers try a connected physical iPad first; if none,
  Mac "Designed for iPad" (native, not a simulator); if neither, they exit
  with an error. **Simulators are never used** (top of §6).
  `test-summary.sh` defaults to scheme `eva-swift-stitch`. CameraKitTests
  files compile into the app-hosted `eva-swift-stitchTests` target via
  dual-membership (§8). Filter as `-only-testing:eva-swift-stitchTests/<SuiteStructName>`
  — note that each `@Suite` in those files is its own struct, so the
  filename does NOT work as a filter prefix.
- **Build log is ground truth; navigator issues are advisory.** Xcode's Issue
  Navigator (`mcp__xcode__XcodeListNavigatorIssues` and the `(SourceKit)`-tagged
  list returned by `BuildProject` / `build_run_*`) reads from a cache that lags
  behind the compiler — especially after adding files, changing targets, or
  editing across module boundaries. Symptoms: "Cannot find type
  `UIViewRepresentable`/`ScenePhase`/`Context`" when SDK imports are obviously
  fine. Rule: check the build log (`scripts/build-summary.sh` exit code, or the
  `BUILD SUCCEEDED` / `BUILD FAILED` line in MCP build output) *first*. If the
  build succeeded, discard every `(SourceKit)`-tagged issue from that run. If
  it failed, trust compiler errors from the log text and cross-reference before
  quoting a navigator entry. Never base a decision on navigator issues alone.
  Persistent phantoms across rebuilds → nuke
  `~/Library/Developer/Xcode/DerivedData/eva-swift-stitch-*` and rebuild.
- **Bound agent return format** per §6.3 below.

### 6.2 Tools: decision tree and usage

Pick the tool that fits the question. Match row by row, top-down:

| Question | Tool | How |
|----------|------|-----|
| What's the current public API + internal shape? | `CameraKit/CONTRACTS.md` | Read it. Every subagent's first read. |
| What's the compiler-validated public contract? Is X `nonisolated`? Does Y conform to `Sendable`? | `.swiftinterface` | `scripts/dump-interface.sh` → `/tmp/CameraKit.swiftinterface` |
| What symbols does file F define? | `LSP documentSymbol` | `LSP` MCP tool (preferred) or `scripts/lsp-symbol.sh outline F` |
| Where is symbol X declared? | `LSP workspaceSymbol` | `LSP` MCP tool or `scripts/lsp-symbol.sh workspace X` |
| Who calls function X? | `LSP prepareCallHierarchy` + `incomingCalls` | `LSP` MCP tool |
| What's the type/doc of symbol at file:line? | `LSP hover` | `LSP` MCP tool |
| Find literal pattern (scaffold slug, TODO, string occurrence) | `Grep` | Claude `Grep` tool or `rg` |
| List active scaffolds as a table | `scripts/scaffold-inventory.sh` | — |
| Build iOS target | `mcp__XcodeBuildMCP__build_run_device` (primary) or `scripts/build-summary.sh` (fallback) | Device-only on this machine (no sims). Wrapper pipes xcodebuild→xcsift→`.build-logs/*.json` + raw log. |
| Run CameraKit or app tests | `mcp__XcodeBuildMCP__test_device` (primary) or `scripts/test-summary.sh` (fallback) | Device-only (no sims). Both default to scheme `eva-swift-stitch` (app-hosted CameraKitTests via dual-membership — see §8). Filter as `eva-swift-stitchTests/<SuiteStructName>`. |
| Re-wire CameraKitTests after adding a new test file | `scripts/sync-test-target.sh` | Idempotent. Adds new `.swift` files under `CameraKit/Tests/CameraKitTests/` to the Xcode test target. See §8. |
| Stage kickoff coherence checks | `scripts/stage-preflight.sh` | Run as first action of a new stage. |
| Refresh CONTRACTS.md explicitly | `scripts/regen-contracts.sh` | Auto-runs on pre-commit; rarely needed by hand. |
| Log a subagent decision | Append one line to `CameraKit/DECISIONS.md` | Stigmergy; coordinator won't re-read. |

#### `CONTRACTS.md` vs `.swiftinterface` — when to use each

**Default to `CONTRACTS.md`.** It's always fresh (pre-commit regen),
shows internal wiring, and is the natural first read.

**Reach for `.swiftinterface` when any of these apply:**
- You need to answer: "is this `@MainActor`?", "is this `nonisolated`?"
- You need to confirm a Sendable conformance (including compiler-synthesized).
- You need exact `@available` annotations.
- You're reasoning about actor boundaries or concurrency semantics.
- You need the synthesized `==`/`hash(into:)` signatures of a Hashable struct.
- You're drafting API-contract tests and need precise public shape.

Run `scripts/dump-interface.sh` to produce `/tmp/CameraKit.swiftinterface`.
It works even when source has SwiftPM-specific errors (Bundle.module) —
the interface is emitted from compiler-deduced structure, not source text.

#### LSP usage

Prefer the `LSP` MCP tool for in-session semantic queries — it auto-configures
through `buildServer.json`. The shell wrapper `scripts/lsp-symbol.sh` is a
fallback for scripted/batch use; it crashes sourcekit-lsp (`Illegal
instruction: 4`) on actor-heavy files like `CameraEngine.swift` because
standalone LSP can't resolve `Bundle.module` or platform-framework imports.
Use the wrapper for leaf files (value types, enums, constants); use the MCP
tool for everything else.

**SourceKit cross-file false positives are common and usually meaningless.**
If inline diagnostics say "Cannot find type X in scope" but `scripts/build-summary.sh`
reports `BUILD: success`, trust the build. SourceKit resolution lag across modules
produces phantom errors after edits; they clear on rebuild. Don't chase them.

### 6.3 Subagent return schema

Every subagent dispatch prompt must end with this return schema.

```xml
<status>DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT | DEFERRED</status>
<files>
- path/to/file.swift
</files>
<assumptions>
- Chose X over Y because Z  (≤3 items, 1 line each)
</assumptions>
<flags>
- Surface-to-upstream items  (≤3 items, 1 line each)
</flags>
<blocker>
  (only if BLOCKED) exact file:line and error text
</blocker>
<question>
  (only if NEEDS_CONTEXT) the single question to resolve
</question>
```

Rules:
- Empty fields omit the tag.
- No prose outside the tagged fields — untagged text is ignored.
- Long-form decisions go to `CameraKit/DECISIONS.md` (append-only), not return text.

## 7. Commit discipline

You produce files. You do **not** run git operations (commit, push, branch, tag,
amend, force-push) without explicit user approval. Hooks are never skipped
(`--no-verify`); signing is never bypassed. If a pre-commit hook fails, fix the
underlying issue and ask again — do not `--amend` around it.

## 8. Load-bearing invariants

- **Tests use a host app, not tool-hosted; CameraKitTests is dual-membered.**
  iOS forbids tool-hosted tests on physical-device destinations (`xcodebuild
  test` errors with `Tool-hosted testing is unavailable on device
  destinations`), and simulators are disallowed on this machine (§6). So
  every `.swift` file in `CameraKit/Tests/CameraKitTests/` is compiled by
  TWO targets: the SwiftPM `.testTarget(name: "CameraKitTests")` in
  `CameraKit/Package.swift` (the package's portability contract for future
  extraction — keep untouched), AND the Xcode `eva-swift-stitchTests` target
  in `eva-swift-stitch.xcodeproj` (`TEST_HOST=eva-swift-stitch.app`, the
  one that actually runs on the iPad). Canonical run command:
  `mcp__XcodeBuildMCP__test_device` with scheme `eva-swift-stitch`, or
  `scripts/test-summary.sh --filter eva-swift-stitchTests/<SuiteStructName>`
  (no scheme flag needed; default is `eva-swift-stitch`). To add a new test
  file in a future stage, create it in `CameraKit/Tests/CameraKitTests/`
  then run `scripts/sync-test-target.sh` (idempotent). Decision #63 in
  `CameraKit/state.md` records the rationale. Filter caveat: each `@Suite`
  is its own struct — `-only-testing:eva-swift-stitchTests/Stage10Tests`
  (filename) matches NOTHING; use the actual struct name from the file
  (`Stage10CoordinatorTests`, `Stage10HappyPathTests`, etc.).
- **The current brief is the source of truth for its stage.** If `architecture/`
  or `ios-platform-guide/` appears to contradict the brief, the brief wins; log
  the conflict in `CameraKit/state.md` under "Decisions taken that weren't in
  briefs" so upstream can patch it.
- **Never edit anything under `implementation/`.** `briefs/`, `architecture/`,
  `domain-revised/`, and `ios-platform-guide/` are upstream artifacts. Gaps go in
  `state.md` under "Open questions for next stage" and get patched upstream.
- **Never install a future-stage primitive early.** No completion-handler D-10
  guard before Stage 09; no C++ `PixelSink` pool before Stage 08; no
  `OSAllocatedUnfairLock` uniform guard before Stage 05. Each stage is deliberate
  about what it does *not* do — pulling primitives forward breaks the chain.
- **Never retire a scaffold out of order.** The chain is locked by each brief's
  §1 `Retires scaffolding from: …`.
- **Never echo Android API names** (`Camera2`, `CameraCaptureSession`,
  `HandlerThread`, `ImageReader`, `SurfaceTexture`, `EGLContext`, `MediaRecorder`,
  `AHardwareBuffer`) in Swift source, tests, or comments — that is the classic
  tell that the clean-room separation leaked.
- **Cite `ADR-##` / `D-##` / `G-##` in code comments when the "why" is
  non-obvious.** Name the anchor; do not paraphrase the platform guide.
- **`AVCaptureSession` mutations and `AVCaptureDevice.lockForConfiguration()` run
  on `sessionQueue` (ADR-07); the `AVCaptureVideoDataOutput` sample-buffer delegate
  is `nonisolated` on the `delivery` queue (ADR-02).** Actors coordinate with
  these queues; they do not replace them. Violating this wedges the session from
  a MainActor caller or races `lockForConfiguration()` against itself.
- **`withThrowingTaskGroup` blocks on group teardown — do not use for
  non-blocking timeout.** A child task blocked on an unresumed
  `withCheckedContinuation` cannot respond to cancellation and holds the group
  open indefinitely — the group's closure does not return until every child task
  finishes, and a stuck continuation prevents that.
  For ADR-30 async-with-timeout, use a `ManagedAtomic<Bool>` CAS race with
  `withCheckedContinuation` + a `Task { try? await Task.sleep(...) }` deadline
  branch. The CAS ensures exactly-once resume without waiting for the losing
  branch. Confirmed on device: `withThrowingTaskGroup` took 5 s when the work
  hung; `ManagedAtomic` approach returned in 150 ms. See `AsyncWithTimeout.swift`.
- **swift-format hook uses `--strict`; warnings fail the commit.** The
  pre-commit hook runs `swift-format lint --strict`. Any diagnostic — including
  `BeginDocumentationCommentWithOneLineSummary` — is a commit blocker. Fix:
  add a blank `///` line after the first sentence of every multi-sentence doc
  comment, or convert internal-only property comments from `///` to `//`.
  `swift-format -i` fixes most rules automatically but NOT
  `BeginDocumentationCommentWithOneLineSummary` — that one requires manual
  splitting.
- **XcodeBuildMCP: set the session default scheme before calling `test_device`
  or `build_device`.** These tools prepend `-scheme <default>` automatically.
  Passing `-scheme` via `extraArgs` produces "option may only be provided once".
  Always call `session_set_defaults { scheme: "..." }` first; never override
  scheme through `extraArgs`.
- **xcodeproj gem: SPM package products use `product_ref`, not `fileRef`.**
  `frameworks_build_phase.add_file_reference(dep)` raises a type-checking error
  for `XCSwiftPackageProductDependency`. Correct pattern:
  `bf = p.new(Xcodeproj::Project::Object::PBXBuildFile); bf.product_ref = dep;
  target.frameworks_build_phase.files << bf`.
- **Creating `xcshareddata/xcschemes/` stops Xcode auto-generating schemes.**
  Once that directory exists every scheme must be an explicit `.xcscheme` file.
  The shared app scheme lives at
  `eva-swift-stitch.xcodeproj/xcshareddata/xcschemes/eva-swift-stitch.xcscheme`.
- **Two test iPads, two UDID schemes — always look up which is connected.**
  This project rotates between two physical iPads (Shreeyak's iPad Pro 11"
  2nd-gen, iPad8,9; and an iPad A16, iPad15,7). Each device has *two distinct
  identifiers* that different tools use:
  - **xctrace / xcodebuild / XcodeBuildMCP destination** — hardware ECID UDID,
    e.g. `00008027-000539EA0184402E`. Use for `-destination "platform=iOS,id=<udid>"`,
    XcodeBuildMCP `session_set_defaults deviceId`, build/test commands.
  - **devicectl CoreDevice UDID** — different scheme, e.g.
    `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`. Use for `xcrun devicectl device copy
    from --device <id>`, devicectl manage / process commands.

  Verify before any device command — the wrong UDID silently targets the wrong
  device or fails with "device not found":
  ```bash
  xcrun xctrace list devices       # build/test UDID column
  xcrun devicectl list devices     # devicectl Identifier column + connected/unavailable state
  ```
  XcodeBuildMCP session defaults already store the xctrace UDID under
  `deviceId`; check with `mcp__XcodeBuildMCP__session_show_defaults` first.
- **Device log capture (`start_device_log_cap`) fails on these iPads**
  ("No provider was found") over both network and USB. For no-crash evidence,
  pull system crash logs instead (substitute the *devicectl* UDID for the
  currently-connected device — see two-iPad note above):
  ```bash
  xcrun devicectl device copy from --device <devicectl-udid> \
    --domain-type systemCrashLogs --source "/" --destination /tmp/crash/
  ```
  Absence of the app bundle name in results confirms no process termination.
- **Reading app logs from device — use `scripts/device-log-live.sh` (the `ipad-logs`
  skill).** iOS 26.4 broke local WiFi device connectivity for every classic logging
  path: `log collect --device-udid` fails with "Device not configured (6)" (iOS 17+
  removed the lockdown pairing record it needs); `log stream` has no `--device` flag;
  `--console` on `devicectl process launch` is USB-only, kills the app over WiFi, and
  only captures stdout/stderr (not `Logger`); `pymobiledevice3` is broken on iOS 26
  (hardcoded RSD port + RSD v24 incompatibility); libimobiledevice is dead since
  iOS 17. The supported path is the file sink: `CameraKitLog.enableFileLogging()`
  (called from `eva_swift_stitchApp.init()`) writes to `<Documents>/camerakit.log`;
  `scripts/device-log-live.sh` polls the device every 4s via `xcrun devicectl device
  copy from` and mirrors to `${TMPDIR}/camerakit-live.log`. Whenever the user asks for
  device logs (any phrasing — "get logs", "tail logs", "what does the device say",
  "log X on device"), invoke the `ipad-logs` skill — never reach for `log collect`,
  `pymobiledevice3`, `idevicesyslog`, or `start_device_log_cap`. Logger calls must
  use `.notice` (or higher) and `privacy: .public` on interpolations to be visible.
  The script's hardcoded devicectl UDID points to Shreeyak's iPad — when running on
  the second iPad (iPad A16), update the script's `IPAD_UDID` constant to that
  device's *devicectl* UDID first.
  The log file is **append-only across launches** (`seekToEndOfFile()` on open);
  every launch emits one `=== CameraKit session started <ISO date> ===` marker.
  When debugging "what just happened", slice to the latest session first:
  `LN=$(grep -n 'session started' camerakit.log | tail -1 | cut -d: -f1); tail -n "+$LN" camerakit.log`.
  Full recipes in the `ipad-logs` skill ("Session boundaries" section).
- **Metal drawable: acquire → clear → conditional work → always present.**
  Never return between `view.currentDrawable` and `commandBuffer.present(drawable)`.
  Bailing out after acquiring a drawable without presenting it leaves the CAMetalLayer
  showing uninitialized GPU memory (green artifacts). Guard only on drawable +
  commandBuffer; the clear runs unconditionally; the blit and any other work are
  conditional inside the present path.
- **`MTLBlitCommandEncoder` — do not use non-zero origins on IOSurface-backed
  textures without validation.** `naturalTex` and `processedTex` are
  CVPixelBuffer/IOSurface-backed. Non-zero `sourceOrigin` or `destinationOrigin`
  in a blit silently breaks rendering (both previews go green, no crash, no error
  without the Metal validation layer enabled). Keep blit origins at `(0,0,0)` until
  verified with the Metal validation layer enabled on device.
- **Bottom bar over full-screen content: use `.safeAreaInset(edge: .bottom)` on
  the root container.** This is the idiomatic SwiftUI pattern for a persistent
  bottom overlay (toolbar, control bar) over full-screen camera/Metal views. It
  anchors the bar explicitly at the safe area edge regardless of how the ZStack's
  children are sized or layered.

## 9. Background reading (only when needed)

**In-repo (always resolvable):**

- `CameraKit/CONTRACTS.md` — current API surface + active scaffolds; every
  subagent's first read. Auto-regenerated; do not edit.
- `CameraKit/DECISIONS.md` — append-only stigmergy log for subagent decisions.
- `CameraKit/state.md` — per-stage history, what's built permanently,
  deferred HITL evidence.

**Upstream (symlinked, read-only):**

- `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` — upstream producer
  pipeline and clean-room discipline.
- `implementation/briefs/README.md` — read-path, kickoff template, glossary
  (scaffold / TESTABLE / FLAGGED / HITL / DEFERRED).
- `implementation/architecture/README.md` — concern-file map + cross-file matrix.
- `implementation/ios-platform-guide/README.md` — `ADR-##` / `G-##` registry.
- `implementation/briefs/stage-NN.md` — spec for the current stage.
