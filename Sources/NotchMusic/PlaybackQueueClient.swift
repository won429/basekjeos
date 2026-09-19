import AppKit
import ApplicationServices

struct PlaybackQueueItem: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let artist: String
    var artworkURL: URL? = nil
    var sourceProcessID: pid_t? = nil
}

struct QueueAccessibilityToken: Sendable {
    let role: String
    let text: String
    var url: URL? = nil
}

enum PlaybackQueueError: Error {
    case permissionRequired, unavailable
}

// Only the active YouTube Music page is inspected, on demand while queue is open.
// No cookies, account data, recommendation feeds or browsing history are read.
actor PlaybackQueueClient {
    static let shared = PlaybackQueueClient()

    func load(processID: pid_t, currentTitle: String) async throws -> [PlaybackQueueItem] {
        guard AXIsProcessTrusted() else { throw PlaybackQueueError.permissionRequired }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Finding the web area must not consume the budget by walking its contents.
        func findPage() -> AXUIElement? {
            scan(app, deadline: Date().addingTimeInterval(2), stopAtWebArea: true)
                .first(where: { $0.token.role == "AXWebArea" && isMusicPage($0.element) })?.element
        }
        guard var page = findPage() else { throw PlaybackQueueError.unavailable }
        var nodes = scan(page, deadline: Date().addingTimeInterval(5))
        if let open = nodes.first(where: { ["플레이어 페이지 열기", "Open player page"].contains($0.token.text) }) {
            AXUIElementPerformAction(open.element, kAXPressAction as CFString)
            try await Task.sleep(nanoseconds: 350_000_000)
            // Navigation can replace the original accessibility web area.
            page = findPage() ?? page
            nodes = scan(page, deadline: Date().addingTimeInterval(5))
        }
        if let next = nodes.first(where: { ["다음 트랙", "Up next", "UP NEXT"].contains($0.token.text) }) {
            AXUIElementPerformAction(next.element, kAXPressAction as CFString)
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: 350_000_000) }
            page = findPage() ?? page
            nodes = scan(page, deadline: Date().addingTimeInterval(5))
            if let result = try? Self.parse(nodes.map(\.token), currentTitle: currentTitle) { return result }
        }
        throw PlaybackQueueError.unavailable
    }

    func play(processID: pid_t, item: PlaybackQueueItem, currentTitle: String) async throws {
        guard AXIsProcessTrusted() else { throw PlaybackQueueError.permissionRequired }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: 180_000_000) }
            guard let page = scan(app, deadline: Date().addingTimeInterval(2), stopAtWebArea: true)
                .first(where: { $0.token.role == "AXWebArea" && isMusicPage($0.element) })?.element else { continue }
            let nodes = scan(page, deadline: Date().addingTimeInterval(5))
            guard let tokenIndex = Self.playButtonTokenIndex(
                in: nodes.map(\.token),
                currentTitle: currentTitle,
                item: item
            ) else { continue }
            guard AXUIElementPerformAction(nodes[tokenIndex].element, kAXPressAction as CFString) == .success else {
                continue
            }
            return
        }
        throw PlaybackQueueError.unavailable
    }

    static func playButtonTokenIndex(
        in tokens: [QueueAccessibilityToken],
        currentTitle: String,
        item: PlaybackQueueItem
    ) -> Int? {
        var inQueue = false
        var buttons: [(tokenIndex: Int, title: String)] = []
        for (index, token) in tokens.enumerated() {
            if ["다음 트랙", "Up next", "UP NEXT"].contains(token.text) {
                inQueue = true
                continue
            }
            guard inQueue else { continue }
            if token.role == "AXToolbar" { break }
            if token.role == "AXButton", let title = playableTitle(token.text) {
                buttons.append((index, title))
            }
        }
        guard let current = buttons.firstIndex(where: { normalized($0.title) == normalized(currentTitle) }) else {
            return nil
        }
        let target = current + item.id + 1
        guard buttons.indices.contains(target),
              normalized(buttons[target].title) == normalized(item.title) else { return nil }
        return buttons[target].tokenIndex
    }

    static func parse(_ tokens: [QueueAccessibilityToken], currentTitle: String) throws -> [PlaybackQueueItem] {
        var inQueue = false
        var rows: [(String, [String], URL?)] = []
        for token in tokens {
            if ["다음 트랙", "Up next", "UP NEXT"].contains(token.text) { inQueue = true; continue }
            guard inQueue else { continue }
            if token.role == "AXToolbar" { break }
            if token.role == "AXButton" {
                let suffixes = [" 일시중지", " 일시 중지", " 재생"]
                if let suffix = suffixes.first(where: { token.text.hasSuffix($0) }), token.text.count > suffix.count {
                    rows.append((String(token.text.dropLast(suffix.count)), [], nil))
                } else if token.text.hasPrefix("Play ") || token.text.hasPrefix("Pause ") {
                    rows.append((String(token.text.dropFirst(token.text.hasPrefix("Play ") ? 5 : 6)), [], nil))
                }
            }
            if !rows.isEmpty, rows[rows.count - 1].2 == nil, let url = token.url,
               let artwork = artworkURL(from: url) { rows[rows.count - 1].2 = artwork }
            if token.role == "AXStaticText", !rows.isEmpty {
                rows[rows.count - 1].1.append(token.text)
            }
        }
        func normalized(_ title: String) -> String { Self.normalized(title) }
        guard let current = rows.firstIndex(where: { normalized($0.0) == normalized(currentTitle) }) else {
            throw PlaybackQueueError.unavailable
        }
        return rows.dropFirst(current + 1).prefix(60).enumerated().map { index, row in
            let details = row.1.filter { $0 != row.0 && $0.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) == nil }
            var artist = details.joined(separator: " ")
            if artist.hasPrefix(row.0) { artist = String(artist.dropFirst(row.0.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            return PlaybackQueueItem(id: index, title: row.0, artist: artist, artworkURL: row.2)
        }
    }

    private static func playableTitle(_ text: String) -> String? {
        let suffixes = [" 일시중지", " 일시 중지", " 재생"]
        if let suffix = suffixes.first(where: { text.hasSuffix($0) }), text.count > suffix.count {
            return String(text.dropLast(suffix.count))
        }
        if text.hasPrefix("Play ") { return String(text.dropFirst(5)) }
        if text.hasPrefix("Pause ") { return String(text.dropFirst(6)) }
        return nil
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func artworkURL(from url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        if host == "i.ytimg.com" || host.hasSuffix(".googleusercontent.com") || host == "lh3.googleusercontent.com" {
            return url
        }
        if host == "music.youtube.com" || host == "www.youtube.com" {
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
                  id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return nil
    }

    private struct Node { let element: AXUIElement; let token: QueueAccessibilityToken }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func isMusicPage(_ element: AXUIElement) -> Bool {
        let value = attribute(element, kAXURLAttribute)
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        return url?.host?.lowercased() == "music.youtube.com"
    }
    private func scan(_ root: AXUIElement, deadline: Date, stopAtWebArea: Bool = false) -> [Node] {
        var result: [Node] = []
        var pending = [(root, 0)]
        while let (element, depth) = pending.popLast(), result.count < 3500, Date() < deadline {
            if Task.isCancelled { break }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            // Reject unrelated pages before traversing their content.
            if role == "AXWebArea", !isMusicPage(element) { continue }
            let names = role == "AXStaticText" ? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            let text = names.lazy.compactMap { self.attribute(element, $0) as? String }.first { !$0.isEmpty } ?? ""
            let rawURL = ["AXURL", "AXImageURL"].lazy.compactMap { self.attribute(element, $0) }.first
            let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            result.append(Node(element: element, token: QueueAccessibilityToken(role: role, text: text, url: url)))
            if stopAtWebArea && role == "AXWebArea" { continue }
            if depth < 30, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }
}
