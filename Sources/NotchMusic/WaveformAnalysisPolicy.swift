import Foundation

enum WaveformPresentation: Equatable {
    case hidden
    case compact
    case expanded
}

enum WaveformAnalysisCadence: Equatable {
    case stopped
    case reduced
    case full

    var framesPerSecond: Double {
        switch self {
        case .stopped: return 0
        case .reduced: return 8
        case .full: return 18
        }
    }

    var minimumInterval: TimeInterval? {
        framesPerSecond > 0 ? 1 / framesPerSecond : nil
    }
}

enum WaveformAnalysisPolicy {
    static func cadence(
        playbackActive: Bool,
        liveMeterEnabled: Bool,
        presentation: WaveformPresentation,
        hasVisibleBackground: Bool
    ) -> WaveformAnalysisCadence {
        guard playbackActive else { return .stopped }
        if hasVisibleBackground {
            return liveMeterEnabled && presentation == .expanded ? .full : .reduced
        }
        guard liveMeterEnabled else { return .stopped }
        switch presentation {
        case .hidden: return .stopped
        case .compact: return .reduced
        case .expanded: return .full
        }
    }
}
