import Foundation

enum LegacyPreferencesMigration {
    static let legacyDomain = "com.notchmusic.player"
    private static let migrationKey = "didMigrateStandalonePreferences"
    private static let userSettingKeys = [
        "playerPresentationStyle", "waveformMode", "appLanguage", "batteryAlertInterval"
    ]

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in valuesToMigrate(legacy: legacy, current: defaults.dictionaryRepresentation()) {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
    }

    static func valuesToMigrate(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        // Migrate preferences, never macOS status-item visibility/ownership data.
        // Existing settings in the new app always win, including 0 (alerts off).
        var result: [String: Any] = [:]
        for key in userSettingKeys where current[key] == nil {
            if let value = legacy[key] { result[key] = value }
        }
        return result
    }
}
