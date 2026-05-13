# Resolution picker → saved-image resolution alignment

**Status:** Plan only. Awaiting user decision between Option A and Option B before implementation.

## Symptom (HITL 2026-05-13)

User picks 1440×1080 (or any resolution) from the new bottom-bar Resolution menu. The next still capture saves an 8-bit TIFF at **4032×3024** — the device's full sensor format — not at the picked resolution. The picker has no effect on the saved-image dimensions.

## Why this is happening

The picker changes `CameraEngine.captureSize` (via `setResolution → reconfigureSize`), which does swap the AVCaptureSession's `activeFormat` to a smaller sensor mode. But:

- `MetalPipeline.naturalPool` and `processedPool` are allocated at the *new* `captureSize`, so the GPU textures match what the sensor delivers.
- Still capture writes a TIFF whose dimensions are `pipeline.captureSize` (`StillCapture.captureImage` arg, `CameraEngine.swift:883`).

So in principle picking 1440×1080 *should* produce a 1440×1080 TIFF. The fact that the user saw a 4032×3024 TIFF means **the capture was taken before they changed the resolution** — i.e., the picker doesn't break this, capture has been at sensor resolution from the start because nobody has picked anything smaller.

**But there's a second, deeper issue worth surfacing here.** The `SessionCapabilities.activeCropRegion` field is publicly advertised as "the crop region in effect at session open … drives the resolution of the natural, processed, and tracker streams" (`domain-revised/10-api-contract.md` §SessionCapabilities; line 177 of the spec). The implementation does **not** honor this:

| Field | Spec says | Implementation does |
|---|---|---|
| `activeCropRegion` | Center-crop applied before processing; drives natural/processed/tracker dims | Pure metadata; never read by MetalPipeline |
| `naturalPool` size | `crop.width × crop.height` | `captureSize.width × captureSize.height` (`MetalPipeline.swift:283`) |
| `processedPool` size | `crop.width × crop.height` | `captureSize.width × captureSize.height` (`MetalPipeline.swift:284`) |
| Pass 1 crop uniform | `crop.x, crop.y, crop.width, crop.height` | `.full(captureSize)` — no crop (`MetalPipeline.swift:276`) |
| `activeCropRegion` origin | Center-anchored (e.g., `x=1216, y=912` for 1600×1200 inside 4032×3024) | Always `(0, 0)` (`CameraEngine.swift:276-281`) |

And on top of that, `setCropRegion(_:)` (`CameraEngine.swift:629`) is a public API that updates *something* — needs tracing — but the GPU pipeline doesn't read from it either.

## Investigation tasks

These are read-only; they refine the fix shape before any code change.

1. **Confirm with a fresh capture at a non-default resolution.** Pick 1440×1080 in the menu, capture, inspect the resulting TIFF's dimensions. Expected outcome: 1440×1080 (the picker *does* work for still capture); if 4032×3024, then `setResolution` isn't propagating to `pipeline.captureSize` and there's a separate bug. **(This is the "run app and test" step the user asked for — verifies the diagnosis before we commit to a fix shape.)**

2. **Trace `setCropRegion`.** `CameraEngine.swift:629` — what does it actually mutate? Is the value stored on the engine, on a uniform buffer, on `naturalPool`, or nowhere? If it's stored but never read by `MetalPipeline.encode()`, that's a no-op public API.

3. **Decide what `activeCropRegion` should mean.** The choices:
   - **(A) WYSIWYG.** Crop is real. Picker's chosen resolution drives `naturalPool`/`processedPool`/`trackerPool` sizes; still capture inherits those. Saved TIFF = picker resolution. `setCropRegion` actually re-crops.
   - **(B) Drop the crop concept.** `activeCropRegion` is removed from `SessionCapabilities` (or kept and documented as "always full frame"); `setCropRegion` is removed or made a no-op. Picker drives the only resolution that matters.
   - **(C) Hybrid.** Natural/processed/tracker stay at `captureSize`; `activeCropRegion` is metadata for downstream consumers (e.g., ML cropping) without affecting GPU dims. Still capture stays at `captureSize`. Document accordingly.

## Recommendation

