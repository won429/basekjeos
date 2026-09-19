import AppKit
import Combine
import SwiftUI

enum ImmersiveDetailMode { case lyrics, queue }
struct LyricsRequestIdentity: Hashable {
    let title: String
    let artist: String

    init(track: LyricsTrack) {
        title = Self.normalize(track.title)
        artist = Self.normalize(track.artist)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

private struct ImmersiveLyricsRequest: Hashable {
    let track: LyricsRequestIdentity
    let enabled: Bool
    let language: AppLanguage
    let provider: LyricsProvider
    let retry: Int
}

@MainActor
final class ImmersiveLyricPlaybackState: ObservableObject {
    @Published fileprivate(set) var activeLine: Int?
}

// Subscribe only to data this screen uses; audio meter frames never invalidate it.
@MainActor
final class ImmersivePlayerModel: ObservableObject {
    @Published var track: LyricsTrack
    @Published var artwork: NSImage?
    @Published var colors: [NSColor]
    @Published var backgroundMode: BackgroundGraphicsMode
    @Published var isPlaying: Bool
    @Published var duration: Double
    @Published var language: AppLanguage
    @Published var lyricsProvider: LyricsProvider
    @Published var outputVolume: Float
    @Published var outputMuted: Bool
    @Published var canAdjustVolume: Bool
    @Published var queue: [PlaybackQueueItem] = []
    @Published var queueLoading = false
    @Published var queueError: PlaybackQueueError?
    @Published var queueSelectionID: Int?
    @Published var queueLoaded = false
    @Published var lyrics = TrackLyrics()
    @Published var loading = true
    @Published var failed = false
    @Published var presented = false
    @Published var backgroundMotionEnabled = false
    @Published var detailMode: ImmersiveDetailMode? = .lyrics
    private var subscriptions = Set<AnyCancellable>()
    private var lyricTime: Double
    private var loadedLyricsTrack: LyricsTrack?
    private var loadedLyricsLanguage: AppLanguage?
    private var loadedLyricsProvider: LyricsProvider?
    private var lyricsRequestID = UUID()
    private var activeLyricsRequest: ImmersiveLyricsRequest?
    private var lyricsFetchTask: Task<TrackLyrics, Error>?
    let client: MediaRemoteClient
    let frameState: PlaybackFrameState
    let lyricState = ImmersiveLyricPlaybackState()
    var elapsed: Double { frameState.elapsed }
    var activeLine: Int? { lyricState.activeLine }

    init(client: MediaRemoteClient) {
        self.client = client
        frameState = client.frameState
        track = LyricsTrack(title: client.title, artist: client.artist, album: client.album,
                            duration: Int(client.duration.rounded()))
        artwork = client.artworkPresentation.image
        colors = client.waveformColors
        backgroundMode = client.backgroundGraphicsMode
        isPlaying = client.isPlaying
        lyricTime = client.elapsed
        duration = client.duration
        language = client.appLanguage
        lyricsProvider = client.lyricsProvider
        outputVolume = client.outputVolume
        outputMuted = client.outputMuted
        canAdjustVolume = client.canAdjustOutputVolume
        // Album and duration are often reported differently by the browser and
        // MediaRemote. They refine display metadata but do not identify a new
        // song, so they must never restart a lyric lookup.
        client.$title.combineLatest(client.$artist)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] title, artist in
                guard let self else { return }
                let next = LyricsTrack(
                    title: title,
                    artist: artist,
                    album: client.album,
                    duration: Int(client.duration.rounded())
                )
                guard LyricsRequestIdentity(track: self.track) != LyricsRequestIdentity(track: next) else {
                    return
                }
                self.lyricsFetchTask?.cancel()
                self.lyricsRequestID = UUID()
                self.activeLyricsRequest = nil
                self.lyrics = TrackLyrics()
                self.loadedLyricsTrack = nil
                self.lyricState.activeLine = nil
                self.loading = true
                self.track = next
            }.store(in: &subscriptions)
        client.$artworkPresentation.sink { [weak self] in self?.artwork = $0.image }.store(in: &subscriptions)
        client.$waveformColors.sink { [weak self] in self?.colors = $0 }.store(in: &subscriptions)
        client.$backgroundGraphicsMode.removeDuplicates().sink { [weak self] in self?.backgroundMode = $0 }.store(in: &subscriptions)
        client.$isPlaying.removeDuplicates().sink { [weak self] in self?.isPlaying = $0 }.store(in: &subscriptions)
        client.$duration.removeDuplicates().sink { [weak self] in self?.duration = $0 }.store(in: &subscriptions)
        client.$appLanguage.removeDuplicates().sink { [weak self] in self?.language = $0 }.store(in: &subscriptions)
        client.$lyricsProvider.removeDuplicates().sink { [weak self] in self?.lyricsProvider = $0 }.store(in: &subscriptions)
        client.$outputVolume.removeDuplicates().sink { [weak self] in self?.outputVolume = $0 }.store(in: &subscriptions)
        client.$outputMuted.removeDuplicates().sink { [weak self] in self?.outputMuted = $0 }.store(in: &subscriptions)
        client.$canAdjustOutputVolume.removeDuplicates().sink { [weak self] in self?.canAdjustVolume = $0 }.store(in: &subscriptions)
        // Lyrics only change when crossing a line boundary. Limiting delivery
        // to 5 Hz keeps the transport smooth while avoiding needless SwiftUI
        // invalidations during playback.
        client.frameState.$elapsed
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] time in
                guard let self else { return }
                // MediaRemote/browser bridges can briefly publish an older
                // position while the transport is advancing. Do not make
                // lyrics visibly jump backwards for these short glitches;
                // large seeks are still accepted immediately.
                if self.isPlaying, time + 0.75 < self.lyricTime { return }
                self.lyricTime = time
            self.updateActiveLine()
        }.store(in: &subscriptions)
    }

    func loadQueue() async {
        let requestedTrack = track
        queueLoading = true
        queueError = nil
        queueLoaded = false
        queue = []
        do {
            let result = try await client.loadPlaybackQueue()
            try Task.checkCancellation()
            guard requestedTrack == track else { return }
            queue = result
            queueLoaded = true
            queueLoading = false
        } catch {
            guard !Task.isCancelled, requestedTrack == track else { return }
            queueLoading = false
            queueError = (error as? PlaybackQueueError) ?? .unavailable
        }
    }

    func playQueueItem(_ item: PlaybackQueueItem) async {
        guard queueSelectionID == nil else { return }
        queueSelectionID = item.id
        queueError = nil
        do {
            try await client.playPlaybackQueueItem(item)
        } catch {
            queueError = (error as? PlaybackQueueError) ?? .unavailable
        }
        queueSelectionID = nil
    }

    func loadLyrics(using service: LyricsClient = .shared, forceRefresh: Bool = false) async {
        let requestedTrack = track
        let requestedLanguage = language
        let requestedProvider = lyricsProvider
        let request = ImmersiveLyricsRequest(
            track: LyricsRequestIdentity(track: requestedTrack),
            enabled: true,
            language: requestedLanguage,
            provider: lyricsProvider,
            retry: 0
        )
        // SwiftUI cancels the task when the lyrics pane leaves the hierarchy.
        // Never attach a new load to that cancelled task: doing so leaves the
        // pane waiting forever when it is opened again. A forced refresh must
        // also always start a fresh request.
        if !forceRefresh, activeLyricsRequest == request, let task = lyricsFetchTask,
           !task.isCancelled {
            do {
                _ = try await task.value
                return
            } catch is CancellationError {
                // The owner below will clear the stale request in its defer.
            } catch {
                // A failed shared request may be retried by this caller.
            }
        }
        guard forceRefresh || loadedLyricsTrack != requestedTrack || loadedLyricsLanguage != requestedLanguage || loadedLyricsProvider != lyricsProvider || failed else { return }
        let requestID = UUID()
        lyricsRequestID = requestID
        activeLyricsRequest = request
        loading = lyrics.lines.isEmpty && lyrics.plain.isEmpty && !lyrics.instrumental
        failed = false
        lyricsFetchTask?.cancel()
        let task = Task {
            if requestedProvider == .youtubeMusic {
                guard let raw = await self.client.readYouTubeLyrics(), !raw.isEmpty else { throw URLError(.resourceUnavailable) }
                let lines = TrackLyrics.parse(raw)
                return TrackLyrics(lines: lines, plain: lines.isEmpty ? raw : "")
            }
            return try await service.lyrics(for: requestedTrack, language: requestedLanguage, forceRefresh: forceRefresh)
        }
        lyricsFetchTask = task
        defer {
            if lyricsRequestID == requestID {
                activeLyricsRequest = nil
                lyricsFetchTask = nil
                loading = false
            }
        }
        do {
            let result = try await task.value
            guard requestedTrack == track, requestedLanguage == language, lyricsRequestID == requestID else { return }
            lyrics = result
            loadedLyricsTrack = requestedTrack
            loadedLyricsLanguage = requestedLanguage
            loadedLyricsProvider = requestedProvider
            activeLyricsRequest = nil
            updateActiveLine()
            loading = false
        } catch {
            guard lyricsRequestID == requestID else { return }
            activeLyricsRequest = nil
            guard !(error is CancellationError), requestedTrack == track, requestedLanguage == language else { return }
            loading = false
            failed = true
        }
    }

    deinit { lyricsFetchTask?.cancel() }

    private func updateActiveLine() {
        let next = lyrics.activeIndex(at: lyricTime)
        if lyricState.activeLine != next { lyricState.activeLine = next }
    }
}

