import AppKit
@main struct AmbientMotionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        let view = AmbientArtworkLayers(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        func animations(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animations)
        }
        view.configure(colors: [.red, .blue], moving: true, mode: .basic)
        precondition(view.isAnimating && animations(view.layer!).filter { $0 == "drift" }.count == 5)
        view.configure(colors: [.red, .blue], moving: true, mode: .waveform)
        precondition(animations(view.layer!).filter { $0 == "freeMotion" }.count == 3)
        view.respond(to: Array(repeating: 1, count: 9))
        precondition(!animations(view.layer!).contains("audioResponse"))
        precondition(BackgroundGraphicsMode.waveform.title == "동작 모드")
        view.stop()
        precondition(!view.isAnimating && animations(view.layer!).isEmpty)
        print("PASS: gentle drift, independent active movement, audio ignored, animation teardown")
    }
}
