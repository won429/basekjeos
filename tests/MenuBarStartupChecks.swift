import AppKit

@main struct MenuBarStartupChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StartupCheckDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class StartupCheckDelegate: NSObject, NSApplicationDelegate {
    private var collapser: MenuBarIconCollapser?
    private var music: NSStatusItem?
    private var reveals: [Bool] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test executable has its own defaults domain; mirror the app's safe order.
        for (name, position) in [("NotchMusic.MainStatusItem", 1),
                                 ("NotchMusic.IconCollapserToggleSafe", 2),
                                 ("NotchMusic.IconCollapserSeparatorSafe", 3)] {
            UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(name)")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NotchMusic.MainStatusItem"
        item.button?.title = "T"
        music = item
        let toggle = NSStatusBar.system.statusItem(withLength: 1)
        let controller = MenuBarIconCollapser(toggleItem: toggle, protectedStatusItem: item,
            reservedFrameProvider: { nil }, // No crowding signal: startup must still collapse.
            temporaryRevealHandler: { [weak self] in self?.reveals.append($0) })
        collapser = controller
        // Assert before yielding to the run loop: a delayed collapse is a failure.
        precondition(controller.isCollapsed, "The initial state must be collapsed before monitoring starts")
        precondition(toggle.button?.toolTip == "접힌 메뉴 막대 아이콘 펼치기")
        precondition(toggle.length == NSStatusItem.squareLength)
        controller.startMonitoring()
        precondition(controller.isCollapsed, "Starting monitoring must preserve the collapsed default")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            precondition(controller.isCollapsed, "The collapsed default must survive the initial AppKit layout")
            precondition(item.button?.window?.isVisible == true, "Settings icon remains accessible")
            let separators = NSApp.windows.filter { $0.frame.width > 500 && $0.frame.height <= 64 }
            precondition(!separators.isEmpty, "Collapsed state must have a physically expanded separator")
            let boundary = separators.map { $0.frame.maxX }.max()!
            precondition(item.button!.window!.frame.minX >= boundary - 1)
            precondition(toggle.button!.window!.frame.minX >= boundary - 1)

            // Transient eviction/reposition must not turn into a permanent reveal.
            item.isVisible = false
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            precondition(controller.isCollapsed)
            item.isVisible = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            precondition(controller.isCollapsed)

            controller.toggle()
            precondition(!controller.isCollapsed)
            controller.startMonitoring() // Repeated start must not override a manual reveal.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            precondition(!controller.isCollapsed, "Polling must respect manual reveal")
            try? await Task.sleep(nanoseconds: 9_500_000_000)
            precondition(controller.isCollapsed, "The existing 10-second automatic return is preserved")
            precondition(self.reveals == [true, false])
            controller.toggle()
            controller.toggle()
            precondition(controller.isCollapsed, "Manual collapse remains available")
            print("PASS: synchronous collapsed initialization before timers, startup layout, automatic collapse without overlap, settings visibility, repeated start, manual reveal, 10-second return, manual collapse")
            NSStatusBar.system.removeStatusItem(item)
            NSApp.terminate(nil)
        }
    }
}
