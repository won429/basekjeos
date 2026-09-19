import AppKit
import Combine

@main struct PlaybackOwnershipChecks {
    @MainActor static func main() throws {
        let client = MediaRemoteClient()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.addRepresentation(bitmap)
        let cover = bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
        func bridge(_ title: String, artist: String = "Bridge Artist", position: Double = 99,
                    playing: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "title": title, "artist": artist, "album": "Bridge Album", "duration": 181,
                "elapsedTime": position, "playbackRate": playing ? 1 : 0,
                "sourceApp": "YouTube Music", "artworkDataBase64": cover
            ])
        }
        func browser(_ title: String, position: Double = 20) {
            client.applyBrowserSnapshot(.init(processID: 999999, title: title, artist: "Browser Artist",
                elapsed: position, duration: 180, playing: true), bundle: "com.google.chrome")
        }
        client.applyBridgeData(try bridge("Song A"))
        browser("Song A")
        let revision = client.artworkPresentation.revision
        var titleEvents = 0
        let observation = client.$title.dropFirst().sink { _ in titleEvents += 1 }
        // Reproduce alternating source metadata, transport state and stale titles.
        for index in 0..<100 {
            client.applyBridgeData(try bridge(index.isMultiple(of: 2) ? "Song A" : "Old Song"))
            browser("Song A", position: 20 + Double(index) / 4)
            precondition(client.title == "Song A" && client.artist == "Browser Artist")
            precondition(client.duration == 180 && client.isPlaying)
            precondition(abs(client.elapsed - (20 + Double(index) / 4)) <= 1.1)
            precondition(client.artworkPresentation.revision == revision,
                         "Polling must not publish another cover or restart its rotation")
        }
        precondition(titleEvents == 0, "Repeated source samples must not announce new songs")
        browser("Song B")
        client.applyBridgeData(try bridge("Song B"))
        let nextRevision = client.artworkPresentation.revision
        precondition(nextRevision > revision)
        for _ in 0..<100 {
            client.applyBridgeData(try bridge("Song A"))
            client.applyBridgeData(try bridge("Song B"))
        }
        precondition(client.title == "Song B" && titleEvents == 1)
        precondition(client.artworkPresentation.revision == nextRevision)
        // Malformed transient browser data must not clear a valid presentation.
        client.applyBrowserSnapshot(.init(processID: 999999, title: "", artist: "",
            elapsed: .nan, duration: .nan, playing: false), bundle: nil)
        precondition(client.title == "Song B")
        withExtendedLifetime(observation) {}
        client.stop()
        print("PASS: 400 conflicting source samples, stable cover revision/metadata/clock, one real track transition, invalid sample rejection")
    }
}
