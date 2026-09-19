import AppKit
import SwiftUI

// Remove the entire media subtree while immersive playback owns presentation.
// Opacity alone would leave its timelines and frame subscriptions running.
struct NotchPlayerSurface: View {
    let mediaClient: MediaRemoteClient
    @ObservedObject var layout: NotchLayoutModel
    let onExpansionChanged: (Bool) -> Void
    var onArtworkSelected: () -> Void = {}

    var body: some View {
        if layout.immersiveActive {
            PlayerSurfaceShape(style: layout.presentationStyle, expansionProgress: 0,
                               compactHeight: layout.compactHeight, expandedCornerRadius: 28)
                .fill(.black)
                .frame(width: layout.compactWidth, height: layout.compactHeight)
                .scaleEffect(1 + 0.22 * layout.immersivePulse, anchor: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            NotchPlayerView(mediaClient: mediaClient, layout: layout,
                            onExpansionChanged: onExpansionChanged,
                            onArtworkSelected: onArtworkSelected)
        }
    }
}

struct NotchPlayerView: View {
    @ObservedObject var mediaClient: MediaRemoteClient
    @ObservedObject var layout: NotchLayoutModel
    let onExpansionChanged: (Bool) -> Void
    var onArtworkSelected: () -> Void = {}

    @State private var isDraggingSlider = false
    @State private var sliderValue: Double = 0

