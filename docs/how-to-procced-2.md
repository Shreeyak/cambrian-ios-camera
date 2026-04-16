Implementation Kickoff Package — CamPlugin into eva-swift-stitch

     Context

     The iOS translation design (~/work/cambrian/ios-translation/design/) is complete and
     GREEN-reviewed. Implementation will land in the existing ~/work/cambrian/eva-swift-stitch
     SwiftUI app as a new CamPlugin/ module. This plan delivers two drafts the user pastes
     into the eva-swift-stitch session to start Phase 1a:

     1. DESIGN_SOURCE.md — one file committed to eva-swift-stitch that pins the design
     repo at a specific commit so the implementing agent always reads the same docs.
     2. Phase 1a plan-mode prompt — the exact prompt to paste into a fresh plan-mode
     session inside eva-swift-stitch. It produces a scoped plan for Phase 1a only.

     No code is written by this plan. The user runs the implementing agent themselves in a
     separate session inside eva-swift-stitch.

     Design pinned at commit: e1c81dc (ios-translation repo, branch main).

     ---
     Draft 1 — DESIGN_SOURCE.md

     Path in target repo: ~/work/cambrian/eva-swift-stitch/DESIGN_SOURCE.md

     # Design Source of Truth

     The Swift code in this repo under `CamPlugin/` is the iOS translation of a Flutter +
     Android camera library. **The authoritative design lives in a separate repo** and must
     not be copied, summarized, or "updated" from inside this repo.

     - **Source repo:** `~/work/cambrian/ios-translation`
     - **Pinned commit:** `e1c81dc` (branch `main`, 2026-04-14)
     - **Verdict:** GREEN (see `review/README.md` in the source repo)

     ## Read order for any agent or engineer touching `CamPlugin/`

     Read in this order before editing a single Swift file. Absolute paths assume the source
     repo is checked out at `~/work/cambrian/ios-translation`.

     1. `design/README.md` — orientation, file index, domain coverage table
     2. `design/01-architecture.md` — sandwich pattern (SwiftUI ↔ Metal/UIKit ↔ CameraEngine actor)
     3. `design/02-concurrency.md` — all 11 invariants mapped to Swift mechanisms; **read this
        before writing any actor, `@MainActor`, or `AsyncStream` code**
     4. `design/03-metal-pipeline.md` — Metal compute shaders, zero-copy path, frame budget
     5. `design/04-opencv-integration.md` — `IFrameConsumer` C++ interface, ObjC++ bridge
     6. `design/05-implementation-phases.md` — **start here for the current phase's file tree
        and acceptance criteria** (the Phase N section is the kickoff brief)
     7. `design/06-decisions-log.md` — read when a design choice looks questionable; alternatives
        are documented with reversibility notes
     8. `design/07-ios-specific-risks.md` — 27 risks, domain edge-case mapping, NEEDS
        INVESTIGATION items; **R-21 and R-22 are P0 acceptance criteria for Phase 1a**
     9. `design/09-architecture-diagrams.md` — visual companion (10 Mermaid + 10 D2 diagrams
        under `design/diagrams/` and `design/diagrams-d2/`)

     ## Load-bearing rules

     - **`design/` is read-only from this repo.** If something is missing, wrong, or
       contradictory, STOP and report — do not "fix it locally". The fix happens upstream in
       the ios-translation repo via the 4-agent pipeline.
     - **No forward-porting across phases.** Phase 1a does not contain Metal code. Phase 2
       does not contain OpenCV. The file trees in `design/05-implementation-phases.md` are
       exhaustive per phase; files not listed do not exist yet.
     - **Deferred findings (F-02, F-04, F-06, F-08)** are implementation-time checklist items
       that fire at specific phases — see annotations in `review/02-adversarial-red-team.md`.
       They are not now-problems unless you're in the phase they belong to.
     - **NEEDS INVESTIGATION items** (U-10 `videoRotationAngle`, U-11 diopter, U-16 AE FPS
       range, R-17 EXIF JSON schema, R-20 noise/edge mapping) are documented in
       `design/07-ios-specific-risks.md` with the phase that must resolve them.

     ## One-time prerequisites before Phase 1a

     These are *project settings*, not Phase 1a tasks. Clear them before dispatching the
     implementing agent so it isn't fighting the build system while writing a state machine.

     - [ ] `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
     - [ ] `SWIFT_VERSION = 6.0` and `SWIFT_STRICT_CONCURRENCY = complete`
     - [ ] `NSCameraUsageDescription` added to `Info.plist` (value: see Phase 5 table in
           `design/05-implementation-phases.md`)
     - [ ] Xcode 16+ with iOS 26 SDK installed
     - [ ] Target device available for on-device runs (simulator does not exercise R-21
           camera-indicator policy or R-05 interruption handling)

     ## Updating the pin

     When the upstream design changes, update the **Pinned commit** line above in the same
     PR as the implementation changes that depend on the new design. Never silently drift.

     ---
     Draft 2 — Phase 1a plan-mode prompt

     Paste this into a fresh session inside ~/work/cambrian/eva-swift-stitch after entering
     plan mode. The prompt assumes the implementing agent can read files under
     ~/work/cambrian/ios-translation/.

     I'm implementing Phase 1a of a 6-phase iOS camera library port. The authoritative design
     lives in a separate repo, pinned at commit e1c81dc. You'll read the design and produce a
     scoped implementation plan for Phase 1a ONLY.

     ## Hard scope boundaries

     - Phase 1a only. No Metal pipeline (Phase 2). No OpenCV / C++ consumers (Phase 3). No
       thermal throttling response (Phase 4). No still capture or recording (Phase 5). No
       API contract coverage polish (Phase 6).
     - Only files listed in `design/05-implementation-phases.md` §Phase 1a "File Tree" exist
       after this phase. `MLProcessor.swift` exists as an empty `@globalActor` stub only.
     - The temporary `AVCaptureVideoPreviewLayer` wrapper (`PreviewLayerWrapper.swift`) is
       explicitly Phase 1a scaffolding and will be removed in Phase 2.
     - Do not write Swift code yet. This session produces a PLAN, not code.

     ## Required reading (in this order)

     Read every section that applies to Phase 1a. Do not skim.

     1. `~/work/cambrian/ios-translation/design/README.md`
     2. `~/work/cambrian/ios-translation/design/01-architecture.md` — entire file
     3. `~/work/cambrian/ios-translation/design/02-concurrency.md` — focus on Invariants 1, 2,
        3, 4, 5, 9, 10 (actor topology, @MainActor boundary, state machine, lifecycle,
        AsyncStream back-pressure). Invariants 6, 7, 8 (Metal / consumer) are Phase 2 / 3.
     4. `~/work/cambrian/ios-translation/design/05-implementation-phases.md` §Phase 1a —
        verbatim, including the Acceptance Criteria, File Tree, and Key Implementation Notes
     5. `~/work/cambrian/ios-translation/design/07-ios-specific-risks.md` — R-01, R-02, R-03,
        R-04, R-05, R-06, R-21, R-22. R-21 and R-22 are P0 for Phase 1a.
     6. `~/work/cambrian/ios-translation/design/06-decisions-log.md` — skim for any D-entry
        that references "Phase 1a" or the files in the Phase 1a tree.

     ## Required context in this repo

     - `DESIGN_SOURCE.md` (root) — pin and read order
     - Current `Info.plist`, project build settings, existing `ContentView.swift`,
       `eva_swift_stitchApp.swift`. You need to know what already exists before adding
       CamPlugin alongside it.
     - Do not modify existing eva-swift-stitch code outside of adding a `CamPlugin/` sibling
       folder and wiring its entry view from the existing app root — unless the plan calls
       that out explicitly and I approve it.

     ## Pre-flight the agent must verify before planning implementation

     Confirm these are already true. If not, STOP and tell me what's missing — these are
     prerequisites, not Phase 1a work:

     - [ ] `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
     - [ ] `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`
     - [ ] `NSCameraUsageDescription` present in `Info.plist`
     - [ ] Xcode with iOS 26 SDK available
     - [ ] On-device run target available (simulator is insufficient for R-21 verification)

     ## Deliverable

     A plan file containing:

     1. **File-by-file task list** — one task per file in the Phase 1a file tree from
        `design/05-implementation-phases.md` §Phase 1a. For each file: purpose (one line),
        the design sections it implements, and its dependencies on other files in the tree.
     2. **Correct task order** — respecting actor/state-machine dependencies. `CameraEngine`
        before `CameraViewModel`; `SessionStateMachine` before `CameraEngine`;
        `PermissionManager` before anything that opens the session.
     3. **Concrete verification steps** for every Phase 1a Acceptance Criterion. Each
        criterion must map to a reproducible manual test or `@Test` unit test. R-21
        (background → camera indicator off within 1 second) must be a manual on-device test.
     4. **NEEDS INVESTIGATION resolutions that land in Phase 1a**:
        - U-10 `videoRotationAngle` — empirical value for the target device; test plan
        - R-22 off-main `startRunning()` — `#assert(!Thread.isMainThread)` placement in DEBUG
     5. **Explicit non-goals** — bullet list of things explicitly NOT done in Phase 1a that
        a reader might expect (Metal pipeline, OpenCV, thermal throttling response, still
        capture, recording, ISO/exposure UI — all later phases).
     6. **Risks specific to this implementation session** — where the design is ambiguous
        enough that you'll need to ask me, vs. where you'll make a call and document it.

     ## Rules

     - `design/` is READ-ONLY from this session. If something is missing or wrong, stop and
       tell me. Do not "fix" design docs.
     - No forward-porting from Phase 1b–6. If a file isn't in the Phase 1a tree, it doesn't
       exist yet.
     - No assumptions about Android structure. The design is iOS-native; don't reason from
       Camera2 / HandlerThread / Surface concepts.
     - The acceptance criteria in `design/05-implementation-phases.md` §Phase 1a ARE the
       test suite. Plan against them literally.

     When the plan file is ready, call ExitPlanMode. Do not start implementing.

     ---
     How the user runs this

     1. Copy Draft 1 into ~/work/cambrian/eva-swift-stitch/DESIGN_SOURCE.md, commit it.
     2. Clear the one-time prerequisites (deployment target, strict concurrency, Info.plist,
     Xcode/SDK, device).
     3. cd ~/work/cambrian/eva-swift-stitch, start a fresh Claude Code session, enter plan
     mode, paste Draft 2 as the prompt.
     4. Review the plan the agent produces; approve or iterate.
     5. Dispatch via /superpowers:executing-plans (or swift-engineering:swift-architect
     → swift-engineer → swift-test-creator) in a new session, pointing at the
     approved plan file.
     6. Walk the Phase 1a Acceptance Criteria on device. Commit + tag phase-1a.
     7. Repeat from step 3 for Phase 1b with a new scoped prompt (same shape, different
     phase section).

     Critical files referenced

     - ~/work/cambrian/ios-translation/design/05-implementation-phases.md (§Phase 1a,
      lines 7–58)
     - ~/work/cambrian/ios-translation/design/02-concurrency.md (invariant mapping)
     - ~/work/cambrian/ios-translation/design/07-ios-specific-risks.md (R-21, R-22)
     - ~/work/cambrian/ios-translation/review/README.md (GREEN verdict for trust anchor)
     - ~/work/cambrian/eva-swift-stitch/ (target repo; currently a skeleton SwiftUI app
     with camera permission scaffolding already present in ContentView.swift)

     Verification of this plan

     There's no code to run. Verification is: the user can paste Draft 1 and Draft 2 into
     eva-swift-stitch unmodified and the resulting plan-mode session produces a Phase 1a
     plan without the agent needing to ask clarifying questions about scope, read order,
     prerequisites, or success criteria. If the agent asks "should I also do X from Phase
     2?" — the prompt failed.