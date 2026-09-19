import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor final class MotionFixture: ObservableObject {
    @Published var playing = true
    var clicks = 0
    var skips = 0
}
struct MotionPreview: View {
    @ObservedObject var model: MotionFixture
    var body: some View {
        ZStack {
            Color.black
            LinearGradient(colors: [.orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 64, height: 64).cornerRadius(8)
                .modifier(PlaybackArtworkMotion(isPlaying: model.playing))
                .position(x: 180, y: 45)
            PlaybackTransportButton(symbol: "backward.fill", size: 22, action: { model.skips -= 1 })
                .position(x: 96, y: 130)
            PlaybackTransportButton(symbol: model.playing ? "pause.fill" : "play.fill", size: 30, width: 44) {
                model.playing.toggle(); model.clicks += 1
            }.position(x: 180, y: 130)
            PlaybackTransportButton(symbol: "forward.fill", size: 22, action: { model.skips += 1 })
                .position(x: 264, y: 130)
        }.frame(width: 360, height: 180)
    }
}
@main struct PlaybackMotionChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MotionDelegate()
        app.delegate = delegate
        app.run()
    }
}
@MainActor final class MotionDelegate: NSObject, NSApplicationDelegate {
    let model = MotionFixture()
    var window: NSWindow!
    var host: NSHostingView<MotionPreview>!
    func capture(_ name: String) async {
        host.layoutSubtreeIfNeeded()
        let available = try! await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = available.windows.first { $0.windowID == CGWindowID(window.windowNumber) }!
        let config = SCStreamConfiguration()
        config.width = 720; config.height = 360; config.showsCursor = false
        let cg = try! await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/nook-motion-\(name).png"))
    }
    func click(_ type: NSEvent.EventType, x: CGFloat = 180) {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        window.sendEvent(event)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        host = NSHostingView(rootView: MotionPreview(model: model))
        host.focusRingType = .none
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await capture("playing")
            click(.leftMouseDown)
            try? await Task.sleep(nanoseconds: 120_000_000)
            await capture("pressed")
            click(.leftMouseUp)
            try? await Task.sleep(nanoseconds: 600_000_000)
            precondition(model.clicks == 1 && !model.playing)
            await capture("paused")
            click(.leftMouseDown); click(.leftMouseUp)
            try? await Task.sleep(nanoseconds: 600_000_000)
            precondition(model.clicks == 2 && model.playing)
            await capture("resumed")
            click(.leftMouseDown, x: 96); click(.leftMouseUp, x: 96)
            try? await Task.sleep(nanoseconds: 100_000_000)
            await capture("previous-moving")
            precondition(model.skips == -1)
            try? await Task.sleep(nanoseconds: 250_000_000)
            click(.leftMouseDown, x: 264); click(.leftMouseUp, x: 264)
            try? await Task.sleep(nanoseconds: 100_000_000)
            await capture("next-moving")
            precondition(model.skips == 0)
            try! "PASS: press, pause and resume; exactly one action per click\n".write(toFile: "/tmp/nook-motion-result.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
