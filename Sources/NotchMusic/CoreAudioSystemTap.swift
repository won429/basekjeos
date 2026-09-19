import AudioToolbox
import CoreAudio
import Foundation

final class CoreAudioSystemTap {
    private let queue = DispatchQueue(label: "com.notchmusic.core-audio-tap", qos: .userInteractive)
    private let onSamples: @Sendable ([Float], Double) -> Void
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var lastSampleTime: TimeInterval = 0
    private var analysisFramesPerSecond = WaveformAnalysisCadence.full.framesPerSecond
    private var streamDescription = AudioStreamBasicDescription()

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void) {
        self.onSamples = onSamples
    }

    func setAnalysisCadence(_ cadence: WaveformAnalysisCadence) {
        queue.async { [weak self] in
            self?.analysisFramesPerSecond = cadence.framesPerSecond
        }
    }

    @available(macOS 14.2, *)
    func start() throws {
        guard processTapID == kAudioObjectUnknown,
              aggregateDeviceID == kAudioObjectUnknown else { return }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Nook Spectrum"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        processTapID = tapID

        do {
            streamDescription = try readTapFormat(tapID)
            let outputDevice = try readDefaultSystemOutputDevice()
            let outputUID = try readDeviceUID(outputDevice)
            let aggregateUID = "com.notchmusic.tap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "Nook Audio Tap",
                kAudioAggregateDeviceUIDKey as String: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceIsStackedKey as String: false,
                kAudioAggregateDeviceTapAutoStartKey as String: true,
                kAudioAggregateDeviceSubDeviceListKey as String: [
                    [kAudioSubDeviceUIDKey as String: outputUID]
                ],
                kAudioAggregateDeviceTapListKey as String: [
                    [
                        kAudioSubTapDriftCompensationKey as String: true,
                        kAudioSubTapUIDKey as String: tapDescription.uuid.uuidString
                    ]
                ]
            ]

            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                operation: "AudioHardwareCreateAggregateDevice"
            )
            aggregateDeviceID = aggregateID

            var procID: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &procID,
                    aggregateID,
                    queue
                ) { [weak self] _, inputData, _, _, _ in
                    self?.consume(inputData)
                },
                operation: "AudioDeviceCreateIOProcIDWithBlock"
            )
            deviceProcID = procID
            try check(
                AudioDeviceStart(aggregateID, procID),
                operation: "AudioDeviceStart"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let deviceProcID {
                AudioDeviceStop(aggregateDeviceID, deviceProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            }
            deviceProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if processTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(processTapID)
            }
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let now = ProcessInfo.processInfo.systemUptime
        guard analysisFramesPerSecond > 0,
              now - lastSampleTime >= 1.0 / analysisFramesPerSecond else { return }
        lastSampleTime = now
        let mutableList = UnsafeMutablePointer(mutating: inputData)
        let buffers = UnsafeMutableAudioBufferListPointer(mutableList)
        guard let samples = monoSamples(from: buffers), !samples.isEmpty else { return }
        onSamples(samples, streamDescription.mSampleRate)
    }

    private func monoSamples(from buffers: UnsafeMutableAudioBufferListPointer) -> [Float]? {
        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)

        if isFloat, streamDescription.mBitsPerChannel == 32 {
            return monoFloatSamples(from: buffers, channelCount: channelCount)
        }
        if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
            return monoInt16Samples(from: buffers, channelCount: channelCount)
        }
        return nil
    }

    private func monoFloatSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int
    ) -> [Float]? {
        guard let first = buffers.first, first.mData != nil else { return nil }

        if buffers.count > 1 {
            let frameCount = buffers.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
            guard frameCount > 0 else { return nil }
            var mono = Array(repeating: Float.zero, count: frameCount)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    mono[frame] += samples[frame] / Float(buffers.count)
                }
            }
            return mono
        }

        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = sampleCount / channelCount
        let samples = first.mData!.assumingMemoryBound(to: Float.self)
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += samples[frame * channelCount + channel]
            }
            return sum / Float(channelCount)
        }
    }

    private func monoInt16Samples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int
    ) -> [Float]? {
        guard let first = buffers.first, first.mData != nil else { return nil }
        let scale = Float(Int16.max)

        if buffers.count > 1 {
            let frameCount = buffers.map { Int($0.mDataByteSize) / MemoryLayout<Int16>.size }.min() ?? 0
            guard frameCount > 0 else { return nil }
            var mono = Array(repeating: Float.zero, count: frameCount)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frameCount {
                    mono[frame] += Float(samples[frame]) / scale / Float(buffers.count)
                }
            }
            return mono
        }

        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Int16>.size
        let frameCount = sampleCount / channelCount
        let samples = first.mData!.assumingMemoryBound(to: Int16.self)
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += Float(samples[frame * channelCount + channel]) / scale
            }
            return sum / Float(channelCount)
        }
    }

    @available(macOS 14.2, *)
    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value),
            operation: "read kAudioTapPropertyFormat"
        )
        return value
    }

    private func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &value
            ),
            operation: "read default system output device"
        )
        return value
    }

    private func readDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
            },
            operation: "read output device UID"
        )
        return value as String
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NSError(
                domain: "NotchMusic.CoreAudioSystemTap",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(status))"]
            )
        }
    }
}
