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
6. Run §11 verification (`swift build` + `swift test` + scaffold greps + any
   `xcodebuild` pass §11 calls for), then update `state.md` per §12.
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

```bash
# Build + tests — ALWAYS through the xcodeproj for an iOS destination.
# DO NOT `swift build --package-path CameraKit/` or `swift test --package-path …`.
# SPM defaults to the host triple (macOS); CameraKit uses iOS-only AVFoundation APIs
# (videoZoomFactor, setExposureTargetBias, …), the host build fails, and that failure
# cascades into phantom SourceKit "cannot find type Size/WhiteBalanceGains" errors
# across unrelated files. If SourceKit goes sideways: `rm -rf CameraKit/.build`,
# clear DerivedData for eva-swift-stitch, rebuild via xcodeproj.
xcodebuild -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
xcodebuild -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  test -only-testing:CameraKitTests/StageNNTests

# Scaffold inventory — live slugs must ≥1 hit; retired slugs must 0.
grep -rn 'NN:slug' CameraKit/Sources/

# Package tests are tool-hosted — NEVER a device destination; always a simulator.
xcodebuild test -scheme CameraKit \
  -destination 'platform=iOS Simulator,id=<uuid>' \
  -only-testing:CameraKitTests/StageNNTests

# Authoritative destination list (simctl may lie about scheme validity):
xcodebuild -scheme eva-swift-stitch -showdestinations

# Reference destinations
-destination 'platform=iOS Simulator,name=iPad (A16)'
-destination 'platform=macOS,arch=arm64,variant=Designed for iPad'
-destination 'platform=iOS,id=<udid>'     # `xcrun xctrace list devices`

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

Prefer **XcodeBuildMCP** over raw `xcodebuild` for build/run/test/simulator/LLDB/UI
automation. Call `session_show_defaults` first each session; if project/scheme/
destination are set, go straight to `build_run_sim` or the device/Mac equivalent.
The **`xcode` MCP** is only for actions that need Xcode itself running (navigator
issues, preview rendering, the open window) — reach for it rarely. **Fastlane** is
release only (`match` → `gym` → `pilot`). If the user names a specific MCP and it
is unavailable, stop and say so — never silently substitute.

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
exercises real capture); **iPad simulator** (no camera — skip for capture paths).
Per-stage HITL / DEFERRED evidence lands under `measurements/stage-NN/`; each
brief's §12 names the exact file paths.

### 6.0 One-time host setup

Each development machine needs this once:

```bash
brew install xcode-build-server fswatch swift-format ripgrep repomix
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
- **First-pass orientation goes through `CameraKit/CONTRACTS.md`.** Every
  subagent's opening instruction should be "Read `CameraKit/CONTRACTS.md`
  first." That file is regenerated by `scripts/regen-contracts.sh` and is the
  canonical current-shape document.
- **Use the toolchain decision tree** (§6.2) for every code-shape query.
  Grep is for literal patterns; LSP is for semantic queries.
- **Never `Read` after `Edit` / `Write`.** The validator already confirmed
  the change; re-reading burns context. Trust the tool.
- **Build output always grep-filtered.** Run `scripts/build-summary.sh`
  instead of raw `xcodebuild`; the wrapper returns `BUILD`, `Swift errors`,
  `Metal errors`, `Warnings` and only expands full output on `--verbose`.
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
| Build & verify iOS target | `scripts/build-summary.sh` | Not raw `xcodebuild`. |
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
