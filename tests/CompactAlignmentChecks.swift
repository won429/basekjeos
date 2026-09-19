import AppKit
import SwiftUI

@main struct CompactAlignmentChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AlignmentDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class AlignmentDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-alignment-review")
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        for style in PlayerPresentationStyle.allCases {
            let layout = NotchLayoutModel(screen: NSScreen.main!, presentationStyle: style)
            layout.setPlaybackActive(false)
            layout.setCompactDisplayState(.idle)
            let baseline = layout.targetCompactWidth
            if style == .notch { precondition(layout.volumeProtectedCenterWidth == baseline) }
            else { precondition(layout.volumeContentScale == min(max(layout.compactHeight / 26, 0.68), 1.18)) }
            layout.setCompactDisplayState(.volume)
            precondition(layout.targetCompactWidth > baseline)
            if style == .notch {
                precondition((layout.targetCompactWidth - baseline) / 2 >= 102,
                             "HUD wings must sit beyond the full baseline notch")
            }
            layout.setAirPodsName("성원이의 아주 긴 이름이 붙은 AirPods Pro 3세대")
            layout.update(for: NSScreen.main!)
            layout.setCompactDisplayState(.airPods)
            let textWidth = ("성원이의 아주 긴 이름이 붙은 AirPods Pro 3세대" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]).width
            precondition(layout.expandedWidth - (style == .notch ? 180 : 158) >= textWidth)
        }
        controller = NotchPanelController(mediaClient: client, presentationStyle: .dynamicIsland)
        controller.show()
        setenv("NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE", "1", 1)
        Task { @MainActor in
            for style in PlayerPresentationStyle.allCases {
                controller.setPresentationStyle(style)
                for state in ["music", "charging", "disconnected", "battery", "airpods", "volume"] {
                    setenv("NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE", state, 1)
                    setenv("NOTCH_MUSIC_SNAPSHOT_BATTERY", "65", 1)
                    client.loadSnapshotPreview()
                    if state == "volume" { client.presentVolume(.init(level: 0.5, muted: false)) }
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    let view = NSApp.windows.compactMap { $0.contentView as? NSHostingView<NotchPlayerView> }.first!
                    let layout = view.rootView.layout
                    precondition(layout.visualSize.height <= view.bounds.height + 0.1)
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(style)-\(state).png"))
                    if state == "music" {
                        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
                        // Check the rendered cover and waveform share a center, without clipping.
                        func center(in range: Range<Int>) -> Double {
                            var rows: [Int] = []
                            for y in 0..<bitmap.pixelsHigh {
                                if range.contains(where: { x in
                                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                                    return c.alphaComponent > 0.5 && c.blueComponent > 0.6 && c.redComponent < 0.3
                                }) { rows.append(y) }
                            }
                            precondition(!rows.isEmpty)
                            precondition(rows.first! > 0 && rows.last! < bitmap.pixelsHigh - 1)
                            return Double(rows.first! + rows.last!) / 2
                        }
                        let left = center(in: 0..<Int(50 * scale))
                        let right = center(in: (bitmap.pixelsWide - Int(50 * scale))..<bitmap.pixelsWide)
                        precondition(abs(left - right) <= 2, "Rendered artwork and meter must align")
                        if style == .dynamicIsland {
                            let capsuleCenter = Double(layout.visualSize.height * scale) / 2 - 0.5
                            precondition(abs(left - capsuleCenter) <= 1 && abs(right - capsuleCenter) <= 1,
                                         "Cover and meter must center inside the capsule, not merely align with each other")
                        }
                    }
                    // Let the previous style's real volume-dismiss task finish
                    // before the next style starts its music fixture.
                    if state == "volume" { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                }
            }
            try! "PASS: both styles, rendered cover/meter center agreement, music and five alerts fit bounds\n".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
