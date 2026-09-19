import AppKit
import Combine
import CoreImage
import QuartzCore
import SwiftUI

enum PlayerTypography {
    static let playbackTime = Font.system(size: 13, weight: .semibold)
}

struct ImmersiveDateLeadingKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct ImmersiveClock: View {
    let language: AppLanguage
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 9) {
                Text(context.date, format: .dateTime.hour().minute())
                    .foregroundStyle(.white.opacity(0.88))
                Text(context.date, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                    .foregroundStyle(.white.opacity(0.45))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ImmersiveDateLeadingKey.self,
                            value: geometry.frame(in: .named("immersiveContent")).minX)
                    })
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
        }
        .environment(\.locale, Locale(identifier: language == .korean ? "ko_KR" : "en_US"))
    }
}

// Native Liquid Glass on macOS 26, loaded by its public Objective-C class name
// so the macOS 13-compatible build can continue using the stable SDK.
struct LiquidGlassCapsule<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let container: NSView
        if #available(macOS 26.0, *), let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassType.init(frame: .zero)
            glass.setValue(24.0, forKey: "cornerRadius")
            // NSGlassEffectViewStyleClear = 1 in the public macOS 26 SDK.
            glass.setValue(1, forKey: "style")
            glass.setValue(nil, forKey: "tintColor")
            glass.setValue(host, forKey: "contentView")
            container = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 24
            material.layer?.masksToBounds = true
            material.addSubview(host)
            container = material
        }
        context.coordinator.host = host
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.host?.rootView = content
        context.coordinator.host?.frame = view.bounds
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var host: NSHostingView<Content>? }
}

// Lightweight rhythm proxy, not source separation: ignore the vocal-heavy
// middle bands. Bass and upper percussion can still contain vocal harmonics.
enum AmbientRhythmEnergy {
    static func measure(_ levels: [Double]) -> Double {
        guard levels.count == 9 else { return 0 }
        let weights = [(0, 0.45), (1, 0.35), (7, 0.15), (8, 0.05)]
        return sqrt(weights.reduce(0.0) { total, entry in
            let level = levels[entry.0].isFinite ? min(1, max(0, levels[entry.0])) : 0
            return total + level * level * entry.1
        })
    }
}

struct AmbientArtworkView: NSViewRepresentable {
    let colors: [NSColor]
    let moving: Bool
    var mode: BackgroundGraphicsMode = .basic
    var audioSource: MediaRemoteClient? = nil

    func makeNSView(context: Context) -> AmbientArtworkLayers { AmbientArtworkLayers() }
    func updateNSView(_ view: AmbientArtworkLayers, context: Context) {
        view.configure(colors: colors, moving: moving, mode: mode)
    }
    static func dismantleNSView(_ view: AmbientArtworkLayers, coordinator: ()) {
        view.stop()
    }
}

