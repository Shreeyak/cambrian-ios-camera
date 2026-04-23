import OSLog

/// Centralised logging for CameraKit.
///
/// Off by default. Set `CameraKitLog.isEnabled = true` early in your app
/// (e.g. `App.init`) to enable output in Console.app and the on-device log file.
public enum CameraKitLog {
    // Master switch — write once at app init before any CameraKit actor runs.
    // nonisolated(unsafe): safe because startup write precedes all concurrent reads.
    public nonisolated(unsafe) static var isEnabled: Bool = false

    static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
    static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
    static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
    static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")

    // MARK: - File sink (Wi-Fi device, no USB console available)

    // nonisolated(unsafe): written once on init(), read from multiple queues — all after init.
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    /// Opens `<Documents>/camerakit.log` for append and starts mirroring all log
    /// calls to it.
    ///
    /// Call once from `App.init()` alongside setting `isEnabled = true`.
    public static func enableFileLogging() {
        guard
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else { return }
        let url = docs.appendingPathComponent("camerakit.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        write("=== CameraKit session started \(Date()) ===")
    }

    static func write(_ message: String) {
        guard isEnabled, let fh = fileHandle else { return }
        let line = "\(timestamp()) \(message)\n"
        fh.write(Data(line.utf8))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
