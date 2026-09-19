import AppKit
import SwiftUI

@main struct ImmersiveEntryChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = EntryDelegate()
        app.delegate = delegate
        app.run()
    }
}
@MainActor private final class EntryDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var notch: NotchPanelController!
    private func assertFixedTop(_ host: NSHostingView<NotchPlayerView>, top: CGFloat, center: CGFloat) {
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.isFlipped ? host.bounds.minY : host.bounds.maxY), to: nil)
        let screenPoint = host.window!.convertPoint(toScreen: point)
        try! "top=\(top) actual=\(screenPoint) host=\(host.frame) window=\(host.window!.frame) flipped=\(host.isFlipped) pulse=\(host.rootView.layout.immersivePulse)".write(toFile: "/tmp/nook-pulse-geometry.txt", atomically: true, encoding: .utf8)
        precondition(abs(screenPoint.y - top) < 0.5, "Pulse moved vertically: \(screenPoint.y) vs \(top)")
        precondition(abs(screenPoint.x - center) < 0.5, "Pulse moved horizontally")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setenv("NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE", "1", 1)
        client = MediaRemoteClient()
        client.loadSnapshotPreview()
        notch = NotchPanelController(mediaClient: client, presentationStyle: .notch)
        Task { @MainActor in
            for style in [PlayerPresentationStyle.notch, .dynamicIsland] {
                notch.setPresentationStyle(style)
                for _ in 0..<3 {
                    notch.show(expanded: true)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let compactHost = NSApp.windows.compactMap { ($0.contentView as? PlayerHostingContainer)?.hostedView as? NSHostingView<NotchPlayerView> }.first!
                    let fixedTop = compactHost.window!.frame.maxY
                    let fixedCenter = compactHost.window!.frame.midX
                    notch.showImmersivePlayer() // Actual entry, including collapse + pulse.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let pulsing = NSApp.windows.compactMap { ($0.contentView as? PlayerHostingContainer)?.hostedView as? NSHostingView<NotchPlayerView> }.first!
                    precondition(pulsing.rootView.layout.immersivePulse == 1,
                                 "Opening pulse must start immediately, not after the portal finishes")
                    for _ in 0..<70 {
                        assertFixedTop(pulsing, top: fixedTop, center: fixedCenter)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    let windows = NSApp.windows.filter {
                        $0.isVisible && ($0.contentView as? PlayerHostingContainer)?.hostedView is NSHostingView<ImmersivePlayerView>
                    }
                    precondition(windows.count == 1)
                    let window = windows[0]
                    precondition(window.frame == window.screen!.frame)
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                    window.keyDown(with: event)
                    for _ in 0..<56 {
                        assertFixedTop(pulsing, top: fixedTop, center: fixedCenter)
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    precondition(!window.isVisible && window.contentView == nil)
                    let host = NSApp.windows.compactMap { ($0.contentView as? PlayerHostingContainer)?.hostedView as? NSHostingView<NotchPlayerView> }.first!
                    precondition(host.rootView.layout.immersivePulse == 0)
                    precondition(abs(host.window!.frame.width - host.rootView.layout.visualSize.width) < 1)
                }
            }
            try! "PASS: six actual entries/exits across notch and island; simultaneous collapse/pulse; fullscreen bounds and compact-size restoration\n".write(toFile: "/tmp/nook-entry-result.txt", atomically: true, encoding: .utf8)
            client.stop()
            NSApp.terminate(nil)
        }
    }
}
