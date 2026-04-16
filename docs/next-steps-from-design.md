Got it — you want the workflow, not for me to do the prep myself. Here's how I'd run it.

  Step-by-step

  1. Pin the design as the source of truth. In eva-swift-stitch, add a tiny DESIGN_SOURCE.md that links to this repo's design/ at a specific
  commit SHA, and lists the read order from design/README.md. Don't copy the files in — you want one canonical copy that can be updated via the
   upstream pipeline.

  2. Bring the target repo up to spec first (one-time prereqs, before any agent run).
  - Bump deployment target: IPHONEOS_DEPLOYMENT_TARGET = 26.0
  - Swift 6 strict concurrency: SWIFT_STRICT_CONCURRENCY = complete
  - Add NSCameraUsageDescription to Info.plist
  - Confirm Xcode 16+/iOS 26 SDK is installed
  (These are "prep," not "Phase 1a" — the agent shouldn't be fighting project settings while also writing a state machine.)

  3. Scope the first agent run to Phase 1a only. Six phases in one session will drift. design/05-implementation-phases.md §Phase 1a is already
  a self-contained kickoff brief: goal, acceptance criteria, file tree, key notes.

  4. Build the Phase 1a input package (the exact docs you hand the implementing agent):
  - design/05-implementation-phases.md §Phase 1a (verbatim — file tree + acceptance criteria)
  - design/01-architecture.md (sandwich pattern)
  - design/02-concurrency.md §Invariant mapping (actor rules the code must satisfy)
  - design/07-ios-specific-risks.md R-21 and R-22 (the P0 policy items for 1a)
  - Two NEEDS INVESTIGATION items that land in 1a: U-10 videoRotationAngle empirical check, R-22 off-main startRunning assertion

  5. Dispatch the agent from inside eva-swift-stitch (not this repo):
  - Enter plan mode → use /superpowers:writing-plans with the input package above to produce a Phase 1a plan
  - Then /superpowers:executing-plans (or swift-engineering:swift-architect → swift-engineer → swift-test-creator chain) to execute
  - Constrain scope in the plan: "only files listed in Phase 1a file tree; no Metal pipeline (that's Phase 2); no OpenCV (that's Phase 3)"

  6. Verification = the acceptance criteria. Phase 1a has ~9 bullets that are the test suite. Walk them on a real device (simulator won't
  exercise R-21 camera-indicator policy or interruption handling). Build + run, then tick each criterion.

  7. Land, tag, repeat. Commit Phase 1a, tag phase-1a, then start a fresh agent session for Phase 1b with its own scoped input package. Each
  phase is one implement→verify→merge cycle.

  Key rules to give the agent (copy into the plan)

  - design/ is read-only source of truth; agent must not "fix" it — if something feels missing, flag it and stop
  - No forward-porting from later phases (no Metal code in 1a, no OpenCV in 1a or 2)
  - Deferred findings (F-02/04/06/08) fire at their specific phases — they're checklist items, not now-problems

  Where I'd start right now

  Decide whether to run Phase 1a inside this plan-mode session in ios-translation, or cd into eva-swift-stitch and start a fresh session there.
   I'd vote fresh session in eva-swift-stitch — the implementing agent should have the target repo as its primary working directory, not this
  prompt workspace.

  Want me to draft the exact DESIGN_SOURCE.md and the Phase 1a plan prompt text for you to paste into the eva-swift-stitch session?
