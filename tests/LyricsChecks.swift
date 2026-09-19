import Foundation

actor Requests {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
}

@main struct LyricsChecks {
    static func main() async throws {
        let identity = LyricsRequestIdentity(track: LyricsTrack(
            title: " Same   Song ", artist: "Artist", album: "First", duration: 180
        ))
        let refinedIdentity = LyricsRequestIdentity(track: LyricsTrack(
            title: "same song", artist: "artist", album: "Deluxe", duration: 181
        ))
        precondition(identity == refinedIdentity,
                     "Album and duration refinements must not restart lyric loading")
        precondition(identity != LyricsRequestIdentity(track: LyricsTrack(
            title: "Next Song", artist: "Artist", album: "", duration: 180
        )))
        let parsed = TrackLyrics.parse("[offset:500]\n[ar:Example]\n[00:03.50][00:05.125]Two times\n[00:01.00]First\n[00:01.00]Translation\n[00:04.00]\n[00:99.0]Invalid")
        precondition(parsed.map(\.time) == [0.5, 3, 3.5, 4.625])
        precondition(parsed[0].text == "First\nTranslation")
        precondition(parsed[2].text.isEmpty)
        let lyrics = TrackLyrics(lines: parsed)
        precondition(lyrics.activeIndex(at: 0) == nil)
        precondition(lyrics.activeIndex(at: 3) == 1)
        precondition(lyrics.activeIndex(at: 100) == 3)
        precondition(lyrics.activeIndex(at: 0.5) == 0) // Backward seek.
        precondition(TrackLyrics.parse("[ar:Only metadata]\nplain text").isEmpty)
        precondition(TrackLyrics.parse("[offset:-250]\n[00:01]Late")[0].time == 1.25)
        let requests = Requests()
        let client = LyricsClient { request in
            let count = await requests.record(request)
            let status = count == 1 ? 404 : 200
            let data = Data(#"{"syncedLyrics":"[00:01]Test line","plainLyrics":"Test line","instrumental":false}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let track = LyricsTrack(title: "Title & + 한글", artist: "Artist", album: "Different edition", duration: 187)
        let loaded = try await client.lyrics(for: track, language: .english)
        precondition(loaded.lines.count == 1)
        let cached = try await client.lyrics(for: track, language: .english)
        precondition(cached == loaded)
        let recorded = await requests.requests
        precondition(recorded.count == 2, "Cache hit must not request again")
        let first = URLComponents(url: recorded[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(first.first { $0.name == "track_name" }?.value == track.title)
        precondition(first.contains { $0.name == "album_name" })
        let second = URLComponents(url: recorded[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(!second.contains { $0.name == "album_name" })
        precondition(second.first { $0.name == "duration" }?.value == "187")
        let errors = Requests()
        let failing = LyricsClient { request in
            _ = await errors.record(request)
            throw URLError(.notConnectedToInternet)
        }
        for _ in 0..<2 {
            do { _ = try await failing.lyrics(for: track, language: .english); preconditionFailure("Expected network error") }
            catch { }
        }
        let attempts = await errors.requests.count
        precondition(attempts == 2, "Transient errors must not be cached")
        let cancelled = Task { try await client.lyrics(for: track, language: .english) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {} catch { preconditionFailure("Wrong error") }
        await duplicateModelLoadChecks()
        try await retrievalChecks()
        print("PASS: LRC timing, offsets, translations, gaps, seeks, URL encoding, album fallback, cache, retry, cancellation")
    }

    @MainActor
    static func duplicateModelLoadChecks() async {
        let requests = Requests()
        let service = LyricsClient { request in
            _ = await requests.record(request)
            try await Task.sleep(nanoseconds: 80_000_000)
            let body = #"{"syncedLyrics":"[00:01]한 번만 불러옴","plainLyrics":"한 번만 불러옴"}"#
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let media = MediaRemoteClient()
        let model = ImmersivePlayerModel(client: media)
        model.track = LyricsTrack(title: "One Song", artist: "One Artist", album: "", duration: 180)
        async let first: Void = model.loadLyrics(using: service)
        async let duplicate: Void = model.loadLyrics(using: service)
        _ = await (first, duplicate)
        let requestCount = await requests.requests.count
        precondition(requestCount == 1,
                     "Concurrent view updates must share one lyric request")
        precondition(!model.loading && model.lyrics.lines.count == 1)
        let refresh = Task { await model.loadLyrics(using: service, forceRefresh: true) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        refresh.cancel() // SwiftUI cancels its task when the lyric pane disappears.
        await model.loadLyrics(using: service)
        await refresh.value
        let afterCancellation = await requests.requests.count
        precondition(afterCancellation == 2 && !model.loading && !model.failed,
                     "Leaving and returning during a lookup must complete without duplicate requests or a stuck spinner")

    }

    static func retrievalChecks() async throws {
        let track = LyricsTrack(title: "노래 (Official Music Video)", artist: "가수 및 참여 가수 - Topic", album: "", duration: 180)
        let requests = Requests()
        let client = LyricsClient { request in
            _ = await requests.record(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let normalized = query.first { $0.name == "track_name" }?.value == "노래"
            let body = request.url!.path == "/api/get" ? "{}" : normalized ? """
            [
              {"trackName":"노래","artistName":"다른 가수","duration":180,"plainLyrics":"틀린 아티스트"},
              {"trackName":"다른 노래","artistName":"가수","duration":180,"plainLyrics":"틀린 곡"},
              {"trackName":"노래","artistName":"가수","duration":240,"plainLyrics":"틀린 길이"},
              {"trackName":"노래 (Live)","artistName":"가수","duration":180,"plainLyrics":"다른 버전"},
              {"trackName":"노래","artistName":"가수","duration":184,"syncedLyrics":"[00:01]찾은 가사"}
            ]
            """ : "[]"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: request.url!.path == "/api/get" ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = try await client.lyrics(for: track, language: .korean)
        precondition(found.lines.first?.text == "찾은 가사", "Normalized search must validate title, artist, version and duration")
        let recorded = await requests.requests
        precondition(recorded.count == 3)
        precondition(!URLComponents(url: recorded.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "duration" })

        let bilingualTrack = LyricsTrack(title: "우리의 다정한 계절 속에 (Season of Memories)", artist: "여자친구", album: "", duration: 185)
        let bilingual = LyricsClient { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let englishTitle = query.first { $0.name == "track_name" }?.value == "Season of Memories"
            let body = request.url!.path == "/api/get" ? "{}" : englishTitle ? #"[{"trackName":"Season of Memories","artistName":"여자친구 (GFRIEND)","duration":187,"syncedLyrics":"[00:01]한글 가사"}]"# : "[]"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: request.url!.path == "/api/get" ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let bilingualResult = try await bilingual.lyrics(for: bilingualTrack, language: .korean)
        precondition(bilingualResult.lines.first?.text == "한글 가사", "Bilingual titles and artist aliases must find the Korean original")

        let plainTrack = LyricsTrack(title: "Song", artist: "Artist", album: "", duration: 180)
        let languageRequests = Requests()
        let languageClient = LyricsClient { request in
            _ = await languageRequests.record(request)
            let exact = #"{"syncedLyrics":"[00:01]Romanized words","plainLyrics":"Romanized words"}"#
            let search = #"[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"한글 원문"}]"#
            return (Data((request.url!.path == "/api/get" ? exact : search).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let english = try await languageClient.lyrics(for: plainTrack, language: .english)
        let korean = try await languageClient.lyrics(for: plainTrack, language: .korean)
        precondition(english.lines.first?.text == "Romanized words")
        precondition(korean.lines.isEmpty && korean.plain == "한글 원문", "Korean original takes priority over romanized timing")
        _ = try await languageClient.lyrics(for: plainTrack, language: .korean)
        var count = await languageRequests.requests.count
        precondition(count == 3, "Caches must be separate by language")
        _ = try await languageClient.lyrics(for: plainTrack, language: .korean, forceRefresh: true)
        count = await languageRequests.requests.count
        precondition(count == 5, "Explicit retry must bypass cache")

        let mixedClient = LyricsClient { request in
            let body = #"{"syncedLyrics":"[00:01]Romanized","plainLyrics":"한국어 가사"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let mixed = try await mixedClient.lyrics(for: plainTrack, language: .korean)
        precondition(mixed.lines.isEmpty && mixed.plain == "한국어 가사")

        let plainFallback = LyricsClient { request in
            let body = request.url!.path == "/api/get" ? "{}"
                : #"[{"trackName":"Song","artistName":"Artist","duration":240,"plainLyrics":"Untimed fallback lyrics"}]"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let relaxed = try await plainFallback.lyrics(for: plainTrack, language: .english)
        precondition(relaxed.lines.isEmpty && relaxed.plain == "Untimed fallback lyrics",
                     "Strong title/artist match should retain plain lyrics when edition duration differs")

        let misses = Requests()
        let missingClient = LyricsClient { request in
            let count = await misses.record(request)
            let body = count <= 2 ? (request.url!.path == "/api/get" ? #"{"syncedLyrics":"[00:01]   ","plainLyrics":"  "}"# : "[]") : #"{"plainLyrics":"Now available"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let missing = try await missingClient.lyrics(for: plainTrack, language: .english)
        precondition(missing.lines.isEmpty && missing.plain.isEmpty)
        let recovered = try await missingClient.lyrics(for: plainTrack, language: .english)
        precondition(recovered.plain == "Now available", "Empty lyrics must not be cached")

        for serverError in [false, true] {
            let attempts = Requests()
            let recovering = LyricsClient { request in
                let count = await attempts.record(request)
                if count == 1 && !serverError { throw URLError(.timedOut) }
                let status = count == 1 ? 503 : 200
                return (Data(#"{"plainLyrics":"Recovered"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let result = try await recovering.lyrics(for: plainTrack, language: .english)
            precondition(result.plain == "Recovered")
            let count = await attempts.requests.count
            precondition(count == 2, "Temporary failure gets one automatic retry")
        }
        let fallback = LyricsClient { request in
            if request.url!.path == "/api/search" { throw URLError(.notConnectedToInternet) }
            return (Data(#"{"plainLyrics":"Original lyrics"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let original = try await fallback.lyrics(for: plainTrack, language: .korean)
        precondition(original.plain == "Original lyrics", "Optional language search failure preserves usable lyrics")
        print("PASS: normalized search, wrong-song rejection, Korean preference, language cache, forced reload, uncached misses, transient retries, original fallback")
    }
}
