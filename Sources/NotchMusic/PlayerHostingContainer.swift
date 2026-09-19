import AppKit

/// Window dimensions belong to the AppKit controller, never to animated SwiftUI
/// content. A plain content view prevents NSHostingView from negotiating window
/// size while AppKit is already completing a layout/display cycle.
final class PlayerHostingContainer: NSView {
    let hostedView: NSView
    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: hostedView.frame)
        autoresizingMask = [.width, .height]
        hostedView.autoresizingMask = [.width, .height]
        addSubview(hostedView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
