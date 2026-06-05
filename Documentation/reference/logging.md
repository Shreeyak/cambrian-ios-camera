# Logging

## CameraKitLog

*Enum*

```swift
enum CameraKitLog
```

Centralised logging for CameraKit. Off by default. Set `CameraKitLog.isEnabled = true` early in your app (e.g. `App.init`) to enable output in Console.app and the on-device log file.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### CameraKitLog.Category.consumers

```swift
case consumers
```

### CameraKitLog.Category.engine

```swift
case engine
```

### CameraKitLog.Category.interop

```swift
case interop
```

### CameraKitLog.Category.metal

```swift
case metal
```

### CameraKitLog.Category.scenePhase

```swift
case scenePhase
```

### CameraKitLog.Category.test

```swift
case test
```

### isEnabled

```swift
nonisolated(unsafe) static var isEnabled: Bool
```

### enableFileLogging()

```swift
static func enableFileLogging()
```

Opens `<Documents>/camerakit.log` for append and starts mirroring all log calls to it. Call once from `App.init()` alongside setting `isEnabled = true`.

### error(_:_:)

```swift
static func error(_ category: Category, _ msg: @autoclosure () -> String)
```

### info(_:_:)

```swift
static func info(_ category: Category, _ msg: @autoclosure () -> String)
```

### notice(_:_:)

```swift
static func notice(_ category: Category, _ msg: @autoclosure () -> String)
```

### warning(_:_:)

```swift
static func warning(_ category: Category, _ msg: @autoclosure () -> String)
```

### CameraKitLog.Category

```swift
enum Category
```
