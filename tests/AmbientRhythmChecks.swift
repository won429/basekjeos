import Foundation
@main struct AmbientRhythmChecks {
    static func main() {
        precondition(AmbientRhythmEnergy.measure([]) == 0)
        precondition(AmbientRhythmEnergy.measure(Array(repeating: 0, count: 9)) == 0)
        precondition(AmbientRhythmEnergy.measure([0,0,0,1,1,1,1,0,0]) == 0)
        precondition(AmbientRhythmEnergy.measure([1,1,0,0,0,0,0,0,0]) > 0.8)
        precondition(AmbientRhythmEnergy.measure([0,0,0,0,0,0,0,1,1]) > 0.4)
        precondition(AmbientRhythmEnergy.measure(Array(repeating: .nan, count: 9)) == 0)
        print("PASS: silence, middle-band exclusion, bass/percussion response, invalid input")
    }
}
