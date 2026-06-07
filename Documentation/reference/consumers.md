# Consumers

## ConsumerRegistry

*Actor*

```swift
actor ConsumerRegistry
```

Swift facade for the per-lane consumer fan-out. `subscribe(stream:buffering:)` returns an `AsyncThrowingStream<Frame>` for one lane. Actor isolation governs `subscribe` (a cold path). Publication runs on the delivery queue via a `nonisolated` `yield(_:stream:)` — no actor hop on the frame clock.

### init()

```swift
init()
```

### subscribe(stream:buffering:)

```swift
func subscribe(stream: StreamId, buffering: BufferingPolicy) -> AsyncThrowingStream<Frame, Error>
```

Returns an `AsyncThrowingStream<Frame>` for one lane with the given ``FrameTransport/BufferingPolicy``. The stream finishes cleanly on `close()` and finishes by THROWING only when CameraKit judges a fault terminal (`CameraError.isFatal`, via ``failAllLanes(_:)``). Transient faults leave the stream open. Termination of the consuming task removes the subscriber synchronously via `onTermination`.
