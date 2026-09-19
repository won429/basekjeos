import AppKit
import Combine
import QuartzCore
import SwiftUI

enum NotchContentMode: Equatable {
    case compact
    case hidden
    case expanded
}

@MainActor
final class NotchLayoutModel: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var contentMode: NotchContentMode = .compact
    @Published private(set) var presentationStyle: PlayerPresentationStyle
    @Published private(set) var arrivalEmphasis: CGFloat = 0
    @Published var immersivePulse: CGFloat = 0
    @Published private(set) var immersiveActive = false

    func setImmersiveActive(_ active: Bool) { immersiveActive = active }
    @Published private(set) var expansionProgress: CGFloat = 0
    @Published private(set) var menuBarHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var compactWidth: CGFloat = 220
    @Published private(set) var compactMusicVisibility: CGFloat = 1
    @Published private(set) var compactPowerVisibility: CGFloat = 0
    @Published private(set) var compactPowerDisplayState: CompactDisplayState?
    @Published private(set) var usesSynchronizedPowerTransition = false
    @Published private(set) var expandedWidth: CGFloat = 360
    @Published private(set) var cameraHousingWidth: CGFloat = 0
    @Published private(set) var hasCameraHousing = false
    @Published private(set) var compactDisplayState: CompactDisplayState = .music
    @Published private(set) var lowBatteryReturnState: CompactDisplayState?
    private(set) var lowBatterySourceState: CompactDisplayState = .music
    private(set) var targetCompactWidth: CGFloat = 220

    private var isPlaybackActive = false
    private var musicCompactWidth: CGFloat = 220
    private var idleCompactWidth: CGFloat = 90
    private var volumeCompactWidth: CGFloat = 284
    private var chargingCompactWidth: CGFloat = 178
    private var airPodsCompactWidth: CGFloat = 190
    private var musicExpandedWidth: CGFloat = 360
    private var airPodsExpandedWidth: CGFloat = 272
    private var airPodsName = "AirPods"

    func setAirPodsName(_ name: String) { airPodsName = name }

    var compactPowerContentWidth: CGFloat { chargingCompactWidth }
    // A capsule is vertically symmetric: use its geometric center. The notch
    // retains its optical correction. Alert growth adds half its extra height.
    var compactContentOffsetY: CGFloat { (presentationStyle == .dynamicIsland ? 0 : 1) + arrivalEmphasis }
    var compactContentCenterY: CGFloat { compactHeight / 2 + compactContentOffsetY }
    var volumeScale: CGFloat { presentationStyle == .dynamicIsland ? compactHeight / 36 : 1 }
    // Keep readable controls independent of the sensor area's geometric scale.
    var compactAccessoryLeadingInset: CGFloat { presentationStyle == .dynamicIsland ? 9 * volumeScale : 13 }
    var compactAccessoryTrailingInset: CGFloat { presentationStyle == .dynamicIsland ? 9.5 * volumeScale : 12 }
    var alertLeadingInset: CGFloat { presentationStyle == .notch ? 26 : compactAccessoryLeadingInset }
    var alertTrailingInset: CGFloat { presentationStyle == .notch ? 26 : compactAccessoryTrailingInset }
    var volumeContentScale: CGFloat {
        presentationStyle == .dynamicIsland ? min(max(compactHeight / 26, 0.68), 1.18) : 1
    }
    var volumeProtectedCenterWidth: CGFloat {
        presentationStyle == .notch ? idleCompactWidth
            : NotchAlertSizing.protectedCenter(cameraWidth: max(cameraHousingWidth, 126 * volumeScale))
    }

    var compactHeight: CGFloat {
        switch presentationStyle {
        case .notch:
            return menuBarHeight
        case .dynamicIsland:
            // Preserve a two-point margin above and below on shorter menu bars,
            // while never exceeding the 36-point reference height.
            return min(36, max(1, menuBarHeight - 4))
        }
    }

    var expandedMusicTopPadding: CGFloat {
        presentationStyle == .notch
            ? (hasCameraHousing ? max(32, menuBarHeight + 12) : 32)
            : 22
    }

    var expandedHeight: CGFloat {
        if compactDisplayState == .lowBattery {
            return presentationStyle == .notch ? menuBarHeight + 100 : 84
        }
        guard compactDisplayState == .airPods else {
            return presentationStyle == .notch ? expandedMusicTopPadding + 188 : 180
        }
        return presentationStyle == .notch ? menuBarHeight + 72
            : max(compactHeight, min(72, max(60, compactHeight * 2.2)))
    }

    var topOffset: CGFloat {
        switch presentationStyle {
        case .notch:
            return 0
        case .dynamicIsland:
            return max(0, (menuBarHeight - compactHeight) / 2)
        }
    }

    var visualSize: NSSize {
        NSSize(
            width: compactWidth + (expandedWidth - compactWidth) * expansionProgress + arrivalEmphasis * 8,
            height: compactHeight + (expandedHeight - compactHeight) * expansionProgress + arrivalEmphasis * 2
        )
    }

    init(screen: NSScreen?, presentationStyle: PlayerPresentationStyle) {
        self.presentationStyle = presentationStyle
        if let screen {
            update(for: screen)
        }
    }

    var panelSize: NSSize {
        panelSize(expanded: isExpanded)
    }

    func panelSize(expanded: Bool) -> NSSize {
        if expanded {
            return NSSize(width: expandedWidth, height: expandedHeight)
        }
        return NSSize(width: compactWidth, height: compactHeight)
    }

    func setArrivalEmphasis(_ amount: CGFloat) { arrivalEmphasis = min(max(amount, 0), 1) }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    func setContentMode(_ mode: NotchContentMode) {
        contentMode = mode
    }

    func setExpansionProgress(_ progress: CGFloat) {
        expansionProgress = min(max(progress, 0), 1)
    }

    func setPresentationStyle(_ style: PlayerPresentationStyle) {
        presentationStyle = style
    }

    func setCompactDisplayState(_ state: CompactDisplayState) {
        if state == .lowBattery, compactDisplayState != .lowBattery {
            lowBatterySourceState = compactDisplayState
        }
        compactDisplayState = state
        targetCompactWidth = compactWidth(for: state)
        expandedWidth = expandedWidth(for: state)
    }

    func setLowBatteryReturnState(_ state: CompactDisplayState?) {
        lowBatteryReturnState = state
    }

    func setPlaybackActive(_ active: Bool) {
        isPlaybackActive = active
        targetCompactWidth = compactWidth(for: compactDisplayState)
    }

    func setCompactWidth(_ width: CGFloat) {
        compactWidth = width
    }

    func setCompactMusicVisibility(_ visibility: CGFloat) {
        compactMusicVisibility = min(max(visibility, 0), 1)
    }

    func setCompactPowerVisibility(_ visibility: CGFloat) {
        compactPowerVisibility = min(max(visibility, 0), 1)
    }

    func preparePowerTransition(to state: CompactDisplayState, synchronized: Bool) {
        usesSynchronizedPowerTransition = synchronized
        if state.isCompactHUD {
            compactPowerDisplayState = state
        } else if !synchronized {
            compactPowerDisplayState = nil
        }
        if !synchronized { setCompactPowerVisibility(state.isCompactHUD ? 1 : 0) }
    }

    func finishPowerTransition() {
        preparePowerTransition(to: compactDisplayState, synchronized: false)
    }

    func update(for screen: NSScreen, updateDisplayedWidth: Bool = true) {
        let visibleTopInset = screen.frame.maxY - screen.visibleFrame.maxY
        let detectedHeight = max(screen.safeAreaInsets.top, visibleTopInset)
        menuBarHeight = (20...80).contains(detectedHeight) ? detectedHeight : NSStatusBar.system.thickness

        var detectedCameraHousingWidth: CGFloat = 0
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            detectedCameraHousingWidth = max(0, rightArea.minX - leftArea.maxX)
        }

        cameraHousingWidth = detectedCameraHousingWidth
        hasCameraHousing = detectedCameraHousingWidth > 0
        musicExpandedWidth = presentationStyle == .notch
            ? min(420, max(1, screen.frame.width - 24))
            : min(360, max(330, screen.frame.width - 24))

        switch presentationStyle {
        case .notch:
            let sideAccessoryWidth = max(menuBarHeight + 8, 46)
            musicCompactWidth = hasCameraHousing
                ? min(max(detectedCameraHousingWidth + sideAccessoryWidth * 2, 220), 320)
                : 204
            // Preserve the established baseline; playback adds room on both sides.
            idleCompactWidth = musicCompactWidth
            musicCompactWidth = min(musicCompactWidth + 48, max(1, screen.frame.width - 24))
        case .dynamicIsland:
            // The reference leaves about 126 points for the camera/Face ID area,
            // with roughly 32-point accessory regions on either side. Scale the
            // full geometry down with the available menu-bar height.
            let referenceScale = compactHeight / 36
            let sensorAreaWidth = max(detectedCameraHousingWidth, 126 * referenceScale)
            let referenceWidth = 190 * referenceScale
            musicCompactWidth = min(
                max(sensorAreaWidth + 64 * referenceScale, referenceWidth),
                320
            )
            idleCompactWidth = min(musicCompactWidth, sensorAreaWidth)
        }
        chargingCompactWidth = min(max(musicCompactWidth, 178), musicExpandedWidth)
        airPodsCompactWidth = musicCompactWidth
        if presentationStyle == .notch {
            let alerts = NotchAlertSizing.widths(musicWidth: idleCompactWidth,
                                                cameraWidth: max(0, idleCompactWidth - 16),
                                                screenWidth: screen.frame.width)
            chargingCompactWidth = alerts.power
            airPodsCompactWidth = alerts.airPods
        }
        volumeCompactWidth = NotchAlertSizing.volumeWidth(
            musicWidth: musicCompactWidth, protectedCenter: volumeProtectedCenterWidth,
            scale: volumeContentScale, screenWidth: screen.frame.width
        )
        if presentationStyle == .dynamicIsland {
            let scale = min(max(compactHeight / 26, 0.68), 1.18)
            chargingCompactWidth = min(screen.frame.width - 24, max(chargingCompactWidth,
                volumeProtectedCenterWidth + 2 * 84 * scale))
        }
        airPodsExpandedWidth = max(airPodsCompactWidth, min(
            musicExpandedWidth,
            max(airPodsCompactWidth, presentationStyle == .notch ? 320 : 272)
        ))
        let nameWidth = ceil((airPodsName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]).width)
        let namedWidth = presentationStyle == .notch ? nameWidth + 196 : (nameWidth + 78) / 0.75
        airPodsExpandedWidth = min(screen.frame.width - 24, max(airPodsExpandedWidth, namedWidth))
        expandedWidth = expandedWidth(for: compactDisplayState)
        targetCompactWidth = compactWidth(for: compactDisplayState)
        if updateDisplayedWidth {
            compactWidth = targetCompactWidth
        }
    }

    private func compactWidth(for state: CompactDisplayState) -> CGFloat {
        switch state {
        case .music:
            return presentationStyle == .notch && !isPlaybackActive ? idleCompactWidth : musicCompactWidth
        case .lowBattery:
            if let destination = lowBatteryReturnState, destination != .lowBattery {
                return compactWidth(for: destination)
            }
            return presentationStyle == .notch ? idleCompactWidth : musicCompactWidth
        case .idle:
            return idleCompactWidth
        case .volume, .brightness:
            return volumeCompactWidth
        case .charging, .disconnected, .batteryLevel:
            return chargingCompactWidth
        case .airPods:
            return airPodsCompactWidth
        }
    }

    private func expandedWidth(for state: CompactDisplayState) -> CGFloat {
        if state == .lowBattery { return musicExpandedWidth }
        if state == .airPods { return airPodsExpandedWidth }
        if state.isPowerStatus { return max(chargingCompactWidth, musicExpandedWidth) }
        return musicExpandedWidth
    }
}