    var body: some View {
        let progress = layout.expansionProgress
        let musicReveal = ramp(progress, from: 0.02, to: 0.55)
        let compactState = layout.compactDisplayState
        let artworkPresentation = mediaClient.artworkPresentation
        let isShowingAirPods = compactState == .airPods
        let isShowingLowBattery = compactState == .lowBattery
        let warningCompactState = layout.lowBatteryReturnState ?? layout.lowBatterySourceState
        let warningCompactReveal = 1 - ramp(progress, from: 0.02, to: 0.30)
        let musicContentVisibility: CGFloat = isShowingAirPods ? 0
            : isShowingLowBattery ? (warningCompactState == .music ? warningCompactReveal : 0) : 1
        let expandedMusicVisibility: CGFloat = isShowingLowBattery ? 0 : musicContentVisibility
        let surfaceWidthScale = layout.visualSize.width / layout.expandedWidth
        let contentScale = min(surfaceWidthScale, layout.visualSize.height / layout.expandedHeight)
        let expansionBlur = musicContentVisibility * sin(progress * .pi) * 4.5
        let usesSynchronizedMusicReveal = (compactState == .music || compactState == .idle)
            || layout.usesSynchronizedPowerTransition
        let compactMediaVisibility = musicContentVisibility * (
            isShowingLowBattery ? 1 : usesSynchronizedMusicReveal
                ? lerp(layout.compactMusicVisibility, 1, ramp(progress, from: 0.10, to: 0.38))
                : compactState == .music
                ? CGFloat(1)
                : ramp(progress, from: 0.10, to: 0.38)
        )
        let isShowingPowerStatus = compactState.isPowerStatus || compactState.isAdjustmentHUD
        let powerDisplayState = isShowingLowBattery
            ? (warningCompactState.isCompactHUD ? warningCompactState : nil)
            : layout.usesSynchronizedPowerTransition
            ? layout.compactPowerDisplayState
            : (compactState.isCompactHUD ? compactState : nil)
        let chargingVisibility = isShowingLowBattery ? warningCompactReveal
            : (layout.usesSynchronizedPowerTransition
            ? layout.compactPowerVisibility : (isShowingPowerStatus ? 1 : 0))
            * (1 - ramp(progress, from: 0.04, to: 0.25))
        let usesDynamicIslandLayout = layout.presentationStyle == .dynamicIsland
        let dynamicIslandScale = usesDynamicIslandLayout ? layout.compactHeight / 36 : 1
        let compactArtSize: CGFloat = usesDynamicIslandLayout ? 22 * dynamicIslandScale : 22
        let compactArtX: CGFloat = layout.compactAccessoryLeadingInset + compactArtSize / 2
        let compactWaveWidth: CGFloat = usesDynamicIslandLayout ? 22 * dynamicIslandScale : 36
        let compactWaveHeight: CGFloat = usesDynamicIslandLayout ? 18 * dynamicIslandScale : 18
        let compactWaveTrailingInset = layout.compactAccessoryTrailingInset + compactWaveWidth / 2
        let compactWaveBarCount = usesDynamicIslandLayout ? 6 : 9
        let artSize = lerp(compactArtSize, 60, progress)
        let artY = lerp(layout.compactContentCenterY, expandedTopPadding + 30, progress)
        let waveX = lerp(
            layout.compactWidth - compactWaveTrailingInset,
            layout.expandedWidth - (usesDynamicIslandLayout ? 34 : 57),
            progress
        )
        let waveY = artY

        ZStack(alignment: .top) {
            ZStack {
                PlayerSurfaceShape(
                    style: layout.presentationStyle,
                    expansionProgress: progress,
                    compactHeight: layout.compactHeight,
                    expandedCornerRadius: isShowingAirPods || isShowingLowBattery
                        ? layout.expandedHeight / 2
                        : 28
                )
                .fill(Color.black)
                .contentShape(PlayerSurfaceShape(style: layout.presentationStyle,
                    expansionProgress: progress, compactHeight: layout.compactHeight,
                    expandedCornerRadius: isShowingAirPods || isShowingLowBattery ? layout.expandedHeight / 2 : 28))
                .onTapGesture {
                    guard layout.isExpanded else { return }
                    if isShowingAirPods { mediaClient.setAirPodsDetailsVisible(false) }
                    onExpansionChanged(false)
                }

                ArtworkFlipView(
                    artwork: artworkPresentation.image,
                    revision: artworkPresentation.revision,
                    animatesChange: artworkPresentation.animatesChange,
                    size: artSize,
                    cornerRadius: lerp(5, 12, progress),
                    onArtworkDisplayed: mediaClient.updateDisplayedArtworkColors
                )
                .frame(width: artSize, height: artSize)
                .modifier(PlaybackArtworkMotion(isPlaying: mediaClient.isPlaying))
                .contentShape(RoundedRectangle(cornerRadius: lerp(5, 12, progress), style: .continuous))
                .onTapGesture(perform: onArtworkSelected)
                .blur(radius: expansionBlur)
                .position(x: lerp(compactArtX, usesDynamicIslandLayout ? 50 : 72, progress), y: artY)
                .opacity(compactMediaVisibility)
                .allowsHitTesting(progress > 0.90 && !isShowingLowBattery && !isShowingAirPods
                                  && mediaClient.isYouTubeMusicSource)
                .help(mediaClient.appLanguage == .korean ? "앨범과 가사 크게 보기" : "Open album and lyrics")
                .accessibilityLabel(mediaClient.appLanguage == .korean ? "몰입형 음악 화면 열기" : "Open immersive player")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onArtworkSelected() }

                if isShowingAirPods {
                    AirPodsStatusView(
                        name: mediaClient.airPodsName,
                        language: mediaClient.appLanguage,
                        unitBattery: mediaClient.airPodsUnitBattery,
                        leftBattery: mediaClient.airPodsLeftBattery,
                        rightBattery: mediaClient.airPodsRightBattery,
                        usesNotchLayout: !usesDynamicIslandLayout,
                        protectedCenterWidth: layout.volumeProtectedCenterWidth,
                        progress: progress,
                        compactWidth: layout.compactWidth,
                        expandedWidth: layout.expandedWidth,
                        compactHeight: layout.compactHeight,
                        expandedHeight: layout.expandedHeight
                    )
                    .frame(
                        width: layout.visualSize.width,
                        height: layout.visualSize.height
                    )
                    .offset(y: layout.compactContentOffsetY * (1 - progress))
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(mediaClient.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !mediaClient.artist.isEmpty {
                        Text(mediaClient.artist)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)
                    }
                }
                .frame(width: usesDynamicIslandLayout ? 198 : max(1, layout.expandedWidth - 210), alignment: .leading)
                .scaleEffect(surfaceWidthScale)
                .blur(radius: expansionBlur)
                .position(x: (usesDynamicIslandLayout ? 194 : 118 + max(1, layout.expandedWidth - 210) / 2) * surfaceWidthScale, y: artY)
                .opacity(musicReveal * expandedMusicVisibility)
                .allowsHitTesting(false)

                ObservedLiveWaveform(
                    frameState: mediaClient.frameState,
                    mode: mediaClient.waveformMode,
                    isPlaying: mediaClient.isPlaying,
                    colors: mediaClient.waveformColors,
                    barCount: 9,
                    compactEmphasis: 1 - progress,
                    compactBarCount: compactWaveBarCount,
                    compactBarWidth: usesDynamicIslandLayout ? 2 * dynamicIslandScale : 1.75,
                    compactBarSpacing: usesDynamicIslandLayout ? 2 * dynamicIslandScale : 2
                )
                .frame(
                    width: lerp(compactWaveWidth, 30, progress),
                    height: lerp(compactWaveHeight, 30, progress)
                )
                .blur(radius: expansionBlur)
                .position(x: waveX, y: waveY)
                .opacity(compactMediaVisibility)
                .allowsHitTesting(false)

                if let powerDisplayState {
                    Group {
                    if powerDisplayState.isAdjustmentHUD {
                        VolumeCompactView(level: powerDisplayState == .brightness ? mediaClient.screenBrightness : mediaClient.outputVolume,
                                          muted: powerDisplayState == .volume && mediaClient.outputMuted,
                                          isBrightness: powerDisplayState == .brightness,
                                          language: mediaClient.appLanguage, scale: layout.volumeContentScale,
                                          protectedCenter: layout.volumeProtectedCenterWidth,
                                          leadingInset: layout.alertLeadingInset,
                                          trailingInset: layout.alertTrailingInset)
                    } else {
                    ChargingCompactView(
                        isConnected: powerDisplayState == .charging
                            || (powerDisplayState == .batteryLevel && mediaClient.batteryLevelIsCharging),
                        isLevelNotification: powerDisplayState == .batteryLevel,
                        isLowBattery: false,
                        percentage: mediaClient.batteryPercentage,
                        language: mediaClient.appLanguage,
                        usesNotchLayout: !usesDynamicIslandLayout,
                        protectedCenterWidth: layout.volumeProtectedCenterWidth,
                        leadingInset: layout.alertLeadingInset,
                        trailingInset: layout.alertTrailingInset,
                        height: layout.compactHeight
                    )
                    }
                    }
                    .frame(width: powerDisplayState.isAdjustmentHUD ? layout.visualSize.width
                           : usesDynamicIslandLayout ? layout.compactPowerContentWidth : layout.compactWidth,
                           height: layout.compactHeight)
                    .position(
                        x: layout.visualSize.width / 2,
                        y: layout.compactContentCenterY
                    )
                    .opacity(chargingVisibility)
                    .allowsHitTesting(false)
                }

                playbackProgress
                    .frame(width: usesDynamicIslandLayout ? 320 : layout.expandedWidth - 84, height: 28)
                    .scaleEffect(contentScale)
                    .blur(radius: expansionBlur)
                    .position(x: layout.visualSize.width / 2,
                              y: lerp(layout.compactHeight / 2, expandedTopPadding + (usesDynamicIslandLayout ? 78 : 92), progress))
                    .opacity(musicReveal * expandedMusicVisibility)
                    .allowsHitTesting(!isShowingLowBattery && !isShowingAirPods && progress > 0.90)

                playerControls
                    .frame(width: layout.expandedWidth, height: 48)
                    .scaleEffect(contentScale)
                    .blur(radius: expansionBlur)
                    .position(
                        x: layout.visualSize.width / 2,
                        y: lerp(layout.compactHeight / 2,
                                min(layout.expandedHeight - 23, expandedTopPadding + (usesDynamicIslandLayout ? 119 : 140)), progress)
                    )
                    .opacity(musicReveal * expandedMusicVisibility)
                    .allowsHitTesting(!isShowingLowBattery && !isShowingAirPods && progress > 0.90)

                if isShowingLowBattery {
                    LowBatteryDetailsView(
                        percentage: mediaClient.batteryPercentage,
                        language: mediaClient.appLanguage,
                        mode: mediaClient.lowPowerMode,
                        usesNotchLayout: !usesDynamicIslandLayout,
                        onToggle: { mediaClient.toggleLowPowerMode() }
                    )
                    .padding(.top, usesDynamicIslandLayout ? 0 : layout.compactHeight)
                    .frame(width: layout.expandedWidth, height: layout.expandedHeight)
                    .scaleEffect(min(surfaceWidthScale, layout.visualSize.height / layout.expandedHeight))
                    .blur(radius: sin(progress * .pi) * 3)
                    .position(x: layout.visualSize.width / 2, y: layout.visualSize.height / 2)
                    .opacity(ramp(progress, from: 0.18, to: 0.72))
                    .allowsHitTesting(progress > 0.65)
                }

                if progress > 0.90 && !isShowingLowBattery {
                    Button {
                        if compactState == .airPods {
                            mediaClient.setAirPodsDetailsVisible(false)
                        }
                        onExpansionChanged(false)
                    } label: {
                        Color.clear
                            .frame(width: layout.presentationStyle == .notch ? layout.expandedWidth : layout.compactWidth, height: layout.compactHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: compactState == .airPods
                            ? layout.expandedWidth
                            : layout.presentationStyle == .notch ? layout.expandedWidth : layout.compactWidth,
                        height: compactState == .airPods
                            ? layout.expandedHeight
                            : layout.compactHeight
                    )
                    .position(
                        x: layout.visualSize.width / 2,
                        y: compactState == .airPods
                            ? layout.expandedHeight / 2
                            : layout.compactHeight / 2
                    )
                    .help("노치를 클릭하여 플레이어 닫기")
                }

                if progress < 0.08 && !isShowingLowBattery {
                    Button {
                        if compactState == .airPods {
                            mediaClient.setAirPodsDetailsVisible(true)
                        }
                        onExpansionChanged(true)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isShowingLowBattery ? mediaClient.appLanguage.lowPowerSettingsHint : "클릭하여 플레이어 열기")
                    .accessibilityLabel(
                        isShowingLowBattery
                            ? mediaClient.appLanguage.batteryDetailTitle(mediaClient.batteryPercentage)
                            : compactState == .airPods
                            ? "AirPods 연결 정보 열기"
                            : compactState == .idle
                                ? "음악 플레이어 열기"
                                : "재생 중인 오디오 미터"
                    )
                }
            }
            .frame(width: layout.visualSize.width, height: layout.visualSize.height)
            .clipShape(
                PlayerSurfaceShape(
                    style: layout.presentationStyle,
                    expansionProgress: progress,
                    compactHeight: layout.compactHeight,
                    expandedCornerRadius: isShowingAirPods || isShowingLowBattery
                        ? layout.expandedHeight / 2
                        : 28
                )
            )
        }
        .frame(width: layout.visualSize.width, height: layout.visualSize.height, alignment: .top)
        .scaleEffect(1 + 0.22 * layout.immersivePulse, anchor: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        // All surface geometry is driven by the controller's display link.
        // A second implicit animation here trails its clipping mask behind it.
        .animation(nil, value: compactState)
        .preferredColorScheme(.dark)
    }

    private var playbackProgress: some View {
        NotchPlaybackProgress(
            frameState: mediaClient.frameState,
            duration: mediaClient.duration,
            onSeek: mediaClient.seek
        )
    }

    private var playerControls: some View {
        ZStack {
            PlaybackTransportButton(symbol: "backward.fill", size: 22, width: 40, action: mediaClient.previousTrack)
            .position(x: layout.presentationStyle == .notch ? layout.expandedWidth / 2 - 84 : 97, y: 24)

            PlaybackTransportButton(symbol: mediaClient.isPlaying ? "pause.fill" : "play.fill", size: 30, width: 44, action: mediaClient.togglePlayback)
            .position(x: layout.presentationStyle == .notch ? layout.expandedWidth / 2 : 181, y: 24)

            PlaybackTransportButton(symbol: "forward.fill", size: 22, width: 40, action: mediaClient.nextTrack)
            .position(x: layout.presentationStyle == .notch ? layout.expandedWidth / 2 + 84 : 264, y: 24)

            Button(action: mediaClient.openAudioOutputSettings) {
                Image(systemName: "airplayaudio")
            }
            .buttonStyle(PlayerButtonStyle(size: 23))
            .position(x: layout.presentationStyle == .notch ? layout.expandedWidth - 57 : 323, y: 24)
        }
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func ramp(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(max((value - start) / (end - start), 0), 1)
    }

    private var compactPlayer: some View {
        Button {
            onExpansionChanged(true)
        } label: {
            HStack(spacing: 0) {
                artwork(
                    size: 22,
                    cornerRadius: 5
                )

                Spacer()

                ObservedLiveWaveform(
                    frameState: mediaClient.frameState,
                    mode: mediaClient.waveformMode,
                    isPlaying: mediaClient.isPlaying,
                    colors: mediaClient.waveformColors,
                    barCount: 9
                )
                .frame(width: 34, height: 15)
            }
            .padding(.horizontal, 10)
            .frame(width: layout.compactWidth, height: layout.compactHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("클릭하여 플레이어 열기")
    }

    private var expandedPlayer: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    artwork(
                        size: 60,
                        cornerRadius: 12
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mediaClient.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(mediaClient.artist)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                ObservedLiveWaveform(
                    frameState: mediaClient.frameState,
                        mode: mediaClient.waveformMode,
                        isPlaying: mediaClient.isPlaying,
                        colors: mediaClient.waveformColors,
                        barCount: 9
                    )
                    .frame(width: 30, height: 30)
                }
                .frame(height: 60)

                HStack(spacing: 8) {
                    Text(timeString(sliderValue))
                        .frame(width: 36, alignment: .leading)

                    PlaybackProgressBar(
                        value: $sliderValue,
                        duration: mediaClient.duration
                    ) { editing, position in
                        isDraggingSlider = editing
                        if !editing, mediaClient.duration > 0 {
                            mediaClient.seek(to: position)
                        }
                    }
                    .frame(height: 12)

                    Text(remainingTime)
                        .frame(width: 42, alignment: .trailing)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.56))
                .padding(.top, 14)

                ZStack {
                    HStack(spacing: 40) {
                        PlaybackTransportButton(symbol: "backward.fill", size: 22, width: 40, action: mediaClient.previousTrack)

                        PlaybackTransportButton(symbol: mediaClient.isPlaying ? "pause.fill" : "play.fill", size: 30, width: 44, action: mediaClient.togglePlayback)

                        PlaybackTransportButton(symbol: "forward.fill", size: 22, width: 40, action: mediaClient.nextTrack)
                    }

                    HStack {
                        Spacer()
                        Button(action: mediaClient.openAudioOutputSettings) {
                            Image(systemName: "airplayaudio")
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.white.opacity(0.56))
                                .frame(width: 36, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 40)
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(
                .top,
                expandedTopPadding
            )
            .padding(.bottom, 10)

            Button {
                onExpansionChanged(false)
            } label: {
                Color.clear
                    .frame(width: layout.compactWidth, height: layout.compactHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("노치를 클릭하여 플레이어 닫기")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var expandedTopPadding: CGFloat {
        layout.expandedMusicTopPadding
    }

    private var remainingTime: String {
        guard mediaClient.duration > 0 else { return "–:––" }
        return "−\(timeString(max(mediaClient.duration - sliderValue, 0)))"
    }

    private func timeString(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func artwork(
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        Group {
            if let artwork = mediaClient.artworkPresentation.image {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.38), Color(white: 0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ArtworkFlipView: View {
    let artwork: NSImage?
    let revision: Int
    let animatesChange: Bool
    let size: CGFloat
    let cornerRadius: CGFloat
    let onArtworkDisplayed: (NSImage?) -> Void

    @State private var displayedArtwork: NSImage?
    @State private var appliedRevision: Int
    @State private var rotation = Double.zero
    @State private var blurRadius = CGFloat.zero
    @State private var artworkOpacity = Double(1)

    init(
        artwork: NSImage?,
        revision: Int,
        animatesChange: Bool,
        size: CGFloat,
        cornerRadius: CGFloat,
        onArtworkDisplayed: @escaping (NSImage?) -> Void
    ) {
        self.onArtworkDisplayed = onArtworkDisplayed
        self.artwork = artwork
        self.revision = revision
        self.animatesChange = animatesChange
        self.size = size
        self.cornerRadius = cornerRadius
        _displayedArtwork = State(initialValue: artwork)
        _appliedRevision = State(initialValue: revision)
    }

    var body: some View {
        ArtworkFace(artwork: displayedArtwork, size: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .rotation3DEffect(
                .degrees(rotation),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.10
            )
            .blur(radius: blurRadius)
            .opacity(artworkOpacity)
            .task(id: revision) {
                guard revision != appliedRevision else {
                    onArtworkDisplayed(displayedArtwork)
                    return
                }
                appliedRevision = revision

                guard animatesChange,
                      displayedArtwork != nil,
                      artwork != nil else {
                    replaceCoverImmediately(with: artwork)
                    return
                }
                await animateCoverChange(to: artwork)
            }
    }

    @MainActor
    private func animateCoverChange(to newArtwork: NSImage?) async {
        // The reference animation turns the old cover edge-on, swaps it at the
        // thinnest point, then lets the new, softly blurred cover settle forward.
        withAnimation(.timingCurve(0.42, 0, 0.72, 1, duration: 0.20)) {
            rotation = 88
            blurRadius = 1.2
            artworkOpacity = 0.82
        }

        do {
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        displayedArtwork = newArtwork
        onArtworkDisplayed(newArtwork)
        rotation = -76
        blurRadius = 4.5
        artworkOpacity = 0.74

        withAnimation(.timingCurve(0.22, 0.68, 0.32, 1, duration: 0.20)) {
            rotation = 0
        }
        withAnimation(.easeOut(duration: 0.40)) {
            blurRadius = 0
            artworkOpacity = 1
        }
    }

    private func replaceCoverImmediately(with newArtwork: NSImage?) {
        displayedArtwork = newArtwork
        onArtworkDisplayed(newArtwork)
        rotation = 0
        blurRadius = 0
        artworkOpacity = 1
    }
}

private struct ArtworkFace: View {
    let artwork: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(white: 0.38),
                            Color(white: 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }
}

private struct AirPodsStatusView: View {
    let name: String
    let language: AppLanguage
    let unitBattery: Int?
    let leftBattery: Int?
    let rightBattery: Int?
    let usesNotchLayout: Bool
    let protectedCenterWidth: CGFloat
    let progress: CGFloat
    let compactWidth: CGFloat
    let expandedWidth: CGFloat
    let compactHeight: CGFloat
    let expandedHeight: CGFloat

    @State private var arrivalProgress = CGFloat.zero

    var body: some View {
        let reveal = min(max((progress - 0.16) / 0.50, 0), 1)
        let expandedCenterY = usesNotchLayout ? compactHeight + (expandedHeight - compactHeight) / 2 : expandedHeight / 2
        let centerY = interpolate(compactHeight / 2, expandedCenterY, progress)
        let productSize = interpolate(30, 58, progress)
        let ringSize = interpolate(15, 34, progress)
        let wingWidth = (compactWidth - protectedCenterWidth) / 2
        let compactLabelReveal = min(max((wingWidth - 70) / 26, 0), 1)
        let compactRingX = interpolate(compactWidth - 39, compactWidth - 85, compactLabelReveal)
        let productX = interpolate(usesNotchLayout ? 39 : compactWidth * 0.125,
                                   usesNotchLayout ? 58 : min(40, expandedWidth * 0.13), progress)
        let ringX = interpolate(usesNotchLayout ? compactRingX : compactWidth * 0.885,
                                usesNotchLayout ? expandedWidth - 48 : expandedWidth - min(40, expandedWidth * 0.11), progress)
        let textLeftX = interpolate(compactWidth * 0.24, usesNotchLayout ? 100 : min(78, expandedWidth * 0.25), progress)
        let textWidth = max(1, expandedWidth - textLeftX - (usesNotchLayout ? 80 : 62))

        ZStack {
            if usesNotchLayout {
                Text("AirPods")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 54, alignment: .leading)
                    .position(x: 81, y: compactHeight / 2)
                    .opacity((1 - reveal) * compactLabelReveal)
                Text(unitBattery.map { "\(min(max($0, 0), 100))%" } ?? "–")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .frame(width: 44)
                    .position(x: compactWidth - 49, y: compactHeight / 2)
                    .opacity((1 - reveal) * compactLabelReveal)
            }
            RotatingAirPodsProduct(name: name, size: productSize)
                .position(
                    x: productX,
                    y: centerY
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(language.airPodsConnectedStatus)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))

                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: textWidth, alignment: .leading)
            .position(
                x: textLeftX + textWidth / 2,
                y: centerY
            )
            .opacity(reveal)
            .offset(y: (1 - reveal) * -3)

            AirPodsBatteryRing(
                percentage: unitBattery,
                percentageVisibility: reveal
            )
                .frame(width: ringSize, height: ringSize)
                .position(
                    x: ringX,
                    y: centerY
                )
        }
        .opacity(arrivalProgress)
        .blur(radius: (1 - arrivalProgress) * 3.5)
        .scaleEffect(0.94 + arrivalProgress * 0.06)
        .onAppear {
            arrivalProgress = 0
            withAnimation(.timingCurve(0.20, 0.78, 0.24, 1, duration: 0.30)) {
                arrivalProgress = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        language.airPodsAccessibilityDescription(
            name: name,
            unitBattery: unitBattery,
            leftBattery: leftBattery,
            rightBattery: rightBattery
        )
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ value: CGFloat) -> CGFloat {
        start + (end - start) * value
    }
}

private struct RotatingAirPodsProduct: View {
    let name: String
    let size: CGFloat

    @State private var animationStart = Date()

    var body: some View {
        Group {
            if name.range(of: "max", options: .caseInsensitive) != nil {
                Image(systemName: "airpodsmax")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            } else if !AirPodsRotationFrameStore.images.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    let elapsed = max(context.date.timeIntervalSince(animationStart), 0)
                    let frameIndex = Int(elapsed * AirPodsRotationFrameStore.framesPerSecond)
                        % AirPodsRotationFrameStore.images.count
                    Image(nsImage: AirPodsRotationFrameStore.images[frameIndex])
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: "airpodspro")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            animationStart = Date()
        }
    }
}

private enum AirPodsRotationFrameStore {
    static let framesPerSecond = 12.0
    static let images: [NSImage] = (0..<60).compactMap { index in
        Bundle.main.url(
            forResource: String(format: "airpods-%03d", index),
            withExtension: "png",
            subdirectory: "AirPodsRotation"
        ).flatMap(NSImage.init(contentsOf:))
    }
}

private struct AirPodsBatteryRing: View {
    let percentage: Int?
    let percentageVisibility: CGFloat

    var body: some View {
        let clamped = min(max(percentage ?? 0, 0), 100)
        let fraction = CGFloat(clamped) / 100
        let ringLineWidth = 2.4 + (2.2 * percentageVisibility)

        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: ringLineWidth)

            Circle()
                .trim(from: 0, to: max(fraction, 0.018))
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(percentage.map(String.init) ?? "–")
                .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.green.opacity(0.98))
                .minimumScaleFactor(0.7)
                .opacity(percentageVisibility)
        }
    }
}

struct LowBatteryDetailsView: View {
    let percentage: Int
    let language: AppLanguage
    @ObservedObject var mode: LowPowerModeController
    var usesNotchLayout = false
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: usesNotchLayout ? 22 : 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(language.batteryDetailTitle(min(max(percentage, 0), 100)))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if mode.didFail {
                    Button(language.lowPowerFailed) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text(mode.isChanging ? language.lowPowerChanging
                         : mode.isEnabled ? language.lowPowerActive : language.lowPowerPrompt)
                        .foregroundStyle(mode.isEnabled ? Color(red: 1, green: 0.79, blue: 0.25) : Color.white.opacity(0.48))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggle) {
                LowBatteryModeBadge(percentage: percentage, isEnabled: mode.isEnabled)
                    .overlay {
                        if mode.isChanging { ProgressView().controlSize(.small) }
                    }
            }
            .buttonStyle(.plain)
            .disabled(mode.isChanging)
            .accessibilityLabel(language == .korean
                ? "저전력 모드 \(mode.isEnabled ? "끄기" : "켜기")"
                : "Turn Low Power Mode \(mode.isEnabled ? "off" : "on")")
        }
        .padding(.leading, usesNotchLayout ? 42 : 30)
        .padding(.trailing, usesNotchLayout ? 42 : 16)
        .animation(.easeInOut(duration: 0.25), value: mode.isEnabled)
    }
}

private struct LowBatteryModeBadge: View {
    let percentage: Int
    let isEnabled: Bool
    @State private var pulse = false
    private let red = Color(red: 1, green: 0.28, blue: 0.36)
    private let yellow = Color(red: 1, green: 0.79, blue: 0.25)

    var body: some View {
        ZStack {
            Capsule().fill(isEnabled ? yellow : Color(red: 0.20, green: 0.025, blue: 0.045))
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isEnabled ? Color.black : red.opacity(0.32))
                    Capsule()
                        .fill(isEnabled ? yellow : red)
                        .frame(width: max(6, 34 * CGFloat(min(max(percentage, 0), 100)) / 100), height: 15)
                        .padding(.leading, 4)
                    if !isEnabled {
                        Circle().stroke(Color(red: 1, green: 0.12, blue: 0.18).opacity(pulse ? 0 : 1), lineWidth: 1.3)
                            .frame(width: 20, height: 20)
                            .scaleEffect(pulse ? 2.7 : 0.65)
                            .offset(x: -3)
                    }
                }
                .frame(width: 42, height: 23)
                Capsule().fill(isEnabled ? Color.black : red.opacity(0.45))
                    .frame(width: 2, height: 8)
            }
        }
        .frame(width: 82, height: 54)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct VolumeCompactView: View {
    let level: Float
    let muted: Bool
    var isBrightness: Bool = false
    let language: AppLanguage
    let scale: CGFloat
    let protectedCenter: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            // Grow the outer padding with the wings so it cannot consume all
            // newly available space during the first frames of expansion.
            let availableWing = max(0, (geometry.size.width - protectedCenter) / 2)
            let leading = min(leadingInset, availableWing * 0.25)
            let trailing = min(trailingInset, availableWing * 0.25)
            let leftWing = max(0, availableWing - leading)
            let rightWing = max(0, availableWing - trailing)
            HStack(spacing: 0) {
                HStack(spacing: 5 * scale) {
                    Image(systemName: isBrightness ? "sun.max.fill" : muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Text(isBrightness ? (language == .korean ? "밝기" : "Brightness")
                         : language == .korean ? (muted ? "음소거" : "음량") : (muted ? "Muted" : "Volume"))
                }
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .fixedSize()
                .frame(width: leftWing, alignment: .leading)
                .clipped()
                Color.clear.frame(width: protectedCenter)
                GeometryReader { bar in
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white)
                        .frame(width: bar.size.width * CGFloat(muted ? 0 : min(max(level, 0), 1)))
                }
                .frame(width: min(rightWing, 76 * scale), height: 3 * scale)
                .animation(.easeOut(duration: 0.10), value: level)
                .animation(.easeOut(duration: 0.10), value: muted)
                .frame(width: rightWing, alignment: .trailing)
                .clipped()
            }
            .foregroundStyle(.white)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isBrightness ? (language == .korean ? "밝기" : "Brightness") : (language == .korean ? "음량" : "Volume")) \(muted ? 0 : Int(level * 100))%")
    }
}

private struct ChargingCompactView: View {
    let isConnected: Bool
    let isLevelNotification: Bool
    let isLowBattery: Bool
    let percentage: Int
    let language: AppLanguage
    let usesNotchLayout: Bool
    let protectedCenterWidth: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let height: CGFloat

    @State private var displayedCharge: CGFloat = 0

    var body: some View {
        let scale = min(max(height / 26, 0.68), 1.18)
        let accent = isLowBattery || (isConnected && percentage <= 20)
            ? Color.red : isConnected ? Color.green : Color.white.opacity(0.48)

        GeometryReader { geometry in
        let availableWing = max(0, (geometry.size.width - protectedCenterWidth) / 2)
        let leading = min(leadingInset, availableWing * 0.25)
        let trailing = min(trailingInset, availableWing * 0.25)
        HStack(spacing: 0) {
            Text(isLowBattery ? language.lowBatteryStatus : isLevelNotification && !isConnected
                 ? language.batteryLevelStatus
                 : language.chargingStatus(isConnected: isConnected))
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: max(0, availableWing - leading), alignment: .leading)
                .clipped()

            Color.clear.frame(width: protectedCenterWidth)

            HStack(spacing: 5 * scale) {
            Text("\(min(max(percentage, 0), 100))%")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .font(.system(size: 10.5 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)

            ChargingBatteryGauge(fraction: displayedCharge, color: accent, filledBody: isLowBattery)
                .frame(width: 24 * scale, height: 11 * scale)
            }
            .frame(width: max(0, availableWing - trailing), alignment: .trailing)
            .clipped()
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: geometry.size.height)
        }
        .onAppear {
            displayedCharge = 0
            withAnimation(.easeOut(duration: 0.85)) {
                displayedCharge = CGFloat(min(max(percentage, 0), 100)) / 100
            }
        }
        .onChange(of: percentage) { newValue in
            withAnimation(.easeOut(duration: 0.4)) {
                displayedCharge = CGFloat(min(max(newValue, 0), 100)) / 100
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isLowBattery ? "\(language.lowBatteryStatus), \(percentage)%" : isLevelNotification && !isConnected
                ? "\(language.batteryLevelStatus), \(percentage)%"
                : language.chargingAccessibilityLabel(
                isConnected: isConnected,
                percentage: percentage
            )
        )
    }
}

private struct ChargingBatteryGauge: View {
    let fraction: CGFloat
    let color: Color
    var filledBody = false

    var body: some View {
        GeometryReader { geometry in
            let terminalWidth = max(1.5, geometry.size.width * 0.07)
            let bodyWidth = geometry.size.width - terminalWidth - 1

            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    if filledBody {
                        RoundedRectangle(cornerRadius: geometry.size.height * 0.32, style: .continuous)
                            .fill(Color(red: 0.23, green: 0.17, blue: 0.18))
                        Rectangle()
                            .fill(color)
                            .frame(width: bodyWidth * min(max(fraction, 0), 1))
                            .frame(width: bodyWidth, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: geometry.size.height * 0.32, style: .continuous))
                    } else {
                    RoundedRectangle(cornerRadius: geometry.size.height * 0.28, style: .continuous)
                        .stroke(Color.white.opacity(0.42), lineWidth: 1)
                    RoundedRectangle(cornerRadius: geometry.size.height * 0.20, style: .continuous)
                        .fill(color)
                        .frame(width: max(0, (bodyWidth - 3) * min(max(fraction, 0), 1)))
                        .padding(1.5)
                    }
                }
                .frame(width: bodyWidth, height: geometry.size.height)

                Capsule()
                    .fill(Color.white.opacity(0.42))
                    .frame(width: terminalWidth, height: geometry.size.height * 0.38)
            }
        }
    }
}

struct PlaybackProgressBar: View {
    @Binding var value: Double
    let duration: Double
    var accessibilityTitle = "재생 위치"
    var valueDescription: ((Double) -> String)? = nil
    let onEditingChanged: (Bool, Double) -> Void

    @State private var isEditing = false

    var body: some View {
        GeometryReader { geometry in
            let fraction: CGFloat = duration > 0
                ? CGFloat(min(max(value / duration, 0), 1))
                : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white.opacity(0.62))
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard duration > 0 else { return }
                        let position = min(max(gesture.location.x, 0), geometry.size.width)
                        let updatedValue = duration * Double(position / max(geometry.size.width, 1))
                        value = updatedValue
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true, updatedValue)
                        }
                    }
                    .onEnded { gesture in
                        guard duration > 0 else { return }
                        let position = min(max(gesture.location.x, 0), geometry.size.width)
                        let finalValue = duration * Double(position / max(geometry.size.width, 1))
                        value = finalValue
                        isEditing = false
                        onEditingChanged(false, finalValue)
                    }
            )
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(valueDescription?(value) ?? (duration > 0 ? "\(Int(value))초" : "사용할 수 없음"))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            onEditingChanged(true, value)
            let adjustedValue: Double
            switch direction {
            case .increment: adjustedValue = min(duration, value + duration / 20)
            case .decrement: adjustedValue = max(0, value - duration / 20)
            @unknown default: adjustedValue = value
            }
            value = adjustedValue
            onEditingChanged(false, adjustedValue)
        }
    }
}

