import AppKit
import SwiftUI

@main
struct ArtworkPresentationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ArtworkPreviewDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class ArtworkPreviewDelegate: NSObject, NSApplicationDelegate {
    var client: MediaRemoteClient!
    var controller: NotchPanelController!
    let output = URL(fileURLWithPath: "/tmp/notch-artwork-review")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        client = MediaRemoteClient(lowPowerMode: LowPowerModeController(readState: { false }, changeState: { _ in }))
        controller = NotchPanelController(mediaClient: client, presentationStyle: .notch)
        controller.show(expanded: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            precondition(client.title == "재생 중이 아님" && client.artworkPresentation.image == nil)
            snapshot("empty")
            setenv("NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE", "1", 1)
            client.loadSnapshotPreview()
            try? await Task.sleep(nanoseconds: 100_000_000)
            let firstPalette = client.waveformColors
            let firstRevision = client.artworkPresentation.revision
            precondition(firstPalette == ArtworkPalette.colors(from: client.artworkPresentation.image!))
            snapshot("first")
            // Fixture delivers the second cover at 250 ms; its visible face
            // changes 200 ms later. The palette must not jump ahead of the face.
            try? await Task.sleep(nanoseconds: 240_000_000)
            precondition(client.artworkPresentation.revision > firstRevision)
            precondition(client.waveformColors == firstPalette, "Keep outgoing cover colors until the flip midpoint")
            snapshot("before-swap")
            try? await Task.sleep(nanoseconds: 360_000_000)
            precondition(client.waveformColors != firstPalette)
            precondition(client.waveformColors == ArtworkPalette.colors(from: client.artworkPresentation.image!))
            snapshot("second")
            try! "PASS: empty label, neutral fallback, palette follows visible cover at flip midpoint\n"
                .write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    func snapshot(_ name: String) {
        let view = NSApp.windows.first { $0.contentView is NSHostingView<NotchPlayerView> }!.contentView!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}
