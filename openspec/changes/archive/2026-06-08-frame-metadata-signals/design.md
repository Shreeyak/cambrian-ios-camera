## Context

The stitcher seeds a first-writer-wins mosaic (EvaScan ADR-006) and must not seed on
an unconverged frame. CameraKit has the state (AE-adjusting flag, WB-settled signal,
lens position in `DeviceStateSnapshot` / `device.lastSnapshot`) but never threaded
it into frame construction: `MetalPipeline` builds a zero-valued `CaptureMetadata`
placeholder and hardcodes `blurScore = 0.0` / `trackerQuality = .good` in the
completion handler. Authoritative design: `docs/03-authoritative-frame-transport-rework.md`
§3.5, §3.6, §3.10.

## Goals / Non-Goals

**Goals:**
- Typed, per-frame `CameraFrameMetadata` carrying real convergence state.
- A clear split: typed decision signals per-frame; heavyweight debug detail as JSON
  on the 3 Hz stream.
- Remove the fabricated `blurScore`/`trackerQuality`.

**Non-Goals:**
- The `FrameMetadata` marker protocol / `Frame` type (`frame-transport-package`).
- Per-lane `Frame` construction plumbing (`frame-delivery-rework`).
- Implementing honest GPU blur/quality signals (explicitly deferred; removed for now).
- The consumer-side seed gate (EvaScan).

## Decisions

- **`settled` is a conjunction, not a single flag.** `settled = AE-converged &&
  WB-settled && focus-converged`, plus the individual `focusState`/`wbState`/
  `exposureState` for finer gating. A single Bool would hide which axis is
  unconverged.
- **Typed vs JSON split by whether a consumer branches on it.** Decision-relevant →
  typed on `CameraFrameMetadata` (hot path, every frame). Debug-only → JSON on the
  existing 3 Hz `frameResultStream` (already low-rate; the camera library already
  produces the detail, we forward it). This keeps heavyweight metadata off the hot
  path while keeping the seed gate's inputs strongly typed.
- **`ProcessingMetadata` → 3 Hz JSON.** Nothing branches on grade params; they change
  only on reconfigure, and `cropRegion` is consumer-driven (echoing it per-frame was
  pure redundancy). The JSON channel is sufficient for confirmation/debug.
- **Remove `blurScore`/`trackerQuality` rather than implement.** They were never
  computed; the consumer's `QualityGate` already covers the need. Implementing an
  honest GPU reduction is out of scope and unneeded today.

## Risks / Trade-offs

- **Plumbing `DeviceStateSnapshot` into the completion handler is real work**, not a
  one-line field (the metadata was entirely stubbed) → Mitigation: the snapshot
  already exists on the device; the work is threading it to the construction site.
- **JSON payload is unstructured/debug-grade** → Accepted: it is explicitly not a
  control surface; anything load-bearing must be promoted to a typed field.
- **Removing advertised signals is breaking** → Mitigation: no external consumer
  uses them; they were hardcoded constants.

## Migration Plan

Land after `frame-transport-package` and `frame-delivery-rework`. Thread
`DeviceStateSnapshot` into `Frame`/`CameraFrameMetadata` construction; add the JSON
diagnostics payload to `FrameResult`; route `ProcessingMetadata` fields into it;
delete `blurScore`/`trackerQuality`/`TrackerQuality`.

## Open Questions

- JSON payload shape (flat key/values vs nested) — left to implementation; it is a
  debug surface, not a contract.
