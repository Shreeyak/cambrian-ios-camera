# cambrian_ios_camera

Flutter plugin wrapping CameraKit for iOS-only camera access.

For full design: `docs/superpowers/specs/2026-05-22-flutter-plugin-phase-b-design.md`.
For lifecycle contract: `CameraKit/README.md`.

## Quick start

```yaml
dependencies:
  cambrian_ios_camera:
    git:
      url: https://github.com/Shreeyak/cambrian-ios-camera.git
      path: flutter
      ref: v1.0.0
```

```dart
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

final engine = CameraEngine();
final caps = await engine.open();
final textureId = await engine.createPreviewTexture(stream: StreamId.processed);
// ...build a Texture(textureId: textureId) into your widget tree
await engine.close();
```

Android: every host method throws `PlatformException(code: 'iOSOnly')`.

## Testing

- Dart unit: `flutter test` (from `flutter/`)
- Swift adapter: `example/scripts/test-swift-adapter.sh` (physical iPad)
- Integration: `example/scripts/test-integration.sh` (physical iPad)

Phase B's lifecycle correctness depends on `CameraKit/Tests/CameraKitTests/LifecycleTests.swift`
remaining green.
