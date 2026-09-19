import Foundation
import IOKit.ps

struct PowerSnapshot: Equatable {
    let isConnectedToPower: Bool
    let isCharging: Bool
    let percentage: Int
}

enum PowerConnectionEvent: Equatable {
    case connected(PowerSnapshot)
    case disconnected(PowerSnapshot)
    case batteryLevel(PowerSnapshot)
}

@MainActor
final class PowerStateMonitor {
    // Internal batteries identify portable Macs without relying on model names
    // (Apple Silicon model identifiers do not necessarily contain "MacBook").
    static let supportsBatteryAlerts: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
        }
    }()

    private let onConnectionChanged: (PowerConnectionEvent) -> Void
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var previousSnapshot: PowerSnapshot?
    private var levelTracker = BatteryLevelTracker()
    private var alertInterval = BatteryAlertInterval.load()

    func setAlertInterval(_ interval: BatteryAlertInterval) {
        alertInterval = interval
        levelTracker.reset()
        if let snapshot = previousSnapshot {
            _ = levelTracker.update(percentage: snapshot.percentage,
                                    connected: snapshot.isConnectedToPower, interval: interval)
        }
    }

    init(onConnectionChanged: @escaping (PowerConnectionEvent) -> Void) {
        self.onConnectionChanged = onConnectionChanged
    }

    func start() {
        guard Self.supportsBatteryAlerts, timer == nil, powerSource == nil else { return }
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak monitor] in
                guard let monitor, monitor.powerSource != nil else { return }
                monitor.poll()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
        previousSnapshot = readSnapshot()
        setAlertInterval(alertInterval)
        if let snapshot = previousSnapshot, alertInterval != .off,
           LowBatteryPolicy.isLow(percentage: snapshot.percentage, connected: snapshot.isConnectedToPower) {
            onConnectionChanged(.batteryLevel(snapshot))
        }
        guard powerSource == nil else { return }
        // Preserve polling as a fallback if notification registration fails.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let powerSource {
            CFRunLoopSourceInvalidate(powerSource)
            self.powerSource = nil
        }
        previousSnapshot = nil
        levelTracker.reset()
    }

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        timer?.invalidate()
    }

    private func poll() {
        guard let snapshot = readSnapshot() else { return }
        defer { previousSnapshot = snapshot }
        let shouldNotifyLevel = levelTracker.update(
            percentage: snapshot.percentage,
            connected: snapshot.isConnectedToPower,
            interval: alertInterval
        )
        guard let previousSnapshot else { return }

        if !previousSnapshot.isConnectedToPower && snapshot.isConnectedToPower {
            onConnectionChanged(.connected(snapshot))
        } else if previousSnapshot.isConnectedToPower && !snapshot.isConnectedToPower {
            onConnectionChanged(.disconnected(snapshot))
        } else if shouldNotifyLevel || LowBatteryPolicy.crossedThreshold(
            previous: previousSnapshot.percentage, current: snapshot.percentage,
            connected: snapshot.isConnectedToPower, alertsEnabled: alertInterval != .off
        ) {
            onConnectionChanged(.batteryLevel(snapshot))
        }
    }

    private func readSnapshot() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }

            let powerState = description[kIOPSPowerSourceStateKey as String] as? String
            let isConnected = powerState == kIOPSACPowerValue
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey as String] as? Int ?? 100, 1)
            let percentage = min(max(Int((Double(current) / Double(maximum) * 100).rounded()), 0), 100)

            return PowerSnapshot(
                isConnectedToPower: isConnected,
                isCharging: isCharging,
                percentage: percentage
            )
        }
        return nil
    }
}
