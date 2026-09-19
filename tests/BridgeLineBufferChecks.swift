import Foundation

@main
struct BridgeLineBufferChecks {
    static func main() throws {
        let buffer = BridgeLineBuffer()
        let song = try JSONSerialization.data(withJSONObject: ["title": "새 노래 🎵", "artworkDataBase64": String(repeating: "A", count: 300_000)])
        let next = try JSONSerialization.data(withJSONObject: ["title": "다음 곡"])
        let input = song + Data([10, 10]) + next + Data([10])
        var received: [Data] = []
        // Deliberately split JSON strings, Unicode scalars, and a cover larger than a pipe buffer.
        for offset in stride(from: 0, to: input.count, by: 7) {
            buffer.consume(Data(input[offset..<min(offset + 7, input.count)])) { received.append($0) }
        }
        precondition(received == [song, next])
        buffer.consume(Data("{\"title\":\"unfinished".utf8)) { _ in preconditionFailure("Partial record escaped") }
        buffer.consume(Data("\"}\n".utf8)) { received.append($0) }
        precondition(received.count == 3)

        let started = Date(timeIntervalSince1970: 100)
        precondition(NowPlayingStreamHealth.isResponsive(startedAt: started, lastDataAt: nil,
                                                         now: Date(timeIntervalSince1970: 104.9)))
        precondition(!NowPlayingStreamHealth.isResponsive(startedAt: started, lastDataAt: nil,
                                                          now: Date(timeIntervalSince1970: 105.1)))
        let heartbeat = Date(timeIntervalSince1970: 104)
        precondition(NowPlayingStreamHealth.isResponsive(startedAt: started, lastDataAt: heartbeat,
                                                         now: Date(timeIntervalSince1970: 108.9)))
        precondition(!NowPlayingStreamHealth.isResponsive(startedAt: started, lastDataAt: heartbeat,
                                                          now: Date(timeIntervalSince1970: 109.1)))

        print("Bridge stream passed: framing, heartbeat health and fresh playback updates")
    }
}
