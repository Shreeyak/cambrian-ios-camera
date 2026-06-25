# ios_example_app (app host)

The SwiftUI dev-harness app that hosts the `CameraKit` package. It owns
`Info.plist`, signing, schemes, app lifecycle, and the host-only UI (camera
view, controls, capture/record/crop buttons). `CameraKit` is linked as a local
SwiftPM dependency and presented via `CameraView()`.

## Orientation lock — an app-layer responsibility

Interface-orientation **locking** lives entirely in this app target, **not** in
the `CameraKit` package. The package is orientation-policy-agnostic: a host is
free to support any orientations it likes. This app pins itself to
landscape-left via three layers:

1. **`Info.plist`** — `UISupportedInterfaceOrientations~ipad` is landscape-left
   only (plus `UIRequiresFullScreen`), so the OS never presents another
   orientation.
2. **`UIApplicationDelegateAdaptor`** (`ios_example_appApp.swift`) — returns
   `OrientationLock.declaredSupported` (`.landscapeLeft`) from
   `application(_:supportedInterfaceOrientationsFor:)`, locking the UIKit window
   regardless of device rotation. `OrientationLock` (`UI/OrientationLock.swift`)
   is the single read path for the policy so tests/HITL read one source of truth.

Both layers are app-host concerns and must not migrate into the package.

### What the package *does* own (and why it's not "orientation locking")

`CameraKit` fixes the **capture-buffer** rotation via
`videoRotationAngle = Constants.captureOrientationAngleDeg` (0°, ADR-17) on the
video **and** photo capture connections. This is not interface-orientation
policy — it only guarantees the pixel buffers (preview, recording, and the
natural/processed stills) come out consistently oriented. The natural-capture
TIFF is right-way-up precisely because the `AVCapturePhotoOutput` connection
carries the same 0° as the video connection; a host that wanted a different UI
orientation would still receive buffers in this fixed capture orientation.