// Full-bleed color washes and soft waveform ribbons, animated by the compositor.
// Both modes share a small 640 × 400 logical canvas with no display timers.
final class AmbientArtworkLayers: NSView {
    private let field = CALayer()
    private let washes = CALayer()
    private let waves = CALayer()
    private let gradients = (0..<5).map { _ in CAGradientLayer() }
    private let ribbons = (0..<3).map { _ in CAGradientLayer() }
    private var waveStrokes: [[CAShapeLayer]] = []
    private var palette: [NSColor] = []
    private var musicPhase: Double = 0
    private var lastAudioTime: CFTimeInterval?
    private var smoothEnergy: Double = 0
    private var shouldMove = false
    private var running = false
    private var powerObserver: NSObjectProtocol?
    private(set) var mode: BackgroundGraphicsMode = .basic
    private(set) var responseScale: CGFloat = 1
    private(set) var responseTranslation = CGPoint.zero
    var isAnimating: Bool { running }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        layer?.masksToBounds = true
        field.anchorPoint = .zero
        field.bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        layer?.addSublayer(field)
        for container in [washes, waves] {
            container.frame = field.bounds
            field.addSublayer(container)
        }
        waves.opacity = 0
        for (index, gradient) in gradients.enumerated() {
            // Broad diagonal washes blend across the entire scene. No radial
            // highlights, visible circular edges or small orbiting color spots.
            gradient.type = .axial
            gradient.startPoint = CGPoint(x: 0.15, y: 0)
            gradient.endPoint = CGPoint(x: 0.85, y: 1)
            gradient.bounds = CGRect(x: 0, y: 0, width: 1400, height: 1100)
            gradient.position = Self.centers[index]
            gradient.setAffineTransform(CGAffineTransform(rotationAngle: Self.angles[index]))
            let horizontalFade = CAGradientLayer()
            horizontalFade.frame = gradient.bounds
            horizontalFade.startPoint = CGPoint(x: 0, y: 0.5)
            horizontalFade.endPoint = CGPoint(x: 1, y: 0.5)
            horizontalFade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
            horizontalFade.locations = [0, 0.25, 0.75, 1]
            let verticalFade = CAGradientLayer()
            verticalFade.frame = gradient.bounds
            verticalFade.startPoint = CGPoint(x: 0.5, y: 0)
            verticalFade.endPoint = CGPoint(x: 0.5, y: 1)
            verticalFade.colors = horizontalFade.colors
            verticalFade.locations = horizontalFade.locations
            horizontalFade.mask = verticalFade
            gradient.mask = horizontalFade
            gradient.shouldRasterize = true
            gradient.rasterizationScale = 1
            washes.addSublayer(gradient)
        }
        for (index, ribbon) in ribbons.enumerated() {
            ribbon.frame = field.bounds.insetBy(dx: -160, dy: -140)
            ribbon.startPoint = CGPoint(x: 0, y: 0.2)
            ribbon.endPoint = CGPoint(x: 1, y: 0.8)
            let mask = CALayer()
            mask.frame = CGRect(origin: .zero, size: ribbon.bounds.size)
            // Blur only the small logical mask, before it is scaled to the screen.
            // This smooths the falloff without blurring text or album artwork.
            mask.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 24.0])!]
            var strokes: [CAShapeLayer] = []
            // Path topology is fixed throughout the loop.
            for width in stride(from: 240, through: 24, by: -24) {
                let stroke = CAShapeLayer()
                stroke.frame = mask.bounds
                stroke.path = Self.wavePath(index: index, phase: 0)
                stroke.fillColor = nil
                stroke.strokeColor = NSColor.white.withAlphaComponent(0.075).cgColor
                stroke.lineWidth = CGFloat(width)
                stroke.lineCap = .round
                stroke.lineJoin = .round
                mask.addSublayer(stroke)
                strokes.append(stroke)
            }
            mask.shouldRasterize = true
            mask.rasterizationScale = 1
            ribbon.mask = mask
            waveStrokes.append(strokes)
            waves.addSublayer(ribbon)
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) } }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.transform = CATransform3DMakeScale(bounds.width / 640, bounds.height / 400, 1)
        CATransaction.commit()
    }

    func configure(colors: [NSColor], moving: Bool, mode: BackgroundGraphicsMode = .basic) {
        let colors = colors.isEmpty ? ArtworkPalette.fallback : colors
        if palette != colors {
            CATransaction.begin()
            CATransaction.setAnimationDuration(palette.isEmpty ? 0 : 1.2)
            palette = colors
            for (index, gradient) in gradients.enumerated() {
                let color = colors[index % colors.count]
                gradient.colors = [0, 0.2, 0.8, 0.2, 0].map { color.withAlphaComponent($0).cgColor }
                gradient.locations = [0, 0.18, 0.5, 0.82, 1]
            }
            for (index, ribbon) in ribbons.enumerated() {
                ribbon.colors = (0..<3).map { colors[(index + $0) % colors.count].cgColor }
                ribbon.locations = [0, 0.5, 1]
            }
            CATransaction.commit()
        }
        if self.mode != mode {
            self.mode = mode
            CATransaction.begin()
            CATransaction.setAnimationDuration(moving ? 0.7 : 0)
            // Keep a quiet bed of color beneath the waves.
            washes.opacity = mode == .basic ? 1 : 0.55
            waves.opacity = mode == .waveform ? 1 : 0
            CATransaction.commit()
            waveStrokes.flatMap { $0 }.forEach { $0.removeAllAnimations() }
            gradients.forEach { $0.removeAllAnimations() }
            ribbons.forEach { $0.removeAllAnimations() }
            running = false
        }
        shouldMove = moving
        updateMotion()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMotion() }

    // Two harmonics form broad, interleaving ribbons instead of equalizer bars.
    // Coordinates include the mask's 160 × 140 overscan margin.
    static func wavePath(index: Int, phase: Double) -> CGPath {
        let path = CGMutablePath()
        let baseline = 340.0 + Double(index - 1) * 66
        let amplitude = [62.0, 84.0, 53.0][index % 3]
        func height(_ x: Double) -> Double {
            baseline + amplitude * sin(x / 640 * .pi * 2 + phase + Double(index) * 1.9)
                + 23 * sin(x / 640 * .pi * 4 - phase + Double(index))
        }
        func slope(_ x: Double) -> Double {
            amplitude * .pi * 2 / 640 * cos(x / 640 * .pi * 2 + phase + Double(index) * 1.9)
                + 23 * .pi * 4 / 640 * cos(x / 640 * .pi * 4 - phase + Double(index))
        }
        path.move(to: CGPoint(x: -80, y: height(-80)))
        for x in stride(from: -80.0, to: 1040, by: 40) {
            path.addCurve(to: CGPoint(x: x + 40, y: height(x + 40)),
                          control1: CGPoint(x: x + 40 / 3, y: height(x) + slope(x) * 40 / 3),
                          control2: CGPoint(x: x + 80 / 3, y: height(x + 40) - slope(x + 40) * 40 / 3))
        }
        return path
    }

    // Kept for callers compiled against the old background API. The background
    // now owns its compositor animation and never consumes audio frames.
    func respond(to levels: [Double]) {}

    private static let centers = [CGPoint(x: 80, y: 340), CGPoint(x: 600, y: 60), CGPoint(x: 240, y: 120),
                                  CGPoint(x: 510, y: 380), CGPoint(x: 100, y: -30)]
    private static let angles: [CGFloat] = [-0.65, 0.55, -0.2, 0.85, -0.9]

    private func updateMotion() {
        let animate = shouldMove && window != nil
        guard running != animate else { return }
        running = animate
        if animate {
            for (index, gradient) in gradients.enumerated() {
                if gradient.animation(forKey: "drift") == nil {
                    let origin = Self.centers[index]
                    let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                    let animation = CAKeyframeAnimation(keyPath: "position")
                    animation.values = [origin,
                        CGPoint(x: origin.x + 235 * direction, y: origin.y - 165),
                        CGPoint(x: origin.x - 155 * direction, y: origin.y + 135), origin].map { NSValue(point: $0) }
                    animation.keyTimes = [0, 0.34, 0.68, 1]
                    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                    animation.duration = ((mode == .basic ? 20.0 : 8.0) + Double(index) * 2.5) * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.8 : 1)
                    animation.repeatCount = .infinity
                    gradient.add(animation, forKey: "drift")
                }
            }
            if mode == .waveform {
                for (index, ribbon) in ribbons.enumerated() {
                    let animation = CAKeyframeAnimation(keyPath: "transform")
                    // A 16-sample loop produces the same slow, continuous
                    // motion while substantially reducing CA animation
                    // interpolation and commit overhead on large displays.
                    animation.values = (0...16).map { step -> NSValue in
                        let phase = Double(step) / 16 * .pi * 2
                        let offset = Double(index) * 2.1
                        var transform = CATransform3DMakeScale(1.14, 1.14, 1)
                        transform = CATransform3DRotate(transform, sin(phase + offset) * 0.16, 0, 0, 1)
                        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(
                            sin(phase + offset) * 110 + sin(phase * 2 + offset) * 25,
                            cos(phase + offset) * 70, 0))
                        return NSValue(caTransform3D: transform)
                    }
                    animation.duration = Double(12 + index * 4)
                        * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.8 : 1)
                    animation.repeatCount = .infinity
                    animation.calculationMode = .linear
                    ribbon.add(animation, forKey: "freeMotion")
                }
            }
            let paused = field.timeOffset
            field.speed = 1
            field.timeOffset = 0
            field.beginTime = 0
            if paused > 0 { field.beginTime = field.convertTime(CACurrentMediaTime(), from: nil) - paused }
        } else {
            lastAudioTime = nil
            let time = field.convertTime(CACurrentMediaTime(), from: nil)
            field.speed = 0
            field.timeOffset = time
        }
    }

    func stop() {
        gradients.forEach { $0.removeAllAnimations() }
        waveStrokes.flatMap { $0 }.forEach { $0.removeAllAnimations() }
        waves.removeAllAnimations()
        ribbons.forEach { $0.removeAllAnimations() }
        shouldMove = false
        running = false
    }
}

