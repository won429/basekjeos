import Foundation

@main
struct BatteryLevelTrackerChecks {
    static func main() {
        func check(_ levels: [Int], connected: Bool, interval: BatteryAlertInterval, expected: [Int]) {
            var tracker = BatteryLevelTracker()
            let actual = levels.filter {
                tracker.update(percentage: $0, connected: connected, interval: interval)
            }
            precondition(actual == expected, "\(interval): \(actual) != \(expected)")
        }
        check([85, 81, 80, 80, 79, 81, 80, 71, 70], connected: false, interval: .ten, expected: [80, 70])
        check([75, 79, 80, 79, 80, 89, 90, 100, 100], connected: true, interval: .ten, expected: [])
        check([91, 69, 68], connected: false, interval: .ten, expected: [69])
        check([69, 91, 92], connected: true, interval: .ten, expected: [])
        check([80, 79, 0], connected: false, interval: .off, expected: [])
        check([20, 90, 100], connected: true, interval: .off, expected: [])
        for interval in BatteryAlertInterval.allCases where interval != .off {
            let step = interval.rawValue
            check(Array(stride(from: 100, through: 0, by: -1)), connected: false, interval: interval,
                  expected: (0..<100).reversed().filter { $0 % step == 0 })
            check(Array(0...100), connected: true, interval: interval,
                  expected: [])
        }
        var tracker = BatteryLevelTracker()
        precondition(!tracker.update(percentage: 85, connected: false, interval: .ten))
        precondition(!tracker.update(percentage: 80, connected: true, interval: .ten))
        precondition(!tracker.update(percentage: 90, connected: true, interval: .ten))
        tracker.reset()
        precondition(!tracker.update(percentage: 91, connected: true, interval: .one))
        precondition(!tracker.update(percentage: 92, connected: true, interval: .one))
        precondition(!tracker.update(percentage: 92, connected: false, interval: .ten))
        precondition(tracker.update(percentage: 90, connected: false, interval: .ten))
        print("Battery thresholds passed: all intervals, discharge alerts, silent charging, skips, jitter, off, reset and connection changes")
    }
}
