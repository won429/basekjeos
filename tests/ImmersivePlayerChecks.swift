import AppKit
import SwiftUI

@main struct ImmersivePlayerChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var notch: NotchPanelController!
    let immersive = ImmersivePlayerController()
    let output = URL(fileURLWithPath: "/tmp/notch-immersive-review")
    let lyricsService = LyricsClient { request in
        let data = try JSONSerialization.data(withJSONObject: [
            "syncedLyrics": "[00:00]A quiet moment before the music\n[00:10]Let the evening settle in\n[00:22]Every little sound comes closer\n[00:36]지금 이 순간, 음악 속으로\n[00:50]Stay a little longer\n[01:03]Let the world fade away\n[01:18]\n[01:24]One more song before we go",
            "plainLyrics": "", "instrumental": false
        ])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = CGSize(width: 1440, height: 900)
        let slot = CGRect(x: 600, y: 4, width: 240, height: 32)
        let closed = ImmersivePortal(progress: 0, source: slot, reduceMotion: false).cardFrame(size: size)
        precondition(abs(closed.minX - slot.minX) < 0.01 && abs(closed.height - slot.height) < 0.01)
        precondition(ImmersivePortal(progress: 1, source: slot, reduceMotion: false).transform(size: size) == .identity)
        precondition(ImmersivePortal(progress: 0, source: slot, reduceMotion: true).transform(size: size) == .identity)
        precondition(LyricScrollLayout.targetOffset(lineMidY: 500, documentHeight: 2_000,
                                                     viewportHeight: 600) == 200)
        precondition(LyricScrollLayout.targetOffset(lineMidY: 12, documentHeight: 2_000,
                                                     viewportHeight: 600) == 0)
        precondition(LyricScrollLayout.targetOffset(lineMidY: 1_900, documentHeight: 2_000,
                                                     viewportHeight: 600) == 1_400)
        var previous = CGSize.zero
        for i in 0...100 {
            let portal = ImmersivePortal(progress: CGFloat(i) / 100, source: slot, reduceMotion: false)
            let frame = portal.cardFrame(size: size)
            let transform = portal.transform(size: size)
            precondition(abs(transform.a - transform.d) < 0.0001, "Card content must keep its aspect ratio")
            precondition(frame.width >= previous.width && frame.height >= previous.height)
            precondition(abs(frame.midX - size.width / 2) < 0.01)
            previous = frame.size
        }
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        client.setWaveformMode(.basic, persist: false)
        precondition(!client.needsAudioCapture)
        let firstConsumer = UUID(), secondConsumer = UUID()
        client.setBackgroundAudioActive(true, consumer: firstConsumer)
        client.setBackgroundAudioActive(true, consumer: secondConsumer)
        precondition(client.needsAudioCapture, "Background capture is independent of the small meter mode")
        client.setBackgroundAudioActive(false, consumer: firstConsumer)
        precondition(client.needsAudioCapture, "One consumer cannot stop another consumer's audio")
        client.setBackgroundAudioActive(false, consumer: secondConsumer)
        precondition(!client.needsAudioCapture)
        client.setWaveformMode(.live, persist: false)
        client.setBackgroundAudioActive(true, consumer: firstConsumer)
        client.setBackgroundAudioActive(false, consumer: firstConsumer)
        client.setWaveformPresentation(.compact)
        precondition(client.needsAudioCapture, "Closing the background preserves the live meter")
        client.setWaveformPresentation(.hidden)
        client.setWaveformMode(.basic, persist: false)
        setenv("NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE", "1", 1)
        client.loadSnapshotPreview()
        notch = NotchPanelController(mediaClient: client, presentationStyle: .notch)
        notch.show(expanded: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            let screen = NSScreen.main!
            for style in PlayerPresentationStyle.allCases {
                notch.setPresentationStyle(style)
                notch.show(expanded: true)
                let source = NSRect(x: screen.frame.midX - 168, y: screen.frame.maxY - 105, width: 60, height: 60)
                immersive.show(client: client, screen: screen, sourceArtworkFrame: source, lyricsService: lyricsService)
                immersive.show(client: client, screen: screen, sourceArtworkFrame: source, lyricsService: lyricsService)
                precondition(NSApp.windows.filter { $0.isVisible && $0.playerHostedView is NSHostingView<ImmersivePlayerView> }.count == 1)
                for index in 0..<7 {
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    if let motionView = NSApp.windows.first(where: { $0.isVisible && $0.playerHostedView is NSHostingView<ImmersivePlayerView> })?.playerHostedView {
                        snapshot(motionView, "\(style)-opening-\(index)")
                        if index == 0,
                           let background = descendants(motionView).compactMap({ $0 as? AmbientArtworkLayers }).first {
                            precondition(!background.isAnimating,
                                         "Background motion waits for the portal transition")
                        }
                    }
                }
                let panel = NSApp.windows.first { $0.isVisible && $0.playerHostedView is NSHostingView<ImmersivePlayerView> }!
                let view = panel.playerHostedView as! NSHostingView<ImmersivePlayerView>
                let model = view.rootView.model
                precondition(panel.frame == screen.frame)
                precondition(model.lyrics.lines.count == 8 && model.activeLine == 3)
                precondition(!model.loading && !model.failed)
                model.colors = [.systemIndigo, .systemPink, .systemTeal]
                try? await Task.sleep(nanoseconds: 300_000_000)
                let background = descendants(view).compactMap { $0 as? AmbientArtworkLayers }.first!
                precondition(background.bounds.width == view.bounds.width)
                if #available(macOS 26.0, *) {
                    let glassViews = descendants(view).filter { NSStringFromClass(type(of: $0)) == "NSGlassEffectView" }
                    precondition(glassViews.count >= 2)
                    precondition(glassViews.allSatisfy { ($0.value(forKey: "style") as? NSNumber)?.intValue == 1
                        && $0.value(forKey: "tintColor") == nil }, "Every glass button uses untinted Clear style")
                }
                model.isPlaying = false
                try? await Task.sleep(nanoseconds: 100_000_000)
                precondition(!background.isAnimating, "Paused playback stops background motion")
                model.isPlaying = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !ProcessInfo.processInfo.isLowPowerModeEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    precondition(background.isAnimating, "Playing resumes compositor animation")
                }
                snapshot(view, "\(style)-lyrics")
                let scrollViews = descendants(view).compactMap { $0 as? NSScrollView }
                precondition(!scrollViews.isEmpty)
                // Reproduce SwiftUI restoring indicators after initial layout.
                for scroll in scrollViews {
                    scroll.verticalScroller = NSScroller()
                    scroll.horizontalScroller = NSScroller()
                    scroll.hasVerticalScroller = true
                    scroll.hasHorizontalScroller = true
                    scroll.reflectScrolledClipView(scroll.contentView)
                }

                precondition(scrollViews.allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller }, "Native lyric scrollbars must be disabled")
                if style == .notch {
                    let original = panel.frame
                    for size in [NSSize(width: 1280, height: 800), NSSize(width: 2560, height: 1440), NSSize(width: 3440, height: 1440)] {
                        panel.setContentSize(size)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        snapshot(view, "responsive-\(Int(size.width))")
                    }
                    panel.setFrame(original, display: true)
                }
                model.backgroundMode = .waveform
                try? await Task.sleep(nanoseconds: 850_000_000)
                precondition(background.mode == .waveform)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    precondition(client.needsAudioCapture, "Showing waveform background acquires capture")
                }
                background.respond(to: [1, 0.95, 0, 0, 0, 0, 0, 0.9, 0.8])
                if background.isAnimating {
                    let firstPosition = background.responseTranslation
                    precondition(abs(firstPosition.x) > 1 && abs(firstPosition.y) > 1, "Music moves fields in both axes")
                    for _ in 0..<12 { background.respond(to: [0.3, 0.8, 0, 0, 0, 0, 0, 0.6, 0.5]) }
                    precondition(background.responseTranslation != firstPosition, "Musical flow continues across successive phrases")
                }
                snapshot(view, "\(style)-wave-background")
                if ProcessInfo.processInfo.environment["NOTCH_GRAPHICS_PREVIEW"] == "1" { return }
                model.isPlaying = false
                try? await Task.sleep(nanoseconds: 100_000_000)
                let heldScale = background.responseScale
                background.respond(to: [0])
                precondition(!background.isAnimating && background.responseScale == heldScale)
                model.isPlaying = true
                model.backgroundMode = .basic
                try? await Task.sleep(nanoseconds: 850_000_000)
                precondition(background.mode == .basic)
                precondition(!client.needsAudioCapture, "Returning to basic releases background capture")
                if FileManager.default.fileExists(atPath: "/tmp/notch-immersive-hold") { return }
                model.detailMode = .queue
                try? await Task.sleep(nanoseconds: 550_000_000)
                snapshot(view, "\(style)-queue")
                model.detailMode = nil
                try? await Task.sleep(nanoseconds: 550_000_000)
                snapshot(view, "\(style)-artwork")
                model.detailMode = .lyrics
                try? await Task.sleep(nanoseconds: 550_000_000)
                precondition(!model.loading && model.lyrics.lines.count == 8, "Returning to lyrics keeps the loaded track")
                // Simulate unsupported / plain / error presentations without external requests.
                model.lyrics = TrackLyrics(plain: "시간 정보 없이도 가사를 읽을 수 있어요.\n\nThe music keeps playing.")
                try? await Task.sleep(nanoseconds: 100_000_000)
                snapshot(view, "\(style)-plain")
                model.lyrics = TrackLyrics()
                model.failed = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                if #available(macOS 26.0, *) {
                    precondition(descendants(view).filter { NSStringFromClass(type(of: $0)) == "NSGlassEffectView" }.count >= 3,
                                 "Retry button must use native Liquid Glass")
                }
                snapshot(view, "\(style)-error")
                await model.loadLyrics(using: lyricsService, forceRefresh: true)
                precondition(!model.failed && !model.loading && model.lyrics.lines.count == 8,
                             "Explicit retry must replace the error with fresh lyrics")
                model.language = model.language == .korean ? .english : .korean
                await model.loadLyrics(using: lyricsService)
                precondition(!model.failed && !model.loading && model.lyrics.lines.count == 8,
                             "Changing language must reload the same track")
                immersive.close()
                try? await Task.sleep(nanoseconds: 140_000_000)
                snapshot(view, "\(style)-closing-mid")
                try? await Task.sleep(nanoseconds: 610_000_000)
                precondition(!immersive.isVisible)
                precondition(!panel.isVisible && panel.contentView == nil)
                precondition(!background.isAnimating, "Closing releases background animations")
                precondition(!client.needsAudioCapture, "Closing releases background capture")
                let notchView = NSApp.windows.compactMap { $0.playerHostedView as? NSHostingView<NotchPlayerView> }.first!
                precondition(notchView.rootView.layout.isExpanded)
            }
            // Forced dismissal while the reverse animation is running must release immediately.
            immersive.show(client: client, screen: screen, sourceArtworkFrame: .zero, lyricsService: lyricsService)
            immersive.close()
            immersive.close(animated: false)
            precondition(!immersive.isVisible)
            try! "PASS: both styles, native Liquid Glass, full-size ambient layers, pause/resume/release, lyrics/queue/artwork modes, screen bounds, highlight, plain/error states, close/reopen\n".write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func snapshot(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

private extension NSWindow {
    var playerHostedView: NSView? { (contentView as? PlayerHostingContainer)?.hostedView ?? contentView }
}
