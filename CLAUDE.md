# CLAUDE.md

This file orients a fresh Claude Code session working in this repo.

## 1. What this repo is

Home of **CameraKit** (a Swift package for iOS camera access) and
**`cambrian_ios_camera`** (a Flutter plugin wrapping CameraKit for use from
Flutter apps). Two examples live alongside: `ios_example_app/` (native SwiftUI
dev harness) and `flutter/example/` (Flutter — populated in Phase B).

CameraKit was produced via a clean-room translation from cam2fd's Android camera
implementation; the upstream brief/architecture corpus is symlinked from
`/Users/shrek/work/cambrian/ios-translation/` and consumed read-only here.
Stages 01–12 of that translation completed on 2026-05-15 (Stage 12 was the
last clean-room translation stage). Subsequent work (Phase 1A/1B/2 and the
2026-05-20 Flutter-monorepo restructure) is post-pipeline and does not follow
the stage-briefs pattern.

Producer discipline does not apply here. See
`/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` for upstream context.

## 2. Repo layout

```
cambrian-ios-camera/  (repo root; GitHub: github.com/Shreeyak/cambrian-ios-camera)
│
├── Package.swift                          # CameraKit SPM manifest at root
│                                            (uses path: pointing into CameraKit/Sources/X)
├── CameraKit/                              # library source (NOT a nested package)
│   ├── Sources/{CameraKit,CameraKitInterop,CameraKitCxx}/
│   ├── Tests/CameraKitTests/               # swift-testing suites; built by the
│   │                                         Xcode ios_example_appTests target only
│   ├── Tests/SPMTestStub/                  # #error stub directing `swift test` to Xcode
│   ├── CONTRACTS.md                        # auto-regenerated current shape (§6.2)
│   ├── DECISIONS.md                        # append-only subagent decision log
│   └── state.md                            # per-stage progress ledger
│
├── ios_example_app/                        # native dev harness + only Xcode project
│   ├── ios_example_app.xcodeproj           # owns Info.plist, signing, schemes
│   ├── ios_example_app/                    # app sources (incl. AppCxx/ Canny consumer)
│   │   ├── ios_example_appApp.swift        # app entry point; hosts CameraKit's root view
│   │   ├── Info.plist                      # NSCameraUsageDescription via build setting (§5)
│   │   └── Assets.xcassets + Preview Content/
│   ├── Tests/                              # XCTest target Info.plist;
│   │                                         sources come from CameraKit/Tests/
│   └── UITests/                            # XCUITest
│
├── flutter/                                # Phase B will populate (§10)
│   └── README.md                           # placeholder
│
├── Frameworks/opencv2.xcframework          # symlink to ~/software/opencv2.xcframework;
│                                             consumed only by ios_example_app
│
├── Documentation/                          # CONSUMER docs (Swift/CameraKit) — the only docs a
│                                             package consumer reads: index.md + guides/ + a
│                                             generated reference/ (symbol-graph.json + clusters).
│                                             Authored in CameraKit/Sources/CameraKit/CameraKit.docc;
│                                             regenerate via scripts/regen-docs.sh. NOT docs/ below.
│
├── docs/                                   # DEV-internal working docs (NOT consumer-facing):
│   ├── reference/                          # in-repo, version-controlled reference docs
│   │   └── ios-platform-guide/             # ADR/G registry + 9 chapters; what the
│   │                                         ADR-## / G-## citations in the Swift sources resolve to
│   └── archived/                           # historical, not relevant to current code:
│       ├── superpowers/{specs,plans}/      #   stage/phase plans + design specs (incl. nested archive/)
│       └── measurements/                   #   per-stage HITL + spike evidence
│
├── scripts/                                # build wrappers, contract regen, etc.
├── .swiftlint.yml
├── README.md                               # two-personality repo intro
└── CLAUDE.md
```

For current stage, live scaffolds, and what's shipped, read `CameraKit/state.md` —
that file is the source of truth for project state; CLAUDE.md only documents
structure and rules.

## 3. Pipeline role and stage discipline

