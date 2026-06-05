# CameraKit Consumer Documentation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a self-contained consumer documentation set for the Swift `CameraKit` package, rendered two ways from shared sources — flat Markdown in `Documentation/` (for coding agents) and a DocC site (for humans).

**Architecture:** Three layers over one router — hand-written guides (DocC articles), a generated API reference (from the compiler symbol graph), and worked-example anchoring (snippets tied to `ios_example_app/`). A `regen-docs.sh` orchestrator emits the symbol graph, runs a Python generator to produce the filtered/grouped reference + indices, flat-renders the guides, and assembles `Documentation/`.

**Tech Stack:** Swift symbol graph (`-emit-symbol-graph`), DocC (`xcodebuild docbuild`), Python 3 (generator + tests via `unittest`), bash (orchestration). Builds are device-only (physical iPad → Mac "Designed for iPad"); never simulators.

**Source of truth:** the approved spec `docs/superpowers/specs/2026-06-06-consumer-api-documentation-design.md`. Read it before starting. The documentation **style** is binding (spec §4.1): brief, complete, formal, one-fact-one-place.

**Conventions for this plan:** Per the user's instruction, code blocks are minimal — they show only the load-bearing command, signature, or template. Behavior and acceptance criteria are described in prose; the implementing agent writes the full code. Commit steps are checkpoints; **all git operations require explicit user approval** per repo rule (CLAUDE.md §7) — do not commit autonomously.

---

## Phase A — Reference + DocC infrastructure (tooling)

Output of Phase A: a working pipeline that produces the full `Documentation/` tree with a real generated reference, generated `index.md` / `api-index.md`, and a DocC catalog that builds — guides stubbed. Independently testable.

### Task A1: Pin the symbol-graph emission (spike)

**Files:**
- Create: `scripts/emit-symbol-graph.sh`

- [ ] **Step 1: Write the emit script.** It builds the package through the app scheme on a non-simulator destination, passing the symbol-graph flags, and copies `CameraKit.symbols.json` to a known output dir. Load-bearing command:

```bash
xcodebuild build -project ios_example_app/ios_example_app.xcodeproj -scheme ios_example_app \
  -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' \
  OTHER_SWIFT_FLAGS="-emit-symbol-graph -emit-symbol-graph-dir $OUT_DIR" -allowProvisioningUpdates
```
Destination order: physical iPad first, then Mac "Designed for iPad"; error if neither. Never a simulator.

- [ ] **Step 2: Run it.** `scripts/emit-symbol-graph.sh /tmp/symgraph`
- [ ] **Step 3: Verify.** Assert `CameraKit.symbols.json` exists and contains `CameraEngine`:

```bash
test -f /tmp/symgraph/CameraKit.symbols.json && grep -q '"CameraEngine"' /tmp/symgraph/CameraKit.symbols.json && echo OK
```
Expected: `OK`. If the flag path differs on the toolchain, adjust per the build log (the assertion is the contract). Record the confirmed invocation in the script header.

- [ ] **Step 4: Commit** (approval-gated).

### Task A2: DocC catalog scaffold

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraKit.docc/Documentation.md` (catalog landing)
- Create: `CameraKit/Sources/CameraKit/CameraKit.docc/guides/.gitkeep` (article home)
- Create: `scripts/build-docc.sh`

- [ ] **Step 1: Add the catalog landing page.** A module overview page with a one-paragraph abstract and a `## Topics` section that will list guides. Minimal frontmatter:

```markdown
# ``CameraKit``
@Metadata { @DisplayName("CameraKit") }
Swift camera library: dual-lane capture, Metal preview, recording, calibration.
## Topics
```

- [ ] **Step 2: Add `build-docc.sh`.** Wraps `xcodebuild docbuild -scheme ios_example_app -destination <device-order>` and locates the produced `CameraKit.doccarchive`.
- [ ] **Step 3: Verify** the catalog builds and an archive is produced (device-only destination). Acceptance: `build-docc.sh` exits 0 and prints the archive path.
- [ ] **Step 4: Commit** (approval-gated).

