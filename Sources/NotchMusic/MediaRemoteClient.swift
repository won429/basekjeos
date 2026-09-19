import AppKit
import Combine
import CoreFoundation
import Darwin
import Foundation

enum WaveformMode: String, CaseIterable {
    case basic
    case live

    var title: String {
        switch self {
        case .basic: return "기본 모드"
        case .live: return "실제 파형 모드"
        }
    }
}

enum CompactDisplayState: Equatable {
    case music
    case idle
    case charging
    case disconnected
    case batteryLevel
    case lowBattery
    case airPods
    case volume
    case brightness

    var isAdjustmentHUD: Bool { self == .volume || self == .brightness }

    var isCompactHUD: Bool { isCompactPowerStatus || isAdjustmentHUD }
    var isNotification: Bool { isPowerStatus || self == .airPods || isAdjustmentHUD }

    var isPowerStatus: Bool {
        self == .charging || self == .disconnected || self == .batteryLevel || self == .lowBattery
    }

    var isCompactPowerStatus: Bool {
        self == .charging || self == .disconnected || self == .batteryLevel
    }
}

struct ArtworkPresentation {
    let image: NSImage?
    let revision: Int
    let animatesChange: Bool
}

@MainActor
final class PlaybackFrameState: ObservableObject {
    @Published fileprivate(set) var elapsed: Double = 0
    @Published fileprivate(set) var audioLevels: [Double] = []
}

private enum YouTubeMusicWebAppState {
    case unavailable
    case paused
    case playing(title: String)
}

@MainActor
final class MediaRemoteClient: ObservableObject {
    @Published private(set) var title = "재생 중이 아님"
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artworkPresentation = ArtworkPresentation(
        image: nil,
        revision: 0,
        animatesChange: false
    )
    @Published private(set) var duration: Double = 0
    let frameState = PlaybackFrameState()
    private(set) var elapsed: Double {
        get { frameState.elapsed }
        set {
            frameState.elapsed = newValue
            playbackAnchorPosition = newValue
            playbackAnchorUptime = ProcessInfo.processInfo.systemUptime
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var sourceApp = "대기 중"
    @Published private(set) var isAvailable = false
    @Published private(set) var isYouTubeMusicSource = false
    private(set) var audioLevels: [Double] {
        get { frameState.audioLevels }
        set { frameState.audioLevels = newValue }
    }
    @Published private(set) var waveformColors: [NSColor] = ArtworkPalette.fallback
    @Published private(set) var backgroundGraphicsMode = BackgroundGraphicsMode.load()
    @Published private(set) var waveformMode: WaveformMode
    @Published private(set) var appLanguage: AppLanguage
    @Published private(set) var lyricsProvider: LyricsProvider
    @Published private(set) var batteryAlertInterval = PowerStateMonitor.supportsBatteryAlerts ? BatteryAlertInterval.load() : .off
    let lowPowerMode: LowPowerModeController
    @Published private(set) var batteryLevelIsCharging = false
    @Published private(set) var audioCaptureState: SystemAudioCaptureState = .idle
    @Published private(set) var compactDisplayState: CompactDisplayState = .music
    @Published private(set) var outputVolume: Float = 0
    @Published private(set) var outputMuted = false
    @Published private(set) var canAdjustOutputVolume = false
    @Published private(set) var screenBrightness: Float = 0
    private let brightnessController = ScreenBrightnessController()
    private var volumeDismissTask: Task<Void, Never>?
    private lazy var volumeMonitor = OutputVolumeMonitor(changed: { [weak self] in self?.presentVolume($0) },
        stateChanged: { [weak self] snapshot, available in
            self?.canAdjustOutputVolume = available
            if let snapshot {
                self?.outputVolume = snapshot.level
                self?.outputMuted = snapshot.muted
            }
        })
    @Published private(set) var batteryPercentage = 0
    @Published private(set) var airPodsName = "AirPods"
    @Published private(set) var airPodsLeftBattery: Int?
    @Published private(set) var airPodsRightBattery: Int?
    @Published private(set) var airPodsUnitBattery: Int?
    @Published private(set) var isAirPodsConnected = false

    private typealias SetElapsedTimeFunction = @convention(c) (Double) -> Void

    private enum Command {
        static let togglePlayPause = 2
        static let nextTrack = 4
        static let previousTrack = 5
    }

    private struct BridgePayload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let playbackRate: Double?
        let sourceApp: String?
        let bundleIdentifier: String?
        let contentItemIdentifier: String?
        let externalContentIdentifier: String?
        let artworkDataBase64: String?
        let artworkMIMEType: String?
        let artworkIdentifier: String?
    }

    private struct ITunesSearchResponse: Decodable {
        let results: [ITunesTrack]
    }

    private struct CommandResponse: Decodable {
        let success: Bool?
        let ignored: Bool?
    }

    private struct ITunesTrack: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: URL?
    }

    private struct ArtworkCandidate {
        let image: NSImage
        let rank: Int
        let source: String
    }

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var playbackBundleIdentifier: String?
    private var setElapsedTimeFunction: SetElapsedTimeFunction?
    private var timer: Timer?
    private var tickCount = 0
    private var playbackAnchorPosition: Double = 0
    private var playbackAnchorUptime = ProcessInfo.processInfo.systemUptime
    private var isRefreshing = false
    private var refreshPending = false
    private var forcedRefreshPending = false
    private var commandRefreshTask: Task<Void, Never>?
    private var nextStreamAttempt = Date.distantPast
    private lazy var nowPlayingStream = NowPlayingStream { [weak self] data in
        self?.applyBridgeData(data)
    }
    private var activeProcesses: [Process] = []
    private var artworkTrackKey = ""
    private var artworkTask: Task<Void, Never>?
    private var artworkLookupID: UUID?
    private var artworkAttemptCount = 0
    private var artworkNextAttemptAt = Date.distantPast
    private var artworkSourceRank = 0
    private var artwork: NSImage?
    private var pendingArtworkTransitionKey: String?
    private var lastPresentedArtworkTrackKey = ""
    private let artworkMemoryCache = NSCache<NSString, NSImage>()
    private lazy var artworkCacheDirectory: URL? = {
        guard let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = baseURL
            .appendingPathComponent("com.notchmusic.player", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            return nil
        }
    }()
    private var hasStarted = false
    private var backgroundAudioConsumers = Set<UUID>()
    private var waveformPresentation = WaveformPresentation.hidden
    var needsAudioCapture: Bool {
        (waveformMode == .live && waveformPresentation != .hidden)
            || !backgroundAudioConsumers.isEmpty
    }
    var waveformAnalysisCadence: WaveformAnalysisCadence {
        WaveformAnalysisPolicy.cadence(
            playbackActive: isPlaying,
            liveMeterEnabled: waveformMode == .live,
            presentation: waveformPresentation,
            hasVisibleBackground: !backgroundAudioConsumers.isEmpty
        )
    }
    private var isUsingYouTubeMusicWebAppFallback = false
    private var browserTask: Task<Void, Never>?
    private var browserProcessID: pid_t?
    private var lastBrowserRead = Date.distantPast
    private var lastBrowserPoll = Date.distantPast
    private var lastBridgeBrowserInvalidation = Date.distantPast
    private var pendingSeek: (position: Double, deadline: Date)?
    private var lastObservedPlaybackState: Bool?
    private var isIdlePresentationReady = false
    private var idlePresentationTask: Task<Void, Never>?
    private var chargingDismissTask: Task<Void, Never>?
    private var airPodsDismissTask: Task<Void, Never>?
    private var isShowingAirPodsDetails = false
    private lazy var powerStateMonitor = PowerStateMonitor { [weak self] event in
        self?.presentPowerEvent(event)
    }
    private lazy var airPodsMonitor = AirPodsMonitor { [weak self] snapshot in
        self?.applyAirPodsSnapshot(snapshot)
    }
    private lazy var audioMonitor = SystemAudioLevelMonitor(
        onLevels: { [weak self] levels in
            Task { @MainActor in
                guard let self, self.hasStarted, self.isPlaying,
                      self.waveformAnalysisCadence != .stopped,
                      self.audioLevels != levels else { return }
                self.audioLevels = levels
            }
        },
        onStateChange: { [weak self] state in
            Task { @MainActor in
                guard let self, self.hasStarted, self.audioCaptureState != state else { return }
                self.audioCaptureState = state
            }
        }
    )