> **Historical — the clean-room stage pipeline is complete (Stage 12 was the
> last; see below).** The `briefs`, `architecture`, and `domain-revised` corpora
> were removed from this repo on 2026-05-30; they remain read-only in the
> upstream `ios-translation` repo at
> `/Users/shrek/work/cambrian/ios-translation/implementation/` (and
> `…/ios-translation/domain-revised/`). No new stage runs here. The workflow
> below is kept as a record of how stages were executed.

Each brief at `…/ios-translation/implementation/briefs/stage-NN.md` was the
authoritative spec for its stage. Per-stage workflow:

1. Read `CameraKit/state.md` from the prior stage.
2. **Pre-flight inventory**: for every entry under "Scaffolding still live",
   `grep -rn <slug> CameraKit/Sources/` must return ≥1 hit. Mismatch halts the
   session and requires escalation — source drift is not quietly patched.
3. Read the stage brief (upstream, path above).
4. Read cited architecture refs (§5), domain refs (§6), and the
   `…/ios-translation/implementation/architecture/api-skeletons/Sources/CameraKit/`
   stubs for every file named in §4.
5. Implement per §4 in dependency order.
6. Run §11 verification using the method prescribed in §6 (XcodeBuildMCP or
   wrapper scripts — never raw `swift build` / `swift test`): build, test filter,
   scaffold greps, and any device smoke the brief's §11 calls for. Then update
   `state.md` per §12.
7. Stop. Request user approval before any git operation.

**FEATURE** stages add user-visible capability and may introduce scaffolds;
**MIGRATION** stages retire ≥1 scaffold with a production primitive, preserve
every prior test, and add no user-visible capability.

**Stage kickoff rule (historical).** Each clean-room stage began with
`scripts/stage-preflight.sh` (state.md ↔ source-slug coherence, `CameraKit/CONTRACTS.md`
freshness, build green). That script was pruned in the 2026-05-28 tooling cleanup;
the stage pipeline is complete (below), so nothing kicks off a new stage now.

**Stage 12 was the last clean-room translation stage.** Subsequent work
(Phase 1A/1B/2 in CameraKit's history, and the 2026-05-20 restructure
documented in `docs/archived/superpowers/specs/2026-05-20-flutter-plugin-monorepo-design.md`)
does not follow the stage briefs-and-pre-flight pattern. Phase B (Flutter
plugin implementation) is fresh design, not a continuation of the
clean-room stages.

## 4. Scaffold-slug convention

Scaffolds are marked inline by an exact-string code comment `// scaffolding:NN:kebab-slug`,
where `NN` is the stage that introduced them. That comment is the grep target for
the next stage's pre-flight check. Do not paraphrase the slug, do not re-punctuate
it, do not split it across lines. A scaffold may only be retired by the stage
whose §1 `Retires scaffolding from: …` entry names it — early retirement breaks
the stage-index ordering and invalidates `state.md` as proof of progress.

## 5. Target shape

- **`Package.swift` lives at the repo root** (moved from `CameraKit/` on
  2026-05-20). Targets use explicit `path:` parameters pointing into
  `CameraKit/Sources/{CameraKit,CameraKitInterop,CameraKitCxx}`. There is
  also one `SPMTestStub` testTarget whose only purpose is to emit a `#error`
  when someone runs `swift test`; the real test suite is Xcode-only (§8).
