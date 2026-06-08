## Context

The natural texture has two identities (`MetalPipeline.swift`): the **internal 16F
working texture** `latestNaturalTex16F` (Pass-1 output, `:130`/`:708`), sampled by
WB/BB calibration (`dispatchCenterPatchOnNatural`) — load-bearing; and the
**streaming natural lane** — Pass-7n BGRA8 conversion (`:594-604`) →
`latestNaturalBuffer` (`:707`) → `FrameSet.natural` → `yield(.natural)` (`:694`),
plus `StreamId.natural` and `SessionCapabilities.naturalTextureId`. The processed
lane derives from the same Pass-1 natural texture via Pass-2, so Pass-1 must stay.
`captureNaturalPicture` (`CameraEngine.swift:1394`, `StillCapture.swift`) currently
reads the streaming `latestNaturalBuffer` mailbox — so naïvely cutting the lane
breaks still capture, and keeping Pass-7n just for the mailbox saves no GPU pass.

## Goals / Non-Goals

**Goals:** remove the streaming natural lane end-to-end on the Swift side; keep
`captureNaturalPicture` (on-demand 16F readback); keep calibration; actually save
the per-frame GPU pass + pooled buffer.

**Non-Goals:** the two-lane `Frame` shape (`frame-delivery-contract`); the
Flutter-side `StreamId.natural`/`naturalTextureId` removal + `TextureBridge`
(`flutter-single-preview`); metadata (`frame-metadata-signals`).

## Decisions

### D1. Cut the streaming lane, keep Pass-1 + 16F
Remove Pass-7n, `naturalPool`/`eightBitNaturalPool` (the natural BGRA8 path),
`latestNaturalBuffer`, the `.natural` yield, `StreamId.natural`,
`SessionCapabilities.naturalTextureId`. Keep Pass-1 and `latestNaturalTex16F`
(processed derives from it; calibration samples it).

### D2. `captureNaturalPicture` → on-demand still (IMPLEMENTED: ISP one-shot)
The natural still is produced on demand, not from a per-frame streaming buffer —
so cutting the streaming lane saves the per-frame Pass-7n cost regardless.

**Implemented (user Decision, 2026-06-08): keep the existing ISP one-shot path.**
`captureNaturalPicture` shoots `session.capturePhoto()` (full-sensor) and runs
`MetalPipeline.gradeOneShot` (Pass-1 crop + Pass-2 grade + BGRA8 convert) at
capture time — full resolution, public API + running-session gating unchanged.
This retains `eightBitNaturalPool` + `gradeOneShot` (one-shot only, no per-frame
cost). Note the still is GRADED (matches the preview), tagged `laneTag:"natural"`.

- *Alternative considered & rejected:* convert the preserved internal 16F natural
  texture (`latestNaturalTex16F`, Pass-1 output, UNGRADED) to BGRA8 on demand.
  This matches the literal "natural" (ungraded) semantics and would let us delete
  `gradeOneShot`/`eightBitNaturalPool`, but it caps the still at output/preview
  resolution (~1440²) vs. full sensor. The user chose full-res over ungraded.
- *Alternative considered & rejected:* keep a low-rate natural BGRA8 mailbox —
  reintroduces a near-per-frame pass and defeats the efficiency goal.

### D3. Sequence after `frame-delivery-contract`
`FrameSet.natural` is removed as part of the `Frame` migration; this change lands
after the contract change so it edits the new per-lane construction, not the old
`FrameSet`.

## Risks / Trade-offs

- **[Cutting the wrong texture breaks calibration]** → explicit: preserve
  `latestNaturalTex16F` + Pass-1; calibration test asserts a non-default result
  after removal.
- **[On-demand readback latency for `captureNaturalPicture`]** → one-shot encode on
  capture; acceptable for a still (not a hot path); reuses the existing still
  readback machinery.
- **[Dangling references to `StreamId.natural`/`naturalTextureId`]** → grep sweep;
  remove `Errors` natural-lane cases that no longer apply; compiler catches the rest.

## Migration Plan

After `frame-delivery-contract`. Steps: remove Pass-7n + natural BGRA8 pools +
`latestNaturalBuffer`; repoint `captureNaturalPicture` to 16F readback; remove
`StreamId.natural` + `naturalTextureId`; prune dead `Errors`/`OutputPathResolution`
references; update DocC. Device-test: calibration passes, `captureNaturalPicture`
returns valid image, no `natural` lane remains.

## Source coverage

Covers doc `02` §A.2 "cut the natural lane" and the captureNaturalPicture-survival
constraint; doc `01` "Cut the natural lane entirely". The Flutter-side removal
(`StreamId` Pigeon enum, `naturalTextureId`, `TextureBridge`) is in
`flutter-single-preview`. (User decision: cut only the streaming lane; keep
`captureNaturalPicture` + the internal 16F texture.)
