import AppKit
import SwiftUI

@main
struct MotionBrightnessChecks {
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
            }
            for style in PlayerPresentationStyle.allCases {
                controller.setPresentationStyle(style)
                client.presentBrightness(0.6)
                try? await Task.sleep(nanoseconds: 600_000_000)
                precondition(client.compactDisplayState == .brightness)
                precondition(layout.compactDisplayState == .brightness)
                snapshot(view, "\(style)-brightness")
                client.presentVolume(.init(level: 0.4, muted: false))
                try? await Task.sleep(nanoseconds: 100_000_000)
                precondition(client.compactDisplayState == .volume)
                client.presentBrightness(0.7)
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                precondition(!client.compactDisplayState.isAdjustmentHUD)
            }
            let lyricState = LyricScrollFixtureState()
            let lyricView = NSHostingView(rootView: LyricScrollFixture(state: lyricState))
            let lyricWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            lyricWindow.isReleasedWhenClosed = false
            lyricWindow.contentView = lyricView
            lyricWindow.orderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            @MainActor func scrollView(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.compactMap { scrollView($0) }.first
            }
            let nativeScroll = scrollView(lyricView)!
            let clip = nativeScroll.contentView
            let initial = clip.bounds.origin.y
            lyricState.active = 8
            try? await Task.sleep(nanoseconds: 250_000_000)
            let middle = clip.bounds.origin.y
            try? await Task.sleep(nanoseconds: 850_000_000)
            let final = clip.bounds.origin.y
            precondition(middle > initial + 1 && final > middle + 1, "Lyrics must move over time, without jumping")
            lyricWindow.close()
            try! "PASS: brightness/volume replacement and dismissal, native lyric animation, both styles open/close, fixed top, monotonic bounded expansion, interrupted reversal\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func snapshot(_ view: NSView, _ name: String) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}

@MainActor private final class LyricScrollFixtureState: ObservableObject {
    @Published var active = 0
}
private struct LyricScrollFixture: View {
    @ObservedObject var state: LyricScrollFixtureState
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                ForEach(0..<16) { index in
                    Text("Lyric line \(index)").frame(height: 60)
                        .background {
                            if state.active == index {
                                SmoothLyricScrollAnchor(lineID: index, reduceMotion: false)
                            }
                        }
                }
            }.frame(maxWidth: .infinity)
        }
    }
}