**Option B.** Reasoning:
- The user's mental model — "what I pick is what gets saved" — is the model of every consumer camera app and matches Option B exactly.
- Option A is a real refactor: every texture pool, every encoder dimension, every recording dim, the Canny stub, and the C++ pixel-sink pool all key off `captureSize`. Re-keying on a separate crop dim ripples through Stages 06–10. Worth it only if there's a concrete consumer that needs the crop semantics — and right now there isn't.
- Option C keeps the public surface promising something the implementation doesn't deliver. Worst of both worlds.
- The picker (Bug 11) already gives users direct control over `captureSize`. That's the only "resolution" knob they should see.

If the user wants Option A or C instead, the rest of this plan flips — see the open question.

## Implementation tasks (Option B)

> Tasks are written assuming Option B is approved. Do **not** start without explicit user sign-off on the choice. If Option A is picked, see the alternative below.

1. **Verify with a fresh HITL.** Pick 1440×1080, capture, confirm the TIFF is 1440×1080. If it's not, **stop** — there's a propagation bug between `setResolution` and `pipeline.captureSize` that has to be fixed first.

2. **Drop `activeCropRegion` from `SessionCapabilities` and remove `setCropRegion`.**
   - `Capabilities.swift`: remove `activeCropRegion: Rect` from the struct + init.
   - `OpenConfiguration.swift`: remove `cropRegion: Rect?` from the open() arg.
   - `CameraEngine.swift`: drop the field population at line 276-281 + 294; remove `setCropRegion(_:)` at line 629.
   - `Constants.swift`: remove `cropDefaultWidthPx` / `cropDefaultHeightPx` (or keep if referenced elsewhere — grep first).
   - This is a **public-API breaking change**. Note in state.md Decisions; flag upstream so `domain-revised/10-api-contract.md` §SessionCapabilities and §`setCropRegion` are deleted.

3. **Update the architecture spec deviation log.** `architecture/06-capture-and-recording.md` references crop interactions with pause/recording — those become moot.

4. **Update `ViewModel.dumpCapabilities`.** Remove the `activeCropRegion` line from `capabilities.txt`.

5. **Tests.** Any test that asserts `activeCropRegion` shape needs to be removed. Grep:
   ```
   grep -rn "activeCropRegion\|setCropRegion\|cropRegion" CameraKit/Tests/
   ```

6. **Verify regression.** Full `test_device` against the `eva-swift-stitch` scheme. All prior tests should still pass.

7. **HITL re-test.** Open app at default 4032×3024 → capture → TIFF is 4032×3024 → switch to 1280×720 → capture → TIFF is 1280×720. Confirm preview also looks right at each resolution.

## Implementation tasks (Option A) — sketch only

If WYSIWYG-with-real-crop is preferred:
1. Make `MetalPipeline` accept a crop rect, allocate `naturalPool`/`processedPool` at crop dims, set Pass-1 crop uniform from it.
2. `setCropRegion` rebuilds the pools (same teardown shape as `setResolution`).
3. Decide what the picker controls: capture (sensor) resolution, or crop resolution. Probably crop; capture stays at the sensor's best 4:3.
4. Ripple updates through `trackerPool`, `encoderPool`, `StillCapture`, `Recording`, the C++ pixel-sink pool — every dim consumer.

This is ~Stage-12-scale work. Out of scope for a UX bug fix.

## Open question for user

**Option A or Option B?** Without an answer this plan stops here.

## Touchpoints (for whichever option)

```
CameraKit/Sources/CameraKit/Capabilities.swift          # SessionCapabilities, OpenConfiguration
CameraKit/Sources/CameraKit/CameraEngine.swift          # open(), captureImage(), setCropRegion()
CameraKit/Sources/CameraKit/MetalPipeline.swift         # pool allocations + crop uniform
CameraKit/Sources/CameraKit/Constants.swift             # cropDefault*Px
CameraKit/Sources/CameraKit/StillCapture.swift          # captureSize arg + readback
CameraKit/Sources/CameraKit/ViewModel.swift             # dumpCapabilities()
CameraKit/Tests/CameraKitTests/                         # any cropRegion assertions
implementation/domain-revised/10-api-contract.md        # spec deviation log
```
