import AppKit
import Darwin

// Resolve at runtime: unavailable displays/APIs leave the key with macOS.
@MainActor final class ScreenBrightnessController {
    private typealias ReadBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias WriteBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let readBrightness: ReadBrightness?
    private let writeBrightness: WriteBrightness?

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        self.library = library
        readBrightness = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: ReadBrightness.self) }
        writeBrightness = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: WriteBrightness.self) }
    }

    deinit { if let library { dlclose(library) } }

    func adjust(_ input: VolumeKeyInput) -> Float? {
        guard input.isBrightness, input.isDown,
              let readBrightness, let writeBrightness else { return nil }
        // Match brightness keys to the built-in display, or the main display
        // when the built-in screen is unavailable (for example, clamshell mode).
        let screens = NSScreen.screens
        let displayIDs = screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let display = displayIDs.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
        var current: Float = 0
        guard readBrightness(display, &current) == 0, current.isFinite else { return nil }
        let target = input.brightnessTarget(from: current)
        guard writeBrightness(display, target) == 0 else { return nil }
        var actual = target
        if readBrightness(display, &actual) != 0 || !actual.isFinite { actual = target }
        return min(max(actual, 0), 1)
    }
}
