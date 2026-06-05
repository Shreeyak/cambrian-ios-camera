# Session State

## SessionState

*Enum*

```swift
enum SessionState
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### SessionState.closed

```swift
case closed
```

### SessionState.error

```swift
case error
```

### SessionState.interrupted

```swift
case interrupted
```

Routine `AVCaptureSession` interruption (Control Center, Split View / Stage Manager, phone call). Distinct from `.error` — auto-resumes on `interruptionEndedNotification`.

### SessionState.opening

```swift
case opening
```

### SessionState.paused

```swift
case paused
```

### SessionState.recovering

```swift
case recovering
```

### SessionState.streaming

```swift
case streaming
```

## StreamId

*Enum*

```swift
enum StreamId
```

### init(rawValue:)

```swift
init?(rawValue: String)
```

### StreamId.natural

```swift
case natural
```

### StreamId.processed

```swift
case processed
```

### StreamId.tracker

```swift
case tracker
```
