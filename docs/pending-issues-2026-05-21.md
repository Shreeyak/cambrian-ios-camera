# Pending issues audit — 2026-05-21

Snapshot of all outstanding/deferred work in CameraKit as of 2026-05-21,
compiled by sweeping `CameraKit/state.md`, `CameraKit/DECISIONS.md`,
`docs/stage-11-pre-existing-bugs.md`, and inline source markers.

**Headline:** the codebase is at a clean checkpoint — **zero inline
`TODO`/`FIXME`/`HACK` markers in `CameraKit/Sources/`, zero active scaffolds**
(`scripts/scaffold-inventory.sh` → "no active scaffolds"). Everything below is
either deferred device verification, by-design deferral, or an opt-in
enhancement. None is a code defect blocking the current build.

Each item cites its tracking location so it can be re-verified — historical
`state.md` sections are not struck through when an item is resolved, so some
older entries may already be done. Verify before acting.

---

## Bucket 1 — Live / current-stage follow-ups (most actionable)

### 1.1 Internal payoff sites, deliberately out of scope
`state.md:249` ("Follow-up consumers (out of scope this PR)"):

- **`RecoveryCoordinator` mid-recovery close detection.** Could consult
  `engine.stateMachine.current` via a new hook to detect a mid-recovery
  `close()` instead of relying purely on `attempt` + external
  `cancelPendingRetry()`.
- **Watchdog state-aware suppression.** Watchdogs could skip firing during
  `.paused` / `.recovering` / `.interrupted` based on a direct state read,
  rather than a `sessionToken` comparison.

Both are refactors that lean on the now-public `SessionStateMachine.current`.
No behavioral bug; cleaner internal wiring.

### 1.2 AVF interruption path — unit-test-only
`state.md:290`. `SessionState.interrupted` (the AVF
`wasInterruptedNotification` route) is verified by unit test only. On iPad,
Control Center / Notification Center do **not** trigger an AVF interruption
(the system keeps the camera bound), so there is no on-device HITL evidence.
May be unverifiable on this hardware short of a phone call / FaceTime
interruption scenario.

### 1.3 Still-capture device HITL — pending
`state.md:175`, `state.md:239`. Golden-path on-device smoke for `captureImage`
/ `captureNaturalPicture` (TIFF + JPEG open correctly, saved-banner timing)
is marked pending. Architecturally exercised; HITL evidence not yet captured
under the current BGRA pipeline.

---

## Bucket 2 — By-design deferrals (tracked, not blockers)

### 2.1 Error-stream → UI not wired
`state.md:895` (Decision #58), `state.md:938`. `updateSettings` hardware-cap
failures log to `CameraKitLog.engine.warning` instead of routing to
`errorStream` (ADR-22). The host app does not subscribe a UI banner to the
error stream. Deferred to a future engine pass; console-only for now.

### 2.2 Recording bitrate default unmeasured
`state.md:1159` (Decision #45). `recordingTargetBitrateBpsDefault =
40_000_000` is a reasonable default for 4K HEVC @ 30fps but is pending
on-device measurement.

### 2.3 `CameraKitInterop` temporary SwiftPM export
`state.md:468`. Exported as a SwiftPM product as a transitional bridge-state
for Phase 3; revisit when the Flutter plugin's Package.swift wiring is final.

### 2.4 `SessionState.closing` enum reconciliation
`state.md:1102` (Decision #50). Either add `.closing` in
`architecture/04-state.md` and use it, or drop it from the brief §8
enablement matrix. Documentation/contract reconciliation, no runtime impact.

### 2.5 `"CamPlugin/v1"` JSON schema (U-09)
`state.md:1369`. Remains deferred.

---

## Bucket 3 — Older deferred HITL / measurement evidence (stages 06–11)

A long tail of `DEFERRED` device-evidence rows. These are measurement
artifacts to capture on-device, not code changes. **Caveat:** these are
historical stage entries; some may have been satisfied in later stages
without the line being struck through. Re-verify each against
`measurements/stage-NN/` before acting.

- `07:tiff-opens-in-preview-and-photos`, `07:saved-banner-appears-three-seconds`,
  `07:authorization-dialog-first-capture` (`state.md:1351-1353`).
- `08:external-canny-stub-runs-on-device` (`state.md:1298`); OpenCV xcframework
  Mac "Designed for iPad" slice unverified — xcframework ships `ios-arm64`
  only (`state.md:1300`).
- `09:ae-convergence-timeout-emits`, `09:fps-degraded-requires-streak` — passed
  as constant-validation stubs; full `TestClock`-driven integration tests
  deferred to a test-improvement pass (`state.md:1215-1216`, `:1225`, `:1234`).
- `10:mp4-plays-in-photos`, `10:low-light-ae-drops-below-30fps`,
  `10:empirical-format-fps-range-fallback` (`state.md:1149-1151`).
- Stage-06 crop visual end-to-end verification and Instruments pool
  high-water-mark evidence (`state.md:1526`, `:1528`).
- Stage-11 `measurements/stage-11/` — three slugs deferred (`state.md:1103`).
- `04:rapid-slider-stress` device Instruments run — optional HITL
  (`state.md:1485`).

---

## Resolved during this audit

### Bug 4 — `processedTex` long-session freeze — **RESOLVED**

`state.md:1101` listed this as an open question ("Needs HITL on iPad… Fix
before retiring `10:synchronous-drain-pause` in Stage 12"). That entry is
**stale**. The bug was already fixed and double-resolved:

1. **Fixed 2026-04-30, verified on iPad 2026-05-09**
   (`docs/stage-11-pre-existing-bugs.md:171`). Root cause: the still-capture
   mailbox stranded the most recently produced processed buffer when the pool
   rotated. Fix: live mailbox forwarding in `CameraEngine` / `DisplayViewModel`.

2. **Mechanism later deleted by D-2P-12** (8-bit BGRA end-to-end, 2026-05-20).
   The entire Pass-6 GPU-readback still pipeline — `stillCapturePool`,
   `armCapture`, `pendingCaptureContinuation`, the stranding still-capture
   mailbox — was removed. Verified absent in current source: a grep for
   `stillCapturePool|armCapture|pendingCaptureContinuation|makeStillCapturePool|stillReadbackBuffer`
   returns **0 hits** under `CameraKit/Sources/`.

The processed lane now uses unconditional per-frame `Mailbox` forwarding:
Pass-2 stores `_latestProcessedTex16F` / `_latestProcessedBgra8Tex` /
`_latestProcessedBuffer` every frame (`MetalPipeline.swift:684-686, 766-767`),
read live via `CameraEngine.currentProcessedTexture()`
(`CameraEngine.swift:830`). A `Mailbox` is a store-latest cell, so the preview
always reflects the newest frame — the original stranding failure mode is
structurally impossible.

**No code change required.** The stale `state.md:1101` entry has been
annotated as resolved pointing here.

> Residual risk: the original on-device verification predates the 2026-05-20
> BGRA pipeline rewrite. The root-cause mechanism is gone, so a regression is
> not expected, but a fresh 5-minute on-device soak under the new pipeline
> would fully retire any doubt. Not done in this pass (requires device + soak
> time); tracked here as optional confirmation, not an open defect.
