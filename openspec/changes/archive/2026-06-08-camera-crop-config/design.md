## Context

CameraKit already honors `OpenConfiguration.cropRegion: Rect?` at `open()`
(`CameraEngine.swift:299-313`), applies live crops via `setCropRegion(_:)`
(rebuilds `MetalPipeline` with new `outputSize`/`cropOrigin`,
`CameraEngine.swift:932`), and validates bounds + even (4:2:0) coordinates in
`validateCropRegion(_:captureSize:)` (`CameraEngine.swift:897`, throws
`EngineError.settingsConflict`). Capture resolution comes from
`device.supportedSizes` (`SessionCapabilities.supportedSizes`,
`CameraEngine.swift:457`) but a requested `captureResolution` is not validated
against it. `Constants.cropDefault*` (1440×1440) exists but is consumed nowhere.

## Goals / Non-Goals

**Goals:** ergonomic center+ratio crop; resolution validation; disabled-by-default
crop with a remembered 1440×1440 default wired from `Constants`; one set of
geometry invariants at every entry point.

**Non-Goals:** changing the Metal crop mechanism (Pass-1 sub-region read);
frame-delivery shape (separate change); tracker sizing (already shipped via
`OpenConfiguration.trackerHeight`).

## Decisions

### D1. Resolution validation: reject, don't snap — and *apply* at open
Compare requested `Size` against `device.supportedSizes`; throw
`EngineError.settingsConflict` naming both when absent. `nil` keeps default.
Silent snapping would hide a caller bug and shift crop math under a surprising
resolution. (A fixed `Resolution` enum is rejected — supported sizes are
device-dependent; `[Size]` in `SessionCapabilities` is the right surface.)

**Implementation note (validate-AND-apply).** `captureResolution` was found to be
**entirely unwired** at `open()` — `CameraSession.configure()` ignored it and
selected the largest 4:3/30fps format. The spec scenario ("the session is
configured at that resolution") mandates apply, not just validate, so this change
wires `captureResolution` into `configure(requestedSize:)`. Selection uses
**exact-dimension FullRange matching** — the same list `SessionCapabilities.supportedSizes`
advertises and `reconfigureSize` matches against — so the set we validate against
and the set we can select from coincide (a size that passes validation can always
be applied). `setResolution` already applied via `reconfigureSize`; it gains the
shared `validateRequestedResolution` pre-check for the richer error.

### D2. `setCenterCrop` math (pinned)
`func setCenterCrop(width:Int, height:Int, offsetX:Double = 0, offsetY:Double = 0) async throws`.
Offsets are ratios of the active-resolution dimensions, from the resolution
center. Order:
1. `w = evenDown(min(width, resW))`, `h = evenDown(min(height, resH))`.
2. `centerX = evenNearest(resW/2 + offsetX*resW)`, `centerY = evenNearest(resH/2 + offsetY*resH)`.
3. `x = centerX - w/2`, `y = centerY - h/2`.
4. Clamp `x ∈ 0...(resW-w)`, `y ∈ 0...(resH-h)`; even-snap origin (bounds already even).
5. Build `Rect(x,y,w,h)`; route through the existing `setCropRegion` rebuild
   (reuses `validateCropRegion` as a final assertion + the proven rebuild/seed).

**Worked example (user spec):** 100×100 resolution & crop, offset (0.1,0.2):
step 2 → `centerX = 50 + 0.1·100 = 60`, `centerY = 50 + 0.2·100 = 70` = `(60,70)`.
Step 4: with `w=h=100` the only legal origin is `(0,0)`, so the effective center
returns to `(50,50)` — the offset is a no-op on a full-size crop. A smaller crop
(e.g. 1440×1440 in a 1920×1440 frame, offsetX 0.1 → `centerX = 960+192 = 1152`,
`x = 1152-720 = 432`, in-bounds) honors the offset. This clamp-after-formula
behavior is documented so callers aren't surprised. (Offset-as-pan-margin is
rejected; it contradicts the `0.1→+10px on 100px` example.)

### D3. Crop enable/disable + remembered default
Engine state: `cropEnabled: Bool = false`, `configuredCrop: Rect?`.
- `setCropEnabled(true)` → apply `configuredCrop` or a centered
  `Constants.cropDefault*` clamped to the active resolution.
- `setCropEnabled(false)` → rebuild at full `captureSize`.
- `setCropRegion`/`setCenterCrop` set `configuredCrop`, imply `cropEnabled = true`.
- `OpenConfiguration.cropEnabled: Bool = false`; `true` + `cropRegion == nil` →
  apply default at open (first frame cropped); `cropRegion != nil` → that rect is
  the configured crop (enabled). Separates policy (cropped vs full) from geometry
  so a toggle/re-enable doesn't lose the rect. (Modeling "disabled" as
  `cropRegion == captureSize` is rejected — loses geometry and couples policy to a
  resolution that `setResolution` can change.)
- **`setResolution` × crop (implementation note).** A resolution change rebuilds
  full-frame, and a remembered rect may not fit the new (smaller) resolution, so
  `setResolution` resets `cropEnabled = false` / `configuredCrop = nil` — a later
  enable applies the default rather than throwing on a stale rect. The spec didn't
  pin this interaction; documented in guide 06.

### D4. Wire `Constants.cropDefault*` into `open()`
The default crop size reads from `Constants.cropDefault*` (1440×1440) — resolves
open decision §D.2 of the recommendations doc (wire, not delete).

## Risks / Trade-offs

- **[Resolution rejection breaks a caller relying on silent acceptance]** → low;
  an unsupported size already produces undefined behavior. Clear error is better.
- **[`setCenterCrop` offset semantics misunderstood]** → documented worked example
  + the full-size no-op note in DocC guide 06 and spec scenarios.
- **[Default-crop clamp on a small sensor format]** → clamp to resolution; never
  upscale; covered by the "clamped to the active resolution if smaller" scenario.

## Migration Plan

Additive except resolution validation. Implement state + APIs, wire `Constants`,
update DocC guide 06, regenerate `Documentation/`, device-test crop tests.
Independently committable before the frame-delivery changes.

## Source coverage (recommendations docs)

Covers: doc `02` §A.0 (1440 default — now wired), §D.2 (cropDefault wire);
doc `01` "Working resolution 1440×1440" + "Crop-default change status". The
1536² perf aside and EvaScan's 1600→1440 housekeeping (§B.4 / §D.1) are
**cross-repo** (mac-stitch-video) — out of scope here, tracked in
`frame-delivery-contract` design's coverage matrix.
