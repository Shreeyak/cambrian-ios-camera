## Why

CameraKit's frame delivery is shaped for a single bundled `FrameSet` with a fixed
global buffering policy and a side error channel — none of which fits the
co-designed stitcher consumer. The consumer needs **per-lane streams at
independent rates**, a **buffering policy per lane** (the motion lane needs a
buffered, every-frame stream the current `.bufferingNewest(1)` cannot express), a
**single termination model** where camera death is visible (not a silent EOF), and
a **holdable, self-describing pixel lease**. We reshape the delivery surface onto
the `frame-transport` vocabulary now, before consumers exist.

## What Changes

- **BREAKING: per-lane delivery yields `Frame`, not `FrameSet`.**
  `subscribe(stream:buffering:)` returns `AsyncThrowingStream<Frame>` for one lane,
  carrying only that lane's `PixelHandle` (no longer pinning the other lane's pool
  buffer). `FrameSet` (and its `Hashable` conformance) is removed.
- **BREAKING: rename `StreamId.processed → .primary`** for one vocabulary across
  producer and consumer. Ripples into the Flutter Pigeon `StreamId` enum (Swift/
  Dart/Kotlin mirrors), the Pigeon DSL, and `TextureBridge`.
- **Per-lane `BufferingPolicy`.** `.primary` → `latestWins`; `.tracker` →
  `keepBuffered(depth:)`. Replaces the hardwired global `.bufferingNewest(1)`.
- **Terminate the lane stream WITH the error, CameraKit deciding terminality.**
  CameraKit recovers from transient faults without ending the stream; only an error
  CameraKit judges terminal (`CameraError.isFatal`) finishes the stream by throwing.
  `errorStream()` remains for observability.
- **`lockedPixels() -> PixelHandle`** — a lease-returning IOSurface borrow helper on
  the lane buffer (not a scoped `withLockedBytes` closure, which unlocks too early
  for a pipeline hold).
- **Fix the tracker-fallback landmine:** the tracker lane is genuinely absent when
  unsubscribed/unrendered — never substitute the full-res primary buffer under the
  `.tracker` label.
- **Tracker resolution is consumer-specified** via `OpenConfiguration.trackerHeight`
  (the contract: one consumer-side `motionInputSize` drives it; a wrong size is a
  configuration error, not a silent re-resize).
- **BREAKING: remove the C-ABI `PixelSink` / `PixelSinkPool` path** (the
  `CameraKitCxx` sink, its `CameraKitInterop` bridge, the C-ABI dispatch in
  `CameraEngine`). Its IOSurface is call-scoped and cannot support a bounded hold.
  The Swift `subscribe()` path supersedes it. **The AppCxx demos and Flutter demo
  that consume it are left broken (accepted).**

## Capabilities

### New Capabilities

- `frame-delivery`: how CameraKit delivers frames to consumers — per-lane
  `AsyncThrowingStream<Frame>`, per-lane buffering policy, the `.primary`/`.tracker`
  lane vocabulary, throwing-stream termination with CameraKit-owned terminal-vs-
  transient judgement, the `lockedPixels()` lease, the consumer-specified tracker
  size contract, and the removal of `FrameSet` and the C-ABI sink.

### Modified Capabilities

<!-- None — openspec/specs/ is empty. -->

## Impact

- **CameraKit API (BREAKING):** `subscribe` signature + element type; `StreamId`
  rename; removal of `FrameSet` and the C-ABI `PixelSink`/`PixelSinkPool`; new
  `lockedPixels()`.
- **CameraKit internals:** `PixelSink.swift` split (keep the Swift consumer
  registry; drop the C-ABI sink); `MetalPipeline` lane yield + tracker-absent fix;
  `CameraEngine` C-ABI dispatch removal; `CameraKitCxx` target shrink; `Errors`
  (`isFatal` terminal semantics).
- **Flutter:** Pigeon `StreamId` regen (`processed→primary`), `TextureBridge`.
- **Accepted breakage:** `ios_example_app` AppCxx demos (Canny/Counter,
  `DisplayViewModel`, `Stage08CannyTests`, `CABIParityTests`) and the Flutter demo.
- **Depends on:** `frame-transport-package`. **Authoritative design:** §3.2–3.4,
  3.9–3.11, 3.13.
