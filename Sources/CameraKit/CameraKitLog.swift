import OSLog

/// Centralised logging for CameraKit.
///
/// Off by default. Set `CameraKitLog.isEnabled = true` early in your app
/// (e.g. `AppDelegate.application(_:didFinishLaunchingWithOptions:)`) to
/// enable unified-logging output visible in Console.app and Xcode's debug console.
public enum CameraKitLog {
    // Master switch — write once at app init before any CameraKit actor runs.
    // nonisolated(unsafe): safe because startup write precedes all concurrent reads.
    public nonisolated(unsafe) static var isEnabled: Bool = false

    static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
    static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
    static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
    static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")
}
