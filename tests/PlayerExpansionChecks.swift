import AppKit
import SwiftUI

@main
struct PlayerExpansionChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ExpansionDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class ExpansionDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-player-expansion-review")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .notch)
        controller.show()
        setenv("NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE", "1", 1)
        client.loadSnapshotPreview()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            let panel = NSApp.windows.first { $0.contentView is NSHostingView<NotchPlayerView> }!
            let view = panel.contentView as! NSHostingView<NotchPlayerView>
            let layout = view.rootView.layout
            for style in PlayerPresentationStyle.allCases {
                controller.setPresentationStyle(style)
                controller.setExpanded(false)
                try? await Task.sleep(nanoseconds: 450_000_000)
                let finalCompact = layout.visualSize
                snapshot(view, "\(style)-compact")
                controller.setExpanded(true)
                let top = panel.frame.maxY
                var previousProgress: CGFloat = 0
                for index in 0..<32 {
                    let progress = layout.expansionProgress
                    precondition(progress >= previousProgress && progress <= 1)
                    precondition(abs(panel.frame.maxY - top) < 0.01)
                    if [0, 3, 6, 10, 15, 25].contains(index) {
                        snapshot(view, "\(style)-open-\(index)")
                    }
                    previousProgress = progress
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                precondition(layout.expansionProgress == 1)
                precondition(layout.visualSize.width == layout.expandedWidth)
                controller.setExpanded(false)
                for index in 0..<22 {
                    if [3, 8, 14].contains(index) { snapshot(view, "\(style)-close-\(index)") }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                precondition(layout.expansionProgress == 0 && layout.visualSize == finalCompact)
                controller.setExpanded(true)
                try? await Task.sleep(nanoseconds: 120_000_000)
                let interrupted = layout.expansionProgress
                controller.setExpanded(false)
                precondition(abs(layout.expansionProgress - interrupted) < 0.01)
                try? await Task.sleep(nanoseconds: 450_000_000)
                precondition(layout.expansionProgress == 0)
                controller.setExpanded(true)
                try? await Task.sleep(nanoseconds: 650_000_000)
                // Exercise the actual hit target, including a notch shoulder
                // outside the physical sensor area.
                click(panel, at: NSPoint(x: style == .notch ? 30 : panel.frame.width / 2,
                                         y: panel.frame.height - 10))
                try? await Task.sleep(nanoseconds: 600_000_000)
                precondition(!layout.isExpanded, "Expanded top region must collapse on a real click")
                controller.setExpanded(true)
                try? await Task.sleep(nanoseconds: 650_000_000)
                // An interior click preserves the controls; exterior clicks collapse.
                controller.dismissExpandedPlayerIfOutside(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
                precondition(layout.isExpanded)
                controller.dismissExpandedPlayerIfOutside(NSPoint(x: panel.frame.maxX + 2, y: panel.frame.midY))
                try? await Task.sleep(nanoseconds: 500_000_000)
                precondition(!layout.isExpanded)
                controller.setExpanded(true)
                try? await Task.sleep(nanoseconds: 650_000_000)
                let artworkX: CGFloat = style == .notch ? 72 : 50
                let artworkY = panel.frame.height - (layout.expandedMusicTopPadding + 30)
                click(panel, at: NSPoint(x: artworkX, y: artworkY))
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard let immersive = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView is NSHostingView<ImmersivePlayerView>
                }) else { preconditionFailure("The artwork hit target must open immersive mode") }
                precondition(panel.isVisible && panel.level.rawValue > immersive.level.rawValue)
                precondition(!layout.isExpanded, "Immersive mode keeps the compact player visible")
                controller.setExpanded(true)
                try? await Task.sleep(nanoseconds: 650_000_000)
                click(immersive, at: NSPoint(x: 150, y: 150))
                try? await Task.sleep(nanoseconds: 500_000_000)
                precondition(!layout.isExpanded && immersive.isVisible, "Outside dismissal preserves immersive playback")
                let immersiveView = immersive.contentView as! NSHostingView<ImmersivePlayerView>
                immersiveView.rootView.onClose()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            try! "PASS: both styles open/close, fixed top, monotonic bounded expansion, interrupted reversal\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
    }

    func snapshot(_ view: NSView, _ name: String) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}
