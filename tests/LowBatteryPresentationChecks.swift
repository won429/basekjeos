import AppKit
import SwiftUI

@main
struct LowBatteryPresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    var actual = false
    var initialFrame = NSRect.zero
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BATTERY_TEST_OUTPUT"]!)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = LowPowerModeController(readState: { [unowned self] in actual }, changeState: { [unowned self] target in
            // Mock only: this test never invokes pmset or asks for administrator access.
            actual = target
        })
        client = MediaRemoteClient(lowPowerMode: mode)
        client.setAppLanguage(.korean, persist: false)
        let style = PlayerPresentationStyle(rawValue: ProcessInfo.processInfo.environment["BATTERY_TEST_STYLE"] ?? "") ?? .dynamicIsland
        controller = NotchPanelController(mediaClient: client, presentationStyle: style)
        controller.show()
        initialFrame = NSApp.windows.first!.frame
        client.loadSnapshotPreview()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            let panel = NSApp.windows.first!
            precondition(panel.frame.height > initialFrame.height + 30, "Low battery must expand without a click")
            snapshot("red")
            client.toggleLowPowerMode()
            try? await Task.sleep(nanoseconds: 400_000_000)
            precondition(client.lowPowerMode.isEnabled)
            snapshot("yellow")
            client.toggleLowPowerMode()
            try? await Task.sleep(nanoseconds: 400_000_000)
            precondition(!client.lowPowerMode.isEnabled)
            snapshot("red-again")
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            precondition(client.compactDisplayState == .music)
            precondition(abs(panel.frame.height - initialFrame.height) < 1, "Warning must automatically collapse")
            snapshot("dismissed")
            print("Battery presentation passed: automatic expansion, enabled/disabled, timed collapse (\(style))")
            NSApp.terminate(nil)
        }
    }

    func snapshot(_ name: String) {
        let view = NSApp.windows.first!.contentView!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
}
