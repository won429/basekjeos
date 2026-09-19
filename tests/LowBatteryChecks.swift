import Foundation

@main
struct LowBatteryChecks {
    static func main() {
        for value in 0...20 {
            precondition(LowBatteryPolicy.isLow(percentage: value, connected: false))
            precondition(!LowBatteryPolicy.isLow(percentage: value, connected: true))
        }
        precondition(!LowBatteryPolicy.isLow(percentage: 21, connected: false))
        precondition(LowBatteryPolicy.crossedThreshold(previous: 21, current: 20, connected: false, alertsEnabled: true))
        precondition(LowBatteryPolicy.crossedThreshold(previous: 23, current: 19, connected: false, alertsEnabled: true))
        precondition(!LowBatteryPolicy.crossedThreshold(previous: 20, current: 19, connected: false, alertsEnabled: true))
        precondition(!LowBatteryPolicy.crossedThreshold(previous: 21, current: 20, connected: true, alertsEnabled: true))
        precondition(!LowBatteryPolicy.crossedThreshold(previous: 21, current: 20, connected: false, alertsEnabled: false))
        precondition(AppLanguage.korean.lowBatteryStatus == "배터리 부족")
        precondition(AppLanguage.english.lowBatteryStatus == "Low Battery")
        precondition(AppLanguage.english.batteryDetailTitle(20) == "20% Battery")
        print("Low battery passed: 20% boundary, skipped percentages, charging, alerts off and localization")
    }
}
