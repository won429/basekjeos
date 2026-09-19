import AppKit

@main struct VolumeKeyChecks {
    @MainActor static func main() {
        func key(_ code: Int, down: Bool = true, repeat repeated: Bool = false, fine: Bool = false) -> VolumeKeyInput {
            VolumeKeyInput(data: code << 16 | (down ? 0x0a00 : 0x0b00) | (repeated ? 1 : 0), fine: fine)!
        }
        precondition(VolumeKeyInput(data: 16 << 16 | 0x0a00, fine: false) == nil, "Playback keys pass through")
        precondition(VolumeKeyInput(data: 0x0c00, fine: false) == nil)
        let current = OutputVolumeSnapshot(level: 0.5, muted: false)
        precondition(key(0).target(from: current).level == 0.5625)
        precondition(key(1, fine: true).target(from: current).level == 0.484375)
        precondition(key(7).target(from: current).muted)
        precondition(key(0).target(from: .init(level: 1, muted: false)).level == 1)
        precondition(key(1).target(from: .init(level: 0, muted: false)).level == 0)
        precondition(key(0).target(from: .init(level: 0.5, muted: true)) == .init(level: 0.0625, muted: false))
        precondition(key(2).isBrightness && key(3).isBrightness)
        precondition(!key(0).isBrightness && !key(7).isBrightness)
        precondition(key(2).brightnessTarget(from: 0.5) == 0.5625)
        precondition(key(3, fine: true).brightnessTarget(from: 0.5) == 0.484375)
        precondition(key(2).brightnessTarget(from: 1) == 1)
        precondition(key(3).brightnessTarget(from: 0) == 0)
        var succeeds = true
        var writes = 0
        let interceptor = VolumeKeyInterceptor { _ in writes += 1; return succeeds }
        precondition(interceptor.consume(key(0)))
        precondition(interceptor.consume(key(0, repeat: true)))
        precondition(interceptor.consume(key(0, down: false)))
        precondition(writes == 2, "Key-up never changes volume")
        precondition(interceptor.consume(key(7)))
        precondition(interceptor.consume(key(7, repeat: true)))
        precondition(writes == 3, "Holding mute does not toggle repeatedly")
        precondition(interceptor.consume(key(7, down: false)))
        succeeds = false
        precondition(!interceptor.consume(key(1)), "Failed writes pass to system")
        precondition(!interceptor.consume(key(1, down: false)))
        precondition(!interceptor.consume(key(2)), "Unsupported brightness stays with macOS")
        precondition(!interceptor.consume(key(2, down: false)))
        succeeds = true
        precondition(interceptor.consume(key(2)))
        precondition(interceptor.consume(key(2, repeat: true)))
        precondition(interceptor.consume(key(2, down: false)))
        interceptor.stop()
        precondition(!interceptor.consume(key(0, down: false)))
        print("PASS: media key filtering, normal/fine steps, mute, limits, repeat, key-up, failure passthrough")
    }
}
