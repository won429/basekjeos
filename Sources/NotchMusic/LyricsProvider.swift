import Foundation

enum LyricsProvider: String, CaseIterable {
    case lrclib
    case youtubeMusic

    static let defaultsKey = "lyricsProvider"
    static let defaultProvider = LyricsProvider.lrclib
    var title: String {
        switch self { case .lrclib: return "LRCLIB"; case .youtubeMusic: return "YouTube Music" }
    }
    static func load(from defaults: UserDefaults = .standard) -> LyricsProvider {
        guard let raw = defaults.string(forKey: defaultsKey), let value = LyricsProvider(rawValue: raw) else { return defaultProvider }
        return value
    }
}