- `ios_example_app/ios_example_app.xcodeproj` is the only Xcode project. It
  owns `Info.plist`, signing, schemes, and `NSCameraUsageDescription` /
  `NSPhotoLibraryAddUsageDescription` (via `INFOPLIST_KEY_*` build settings,
  not literal Plist keys). `CameraKit` is linked as a local SwiftPM
  dependency via `XCLocalSwiftPackageReference` with `relativePath: ..` (the
  xcodeproj's parent of parent is the repo root, where `Package.swift` lives).
  The app target imports it and presents `CameraView()`. Bundle ID:
  `com.cambrian.ios-example-app`; iPad only.
- iOS 26 deployment target; Swift 6 language mode; `SWIFT_STRICT_CONCURRENCY =
  complete` is enforced at build time — treat concurrency warnings as errors.
- **C++ + OpenCV layout (Phase 1B onward).** The `CameraKitCxx` target inside
  the package contains the PixelSink pool seam only (no OpenCV). The OpenCV
  consumer (Canny demo) lives in `ios_example_app/ios_example_app/AppCxx/`
  and links the `opencv2.xcframework` via the symlink at `Frameworks/`
  (repo root). The CameraKit Swift package itself does NOT link OpenCV.
- **Free Apple Developer profile limit: 3 apps per device.** When installing
  on iPad fails with "maximum number of installed apps using a free developer
  profile", uninstall an existing one (long-press → Remove App) and retry.

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
scripts/test-summary.sh --filter ios_example_appTests/Stage01Tests
scripts/test-summary.sh --scheme ios_example_app           # app-level tests
```

Both wrappers pipe `xcodebuild` through `xcsift` (structured JSON output in
`.build-logs/<ts>-*.json`), tee the raw log to `.build-logs/<ts>-*.log`, and
enforce the device-only destination order: physical iPad → Mac "Designed for
iPad" → error. The JSON file is the first thing to read on failure — it has
file/line/message per error, not a grep approximation.

**Never invoke `xcodebuild build` or `xcodebuild test` directly** in a Bash tool
call. `swift build` and `swift test` at the repo root are also avoided: SPM
defaults to the host triple (macOS); CameraKit uses iOS-only AVFoundation APIs,
the host build fails. Running `swift test` does produce the friendly
`SPMTestStub` `#error` pointing to the Xcode path — useful as a sanity-check
but not a substitute for the real test suite. If SourceKit goes sideways:
`rm -rf .build`, clear DerivedData for `ios_example_app-*`, rebuild via the
MCP or wrapper.

Other operations:

```bash
# Scaffold inventory — live slugs must ≥1 hit; retired slugs must 0.
grep -rn 'NN:slug' CameraKit/Sources/

# Destination introspection (when you need to see what xcodebuild considers valid):
xcodebuild -project ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app -showdestinations

# Destination string formats (for --destination on wrappers) — DEVICE ONLY:
#   platform=iOS,id=<udid>                                   (physical iPad; from `xcrun xctrace list devices`)
#   platform=macOS,arch=arm64,variant=Designed for iPad      (native Mac fallback)
# NEVER `platform=iOS Simulator,...` — simulators are disallowed on this machine.

# Style gate = swift-format (exactly what the pre-commit hook runs on staged
# sources). SwiftLint is NOT a commit gate and crashes standalone on this
# machine's beta toolchain ("Loading sourcekitdInProc.framework … failed"),
# so `.swiftlint.yml` is IDE-advisory only — do not rely on the CLI here.
swift-format lint --strict CameraKit/Sources/CameraKit/*.swift
swift-format -i            CameraKit/Sources/CameraKit/*.swift   # auto-fix in place
```

For programmatic xcodeproj edits (package dependencies, build-setting flips,
orientation locks, untracking user-state), use the system-installed Ruby
`xcodeproj` gem — **never** hand-edit `project.pbxproj`:

```bash
ruby -e "require 'xcodeproj'
p = Xcodeproj::Project.open('ios_example_app/ios_example_app.xcodeproj')
# ...mutations...
p.save"
```

**MCP ecosystem** — XcodeBuildMCP owns build/run/test/LLDB/UI on device
targets (see above; simulators are disallowed on this machine). The **`xcode` MCP** is only for actions that need Xcode itself running
(navigator issues, preview rendering, the open window) — reach for it rarely.
If the user names a specific MCP and it is unavailable, stop and say so —
never silently substitute.

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
top of §6). Per-stage HITL / DEFERRED evidence for the completed stages lives under
`docs/archived/measurements/stage-NN/` (the pipeline is complete; no new evidence lands).

### 6.0 One-time host setup

Each development machine needs this once:

```bash
brew install xcode-build-server swift-format ripgrep repomix xcsift jq lefthook
cd "$(git rev-parse --show-toplevel)"
xcode-build-server config -project ios_example_app/ios_example_app.xcodeproj \
                          -scheme ios_example_app
lefthook install                # installs the pre-commit hook (no pre-push — see below)
```

