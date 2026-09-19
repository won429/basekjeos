import Foundation

@main struct WaveformAnalysisPolicyChecks {
    static func main() {
        func cadence(
            playing: Bool = true,
            live: Bool = true,
            presentation: WaveformPresentation = .expanded,
            background: Bool = false
        ) -> WaveformAnalysisCadence {
            WaveformAnalysisPolicy.cadence(
                playbackActive: playing,
                liveMeterEnabled: live,
                presentation: presentation,
                hasVisibleBackground: background
            )
        }

        precondition(cadence(playing: false) == .stopped)
        precondition(cadence(presentation: .hidden) == .stopped)
        precondition(cadence(presentation: .compact) == .reduced)
        precondition(cadence(presentation: .expanded) == .full)
        precondition(cadence(live: false) == .stopped)
        precondition(cadence(live: false, presentation: .hidden, background: true) == .reduced)
        precondition(WaveformAnalysisCadence.reduced.framesPerSecond == 8)
        precondition(WaveformAnalysisCadence.full.framesPerSecond == 18)
        precondition(WaveformAnalysisCadence.stopped.minimumInterval == nil)
        print("PASS: paused and hidden stop, compact/background 8 Hz, expanded live meter 18 Hz")
    }
}
