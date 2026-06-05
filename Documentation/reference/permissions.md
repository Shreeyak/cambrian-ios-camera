# Permissions

## CameraPermissionStatus

*Enum*

```swift
enum CameraPermissionStatus
```

Permission status for camera + Photos library. Cross-platform-neutral enum mapping iOS `AVAuthorizationStatus` / `PHAuthorizationStatus` to a single shape the Pigeon contract can carry.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### CameraPermissionStatus.authorized

```swift
case authorized
```

### CameraPermissionStatus.denied

```swift
case denied
```

### CameraPermissionStatus.notDetermined

```swift
case notDetermined
```

### CameraPermissionStatus.restricted

```swift
case restricted
```
