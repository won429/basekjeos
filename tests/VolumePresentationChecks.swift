import AppKit
import SwiftUI

@main struct VolumePresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Checks()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class Checks: NSObject, NSApplicationDelegate {
    let output = URL(fileURLWithPath: "/tmp/notch-volume-review")
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    var layout: NotchLayoutModel!
    var view: NSHostingView<NotchPlayerView>!
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .dynamicIsland)
        controller.show()
        view = NSApp.windows.compactMap { $0.contentView as? NSHostingView<NotchPlayerView> }.first!
        layout = view.rootView.layout
        Task { @MainActor in
            for style in [PlayerPresentationStyle.dynamicIsland, .notch] {
                controller.setPresentationStyle(style)
                preview("idle")
                await pause(0.6)
                let idleWidth = layout.compactWidth
                client.presentVolume(.init(level: 0.5, muted: false))
                await pause(0.10)
                require(layout.compactWidth > idleWidth, "Volume expands immediately")
                require(layout.compactPowerVisibility > 0.02, "Volume content appears during early expansion")
                snapshot("\(style)-volume-entering")
                await checkPulse()
                require(layout.compactDisplayState == .volume, "Volume visible")
                snapshot("\(style)-volume")
                client.presentVolume(.init(level: 0.75, muted: false))
                await pause(0.2)
                require(layout.arrivalEmphasis == 0, "Repeated volume updates do not bounce")
                await pause(1.4)
                client.presentVolume(.init(level: 0.75, muted: true))
                await pause(0.7)
                require(layout.compactDisplayState == .volume && client.outputMuted, "Last adjustment extends timeout")
                snapshot("\(style)-muted")
                await pause(1.9)
                require(layout.compactDisplayState == .idle && layout.arrivalEmphasis == 0, "Volume returns to idle")
                preview("music")
                await pause(0.6)
                let musicWidth = layout.compactWidth
                client.presentVolume(.init(level: 0.5, muted: false))
                await pause(0.15)
                require(layout.compactWidth > musicWidth, "Volume grows beyond music width")
                require(layout.compactMusicVisibility + layout.compactPowerVisibility > 0.95,
                        "Music to volume has no black gap")
                snapshot("\(style)-music-to-volume")
                await pause(2.5)
                for state in ["charging", "airpods", "battery"] {
                    setenv("NOTCH_MUSIC_SNAPSHOT_BATTERY", "15", 1)
                    preview(state)
                    await checkPulse()
                    snapshot("\(style)-\(state)")
                    preview("idle")
                    await pause(0.55)
                }
                client.presentVolume(.init(level: 0, muted: false))
                await pause(0.12)
                preview("charging")
                await checkPulse()
                require(layout.compactDisplayState == .charging, "Interrupted alert wins")
                await pause(2.1)
                require(layout.compactDisplayState == .charging, "Old volume timeout cannot hide charging")
            }
            try! "PASS: volume/mute, timeout renewal and return, both styles, all alert pulses, interruption bounds\n".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
    func checkPulse() async {
        var peak: CGFloat = 0
        for _ in 0..<30 {
            peak = max(peak, layout.arrivalEmphasis)
            require(layout.visualSize.width <= view.bounds.width + 0.1, "No horizontal clipping")
            require(layout.visualSize.height <= view.bounds.height + 0.1, "No vertical clipping")
            await pause(0.02)
        }
        require(peak > 0.8 && peak <= 1, "Single small pulse")
        require(layout.arrivalEmphasis == 0, "Pulse settles completely")
    }
    func preview(_ state: String) {
        setenv("NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE", state, 1)
        client.loadSnapshotPreview()
    }
    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    func require(_ condition: Bool, _ message: String) {
        if !condition {
            try! "FAIL: \(message), state=\(layout.compactDisplayState), visual=\(layout.visualSize), bounds=\(view.bounds)\n".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }
    func snapshot(_ name: String) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
}