enum ImmersiveMotion {
    static var openDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0.62
    }
    static var closeDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0.46
    }
    static var opening: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: openDuration)
            : .timingCurve(0.20, 0.80, 0.20, 1, duration: openDuration)
    }
    static var closing: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.18)
            : .timingCurve(0.40, 0, 0.20, 1, duration: closeDuration)
    }
}

// A rounded, proportionally scaled card emerges from the sensor slot. Only the
// card's mask changes aspect ratio; artwork and text never stretch into a ribbon.
struct ImmersivePortal: AnimatableModifier {
    var progress: CGFloat
    let source: CGRect
    let reduceMotion: Bool
    var size: CGSize = .zero
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    private var t: CGFloat { min(max(progress, 0), 1) }

    func cardFrame(size: CGSize) -> CGRect {
        guard !reduceMotion, t < 1 else { return CGRect(origin: .zero, size: size) }
        let width = source.width + (size.width - source.width) * t
        let height = source.height + (size.height - source.height) * t
        let centerX = source.midX + (size.width / 2 - source.midX) * t
        // Slight downward travel lets the card detach before settling full-screen.
        let top = source.minY * (1 - t) + min(52, size.height * 0.065) * sin(.pi * t)
        return CGRect(x: centerX - width / 2, y: top, width: width, height: height)
    }

