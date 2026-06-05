# Recording

## RecordingOptions

*Struct*

```swift
struct RecordingOptions
```

Options for starting a recording session.

### init(bitrateBps:fps:outputURL:photosDestination:)

```swift
init(bitrateBps: Int? = nil, fps: Int? = nil, outputURL: URL? = nil, photosDestination: PhotosDestination = .none)
```

### bitrateBps

```swift
var bitrateBps: Int?
```

Target video bitrate in bits per second.

### fps

```swift
var fps: Int?
```

Target frame rate (30).

### outputURL

```swift
var outputURL: URL?
```

Output URL resolved per `OutputPathResolver.video`. `nil` → `<Documents>/<ISO8601-timestamp>.mp4`. A name must carry the `.mp4` extension (filename-only URLs land in `<Documents>`; absolute paths inside `NSHomeDirectory()` are used as-is). A name with no extension throws `RecordingError.missingFileExtension`; a non-`.mp4` extension throws `RecordingError.unsupportedVideoFormat`; a path outside the app sandbox throws `EngineError.invalidOutputPath` — all from `startRecording`.

### photosDestination

```swift
var photosDestination: PhotosDestination
```

Whether and how to publish the finished `.mp4` to the Photos library. Defaults to `.none`; the recording lives only at `outputURL`. See `PhotosDestination` for per-case semantics.

## RecordingStart

*Struct*

```swift
struct RecordingStart
```

Result of a successful recording start.

### init(uri:displayName:)

```swift
init(uri: String, displayName: String)
```

### displayName

```swift
let displayName: String
```

Displayed filename (without path).

### uri

```swift
let uri: String
```

Destination URL as a string per `api-surface.md`.

## RecordingState

*Enum*

```swift
enum RecordingState
```

### RecordingState.finalizing

```swift
case finalizing
```

### RecordingState.idle(lastUri:)

```swift
case idle(lastUri: String?)
```

### RecordingState.recording

```swift
case recording
```

## PhotosDestination

*Enum*

```swift
enum PhotosDestination
```

Decides whether and how to publish a captured file to the Photos library. Photos failures are non-fatal: the on-disk file is always preserved when Photos can't accept it. Use the engine's `errorStream()` to surface the failure to the UI if desired.

- `.none`: Photos library is not touched. File lives only at the on-disk URL.
- `.copy`: File persists at the on-disk URL AND a copy is added to Photos (uses `PHAssetResourceCreationOptions.shouldMoveFile = false`). Use this when the caller wants the file accessible via Files.app *and* via Photos.
- `.move`: Best-effort move into Photos (`shouldMoveFile = true`). On success the on-disk file is removed from the sandbox and the URI returned by `captureImage` / `stopRecording` points to a no-longer-existent path. On failure (denied auth, Photos error, etc.) the file remains at the on-disk URL — equivalent to `.copy`'s failure path. Use this when zero sandbox footprint after capture is the goal.

### init(rawValue:)

```swift
init?(rawValue: String)
```

### PhotosDestination.copy

```swift
case copy
```

### PhotosDestination.move

```swift
case move
```

### PhotosDestination.none

```swift
case none
```