**What `xcode-build-server` does and why we need it.** Sourcekit-lsp (Apple's
Language Server, used by VS Code, neovim, Helix, Sublime Text, etc.) needs to
know how Xcode would compile each Swift file to provide semantic features —
type-resolution, jump-to-definition, find-references, hover docs, completions
across file boundaries. Xcode itself uses an undocumented internal protocol to
talk to its build system; sourcekit-lsp can't replicate that. The
`xcode-build-server` (Homebrew: `brew install xcode-build-server`) is a
third-party tool that translates between the two: it runs `xcodebuild
-showBuildSettings` to learn the project's compile flags, then exposes them
via the standard Build Server Protocol that sourcekit-lsp understands.

Concretely: `xcode-build-server config -project
ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app` writes
`buildServer.json` in the current directory. That file contains the workspace
path, the scheme name, and a `build_root` pointing at the project's
DerivedData. Sourcekit-lsp walks up from a source file's path looking for
`buildServer.json` — so the file MUST be at the repo root (not inside
`ios_example_app/`) to be reachable from sources in `CameraKit/Sources/`.

Without this setup, sourcekit-lsp falls back to a heuristic resolver that
can't track cross-module imports cleanly — you'll see "cannot find type X in
scope" in your editor on Swift files that obviously compile fine.
`buildServer.json` is gitignored (host-specific DerivedData paths); each
developer regenerates after cloning, after switching schemes, or after Xcode
bumps DerivedData hash. Inside Xcode itself, none of this matters — Xcode
uses its own build system. This is purely for external editors.