### Task A3: Consumer-symbol filter

**Files:**
- Create: `scripts/docgen/consumer_symbols.py` (filter)
- Create: `scripts/docgen/cluster_map.json` (type → cluster-file + include/exclude config)
- Test: `scripts/docgen/tests/test_consumer_symbols.py`

- [ ] **Step 1: Write the failing test.** Given a fixture symbol graph containing one consumer type (`CameraEngine`) and one internal type (`Watchdog`), the filter returns only `CameraEngine` and reports `Watchdog` as excluded.
- [ ] **Step 2: Define the config + filter.** `cluster_map.json` encodes the spec §9 grouping (cluster → member types) and an explicit exclude list (the dev-internal types named in spec §8.2 `NOT IN THIS REFERENCE`). The filter applies the discriminator "would a consumer ever type this symbol?" via the allow (cluster map) / deny (exclude) lists. Signature:

```python
def filter_symbols(graph: dict, config: dict) -> tuple[list[dict], list[str]]:  # (kept, excluded_names)
```

- [ ] **Step 3: Run the test — green.** `python3 -m unittest scripts.docgen.tests.test_consumer_symbols`
- [ ] **Step 4: Commit** (approval-gated).

### Task A4: Reference generator (symbol graph → grouped cluster Markdown)

**Files:**
- Create: `scripts/docgen/render_reference.py`
- Test: `scripts/docgen/tests/test_render_reference.py`

- [ ] **Step 1: Write the failing test.** Given filtered symbols mapped to clusters, the generator writes one Markdown file per non-empty cluster; each type renders as an `## <Symbol>` section with signature, summary, parameters, returns, and errors drawn from the symbol graph docs. Assert a known symbol's section contains its parameter names.
- [ ] **Step 2: Implement.** Per-file shape per spec §9 (H1 cluster title, H2 per type). Strip/rewrite dev-internal anchors (`Phase-2 design §`, `Stage NN`, `Constants.*`) from doc text so output is self-contained (spec §9 hygiene). Apply the formal/brief style.
- [ ] **Step 3: Run the test — green.**
- [ ] **Step 4: Commit** (approval-gated).

### Task A5: `api-index.md` generator

**Files:**
- Create: `scripts/docgen/render_api_index.py`
- Test: `scripts/docgen/tests/test_render_api_index.py`

- [ ] **Step 1: Write the failing test.** Assert the output contains the four spec §8.2 sections (`HOW THE REFERENCE IS ORGANIZED`, `SYMBOL → FILE`, `BY CLUSTER`, `NOT IN THIS REFERENCE`), that every kept symbol appears in the `SYMBOL → FILE` table mapping to its cluster file, and that each excluded type is listed under `NOT IN THIS REFERENCE`.
- [ ] **Step 2: Implement** per spec §8.2. The `SYMBOL → FILE` table is the agent's one-grep lookup.
- [ ] **Step 3: Run the test — green.**
- [ ] **Step 4: Commit** (approval-gated).

### Task A6: `index.md` generator (the router)

**Files:**
- Create: `scripts/docgen/render_index.py`
- Create: `scripts/docgen/capabilities.json` (capability → description + guide links)
- Test: `scripts/docgen/tests/test_render_index.py`

- [ ] **Step 1: Write the failing test.** Assert the output uses grep-able `## SECTION:` headings for all spec §8.1 sections; that the capability list is a flat list (not a table) where every entry has identical structure with the two subheadings `#### What it does` and `#### Where it's documented`; that capability links point into `guides/` only; and that the `API REFERENCE` section links to `reference/api-index.md` without enumerating symbols.
- [ ] **Step 2: Implement** per spec §8.1. Capability content comes from `capabilities.json` (one entry per capability listed in spec §8.1).
- [ ] **Step 3: Run the test — green.**
- [ ] **Step 4: Commit** (approval-gated).

### Task A7: Guide flat-render (DocC articles → plain Markdown)

