import CoreAudio
import Foundation

struct OutputVolumeSnapshot: Equatable {
    let level: Float
    let muted: Bool
}

@MainActor final class OutputVolumeMonitor {
    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: OutputVolumeSnapshot?
    private var running = false
    private let changed: (OutputVolumeSnapshot) -> Void
    private let stateChanged: (OutputVolumeSnapshot?, Bool) -> Void

    init(changed: @escaping (OutputVolumeSnapshot) -> Void,
         stateChanged: @escaping (OutputVolumeSnapshot?, Bool) -> Void = { _, _ in }) {
        self.changed = changed
        self.stateChanged = stateChanged
    }
    func start() {
        guard !running else { return }
        running = true
        observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                scope: kAudioObjectPropertyScopeGlobal, channel: 0, deviceChanged: true)
        bindDevice()
    }
    func stop() {
        running = false
        for var observation in observations {
            AudioObjectRemovePropertyListenerBlock(observation.object, &observation.address, .main, observation.block)
        }
        observations.removeAll()
        last = nil
        stateChanged(nil, false)
    }
    private func bindDevice() {
        for var observation in observations where observation.object != kAudioObjectSystemObject {
            AudioObjectRemovePropertyListenerBlock(observation.object, &observation.address, .main, observation.block)
        }
        observations.removeAll { $0.object != kAudioObjectSystemObject }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            stateChanged(nil, false)
            return
        }
        for channel: UInt32 in [0, 1, 2] {
            observe(device, kAudioDevicePropertyVolumeScalar, channel: channel)
            observe(device, kAudioDevicePropertyMute, channel: channel)
        }
        last = readSnapshot() // Switching devices alone is not a volume adjustment.
        stateChanged(last, canSetVolume)
    }
    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                         channel: UInt32, deviceChanged: Bool = false) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: channel)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                if deviceChanged { self.bindDevice() } else { self.sample() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            observations.append(Observation(object: object, address: address, block: block))
        }
    }
    private func scalar(_ selector: AudioObjectPropertySelector, channel: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
        var result: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr,
              result.isFinite else { return nil }
        return min(max(result, 0), 1)
    }
    private func readSnapshot() -> OutputVolumeSnapshot? {
        let channels = [UInt32(1), 2].compactMap { scalar(kAudioDevicePropertyVolumeScalar, channel: $0) }
        guard let level = scalar(kAudioDevicePropertyVolumeScalar, channel: 0)
            ?? (channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address) { _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) }
        return OutputVolumeSnapshot(level: level, muted: muted != 0)
    }
    func adjust(_ input: VolumeKeyInput) -> Bool {
        guard running, let before = readSnapshot() else { return false }
        return apply(input.target(from: before), before: before, showsFeedback: true)
    }

    var canSetVolume: Bool {
        guard running else { return false }
        let channels: [UInt32] = scalar(kAudioDevicePropertyVolumeScalar, channel: 0) != nil ? [0] : [1, 2]
        let available = channels.filter { scalar(kAudioDevicePropertyVolumeScalar, channel: $0) != nil }
        return !available.isEmpty && available.allSatisfy { channel in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
    }

    func setLevel(_ level: Float) -> Bool {
        guard level.isFinite, canSetVolume, let before = readSnapshot() else { return false }
        return apply(OutputVolumeSnapshot(level: min(max(level, 0), 1), muted: false),
                     before: before, showsFeedback: false)
    }

    private func apply(_ target: OutputVolumeSnapshot, before: OutputVolumeSnapshot, showsFeedback: Bool) -> Bool {
        var writes: [(AudioObjectPropertyAddress, Float, Float)] = []
        if abs(target.level - before.level) > 0.0001 {
            let channels: [UInt32] = scalar(kAudioDevicePropertyVolumeScalar, channel: 0) != nil ? [0] : [1, 2]
            for channel in channels {
                guard let old = scalar(kAudioDevicePropertyVolumeScalar, channel: channel) else { continue }
                let address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
                writes.append((address, old, target.level))
            }
            guard !writes.isEmpty else { return false }
        }
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
        let changesMute = before.muted != target.muted
        for var entry in writes {
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &entry.0, &settable) == noErr, settable.boolValue else { return false }
        }
        if changesMute {
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue else { return false }
        }
        func rollback() {
            for var entry in writes {
                _ = AudioObjectSetPropertyData(device, &entry.0, 0, nil, 4, &entry.1)
            }
            if changesMute {
                var old: UInt32 = before.muted ? 1 : 0
                _ = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, 4, &old)
            }
        }
        for var entry in writes {
            guard AudioObjectSetPropertyData(device, &entry.0, 0, nil, 4, &entry.2) == noErr else {
                rollback(); return false
            }
        }
        if changesMute {
            var muted: UInt32 = target.muted ? 1 : 0
            guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, 4, &muted) == noErr else {
                rollback(); return false
            }
        }
        guard let actual = readSnapshot(), abs(actual.level - target.level) < 0.015,
              actual.muted == target.muted else { rollback(); return false }
        last = actual
        stateChanged(actual, canSetVolume)
        if showsFeedback { changed(actual) } // The immersive slider does not collapse the underlying notch.
        return true
    }

    private func sample() {
        guard let value = readSnapshot(), value != last else { return }
        last = value
        stateChanged(value, canSetVolume)
        changed(value)
    }
}
