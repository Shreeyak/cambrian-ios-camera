# Tasks

Lands after `frame-delivery-contract` (edits the new per-lane construction).
Build/test via XcodeBuildMCP `*_device` (fallback `scripts/build-summary.sh` /
`scripts/test-summary.sh`); device-only, never simulators.

## 1. Remove the streaming natural lane

- [ ] 1.1 In `MetalPipeline`, remove Pass-7n and the natural BGRA8 pools (`eightBitNaturalPool`; `naturalPool` only if it solely fed the streaming lane — keep whatever Pass-1/16F needs), and the `latestNaturalBuffer` streaming mailbox + its `.natural` yield.
- [ ] 1.2 Remove `StreamId.natural` and `SessionCapabilities.naturalTextureId`.
- [ ] 1.3 Prune dead references in `Errors.swift` (natural-lane error cases that no longer apply) and `OutputPathResolution`.

## 2. Preserve calibration inputs

- [ ] 2.1 Keep Pass-1 and `latestNaturalTex16F` (processed derives from it; calibration samples it). Verify no calibration path read the removed streaming buffer.

## 3. Repoint captureNaturalPicture

- [ ] 3.1 Re-implement `captureNaturalPicture` to convert the current 16F natural texture to BGRA8 on demand (one-shot encode at capture time), preserving the public signature and the existing "no natural frame yet" error gating.

## 4. Tests + docs + verify

- [ ] 4.1 Tests: no `StreamId.natural` exists; `captureNaturalPicture` returns a valid image with only `processed`/`tracker` streaming; calibration (WB/BB) still produces a non-default result.
- [ ] 4.2 Update DocC guides referencing the natural lane; regenerate `Documentation/`.
- [ ] 4.3 Build green on device; tests pass; `swift-format lint --strict` passes.
