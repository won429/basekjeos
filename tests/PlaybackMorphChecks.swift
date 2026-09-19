import AppKit
import SwiftUI

// Runs the real controller with preview playback data; does not control a music app.
@main
struct PlaybackMorphChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MorphDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class MorphDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-playback-morph-review")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .notch)
        controller.show()
        preview("idle")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let panel = NSApp.windows.first { $0.contentView is NSHostingView<NotchPlayerView> }!
            let view = panel.contentView as! NSHostingView<NotchPlayerView>
            let layout = view.rootView.layout
            for style in PlayerPresentationStyle.allCases {
            preview("idle")
            controller.setPresentationStyle(style)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let baseline = layout.compactWidth
            precondition(layout.compactMusicVisibility == 0)
            let center = controller.reservedMenuBarFrame!.midX
            let top = controller.reservedMenuBarFrame!.maxY
            snapshot(view, "\(style)-idle")
            preview("music")
            let growth = layout.targetCompactWidth - baseline
            var samples: [[String: Double]] = []
            var previousWidth = baseline
            for index in 0..<32 {
                let width = layout.compactWidth
                let visibility = layout.compactMusicVisibility
                precondition(width >= previousWidth - 0.01 && width <= baseline + growth + 0.01,
                             "Playback width must grow continuously without rebound")
                precondition(abs((width - baseline) / growth - visibility) < 0.01,
                             "Artwork/waveform reveal must track the width")
                let frame = controller.reservedMenuBarFrame!
                precondition(abs(frame.midX - center) <= 1 / (panel.screen?.backingScaleFactor ?? 1) + 0.01 && abs(frame.maxY - top) < 0.01)
                samples.append(["width": width, "visibility": visibility])
                snapshot(view, "\(style)-playing-\(index)")
                previousWidth = width
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(abs(layout.compactWidth - baseline - growth) < 0.01)
            preview("paused")
            let pausedWidth = style == .notch ? baseline : baseline + growth
            try? await Task.sleep(nanoseconds: 550_000_000)
            precondition(abs(layout.compactWidth - pausedWidth) < 0.01)
            precondition(layout.compactMusicVisibility == 1, "Paused artwork remains visible")
            preview("idle")
            try? await Task.sleep(nanoseconds: 550_000_000)
            precondition(abs(layout.compactWidth - baseline) < 0.01 && layout.compactMusicVisibility == 0)
            // Reverse an in-flight expansion: retain the currently displayed width.
            preview("music")
            try? await Task.sleep(nanoseconds: 140_000_000)
            let interruptedWidth = layout.compactWidth
            preview("idle")
            precondition(abs(layout.compactWidth - interruptedWidth) < 0.1)
            try? await Task.sleep(nanoseconds: 550_000_000)
            precondition(abs(layout.compactWidth - baseline) < 0.01)
            try! JSONSerialization.data(withJSONObject: samples, options: .prettyPrinted)
                .write(to: output.appendingPathComponent("\(style)-samples.json"))
            }
            try! "PASS: both styles, bounded growth, synchronized reveal, fixed center/top, pause/idle, interrupted reversal\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func preview(_ state: String) {
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