**Files:**
- Create: `scripts/docgen/flatten_guides.py`
- Test: `scripts/docgen/tests/test_flatten_guides.py`

- [ ] **Step 1: Write the failing test.** Given a DocC article containing DocC directives (`@Metadata`, `@Links`, a `<doc:Other>` symbol link), assert the flattened output strips/degrades directives to plain Markdown and rewrites `<doc:>` links to relative `.md` paths, preserving prose and code blocks.
- [ ] **Step 2: Implement** the degrade pass (spec §11 / §12 "flat-Markdown-from-DocC-articles").
- [ ] **Step 3: Run the test — green.**
- [ ] **Step 4: Commit** (approval-gated).

### Task A8: `regen-docs.sh` orchestrator + `Documentation/` assembly

**Files:**
- Create: `scripts/regen-docs.sh`
- Create: `Documentation/.gitignore` (ignore the transient `symbol-graph` working dir if not committed)

- [ ] **Step 1: Write the orchestrator.** Sequence: `emit-symbol-graph.sh` → `consumer_symbols` → `render_reference` + `render_api_index` (into `Documentation/reference/`) → `render_index` (`Documentation/index.md`) → `flatten_guides` (`Documentation/guides/`). Mirrors the spirit of `regen-contracts.sh`.
- [ ] **Step 2: Run it** end-to-end.
- [ ] **Step 3: Verify the tree** matches spec §6: `Documentation/index.md`, `Documentation/reference/api-index.md`, `Documentation/reference/symbol-graph.json`, per-cluster `reference/*.md`, and (stub) `Documentation/guides/*.md`. Acceptance: all expected files exist; `index.md` greps `^## SECTION:`; `api-index.md` greps `SYMBOL → FILE`.
- [ ] **Step 4: Decide regeneration trigger** (on-demand vs hook/CI) — default on-demand; document in the script header. (Spec §11: structure does not depend on the trigger.)
- [ ] **Step 5: Commit** (approval-gated).

---

## Phase B — Guide authoring + example anchoring (prose)

Output of Phase B: the ten guides authored against the real, working structure, every snippet anchored to the compiled example app, style-compliant. Validated by DocC build + snippet compilation + style review (not unit tests).

### Task B1: Snippet-anchoring mechanism

**Files:**
- Create: `CameraKit/Sources/CameraKit/CameraKit.docc/Snippets/` (if DocC Snippets) **or** `scripts/docgen/extract_snippet.py` (if marker extraction)

- [ ] **Step 1: Choose the mechanism.** DocC compiled Snippets vs marker-region extraction from `ios_example_app/` sources (spec §10). Both keep snippets honest. Recommendation: marker extraction from the example app, so the *single* source of example code stays the app the user designated as the reference.
- [ ] **Step 2: Implement.** Marker form (example): a snippet is the region between `// docs:begin(<id>)` and `// docs:end(<id>)` in an example-app file; the extractor emits it as a fenced Swift block for inclusion at render time.
- [ ] **Step 3: Verify** one extracted snippet round-trips into a guide and compiles as part of the example-app build.
- [ ] **Step 4: Commit** (approval-gated).

### Task B2: Author the ten guides

**Files (DocC articles, authored here; flat copies generated by A7):**
- Create: `CameraKit/Sources/CameraKit/CameraKit.docc/guides/01-overview.md` … `10-advanced-zero-copy-consumers.md`

Author each per the spec §7 outline. For **each** guide: (a) open with "Assumes you've read: …"; (b) cover the listed sections; (c) anchor every code example to the named example-app file via Task B1; (d) obey the style contract (spec §4.1). Do them one per commit.

