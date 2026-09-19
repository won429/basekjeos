import AppKit
import ApplicationServices

struct VolumeKeyInput {
    enum Action: Int { case increase = 0, decrease = 1, brightnessIncrease = 2, brightnessDecrease = 3, mute = 7 }
    let action: Action
    let isDown: Bool
    let isRepeat: Bool
    let fine: Bool

    init?(data: Int, fine: Bool) {
        let bits = UInt32(truncatingIfNeeded: data)
        guard let action = Action(rawValue: Int(bits >> 16)) else { return nil }
        let state = (bits >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        self.action = action
        isDown = state == 0x0a
        isRepeat = bits & 1 != 0
        self.fine = fine
    }

    var isBrightness: Bool { action == .brightnessIncrease || action == .brightnessDecrease }

    func brightnessTarget(from current: Float) -> Float {
        let step: Float = fine ? 1 / 64 : 1 / 16
        return min(max(current + (action == .brightnessIncrease ? step : -step), 0), 1)
    }

    func target(from current: OutputVolumeSnapshot) -> OutputVolumeSnapshot {
        if action == .mute { return .init(level: current.level, muted: !current.muted) }
        let step: Float = fine ? 1 / 64 : 1 / 16
        let base = current.muted ? 0 : current.level
        return .init(level: min(max(base + (action == .increase ? step : -step), 0), 1), muted: false)
    }
}

@MainActor final class VolumeKeyInterceptor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed = Set<Int>()
    private let apply: (VolumeKeyInput) -> Bool
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(apply: @escaping (VolumeKeyInput) -> Bool) { self.apply = apply }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1) << 14,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<VolumeKeyInterceptor>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.swallowed.removeAll()
                        if let tap = owner.tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    guard type.rawValue == 14, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8,
                          let input = VolumeKeyInput(data: key.data1,
                              fine: key.modifierFlags.contains([.shift, .option])) else {
                        return Unmanaged.passUnretained(event)
                    }
                    return owner.consume(input) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Never swallow a key unless the device actually accepted our adjustment.
    func consume(_ input: VolumeKeyInput) -> Bool {
        let code = input.action.rawValue
        if !input.isDown { return swallowed.remove(code) != nil }
        if input.action == .mute && input.isRepeat { return swallowed.contains(code) }
        guard apply(input) else { swallowed.remove(code); return false }
        swallowed.insert(code)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowed.removeAll()
    }
}