private final class ImmersivePanel: NSPanel {
    var dismiss: (() -> Void)?
    var togglePlayback: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() }
        else if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            togglePlayback?()
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class ImmersivePlayerController {
    private var panel: ImmersivePanel?
    private var model: ImmersivePlayerModel?
    private var closing = false
    private var presentationTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    var isVisible: Bool { panel != nil }
    var onTransition: ((Bool) -> Void)?

    func show(client: MediaRemoteClient, screen: NSScreen, sourceArtworkFrame: NSRect,
              lyricsService: LyricsClient = .shared, sourceSurfaceFrame: NSRect? = nil) {
        guard panel == nil else { return }
        let model = ImmersivePlayerModel(client: client)
        let frame = screen.frame
        let surface = sourceSurfaceFrame ?? NSRect(x: frame.midX - 110, y: frame.maxY - 36, width: 220, height: 36)
        let source = CGRect(x: surface.minX - frame.minX, y: frame.maxY - surface.maxY,
                            width: surface.width, height: surface.height)
        let panel = ImmersivePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.dismiss = { [weak self] in self?.close() }
        panel.togglePlayback = { [weak client] in client?.togglePlayback() }
        let view = NSHostingView(rootView: ImmersivePlayerView(model: model, source: source,
            onClose: { [weak self] in self?.close() }, lyricsService: lyricsService))
        view.sizingOptions = []
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = PlayerHostingContainer(hostedView: view)
        self.model = model
        self.panel = panel
        closing = false
        panel.makeKeyAndOrderFront(nil)
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self, weak model, weak panel] in
            // Give SwiftUI one run-loop turn to lay out the initial portal. Forcing
            // synchronous layout and display here made the first transition frame
            // contend with the full-screen animation.
            await Task.yield()
            guard let self, let model, let panel,
                  self.model === model, self.panel === panel,
                  !Task.isCancelled else { return }
            self.onTransition?(true)
            withAnimation(ImmersiveMotion.opening) { model.presented = true }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(ImmersiveMotion.openDuration * 1_000_000_000)
                )
            } catch { return }
            guard self.model === model, self.panel === panel, !self.closing else { return }
            // The full-screen background starts after the portal settles, keeping
            // its compositor work out of the entry animation.
            model.backgroundMotionEnabled = true
            self.presentationTask = nil
        }
    }

    func close(animated: Bool = true) {
        guard panel != nil else { return }
        if !animated {
            dismissalTask?.cancel()
            finishClosing()
            return
        }
        guard !closing else { return }
        closing = true
        presentationTask?.cancel()
        presentationTask = nil
        model?.backgroundMotionEnabled = false
        dismissalTask?.cancel()
        withAnimation(ImmersiveMotion.closing) { model?.presented = false }
        dismissalTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(ImmersiveMotion.closeDuration * 1_000_000_000)) } catch { return }
            self?.finishClosing()
        }
    }

    private func finishClosing() {
        // Removing the hosting view cancels its lyric task and all subscriptions.
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        model = nil
        closing = false
        presentationTask?.cancel()
        presentationTask = nil
        dismissalTask = nil
        onTransition?(false)
    }

}

