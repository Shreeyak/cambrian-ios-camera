## Why

CameraKit (producer, iOS-only) and the EvaScan stitcher (consumer, macOS + iOS)
today speak two different frame vocabularies — CameraKit's `FrameSet` and
EvaScan's `NextFrame`/`FrameBuffer` — bridged by an adapter that re-packs fields
and recomputes stride as `width*4` (a latent row-corruption bug). Before CameraKit
has external consumers, we collapse both onto **one shared element vocabulary**.
That vocabulary cannot live inside CameraKit (its AVFoundation imports make it
iOS-only, and EvaScan's macOS build must reference the element type without pulling
AVFoundation), so it needs a platform-neutral home.

## What Changes

- **New SPM product `FrameTransport`** in this repo: a platform-neutral target
  (iOS + macOS; CoreVideo/IOSurface/Foundation only, **no AVFoundation**) importable
  standalone without the rest of CameraKit.
- **New shared types:** `Frame` (lane + index + timestampNs + pixels + metadata),
  `PixelHandle` (a `final class` carrying baseAddress/width/height/bytesPerRow/format
  and releasing its IOSurface lock on `deinit`), `FrameMetadata` (marker protocol
  for producer-specific concrete metadata), and the enums `Lane { primary, tracker }`,
  `PixelFormat { bgra8 }`, `BufferingPolicy { blocking, latestWins, keepBuffered(depth) }`.
- **CameraKit gains a dependency** on `FrameTransport` (it will produce `Frame`s in
  a later change); the Flutter plugin inherits the transitive dependency.
- This change introduces the **types only**. Wiring CameraKit's delivery to emit
  `Frame` is `frame-delivery-rework`; the camera's concrete `CameraFrameMetadata`
  is `frame-metadata-signals`.

## Capabilities

### New Capabilities

- `frame-transport`: the platform-neutral shared frame vocabulary — the `Frame`
  envelope, the self-describing `PixelHandle` lease, the `FrameMetadata` marker
  protocol, and the `Lane`/`PixelFormat`/`BufferingPolicy` enums — and the
  build/layering invariants that keep it importable on macOS without AVFoundation.

### Modified Capabilities

<!-- None — openspec/specs/ is empty; this is the foundational vocabulary. -->

## Impact

- **New package/product:** `FrameTransport` (SPM target + product in
  `Package.swift`).
- **CameraKit:** new dependency edge `CameraKit → FrameTransport`. No behavior
  change yet (types are not yet produced).
- **Downstream:** EvaScan (`mac-stitch-video`) will depend on
  `.product("FrameTransport", package: "cambrian-ios-camera")` — tracked in that
  repo, out of scope here.
- **Authoritative design:** `docs/03-authoritative-frame-transport-rework.md` §2.
