Here's my analysis of the briefs. Each stage's needs mapped to the relevant skills:

  ---
  Stage breakdown

  ┌───────┬───────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Stage │   Type    │                                             Core technical demands                                             │
  ├───────┼───────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 05    │ MIGRATION │ OSAllocatedUnfairLock<UniformStorage>, per-frame snapshot, Metal uniform buffer write path                     │
  ├───────┼───────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 06    │ FEATURE   │ CVPixelBufferPool trio, ConsumerRegistry actor, AsyncStream<FrameSet>, Pass 4 compute shader, debug overlay UI │
  ├───────┼───────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 07    │ FEATURE   │ Metal blit readback, vImage RGBA16F→RGB8, CGImageDestination TIFF, EXIF, PHPhotoLibrary                        │
  ├───────┼───────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 08    │ MIGRATION │ Swift/C++ interop (CxxInterop mode), C-ABI PixelSinkCallbacks, OpenCV xcframework, SPM multi-target            │
  └───────┴───────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  ---
  Skills that will be genuinely useful

  Strongly recommended

  all-ios-skills:swift-concurrency
  Stages 05, 06, 08. OSAllocatedUnfairLock, AsyncStream.bufferingNewest(1), actor isolation discipline, the CAS race pattern in StillCapture. This is the
  highest-leverage skill across 3 of the 4 stages.

  swift-engineering:modern-swift
  Stages 05, 06, 08. Swift 6 strict concurrency mode, @unchecked Sendable + IOSurface contract documentation, nonisolated delivery-queue path, Sendable crossing the
  actor boundary. Overlaps with swift-concurrency but covers the strict-mode compiler posture more directly.

  all-ios-skills:photokit
  Stage 07. PHPhotoLibrary.requestAuthorization(for: .addOnly), the authorization flow, documents fallback when denied. The brief requires handling denial gracefully
   per G-09.

  all-ios-skills:swift-testing / swift-engineering:swift-testing
  All stages. Each brief has 5–8 TESTABLE tests. The stress-test harness for Stage 05 (concurrent uniform writes), the mailbox-drop test for Stage 06, and the C-ABI
  round-trip test for Stage 08 all need the swift-testing framework idioms.

  swift-engineering:ios-26-platform
  Stages 05–08. iOS 26 SDK changes (new API availability, any OSAllocatedUnfairLock changes from Synchronization framework, CVPixelBuffer API surface). Worth
  checking before assuming WWDC-vintage API shapes.

  Situationally useful

  swift-engineering:swiftui-patterns / all-ios-skills:swiftui-patterns
  Stage 06 (tracker thumbnail, debug overlay with #if DEBUG), Stage 07 (capture button, 3s banner dismiss). The brief uses .safeAreaInset(edge: .bottom) and
  observable ViewModel patterns already documented in CLAUDE.md — the skill reinforces the right idioms.

  all-ios-skills:swift-language
  Stage 08. The Swift/C++ interoperability mode (.interoperabilityMode(.Cxx)), @convention(c) function pointer typealiases, Unmanaged.passRetained → void* context
  shim. This is niche enough that the skill's reference material will save time.

  swift-engineering:swift-diagnostics
  Stage 08. CxxInterop introduces a new class of SourceKit false-positives and cross-module diagnostics. Useful as a triage reference when the build log and
  navigator diverge on the new CameraKitCxx target.

  ---
  Skills to skip

  Everything framework-specific (HealthKit, StoreKit, CloudKit, CoreBluetooth, MapKit, SpriteKit, ARKit, etc.) has no connection to any of these stages. Same for
  swift-engineering:localization, grdb, sqlite-data, haptics, storekit.

  all-ios-skills:avkit — the briefs use AVFoundation directly (AVCaptureSession, CVPixelBuffer); AVKit is the playback-layer UI framework and isn't relevant here.

  all-ios-skills:swiftdata / swift-engineering:composable-architecture — persistence here is UserDefaults-backed SettingsPersistence, not SwiftData or TCA.

  ---
  Priority order for invocation

  When you start each stage, invoke in this order:
  1. all-ios-skills:swift-concurrency (stages 05, 06, 08) or all-ios-skills:photokit (stage 07) — domain-specific primer
  2. swift-engineering:modern-swift — strict concurrency posture confirmation
  3. all-ios-skills:swift-testing — before writing the test suite

  swift-engineering:ios-26-platform and all-ios-skills:swift-language (for CxxInterop) are one-time consults at the start of their respective stages, not repeated.
