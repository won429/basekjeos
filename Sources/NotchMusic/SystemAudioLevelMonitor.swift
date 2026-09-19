import Accelerate
import AudioToolbox
import CoreMedia
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum SystemAudioCaptureState: Equatable {
    case idle
    case starting
    case running
    case permissionRequired
    case failed
}

// All mutable capture and FFT state is confined to sampleQueue.
final class SystemAudioLevelMonitor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.notchmusic.audio-levels", qos: .userInitiated)
    private let onLevels: @Sendable ([Double]) -> Void
    private let onStateChange: @Sendable (SystemAudioCaptureState) -> Void
    private let fftSize = 2_048
    private let bandEdges: [Double] = [45, 90, 180, 360, 720, 1_400, 2_800, 5_600, 11_000, 20_000]
    private let bandGain: [Double] = [1.18, 1.14, 1.10, 1.04, 1.0, 1.0, 1.04, 1.10, 1.16]
    private var stream: SCStream?
    private var coreAudioTap: CoreAudioSystemTap?
    private var startTask: Task<Void, Never>?
    private var smoothedBands = Array(repeating: 0.06, count: 9)
    private var lastPublishTime: TimeInterval = 0
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var fftInput = [Float](repeating: 0, count: 2_048)
    private var fftWindowed = [Float](repeating: 0, count: 2_048)
    private var fftReal = [Float](repeating: 0, count: 1_024)
    private var fftImaginary = [Float](repeating: 0, count: 1_024)
    private var fftMagnitudes = [Float](repeating: 0, count: 1_024)
    private var generation = 0
    private var didLogInputFormat = false
    private var didLogLevels = false
    private var didLogSamples = false
    private var playbackIsActive = false
    private var analysisCadence = WaveformAnalysisCadence.stopped
    private var silentInputStartedAt: TimeInterval?
    private var didReportSilentInput = false

    init(
        onLevels: @escaping @Sendable ([Double]) -> Void,
        onStateChange: @escaping @Sendable (SystemAudioCaptureState) -> Void
    ) {
        self.onLevels = onLevels
        self.onStateChange = onStateChange
        let log2Size = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        window = Array(repeating: 0, count: fftSize)
        super.init()
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func start() {
        sampleQueue.async { [self] in startOnQueue() }
    }

    private func startOnQueue() {
        guard startTask == nil, stream == nil, coreAudioTap == nil else { return }

        lastPublishTime = 0
        didLogInputFormat = false
        didLogLevels = false
        didLogSamples = false
        smoothedBands = Array(repeating: 0.06, count: 9)

        if #available(macOS 14.2, *) {
            onStateChange(.starting)
            let currentGeneration = generation
            let tap = CoreAudioSystemTap { [weak self] samples, sampleRate in
                guard let monitor = self else { return }
                monitor.sampleQueue.async { [weak monitor] in
                    guard let monitor, monitor.coreAudioTap != nil,
                          monitor.generation == currentGeneration else { return }
                    monitor.process(samples: samples, sampleRate: sampleRate, source: "Core Audio tap")
                }
            }
            tap.setAnalysisCadence(analysisCadence)
            do {
                try tap.start()
                coreAudioTap = tap
                onStateChange(.running)
                Self.writeDiagnostic("Core Audio system tap started")
            } catch {
                tap.stop()
                let status = OSStatus((error as NSError).code)
                onStateChange(
                    status == kAudioDevicePermissionsError
                        ? .permissionRequired
                        : .failed
                )
                Self.writeDiagnostic("Core Audio system tap failed: \(error)")
            }
            return
        }

        startScreenCaptureFallback()
    }

    func setPlaybackActive(_ active: Bool) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            playbackIsActive = active
            if !active {
                silentInputStartedAt = nil
                didReportSilentInput = false
            }
        }
    }

    func setAnalysisCadence(_ cadence: WaveformAnalysisCadence) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            analysisCadence = cadence
            coreAudioTap?.setAnalysisCadence(cadence)
            if cadence == .stopped {
                lastPublishTime = 0
            }
        }
    }

    private func startScreenCaptureFallback() {
        guard startTask == nil, stream == nil else { return }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            Self.writeDiagnostic("screen and system audio recording permission is required")
            onStateChange(.permissionRequired)
            return
        }

        generation += 1
        let currentGeneration = generation
        onStateChange(.starting)

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                try Task.checkCancellation()
                guard let display = content.displays.first else {
                    throw NSError(domain: "NotchMusic.AudioCapture", code: 1)
                }

                let filter = SCContentFilter(
                    display: display,
                    including: content.applications,
                    exceptingWindows: []
                )
                let configuration = SCStreamConfiguration()
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                configuration.queueDepth = 1
                configuration.showsCursor = false
                configuration.capturesAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                // The app does not emit audio. Keeping this disabled also avoids
                // systems that attribute browser audio to the responsible process
                // and consequently deliver silent capture buffers.
                configuration.excludesCurrentProcessAudio = false

                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: self
                )
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.sampleQueue.async { [self] in
                    guard self.generation == currentGeneration else {
                        Task { try? await stream.stopCapture() }
                        return
                    }
                    self.stream = stream
                    self.startTask = nil
                    self.onStateChange(.running)
                    Self.writeDiagnostic("system audio capture started")
                }
            } catch {
                self.sampleQueue.async { [self] in
                    guard self.generation == currentGeneration else { return }
                    self.stream = nil
                    self.startTask = nil
                    self.onStateChange(.failed)
                    Self.writeDiagnostic("system audio capture failed: \(error)")
                }
            }
        }
    }

    func stop() {
        // AudioHardware teardown can block in a driver. Never do it on the UI
        // thread (including the application's termination callback).
        sampleQueue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        generation += 1
        coreAudioTap?.stop()
        coreAudioTap = nil
        startTask?.cancel()
        startTask = nil
        smoothedBands = Array(repeating: 0.06, count: 9)
        onStateChange(.idle)

        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard self.stream === stream, type == .audio, sampleBuffer.isValid else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard playbackIsActive,
              let minimumInterval = analysisCadence.minimumInterval,
              now - lastPublishTime >= minimumInterval else { return }
        lastPublishTime = now

        if !didLogInputFormat,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
            didLogInputFormat = true
            Self.writeDiagnostic(
                "audio input format=\(description.mFormatID) flags=\(description.mFormatFlags) bits=\(description.mBitsPerChannel) channels=\(description.mChannelsPerFrame) rate=\(description.mSampleRate)"
            )
        }

        guard let levels = spectralLevels(from: sampleBuffer) else {
            if didLogInputFormat, !didLogLevels {
                Self.writeDiagnostic("audio samples arrived but FFT conversion failed")
            }
            return
        }
        if !didLogLevels {
            didLogLevels = true
            Self.writeDiagnostic("FFT bands active min=\(levels.min() ?? 0) max=\(levels.max() ?? 0)")
        }
        onLevels(levels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onStateChange(.failed)
            Self.writeDiagnostic("system audio stream stopped: \(error)")
        }
    }

    private static func writeDiagnostic(_ message: String) {
        guard let data = "[NotchMusic] \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private func process(samples: [Float], sampleRate: Double, source: String) {
        guard playbackIsActive, analysisCadence != .stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let maximum = samples.reduce(Float.zero) { max($0, abs($1)) }
        updateSignalState(peak: maximum, now: now)
        if !didLogSamples {
            didLogSamples = true
            Self.writeDiagnostic("\(source) samples=\(samples.count) peak=\(maximum)")
        }

        guard let levels = analyzeSpectrum(samples: samples, sampleRate: sampleRate) else { return }
        if !didLogLevels {
            didLogLevels = true
            Self.writeDiagnostic("FFT bands active min=\(levels.min() ?? 0) max=\(levels.max() ?? 0)")
        }
        onLevels(levels)
    }

    private func updateSignalState(peak: Float, now: TimeInterval) {
        guard playbackIsActive else {
            silentInputStartedAt = nil
            didReportSilentInput = false
            return
        }

        if peak > 0.000_005 {
            silentInputStartedAt = nil
            if didReportSilentInput {
                didReportSilentInput = false
                onStateChange(.running)
            }
            return
        }

        if silentInputStartedAt == nil {
            silentInputStartedAt = now
        }
        if !didReportSilentInput,
           now - (silentInputStartedAt ?? now) >= 4 {
            didReportSilentInput = true
            onStateChange(.permissionRequired)
            Self.writeDiagnostic("audio tap is returning silent samples while media is playing")
        }
    }

    private func analyzeSpectrum(samples: [Float], sampleRate: Double) -> [Double]? {
        guard let fftSetup, !samples.isEmpty else { return nil }

        vDSP_vclr(&fftInput, 1, vDSP_Length(fftSize))
        let recentSamples = samples.suffix(fftSize)
        fftInput.replaceSubrange((fftSize - recentSamples.count)..<fftSize, with: recentSamples)

        vDSP_vmul(fftInput, 1, window, 1, &fftWindowed, 1, vDSP_Length(fftSize))

        let log2Size = vDSP_Length(log2(Double(fftSize)))

        fftReal.withUnsafeMutableBufferPointer { realBuffer in
            fftImaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                fftWindowed.withUnsafeBytes { rawBuffer in
                    let complex = rawBuffer.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(
                        complex.baseAddress!,
                        2,
                        &splitComplex,
                        1,
                        vDSP_Length(fftSize / 2)
                    )
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(
                    &splitComplex,
                    1,
                    &fftMagnitudes,
                    1,
                    vDSP_Length(fftSize / 2)
                )
            }
        }

        let binFrequency = max(sampleRate, 1) / Double(fftSize)
        var output = Array(repeating: 0.0, count: bandGain.count)
        for index in output.indices {
            let lowerBin = max(1, Int(bandEdges[index] / binFrequency))
            let upperBin = min(fftMagnitudes.count - 1, Int(bandEdges[index + 1] / binFrequency))
            guard upperBin >= lowerBin else { continue }

            var power = 0.0
            for bin in lowerBin...upperBin {
                power += Double(fftMagnitudes[bin])
            }
            power /= Double(upperBin - lowerBin + 1)

            let amplitude = sqrt(max(power, 0)) * 2 / Double(fftSize)
            let decibels = 20 * log10(max(amplitude, 0.000_001))
            let normalized = min(max((decibels + 72) / 56, 0), 1)
            let emphasized = min(pow(normalized, 0.72) * bandGain[index], 1)
            let smoothing = emphasized > smoothedBands[index] ? 0.90 : 0.48
            smoothedBands[index] += (emphasized - smoothedBands[index]) * smoothing
            output[index] = smoothedBands[index]
        }
        return output
    }

    private func spectralLevels(from sampleBuffer: CMSampleBuffer) -> [Double]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let descriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let description = descriptionPointer.pointee
        guard description.mFormatID == kAudioFormatLinearPCM else { return nil }

        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, requiredSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        return withExtendedLifetime(blockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let mono = monoSamples(from: buffers, description: description), !mono.isEmpty else {
                return nil
            }
            if !didLogSamples {
                didLogSamples = true
                let maximum = mono.reduce(Float.zero) { max($0, abs($1)) }
                let layout = buffers.map { "\($0.mNumberChannels)x\($0.mDataByteSize)" }.joined(separator: ",")
                Self.writeDiagnostic("audio buffers=\(buffers.count) layout=\(layout) monoSamples=\(mono.count) peak=\(maximum)")
            }

            let maximum = mono.reduce(Float.zero) { max($0, abs($1)) }
            updateSignalState(
                peak: maximum,
                now: ProcessInfo.processInfo.systemUptime
            )

            return analyzeSpectrum(samples: mono, sampleRate: description.mSampleRate)
        }
    }

    private func monoSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        description: AudioStreamBasicDescription
    ) -> [Float]? {
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let channelCount = max(Int(description.mChannelsPerFrame), 1)

        if isFloat, description.mBitsPerChannel == 32 {
            return monoFloatSamples(from: buffers, channelCount: channelCount)
        }
        if isSignedInteger, description.mBitsPerChannel == 16 {
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
}