- [ ] `01-overview.md` — actor model; dual-lane; lifecycle model. Anchor: `ios_example_appApp.swift`.
- [ ] `02-getting-started.md` — install → permissions → construct → open → preview → close; **owns order-of-operations**; common mistakes. Anchor: `ios_example_appApp.swift`, `UI/CameraView.swift`.
- [ ] `03-lifecycle.md` — `setLifecyclePhase`, `initialPhase`, phase→behavior table, SwiftUI + UIScene wiring, interruptions. Anchor: `ios_example_appApp.swift`, `UI/CameraView.swift`.
- [ ] `04-preview.md` — three lanes; output-type choice; rendering; freshness. Anchor: the Metal view in `UI/`.
- [ ] `05-capturing-stills-and-video.md` — `captureImage` vs `captureNaturalPicture`; output paths; recording; Photos. Anchor: `UI/RecordingViewModel.swift`.
- [ ] `06-controlling-the-camera.md` — capabilities bound settings; `CameraSettings`; auto/manual coupling; WB; zoom/EV; resolution; **crop/ROI in `activeCaptureResolution` pixel space (not the sensor); bound moves with `setResolution`** (per the corrected model). Anchor: `UI/HardwareControlsViewModel.swift`.
- [ ] `07-image-processing.md` — `ProcessingParameters`; processed-lane-only; `.identity`; persistence. Anchor: `UI/ProcessingViewModel.swift`.
- [ ] `08-calibration.md` — white/black balance; `CalibrationResult`; convergence. Anchor: `UI/CalibrationViewModel.swift`.
- [ ] `09-observing-state-and-errors.md` — five streams; non-replay; `SessionState`; errors; recovery; `FrameResult` vs `FrameSet`. Anchor: `UI/ErrorPresenterViewModel.swift`, `UI/DisplayViewModel.swift`.
- [ ] `10-advanced-zero-copy-consumers.md` — when needed; `ConsumerRegistry`/`StreamId`; Swift + native callbacks; `FrameSet`; metrics. Anchor: `AppCxx/` if applicable, else mark advanced/no-app-example.
- [ ] **Commit** after each guide (approval-gated).

### Task B3: Wire the catalog Topics + root README pointer

**Files:**
- Modify: `CameraKit/Sources/CameraKit/CameraKit.docc/Documentation.md` (list guides under `## Topics`)
- Modify: `README.md` (root) — add a one-line pointer to `Documentation/` for consumers

- [ ] **Step 1:** List the ten guides in the catalog landing `## Topics`.
- [ ] **Step 2:** Add the consumer pointer to root `README.md` (route to `Documentation/`; do not route consumers into `docs/`).
- [ ] **Step 3: Commit** (approval-gated).

### Task B4: Full regeneration + verification

- [ ] **Step 1:** Run `scripts/regen-docs.sh`; confirm `Documentation/` is fully populated (guides flat-rendered, reference generated, indices present).
- [ ] **Step 2:** Run `scripts/build-docc.sh`; confirm the DocC archive builds with articles + symbol pages (device-only destination).
- [ ] **Step 3:** Confirm anchored snippets compile (example-app build green on iPad/Mac "Designed for iPad").
- [ ] **Step 4: Style pass** — review every guide + generated reference against spec §4.1 (brief, complete, formal, one-fact-one-place). Fix violations.
- [ ] **Step 5: Discoverability check** — from `Documentation/index.md` alone, confirm an agent can reach the crop/ROI semantics and the lifecycle order-of-operations in ≤2 hops.
- [ ] **Step 6: Commit** (approval-gated).

---

## Self-review notes (author)

- **Spec coverage:** §5 layers → Phases A/B; §6 location/tree → A8; §7 guides → B2; §8.1 index → A6; §8.2 api-index → A5; §9 symbol-graph reference + scoping + hygiene → A1/A3/A4; §10 example anchoring → B1/B2; §11 generation/drift → A8/B4; §4.1 style → B4 Step 4 (review gate).
- **Open items (spec §12) resolved in-plan:** symbol-graph invocation → A1 spike; snippet mechanism → B1; flat-from-DocC → A7; consumer include-list → A3 config.
- **Type/name consistency:** `cluster_map.json` is the single grouping authority consumed by A4/A5; `capabilities.json` by A6; `consumer_symbols.filter_symbols` returns `(kept, excluded)` consumed by A4/A5.
