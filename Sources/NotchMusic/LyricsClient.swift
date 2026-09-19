import Foundation

struct LyricsTrack: Hashable {
    let title: String
    let artist: String
    let album: String
    let duration: Int
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

struct TrackLyrics: Equatable {
    var lines: [LyricLine] = []
    var plain: String = ""
    var instrumental = false

    // Multiple timestamps, millisecond fractions, and LRC offsets are supported.
    static func parse(_ lrc: String) -> [LyricLine] {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2}(?:\.\d+)?)\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let fullRange = NSRange(lrc.startIndex..., in: lrc)
        let offset = offsetPattern.firstMatch(in: lrc, range: fullRange)
            .flatMap { Range($0.range(at: 1), in: lrc) }
            .flatMap { Double(lrc[$0]) }.map { $0 / 1000 } ?? 0
        var entries: [(Double, String)] = []
        for row in lrc.components(separatedBy: .newlines) {
            let matches = timestamp.matches(in: row, range: NSRange(row.startIndex..., in: row))
            guard let last = matches.last, let end = Range(last.range, in: row)?.upperBound else { continue }
            let text = row[end...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let m = Range(match.range(at: 1), in: row), let s = Range(match.range(at: 2), in: row),
                      let minutes = Double(row[m]), let seconds = Double(row[s]), seconds < 60 else { continue }
                entries.append((max(0, minutes * 60 + seconds - offset), text))
            }
        }
        // Combine translations sharing a timestamp; retain empty instrumental gaps.
        let sorted = entries.enumerated().sorted { $0.element.0 == $1.element.0
            ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
        var result: [LyricLine] = []
        for entry in sorted.map(\.element) {
            if let last = result.last, last.time == entry.0 {
                result[result.count - 1] = LyricLine(id: last.id, time: last.time,
                    text: [last.text, entry.1].filter { !$0.isEmpty }.joined(separator: "\n"))
            } else {
                result.append(LyricLine(id: result.count, time: entry.0, text: entry.1))
            }
        }
        return result
    }