@MainActor
final class NotchPanelController: NSObject {
    private struct AnimationSample: Codable {
        let progress: Double
        let width: Double
        let height: Double
        let topError: Double
    }

    private struct FrameAnimationState {
        let startProgress: CGFloat
        let arrivalStart: CGFloat
        let emphasizesArrival: Bool
        let targetProgress: CGFloat
        let finalFrame: NSRect
        let startTime: TimeInterval
        let duration: TimeInterval
        let expanded: Bool
        let usesPlayerMorph: Bool
        let generation: Int
    }

    private struct CompactAnimationState {
        let startWidth: CGFloat
        let arrivalStart: CGFloat
        let emphasizesArrival: Bool
        let targetWidth: CGFloat
        let startMusicVisibility: CGFloat
        let targetMusicVisibility: CGFloat
        let usesSmoothMotion: Bool
        let synchronizesPower: Bool
        let synchronizesVolume: Bool
        let startPowerVisibility: CGFloat
        let targetPowerVisibility: CGFloat
        let finalFrame: NSRect
        let startTime: TimeInterval
        let duration: TimeInterval
        let generation: Int
    }

    private struct MenuBarAvoidanceAnimationState {
        let startOffset: CGFloat
        let targetOffset: CGFloat
        let startTime: TimeInterval
        let duration: TimeInterval
        let generation: Int
    }

