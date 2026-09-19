import SwiftUI

/// Shared, event-driven transport feedback. No idle timer or audio sampling.
struct PlaybackTransportButton: View {
    let symbol: String
    let size: CGFloat
    var width: CGFloat = 40
    var height: CGFloat = 40
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = 0

    var body: some View {
        Button {
            if !reduceMotion { activation &+= 1 }
            action()
        } label: {
            if #available(macOS 14.0, *), symbol == "backward.fill" || symbol == "forward.fill" {
                Color.clear.frame(width: size * 1.7, height: size)
                    .keyframeAnimator(initialValue: CGFloat.zero, trigger: activation) { _, phase in
                        ZStack {
                            ForEach(0..<3) { index in
                                let travel = CGFloat(index) - 0.5 - phase
                                let edge = min(1, max(0, (1.5 - abs(travel)) * 2))
                                Image(systemName: "play.fill")
                                    .font(.system(size: size, weight: .semibold))
                                    .scaleEffect(x: symbol == "backward.fill" ? -edge : edge, y: edge)
                                    .opacity(edge)
                                    .offset(x: travel * size * 0.78 * (symbol == "backward.fill" ? 1 : -1))
                            }
                        }
                        .frame(width: size * 1.7, height: size)
                    } keyframes: { _ in
                        CubicKeyframe(1, duration: 0.26)
                        MoveKeyframe(0)
                    }
            } else {
                ZStack {
                    Image(systemName: "play.fill").opacity(symbol == "play.fill" ? 1 : 0)
                    Image(systemName: "pause.fill").opacity(symbol == "pause.fill" ? 1 : 0)
                }
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.2, height: size * 1.2)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: symbol)
            }
        }
        .buttonStyle(PlaybackPressStyle(width: width, height: height))
        .modifier(PlaybackFocusAppearance())
        .accessibilityLabel(symbol == "backward.fill" ? "이전 곡" : symbol == "forward.fill" ? "다음 곡" : symbol == "pause.fill" ? "일시정지" : "재생")
    }
}

struct PlaybackPressStyle: ButtonStyle {
    var width: CGFloat = 40
    var height: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.94))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.82 : 1)
            .frame(width: width, height: height)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.10 : 0)))
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : configuration.isPressed
                ? .easeOut(duration: 0.09)
                : .spring(response: 0.30, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct PlaybackArtworkMotion: ViewModifier {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.85)) {
                $0.scaleEffect(isPlaying ? 1 : 0.80, anchor: .center)
            }
        } else {
            content.scaleEffect(isPlaying ? 1 : 0.80, anchor: .center)
        }
    }
}

private struct PlaybackFocusAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
