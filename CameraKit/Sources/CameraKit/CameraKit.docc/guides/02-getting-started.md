# Getting started

A first working integration, from installation to a live preview.

Assumes you have read <doc:01-overview>.

## Install

Add CameraKit with Swift Package Manager. In Xcode: **File → Add Package
Dependencies** and enter the repository URL, or add it to `Package.swift`:

```swift
.package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", from: "1.2.0")
```

Then depend on the `CameraKit` product and `import CameraKit`.

## Permissions

Camera capture requires a usage description. Add `NSCameraUsageDescription` to
your app's `Info.plist`. To save captures to the Photos library, also add
`NSPhotoLibraryAddUsageDescription`.

``CameraEngine/open(configuration:)`` requests camera authorization as part of
opening; you do not have to request it first. The standalone
``CameraEngine/cameraPermissionStatus()`` and
``CameraEngine/requestCameraPermission()`` exist only for pre-flighting your own
UI (for example, showing a rationale screen before the system prompt).

## The order of operations

Every integration follows the same sequence:

1. **Construct** the engine with the launch phase.
2. **Open** the session and read its capabilities.
3. **Preview** the chosen lane.
4. **Capture or record** as the user acts.
5. **Close** the session when done.

Forwarding the app lifecycle (step between open and close) is mandatory and is
covered in <doc:03-lifecycle>.

## Construct the engine

``CameraEngine`` requires an `initialPhase` — there is no default. Pass the phase
your app launches in; pass `.background` when unsure. A default of `.active`
would be a privacy trap: if `open()` ran before the host forwarded its first
phase, the camera would turn on with no visible UI.

```swift
let engine = CameraEngine(initialPhase: .background)
```

## Open and read capabilities

``CameraEngine/open(configuration:)`` returns ``SessionCapabilities`` describing
the active resolution, supported sizes, and the valid ranges for every setting.
Read capabilities before driving settings (<doc:06-controlling-the-camera>).

```swift
let capabilities = try await engine.open()
```

## Show a preview and forward lifecycle

Render a preview lane (<doc:04-preview>) and forward every lifecycle transition
(<doc:03-lifecycle>). Both are required for a correct, privacy-respecting
integration.

## Close

```swift
await engine.close()
```

## Common mistakes

- **Subscribe to streams before or around `open()`.** The event streams do not
  replay history (<doc:09-observing-state-and-errors>); subscribing afterwards
  misses early events.
- **Do not default `initialPhase` to `.active`.** State the real launch phase,
  or `.background` when unsure.

## Reference integration

`ios_example_app/ios_example_app/UI/ViewModel.swift` constructs the engine with
`initialPhase: .background`, opens it, and reads capabilities;
`UI/CameraView.swift` wires the preview and lifecycle.
