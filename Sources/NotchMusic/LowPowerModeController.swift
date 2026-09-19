import AppKit
import Combine

/// The system remains the source of truth; a successful command alone never turns the UI yellow.
@MainActor
final class LowPowerModeController: ObservableObject {
    enum ChangeError: Error { case cancelled, failed }
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isChanging = false
    @Published private(set) var didFail = false
    private let readState: () -> Bool
    private let changeState: (Bool) async throws -> Void
    private var observation: AnyCancellable?

    init(readState: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         changeState: @escaping (Bool) async throws -> Void = LowPowerModeController.setBatteryMode) {
        self.readState = readState
        self.changeState = changeState
        isEnabled = readState()
        observation = NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() { isEnabled = readState() }

    func toggle() async {
        guard !isChanging else { return }
        refresh()
        let target = !isEnabled
        isChanging = true
        didFail = false
        defer { isChanging = false }
        do {
            try await changeState(target)
            // macOS can deliver the power-state notification after pmset exits.
            for _ in 0..<15 {
                refresh()
                if isEnabled == target { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            didFail = true
        } catch ChangeError.cancelled {
            refresh()
        } catch {
            refresh()
            didFail = true
        }
    }

    nonisolated private static func setBatteryMode(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                // Only battery power is changed. Authorization is requested by macOS on click.
                process.arguments = ["-e", "do shell script \"/usr/bin/pmset -b lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"]
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let text = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(throwing: text.contains("(-128)") ? ChangeError.cancelled : ChangeError.failed)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
