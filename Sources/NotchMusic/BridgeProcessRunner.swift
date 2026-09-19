import Foundation

/// Drain both pipes while the child runs. Waiting for exit before reading can
/// deadlock as soon as an embedded cover exceeds the kernel pipe capacity.
@MainActor
final class BridgeProcessRunner {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        func store(_ data: Data, isError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isError { stderr = data } else { stdout = data }
        }
        func read() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (stdout, stderr)
        }
    }

    static func run(
        _ process: Process,
        timeout: TimeInterval = 10,
        completion: @escaping @MainActor (Data, Data, Int32) -> Void
    ) throws {
        let stdout = Pipe(), stderr = Pipe()
        let output = Output()
        let readers = DispatchGroup()
        process.standardOutput = stdout
        process.standardError = stderr
        readers.enter()
        readers.enter()
        process.terminationHandler = { child in
            readers.notify(queue: .main) {
                let (data, errors) = output.read()
                Task { @MainActor in completion(data, errors, child.terminationStatus) }
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            readers.leave()
            readers.leave()
            throw error
        }
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            DispatchQueue.global(qos: .utility).async {
                output.store(pipe.fileHandleForReading.readDataToEndOfFile(), isError: isError)
                try? pipe.fileHandleForReading.close()
                readers.leave()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            cancel(process)
        }
    }

    static func cancel(_ process: Process, force: Bool = false) {
        guard process.isRunning else { return }
        if force {
            // App termination must not leave a helper running after its run loop exits.
            kill(process.processIdentifier, SIGKILL)
            return
        }
        process.terminate()
        // Some JXA/private-framework calls do not respond to SIGTERM promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [process] in
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
