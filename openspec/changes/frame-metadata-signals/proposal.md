## Why

The stitcher gates its first-writer-wins mosaic seed on the camera's convergence
state (a mid-autofocus frame must not seed). Today that state is unavailable on the
frame: `CaptureMetadata` is a zero-valued stub, and `blurScore`/`trackerQuality` are
hardcoded lies (`0.0` / `.good`). The real sensor state lives in
`device.lastSnapshot` but was never threaded into frame construction. We deliver the
decision-relevant signals as **typed, per-frame metadata**, route heavyweight debug
detail to the **low-rate 3 Hz stream as JSON**, and remove the fabricated signals.

## What Changes

- **`CameraFrameMetadata: FrameMetadata`** carried per-frame, with typed fields the
  consumer branches on: `settled` (AE && WB && focus converged), `focusState`,
  `wbState`, `exposureState`. Plumbed from the real `DeviceStateSnapshot`
  (`device.lastSnapshot`) into frame construction — replacing the zero-valued stub.
- **Rule:** anything a consumer makes a control decision on is a typed member of
  `CameraFrameMetadata`; it is never an untyped blob.
- **3 Hz `frameResultStream` carries a JSON debug payload** for heavyweight,
  occasionally-needed diagnostics already produced by the camera library (AF status
  detail, WB settling progress, full AE state) — forwarded, not branched on.
- **`ProcessingMetadata` (grade params: brightness/contrast/saturation/gamma/
  cropRegion/wbGains) routes to the 3 Hz JSON**, not per-frame typed metadata —
  nothing branches on grade params and they change only on reconfigure.
- **BREAKING: remove `blurScore` and `trackerQuality`** (and the `TrackerQuality`
  enum) — hardcoded signals the contract advertised but never computed. The
  stitcher's own `QualityGate` covers the equivalent.

## Capabilities

### New Capabilities

- `frame-metadata`: the camera's per-frame typed decision signals
  (`CameraFrameMetadata`: `settled`/`focusState`/`wbState`/`exposureState`, plumbed
  from real sensor state), the off-hot-path 3 Hz JSON debug channel (including the
  former `ProcessingMetadata`), and the removal of the fabricated
  `blurScore`/`trackerQuality` signals.

### Modified Capabilities

<!-- None — openspec/specs/ is empty. -->

## Impact

- **CameraKit API:** `CameraFrameMetadata` on `Frame`; `FrameResult` gains a JSON
  diagnostics payload; **remove** `blurScore`/`trackerQuality`/`TrackerQuality`.
- **CameraKit internals:** thread `DeviceStateSnapshot` into the MetalPipeline
  completion handler (replace the `.placeholder()` stub); drop the hardcoded
  `blurScore`/`trackerQuality` assignments; route `ProcessingMetadata` fields into
  the 3 Hz JSON.
- **Depends on:** `frame-transport-package` (the `FrameMetadata` marker + `Frame`)
  and `frame-delivery-rework` (per-lane `Frame` construction). **Authoritative
  design:** §3.5, §3.6, §3.10.