struct ImmersivePlayerView: View {
    @ObservedObject var model: ImmersivePlayerModel
    let source: CGRect
    let onClose: () -> Void
    var lyricsService: LyricsClient = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retry = 0
    @State private var queueRetry = 0
    @State private var volumeValue: Double = 0
    @State private var volumeDragging = false
    @State private var lastAudibleVolume: Double = 0.5
    @State private var dateLeading: CGFloat?

    private var korean: Bool { model.language == .korean }
    private var progress: CGFloat { model.presented ? 1 : 0 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let contentWidth = width - max(80, width * 0.12)
            let hidesDetails = model.detailMode == nil
            let cover = min(360, contentWidth * 0.36, max(160, height - 350))
            let playerColumnWidth = max(cover, contentWidth * 0.36)
            let leading = (width - contentWidth) / 2
            let top = max(90, (height - cover - 220) / 2)
            let detailTop = top
            // Lyrics and queue now extend alongside the complete transport and
            // volume stack instead of ending at the bottom edge of the cover.
            let detailHeight = min(cover + 220, max(cover, height - detailTop - 88))
            // Match the established lyric column to the date (not the time)
            // in the centered top clock.
            let lyricLeading = dateLeading ?? width / 2
            let lyricWidth = max(0, width - leading - lyricLeading)
            let target = CGPoint(x: hidesDetails ? width / 2 : leading + playerColumnWidth / 2, y: top + cover / 2)
            ZStack(alignment: .topLeading) {
                ambientBackground

                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.up").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background {
                                LiquidGlassCapsule { Color.clear }
                                    .allowsHitTesting(false)
                            }
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(korean ? "플레이어로 돌아가기 (Esc)" : "Back to player (Esc)")
                    .accessibilityLabel(korean ? "몰입 화면 닫기" : "Close immersive player")
                    .frame(width: 42, height: 42)
                    Spacer()
                    ImmersiveClock(language: model.language)
                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.horizontal, 36).padding(.top, max(42, geometry.safeAreaInsets.top + 12))

