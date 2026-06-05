# Consumer-facing API documentation for CameraKit — design

**Date:** 2026-06-06
**Status:** Approved design (pre-implementation)
**Scope:** Swift `CameraKit` package only (not the Dart/Flutter surface)

---

## 1. Problem

A developer — or, primarily, their coding agent — cannot understand or integrate
CameraKit without reading material that is meant for *developing this package*, not
for *consuming* it. Concretely:

- **Semantics that exist are hidden.** Per-symbol meaning lives in `///` comments
  (e.g. crop's 4:2:0 even-coordinate rule), but `CONTRACTS.md` is generated with
  `repomix --remove-comments`, so it carries *shape without meaning*. An agent
  reading `CONTRACTS.md` sees `func setCropRegion(_ rect: Rect)` and
  `cropDefaultWidthPx = 1600` with no explanation, and is forced into the source.
- **Cross-symbol behavior is written down nowhere consumer-facing.** Questions like
  "does `activeCaptureResolution` report the crop output or the sensor size?",
  "which preview lane reflects processing?", or "what order do I call things in?"
  require reading multiple source files and inferring relationships.
- **There is no map.** Capabilities (crop, calibration, GPU processing) are
  undiscoverable — an agent finds them by accident while grepping.
- **Everything currently in `docs/` is dev-internal.** `docs/`, `CONTRACTS.md`,
  `DECISIONS.md`, `state.md`, the ADR / platform guide, and the source are all for
  agents *building* the package. None is suitable for a consumer.

## 2. Goals

Produce **one self-contained consumer documentation set** such that a consumer
(human or coding agent) reads *only* that set and never needs source code,
`CONTRACTS.md`, ADRs, or `docs/` working notes.

Render it **two ways from shared sources**:

- **Flat Markdown in-repo** — primary; optimized for an agent's grep-then-read.
- **DocC** — same sources, rendered as a human-browsable site.

Anchor every code example to the **example app** (`ios_example_app/`), which
already integrates CameraKit per best practice and is compiled + device-tested,
so example code cannot silently drift.

## 3. Non-goals

- **No Dart/Flutter docs.** Swift `CameraKit` surface only.
- **No new API or behavior.** Documentation only.
- **Not a rewrite of `docs/`.** `docs/` remains the dev-internal tree, untouched
  except for this spec.
- **Not exhaustive coverage of every public symbol.** The compiler emits all
  public symbols (including DI/test/recovery internals); the consumer reference is
  a deliberate *subset* (§7).

## 4. Audience and reading model

- **Primary reader: a coding agent doing local `grep`-then-`read`** on Markdown in
  the repo. This drives every structural choice: small topical files, grep-able
  headings, a symbol→file lookup table, self-describing labels.
- **Secondary reader: a human** via the rendered DocC site (search, sidebar,
  cross-links).

Both render from one source of truth per layer (§9), so the two never diverge.

### 4.1 Documentation style (binding on all layers)

Every document — guides, index files, and generated reference prose — adheres to:

- **Brevity.** Convey all required information in as few words as possible.
  Prefer short sentences and lists over paragraphs. No filler, no restatement, no
  marketing tone.
- **Completeness without loss of clarity.** Brevity never omits a required fact.
  If a constraint, parameter, ordering rule, or failure mode is load-bearing, state
  it — concisely.
- **Formal register.** Third-person, precise, declarative. Avoid colloquialism,
  hedging, and first-person address beyond direct instruction ("Call `open()`
  before…").
- **One fact, one place.** State each fact once and cross-link rather than repeat,
  to keep documents short and prevent divergence.

This style is a review criterion for the documentation, not merely a preference.

## 5. Architecture — three layers over one router

The doc set is three content layers, each backed by a single source of truth, with
one top-level router (`index.md`):

| Layer | Content | Source of truth | Drift posture |
|---|---|---|---|
| **Guides** (teaching) | concepts, mental models, order-of-operations, gotchas | hand-written DocC articles (Markdown) | slow-changing prose; the *only* hand-maintained layer |
| **API reference** (lookup) | per-symbol signatures, params, returns, errors, conformances | **symbol graph** emitted by the compiler | regenerated; cannot drift |
| **Worked example** (proof) | real end-to-end integration code | **the example app** (compiled + device-tested) | snippets anchored to it; breakage surfaces as a build error |

The two mental models a fresh integrator *must* internalize (and gets wrong without
guidance), derived from the whole API surface — not from any single feature:

1. **Declarative lifecycle.** `CameraEngine` has no conventional `start()`/`stop()`.
   The entire lifecycle API is `setLifecyclePhase(_:)` plus a **no-default**
   `initialPhase` at construction (a deliberate privacy trap-avoidance). New users
   reach for imperative start/stop, skip forwarding `.inactive`/`.background`, and
   default `initialPhase` to `.active` (turning the camera on with no UI).
2. **Dual-lane capture** (natural vs processed, plus a tracker lane). This silently
   governs preview (`currentTexture()` vs `currentProcessedTexture()` vs
   `currentTrackerTexture()`), still capture (`captureNaturalPicture` = natural lane;
   `captureImage` = processed lane), and processing (`ProcessingParameters` affects
   *only* the processed lane).

Lower-order traps the guides must call out: streams are **non-replaying** (subscribe
before/around `open()`); `open()` prompts for permission internally; setting one
manual field can flip the mode to manual; `SessionCapabilities` bounds every setting.

## 6. Location and artifacts

- **Authoring home (single source):** a DocC catalog at
  `CameraKit/Sources/CameraKit/CameraKit.docc/`. Guides are DocC articles (`.md`)
  inside the catalog. This is the idiomatic Swift location and is unmistakably "the
  package's public docs," not dev notes.
- **Agent-facing flat output:** emitted to repo-root **`Documentation/`**
  (capital-D, visually distinct from the dev-internal lowercase `docs/`). Contains
  the guides-as-flat-Markdown, the generated API reference, and `index.md`.
- The root `README.md` routes consumers to `Documentation/`. **Nothing routes a
  consumer into `docs/`.**

```
Documentation/                         ← the ONLY place a consumer reads
├── index.md                           ← top-level router (§8)
├── guides/                            ← layer 1, flat-rendered from the .docc articles
│   ├── 01-overview.md
│   ├── 02-getting-started.md
│   ├── 03-lifecycle.md
│   ├── 04-preview.md
│   ├── 05-capturing-stills-and-video.md
│   ├── 06-controlling-the-camera.md
│   ├── 07-image-processing.md
│   ├── 08-calibration.md
│   ├── 09-observing-state-and-errors.md
│   └── 10-advanced-zero-copy-consumers.md
└── reference/                         ← layer 2, generated from the symbol graph
    ├── api-index.md                   ← symbol→file lookup + cluster map (§8)
    ├── symbol-graph.json              ← canonical machine source (compiler-emitted)
    └── <cluster>.md                   ← flat-markdown views, grouped by cohesion

CameraKit/Sources/CameraKit/CameraKit.docc/   ← authoring source of truth (DocC)
└── <guide articles> + Documentation.md (catalog landing) + Snippets/ (if used)
```

## 7. Layer 1 — conceptual guides

Ten guides, ordered by the **forced-learning seams** of the API (not the method
list). Numeric filename prefixes encode reading order for both the agent (sort) and
DocC (TOC). Each guide opens with an "Assumes you've read: …" pointer and cites the
real example-app file that demonstrates it (§9).

1. **`01-overview.md`** — what CameraKit is; the engine is an `async` actor; the
   dual-lane model; the lifecycle model; what you own vs what CameraKit owns. Installs
   the two mental models before any code.
2. **`02-getting-started.md`** — install (SPM) → permissions → construct
   (`initialPhase`, no default) → `open()` → first preview → close. **Owns the
   order-of-operations.** Common mistakes (subscribe streams before/around open;
   don't default `.active`). Walkthrough of the example app's real path.
3. **`03-lifecycle.md`** — `setLifecyclePhase(_:)` (never throws, latest wins);
   `initialPhase` rationale; the phase→behavior table (active/inactive/background);
   SwiftUI `scenePhase` wiring; UIScene wiring; interruptions are automatic.
4. **`04-preview.md`** — the three lanes; choosing an output type (Metal texture vs
   `currentPixelBuffer(stream:)` vs native handle); rendering; frame freshness.
5. **`05-capturing-stills-and-video.md`** — stills: processed (`captureImage`) vs
   natural (`captureNaturalPicture`); output paths/formats; recording start/stop;
   `RecordingOptions`; saving to Photos; observing recording state.
6. **`06-controlling-the-camera.md`** — capabilities define valid ranges;
   `CameraSettings`; auto/manual coupling (single manual field flips the mode); white
   balance; zoom & exposure compensation; resolution; region-of-interest / sensor
   crop; settings persistence.
7. **`07-image-processing.md`** — `ProcessingParameters` (brightness, contrast,
   saturation, black R/G/B, gamma); processed-lane-only; the `.identity` baseline;
   applying & persisting.
8. **`08-calibration.md`** — white- and black-balance calibration; reading
   `CalibrationResult`; convergence and failure.
9. **`09-observing-state-and-errors.md`** — the five streams; **streams don't
   replay**; `SessionState`; errors (`CameraError`, fatal vs non-fatal); automatic
   recovery; `FrameResult` vs `FrameSet`.
10. **`10-advanced-zero-copy-consumers.md`** — when you need it (most don't);
    `ConsumerRegistry` and `StreamId`; Swift consumers; native callbacks; `FrameSet`
    contents; delivery metrics.

## 8. Index files

### 8.1 `index.md` — the router

Reads *evidently* as an index: it opens by describing its own sections, and every
section uses a **grep-able token-prefixed heading**.

- **Heading convention:** `## SECTION: <NAME>` (uppercase, stable token). An agent
  greps `^## SECTION:` to enumerate the router, or `## SECTION: CAPABILITIES` to jump.
  Capability entries use `### CAPABILITY: <name>`.
- **Sections:**
  - `## SECTION: HOW TO USE THIS INDEX` — what each following section is and who it's for.
  - `## SECTION: START HERE` — the mandatory reading order (01 → 02); notes that
    order-of-operations lives in getting-started, not here.
  - `## SECTION: GUIDES` — the ordered guide list with one-line purposes; links into `guides/`.
  - `## SECTION: CAPABILITIES` — the capability **flat list** (below); links to
    **guides only**.
  - `## SECTION: API REFERENCE` — one paragraph + a single link to
    `reference/api-index.md`; does **not** enumerate per-symbol descriptions.
  - `## SECTION: CONVENTIONS` — cross-cutting reading rules (async actor; dual-lane;
    streams don't replay; capabilities bound settings), each a one-line pointer.

**Capability list entry template** — flat list (not a table); every entry has the
same two self-describing subheadings:

```markdown
### CAPABILITY: <capability name>

#### What it does
<1–2 sentences, plain prose.>

#### Where it's documented
- [<Guide title>](guides/0N-....md)
```

`#### What it does` is the description payload; `#### Where it's documented` is the
navigation payload — labels chosen so an agent classifies each block from the
heading alone. Capabilities enumerated (one block each): Lifecycle · Preview · Still
capture · Video recording · Camera settings · Resolution & region-of-interest ·
Image processing · White/black-balance calibration · State, errors & recovery ·
Zero-copy frame consumers.

### 8.2 `reference/api-index.md` — the reference index

- `## SECTION: HOW THE REFERENCE IS ORGANIZED` — one cluster file per cohesive group.
- `## SECTION: SYMBOL → FILE` — alphabetical `Symbol → file.md` map; **the agent's
  one-grep lookup table** (the load-bearing piece).
- `## SECTION: BY CLUSTER` — cluster files in guide order with member symbols.
- `## SECTION: NOT IN THIS REFERENCE` — names the development-internal public types
  deliberately excluded (e.g. `Watchdog`, `RecoveryCoordinator`,
  `CaptureDeviceProviding`, `AssetWriting`, `Mailbox`, the `_*ForTest` hooks) and
  states consumers never call them.

## 9. Layer 2 — API reference from the symbol graph

- **Source of truth:** the compiler-emitted symbol graph
  (`swift build -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <dir>`,
  or the equivalent build-setting path; exact invocation finalized in the plan).
  This is complete and accurate (signatures, params, returns, availability) and
  includes **relationships** (conformances, inheritance) a `///` scrape can't give.
  It is also what DocC ingests, so one artifact feeds both renders.
- **Agent artifacts (both):**
  - the raw `symbol-graph.json` (canonical lookup source), and
  - a generated **flat-markdown view** grouped by cohesion (one cluster file per
    related-type group), plus the `SYMBOL → FILE` index, for cheap grep-jump.
- **Grouping:** group-by-cohesion (e.g. `CameraSettings` with `CameraMode` /
  `WhiteBalanceMode` / `WhiteBalancePreset`; all error enums in `errors.md`; all
  frame types in `frames.md`), aligned with the guide seams. Per-file shape: an H1
  cluster title, then one H2 per type with signature, summary, parameters, returns,
  errors.
- **Consumer scoping (the filter):** the symbol graph emits *all* public symbols.
  The consumer reference includes only symbols a consumer would write in their own
  integration code. Discriminator: *"would a consumer ever type this symbol's name?"*
  No → excluded (DI seams, test hooks, recovery/watchdog internals, asset-writer
  protocol, `Mailbox`, interop plumbing) and listed under `NOT IN THIS REFERENCE`.
- **Internal-anchor hygiene:** several `///` bodies cite dev-internal anchors
  (`Phase-2 design §2d.5`, `Stage 06`, `Constants.*`) a consumer can't resolve. The
  reference-generation step strips/rewrites these so consumer text stays
  self-contained. (Where feasible, fix at the source `///` so DocC inherits the
  clean text; otherwise strip during flat-markdown generation.)

## 10. Layer 3 — example-app anchoring

`ios_example_app/` is the canonical worked integration — already best-practice,
compiled, and device-tested. It is the anchor that keeps example code honest.

- **Guides cite the real file/region** that demonstrates each concept. Mapping
  (illustrative; finalized in the plan):
  - lifecycle forwarding → `ios_example_app/ios_example_app/ios_example_appApp.swift`
    + `UI/CameraView.swift`
  - preview lanes → the Metal view in `UI/`
  - capture / recording / processing / calibration → `UI/RecordingViewModel.swift`,
    `UI/ProcessingViewModel.swift`, `UI/CalibrationViewModel.swift`,
    `UI/HardwareControlsViewModel.swift`
- **Shown code is anchored to the compiled app**, not free-typed — via DocC
  compiled Snippets or marker-region extraction from the app's sources. If the API
  changes and the app is updated, the snippet moves with it; a snippet that stops
  compiling is a build signal. The exact mechanism is chosen in the plan.

## 11. Generation and drift posture

- **Guides:** hand-written Markdown DocC articles. The only hand-maintained layer;
  scoped to slow-changing concepts. Flat-Markdown copies for `Documentation/guides/`
  are produced from the same article files (copy/transform step).
- **Reference:** regenerated from the symbol graph; never hand-edited. A regen
  script (sibling in spirit to `scripts/regen-contracts.sh`) emits
  `symbol-graph.json`, the cluster Markdown, and `api-index.md`.
- **Example snippets:** anchored to the compiled example app; drift surfaces as a
  build error.
- **DocC site:** built from the catalog (articles + symbol graph + snippets).
- Whether regeneration is wired into a hook/CI or run on demand is a plan decision;
  the structure does not depend on the trigger.

## 12. Risks and open items (resolved in the plan)

- **Exact symbol-graph invocation** for an iOS-only AVFoundation package built
  device-only (host-triple `swift build` fails here — must emit via the Xcode/SPM
  path that targets iOS). To be pinned in the plan.
- **Snippet mechanism** — DocC compiled Snippets vs marker-region extraction from
  the example app. Both keep snippets honest; the plan picks one.
- **Flat-Markdown-from-DocC-articles** — DocC articles use some DocC-specific
  directives; the flat-render step must degrade these gracefully for the agent copy.
- **Consumer-symbol include-list** — the filter (§9) needs an explicit allow/deny
  list; the plan derives it from the public surface.

## 13. Out of scope / explicitly excluded

- Dart/Flutter consumer docs.
- Hosting/publishing the DocC site (separate concern).
- Any change to `CONTRACTS.md`'s role: it remains the dev-internal full-shape doc.
- Renaming the package (`CameraKit` → `CambrianCamera`) — tracked elsewhere.
