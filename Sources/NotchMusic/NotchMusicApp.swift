import AppKit
import ApplicationServices
import Combine
import SwiftUI

@main
struct NotchMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            NookSettingsView(delegate: appDelegate)
        }
    }
}

@MainActor
private struct NookSettingsView: View {
    let delegate: AppDelegate
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nook")
                        .font(.title2.bold())
                    Text("버전 \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("상태") {
                VStack(spacing: 10) {
                    settingsRow(
                        title: "볼륨·밝기 키 제어",
                        value: AXIsProcessTrusted() ? "연결됨" : "손쉬운 사용 권한 필요",
                        symbol: AXIsProcessTrusted() ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    Divider()
                    settingsRow(
                        title: "실제 파형",
                        value: delegate.audioCaptureStatusTitle,
                        symbol: "waveform"
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("빠른 작업") {
                HStack {
                    Button("플레이어 보기") { delegate.showPlayer() }
                    Button("YouTube Music 열기") { delegate.openYouTubeMusic() }
                    Spacer()
                    Button("손쉬운 사용 권한") { delegate.openAccessibilityPermission() }
                    Button("오디오 녹음 권한") { delegate.openAudioCapturePermission() }
                }
                .padding(.vertical, 4)
            }

            Text("표시 형태, 파형, 배경, 가사, 언어와 배터리 알림은 메뉴 막대의 Nook 아이콘에서 변경할 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
    }

    private func settingsRow(title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let presentationStyleDefaultsKey = "playerPresentationStyle"
    private var mediaClient: MediaRemoteClient?
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?
    private var menuBarIconCollapser: MenuBarIconCollapser?
    private var styleMenuItems: [NSMenuItem] = []
    private var backgroundGraphicsMenuItems: [NSMenuItem] = []
    private var waveformMenuItems: [NSMenuItem] = []
    private var languageMenuItems: [NSMenuItem] = []
    private var lyricsProviderMenuItems: [NSMenuItem] = []
    private var batteryAlertMenuItems: [NSMenuItem] = []
    private var waveformStateCancellable: AnyCancellable?
    private var didShowWaveformPermissionAlert = false
    private var volumeKeys: VolumeKeyInterceptor?
    private var volumeKeysMenuItem: NSMenuItem?
    private var volumePermissionMenuItem: NSMenuItem?
    private var hidesSystemVolume: Bool {
        UserDefaults.standard.object(forKey: "hideSystemVolumeHUD") as? Bool ?? true
    }
    var audioCaptureStatusTitle: String {
        switch mediaClient?.audioCaptureState ?? .idle {
        case .idle: "대기 중"
        case .starting: "연결 중"
        case .running: "연결됨"
        case .permissionRequired: "화면 및 시스템 오디오 녹음 권한 필요"
        case .failed: "연결 실패"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyPreferencesMigration.migrateIfNeeded()
        NSApp.setActivationPolicy(.regular)

        let snapshotPath = ProcessInfo.processInfo.environment["NOTCH_MUSIC_SNAPSHOT_DIR"]
        let storedStyle = UserDefaults.standard.string(forKey: presentationStyleDefaultsKey)
        let previewStyle = ProcessInfo.processInfo.environment["NOTCH_MUSIC_PRESENTATION_STYLE"]
        let presentationStyle = PlayerPresentationStyle(rawValue: previewStyle ?? storedStyle ?? "") ?? .notch
        let client = MediaRemoteClient()
        if let previewWaveformMode = ProcessInfo.processInfo.environment["NOTCH_MUSIC_WAVEFORM_MODE"],
           let waveformMode = WaveformMode(rawValue: previewWaveformMode) {
            client.setWaveformMode(waveformMode, persist: false)
        }
        if let previewLanguage = ProcessInfo.processInfo.environment["NOTCH_MUSIC_LANGUAGE"],
           let language = AppLanguage(rawValue: previewLanguage) {
            client.setAppLanguage(language, persist: false)
        }
        let controller = NotchPanelController(
            mediaClient: client,
            presentationStyle: presentationStyle
        )
        mediaClient = client
        panelController = controller
        waveformStateCancellable = client.$audioCaptureState.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateWaveformMenuState()
                self?.showWaveformPermissionAlertIfNeeded()
            }
        }

        controller.show()

        if let snapshotPath {
            client.loadSnapshotPreview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                controller.captureDebugSnapshots(to: URL(fileURLWithPath: snapshotPath, isDirectory: true))
            }
        } else {
            configureStatusItem()
            client.start()
            volumeKeys = VolumeKeyInterceptor { [weak client] in client?.adjustVolumeKey($0) ?? false }
            refreshVolumeKeys()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshVolumeKeys),
                name: NSWorkspace.didActivateApplicationNotification, object: nil)
            if hidesSystemVolume && !AXIsProcessTrusted()
                && !UserDefaults.standard.bool(forKey: "didRequestVolumeKeyPermission") {
                UserDefaults.standard.set(true, forKey: "didRequestVolumeKeyPermission")
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        volumeKeys?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        mediaClient?.stop()
    }

    private func configureStatusItem() {
        positionStatusItemsOutsideHiddenGroup()

        // Create right to left: the music menu must stay outside the separator's
        // hidden group even before macOS restores the saved positions.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NotchMusic.MainStatusItem"
        let revealItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Nook 설정"
        item.isVisible = true

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "플레이어 보기", action: #selector(showPlayer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "YouTube Music 열기", action: #selector(openYouTubeMusic), keyEquivalent: ""))
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "표시 형태", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        styleMenuItems = PlayerPresentationStyle.allCases.enumerated().map { index, style in
            let item = NSMenuItem(
                title: style.title,
                action: #selector(selectPresentationStyle(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            styleMenu.addItem(item)
            return item
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let waveformItem = NSMenuItem(title: "파형 모드", action: nil, keyEquivalent: "")
        let waveformMenu = NSMenu()
        waveformMenuItems = WaveformMode.allCases.enumerated().map { index, mode in
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectWaveformMode(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            waveformMenu.addItem(item)
            return item
        }
        waveformItem.submenu = waveformMenu
        menu.addItem(waveformItem)

        let backgroundItem = NSMenuItem(title: "배경 그래픽 모드 설정", action: nil, keyEquivalent: "")
        let backgroundMenu = NSMenu()
        backgroundGraphicsMenuItems = BackgroundGraphicsMode.allCases.enumerated().map { index, mode in
            let item = NSMenuItem(title: mode.title, action: #selector(selectBackgroundGraphicsMode(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            backgroundMenu.addItem(item)
            return item
        }
        backgroundItem.submenu = backgroundMenu
        menu.addItem(backgroundItem)

        let lyricsProviderItem = NSMenuItem(title: "가사 제공자", action: nil, keyEquivalent: "")
        let lyricsProviderMenu = NSMenu()
        lyricsProviderMenuItems = LyricsProvider.allCases.enumerated().map { index, provider in
            let item = NSMenuItem(title: provider.title, action: #selector(selectLyricsProvider(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; lyricsProviderMenu.addItem(item); return item
        }
        lyricsProviderItem.submenu = lyricsProviderMenu
        menu.addItem(lyricsProviderItem)

        let languageItem = NSMenuItem(title: "언어 설정", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        languageMenuItems = AppLanguage.allCases.enumerated().map { index, language in
            let item = NSMenuItem(
                title: language.title,
                action: #selector(selectAppLanguage(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            languageMenu.addItem(item)
            return item
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        let batteryAlertItem = NSMenuItem(title: "배터리 잔량 알림", action: nil, keyEquivalent: "")
        let batteryAlertMenu = NSMenu()
        batteryAlertMenuItems = BatteryAlertInterval.allCases.enumerated().map { index, interval in
            let item = NSMenuItem(title: interval.title,
                                  action: #selector(selectBatteryAlertInterval(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            batteryAlertMenu.addItem(item)
            return item
        }
        batteryAlertMenu.autoenablesItems = false
        for item in batteryAlertMenuItems { item.isEnabled = PowerStateMonitor.supportsBatteryAlerts }
        if PowerStateMonitor.supportsBatteryAlerts {
            batteryAlertItem.submenu = batteryAlertMenu
        } else {
            batteryAlertItem.title = "배터리 잔량 알림 (MacBook 전용)"
            batteryAlertItem.isEnabled = false
        }
        menu.addItem(batteryAlertItem)
        let volumeItem = NSMenuItem(title: "시스템 볼륨·밝기 표시 숨기기", action: #selector(toggleSystemVolume), keyEquivalent: "")
        volumeKeysMenuItem = volumeItem
        menu.addItem(volumeItem)
        let permissionItem = NSMenuItem(title: "볼륨·밝기 제어 권한 허용…", action: #selector(openVolumePermission), keyEquivalent: "")
        volumePermissionMenuItem = permissionItem
        menu.addItem(permissionItem)
        refreshVolumeKeys()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        item.isVisible = true

        let collapser = MenuBarIconCollapser(
            toggleItem: revealItem,
            protectedStatusItem: item,
            reservedFrameProvider: { [weak self] in
                self?.panelController?.reservedMenuBarFrame
            },
            temporaryRevealHandler: { [weak self] revealed in
                self?.panelController?.setMenuBarAvoidanceActive(revealed)
            }
        )
        menuBarIconCollapser = collapser
        collapser.startMonitoring()

        updateStyleMenuState()
        updateLyricsProviderMenuState()
        updateWaveformMenuState()
        updateLanguageMenuState()
        updateBackgroundGraphicsMenuState()
        updateBatteryAlertMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshVolumeKeys() }

    @objc private func refreshVolumeKeys() {
        if hidesSystemVolume && AXIsProcessTrusted() { volumeKeys?.start() }
        else { volumeKeys?.stop() }
        volumeKeysMenuItem?.state = hidesSystemVolume ? .on : .off
        let active = volumeKeys?.isActive == true
        volumePermissionMenuItem?.isHidden = !hidesSystemVolume || active
        volumePermissionMenuItem?.title = AXIsProcessTrusted() ? "볼륨·밝기 키 제어 다시 연결" : "볼륨·밝기 제어 권한 허용…"
    }

    @objc private func toggleSystemVolume() {
        UserDefaults.standard.set(!hidesSystemVolume, forKey: "hideSystemVolumeHUD")
        refreshVolumeKeys()
        if hidesSystemVolume && !AXIsProcessTrusted() { openVolumePermission() }
    }

    @objc func openVolumePermission() {
        if AXIsProcessTrusted() { volumeKeys?.stop(); refreshVolumeKeys(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilityPermission()
    }

    func openAccessibilityPermission() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openAudioCapturePermission() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    private func openPrivacySettings(anchor: String) {
        let paneIdentifier: String
        if #available(macOS 27.0, *) {
            paneIdentifier = "com.apple.settings.PrivacySecurity.extension"
        } else {
            paneIdentifier = "com.apple.preference.security"
        }

        guard let url = URL(string: "x-apple.systempreferences:\(paneIdentifier)?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectBatteryAlertInterval(_ sender: NSMenuItem) {
        guard BatteryAlertInterval.allCases.indices.contains(sender.tag) else { return }
        mediaClient?.setBatteryAlertInterval(BatteryAlertInterval.allCases[sender.tag])
        updateBatteryAlertMenuState()
    }

    private func updateBatteryAlertMenuState() {
        guard let selected = mediaClient?.batteryAlertInterval else { return }
        for (index, item) in batteryAlertMenuItems.enumerated() {
            item.state = BatteryAlertInterval.allCases[index] == selected ? .on : .off
        }
    }

    private func positionStatusItemsOutsideHiddenGroup() {
        let inputMenuPositionKey = "NSStatusItem Preferred Position Item-0"
        let musicPositionKey = "NSStatusItem Preferred Position NotchMusic.MainStatusItem"
        let revealPositionKey = "NSStatusItem Preferred Position NotchMusic.IconCollapserToggleSafe"
        let separatorPositionKey = "NSStatusItem Preferred Position NotchMusic.IconCollapserSeparatorSafe"
        let inputMenuPosition = (CFPreferencesCopyAppValue(
            inputMenuPositionKey as CFString,
            "com.apple.TextInputMenuAgent" as CFString
        ) as? NSNumber)?.intValue ?? 0

        // Preferred positions increase toward the left. Keep the music icon on
        // the visible side of both the reveal arrow and the expanding separator.
        UserDefaults.standard.set(
            inputMenuPosition + 1,
            forKey: musicPositionKey
        )
        UserDefaults.standard.set(
            inputMenuPosition + 2,
            forKey: revealPositionKey
        )
        UserDefaults.standard.set(
            inputMenuPosition + 3,
            forKey: separatorPositionKey
        )
    }


    @objc func showPlayer() {
        panelController?.show(expanded: true)
    }

    @objc func openYouTubeMusic() {
        guard let url = URL(string: "https://music.youtube.com") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectPresentationStyle(_ sender: NSMenuItem) {
        guard PlayerPresentationStyle.allCases.indices.contains(sender.tag) else { return }
        let style = PlayerPresentationStyle.allCases[sender.tag]
        UserDefaults.standard.set(style.rawValue, forKey: presentationStyleDefaultsKey)
        panelController?.setPresentationStyle(style)
        updateStyleMenuState()
    }

    private func updateStyleMenuState() {
        let storedStyle = UserDefaults.standard.string(forKey: presentationStyleDefaultsKey)
        let selected = PlayerPresentationStyle(rawValue: storedStyle ?? "") ?? .notch
        statusItem?.button?.image = selected.menuBarIcon
        statusItem?.button?.toolTip = "Nook 설정 — \(selected.title)"
        for (index, item) in styleMenuItems.enumerated() {
            item.state = PlayerPresentationStyle.allCases[index] == selected ? .on : .off
        }
    }

    @objc private func selectWaveformMode(_ sender: NSMenuItem) {
        guard WaveformMode.allCases.indices.contains(sender.tag) else { return }
        let mode = WaveformMode.allCases[sender.tag]
        mediaClient?.setWaveformMode(mode)
        updateWaveformMenuState()

        if mode == .live {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showWaveformPermissionAlertIfNeeded()
            }
        }
    }

    private func updateWaveformMenuState() {
        guard let client = mediaClient else { return }
        for (index, item) in waveformMenuItems.enumerated() {
            let mode = WaveformMode.allCases[index]
            item.state = mode == client.waveformMode ? .on : .off
            if mode == .live {
                switch client.audioCaptureState {
                case .starting:
                    item.title = "\(mode.title) — 연결 중"
                case .running:
                    item.title = "\(mode.title) — 연결됨"
                case .permissionRequired:
                    item.title = "\(mode.title) — 권한 필요"
                case .failed:
                    item.title = "\(mode.title) — 다시 선택"
                case .idle:
                    item.title = mode.title
                }
            }
        }
    }

    @objc private func selectBackgroundGraphicsMode(_ sender: NSMenuItem) {
        guard BackgroundGraphicsMode.allCases.indices.contains(sender.tag) else { return }
        mediaClient?.setBackgroundGraphicsMode(BackgroundGraphicsMode.allCases[sender.tag])
        updateBackgroundGraphicsMenuState()
    }

    private func updateBackgroundGraphicsMenuState() {
        guard let selected = mediaClient?.backgroundGraphicsMode else { return }
        for (index, item) in backgroundGraphicsMenuItems.enumerated() {
            item.state = BackgroundGraphicsMode.allCases[index] == selected ? .on : .off
        }
    }

    @objc private func selectLyricsProvider(_ sender: NSMenuItem) {
        guard LyricsProvider.allCases.indices.contains(sender.tag) else { return }
        mediaClient?.setLyricsProvider(LyricsProvider.allCases[sender.tag])
        updateLyricsProviderMenuState()
    }

    private func updateLyricsProviderMenuState() {
        let selected = mediaClient?.lyricsProvider ?? .defaultProvider
        for (index, item) in lyricsProviderMenuItems.enumerated() { item.state = LyricsProvider.allCases[index] == selected ? .on : .off }
    }

    @objc private func selectAppLanguage(_ sender: NSMenuItem) {
        guard AppLanguage.allCases.indices.contains(sender.tag) else { return }
        mediaClient?.setAppLanguage(AppLanguage.allCases[sender.tag])
        updateLanguageMenuState()
    }

    private func updateLanguageMenuState() {
        guard let selected = mediaClient?.appLanguage else { return }
        for (index, item) in languageMenuItems.enumerated() {
            item.state = AppLanguage.allCases[index] == selected ? .on : .off
        }
    }

    private func showWaveformPermissionAlertIfNeeded() {
        guard mediaClient?.audioCaptureState == .permissionRequired,
              !didShowWaveformPermissionAlert else { return }
        didShowWaveformPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "실제 파형을 사용하려면 권한이 필요합니다"
        alert.informativeText = "시스템 설정의 개인정보 보호 및 보안에서 Nook의 화면 및 시스템 오디오 녹음을 허용한 뒤 앱을 다시 실행해 주세요. 화면 영상과 마이크는 처리하지 않습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "나중에")
        if alert.runModal() == .alertFirstButtonReturn {
            openAudioCapturePermission()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
