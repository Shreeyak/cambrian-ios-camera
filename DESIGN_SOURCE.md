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