private struct NotchPlaybackProgress: View {
    @ObservedObject var frameState: PlaybackFrameState
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var value = 0.0
    @State private var isEditing = false
    @State private var lastDisplayedValue = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Text(time(value)).frame(width: 36, alignment: .leading)
            PlaybackProgressBar(value: $value, duration: duration) { editing, position in
                isEditing = editing
                if !editing, duration > 0 { onSeek(position) }
            }
            .frame(height: 12)
            Text("−\(time(max(duration - value, 0)))").frame(width: 42, alignment: .trailing)
        }
        .font(PlayerTypography.playbackTime)
        .foregroundStyle(.white.opacity(0.56))
        .onReceive(frameState.$elapsed) {
            guard !isEditing else { return }
            // Ignore short stale bridge samples so the label and thumb cannot
            // alternate between adjacent positions during playback.
            guard $0 + 0.75 >= lastDisplayedValue else { return }
            lastDisplayedValue = $0
            value = $0
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct ObservedLiveWaveform: View {
    @ObservedObject var frameState: PlaybackFrameState
    let mode: WaveformMode
    let isPlaying: Bool
    let colors: [NSColor]
    let barCount: Int
    var compactEmphasis: CGFloat = 0
    var compactBarCount: Int? = nil
    var compactBarWidth: CGFloat = 1.75
    var compactBarSpacing: CGFloat = 2

    var body: some View {
        LiveWaveform(
            mode: mode,
            isPlaying: isPlaying,
            levels: frameState.audioLevels,
            colors: colors,
            barCount: barCount,
            compactEmphasis: compactEmphasis,
            compactBarCount: compactBarCount,
            compactBarWidth: compactBarWidth,
            compactBarSpacing: compactBarSpacing
        )
    }
}

private struct LiveWaveform: View {
    private enum ChannelRole {
        case low
        case accompaniment
        case vocal
        case high
    }

    private static let roleOrder: [ChannelRole] = [
        .low, .vocal, .high, .accompaniment, .low,
        .vocal, .high, .accompaniment, .vocal
    ]
    private static let attackRates: [CGFloat] = [0.58, 0.51, 0.62, 0.48, 0.56, 0.53, 0.60, 0.50, 0.55]
    private static let releaseRates: [CGFloat] = [0.34, 0.29, 0.38, 0.31, 0.36, 0.30, 0.37, 0.33, 0.27]
    private static let barGains: [Double] = [1.08, 1.02, 1.10, 0.98, 1.06, 1.03, 1.08, 0.96, 1.00]
    // Deliberately non-symmetrical so the meter does not settle into a ribbon silhouette.
    private static let maximumHeights: [CGFloat] = [0.78, 0.86, 0.74, 0.83, 0.80, 0.88, 0.77, 0.85, 0.82]
    private static let basicPhases: [Double] = [0.00, 0.43, 0.91, 1.37, 1.82, 2.29, 2.74, 3.18, 3.63]
    private static let sixBarCompactSlots: [CGFloat] = [0, 0.5, 1, 2, 2.5, 3, 4, 4.5, 5]
    private static let sixBarCompactVisibility = [true, false, true, true, false, true, true, false, true]

    @State private var liveDisplayAmounts = Array(repeating: CGFloat(0.08), count: 9)
    @State private var previousLiveLevels: [Double] = []
    @State private var cachedBarColors: [NSColor] = []

    let mode: WaveformMode
    let isPlaying: Bool
    let levels: [Double]
    let colors: [NSColor]
    let barCount: Int
    var compactEmphasis: CGFloat = 0
    var compactBarCount: Int? = nil
    var compactBarWidth: CGFloat = 1.75
    var compactBarSpacing: CGFloat = 2

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 18.0,
                paused: !isPlaying || (mode == .live && !levels.isEmpty)
            )
        ) { timeline in
            GeometryReader { geometry in
                let resolvedCompactBarCount = min(
                    max(compactBarCount ?? barCount, 1),
                    barCount
                )
                let expandedSpacing: CGFloat = 1.5
                let expandedBarWidth = max(
                    1.5,
                    (geometry.size.width - expandedSpacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                )
                let barWidth = expandedBarWidth
                    + (compactBarWidth - expandedBarWidth) * compactEmphasis
                let compactContentWidth = compactBarWidth * CGFloat(resolvedCompactBarCount)
                    + compactBarSpacing * CGFloat(resolvedCompactBarCount - 1)
                let expandedContentWidth = expandedBarWidth * CGFloat(barCount)
                    + expandedSpacing * CGFloat(barCount - 1)
                let compactStartX = (geometry.size.width - compactContentWidth) / 2
                let expandedStartX = (geometry.size.width - expandedContentWidth) / 2
                let usesSixBarCompactLayout = resolvedCompactBarCount == 6 && barCount == 9
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    ForEach(0..<barCount, id: \.self) { index in
                        let rawAmount = amount(at: index, time: time)
                        let emphasizedAmount = min(
                            1,
                            CGFloat(pow(Double(rawAmount), 0.72)) + 0.08
                        )
                        let displayedAmount = rawAmount
                            + (emphasizedAmount - rawAmount) * compactEmphasis
                        let compactSlot = usesSixBarCompactLayout
                            ? Self.sixBarCompactSlots[index]
                            : CGFloat(min(index, resolvedCompactBarCount - 1))
                        let compactX = compactStartX
                            + compactBarWidth / 2
                            + CGFloat(compactSlot) * (compactBarWidth + compactBarSpacing)
                        let expandedX = expandedStartX
                            + expandedBarWidth / 2
                            + CGFloat(index) * (expandedBarWidth + expandedSpacing)
                        let barX = expandedX + (compactX - expandedX) * compactEmphasis
                        let expansionProgress = 1 - compactEmphasis
                        let isVisibleWhenCompact = usesSixBarCompactLayout
                            ? Self.sixBarCompactVisibility[index]
                            : index < resolvedCompactBarCount
                        let addedBarOpacity = isVisibleWhenCompact
                            ? CGFloat(1)
                            : min(max((expansionProgress - 0.18) / 0.42, 0), 1)

                        Capsule()
                            .fill(barColor(at: index))
                            .frame(
                                width: barWidth,
                                height: max(3, geometry.size.height * displayedAmount)
                            )
                            .position(x: barX, y: geometry.size.height / 2)
                            .opacity((isPlaying ? 0.96 : 0.42) * addedBarOpacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .animation(.easeOut(duration: 0.16), value: isPlaying)
            }
        }
        .onAppear {
            cachedBarColors = resolvedBarColors
            updateLiveDisplayAmounts(using: levels)
        }
        .onChange(of: colors) { _ in cachedBarColors = resolvedBarColors }
        .onChange(of: levels) { newLevels in
            updateLiveDisplayAmounts(using: newLevels)
        }
        .onChange(of: mode) { newMode in
            if newMode == .live {
                liveDisplayAmounts = Array(repeating: 0.08, count: max(barCount, 1))
                previousLiveLevels = []
                updateLiveDisplayAmounts(using: levels)
            }
        }
        .accessibilityLabel(isPlaying ? "재생 중인 오디오 미터" : "일시 정지")
    }

    private func amount(at index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else {
            let restingPattern: [CGFloat] = [0.08, 0.13, 0.09, 0.16, 0.10, 0.14, 0.08, 0.12, 0.08]
            return restingPattern[index % restingPattern.count]
        }

        if mode == .live, !levels.isEmpty {
            guard liveDisplayAmounts.indices.contains(index) else {
                return liveTargetAmount(at: index, sourceLevels: levels)
            }
            return liveDisplayAmounts[index]
        }

        if mode == .live {
            return 0.08
        }

        return basicAmount(at: index, time: time)
    }

    private func liveTargetAmount(
        at index: Int,
        sourceLevels: [Double],
        previousLevels: [Double] = []
    ) -> CGFloat {
        guard !sourceLevels.isEmpty else { return 0.08 }
        let slot = index % 9
        let profile: [(Int, Double)]
        let overallWeight: Double

        // The nine bars deliberately use different frequency windows rather than
        // cloning four shared role values. Band indices span roughly 45 Hz–20 kHz.
        switch slot {
        case 0: // Sub bass + bass
            profile = [(0, 0.54), (1, 0.36), (2, 0.10)]
            overallWeight = 0
        case 1: // Vocal A: approximately 300–1,500 Hz
            profile = [(2, 0.18), (3, 0.36), (4, 0.34), (5, 0.12)]
            overallWeight = 0
        case 2: // High mids + treble
            profile = [(4, 0.12), (5, 0.30), (6, 0.32), (7, 0.19), (8, 0.07)]
            overallWeight = 0
        case 3: // Bass + the full mid range
            profile = [(1, 0.24), (2, 0.20), (3, 0.20), (4, 0.20), (5, 0.16)]
            overallWeight = 0
        case 4: // Bass + kick
            profile = [(0, 0.35), (1, 0.45), (2, 0.15), (3, 0.05)]
            overallWeight = 0
        case 5: // Vocal B: approximately 500–3,000 Hz + overall loudness
            profile = [(3, 0.18), (4, 0.26), (5, 0.24)]
            overallWeight = 0.32
        case 6: // Treble + high mids, biased higher than bar 3
            profile = [(5, 0.18), (6, 0.27), (7, 0.32), (8, 0.23)]
            overallWeight = 0
        case 7: // Mid + bass + overall loudness
            profile = [(1, 0.14), (2, 0.16), (3, 0.18), (4, 0.18), (5, 0.12)]
            overallWeight = 0.22
        default: // Vocal C: approximately 1,000–4,000 Hz
            profile = [(4, 0.18), (5, 0.40), (6, 0.42)]
            overallWeight = 0
        }

        let energy = weightedLevel(profile, in: sourceLevels)
            + overallLevel(in: sourceLevels) * overallWeight
        let previousEnergy = previousLevels.count == sourceLevels.count
            ? weightedLevel(profile, in: previousLevels)
                + overallLevel(in: previousLevels) * overallWeight
            : energy
        let spectrumPeak = max(sourceLevels.max() ?? 0, 0.08)
        let signalGate = min(max((spectrumPeak - 0.045) / 0.18, 0), 1)
        let relativeEnergy = min(max(energy / spectrumPeak, 0), 1)
        let signedChange = energy - previousEnergy

        // Expand both rises and falls from the real spectrum. Keeping the steady
        // component below the ceiling prevents loud, mastered tracks from pinning
        // bars at maximum height while small musical changes remain visible.
        let rise = min(max(signedChange, 0) * 3.2, 0.11) * signalGate
        let fall = min(max(-signedChange, 0) * 2.3, 0.08) * signalGate
        let absoluteEnergy = min(max((energy - 0.035) / 0.82, 0), 1)
        let steadyShape = relativeEnergy * signalGate
        let responsiveEnergy = 0.055
            + absoluteEnergy * 0.39
            + steadyShape * 0.18
            + rise
            - fall
        let shaped = pow(min(max(responsiveEnergy * Self.barGains[slot], 0.035), 0.92), 0.90)
        return min(Self.maximumHeights[slot], CGFloat(shaped))
    }

    private func weightedLevel(_ bands: [(Int, Double)], in sourceLevels: [Double]) -> Double {
        guard !sourceLevels.isEmpty else { return 0 }
        return bands.reduce(0) { partial, band in
            let index = min(max(band.0, 0), sourceLevels.count - 1)
            return partial + min(max(sourceLevels[index], 0), 1) * band.1
        }
    }

    private func overallLevel(in sourceLevels: [Double]) -> Double {
        guard !sourceLevels.isEmpty else { return 0 }
        let squaredMean = sourceLevels.reduce(0) { partial, value in
            let clamped = min(max(value, 0), 1)
            return partial + clamped * clamped
        } / Double(sourceLevels.count)
        return sqrt(squaredMean)
    }

    private func updateLiveDisplayAmounts(using sourceLevels: [Double]) {
        guard mode == .live, !sourceLevels.isEmpty else { return }
        var next = liveDisplayAmounts
        if next.count != barCount {
            next = Array(repeating: 0.08, count: max(barCount, 1))
        }

        for index in 0..<barCount {
            let slot = index % 9
            let target = liveTargetAmount(
                at: index,
                sourceLevels: sourceLevels,
                previousLevels: previousLiveLevels
            )
            let current = next[index]
            let response = target > current ? Self.attackRates[slot] : Self.releaseRates[slot]
            next[index] = current + (target - current) * response
        }
        liveDisplayAmounts = next
        previousLiveLevels = sourceLevels
    }

    private func basicAmount(at index: Int, time: TimeInterval) -> CGFloat {
        let slot = index % 9
        let role = Self.roleOrder[slot]
        let phase = Self.basicPhases[slot]
        let speed = [1.00, 0.94, 1.07, 1.12, 0.98, 1.08, 1.03, 0.91, 1.05][slot]
        let amount: Double

        switch role {
        case .vocal:
            let phrase = pow(abs(sin(time * 2.25 * speed + phase)), 1.35)
            let vibrato = (sin(time * 7.2 * speed + phase * 1.7) + 1) * 0.5
            let accent = pow(abs(sin(time * 4.3 - phase * 0.8)), 3.4)
            amount = 0.08 + phrase * 0.53 + vibrato * 0.14 + accent * 0.23
        case .high:
            let sparkle = pow(abs(sin(time * 5.8 * speed + 0.55 + phase)), 3.0)
            let shimmer = (sin(time * 9.5 * speed - phase * 1.4) + 1) * 0.5
            let flash = pow(abs(sin(time * 12.0 + phase * 0.6)), 5.2)
            amount = 0.06 + sparkle * 0.45 + shimmer * 0.17 + flash * 0.30
        case .low:
            let bassBeat = pow(abs(sin(time * 2.6 * speed + 1.1 + phase * 0.6)), 5.3)
            let body = pow(abs(sin(time * 1.2 - phase)), 1.5)
            let rebound = pow(abs(sin(time * 4.8 + phase)), 4.0)
            amount = 0.09 + bassBeat * 0.63 + body * 0.12 + rebound * 0.16
        case .accompaniment:
            let groove = pow(abs(sin(time * 3.8 * speed + 1.7 + phase)), 1.9)
            let syncopation = pow(abs(sin(time * 6.2 * speed - phase * 1.8)), 3.5)
            let detail = (sin(time * 8.5 + phase * 0.9) + 1) * 0.5
            amount = 0.07 + groove * 0.39 + syncopation * 0.36 + detail * 0.14
        }

        let maximum = Self.maximumHeights[slot]
        return 0.05 + min(CGFloat(amount), 1) * (maximum - 0.05)
    }

    private func barColor(at index: Int) -> Color {
        let colors = cachedBarColors
        guard !colors.isEmpty else { return .white }
        guard colors.count > 1, barCount > 1 else { return Color(nsColor: colors[0]) }

        let position = CGFloat(index) / CGFloat(barCount - 1)
        let scaled = position * CGFloat(colors.count - 1)
        let lowerIndex = min(Int(scaled.rounded(.down)), colors.count - 1)
        let upperIndex = min(lowerIndex + 1, colors.count - 1)
        let fraction = scaled - CGFloat(lowerIndex)
        let blended = colors[lowerIndex].blended(
            withFraction: fraction,
            of: colors[upperIndex]
        ) ?? colors[lowerIndex]
        return Color(nsColor: blended)
    }

    private var resolvedBarColors: [NSColor] {
        colors.map { ArtworkPalette.waveformColor($0) }
    }
}

private struct PlayerButtonStyle: ButtonStyle {
    var size: CGFloat
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.94))
            .frame(width: prominent ? 44 : 40, height: 40)
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
