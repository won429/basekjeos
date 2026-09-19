import Foundation

enum BackgroundGraphicsMode: String, CaseIterable {
    case basic
    case waveform

    static let defaultsKey = "backgroundGraphicsMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .basic
    }
    var title: String { self == .basic ? "기본 모드" : "동작 모드" }
}
