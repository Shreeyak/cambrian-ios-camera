# Consumers

## ConsumerRegistry

*Actor*

```swift
actor ConsumerRegistry
```

Swift facade for the consumer fan-out. `subscribe(stream:)` uses `AsyncStream` directly. `registerCallback(stream:callbacks:)` inserts a C++ pool entry. `yield(_:stream:)` dispatches to both paths. Actor isolation governs subscribe/unregister/registerCallback (cold paths). Publication runs on the delivery queue via a `nonisolated` `yield(_:stream:)` — no actor hop on the frame clock.

### init()

```swift
init()
```

### metricsStream()

```swift
func metricsStream() -> AsyncStream<FrameDeliveryStats>
```

A single `AsyncStream<FrameDeliveryStats>` aggregating Swift-side per-lane drop counters and the C++ pool's `mailbox_overwrite_count` atomics. The C++ pool drives the cadence — one emission per `FPS_MEASUREMENT_WINDOW_FRAMES` — via its metrics callback; each sample carries per-lane *deltas*, not cumulative counts. Cached: re-callers receive the same stream.

### registerCallback(stream:callbacks:)

```swift
func registerCallback(stream: StreamId, callbacks: PixelSinkCallbacks) throws -> ConsumerToken
```

Registers a C-ABI consumer in the C++ pool.

### subscribe(stream:)

```swift
func subscribe(stream: StreamId) -> AsyncStream<FrameSet>
```

Termination of the stream (consuming `Task` cancelled or returned) removes the subscriber synchronously via `onTermination`.

### unregister(token:)

```swift
func unregister(token: ConsumerToken)
```

Finishes the subscriber's continuation (Swift lane) or removes the C++ pool entry. Same recursive-lock concern as `release()`: extract the continuation under lock, finish it once the lock is released.

## ConsumerToken

*Struct*

```swift
struct ConsumerToken
```

Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and `.registerCallback(stream:callbacks:)`.

### init(id:stream:)

```swift
init(id: UInt64, stream: StreamId)
```

### id

```swift
let id: UInt64
```

### stream

```swift
let stream: StreamId
```

## PixelSinkCallbacks

*Struct*

```swift
struct PixelSinkCallbacks
```

### init(onFrame:onOverwrite:onError:context:)

```swift
init(onFrame: OnFrame?, onOverwrite: OnOverwrite?, onError: OnError?, context: UnsafeMutableRawPointer?)
```

### context

```swift
let context: UnsafeMutableRawPointer?
```

### onError

```swift
let onError: OnError?
```

### onFrame

```swift
let onFrame: OnFrame?
```

### onOverwrite

```swift
let onOverwrite: OnOverwrite?
```

### PixelSinkCallbacks.OnError

```swift
typealias OnError = @convention(c) (_ context: UnsafeMutableRawPointer?, _ code: Int32) -> Void
```

### PixelSinkCallbacks.OnFrame

```swift
typealias OnFrame = @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32, _ frameNumber: UInt64, _ presentationTimeNs: Int64, _ surface: UnsafeMutableRawPointer?) -> Void
```

### PixelSinkCallbacks.OnOverwrite

```swift
typealias OnOverwrite = @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32) -> Void
```
