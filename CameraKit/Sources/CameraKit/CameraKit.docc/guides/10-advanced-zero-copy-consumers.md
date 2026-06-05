# Advanced: zero-copy consumers

Consuming raw frame sets with zero copy, from Swift or native code.

Assumes you have read <doc:04-preview> and <doc:09-observing-state-and-errors>.

## When you need this

Most integrations do not. Preview (<doc:04-preview>) and capture
(<doc:05-capturing-stills-and-video>) cover the common cases. Reach for a
consumer only when you must process every frame's pixels yourself — for example a
computer-vision pipeline — without copying them.

## The consumer registry

Frame consumers attach through ``CameraEngine/consumers``, a
``ConsumerRegistry``. Subscribe per lane with ``StreamId`` (``StreamId/natural``,
``StreamId/processed``, ``StreamId/tracker``).

## Swift consumers

``ConsumerRegistry/subscribe(stream:)`` returns an `AsyncStream<FrameSet>`:

```swift
for await frame in engine.consumers.subscribe(stream: .processed) {
    // inspect frame.natural / frame.processed / frame.tracker and metadata
}
```

## Native callbacks

Native (C/C++) consumers register a callback set instead:

```swift
let token = try engine.consumers.registerCallback(stream: .processed, callbacks: callbacks)
// ... later ...
engine.consumers.unregister(token: token)
```

``ConsumerRegistry/registerCallback(stream:callbacks:)`` takes a
``PixelSinkCallbacks`` (``PixelSinkCallbacks/onFrame``,
``PixelSinkCallbacks/onOverwrite``, ``PixelSinkCallbacks/onError``, and a
``PixelSinkCallbacks/context`` pointer) and returns a ``ConsumerToken``. Always
``ConsumerRegistry/unregister(token:)`` when done.

## FrameSet contents

Each ``FrameSet`` is one atomic, multi-lane payload:
``FrameSet/frameNumber``, ``FrameSet/captureTime``, the three lane buffers
``FrameSet/natural`` / ``FrameSet/processed`` / ``FrameSet/tracker``,
``FrameSet/capture`` (``CaptureMetadata``), ``FrameSet/processing``
(``ProcessingMetadata``), ``FrameSet/blurScore``, and ``FrameSet/trackerQuality``
(``TrackerQuality``).

## Delivery metrics and back-pressure

``ConsumerRegistry/metricsStream()`` emits ``FrameDeliveryStats`` per lane —
``FrameDeliveryStats/producedByLane``, ``FrameDeliveryStats/deliveredByLane``,
``FrameDeliveryStats/droppedByLane``, and pool-exhaustion counters. A slow
consumer causes frames to be dropped rather than queued: delivery is
newest-wins, so a consumer that cannot keep up sees gaps, not backlog. Watch the
drop counters to size your processing budget.

## Reference integration

The example app renders via the preview path and does not register a raw
consumer; use ``ConsumerRegistry`` directly as shown above.
