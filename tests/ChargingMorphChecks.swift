import AppKit
import SwiftUI

@main
struct ChargingMorphChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ChargingMorphDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class ChargingMorphDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-charging-morph-review")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .dynamicIsland)
        controller.show()
        preview("idle")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let panel = NSApp.windows.first { $0.contentView is NSHostingView<NotchPlayerView> }!
            let view = panel.contentView as! NSHostingView<NotchPlayerView>
            let layout = view.rootView.layout
            let idleWidth = layout.compactWidth
            let top = controller.reservedMenuBarFrame!.maxY
            let center = controller.reservedMenuBarFrame!.midX
            for percentage in [20, 21] {
                setenv("NOTCH_MUSIC_SNAPSHOT_BATTERY", String(percentage), 1)
                preview("charging")
                let target = layout.targetCompactWidth
                var previousWidth = layout.compactWidth
                for index in 0..<28 {
                    require(layout.compactWidth >= previousWidth - 0.01)
                    require(layout.compactWidth <= target + 0.01, "No charging rebound")
                    require(layout.compactPowerContentWidth == target, "Stable text layout")
                    let frame = controller.reservedMenuBarFrame!
                    try! "width=\(layout.compactWidth), target=\(target), content=\(layout.compactPowerContentWidth), center=\(frame.midX) baseline=\(center), top=\(frame.maxY) baseline=\(top)\n"
                        .write(to: output.appendingPathComponent("last-frame.txt"), atomically: true, encoding: .utf8)
                    // AppKit aligns odd/even panel widths to backing pixels.
                    let pixel = 1 / (panel.screen?.backingScaleFactor ?? 1)
                    require(abs(frame.midX - center) <= pixel + 0.01 && abs(frame.maxY - top) < 0.01)
                    if index < 3 { require(layout.compactPowerVisibility < 0.01) }
                    if [0, 10, 16, 25].contains(index) { snapshot(view, "charge-\(percentage)-\(index)") }
                    previousWidth = layout.compactWidth
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                require(layout.compactPowerVisibility == 1 && !layout.usesSynchronizedPowerTransition)
                preview("idle")
                require(layout.compactPowerDisplayState == .charging, "Retain outgoing content to fade it")
                previousWidth = layout.compactWidth
                for _ in 0..<28 {
                    require(layout.compactWidth <= previousWidth + 0.01)
                    require(layout.compactWidth >= idleWidth - 0.01)
                    previousWidth = layout.compactWidth
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                require(layout.compactPowerVisibility == 0 && layout.compactPowerDisplayState == nil)
            }
            preview("music")
            try? await Task.sleep(nanoseconds: 550_000_000)
            let musicWidth = layout.compactWidth
            preview("charging")
            try? await Task.sleep(nanoseconds: 550_000_000)
            preview("music")
            try? await Task.sleep(nanoseconds: 550_000_000)
            require(abs(layout.compactWidth - musicWidth) < 0.01 && layout.compactMusicVisibility == 1)
            // Unplug during arrival: no jump to an intermediate target width.
            preview("charging")
            try? await Task.sleep(nanoseconds: 150_000_000)
            let interruptedWidth = layout.compactWidth
            preview("disconnected")
            require(abs(layout.compactWidth - interruptedWidth) < 0.1)
            try? await Task.sleep(nanoseconds: 550_000_000)
            require(layout.compactDisplayState == .disconnected && layout.compactPowerVisibility == 1)
            preview("idle")
            try? await Task.sleep(nanoseconds: 550_000_000)
            controller.setPresentationStyle(.notch)
            let notchBaseline = layout.compactWidth
            preview("music")
            try? await Task.sleep(nanoseconds: 550_000_000)
            require(abs(layout.compactWidth - notchBaseline - 48) < 0.01)
            try! "PASS: idle/music charging return, no rebound, stable text layout, delayed reveal, retained exit, interruption\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func require(_ condition: Bool, _ message: String = "", line: Int = #line) {
        guard condition else {
            try! "FAIL line \(line): \(message)\n".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }

    func preview(_ state: String) {
        // Preview playback deliberately preserves alerts, so reset that fixture
        // before requesting music. Both updates occur before the next frame.
        if state == "music", client.compactDisplayState.isPowerStatus {
            setenv("NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE", "idle", 1)
            client.loadSnapshotPreview()
        }
        setenv("NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE", state, 1)
        client.loadSnapshotPreview()
    }

    func snapshot(_ view: NSView, _ name: String) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}
