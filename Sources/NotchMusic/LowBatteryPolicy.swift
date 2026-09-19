import Foundation

enum LowBatteryPolicy {
    static func isLow(percentage: Int, connected: Bool) -> Bool {
        !connected && percentage <= 20
    }

    static func crossedThreshold(previous: Int, current: Int, connected: Bool,
                                 alertsEnabled: Bool) -> Bool {
        alertsEnabled && previous > 20 && isLow(percentage: current, connected: connected)
    }
}