    private let panel: NSPanel
    private let layout: NotchLayoutModel
    private weak var mediaClient: MediaRemoteClient?
    private var hostingView: NSHostingView<NotchPlayerSurface>?
    private let immersivePlayer = ImmersivePlayerController()
    private var immersivePulseTask: Task<Void, Never>?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var compactDisplayCancellable: AnyCancellable?
    private var pendingCompactState: DispatchWorkItem?
    private var pendingArrivalEmphasis = false
    private var targetExpanded = false
    private var transitionGeneration = 0
    private var frameAnimationTimer: Timer?
    private var frameDisplayLink: AnyObject?
    private var frameAnimationState: FrameAnimationState?
    private var compactAnimationTimer: Timer?
    private var compactDisplayLink: AnyObject?
    private var compactAnimationState: CompactAnimationState?
    private var compactAnimationGeneration = 0
    private var menuBarAvoidanceTimer: Timer?
    private var menuBarAvoidanceDisplayLink: AnyObject?
    private var menuBarAvoidanceAnimationState: MenuBarAvoidanceAnimationState?
    private var menuBarAvoidanceGeneration = 0
    private var menuBarAvoidanceOffset: CGFloat = 0
    private var isAvoidingMenuBar = false
    private var debugSnapshotDirectory: URL?
    private var debugExpansionSamples: [AnimationSample] = []
    private var debugCapturedMidExpansion = false
    private var debugCapturedCompactMorph = false

    var reservedMenuBarFrame: NSRect? {
        guard panel.isVisible else { return nil }
        let size = layout.visualSize
        return NSRect(
            x: panel.frame.midX - size.width / 2,
            y: panel.frame.maxY - layout.menuBarHeight,
            width: size.width,
            height: layout.menuBarHeight
        )
    }

