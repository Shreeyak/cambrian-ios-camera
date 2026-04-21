import Foundation

/// UserDefaults adapter keyed by "CameraKit.CameraSettings" (07-settings.md §Persistence).
///
/// All members are static so the engine actor can call them from a detached Task
/// without violating strict concurrency (UserDefaults is Sendable in practice).
enum SettingsPersistence {
    static let key = "CameraKit.CameraSettings"

    static func save(_ settings: CameraSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> CameraSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CameraSettings.self, from: data)
    }
}