                coverImage
                    .frame(width: cover, height: cover)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35 * progress), radius: 32 * progress, y: 18 * progress)
                    .modifier(PlaybackArtworkMotion(isPlaying: model.isPlaying))
                    .position(x: target.x, y: target.y)

                transport
                    .frame(width: cover)
                    .position(x: target.x, y: top + cover + 110)

                Group {
                    if model.detailMode == .queue { queuePane }
                    else { lyricsPane }
                }
                    .id(model.detailMode)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 16)))
                    .animation(.easeInOut(duration: 0.32), value: model.loading)
                    .frame(width: lyricWidth, height: detailHeight)
                    .position(x: lyricLeading + lyricWidth / 2, y: detailTop + detailHeight / 2)
                    .opacity(hidesDetails ? 0 : 1)
                    .allowsHitTesting(!hidesDetails)

                Text(model.detailMode == .lyrics ? (korean ? "가사 · \(model.lyricsProvider.title)" : "Lyrics · \(model.lyricsProvider.title)") : "YouTube Music")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .position(x: 90, y: height - 40)

                LiquidGlassCapsule {
                    HStack(spacing: 2) {
                        modeButton(.lyrics, symbol: "quote.bubble.fill", label: korean ? "가사" : "Lyrics")
                        modeButton(.queue, symbol: "list.bullet", label: korean ? "재생목록" : "Queue")
                    }
                    .padding(4)
                    .preferredColorScheme(.dark)
                }
                .frame(width: 102, height: 48)
                .position(x: width - 87, y: height - 44)
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "immersiveContent")
            .clipped()
            .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.9), value: model.detailMode)
            .modifier(ImmersivePortal(progress: progress, source: source, reduceMotion: reduceMotion, size: geometry.size))
            .allowsHitTesting(model.presented)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task(id: ImmersiveLyricsRequest(track: LyricsRequestIdentity(track: model.track), enabled: model.detailMode == .lyrics, language: model.language, provider: model.lyricsProvider, retry: retry)) {
            if model.detailMode == .lyrics { await model.loadLyrics(using: lyricsService, forceRefresh: model.failed) }
        }
        .task(id: ImmersiveLyricsRequest(track: LyricsRequestIdentity(track: model.track), enabled: model.detailMode == .queue, language: model.language, provider: model.lyricsProvider, retry: queueRetry)) {
            if model.detailMode == .queue { await model.loadQueue() }
        }
        .onReceive(model.$outputVolume) { if !volumeDragging { volumeValue = Double($0) } }
        .onPreferenceChange(ImmersiveDateLeadingKey.self) { dateLeading = $0 }
    }

    private var ambientBackground: some View {
        ZStack {
            AmbientArtworkView(colors: model.colors,
                moving: model.backgroundMotionEnabled && !reduceMotion,
                mode: model.backgroundMode, audioSource: model.client)
            LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var coverImage: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.track.title).font(.system(size: 21, weight: .bold)).lineLimit(1)
            Text(model.track.artist).font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.50)).lineLimit(1).padding(.top, 5)
            ImmersivePlaybackProgress(
                frameState: model.frameState,
                duration: model.duration,
                client: model.client,
                korean: korean
            )
            .padding(.top, 20)
            HStack(spacing: 44) {
                playbackButton("backward.fill", label: korean ? "이전 곡" : "Previous track",
                               size: 23, action: model.client.previousTrack)
                playbackButton(model.isPlaying ? "pause.fill" : "play.fill",
                               label: model.isPlaying ? (korean ? "일시 정지" : "Pause") : (korean ? "재생" : "Play"),
                               size: 32, action: model.client.togglePlayback)
                playbackButton("forward.fill", label: korean ? "다음 곡" : "Next track",
                               size: 23, action: model.client.nextTrack)
            }
            .frame(maxWidth: .infinity).padding(.top, 12)
            volumeControls.padding(.top, 14)
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 12) {
            Button {
                let silenced = model.outputMuted || volumeValue < 0.001
                if !silenced { lastAudibleVolume = volumeValue }
                let target = silenced ? max(0.05, lastAudibleVolume) : 0
                if model.client.setOutputVolume(Float(target)) { volumeValue = target }
            } label: {
                Image(systemName: model.outputMuted || volumeValue < 0.001 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).disabled(!model.canAdjustVolume)
            .accessibilityLabel(korean ? "음소거 또는 음량 복원" : "Mute or restore volume")
            PlaybackProgressBar(value: Binding(get: { volumeValue }, set: { value in
                volumeValue = value
                if !model.client.setOutputVolume(Float(value)) { volumeValue = Double(model.outputVolume) }
            }), duration: 1, accessibilityTitle: korean ? "음량" : "Volume",
                valueDescription: { "\(Int($0 * 100))%" }) { editing, _ in
                volumeDragging = editing
                if !editing { volumeValue = Double(model.outputVolume) }
            }
            .frame(height: 20).disabled(!model.canAdjustVolume)
            .opacity(model.canAdjustVolume ? 1 : 0.35)
            Button(action: model.client.openAudioOutputSettings) {
                Image(systemName: "speaker.wave.3.fill").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(korean ? "사운드 출력 설정 열기" : "Open sound output settings")
            .accessibilityLabel(korean ? "사운드 출력 설정" : "Sound output settings")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .help(model.canAdjustVolume ? (korean ? "시스템 음량" : "System volume")
              : (korean ? "이 출력 기기는 기기에서 음량을 조절하세요" : "Adjust volume on this output device"))
    }

    private func playbackButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        PlaybackTransportButton(symbol: symbol, size: size, width: 48, height: 48, action: action)
            .help(label).accessibilityLabel(label)
    }

    private func modeButton(_ mode: ImmersiveDetailMode, symbol: String, label: String) -> some View {
        Button {
            model.detailMode = model.detailMode == mode ? nil : mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(model.detailMode == mode ? 1 : 0.58))
                .frame(width: 46, height: 40)
                .background(.white.opacity(model.detailMode == mode ? 0.20 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(model.detailMode == mode ? 0.22 : 0), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityValue(model.detailMode == mode ? (korean ? "선택됨" : "Selected") : "")
    }

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(korean ? "재생목록" : "Queue")
                .font(.system(size: 30, weight: .bold))
            HStack(spacing: 16) {
                coverImage.frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(korean ? "현재 재생 중" : "Now playing")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(model.track.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Text(model.track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(.white.opacity(0.1))
            if model.queueLoading {
                ProgressView().controlSize(.small)
            } else if model.queueLoaded {
                if model.queue.isEmpty {
                    Text(korean ? "다음 트랙이 없어요." : "No upcoming tracks.")
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(model.queue) { item in
                                Button {
                                    Task { await model.playQueueItem(item) }
                                } label: {
                                    HStack(alignment: .center, spacing: 16) {
                                        Text(String(item.id + 1)).monospacedDigit()
                                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                                            .frame(width: 24)
                                        QueueArtwork(item: item)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                                            if !item.artist.isEmpty {
                                                Text(item.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        if model.queueSelectionID == item.id {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.52))
                                                .frame(width: 28, height: 28)
                                                .background(.white.opacity(0.08), in: Circle())
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.queueSelectionID != nil)
                                .accessibilityHint(korean ? "이 노래 재생" : "Play this song")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(HiddenScrollIndicators())
                    }.scrollIndicators(.hidden)
                    .frame(maxHeight: .infinity)
                    if model.queueError != nil {
                        Text(korean ? "선택한 노래를 재생하지 못했어요. 재생목록을 새로고침해 주세요."
                             : "Couldn’t play that song. Refresh the queue and try again.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
            } else {
                Text(model.queueError == .permissionRequired
                     ? (korean ? "다음 트랙을 읽으려면 Nook의 손쉬운 사용 권한이 필요해요." : "Allow Accessibility access for Nook to read upcoming tracks.")
                     : (korean ? "YouTube Music에서 다음 트랙을 연 뒤 다시 가져와 주세요." : "Open Up next in YouTube Music, then refresh."))
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LiquidGlassCapsule {
                Button { queueRetry += 1 } label: {
                    Label(korean ? "다시 가져오기" : "Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 160, height: 44)
                }.buttonStyle(.plain).disabled(model.queueLoading)
            }.frame(width: 160, height: 44)
            LiquidGlassCapsule {
                Button {
                    onClose()
                    model.client.revealYouTubeMusic()
                } label: {
                    Label(korean ? "YouTube Music 열기" : "Open YouTube Music", systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 220, height: 44)
                }.buttonStyle(.plain)
            }.frame(width: 220, height: 44)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var lyricsPane: some View {
        if model.loading {
            VStack(alignment: .leading, spacing: 18) {
                ProgressView().controlSize(.small)
                Text(korean ? "가사를 불러오는 중" : "Finding the words")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if !model.lyrics.lines.isEmpty {
            syncedLyrics
        } else if !model.lyrics.plain.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(korean ? "시간 정보가 없는 가사" : "Lyrics without timing")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    Text(model.lyrics.plain).font(.system(size: 28.6, weight: .bold)).lineSpacing(12)
                        .foregroundStyle(.white.opacity(0.7))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 65)
                .background(HiddenScrollIndicators())
            }.scrollIndicators(.hidden)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: model.lyrics.instrumental ? "waveform" : "quote.bubble")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.3))
                Text(model.failed ? (korean ? "가사를 불러오지 못했어요" : "Couldn’t load lyrics")
                     : model.lyrics.instrumental ? (korean ? "가사 없이, 음악에 집중" : "Just the music")
                     : (korean ? "아직 등록된 가사가 없어요" : "No lyrics for this track yet"))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                Text(korean ? "그대로 음악을 즐겨보세요." : "Stay here. Enjoy the music.")
                    .font(.system(size: 16)).foregroundStyle(.white.opacity(0.35))
                if !model.lyrics.instrumental {
                    LiquidGlassCapsule {
                        Button {
                            model.failed = true
                            retry += 1
                        } label: {
                            Label(korean ? "다시 가져오기" : "Try again", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 160, height: 44)
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                    }.frame(width: 160, height: 44).padding(.top, 12)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var syncedLyrics: some View {
        SyncedLyricsView(
            lines: model.lyrics.lines,
            playback: model.lyricState,
            client: model.client,
            korean: korean,
            reduceMotion: reduceMotion
        )
    }

    private func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct ImmersivePlaybackProgress: View {
    @ObservedObject var frameState: PlaybackFrameState
    let duration: Double
    let client: MediaRemoteClient
    let korean: Bool
    @State private var scrub = 0.0
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            PlaybackProgressBar(value: $scrub, duration: duration) { editing, position in
                dragging = editing
                if !editing { client.seek(to: position) }
            }
            .frame(height: 22)
            .disabled(duration <= 0)
            .accessibilityLabel(korean ? "재생 위치" : "Playback position")
            HStack {
                Text(time(scrub))
                Spacer()
                Text("−" + time(max(0, duration - scrub)))
            }
            .font(PlayerTypography.playbackTime)
            .foregroundStyle(.white.opacity(0.4))
        }
        .onReceive(frameState.$elapsed.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)) {
            if !dragging { scrub = $0 }
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @ObservedObject var playback: ImmersiveLyricPlaybackState
    let client: MediaRemoteClient
    let korean: Bool
    let reduceMotion: Bool
    @State private var lyricsReady = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(lines) { line in
                            SyncedLyricRow(line: line, active: playback.activeLine == line.id,
                                client: client, korean: korean, reduceMotion: reduceMotion,
                                lyricsReady: lyricsReady,
                                entranceDelay: Double(min(abs(line.id - (playback.activeLine ?? 0)), 4)) * 0.025)
                                .equatable()
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, geometry.size.height * 0.38)
                    .padding(.trailing, 8)
                    .background(HiddenScrollIndicators())
                }
                .scrollIndicators(.hidden)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.13),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                .task {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        lyricsReady = false
                        proxy.scrollTo(playback.activeLine ?? 0, anchor: .center)
                    }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    lyricsReady = true
                }
            }
        }
    }
}

// The playback publisher belongs to the list; unchanged rows retain their view
// graph when another line becomes active. Preserve all existing motion values.
private struct SyncedLyricRow: View, Equatable {
    let line: LyricLine
    let active: Bool
    let client: MediaRemoteClient
    let korean: Bool
    let reduceMotion: Bool
    let lyricsReady: Bool
    let entranceDelay: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line && lhs.active == rhs.active && lhs.client === rhs.client
            && lhs.korean == rhs.korean && lhs.reduceMotion == rhs.reduceMotion
            && lhs.lyricsReady == rhs.lyricsReady && lhs.entranceDelay == rhs.entranceDelay
    }

    var body: some View {
        Button { client.seek(to: line.time) } label: {
            Text(line.text.isEmpty ? "•••" : line.text)
                .font(.system(size: 32, weight: .bold))
                .lineSpacing(5)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white.opacity(active ? 1 : 0.27))
                .scaleEffect(active ? 1 : 27.0 / 32.0, anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(lyricsReady ? 1 : 0)
        .offset(y: lyricsReady || reduceMotion ? 0 : 18)
        .animation(reduceMotion ? .easeOut(duration: 0.12)
            : .easeOut(duration: 0.36).delay(entranceDelay),
            value: lyricsReady)
        .animation(.easeInOut(duration: 0.20), value: active)
        .background {
            if active {
                SmoothLyricScrollAnchor(lineID: line.id, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(line.text.isEmpty ? (korean ? "간주" : "Instrumental break") : line.text)
        .accessibilityHint(korean ? "이 구절부터 재생" : "Play from this line")
    }
}
