import SwiftUI

actor QueueArtworkLookup {
    static let shared = QueueArtworkLookup()
    private var cache: [String: URL] = [:]
    private var misses = Set<String>()
    private struct Response: Decodable { let results: [Track] }
    private struct Track: Decodable {
        let trackName: String?
        let artistName: String?
        let artworkUrl100: URL?
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func matches(title: String, artist: String, candidateTitle: String, candidateArtist: String) -> Bool {
        let a = normalized(artist), b = normalized(candidateArtist)
        return !a.isEmpty && !b.isEmpty && normalized(title) == normalized(candidateTitle)
            && (a == b || (min(a.count, b.count) >= 3 && (a.contains(b) || b.contains(a))))
    }
    func url(for item: PlaybackQueueItem) async -> URL? {
        if let url = item.artworkURL { return url }
        let key = item.title + "\n" + item.artist
        if let url = cache[key] { return url }
        guard !misses.contains(key), !item.artist.isEmpty else { return nil }
        for country in ["KR", "US"] {
            guard !Task.isCancelled else { return nil }
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [.init(name: "term", value: item.title + " " + item.artist),
                .init(name: "entity", value: "song"), .init(name: "limit", value: "8"),
                .init(name: "country", value: country)]
            do {
                var request = URLRequest(url: components.url!)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let result = try JSONDecoder().decode(Response.self, from: data)
                if let match = result.results.first(where: {
                    Self.matches(title: item.title, artist: item.artist,
                        candidateTitle: $0.trackName ?? "", candidateArtist: $0.artistName ?? "")
                }), let url = match.artworkUrl100 {
                    if cache.count >= 80 { cache.removeAll(keepingCapacity: true) }
                    cache[key] = url
                    return url
                }
            } catch { if Task.isCancelled { return nil } }
        }
        if !Task.isCancelled, let url = await youtubeURL(for: item) {
            if cache.count >= 80 { cache.removeAll(keepingCapacity: true) }
            cache[key] = url
            return url
        }
        if misses.count >= 80 { misses.removeAll(keepingCapacity: true) }
        misses.insert(key)
        return nil
    }
    private func youtubeURL(for item: PlaybackQueueItem) async -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [.init(name: "search_query", value: item.title + " " + item.artist + " official audio")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let regex = try NSRegularExpression(pattern: #"var ytInitialData = (\{.*?\});"#, options: [.dotMatchesLineSeparators])
            guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let json = String(html[range]).data(using: .utf8) else { return nil }
            let object = try JSONSerialization.jsonObject(with: json)
            return Self.youtubeArtwork(in: object, item: item)
        } catch { return nil }
    }

    static func youtubeArtwork(in object: Any, item: PlaybackQueueItem) -> URL? {
        func text(_ object: Any?) -> String {
            guard let value = object as? [String: Any] else { return "" }
            if let simple = value["simpleText"] as? String { return simple }
            return (value["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        if let dict = object as? [String: Any] {
            if let video = dict["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String {
                let title = normalized(text(video["title"]))
                let artistText = normalized(text(video["ownerText"]) + text(video["longBylineText"]))
                let target = normalized(item.title.components(separatedBy: " (feat.").first ?? item.title)
                let aliases = item.artist.components(separatedBy: CharacterSet(charactersIn: "()"))
                    .map(normalized).filter { !$0.isEmpty }
                if !target.isEmpty, title.contains(target), aliases.contains(where: { title.contains($0) || artistText.contains($0) }),
                   id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                    return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
                }
            }
            for value in dict.values { if let url = youtubeArtwork(in: value, item: item) { return url } }
        } else if let array = object as? [Any] {
            for value in array { if let url = youtubeArtwork(in: value, item: item) { return url } }
        }
        return nil
    }

}

struct QueueArtwork: View {
    let item: PlaybackQueueItem
    @State private var url: URL?
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: item) { url = await QueueArtworkLookup.shared.url(for: item) }
    }
}