    func activeIndex(at elapsed: Double) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= elapsed { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

actor LyricsClient {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let shared = LyricsClient()
    private struct CacheKey: Hashable {
        let track: LyricsTrack
        let language: AppLanguage
    }
    private let fetch: Fetch
    private var cache: [CacheKey: TrackLyrics] = [:]
    private var order: [CacheKey] = []

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) { self.fetch = fetch }

    func lyrics(for track: LyricsTrack, language: AppLanguage = .systemDefault,
                forceRefresh: Bool = false) async throws -> TrackLyrics {
        try Task.checkCancellation()
        let key = CacheKey(track: track, language: language)
        if forceRefresh {
            cache.removeValue(forKey: key)
            order.removeAll { $0 == key }
        } else if let cached = cache[key] { return cached }
        guard !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return TrackLyrics() }
        var best: TrackLyrics?
        var relaxedPlainFallback: TrackLyrics?
        var lastError: Error?
        let normalized = LyricsTrack(title: Self.cleanTitle(track.title), artist: Self.cleanArtist(track.artist),
                                     album: track.album, duration: track.duration)
        // Exact metadata is cheapest. Album editions often differ between providers.
        for includeAlbum in track.album.isEmpty ? [false] : [true, false] {
            do {
                if let data = try await request(path: "get", items: Self.items(track, album: includeAlbum, duration: true)) {
                    let candidate = try JSONDecoder().decode(Response.self, from: data).lyrics(language: language)
                    if candidate.isAvailable { best = candidate; break }
                }
            } catch {
                try Task.checkCancellation()
                // Retrying an unavailable host with different metadata cannot help.
                throw error
            }
        }
        // Search ignores exact duration/album requirements, but validates the returned
        // identity and timing before accepting a result. Also look for Hangul alternatives.
        if best == nil || (language == .korean && best?.containsKorean == false && best?.instrumental == false) {
            var searches = [track]
            for title in Self.aliases(normalized.title) {
                let query = LyricsTrack(title: title, artist: normalized.artist, album: track.album, duration: track.duration)
                if !searches.contains(query) { searches.append(query) }
            }
            var bestScore = best.map { Self.quality($0, language: language) } ?? -1
            for query in searches {
                do {
                    if let data = try await request(path: "search", items: Self.items(query, album: false, duration: false)) {
                        let results = try JSONDecoder().decode([Response].self, from: data)
                        for response in results {
                            let candidate = response.lyrics(language: language)
                            guard response.matchesIdentity(normalized) else { continue }
                            if !candidate.plain.isEmpty,
                               relaxedPlainFallback.map({
                                   Self.quality(candidate, language: language)
                                       > Self.quality($0, language: language)
                               }) ?? true {
                                relaxedPlainFallback = TrackLyrics(
                                    lines: [],
                                    plain: candidate.plain,
                                    instrumental: candidate.instrumental
                                )
                            }
                            guard response.matches(normalized) else { continue }
                            guard candidate.isAvailable else { continue }
                            let score = Self.quality(candidate, language: language)
                            if score > bestScore { best = candidate; bestScore = score }
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                }
                if let best, language != .korean || best.containsKorean || best.instrumental { break }
            }
        }
        try Task.checkCancellation()
        if let relaxedPlainFallback {
            if let current = best {
                if Self.quality(relaxedPlainFallback, language: language)
                    > Self.quality(current, language: language) {
                    best = relaxedPlainFallback
                }
            } else {
                best = relaxedPlainFallback
            }
        }
        guard let best else {
            if let lastError { throw lastError }
            // A miss may become a hit on retry; never retain negative results.
            return TrackLyrics()
        }
        if lastError == nil {
            cache[key] = best
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > 40 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return best
    }

    private static func quality(_ lyrics: TrackLyrics, language: AppLanguage) -> Int {
        (language == .korean && lyrics.containsKorean ? 100 : 0)
            + (!lyrics.lines.isEmpty ? 10 : 0) + (!lyrics.plain.isEmpty ? 1 : 0)
    }

    private struct Response: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?

        func lyrics(language: AppLanguage) -> TrackLyrics {
            var lines = TrackLyrics.parse(syncedLyrics ?? "")
            let plain = (plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { lines = [] }
            // Some entries pair romanized timed lyrics with the original Korean plain text.
            if language == .korean, TrackLyrics.hasKorean(plain),
               !lines.contains(where: { TrackLyrics.hasKorean($0.text) }) { lines = [] }
            return TrackLyrics(lines: lines, plain: plain, instrumental: instrumental ?? false)
        }

        func matches(_ track: LyricsTrack) -> Bool {
            guard matchesIdentity(track) else { return false }
            if track.duration > 0 {
                guard let duration, duration.isFinite,
                      abs(duration - Double(track.duration)) <= max(8, Double(track.duration) * 0.05) else { return false }
            }
            return true
        }

        func matchesIdentity(_ track: LyricsTrack) -> Bool {
            guard let trackName, let artistName else { return false }
            return LyricsClient.sameName(LyricsClient.cleanTitle(trackName), track.title)
                && LyricsClient.sameName(LyricsClient.cleanArtist(artistName), track.artist)
        }
    }

    private static func cleanTitle(_ value: String) -> String {
        // Strip video/credit decorations, retaining live/remix/version qualifiers.
        value.replacingOccurrences(of: #"(?i)\s*[\(\[]\s*(?:official(?:\s+(?:music|lyric))?\s*(?:video|audio|visualizer)?|lyrics?|가사|뮤직비디오|M/?V|HD|4K)\s*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*[\(\[]\s*(?:feat\.?|ft\.?)\s+[^\)\]]+[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanArtist(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\s+-\s+Topic$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?)\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:및|&)\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Korean releases often carry both names: “한국어 제목 (English Title)”.
    // Only split cross-script aliases; performance/version qualifiers stay attached.
    private static func aliases(_ value: String) -> [String] {
        let pattern = #"^(.+?)\s*[\(\[]([^\)\]]+)[\)\]]$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let baseRange = Range(match.range(at: 1), in: value),
              let aliasRange = Range(match.range(at: 2), in: value) else { return [value] }
        let base = String(value[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = String(value[aliasRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let qualifiers = #"(?i)\b(live|remix|mix|remaster(?:ed)?|version|ver|instrumental|acoustic|edit|sped|slowed|cover|karaoke)\b|버전|라이브|리믹스|어쿠스틱"#
        guard TrackLyrics.hasKorean(base) != TrackLyrics.hasKorean(alias),
              alias.range(of: qualifiers, options: .regularExpression) == nil else { return [value] }
        return [value, base, alias]
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        !Set(aliases(lhs).map(identity)).isDisjoint(with: aliases(rhs).map(identity))
    }

    private static func identity(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let stripped = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return stripped.isEmpty ? folded : String(String.UnicodeScalarView(stripped))
    }

    private static func items(_ track: LyricsTrack, album: Bool, duration: Bool) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if album, !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if duration, (1...3600).contains(track.duration) {
            items.append(URLQueryItem(name: "duration", value: String(track.duration)))
        }
        return items
    }

    private func request(path: String, items: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("NotchMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await fetch(request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 404 { return nil }
                if [502, 503, 504].contains(http.statusCode), attempt == 0 {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }
                guard http.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
                return data
            } catch let error as URLError where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw URLError(.badServerResponse)
    }
}

private extension TrackLyrics {
    var isAvailable: Bool { instrumental || !lines.isEmpty || !plain.isEmpty }
    var containsKorean: Bool {
        // Check the text actually displayed, rather than hidden plain lyrics.
        lines.isEmpty ? Self.hasKorean(plain) : lines.contains { Self.hasKorean($0.text) }
    }
    static func hasKorean(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value)
            || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }
}