The third command installs the repo's git hooks, declared in `lefthook.toml` and
managed by [lefthook](https://lefthook.dev). One stage runs:
- **pre-commit** — `swift-format lint --strict` on staged
  `CameraKit/Sources/**.swift` (the authoritative style gate) and a
  `CONTRACTS.md` regen that re-stages the refreshed file. **SwiftLint is NOT a
  commit gate** — it flags CameraKit/Sources' deliberate patterns (test-seam
  `_*ForTest` identifiers, the large `CameraEngine` actor) as errors, and crashes
  standalone on this machine's beta toolchain (`Loading
  sourcekitdInProc.framework … failed`), so `.swiftlint.yml` is IDE-advisory only.

There is **no pre-push hook**: the `camerakit-only` synthetic-branch subtree-sync
was retired in the 2026-05-20 restructure (Package.swift now lives at the repo
root, so `git subtree split --prefix=CameraKit` no longer yields a valid SPM
package — the manifest is outside `CameraKit/`). The Flutter plugin at `flutter/`
is the replacement consumption model — see §10.

**Why lefthook and not git's `core.hooksPath` + a `.githooks/` dir:**
`lefthook install` writes its runner into `.git/hooks/`, so the hooks fire
regardless of what `core.hooksPath` is set to. The worktree tooling repeatedly
resets `core.hooksPath` to the default `.git/hooks` (it writes the *shared*
`.git/config`, common to every linked worktree), which silently disabled the old
`.githooks` setup more than once. Installing into `.git/hooks` makes that reset a
no-op. **Do not set `core.hooksPath`** — leave it unset (default). If you ever see
it set, `git config --unset core.hooksPath` and the hooks keep working. Re-run
`lefthook install` after cloning. Skip a hook for a genuine emergency with
`git commit --no-verify` / `git push --no-verify` (do not use casually).

The `CONTRACTS.md` regen is byte-deterministic (no embedded timestamp), so the
pre-commit hook only produces a diff on a real API-shape change; the hook
`git add`s the refreshed `CONTRACTS.md` so it lands in the same commit (lefthook
does not abort on hook-modified files — one-attempt commits).

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
  `test-summary.sh` defaults to scheme `ios_example_app`. CameraKitTests
  files compile into the app-hosted `ios_example_appTests` target via
  pbxproj wiring (§8). Filter as `-only-testing:ios_example_appTests/<SuiteStructName>`
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
  `~/Library/Developer/Xcode/DerivedData/ios_example_app-*` and rebuild.
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
| Build iOS target | `mcp__XcodeBuildMCP__build_run_device` (primary) or `scripts/build-summary.sh` (fallback) | Device-only on this machine (no sims). Wrapper pipes xcodebuild→xcsift→`.build-logs/*.json` + raw log. |
| Run CameraKit or app tests | `mcp__XcodeBuildMCP__test_device` (primary) or `scripts/test-summary.sh` (fallback) | Device-only (no sims). Both default to scheme `ios_example_app` (app-hosted CameraKitTests via pbxproj wiring — see §8). Filter as `ios_example_appTests/<SuiteStructName>`. |
| Re-wire CameraKitTests after adding a new test file | `scripts/sync-test-target.sh` | Idempotent. Adds new `.swift` files under `CameraKit/Tests/CameraKitTests/` to the Xcode test target. See §8. |
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

- **Debugging: when reasoning keeps losing to observation, stop deriving and
  measure — through an independent, non-tautological path.** If your reading of
  the code (or your model of how it "must" behave) repeatedly concludes "this is
  correct," yet an observation — a user's report, a screenshot, a test, a logged
  runtime value — keeps contradicting it, the repeated contradiction is *itself*
  the signal: the fault lives in something the static read cannot see (an
  undocumented framework/API convention, a runtime value that differs from the
  source, a coordinate-system / unit / orientation mismatch, a layer you haven't
  instrumented). Re-deriving the same conclusion a third time will not find it.
  Two corollaries:
  - **Reject tautological evidence.** A log/assert/check that re-emits the same
    formula you're trying to verify proves nothing (e.g. logging `center =
    width/2` to "confirm" something sits at `width/2`; two values that both
    reduce to the same expression "matching" each other). Confirm through a
    *different* path — a separate code path, a real on-device/runtime
    measurement, or an independent ground-truth marker — not the expression under
    test.
  - **Bisect with an independent third reference.** When two things that "should
    match" don't, and you can't tell which is wrong, introduce a third reference
    computed by a wholly independent mechanism and compare all three. That
    collapses an irreconcilable contradiction into one concrete, fixable site.
  After observation contradicts reasoning twice, switch from arguing to
  instrumenting — it is almost always faster than the next re-derivation, and it
  is the only thing that finds bugs that hide *below* the source (framework
  internals, GPU/driver conventions, the runtime environment).

- **Tests use a host app, not tool-hosted; single-membership Xcode-only.**
  iOS forbids tool-hosted tests on physical-device destinations (`xcodebuild
  test` errors with `Tool-hosted testing is unavailable on device
  destinations`), and simulators are disallowed on this machine (§6). So
  every `.swift` file in `CameraKit/Tests/CameraKitTests/` is compiled
  exclusively by the Xcode `ios_example_appTests` target
  (`TEST_HOST=ios_example_app.app`, runs on iPad). The SPM-side
  `.testTarget(name: "CameraKitTests")` was removed during the 2026-05-20
  restructure (it was an aspirational portability contract that never
  worked due to the macOS-host-triple AVFoundation problem); in its place
  is `SPMTestStub` whose only purpose is to make `swift test` emit a clear
  `#error` pointing to the Xcode path. Canonical run command:
  `mcp__XcodeBuildMCP__test_device` with scheme `ios_example_app`, or
  `scripts/test-summary.sh --filter ios_example_appTests/<SuiteStructName>`
  (no scheme flag needed; default is `ios_example_app`). To add a new test
  file, create it in `CameraKit/Tests/CameraKitTests/` then run
  `scripts/sync-test-target.sh` (idempotent — writes pbxproj entries).
  Filter caveat: each `@Suite` is its own struct —
  `-only-testing:ios_example_appTests/Stage10Tests` (filename) matches
  NOTHING; use the actual struct name from the file
  (`Stage10CoordinatorTests`, `Stage10HappyPathTests`, etc.).
- **The current brief is the source of truth for its stage.** If `architecture/`
  or `ios-platform-guide/` appears to contradict the brief, the brief wins; log
  the conflict in `CameraKit/state.md` under "Decisions taken that weren't in
  briefs" so upstream can patch it.
- **`ADR-##` / `G-##` citations resolve to `docs/reference/ios-platform-guide/`.**
  That in-repo guide is the canonical reference — its `README.md` is the registry.
  The broader clean-room corpus (`briefs`, `architecture`, `domain-revised`) is
  read-only in the upstream `ios-translation` repo and is no longer mirrored here;
  if one of those appears to contradict the code, log it in `state.md` under "Open
  questions" for upstream to patch.
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
  `ios_example_app/ios_example_app.xcodeproj/xcshareddata/xcschemes/ios_example_app.xcscheme`.
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
  (called from `ios_example_appApp.init()`) writes to `<Documents>/camerakit.log`;
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
- `docs/reference/ios-platform-guide/` — the iOS platform guide; `README.md` is
  the `ADR-##` / `G-##` registry that every `ADR-##` / `G-##` citation in the
  Swift sources resolves against, plus the 9 chapters
  (`01-architecture.md` … `09-opencv.md`).

**Upstream (read-only, in the `ios-translation` repo — not mirrored here):**

- `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` — upstream producer
  pipeline and clean-room discipline.
- `/Users/shrek/work/cambrian/ios-translation/implementation/briefs/` —
  `README.md` (read-path, kickoff template, glossary: scaffold / TESTABLE /
  FLAGGED / HITL / DEFERRED) and `stage-NN.md` (each stage's spec).
- `/Users/shrek/work/cambrian/ios-translation/implementation/architecture/README.md`
  — concern-file map + cross-file matrix.

## 10. Flutter plugin layout — `cambrian_ios_camera` under `flutter/`

This repo ships a Flutter plugin in addition to the Swift package. The plugin
lives at `flutter/` and follows standard Flutter plugin conventions:

```
flutter/
├── pubspec.yaml
├── lib/                                  (Dart-facing API + Pigeon-generated bindings)
├── pigeons/                              (Pigeon DSL inputs)
├── ios/cambrian_ios_camera/Package.swift (depends on root via .package(path: "../../.."))
├── android/                              (no-op stub, throws PlatformException)
├── test/                                 (Dart unit tests)
└── example/                              (standard Flutter plugin example app)
```

**Status:** Phase B populated `flutter/` (v1.0.0 — singleton `CameraEngine` over
Pigeon HostApi + five EventChannel streams, native UIScene lifecycle, zero-copy
`FlutterTexture` preview, Android no-op stub, example app). Spec and plan:
`docs/archived/superpowers/specs/2026-05-22-flutter-plugin-phase-b-design.md` and
`docs/archived/superpowers/plans/2026-05-22-flutter-plugin-phase-b.md`; the superseded
Phase 3 plans live in `docs/archived/superpowers/plans/archive/`. See `CameraKit/state.md`
for the full Phase B entry.

**Downstream Flutter consumption:**

```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter        # plugin is at flutter/, not the repo root
      ref: v1.0.0          # pin to a tag
```

**Legacy `camerakit-only` synthetic branch:** This repo previously maintained
a synthetic `camerakit-only` branch on origin (regenerated by a `.githooks/pre-push`
hook via `git subtree split --prefix=CameraKit`) for an earlier cam2fd-subtree
consumption model. The hook was deleted in the 2026-05-20 restructure because
moving `Package.swift` to the repo root invalidates that workflow. The branch
on origin is frozen at its last valid pre-restructure SHA as a safety snapshot
and can be deleted at PR-merge time.

See `README.md` for the full consumer-facing version.

**Flutter integration test constraints:**
- `flutter test integration_test` requires **USB** connectivity to the iPad — wireless
  tethering fails with "Cannot start app on wirelessly tethered iOS device". The error
  message suggests `--publish-port` but that flag does not exist in Flutter 3.41.6 stable.
  Connect via USB cable before running `flutter/example/scripts/test-integration.sh`
  or gate check [3/7].
- VM service "Connection refused" on the first run is transient (timing). Retry once
  before investigating.
- `xcodebuild test` (Swift adapter tests) works fine wirelessly; only `flutter test
  integration_test` requires USB.