    init(lowPowerMode: LowPowerModeController? = nil) {
        self.lowPowerMode = lowPowerMode ?? LowPowerModeController()
        waveformMode = WaveformMode(
            rawValue: UserDefaults.standard.string(forKey: "waveformMode") ?? ""
        ) ?? .basic
        appLanguage = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        ) ?? .systemDefault
        lyricsProvider = LyricsProvider.load()
        artworkMemoryCache.countLimit = 80
        loadControlFunction()
        isAvailable = bridgeScriptURL != nil
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startNowPlayingStreamIfNeeded()
        refresh()
        powerStateMonitor.start()
        airPodsMonitor.start()
        volumeMonitor.start()
        updateAudioCapture()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        hasStarted = false
        browserTask?.cancel()
        browserTask = nil
        Task { await YouTubeBrowserPlayback.shared.retainProcesses([]) }
        nowPlayingStream.stop()
        timer?.invalidate()
        timer = nil
        commandRefreshTask?.cancel()
        commandRefreshTask = nil
        refreshPending = false
        forcedRefreshPending = false
        activeProcesses.forEach { process in
            if process.isRunning {
                BridgeProcessRunner.cancel(process, force: true)
            }
        }
        activeProcesses.removeAll()
        artworkTask?.cancel()
        artworkTask = nil
        artworkLookupID = nil
        idlePresentationTask?.cancel()
        idlePresentationTask = nil
        chargingDismissTask?.cancel()
        chargingDismissTask = nil
        airPodsDismissTask?.cancel()
        airPodsDismissTask = nil
        powerStateMonitor.stop()
        airPodsMonitor.stop()
        volumeMonitor.stop()
        volumeDismissTask?.cancel()
        audioMonitor.setPlaybackActive(false)
        audioMonitor.stop()
        audioLevels = []
    }

    func setWaveformMode(_ mode: WaveformMode, persist: Bool = true) {
        if waveformMode == mode {
            if mode == .live, hasStarted {
                audioMonitor.stop()
                updateAudioCapture()
            }
            return
        }
        waveformMode = mode
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: "waveformMode")
        }
        audioLevels = []

        guard hasStarted else { return }
        updateAudioCapture()
    }

    func setBackgroundAudioActive(_ active: Bool, consumer: UUID) {
        if active { backgroundAudioConsumers.insert(consumer) }
        else { backgroundAudioConsumers.remove(consumer) }
        updateAudioCapture()
    }

    func setWaveformPresentation(_ presentation: WaveformPresentation) {
        guard waveformPresentation != presentation else { return }
        waveformPresentation = presentation
        updateAudioCapture()
    }

    private func updateAudioCapture() {
        guard hasStarted else { return }
        let cadence = waveformAnalysisCadence
        audioMonitor.setPlaybackActive(isPlaying)
        audioMonitor.setAnalysisCadence(cadence)
        if cadence != .stopped {
            audioMonitor.start()
        } else {
            audioMonitor.stop()
            audioLevels = []
        }
    }

    func readYouTubeLyrics() async -> String? {
        guard let pid = browserProcessID else { return nil }
        return await YouTubeBrowserPlayback.shared.readLyrics(processID: pid)
    }

    func loadPlaybackQueue() async throws -> [PlaybackQueueItem] {
        guard isYouTubeMusicSource else { throw PlaybackQueueError.unavailable }
        let active = playbackBundleIdentifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        let webApps = NSWorkspace.shared.runningApplications.filter {
            isYouTubeMusicSafariWebApp(bundleIdentifier: $0.bundleIdentifier?.lowercased() ?? "")
        }
        // MediaRemote can identify Safari instead of its standalone music web app.
        var seen = Set<pid_t>()
        let candidates = ([active].compactMap { $0 } + webApps + youtubeBrowserApplications()).filter { seen.insert($0.processIdentifier).inserted }
        for application in candidates {
            try Task.checkCancellation()
            do {
                return try await PlaybackQueueClient.shared
                    .load(processID: application.processIdentifier, currentTitle: title)
                    .map {
                        var item = $0
                        item.sourceProcessID = application.processIdentifier
                        return item
                    }
            } catch PlaybackQueueError.permissionRequired {
                throw PlaybackQueueError.permissionRequired
            } catch is CancellationError {
                throw CancellationError()
            } catch { continue }
        }
        throw PlaybackQueueError.unavailable
    }

    func playPlaybackQueueItem(_ item: PlaybackQueueItem) async throws {
        guard isYouTubeMusicSource,
              let processID = item.sourceProcessID ?? browserProcessID else {
            throw PlaybackQueueError.unavailable
        }
        try await PlaybackQueueClient.shared.play(
            processID: processID,
            item: item,
            currentTitle: title
        )
        browserProcessID = processID
        elapsed = 0
        lastBrowserPoll = .distantPast
        await YouTubeBrowserPlayback.shared.invalidate(
            processID: processID,
            structure: false,
            layout: true
        )
        pollYouTubeBrowser()
    }

    func setBackgroundGraphicsMode(_ mode: BackgroundGraphicsMode, persist: Bool = true) {
        backgroundGraphicsMode = mode
        if persist { UserDefaults.standard.set(mode.rawValue, forKey: BackgroundGraphicsMode.defaultsKey) }
    }

    func setLyricsProvider(_ provider: LyricsProvider, persist: Bool = true) {
        lyricsProvider = provider
        if persist { UserDefaults.standard.set(provider.rawValue, forKey: LyricsProvider.defaultsKey) }
    }

    func setAppLanguage(_ language: AppLanguage, persist: Bool = true) {
        appLanguage = language
        if persist {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        }
    }

    func setBatteryAlertInterval(_ interval: BatteryAlertInterval) {
        guard PowerStateMonitor.supportsBatteryAlerts else { return }
        batteryAlertInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: BatteryAlertInterval.defaultsKey)
        powerStateMonitor.setAlertInterval(interval)
        if interval == .off, compactDisplayState == .batteryLevel || compactDisplayState == .lowBattery {
            chargingDismissTask?.cancel()
            restoreDefaultCompactDisplay()
        }
    }

    func setAirPodsDetailsVisible(_ visible: Bool) {
        isShowingAirPodsDetails = visible
        if visible, compactDisplayState == .airPods {
            airPodsDismissTask?.cancel()
            airPodsDismissTask = nil
        } else if !visible, compactDisplayState == .airPods {
            scheduleAirPodsDismiss(after: 3)
        }
    }

    func toggleLowPowerMode() {
        guard compactDisplayState == .lowBattery, !lowPowerMode.isChanging else { return }
        chargingDismissTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.lowPowerMode.toggle()
            if self.compactDisplayState == .lowBattery {
                self.schedulePowerDismiss(after: 5)
            }
        }
    }

    private func schedulePowerDismiss(after delay: TimeInterval? = nil) {
        chargingDismissTask?.cancel()
        let duration = delay ?? (compactDisplayState == .lowBattery ? 7 : 4)
        chargingDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.compactDisplayState.isPowerStatus else { return }
            if self.compactDisplayState == .lowBattery, self.lowPowerMode.isChanging {
                self.schedulePowerDismiss(after: 5)
                return
            }
            self.restoreDefaultCompactDisplay()
        }
    }

    func refresh(afterCurrentRequest: Bool = false, evenIfStreaming: Bool = false) {
        guard evenIfStreaming || !nowPlayingStream.isRunning else { return }
        guard !isRefreshing else {
            refreshPending = refreshPending || afterCurrentRequest || evenIfStreaming
            forcedRefreshPending = forcedRefreshPending || evenIfStreaming
            return
        }
        isRefreshing = true

        runBridge(arguments: ["get"]) { [weak self] data, error in
            guard let self else { return }
            self.isRefreshing = false
            guard self.hasStarted else { return }
            defer {
                if self.refreshPending {
                    let force = self.forcedRefreshPending
                    self.refreshPending = false
                    self.forcedRefreshPending = false
                    self.refresh(evenIfStreaming: force)
                }
            }

            if let error {
                self.debugLog("bridge error: \(error)")
                return
            }
            guard let data, evenIfStreaming || !self.nowPlayingStream.isRunning else { return }
            self.applyBridgeData(data)
        }
    }

    func togglePlayback() {
        guard isYouTubeMusicSource else { return }
        send(command: Command.togglePlayPause)
    }

    func nextTrack() {
        guard isYouTubeMusicSource else { return }
        send(command: Command.nextTrack)
    }

    func previousTrack() {
        guard isYouTubeMusicSource else { return }
        send(command: Command.previousTrack)
    }

    func seek(to position: Double) {
        guard isYouTubeMusicSource else { return }
        let clamped = min(max(position, 0), duration)
        elapsed = clamped
        pendingSeek = (clamped, Date().addingTimeInterval(1.5))
        if let pid = browserProcessID {
            Task { @MainActor [weak self] in
                _ = await YouTubeBrowserPlayback.shared.send(.seek(clamped), processID: pid)
                guard let self else { return }
                // AX sliders are inconsistent across Safari and Chromium: some
                // accept AXValue without dispatching the page's input event.
                // Also issue the MediaRemote seek, but only after re-verifying
                // that the global Now Playing owner is YouTube Music.
                self.runBridge(arguments: ["get"]) { [weak self] data, _ in
                    guard let self, let data,
                          let payload = try? JSONDecoder().decode(BridgePayload.self, from: data),
                          self.isYouTubeMusicPayload(payload) else { return }
                    self.setElapsedTimeFunction?(clamped)
                }
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                self.lastBrowserPoll = .distantPast
                self.pollYouTubeBrowser()
            }
            return
        }
        guard isYouTubeMusicSource, !isUsingYouTubeMusicWebAppFallback else { return }
        runBridge(arguments: ["get"]) { [weak self] data, _ in
            guard let self,
                  let data,
                  let payload = try? JSONDecoder().decode(BridgePayload.self, from: data),
                  self.isYouTubeMusicPayload(payload) else { return }
            self.setElapsedTimeFunction?(clamped)
            self.elapsed = clamped
            self.pendingSeek = nil
            self.scheduleRefresh()
        }
    }

    func openYouTubeMusic() {
        guard let url = URL(string: "https://music.youtube.com") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealYouTubeMusic() {
        let applications = NSWorkspace.shared.runningApplications
        let source = applications.first { isYouTubeMusicSource && playbackBundleIdentifier != nil
            && $0.bundleIdentifier == playbackBundleIdentifier }
            ?? applications.first { isYouTubeMusicSafariWebApp(bundleIdentifier: $0.bundleIdentifier?.lowercased() ?? "") }
        if let source, source.activate(options: []) { return }
        openYouTubeMusic()
    }

    func openAudioOutputSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func loadSnapshotPreview() {
        title = "LEMONADE"
        artist = "aespa 및 Becky G"
        album = "Rich Man - The 6th Mini Album"
        duration = 187
        elapsed = 42
        updatePlaybackState(true)
        sourceApp = "YouTube Music"
        isAvailable = true
        isYouTubeMusicSource = ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_NON_YOUTUBE"] != "1"
        audioLevels = [0.18, 0.42, 0.66, 0.34, 0.82, 0.48, 0.72, 0.28, 0.54]
        if ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_ARTWORK_CYCLE"] == "1" {
            loadSnapshotArtworkCycle()
        } else {
            requestArtworkIfNeeded(
                title: title,
                artist: artist,
                embeddedArtworkBase64: nil,
                artworkIdentifier: nil
            )
        }

        switch ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE"] {
        case "paused":
            updatePlaybackState(false)
        case "idle":
            updatePlaybackState(false)
            idlePresentationTask?.cancel()
            isIdlePresentationReady = true
            compactDisplayState = .idle
        case "battery", "battery-charging":
            batteryPercentage = Int(
                ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_BATTERY"] ?? "80"
            ) ?? 80
            batteryLevelIsCharging = ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_COMPACT_STATE"] == "battery-charging"
            compactDisplayState = LowBatteryPolicy.isLow(percentage: batteryPercentage, connected: batteryLevelIsCharging)
                ? .lowBattery : .batteryLevel
        case "charging":
            batteryPercentage = Int(
                ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_BATTERY"] ?? "82"
            ) ?? 82
            compactDisplayState = .charging
        case "disconnected":
            batteryPercentage = Int(
                ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_BATTERY"] ?? "82"
            ) ?? 82
            compactDisplayState = LowBatteryPolicy.isLow(percentage: batteryPercentage, connected: false)
                ? .lowBattery : .disconnected
        case "airpods":
            airPodsName = "성원의 AirPods Pro"
            airPodsLeftBattery = 76
            airPodsRightBattery = 74
            airPodsUnitBattery = 75
            isAirPodsConnected = true
            compactDisplayState = .airPods
        default:
            break
        }
        if compactDisplayState == .lowBattery { schedulePowerDismiss() }
    }

    private func loadSnapshotArtworkCycle() {
        let firstKey = "snapshot-first"
        artworkTrackKey = firstKey
        pendingArtworkTransitionKey = firstKey
        presentArtwork(snapshotArtwork(color: .systemPink), for: firstKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let secondKey = "snapshot-second"
            self.artworkTrackKey = secondKey
            self.pendingArtworkTransitionKey = secondKey
            self.presentArtwork(self.snapshotArtwork(color: .systemBlue), for: secondKey)
        }
    }

    private func snapshotArtwork(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 160, height: 160))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 160).fill()
        image.unlockFocus()
        return image
    }

    private var bridgeScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "NowPlayingBridge", withExtension: "js") {
            return bundled
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/NowPlayingBridge.js")
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    private func runBridge(
        arguments: [String],
        completion: @escaping @MainActor (Data?, String?) -> Void
    ) {
        guard let scriptURL = bridgeScriptURL else {
            completion(nil, "NowPlayingBridge.js를 찾을 수 없습니다")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", scriptURL.path] + arguments
        do {
            try BridgeProcessRunner.run(process) { [weak self, weak process] output, errors, status in
                if let process {
                    self?.activeProcesses.removeAll(where: { $0 === process })
                }
                let errorText = String(data: errors, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(status == 0 ? output : nil,
                           status == 0 ? nil : (errorText?.isEmpty == false ? errorText : "osascript 종료 코드 \(status)"))
            }
            activeProcesses.append(process)
        } catch {
            completion(nil, error.localizedDescription)
        }
    }

    private func youtubeBrowserApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            let id = $0.bundleIdentifier?.lowercased() ?? ""
            return ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser"].contains(id)
                || isYouTubeMusicSafariWebApp(bundleIdentifier: id)
        }
    }

    private func pollYouTubeBrowser() {
        guard hasStarted, browserTask == nil, Date().timeIntervalSince(lastBrowserPoll) >= 1 else { return }
        lastBrowserPoll = Date()
        let apps = youtubeBrowserApplications().sorted {
            ($0.processIdentifier == browserProcessID ? 0 : 1) < ($1.processIdentifier == browserProcessID ? 0 : 1)
        }
        let candidates = apps.map { ($0.processIdentifier, $0.bundleIdentifier) }
        if let pid = browserProcessID, !candidates.contains(where: { $0.0 == pid }) {
            browserProcessID = nil
            resetMetadata(showIdleImmediately: true)
        }
        let commandGeneration = browserCommandGeneration
        browserTask = Task { @MainActor [weak self] in
            await YouTubeBrowserPlayback.shared.retainProcesses(Set(candidates.map { $0.0 }))
            var selected: (YouTubeBrowserSnapshot, String?)?
            for (pid, bundle) in candidates {
                guard !Task.isCancelled else { break }
                if let snapshot = await YouTubeBrowserPlayback.shared.read(processID: pid) {
                    if selected == nil || snapshot.playing { selected = (snapshot, bundle) }
                    if pid == self?.browserProcessID || snapshot.playing {
                        selected = (snapshot, bundle)
                        break
                    }
                }
            }
            guard let self else { return }
            defer { self.browserTask = nil }
            guard !Task.isCancelled, self.hasStarted, commandGeneration == self.browserCommandGeneration else { return }
            guard let (snapshot, bundle) = selected else {
                // A transient AX tree rebuild is not a stopped player. Keep the
                // last presentation and let MediaRemote take over after the lease.
                if Date().timeIntervalSince(self.lastBrowserRead) >= 5 {
                    self.browserProcessID = nil
                }
                return
            }
            self.applyBrowserSnapshot(snapshot, bundle: bundle)
        }
    }

    func applyBrowserSnapshot(_ snapshot: YouTubeBrowserSnapshot, bundle: String?) {
        guard !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.duration.isFinite, snapshot.elapsed.isFinite else { return }
        browserProcessID = snapshot.processID
        lastBrowserRead = Date()
        if playbackBundleIdentifier != bundle { playbackBundleIdentifier = bundle }
        if isUsingYouTubeMusicWebAppFallback { isUsingYouTubeMusicWebAppFallback = false }
        if !isYouTubeMusicSource { isYouTubeMusicSource = true }
        if sourceApp != "YouTube Music" { sourceApp = "YouTube Music" }
        let titleChanged = title != snapshot.title
        if titleChanged {
            pendingSeek = nil
            title = snapshot.title
            album = ""
            duration = max(0, snapshot.duration)
            // Never carry the previous song's artist into a new title while
            // the browser is still constructing its accessibility tree.
            artist = snapshot.artist
        } else if !snapshot.artist.isEmpty, artist != snapshot.artist {
            artist = snapshot.artist
        }
        if snapshot.duration > 0, duration != snapshot.duration {
            duration = snapshot.duration
        }
        if let pending = pendingSeek {
            if abs(snapshot.elapsed - pending.position) <= 2 || Date() >= pending.deadline {
                pendingSeek = nil
                elapsed = max(0, snapshot.elapsed)
            } else {
                elapsed = pending.position
            }
        } else if titleChanged || snapshot.playing != isPlaying || !isPlaying
                    || abs(snapshot.elapsed - elapsed) > 1.1 {
            // Browser labels are quantized to seconds. Do not repeatedly rewind
            // the smooth clock to the same displayed second on each AX refresh.
            elapsed = max(0, snapshot.elapsed)
        }
        updatePlaybackState(snapshot.playing)
        requestArtworkIfNeeded(title: snapshot.title, artist: snapshot.artist, embeddedArtworkBase64: nil, artworkIdentifier: nil)
    }

    func applyBridgeData(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(BridgePayload.self, from: data),
              let newTitle = payload.title,
              !newTitle.isEmpty else {
            if !isYouTubeMusicSource { resetMetadata() }
            pollYouTubeBrowser()
            return
        }

        let source = sourceIdentity(
            payload.sourceApp,
            bundleIdentifier: payload.bundleIdentifier,
            contentItemIdentifier: payload.contentItemIdentifier,
            externalContentIdentifier: payload.externalContentIdentifier
        )
        guard source.isYouTubeMusic else {
            debugLog("ignored non-YouTube Music source: \(source.name)")
            // Another app becoming Now Playing must never erase YouTube Music.
            pollYouTubeBrowser()
            return
        }

        let newArtist = payload.artist?.isEmpty == false ? payload.artist! : "아티스트 정보 없음"
        let newAlbum = payload.album ?? ""
        let newDuration = max(payload.duration ?? 0, 0)
        let newPlaying = (payload.playbackRate ?? 0) > 0
        // One owner for title, artist, playback and clock. Mixing fields from
        // two independently delayed sources makes the same songs alternate.
        if browserProcessID != nil, Date().timeIntervalSince(lastBrowserRead) < 5 {
            if normalizedMetadata(newTitle) == normalizedMetadata(title) {
                if pendingSeek == nil, newPlaying == isPlaying, newDuration > 0,
                   abs(newDuration - duration) < 2,
                   abs((payload.elapsedTime ?? elapsed) - elapsed) < 2 {
                    elapsed = min(duration, max(0, payload.elapsedTime ?? elapsed))
                }
                // Embedded artwork may enrich the browser's current track, but
                // must not rewrite its artist, duration, position or play state.
                requestArtworkIfNeeded(title: title, artist: artist,
                    embeddedArtworkBase64: payload.artworkDataBase64,
                    artworkIdentifier: payload.artworkIdentifier)
            }
            if (normalizedMetadata(newTitle) != normalizedMetadata(title) || newPlaying != isPlaying),
               Date().timeIntervalSince(lastBridgeBrowserInvalidation) >= 1,
                      let processID = browserProcessID {
                lastBridgeBrowserInvalidation = Date()
                Task {
                    await YouTubeBrowserPlayback.shared.invalidate(
                        processID: processID, structure: false, layout: true)
                }
            }
            return
        }
        browserProcessID = nil
        isUsingYouTubeMusicWebAppFallback = false
        playbackBundleIdentifier = payload.bundleIdentifier
        let newElapsed = min(max(payload.elapsedTime ?? 0, 0), newDuration)
        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        if album != newAlbum { album = newAlbum }
        if duration != newDuration { duration = newDuration }
        if elapsed != newElapsed { elapsed = newElapsed }
        updatePlaybackState(newPlaying)
        if sourceApp != source.name { sourceApp = source.name }
        if !isYouTubeMusicSource { isYouTubeMusicSource = true }
        requestArtworkIfNeeded(
            title: title,
            artist: artist,
            embeddedArtworkBase64: payload.artworkDataBase64,
            artworkIdentifier: payload.artworkIdentifier
        )
    }

    private func sourceIdentity(
        _ name: String?,
        bundleIdentifier: String?,
        contentItemIdentifier: String?,
        externalContentIdentifier: String?
    ) -> (name: String, isYouTubeMusic: Bool) {
        let displayName = name?.isEmpty == false ? name! : "브라우저"
        let normalizedName = displayName.lowercased()
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let contentIdentity = [contentItemIdentifier, externalContentIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let isYouTubeMusic = normalizedName.contains("youtube music")
            || normalizedName.contains("yt music")
            || bundle.contains("cinhimbnkkaeohfgghhklpknlkffjgod")
            || isYouTubeMusicSafariWebApp(bundleIdentifier: bundle)
            || contentIdentity.contains("music.youtube.com")
            || contentIdentity.contains("youtube music")
        return (isYouTubeMusic ? "YouTube Music" : displayName, isYouTubeMusic)
    }

    private func isYouTubeMusicPayload(_ payload: BridgePayload) -> Bool {
        sourceIdentity(
            payload.sourceApp,
            bundleIdentifier: payload.bundleIdentifier,
            contentItemIdentifier: payload.contentItemIdentifier,
            externalContentIdentifier: payload.externalContentIdentifier
        ).isYouTubeMusic
    }

    @discardableResult
    private func applyYouTubeMusicWebAppFallback() -> Bool {
        switch youtubeMusicWebAppState() {
        case .unavailable:
            return false
        case .paused:
            guard isUsingYouTubeMusicWebAppFallback else { return false }
            updatePlaybackState(false)
            return true
        case .playing(let detectedTitle):
            let changedTrack = title != detectedTitle || !isUsingYouTubeMusicWebAppFallback
            isUsingYouTubeMusicWebAppFallback = true
            playbackBundleIdentifier = nil
            title = detectedTitle
            if changedTrack {
                artist = "YouTube Music"
                album = ""
                duration = 0
                elapsed = 0
            }
            sourceApp = "YouTube Music"
            if !isYouTubeMusicSource { isYouTubeMusicSource = true }
            updatePlaybackState(true)
            requestArtworkIfNeeded(
                title: detectedTitle,
                artist: artist,
                embeddedArtworkBase64: nil,
                artworkIdentifier: nil
            )
            debugLog("using Safari YouTube Music web app fallback: \(detectedTitle)")
            return true
        }
    }

    private func youtubeMusicWebAppState() -> YouTubeMusicWebAppState {
        let webApps = NSWorkspace.shared.runningApplications.filter { application in
            isYouTubeMusicSafariWebApp(bundleIdentifier: application.bundleIdentifier?.lowercased() ?? "")
        }
        guard !webApps.isEmpty else { return .unavailable }

        let processIDs = Set(webApps.map(\.processIdentifier))
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let suffix = " | YouTube Music"
        for window in windowInfo {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  processIDs.contains(pid_t(ownerPID)),
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let windowName = window[kCGWindowName as String] as? String,
                  windowName.hasSuffix(suffix) else { continue }
            let trackTitle = String(windowName.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trackTitle.isEmpty {
                return .playing(title: trackTitle)
            }
        }
        return .paused
    }

    private func isYouTubeMusicSafariWebApp(bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.hasPrefix("com.apple.safari.webapp.") else { return false }
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.lowercased() == bundleIdentifier }
            .contains { application in
                guard let bundleURL = application.bundleURL,
                      let info = Bundle(url: bundleURL)?.infoDictionary else { return false }
                let manifestURL = info["WKManifestURL"] as? String ?? ""
                let manifest = info["Manifest"] as? [String: Any]
                let startURL = manifest?["start_url"] as? String ?? ""
                return manifestURL.lowercased().contains("music.youtube.com")
                    || startURL.lowercased().contains("music.youtube.com")
            }
    }

    private func requestArtworkIfNeeded(
        title: String,
        artist: String,
        embeddedArtworkBase64: String?,
        artworkIdentifier: String?
    ) {
        // The web-app fallback only knows the title.  Keying with the artist made
        // the same song look new whenever MediaRemote and the fallback alternated.
        let trackKey = normalizedMetadata(title)
        let isNewTrack = artworkTrackKey != trackKey

        if isNewTrack {
            artworkTask?.cancel()
            artworkTask = nil
            artworkLookupID = nil
            artworkTrackKey = trackKey
            artworkAttemptCount = 0
            artworkNextAttemptAt = .distantPast
            artworkSourceRank = 0
            pendingArtworkTransitionKey = trackKey
            // Keep the previous cover visible until the next cover is ready.  The
            // view uses that overlap to reproduce the iPhone's edge-on cover flip
            // instead of flashing the placeholder between songs.
            setArtwork(nil, announcesChange: false)

            if let cachedArtwork = cachedArtwork(for: trackKey) {
                // Cached covers are shown before any network request. Embedded
                // MediaRemote data can still replace them below when available.
                artworkSourceRank = 1
                presentArtwork(cachedArtwork, for: trackKey)
                debugLog("artwork loaded from cache")
            }
        }

        if artworkSourceRank >= 4 { return }

        if let encoded = embeddedArtworkBase64,
           let imageData = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
           let image = NSImage(data: imageData) {
            if artworkSourceRank < 4 {
                artworkTask?.cancel()
                artworkTask = nil
                artworkLookupID = nil
                artworkSourceRank = 4
                presentArtwork(image, for: trackKey)
                cacheArtwork(image, for: trackKey)
                debugLog("embedded artwork loaded: \(imageData.count) bytes")
            }
            return
        }

        let identifierURL = artworkURL(from: artworkIdentifier)
        if artworkSourceRank >= 3 || (artworkSourceRank >= 1 && identifierURL == nil) {
            return
        }
        guard artworkTask == nil, Date() >= artworkNextAttemptAt else { return }

        artworkAttemptCount += 1
        let lookupID = UUID()
        artworkLookupID = lookupID
        artworkTask = Task { [weak self] in
            guard let self else { return }

            var foundArtwork = false
            await withTaskGroup(of: ArtworkCandidate?.self) { group in
                if let identifierURL {
                    group.addTask { [weak self] in
                        guard let self,
                              let image = await self.loadRemoteImage(from: identifierURL) else {
                            return nil
                        }
                        return ArtworkCandidate(
                            image: image,
                            rank: 3,
                            source: "MediaRemote artwork URL"
                        )
                    }
                }

                group.addTask { [weak self] in
                    guard let self,
                          let image = await self.loadArtworkFromITunes(
                            title: title,
                            artist: artist
                          ) else { return nil }
                    return ArtworkCandidate(image: image, rank: 2, source: "iTunes search")
                }

                group.addTask { [weak self] in
                    guard let self,
                          let image = await self.loadArtworkFromYouTube(
                            title: title,
                            artist: artist
                          ) else { return nil }
                    return ArtworkCandidate(image: image, rank: 1, source: "YouTube search")
                }

                for await candidate in group {
                    guard !Task.isCancelled,
                          self.artworkTrackKey == trackKey,
                          self.artworkLookupID == lookupID else {
                        group.cancelAll()
                        return
                    }
                    guard let candidate else { continue }
                    foundArtwork = true
                    guard candidate.rank > self.artworkSourceRank else { continue }

                    self.artworkSourceRank = candidate.rank
                    self.artworkAttemptCount = 0
                    self.presentArtwork(candidate.image, for: trackKey)
                    self.cacheArtwork(candidate.image, for: trackKey)
                    self.debugLog("artwork loaded from \(candidate.source)")

                    if candidate.rank >= 3 {
                        group.cancelAll()
                        break
                    }
                }
            }

            guard !Task.isCancelled,
                  self.artworkTrackKey == trackKey,
                  self.artworkLookupID == lookupID else { return }

            self.artworkTask = nil
            self.artworkLookupID = nil
            if !foundArtwork {
                let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
                let delay = delays[min(self.artworkAttemptCount - 1, delays.count - 1)]
                self.artworkNextAttemptAt = Date().addingTimeInterval(delay)
                self.debugLog("artwork unavailable; retrying in \(Int(delay))s")
            }
        }
    }

    private func loadArtworkFromITunes(title: String, artist: String) async -> NSImage? {
        for country in ["KR", "US"] {
            var components = URLComponents(string: "https://itunes.apple.com/search")
            components?.queryItems = [
                URLQueryItem(name: "term", value: "\(title) \(artist)"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "country", value: country)
            ]
            guard let searchURL = components?.url else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: searchURL)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let result = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data) else {
                    continue
                }

                let track = result.results.max {
                    artworkMatchScore($0, title: title, artist: artist)
                        < artworkMatchScore($1, title: title, artist: artist)
                }
                guard let smallArtworkURL = track?.artworkUrl100 else { continue }
                let artworkURL = URL(
                    string: smallArtworkURL.absoluteString.replacingOccurrences(
                        of: "100x100bb",
                        with: "600x600bb"
                    )
                ) ?? smallArtworkURL
                if let image = await loadRemoteImage(from: artworkURL) {
                    return image
                }
            } catch is CancellationError {
                return nil
            } catch {
                debugLog("iTunes artwork lookup error: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func loadArtworkFromYouTube(title: String, artist: String) async -> NSImage? {
        let query = "\(title) \(artist) official audio"
        let bases = [
            ("https://music.youtube.com/search", "q"),
            ("https://www.youtube.com/results", "search_query")
        ]

        for (base, queryName) in bases {
            var components = URLComponents(string: base)
            components?.queryItems = [URLQueryItem(name: queryName, value: query)]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("ko-KR,ko;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let html = String(data: data, encoding: .utf8),
                      let videoID = firstYouTubeVideoID(in: html) else { continue }

                for quality in ["maxresdefault", "hqdefault", "mqdefault"] {
                    guard let imageURL = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(quality).jpg") else { continue }
                    if let image = await loadRemoteImage(from: imageURL) {
                        return image
                    }
                }
            } catch is CancellationError {
                return nil
            } catch {
                debugLog("YouTube artwork lookup error: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func loadRemoteImage(from url: URL) async -> NSImage? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func artworkURL(from identifier: String?) -> URL? {
        guard var value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\\u0026", with: "&")
        return URL(string: value)
    }

    private func firstYouTubeVideoID(in html: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "\\\"videoId\\\":\\\"([A-Za-z0-9_-]{11})\\\""
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let idRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[idRange])
    }

    private func artworkMatchScore(_ track: ITunesTrack, title: String, artist: String) -> Int {
        let wantedTitle = normalizedMetadata(title)
        let wantedArtist = normalizedMetadata(artist)
        let candidateTitle = normalizedMetadata(track.trackName ?? "")
        let candidateArtist = normalizedMetadata(track.artistName ?? "")
        let candidateAlbum = normalizedMetadata(track.collectionName ?? "")
        var score = 0
        if candidateTitle == wantedTitle { score += 8 }
        else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) { score += 4 }
        if candidateArtist == wantedArtist { score += 6 }
        else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) { score += 3 }
        if !album.isEmpty, candidateAlbum == normalizedMetadata(album) { score += 2 }
        return score
    }

    private func normalizedMetadata(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func loadControlFunction() {
        let paths = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote"
        ]

        for path in paths {
            if let handle = dlopen(path, RTLD_NOW) {
                frameworkHandle = handle
                break
            }
        }

        guard let frameworkHandle,
              let symbol = dlsym(frameworkHandle, "MRMediaRemoteSetElapsedTime") else { return }
        setElapsedTimeFunction = unsafeBitCast(symbol, to: SetElapsedTimeFunction.self)
    }

    private func presentArtwork(_ image: NSImage, for trackKey: String) {
        let isPendingTrack = pendingArtworkTransitionKey == trackKey
        let shouldAnimate = isPendingTrack && lastPresentedArtworkTrackKey != trackKey
        if isPendingTrack {
            pendingArtworkTransitionKey = nil
        }
        lastPresentedArtworkTrackKey = trackKey
        setArtwork(image, animatesChange: shouldAnimate)
    }

    private func cachedArtwork(for trackKey: String) -> NSImage? {
        let cacheKey = trackKey as NSString
        if let image = artworkMemoryCache.object(forKey: cacheKey) {
            return image
        }
        guard let fileURL = artworkCacheFileURL(for: trackKey),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let image = NSImage(data: data) else { return nil }
        artworkMemoryCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func cacheArtwork(_ image: NSImage, for trackKey: String) {
        artworkMemoryCache.setObject(image, forKey: trackKey as NSString)
        guard let fileURL = artworkCacheFileURL(for: trackKey),
              let tiffData = image.tiffRepresentation else { return }

        Task.detached(priority: .utility) {
            guard let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return
            }
            try? pngData.write(to: fileURL, options: .atomic)
        }
    }

    private func artworkCacheFileURL(for trackKey: String) -> URL? {
        artworkCacheDirectory?.appendingPathComponent(
            String(format: "%016llx.png", stableArtworkHash(trackKey)),
            isDirectory: false
        )
    }

    private func stableArtworkHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func setArtwork(
        _ image: NSImage?,
        announcesChange: Bool = true,
        animatesChange: Bool = false
    ) {
        let hadArtwork = artworkPresentation.image != nil
        artwork = image
        if announcesChange, image != nil || hadArtwork {
            artworkPresentation = ArtworkPresentation(
                image: image,
                revision: artworkPresentation.revision &+ 1,
                animatesChange: animatesChange && image != nil
            )
        }
    }

    func updateDisplayedArtworkColors(_ image: NSImage?) {
        // Called when the cover face actually changes, including the midpoint of
        // a flip. Pending lookups keep the palette of the still-visible cover.
        waveformColors = image.map(ArtworkPalette.colors) ?? ArtworkPalette.fallback
    }

    private func startNowPlayingStreamIfNeeded() {
        guard hasStarted, !nowPlayingStream.isRunning, Date() >= nextStreamAttempt,
              let scriptURL = bridgeScriptURL else { return }
        nextStreamAttempt = Date().addingTimeInterval(5)
        nowPlayingStream.start(scriptURL: scriptURL)
    }

    private func tick() {
        if nowPlayingStream.isRunning, !nowPlayingStream.isResponsive {
            debugLog("now playing stream stopped responding; restarting")
            nowPlayingStream.stop()
            // Allow one direct read before the watcher is started again. This
            // prevents a silent but still-running process from freezing the UI.
            nextStreamAttempt = Date().addingTimeInterval(1)
        }
        pollYouTubeBrowser()
        startNowPlayingStreamIfNeeded()
        tickCount += 1
        if isPlaying, duration > 0 {
            frameState.elapsed = min(duration, playbackAnchorPosition
                + max(0, ProcessInfo.processInfo.systemUptime - playbackAnchorUptime))
        }
        // The stream handles regular updates. Poll only if it exits or cannot start.
        if !nowPlayingStream.isRunning && (isPlaying || tickCount.isMultiple(of: 20)) {
            refresh()
        }
    }

    private func updatePlaybackState(_ playing: Bool) {
        let previousState = lastObservedPlaybackState
        lastObservedPlaybackState = playing
        if isPlaying != playing {
            // Resume from the held position, not from time spent paused.
            playbackAnchorPosition = elapsed
            playbackAnchorUptime = ProcessInfo.processInfo.systemUptime
            isPlaying = playing
        }
        if previousState != playing { updateAudioCapture() }

        if playing {
            idlePresentationTask?.cancel()
            idlePresentationTask = nil
            isIdlePresentationReady = false
            if !compactDisplayState.isPowerStatus
                && compactDisplayState != .airPods && !compactDisplayState.isAdjustmentHUD {
                if compactDisplayState != .music { compactDisplayState = .music }
            }
        } else if previousState != false {
            scheduleIdlePresentation()
        }
    }

    private func scheduleIdlePresentation() {
        idlePresentationTask?.cancel()
        isIdlePresentationReady = false
        let configuredDelay = ProcessInfo.processInfo.environment["NOTCH_MUSIC_IDLE_DELAY"]
            .flatMap(TimeInterval.init) ?? 30
        idlePresentationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(configuredDelay, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.isIdlePresentationReady = true
            if !self.compactDisplayState.isPowerStatus
                && self.compactDisplayState != .airPods && !self.compactDisplayState.isAdjustmentHUD {
                self.compactDisplayState = .idle
            }
        }
    }

    private func applyAirPodsSnapshot(_ snapshot: AirPodsSnapshot?) {
        let wasConnected = isAirPodsConnected

        guard let snapshot else {
            isAirPodsConnected = false
            airPodsDismissTask?.cancel()
            airPodsDismissTask = nil
            isShowingAirPodsDetails = false
            if wasConnected, compactDisplayState == .airPods {
                restoreDefaultCompactDisplay()
            }
            return
        }

        airPodsName = snapshot.name
        airPodsLeftBattery = snapshot.leftBattery
        airPodsRightBattery = snapshot.rightBattery
        airPodsUnitBattery = snapshot.unitBattery
        isAirPodsConnected = true

        if !wasConnected {
            chargingDismissTask?.cancel()
            chargingDismissTask = nil
            compactDisplayState = .airPods
            scheduleAirPodsDismiss(after: 9)
        }
    }

    private func scheduleAirPodsDismiss(after delay: TimeInterval) {
        airPodsDismissTask?.cancel()
        airPodsDismissTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(max(delay, 0) * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  !self.isShowingAirPodsDetails,
                  self.compactDisplayState == .airPods else { return }
            self.restoreDefaultCompactDisplay()
        }
    }

    private func restoreDefaultCompactDisplay() {
        compactDisplayState = isIdlePresentationReady ? .idle : .music
    }

    func adjustVolumeKey(_ input: VolumeKeyInput) -> Bool {
        guard input.isBrightness else { return volumeMonitor.adjust(input) }
        guard let level = brightnessController.adjust(input) else { return false }
        presentBrightness(level)
        return true
    }

    func presentBrightness(_ level: Float) {
        guard level.isFinite else { return }
        screenBrightness = min(max(level, 0), 1)
        presentAdjustment(.brightness)
    }
    @discardableResult func setOutputVolume(_ level: Float) -> Bool { volumeMonitor.setLevel(level) }

    func presentVolume(_ snapshot: OutputVolumeSnapshot) {
        outputVolume = min(max(snapshot.level, 0), 1)
        outputMuted = snapshot.muted
        presentAdjustment(.volume)
    }

    private func presentAdjustment(_ state: CompactDisplayState) {
        chargingDismissTask?.cancel()
        airPodsDismissTask?.cancel()
        isShowingAirPodsDetails = false
        if compactDisplayState != state { compactDisplayState = state }
        volumeDismissTask?.cancel()
        volumeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.compactDisplayState == state else { return }
            self.restoreDefaultCompactDisplay()
        }
    }

    private func presentPowerEvent(_ event: PowerConnectionEvent) {
        let snapshot: PowerSnapshot
        let displayState: CompactDisplayState
        switch event {
        case .connected(let value):
            snapshot = value
            displayState = .charging
        case .disconnected(let value):
            snapshot = value
            displayState = .disconnected
        case .batteryLevel(let value):
            snapshot = value
            displayState = .batteryLevel
        }
        batteryLevelIsCharging = snapshot.isConnectedToPower
        batteryPercentage = snapshot.percentage
        airPodsDismissTask?.cancel()
        airPodsDismissTask = nil
        isShowingAirPodsDetails = false
        let nextState: CompactDisplayState = batteryAlertInterval != .off && LowBatteryPolicy.isLow(percentage: snapshot.percentage, connected: snapshot.isConnectedToPower)
            ? .lowBattery : displayState
        compactDisplayState = nextState
        lowPowerMode.refresh()
        schedulePowerDismiss()
    }

    private var browserCommandGeneration = 0

    private func send(command: Int) {
        guard isYouTubeMusicSource else { return }
        if let pid = browserProcessID {
            browserCommandGeneration += 1
            let generation = browserCommandGeneration
            let action: YouTubeBrowserPlayback.Command = command == Command.nextTrack ? .next : command == Command.previousTrack ? .previous : .toggle
            Task { @MainActor [weak self] in
                let sent = await YouTubeBrowserPlayback.shared.send(action, processID: pid)
                guard let self, sent, generation == self.browserCommandGeneration else { return }
                if let snapshot = await YouTubeBrowserPlayback.shared.read(processID: pid),
                   generation == self.browserCommandGeneration, self.browserProcessID == pid {
                    self.applyBrowserSnapshot(snapshot, bundle: self.playbackBundleIdentifier)
                }
                self.scheduleBrowserRefresh(processID: pid)
            }
            return
        }
        if isUsingYouTubeMusicWebAppFallback { return }
        runBridge(arguments: ["send", String(command)]) { [weak self] data, error in
            if let error {
                self?.debugLog("command error: \(error)")
                // Never send global media keys to an unrelated player.
            } else if let data,
                      let response = try? JSONDecoder().decode(CommandResponse.self, from: data),
                      response.success != true {
                if response.ignored == true {
                    self?.debugLog("command ignored because the active source is not YouTube Music")
                } else {
                    self?.debugLog("command rejected; no global fallback")
                    // Never send global media keys to an unrelated player.
                }
            }
            self?.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        commandRefreshTask?.cancel()
        refresh(afterCurrentRequest: true, evenIfStreaming: true)
        commandRefreshTask = Task { [weak self] in
            // Music apps may publish the new track slightly after acknowledging a command.
            // Coalesce overlapping reads so a busy bridge cannot lose the follow-up.
            for delay: UInt64 in [150_000_000, 250_000_000, 400_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.refresh(afterCurrentRequest: true, evenIfStreaming: true)
            }
        }
    }

    private func scheduleBrowserRefresh(processID: pid_t) {
        commandRefreshTask?.cancel()
        commandRefreshTask = Task { @MainActor [weak self] in
            // Browser accessibility notifications are not reliable for every
            // transport control. Explicitly invalidate the lightweight cache
            // after a successful command and retry while the page publishes it.
            for delay: UInt64 in [80_000_000, 180_000_000, 320_000_000, 500_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.hasStarted else { return }
                await YouTubeBrowserPlayback.shared.invalidate(
                    processID: processID,
                    structure: false,
                    layout: true
                )
                self.lastBrowserPoll = .distantPast
                self.pollYouTubeBrowser()
            }
        }
    }

    private func resetMetadata(showIdleImmediately: Bool = false) {
        browserProcessID = nil
        pendingSeek = nil
        lastBrowserRead = .distantPast
        lastBridgeBrowserInvalidation = .distantPast
        playbackBundleIdentifier = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkLookupID = nil
        title = "재생 중이 아님"
        artist = ""
        album = ""
        pendingArtworkTransitionKey = nil
        setArtwork(nil, animatesChange: false)
        artworkTrackKey = ""
        artworkAttemptCount = 0
        artworkNextAttemptAt = .distantPast
        artworkSourceRank = 0
        duration = 0
        elapsed = 0
        updatePlaybackState(false)
        sourceApp = "대기 중"
        isYouTubeMusicSource = false
        isUsingYouTubeMusicWebAppFallback = false
        if showIdleImmediately {
            idlePresentationTask?.cancel()
            idlePresentationTask = nil
            isIdlePresentationReady = true
            if !compactDisplayState.isPowerStatus
                && compactDisplayState != .airPods && !compactDisplayState.isAdjustmentHUD {
                compactDisplayState = .idle
            }
        }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["NOTCH_MUSIC_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[NotchMusic] \(message)\n".utf8))
    }
}
