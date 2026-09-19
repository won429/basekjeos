import Foundation

@main
struct BridgeProcessChecks {
    @MainActor static func main() async throws {
        let large = Process()
        large.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        large.arguments = ["-e", "print STDOUT 'A' x 1048576; print STDERR 'B' x 1048576;"]
        let result = try await execute(large)
        precondition(result.0 == Data(repeating: 65, count: 1_048_576))
        precondition(result.1 == Data(repeating: 66, count: 1_048_576))
        precondition(result.2 == 0)

        let hung = Process()
        hung.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        hung.arguments = ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30;"]
        let started = Date()
        let timedOut = try await execute(hung, timeout: 0.3)
        precondition(timedOut.2 != 0 && Date().timeIntervalSince(started) < 4)
        precondition(!hung.isRunning)

        let cancelled = Process()
        cancelled.executableURL = URL(fileURLWithPath: "/bin/sleep")
        cancelled.arguments = ["30"]
        let cancelledResult: (Data, Data, Int32) = try await withCheckedThrowingContinuation { continuation in
            do {
                try BridgeProcessRunner.run(cancelled) { continuation.resume(returning: ($0, $1, $2)) }
                BridgeProcessRunner.cancel(cancelled)
            } catch { continuation.resume(throwing: error) }
        }
        precondition(cancelledResult.2 != 0 && !cancelled.isRunning)

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/notch-test")
        do { _ = try await execute(missing); preconditionFailure("Missing executable succeeded") }
        catch { }
        print("PASS: 1 MiB stdout + stderr, unresponsive child timeout, cancellation, launch failure")
    }

    @MainActor static func execute(_ process: Process, timeout: TimeInterval = 5) async throws -> (Data, Data, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try BridgeProcessRunner.run(process, timeout: timeout) { continuation.resume(returning: ($0, $1, $2)) }
            } catch { continuation.resume(throwing: error) }
        }
    }
}
