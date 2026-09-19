import Foundation
import IOBluetooth

struct AirPodsSnapshot: Equatable {
    let name: String
    let leftBattery: Int?
    let rightBattery: Int?
    let unitBattery: Int?
}

@MainActor
final class AirPodsMonitor {
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int

    private let onChange: (AirPodsSnapshot?) -> Void
    private var timer: Timer?
    private let deviceQueue = DispatchQueue(label: "com.notchmusic.airpods", qos: .utility)
    private var pollInFlight = false
    private var generation = 0
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastSnapshot: AirPodsSnapshot?
    private var hasDeliveredInitialState = false

    init(onChange: @escaping (AirPodsSnapshot?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }

        generation += 1
        let center = NotificationCenter.default
        let names = [
            Notification.Name("IOBluetoothDeviceConnected"),
            Notification.Name("IOBluetoothDeviceDisconnected")
        ]
        notificationTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.poll()
                }
            }
        }

        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        generation += 1
        pollInFlight = false
        timer?.invalidate()
        timer = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        lastSnapshot = nil
        hasDeliveredInitialState = false
    }

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let currentGeneration = generation
        deviceQueue.async { [weak self] in
            let snapshot = autoreleasepool { Self.readSnapshot() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.pollInFlight = false
                guard !self.hasDeliveredInitialState || snapshot != self.lastSnapshot else { return }
                self.hasDeliveredInitialState = true
                self.lastSnapshot = snapshot
                self.onChange(snapshot)
            }
        }
    }

    nonisolated private static func readSnapshot() -> AirPodsSnapshot? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.first { device in
            device.isConnected() && isAirPodsName(device.nameOrAddress)
        }.map(snapshot(for:))
    }

    nonisolated private static func snapshot(for device: IOBluetoothDevice) -> AirPodsSnapshot {
        let left = validPercentage(integerValue("batteryPercentLeft", from: device))
        let right = validPercentage(integerValue("batteryPercentRight", from: device))
        let combined = validPercentage(integerValue("batteryPercentCombined", from: device))
            ?? validPercentage(integerValue("batteryPercentSingle", from: device))
            ?? validPercentage(integerValue("headsetBattery", from: device))

        let unitBattery: Int?
        if let combined {
            unitBattery = combined
        } else {
            let availableUnits = [left, right].compactMap { $0 }
            unitBattery = availableUnits.isEmpty
                ? nil
                : Int((Double(availableUnits.reduce(0, +)) / Double(availableUnits.count)).rounded())
        }

        return AirPodsSnapshot(
            name: device.nameOrAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "AirPods",
            leftBattery: left,
            rightBattery: right,
            unitBattery: unitBattery
        )
    }

    nonisolated private static func isAirPodsName(_ name: String?) -> Bool {
        name?.range(of: "airpods", options: .caseInsensitive) != nil
    }

    nonisolated private static func validPercentage(_ value: Int?) -> Int? {
        guard let value, (1...100).contains(value) else { return nil }
        return value
    }

    nonisolated private static func integerValue(_ selectorName: String, from object: NSObject) -> Int? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else { return nil }
        return unsafeBitCast(implementation, to: IntegerGetter.self)(object, selector)
    }
}
