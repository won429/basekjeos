import AppKit

@MainActor
final class MenuBarIconCollapser: NSObject {
    typealias ReservedFrameProvider = @MainActor () -> NSRect?
    typealias TemporaryRevealHandler = @MainActor (Bool) -> Void

    private let toggleItem: NSStatusItem
    private let separatorItem: NSStatusItem
    private let temporaryRevealHandler: TemporaryRevealHandler
    private var autoCollapseTimer: Timer?
    private var layoutMonitor: Timer?
    private(set) var isCollapsed = true

    init(toggleItem: NSStatusItem, protectedStatusItem: NSStatusItem,
         reservedFrameProvider: @escaping ReservedFrameProvider,
         temporaryRevealHandler: @escaping TemporaryRevealHandler) {
        self.toggleItem = toggleItem
        self.temporaryRevealHandler = temporaryRevealHandler
        // Restore the separator's saved position at its small size before widening.
        // Creating an oversized item before assigning its autosave name can make
        // AppKit evict it during the very first menu-bar layout.
        separatorItem = NSStatusBar.system.statusItem(withLength: 1)
        super.init()
        toggleItem.autosaveName = "NotchMusic.IconCollapserToggleSafe"
        separatorItem.autosaveName = "NotchMusic.IconCollapserSeparatorSafe"
        separatorItem.button?.title = ""
        toggleItem.button?.target = self
        toggleItem.button?.action = #selector(toggle)
        applyLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(applyLayout),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        autoCollapseTimer?.invalidate()
        layoutMonitor?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(separatorItem)
        NSStatusBar.system.removeStatusItem(toggleItem)
    }

    func startMonitoring() {
        guard layoutMonitor == nil else { return }
        // Repair layout without treating transient window visibility as user intent.
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyLayout() }
        }
        layoutMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
        applyLayout()
    }

    @objc func toggle() { setCollapsed(!isCollapsed) }

    func setCollapsed(_ collapsed: Bool) {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        let changed = isCollapsed != collapsed
        isCollapsed = collapsed
        applyLayout()
        if changed { temporaryRevealHandler(!collapsed) }
        if !collapsed {
            let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.setCollapsed(true) }
            }
            autoCollapseTimer = timer
            // Menu tracking must not postpone the automatic return indefinitely.
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func applyLayout() {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 1440
        let length: CGFloat = isCollapsed ? max(500, min(widest * 2, 10_000)) : 1
        if separatorItem.length != length { separatorItem.length = length }
        if !separatorItem.isVisible { separatorItem.isVisible = true }
        if !toggleItem.isVisible { toggleItem.isVisible = true }
        if toggleItem.length != NSStatusItem.squareLength { toggleItem.length = NSStatusItem.squareLength }
        let title = isCollapsed ? "접힌 메뉴 막대 아이콘 펼치기" : "메뉴 막대 아이콘 다시 접기"
        if toggleItem.button?.toolTip != title {
            toggleItem.button?.image = NSImage(systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
                accessibilityDescription: isCollapsed ? "아이콘 펼치기" : "아이콘 접기")
            toggleItem.button?.toolTip = title
        }
    }
}
