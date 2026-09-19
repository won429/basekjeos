import Foundation

enum BatteryAlertInterval: Int, CaseIterable {
    case one = 1, five = 5, ten = 10, twenty = 20, thirty = 30
    case forty = 40, fifty = 50, off = 0

    static let defaultsKey = "batteryAlertInterval"

    var title: String { self == .off ? "끔" : "\(rawValue)%단위" }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: defaultsKey) != nil else { return .ten }
        return Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .ten
    }
}

// Track the furthest level reached in a power session so small battery-estimate
// fluctuations cannot repeatedly announce the same threshold.
struct BatteryLevelTracker {
    private var extreme: Int?
    private var connected: Bool?

    mutating func reset() {
        extreme = nil
        connected = nil
    }

    mutating func update(percentage: Int, connected: Bool, interval: BatteryAlertInterval) -> Bool {
        let current = min(max(percentage, 0), 100)
        guard self.connected == connected, let previous = extreme else {
            self.connected = connected
            extreme = current
            return false
        }
        extreme = connected ? max(previous, current) : min(previous, current)
        let step = interval.rawValue
        guard step > 0 else { return false }
        // Charger connection/disconnection is handled separately by PowerStateMonitor.
        // Percentage milestones (including 100%) are silent while plugged in.
        guard !connected else { return false }
        return current < previous && (current + step - 1) / step < (previous + step - 1) / step
    }
}
