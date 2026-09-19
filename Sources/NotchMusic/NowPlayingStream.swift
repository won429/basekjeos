import Foundation

enum NowPlayingStreamHealth {
    static let timeout: TimeInterval = 5

    static func isResponsive(
        startedAt: Date?,
        lastDataAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let reference = lastDataAt ?? startedAt else { return false }
        return now.timeIntervalSince(reference) <= timeout
    }
}

/// Handles fragmented UTF-8 and multiple messages in a single pipe read.
final class BridgeLineBuffer {
    private let lock = NSLock()
    private var pending = Data()
    private var scannedBytes = 0

    func consume(_ data: Data, onLine: (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var scanStart = pending.index(pending.startIndex, offsetBy: scannedBytes)
        while let newline = pending[scanStart...].firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { onLine(line) }
            scanStart = pending.startIndex
        }
        scannedBytes = pending.count
    }
}

@MainActor
final class NowPlayingStream {
    private var process: Process?
    private var output: Pipe?
    private var startedAt: Date?
    private var lastDataAt: Date?
    private let onData: (Data) -> Void

    var isRunning: Bool { process?.isRunning == true }
    var isResponsive: Bool {
        isRunning && NowPlayingStreamHealth.isResponsive(
            startedAt: startedAt,
            lastDataAt: lastDataAt
        )
    }

    init(onData: @escaping (Data) -> Void) { self.onData = onData }

    func start(scriptURL: URL) {
        guard process == nil else { return }
        let child = Process()
        let pipe = Pipe()
        let lines = BridgeLineBuffer()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        child.arguments = ["-l", "JavaScript", scriptURL.path, "watch"]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        process = child
        output = pipe
        startedAt = Date()
        lastDataAt = nil

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Read while the child runs, so even a large embedded cover cannot fill
            // the pipe and deadlock the producer while the app waits for termination.
            lines.consume(data) { line in
                DispatchQueue.main.async { [weak self, weak child] in
                    guard let self, let child, self.process === child else { return }
                    self.lastDataAt = Date()
                    self.onData(line)
                }
            }
        }
        child.terminationHandler = { [weak self, weak child] _ in
            DispatchQueue.main.async { [weak self, weak child] in
                guard let self, let child, self.process === child else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                self.process = nil
                self.startedAt = nil
                self.lastDataAt = nil
            }
        }
        do {
            try child.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            output = nil
            startedAt = nil
            lastDataAt = nil
        }
    }

    func stop() {
        let child = process
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        startedAt = nil
        lastDataAt = nil
        if let child { BridgeProcessRunner.cancel(child, force: true) }
    }
}
