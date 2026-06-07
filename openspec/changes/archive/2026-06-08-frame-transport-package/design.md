## Context

CameraKit is iOS-only (AVFoundation). The EvaScan stitcher is macOS + iOS and its
platform-neutral core references the frame element type through its `FrameSource`
protocol. CLAUDE.md forbids CameraKit depending on EvaScan's `StitchProtocols`, and
a camera repo depending on a stitcher repo is backwards layering. The shared
element type therefore cannot live in CameraKit (breaks EvaScan's macOS build) nor
in EvaScan (breaks the layering rule). It needs a third, platform-neutral home.
Full rationale: `docs/03-authoritative-frame-transport-rework.md` §2.

## Goals / Non-Goals

**Goals:**
- Define the shared vocabulary (`Frame`, `PixelHandle`, `FrameMetadata`, `Lane`,
  `PixelFormat`, `BufferingPolicy`) in one platform-neutral place.
- Build on iOS and macOS; importable without the rest of CameraKit.
- Self-describing pixels (kill `width*4`) and a holdable lease (support the
  consumer's bounded ECC hold).

**Non-Goals:**
- Producing `Frame`s from CameraKit's delivery path (that is `frame-delivery-rework`).
- The camera's concrete `CameraFrameMetadata` fields (that is `frame-metadata-signals`).
- EvaScan-side adoption (tracked in `mac-stitch-video`).

## Decisions

- **Separate SPM product, not a sub-type of CameraKit.** A neutral product is the
  only option that compiles on macOS while remaining importable by an iOS camera
  package. Alternatives rejected: (a) types inside CameraKit — breaks EvaScan macOS
  build; (b) a standalone third repo — adds a repo to version/pin in lockstep for no
  benefit over a product in this repo; (c) congruent copies + adapter — reintroduces
  drift and the field-copy the unification is meant to delete.
- **`PixelHandle` is a `final class`, not a struct.** "Releases on deinit" requires
  a deinit, which structs lack. `@unchecked Sendable` is sound: `baseAddress` is
  immutable after init, the writer (GPU/decoder) finished before delivery
  (single-writer), and concurrent read-only consumers of an immutable buffer are
  safe.
- **`FrameMetadata` is a marker protocol with per-producer concretes**, not a
  struct with common fields. Producer-specific decision data (`settled`,
  `groundTruthPose`, …) belongs on the concrete type; the universal envelope stays
  agnostic. Consumers downcast at a source-specific boundary.
- **`bytesPerRow` is mandatory and authoritative.** Carrying the real IOSurface
  stride on the handle removes the consumer's `width*4` assumption at its root.
- **`BufferingPolicy` is an enum, not a Bool.** It must express
  `keepBuffered(depth:)` for the every-frame motion lane, which a `prefersLatestWins`
  Bool cannot.

## Risks / Trade-offs

- **New dependency edge for the Flutter plugin** (transitively via CameraKit) →
  Mitigation: the product is tiny and neutral; no AVFoundation, no runtime cost.
- **`@unchecked Sendable` on `PixelHandle`** → Mitigation: documented single-writer
  invariant; the lease holds the lock for the buffer's full lifetime; pool sizing
  absorbs concurrent display/consumer holds.
- **A neutral package in a camera-named repo can read oddly to non-camera consumers**
  → Mitigation: the product name is `FrameTransport` (not camera-named); it is the
  shared transport currency that file/synthetic sources also use.

## Migration Plan

Additive only: introduce the product and types; add the `CameraKit → FrameTransport`
dependency. No existing API changes in this change. Subsequent changes
(`frame-delivery-rework`, `frame-metadata-signals`, `remove-natural-lane`) migrate
the delivery surface onto these types.

## Open Questions

- None blocking. (`PixelFormat.gray8` for a future grayscale tracker is reserved
  but explicitly out of scope.)
