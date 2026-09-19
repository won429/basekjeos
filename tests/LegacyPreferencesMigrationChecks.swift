import Foundation

@main
struct LegacyPreferencesMigrationChecks {
    static func main() {
        let legacy: [String: Any] = [
            "playerPresentationStyle": "dynamicIsland", "waveformMode": "live",
            "appLanguage": "ko", "batteryAlertInterval": 1,
            "NSStatusItem VisibleCC Item-0": false,
            "NSStatusItem Preferred Position NotchMusic.MainStatusItem": 322
        ]
        let migrated = LegacyPreferencesMigration.valuesToMigrate(legacy: legacy, current: [:])
        precondition(migrated.count == 4)
        precondition(migrated["appLanguage"] as? String == "ko")
        precondition(migrated["waveformMode"] as? String == "live")
        precondition(migrated["playerPresentationStyle"] as? String == "dynamicIsland")
        precondition(migrated["batteryAlertInterval"] as? Int == 1)
        let preserved = LegacyPreferencesMigration.valuesToMigrate(
            legacy: legacy, current: ["appLanguage": "en", "batteryAlertInterval": 0])
        precondition(preserved.count == 2)
        precondition(preserved["appLanguage"] == nil && preserved["batteryAlertInterval"] == nil)
        precondition(LegacyPreferencesMigration.valuesToMigrate(legacy: [:], current: [:]).isEmpty)
        print("Preference migration passed: four settings, no status metadata, existing values preserved")
    }
}
