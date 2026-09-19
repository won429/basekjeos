import Foundation

@main
struct LowPowerModeChecks {
    @MainActor static func main() async {
        var actual = false
        var calls = 0
        let mode = LowPowerModeController(readState: { actual }, changeState: { target in
            calls += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            actual = target
        })
        let pending = Task { await mode.toggle() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        precondition(mode.isChanging && !mode.isEnabled, "Do not show enabled before confirmation")
        await mode.toggle()
        await pending.value
        precondition(calls == 1 && mode.isEnabled && !mode.isChanging && !mode.didFail)
        await mode.toggle()
        precondition(!mode.isEnabled && calls == 2)
        actual = true
        mode.refresh()
        precondition(mode.isEnabled, "Reflect changes made outside the app")

        let cancelled = LowPowerModeController(readState: { false }, changeState: { _ in
            throw LowPowerModeController.ChangeError.cancelled
        })
        await cancelled.toggle()
        precondition(!cancelled.isEnabled && !cancelled.didFail && !cancelled.isChanging)
        let failed = LowPowerModeController(readState: { false }, changeState: { _ in
            throw LowPowerModeController.ChangeError.failed
        })
        await failed.toggle()
        precondition(!failed.isEnabled && failed.didFail && !failed.isChanging)
        let unchanged = LowPowerModeController(readState: { false }, changeState: { _ in })
        await unchanged.toggle()
        precondition(!unchanged.isEnabled && unchanged.didFail, "Command exit is not state confirmation")
        print("Low power mode passed: confirmed toggle, repeated clicks, external state, cancellation, failure, unconfirmed success")
    }
}