    init(mediaClient: MediaRemoteClient, presentationStyle: PlayerPresentationStyle) {
        self.mediaClient = mediaClient
        let layout = NotchLayoutModel(
            screen: NSScreen.main ?? NSScreen.screens.first,
            presentationStyle: presentationStyle
        )
        self.layout = layout
        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        let hostingView = NSHostingView(
            rootView: NotchPlayerSurface(
                mediaClient: mediaClient,
                layout: layout,
                onExpansionChanged: { [weak self] expanded in
                    self?.setExpanded(expanded)
                },
                onArtworkSelected: { [weak self] in
                    self?.showImmersivePlayer()
                }
            )
        )
        hostingView.sizingOptions = []
        hostingView.focusRingType = .none
        hostingView.frame = NSRect(origin: .zero, size: layout.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = PlayerHostingContainer(hostedView: hostingView)
        self.hostingView = hostingView
        installOutsideClickMonitors()
        immersivePlayer.onTransition = { [weak self] opening in
            guard let self else { return }
            self.layout.setImmersiveActive(opening)
            self.layout.setPlaybackActive(self.mediaClient?.isPlaying ?? false)
            self.applyCompactDisplayState(opening ? .idle : (self.mediaClient?.compactDisplayState ?? .idle))
            self.applyExpanded(false, animated: false)
            self.updateWaveformPresentation()
            self.pulseForImmersiveTransition(opening: opening)
        }

        layout.setAirPodsName(mediaClient.airPodsName)
        layout.setPlaybackActive(mediaClient.isPlaying)
        compactDisplayCancellable = mediaClient.$compactDisplayState
            .combineLatest(mediaClient.$isPlaying)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .sink { [weak self] state, playing in
                guard let self, !self.layout.immersiveActive else { return }
                self.layout.setPlaybackActive(playing)
                // A playback toggle does not change expanded geometry. In
                // particular, do not force layout from a Published willSet sink.
                if self.targetExpanded && state == self.layout.compactDisplayState { return }
                guard state == .music || state != self.layout.compactDisplayState else { return }
                self.applyCompactDisplayState(state)
            }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
    }

    private func installOutsideClickMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self?.dismissExpandedPlayerIfOutside(point)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissExpandedPlayerIfOutside(point) }
        }
    }

    // Screen coordinates, using the visible shape rather than the animation's
    // larger transparent window. The original click still reaches its target.
    func dismissExpandedPlayerIfOutside(_ point: NSPoint) {
        guard targetExpanded, panel.isVisible else { return }
        let size = layout.visualSize
        let local = CGPoint(x: point.x - (panel.frame.midX - size.width / 2),
                            y: panel.frame.maxY - point.y)
        let shape = PlayerSurfaceShape(style: layout.presentationStyle,
            expansionProgress: layout.expansionProgress, compactHeight: layout.compactHeight,
            expandedCornerRadius: layout.compactDisplayState == .airPods || layout.compactDisplayState == .lowBattery
                ? layout.expandedHeight / 2 : 28)
        guard !shape.path(in: CGRect(origin: .zero, size: size)).contains(local) else { return }
        mediaClient?.setAirPodsDetailsVisible(false)
        setExpanded(false)
    }

    func show(expanded: Bool = false) {
        applyExpanded(expanded, animated: false)
        panel.orderFrontRegardless()
        updateWaveformPresentation()
    }

    func setExpanded(_ expanded: Bool) {
        immersivePulseTask?.cancel()
        immersivePulseTask = nil
        layout.immersivePulse = 0
        hostingView?.autoresizingMask = [.width, .height]
        applyExpanded(expanded, animated: true)
    }

    private func pulseForImmersiveTransition(opening: Bool) {
        immersivePulseTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        immersivePulseTask = Task { @MainActor [weak self] in
            // Start in the same run-loop turn as the immersive presentation.
            guard let self, !Task.isCancelled else { return }
            self.applyExpanded(false, animated: false)
            guard let screen = self.screenForPanel() else { return }
            let compact = self.layout.visualSize
            let container = NSSize(width: ceil(compact.width * 1.24 / 2) * 2,
                                   height: ceil(compact.height * 1.24))
            // Reserve overscan once; the pulse changes only a scale transform.
            self.stopMenuBarAvoidanceAnimation()
            // Keep the hosting view's layout size unchanged. Resizing it together
            // with the window lets SwiftUI animate its alignment during the pulse.
            self.hostingView?.autoresizingMask = []
            self.panel.setFrame(self.frame(for: container, on: screen.frame), display: false)
            let contentBounds = self.panel.contentView?.bounds ?? NSRect(origin: .zero, size: container)
            self.hostingView?.frame = NSRect(
                x: contentBounds.midX - compact.width / 2,
                y: contentBounds.maxY - compact.height,
                width: compact.width, height: compact.height)
            self.panel.contentView?.layoutSubtreeIfNeeded()
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)) {
                self.layout.immersivePulse = 1
            }
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                self.layout.immersivePulse = 0
            }
            do { try await Task.sleep(nanoseconds: 460_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self.panel.setFrame(self.frame(for: self.layout.visualSize, on: screen.frame), display: false)
            self.hostingView?.frame = NSRect(origin: .zero, size: self.layout.visualSize)
            self.hostingView?.autoresizingMask = [.width, .height]
            self.immersivePulseTask = nil
        }
    }

    func showImmersivePlayer() {
        guard layout.isExpanded, layout.expansionProgress > 0.90,
              layout.compactDisplayState != .airPods, layout.compactDisplayState != .lowBattery,
              let client = mediaClient, client.isYouTubeMusicSource,
              let screen = screenForPanel() else { return }
        let centerX: CGFloat = layout.presentationStyle == .notch ? 72 : 50
        let source = NSRect(x: panel.frame.midX - layout.visualSize.width / 2 + centerX - 30,
                            y: panel.frame.maxY - layout.expandedMusicTopPadding - 60,
                            width: 60, height: 60)
        let surface = NSRect(x: panel.frame.midX - layout.compactWidth / 2,
                             y: panel.frame.maxY - layout.compactHeight,
                             width: layout.compactWidth, height: layout.compactHeight)
        immersivePlayer.show(client: client, screen: screen, sourceArtworkFrame: source, sourceSurfaceFrame: surface)
        // Keep only the resting surface above the immersive panel.
        applyExpanded(false, animated: false)
        panel.orderFrontRegardless()
    }

    func setPresentationStyle(_ style: PlayerPresentationStyle) {
        guard layout.presentationStyle != style else { return }
        immersivePlayer.close(animated: false)
        immersivePulseTask?.cancel()
        immersivePulseTask = nil
        layout.immersivePulse = 0
        hostingView?.autoresizingMask = [.width, .height]
        stopFrameAnimation()
        stopCompactAnimation()
        layout.setPresentationStyle(style)
        if let screen = screenForPanel() {
            layout.update(for: screen)
        }
        applyExpanded(false, animated: false)
    }

    func setMenuBarAvoidanceActive(_ active: Bool) {
        guard immersivePulseTask == nil, isAvoidingMenuBar != active else { return }
        isAvoidingMenuBar = active
        animateMenuBarAvoidance(to: active ? menuBarDropOffset : 0)
    }

    private func applyExpanded(_ expanded: Bool, animated: Bool) {
        let expanded = expanded && !layout.immersiveActive
        stopFrameAnimation()
        stopCompactAnimation()
        layout.setCompactMusicVisibility(layout.compactDisplayState == .music ? 1 : 0)
        layout.finishPowerTransition()
        transitionGeneration += 1
        let generation = transitionGeneration
        targetExpanded = expanded
        updateWaveformPresentation()

        let screen = screenForPanel()
        if let screen {
            // Start the warning from the currently visible compact width.
            // On dismissal, head directly to the destination's compact width.
            let enteringWarning = expanded && layout.compactDisplayState == .lowBattery
                && layout.expansionProgress < 0.001
            layout.update(for: screen, updateDisplayedWidth: !enteringWarning)
        }

        let screenFrame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        let compactSize = layout.panelSize(expanded: false)
        let expandedSize = layout.panelSize(expanded: true)
        let compactFrame = frame(for: compactSize, on: screenFrame)
        let expandedFrame = frame(for: expandedSize, on: screenFrame)
        let finalFrame = expanded ? expandedFrame : compactFrame
        let expectedContentMode: NotchContentMode = expanded ? .expanded : .compact

        if animated, !pendingArrivalEmphasis, layout.arrivalEmphasis == 0,
           layout.isExpanded == expanded,
           layout.contentMode == expectedContentMode,
           abs(panel.frame.height - finalFrame.height) < 0.1,
           abs(panel.frame.width - finalFrame.width) < 0.1,
           abs(layout.expansionProgress - (expanded ? 1 : 0)) < 0.001 {
            return
        }

        guard animated, panel.isVisible else {
            pendingArrivalEmphasis = false
            layout.setArrivalEmphasis(0)
            layout.setExpanded(expanded)
            layout.setExpansionProgress(expanded ? 1 : 0)
            layout.setContentMode(expanded ? .expanded : .compact)
            panel.setFrame(finalFrame, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: finalFrame.size)
            refreshHostedContent()
            return
        }

        // The panel takes its final bounding rect once. During the transition only
        // the clipped surface changes, avoiding separate AppKit width/height passes.
        let arrivalPadding: CGFloat = pendingArrivalEmphasis || layout.arrivalEmphasis > 0 ? 1 : 0
        let containerSize = NSSize(width: expandedSize.width + 8 * arrivalPadding,
                                   height: expandedSize.height + 2 * arrivalPadding)
        panel.setFrame(frame(for: containerSize, on: screenFrame), display: false, animate: false)
        hostingView?.frame = NSRect(origin: .zero, size: containerSize)
        layout.setExpanded(expanded)
        layout.setContentMode(expanded ? .expanded : .compact)
        refreshHostedContent()
        animatePanel(
            finalFrame: finalFrame,
            expanded: expanded,
            generation: generation
        )
    }

    private func applyCompactDisplayState(_ state: CompactDisplayState) {
        let state: CompactDisplayState = layout.immersiveActive ? .idle : state
        layout.setAirPodsName(mediaClient?.airPodsName ?? "AirPods")
        pendingCompactState?.cancel()
        pendingCompactState = nil
        pendingArrivalEmphasis = state.isNotification && state != layout.compactDisplayState
        // Fold the warning straight into the actual next state. No intermediate
        // music-width capsule or delayed second width animation.
        if layout.compactDisplayState == .lowBattery, state != .lowBattery,
           layout.expansionProgress > 0.001 {
            layout.setLowBatteryReturnState(state)
            applyExpanded(false, animated: true)
            return
        }
        layout.setLowBatteryReturnState(nil)
        compactAnimationGeneration += 1
        let generation = compactAnimationGeneration
        let startWidth = layout.compactWidth
        let previousState = layout.compactDisplayState
        let emphasizesArrival = state.isNotification && state != previousState
        pendingArrivalEmphasis = emphasizesArrival
        let smoothPlaybackMotion = (previousState == .music || previousState == .idle)
            && (state == .music || state == .idle)
        let supportsPowerMorph = (state.isCompactHUD || state == .music || state == .idle)
            && (previousState.isCompactHUD || previousState == .music || previousState == .idle)
        let involvesVolume = previousState.isAdjustmentHUD || state.isAdjustmentHUD
        let smoothPowerMotion = (layout.presentationStyle == .dynamicIsland || involvesVolume) && supportsPowerMorph
            && (previousState.isCompactHUD || state.isCompactHUD
                || layout.usesSynchronizedPowerTransition)
        let targetPowerVisibility: CGFloat = state.isCompactHUD ? 1 : 0
        let startPowerVisibility = layout.compactPowerVisibility
        let targetMusicVisibility: CGFloat = state == .music ? 1 : 0
        let startMusicVisibility = smoothPlaybackMotion || smoothPowerMotion
            ? layout.compactMusicVisibility : targetMusicVisibility
        let wasShowingAirPods = layout.compactDisplayState == .airPods
        layout.setCompactDisplayState(state)
        updateWaveformPresentation()
        layout.setCompactMusicVisibility(startMusicVisibility)
        layout.preparePowerTransition(to: state, synchronized: smoothPowerMotion)

        if state == .lowBattery {
            applyExpanded(true, animated: true)
            return
        }
        if targetExpanded && (state == .airPods || state.isAdjustmentHUD || wasShowingAirPods) {
            applyExpanded(false, animated: true)
            return
        }
        if targetExpanded, pendingArrivalEmphasis {
            applyExpanded(true, animated: true)
            return
        }
        guard let screen = screenForPanel() else {
            pendingArrivalEmphasis = false
            layout.setArrivalEmphasis(0)
            layout.setCompactWidth(layout.targetCompactWidth)
            layout.setCompactMusicVisibility(targetMusicVisibility)
            layout.finishPowerTransition()
            refreshHostedContent()
            return
        }
        layout.update(for: screen, updateDisplayedWidth: false)
        let targetWidth = layout.targetCompactWidth

        guard panel.isVisible, !targetExpanded, layout.expansionProgress < 0.001 else {
            pendingArrivalEmphasis = false
            layout.setArrivalEmphasis(0)
            layout.setCompactWidth(targetWidth)
            layout.setCompactMusicVisibility(targetMusicVisibility)
            layout.finishPowerTransition()
            refreshHostedContent()
            return
        }

        stopCompactAnimation()
        guard abs(startWidth - targetWidth) > 0.1
            || abs(startMusicVisibility - targetMusicVisibility) > 0.001
            || (smoothPowerMotion && abs(startPowerVisibility - targetPowerVisibility) > 0.001)
            || emphasizesArrival || layout.arrivalEmphasis > 0 else {
            layout.setCompactWidth(targetWidth)
            layout.setCompactMusicVisibility(targetMusicVisibility)
            layout.finishPowerTransition()
            refreshHostedContent()
            return
        }

        let finalSize = NSSize(width: targetWidth, height: layout.compactHeight)
        let finalFrame = frame(for: finalSize, on: screen.frame)
        let overshootAllowance: CGFloat = emphasizesArrival || layout.arrivalEmphasis > 0 ? 8
            : smoothPlaybackMotion || smoothPowerMotion ? 0 : abs(targetWidth - startWidth) * 0.08 + 2
        let containerSize = NSSize(
            width: max(startWidth, targetWidth) + overshootAllowance,
            height: layout.compactHeight + (emphasizesArrival || layout.arrivalEmphasis > 0 ? 2 : 0)
        )
        let containerFrame = frame(for: containerSize, on: screen.frame)

        panel.setFrame(containerFrame, display: false, animate: false)
        hostingView?.frame = NSRect(origin: .zero, size: containerSize)
        layout.setCompactWidth(startWidth)
        compactAnimationState = CompactAnimationState(
            startWidth: startWidth,
            arrivalStart: layout.arrivalEmphasis,
            emphasizesArrival: emphasizesArrival,
            targetWidth: targetWidth,
            startMusicVisibility: startMusicVisibility,
            targetMusicVisibility: targetMusicVisibility,
            usesSmoothMotion: smoothPlaybackMotion || smoothPowerMotion || emphasizesArrival,
            synchronizesPower: smoothPowerMotion,
            synchronizesVolume: involvesVolume,
            startPowerVisibility: startPowerVisibility,
            targetPowerVisibility: targetPowerVisibility,
            finalFrame: finalFrame,
            startTime: ProcessInfo.processInfo.systemUptime,
            duration: targetWidth > startWidth ? 0.46 : 0.42,
            generation: generation
        )
        pendingArrivalEmphasis = false
        debugCapturedCompactMorph = false

        if #available(macOS 14.0, *) {
            let displayLink = panel.displayLink(
                target: self,
                selector: #selector(compactAnimationDisplayLinkTick(_:))
            )
            compactDisplayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(compactAnimationTimerTick(_:)),
                userInfo: nil,
                repeats: true
            )
            compactAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceCompactAnimation()
    }

    @available(macOS 14.0, *)
    @objc private func compactAnimationDisplayLinkTick(_ displayLink: CADisplayLink) {
        advanceCompactAnimation()
    }

    @objc private func compactAnimationTimerTick(_ timer: Timer) {
        advanceCompactAnimation()
    }

    private func advanceCompactAnimation() {
        guard let state = compactAnimationState,
              state.generation == compactAnimationGeneration else {
            stopCompactAnimation()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - state.startTime
        let linearProgress = min(max(elapsed / state.duration, 0), 1)
        // Playback starts and settles at rest, without the alert-style rebound.
        // Width and accessory reveal share this display-link sample.
        updateArrivalEmphasis(progress: linearProgress, start: state.arrivalStart, active: state.emphasizesArrival)
        let morphProgress = state.usesSmoothMotion
            ? smoothProgress(linearProgress) : rubberProgress(linearProgress)
        let width = interpolate(state.startWidth, state.targetWidth, morphProgress)
        layout.setCompactWidth(max(width, 1))
        if state.synchronizesPower {
            // Volume content follows the width from the first frame, with no
            // empty black interval between outgoing and incoming accessories.
            let fadeOut = state.synchronizesVolume ? morphProgress : smoothProgress(linearProgress / 0.30)
            let fadeIn = state.synchronizesVolume ? morphProgress : smoothProgress((linearProgress - 0.28) / 0.52)
            let powerFadeIn = state.synchronizesVolume ? morphProgress : smoothProgress((linearProgress - 0.62) / 0.34)
            layout.setCompactMusicVisibility(interpolate(
                state.startMusicVisibility, state.targetMusicVisibility,
                state.targetMusicVisibility > state.startMusicVisibility ? fadeIn : fadeOut
            ))
            layout.setCompactPowerVisibility(interpolate(
                state.startPowerVisibility, state.targetPowerVisibility,
                state.targetPowerVisibility > state.startPowerVisibility ? powerFadeIn : fadeOut
            ))
        } else {
            layout.setCompactMusicVisibility(interpolate(
                state.startMusicVisibility, state.targetMusicVisibility, morphProgress
            ))
        }
        refreshHostedContent()

        if !debugCapturedCompactMorph,
           linearProgress >= 0.5,
           let directory = debugSnapshotDirectory {
            debugCapturedCompactMorph = true
            captureSnapshot(named: "compact-morphing.png", in: directory)
        }

        if linearProgress >= 1 {
            stopCompactAnimation()
            layout.setCompactWidth(state.targetWidth)
            layout.setCompactMusicVisibility(state.targetMusicVisibility)
            layout.finishPowerTransition()
            panel.setFrame(state.finalFrame, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: state.finalFrame.size)
            refreshHostedContent()
        }
    }

    private func animatePanel(
        finalFrame: NSRect,
        expanded: Bool,
        generation: Int
    ) {
        let usesPlayerMorph = layout.compactDisplayState != .airPods && layout.compactDisplayState != .lowBattery
        let state = FrameAnimationState(
            startProgress: layout.expansionProgress,
            arrivalStart: layout.arrivalEmphasis,
            emphasizesArrival: pendingArrivalEmphasis,
            targetProgress: expanded ? 1 : 0,
            finalFrame: finalFrame,
            startTime: ProcessInfo.processInfo.systemUptime,
            duration: expanded ? 0.56 : 0.42,
            expanded: expanded,
            usesPlayerMorph: usesPlayerMorph,
            generation: generation
        )
        pendingArrivalEmphasis = false
        frameAnimationState = state
        if expanded {
            debugExpansionSamples.removeAll(keepingCapacity: true)
            debugCapturedMidExpansion = false
        }

        if #available(macOS 14.0, *) {
            let displayLink = panel.displayLink(
                target: self,
                selector: #selector(frameAnimationDisplayLinkTick(_:))
            )
            frameDisplayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(frameAnimationTimerTick(_:)),
                userInfo: nil,
                repeats: true
            )
            frameAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceFrameAnimation()
    }

    @available(macOS 14.0, *)
    @objc private func frameAnimationDisplayLinkTick(_ displayLink: CADisplayLink) {
        advanceFrameAnimation()
    }

    @objc private func frameAnimationTimerTick(_ timer: Timer) {
        advanceFrameAnimation()
    }

    private func advanceFrameAnimation() {
        guard let state = frameAnimationState,
              transitionGeneration == state.generation,
              targetExpanded == state.expanded else {
            stopFrameAnimation()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - state.startTime
        let linearProgress = min(max(elapsed / state.duration, 0), 1)
        updateArrivalEmphasis(progress: linearProgress, start: state.arrivalStart, active: state.emphasizesArrival)
        // Zero velocity and acceleration at both ends avoids a hard launch/stop.
        let t = linearProgress
        let easedProgress = CGFloat(t * t * t * (10 + t * (-15 + 6 * t)))
        let progress = interpolate(
            state.startProgress,
            state.targetProgress,
            easedProgress
        )
        layout.setExpansionProgress(progress)
        // Let SwiftUI and the display link coalesce layout/drawing for this frame.
        hostingView?.needsLayout = true
        hostingView?.needsDisplay = true

        if state.expanded, debugSnapshotDirectory != nil {
            let visualSize = layout.visualSize
            debugExpansionSamples.append(
                AnimationSample(
                    progress: linearProgress,
                    width: Double(visualSize.width),
                    height: Double(visualSize.height),
                    topError: Double(panel.frame.maxY - state.finalFrame.maxY)
                )
            )
            if !debugCapturedMidExpansion,
               progress >= 0.5,
               let directory = debugSnapshotDirectory {
                debugCapturedMidExpansion = true
                captureSnapshot(named: "expanding.png", in: directory)
            }
        }

        if linearProgress >= 1 {
            stopFrameAnimation()
            layout.setExpansionProgress(state.targetProgress)
            panel.setFrame(state.finalFrame, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: state.finalFrame.size)
            if state.expanded {
                writeDebugAnimationSamples()
            }
            finishTransition(
                expanded: state.expanded,
                generation: state.generation
            )
        }
    }

    private func frame(for size: NSSize, on screenFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - layout.topOffset - size.height - menuBarAvoidanceOffset,
            width: size.width,
            height: size.height
        )
    }

    private var menuBarDropOffset: CGFloat {
        // Keep the island just below the menu bar rather than letting it overlap
        // the first row of app content.
        max(0, layout.menuBarHeight + 3 - layout.topOffset)
    }

    private func animateMenuBarAvoidance(to targetOffset: CGFloat) {
        stopMenuBarAvoidanceAnimation()
        menuBarAvoidanceGeneration += 1
        let generation = menuBarAvoidanceGeneration
        guard panel.isVisible, abs(menuBarAvoidanceOffset - targetOffset) > 0.1 else {
            menuBarAvoidanceOffset = targetOffset
            repositionPanelForCurrentState()
            return
        }

        menuBarAvoidanceAnimationState = MenuBarAvoidanceAnimationState(
            startOffset: menuBarAvoidanceOffset,
            targetOffset: targetOffset,
            startTime: ProcessInfo.processInfo.systemUptime,
            duration: targetOffset > menuBarAvoidanceOffset ? 0.34 : 0.38,
            generation: generation
        )

        if #available(macOS 14.0, *) {
            let displayLink = panel.displayLink(
                target: self,
                selector: #selector(menuBarAvoidanceDisplayLinkTick(_:))
            )
            menuBarAvoidanceDisplayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(menuBarAvoidanceTimerTick(_:)),
                userInfo: nil,
                repeats: true
            )
            menuBarAvoidanceTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceMenuBarAvoidanceAnimation()
    }

    @available(macOS 14.0, *)
    @objc private func menuBarAvoidanceDisplayLinkTick(_ displayLink: CADisplayLink) {
        advanceMenuBarAvoidanceAnimation()
    }

    @objc private func menuBarAvoidanceTimerTick(_ timer: Timer) {
        advanceMenuBarAvoidanceAnimation()
    }

    private func advanceMenuBarAvoidanceAnimation() {
        guard let state = menuBarAvoidanceAnimationState,
              state.generation == menuBarAvoidanceGeneration else {
            stopMenuBarAvoidanceAnimation()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - state.startTime
        let linearProgress = min(max(elapsed / state.duration, 0), 1)
        let easedProgress = smoothProgress(linearProgress)
        menuBarAvoidanceOffset = interpolate(
            state.startOffset,
            state.targetOffset,
            easedProgress
        )
        repositionPanelForCurrentState()

        if linearProgress >= 1 {
            stopMenuBarAvoidanceAnimation()
            menuBarAvoidanceOffset = state.targetOffset
            repositionPanelForCurrentState()
        }
    }

    private func repositionPanelForCurrentState() {
        guard let screen = screenForPanel() else { return }
        var frame = panel.frame
        frame.origin.y = screen.frame.maxY
            - layout.topOffset
            - frame.height
            - menuBarAvoidanceOffset
        panel.setFrame(frame, display: true, animate: false)
    }

    private func updateArrivalEmphasis(progress: Double, start: CGFloat, active: Bool) {
        let t = min(max(progress, 0), 1)
        let pulse = active ? pow(sin(.pi * t), 2) : 0
        layout.setArrivalEmphasis(t >= 1 ? 0 : start * (1 - smoothProgress(t)) + CGFloat(pulse))
    }

    private func smoothProgress(_ value: Double) -> CGFloat {
        let t = min(max(value, 0), 1)
        return CGFloat(t * t * (3 - 2 * t))
    }

    private func rubberProgress(_ value: Double) -> CGFloat {
        let t = min(max(value, 0), 1)
        guard t < 1 else { return 1 }
        let overshoot = 1.12
        let shifted = t - 1
        return CGFloat(1 + (overshoot + 1) * shifted * shifted * shifted + overshoot * shifted * shifted)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func stopFrameAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        if #available(macOS 14.0, *),
           let displayLink = frameDisplayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        frameDisplayLink = nil
        frameAnimationState = nil
    }

    private func stopCompactAnimation() {
        compactAnimationTimer?.invalidate()
        compactAnimationTimer = nil
        if #available(macOS 14.0, *),
           let displayLink = compactDisplayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        compactDisplayLink = nil
        compactAnimationState = nil
    }

    private func stopMenuBarAvoidanceAnimation() {
        menuBarAvoidanceTimer?.invalidate()
        menuBarAvoidanceTimer = nil
        if #available(macOS 14.0, *),
           let displayLink = menuBarAvoidanceDisplayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        menuBarAvoidanceDisplayLink = nil
        menuBarAvoidanceAnimationState = nil
    }

    private func finishTransition(expanded: Bool, generation: Int) {
        guard transitionGeneration == generation,
              targetExpanded == expanded else { return }

        layout.setExpanded(expanded)
        if !expanded, let destination = layout.lowBatteryReturnState {
            layout.setLowBatteryReturnState(nil)
            layout.setCompactDisplayState(destination)
            layout.setCompactMusicVisibility(destination == .music ? 1 : 0)
            layout.finishPowerTransition()
        }
        updateWaveformPresentation()
        refreshHostedContent()

        let expectedMode: NotchContentMode = expanded ? .expanded : .compact
        if layout.contentMode != expectedMode {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                layout.setContentMode(expectedMode)
            }
        }
    }

    private func refreshHostedContent() {
        hostingView?.needsLayout = true
        hostingView?.layoutSubtreeIfNeeded()
        hostingView?.needsDisplay = true
        hostingView?.displayIfNeeded()
    }

    private func updateWaveformPresentation() {
        guard !layout.immersiveActive, panel.isVisible, layout.compactDisplayState == .music else {
            mediaClient?.setWaveformPresentation(.hidden)
            return
        }
        mediaClient?.setWaveformPresentation(targetExpanded ? .expanded : .compact)
    }

    private func screenForPanel() -> NSScreen? {
        if panel.isVisible, let screen = panel.screen {
            return screen
        }
        return NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
    }

    @objc private func screenConfigurationChanged() {
        immersivePlayer.close(animated: false)
        stopMenuBarAvoidanceAnimation()
        menuBarAvoidanceOffset = isAvoidingMenuBar ? menuBarDropOffset : 0
        stopCompactAnimation()
        applyExpanded(targetExpanded, animated: false)
    }

    func captureDebugSnapshots(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        debugSnapshotDirectory = directory
        applyExpanded(false, animated: false)

        if ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_COMPACT_ONLY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.captureSnapshot(named: "compact.png", in: directory)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.captureSnapshot(named: "compact.png", in: directory)
            self?.setExpanded(true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                self?.captureSnapshot(named: "expanded.png", in: directory)
                if ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_KEEP_EXPANDED"] == "1" { return }
                self?.setExpanded(false)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                    self?.captureSnapshot(named: "collapsing.png", in: directory)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) { [weak self] in
                    self?.captureSnapshot(named: "compact-again.png", in: directory)
                }
            }
        }
    }

    private func writeDebugAnimationSamples() {
        guard let directory = debugSnapshotDirectory,
              let data = try? JSONEncoder().encode(debugExpansionSamples) else { return }
        try? data.write(
            to: directory.appendingPathComponent("expansion-frames.json"),
            options: .atomic
        )
    }

    private func captureSnapshot(named name: String, in directory: URL) {
        guard let view = panel.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }

        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
