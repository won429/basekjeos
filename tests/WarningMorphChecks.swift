import AppKit
import SwiftUI

@main struct WarningMorphChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = WarningMorphDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class WarningMorphDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-warning-morph-review")
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .dynamicIsland)
        controller.show()
        Task { @MainActor in
            let panel = NSApp.windows.first { $0.contentView is NSHostingView<NotchPlayerView> }!
            let view = panel.contentView as! NSHostingView<NotchPlayerView>
            let layout = view.rootView.layout
            for style in PlayerPresentationStyle.allCases {
                controller.setPresentationStyle(style)
                preview("idle")
                try? await Task.sleep(nanoseconds: 550_000_000)
                let initialWidth = layout.visualSize.width
                preview("battery")
                require(abs(layout.visualSize.width - initialWidth) < 1, "No width jump before warning expansion")
                var last = layout.visualSize
                for index in 0..<26 {
                    let size = layout.visualSize
                    require(size.width >= last.width - 0.1 && size.height >= last.height - 0.1, "Monotonic warning entry")
                    if [0, 4, 8, 13, 25].contains(index) { snapshot(view, "\(style)-entry-\(index)") }
                    last = size
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                require(layout.expansionProgress == 1, "Warning expanded")
                for destination in ["charging", "idle", "music"] {
                    if layout.compactDisplayState != .lowBattery {
                        preview("battery")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if destination == "music" { preview("idle") }
                    preview(destination)
                    last = layout.visualSize
                    var samples: [[String: Double]] = []
                    for index in 0..<30 {
                        let size = layout.visualSize
                        require(size.width <= last.width + 0.1 && size.height <= last.height + 0.1,
                                "No shrink-then-regrow on warning dismissal")
                        if [0, 4, 8, 13, 22].contains(index) { snapshot(view, "\(style)-\(destination)-\(index)") }
                        samples.append(["width": size.width, "height": size.height])
                        last = size
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    let expected: CompactDisplayState = destination == "charging" ? .charging : destination == "idle" ? .idle : .music
                    require(layout.compactDisplayState == expected && layout.expansionProgress == 0, "Destination reached")
                    require(abs(layout.compactWidth - layout.targetCompactWidth) < 0.1, "Final width matches destination")
                    try! JSONSerialization.data(withJSONObject: samples).write(to: output.appendingPathComponent("\(style)-\(destination).json"))
                }
            }
            try! "PASS: both styles, warning entry, direct charging/idle/music return without bounce\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
    func preview(_ state: String) {
        setenv("NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE", state, 1)
        setenv("NOTCH_MUSIC_SNAPSHOT_BATTERY", "12", 1)
        client.loadSnapshotPreview()
    }
    func require(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            try! "FAIL \(line): \(message)".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }
    func snapshot(_ view: NSView, _ name: String) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
}
