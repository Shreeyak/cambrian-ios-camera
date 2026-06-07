## Context

This change reshapes CameraKit's delivery surface onto the `frame-transport`
vocabulary. Today: `subscribe(stream:) -> AsyncStream<FrameSet>` hardwired to
`.bufferingNewest(1)`, delivering all lanes bundled; errors go to a separate
`errorStream()`; the frame stream finishes silently on failure (looks like clean
EOF). `PixelSink.swift` holds both the Swift consumer registry (keep) and the C-ABI
sink (remove). Authoritative design: `docs/03-authoritative-frame-transport-rework.md`
§3.2–3.4, 3.9–3.11, 3.13.

## Goals / Non-Goals

**Goals:**
- Per-lane `AsyncThrowingStream<Frame>` with a per-lane `BufferingPolicy`.
- One vocabulary: `processed → primary`.
- One termination model; camera death is visible; CameraKit owns terminality.
- A holdable `lockedPixels()` lease; tracker genuinely absent when off.
- Remove `FrameSet` and the C-ABI sink.

**Non-Goals:**
- The `Frame`/`PixelHandle` type definitions (`frame-transport-package`).
- The camera's `CameraFrameMetadata` fields and 3 Hz JSON (`frame-metadata-signals`).
- Cutting the natural lane (`remove-natural-lane`).
- Repairing the AppCxx/Flutter demos that consume the C-ABI path (accepted broken).

## Decisions

- **`AsyncThrowingStream<Frame>` per lane, not `AsyncStream<FrameSet>`.** Separate
  streams are required by the dual-rate consumer (tracker every frame, primary
  gated). A single bundled element forces a shared cadence. Alternative (keep
  `FrameSet`, let consumer demux) rejected: it pins unused lanes' pool buffers and
  cannot carry per-lane policy.
- **Buffering policy per subscription.** `latestWins` for `.primary`,
  `keepBuffered(depth:)` for `.tracker`. The old fixed `.bufferingNewest(1)` cannot
  express a buffered every-frame motion lane.
- **CameraKit decides terminal vs transient.** CameraKit already retries/re-arms;
  the lane stream stays open across transient faults and throws only on
  `CameraError.isFatal`. This keeps the consumer's single `for try await` loop as
  the one place EOF (finish) and failure (throw) are observed. `errorStream()` stays
  for non-fatal observability.
- **`lockedPixels()` returns a lease, not a scoped closure.** The consumer holds
  pixels across a bounded pipeline stage (~300 ms ECC); a scoped `withLockedBytes`
  unlocks at closure exit — far too early. The lease (a `PixelHandle`) holds the
  lock for its lifetime.
- **Tracker genuinely absent.** Remove `trackerForSet = trackerBuf ?? processedForSet`;
  an unsubscribed tracker yields nothing rather than a mislabeled full-res buffer.
- **Remove the C-ABI sink, split `PixelSink.swift`.** The call-scoped IOSurface
  cannot support a hold; the Swift registry is strictly better. Split the file so
  the registry survives the C-ABI deletion.

## Risks / Trade-offs

- **Breaking API + Flutter Pigeon regen** → Mitigation: no external consumers yet;
  preview already uses the full-res lane, so only the name changes.
- **Demos break** → Accepted by owner; not repaired in this change.
- **Terminal-vs-transient misclassification could hide a fatal fault or kill a
  recoverable stream** → Mitigation: gate strictly on the existing
  `CameraError.isFatal`; covered by tests for both paths.

## Migration Plan

Land after `frame-transport-package`. Sequence: introduce per-lane stream +
policy + `lockedPixels()`; rename `processed→primary` and regen Pigeon; switch to
throwing termination; remove tracker fallback; remove `FrameSet` and the C-ABI
sink (split `PixelSink.swift`). The natural-lane cut (`remove-natural-lane`) lands
after this on the new `Frame` shape.

## Open Questions

- None blocking. (Whether to fully retire `CameraKitCxx` once the sink is gone —
  the PixelSink pool seam was its main content — is deferred; this change removes
  the sink, not necessarily the empty target.)