    func transform(size: CGSize) -> CGAffineTransform {
        guard !reduceMotion, size.width > 0, size.height > 0 else { return .identity }
        let frame = cardFrame(size: size)
        let scale = frame.width / size.width
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: frame.minX, ty: frame.minY)
    }

    func body(content: Content) -> some View {
        let frame = cardFrame(size: size)
        let scale = size.width > 0 ? frame.width / size.width : 1
        let radius = reduceMotion ? 0 : source.height / 2 * (1 - t) + 32 * sin(.pi * t)
        let fade = min(1, t / 0.12)
        content
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(reduceMotion ? t : fade * fade * (3 - 2 * fade))
            .position(x: frame.midX, y: frame.midY)
            .frame(width: size.width, height: size.height)
    }
}

// Only the current lyric owns a native anchor. AppKit animates the clip view;
// no polling, per-row native views, or per-frame SwiftUI state updates are needed.
enum LyricScrollLayout {
    static func targetOffset(
        lineMidY: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maximum = max(0, documentHeight - viewportHeight)
        return min(max(lineMidY - viewportHeight / 2, 0), maximum)
    }
}

struct SmoothLyricScrollAnchor: NSViewRepresentable {
    let lineID: Int
    let reduceMotion: Bool

    func makeNSView(context: Context) -> LyricAnchorView { LyricAnchorView() }

    func updateNSView(_ view: LyricAnchorView, context: Context) {
        view.lineID = lineID
        view.reduceMotion = reduceMotion
        view.needsLayout = true
    }
}

final class LyricAnchorView: NSView {
    var lineID = 0
    var reduceMotion = false
    private var scrolledLineID: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard scrolledLineID != lineID, window != nil, bounds.height > 0,
              let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        scrolledLineID = lineID
        let clip = scroll.contentView
        let rect = convert(bounds, to: document)
        let target = CGPoint(x: clip.bounds.origin.x,
                             y: LyricScrollLayout.targetOffset(
                                lineMidY: rect.midY,
                                documentHeight: document.bounds.height,
                                viewportHeight: clip.bounds.height
                             ))
        guard abs(target.y - clip.bounds.origin.y) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.1, 0.25, 1)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {}
    }
}

// Keep the native scroll view hidden even with macOS “Always” scroll bars.
struct HiddenScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> IndicatorGuardView { IndicatorGuardView() }
    func updateNSView(_ view: IndicatorGuardView, context: Context) { view.hideIndicators() }
}

final class IndicatorGuardView: NSView {
    private weak var guardedScroll: NSScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var applying = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { observations = []; guardedScroll = nil }
        else {
            hideIndicators()
            // SwiftUI may attach the document after the representable's window callback.
            DispatchQueue.main.async { [weak self] in self?.hideIndicators() }
        }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideIndicators()
    }
    override func layout() {
        super.layout()
        hideIndicators()
    }
    func hideIndicators() {
        guard !applying, let scroll = enclosingScrollView else { return }
        if guardedScroll !== scroll {
            observations = []
            guardedScroll = scroll
            // SwiftUI can restore these properties after layout or lyric updates.
            observations = [
                scroll.observe(\.hasVerticalScroller, options: [.new]) { [weak self] _, _ in self?.hideIndicators() },
                scroll.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] _, _ in self?.hideIndicators() },
                scroll.observe(\.verticalScroller, options: [.new]) { [weak self] _, _ in self?.hideIndicators() },
                scroll.observe(\.horizontalScroller, options: [.new]) { [weak self] _, _ in self?.hideIndicators() }
            ]
        }
        applying = true
        defer { applying = false }
        scroll.verticalScroller?.alphaValue = 0
        scroll.horizontalScroller?.alphaValue = 0
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
    }
}
