import SwiftUI

struct PlayerSurfaceShape: Shape {
    let style: PlayerPresentationStyle
    var expansionProgress: CGFloat
    let compactHeight: CGFloat
    let expandedCornerRadius: CGFloat

    var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let progress = min(max(expansionProgress, 0), 1)
        if style == .dynamicIsland {
            let compactRadius = compactHeight / 2
            let radius = compactRadius + (expandedCornerRadius - compactRadius) * progress
            return Path(roundedRect: rect, cornerRadius: radius)
        }

        // Broader continuous corners ease out of the straight bezel/sides.
        // Circular arcs have an abrupt curvature change at those joins, which
        // can still look angular even when their tangent directions agree.
        let shoulder = min(10 + 6 * progress, rect.width / 4, rect.height * 0.32)
        // Keep the approved shoulders, but give the base a subtler rounding.
        let bottom = min(9 + 11 * progress, (rect.width - 2 * shoulder) / 2,
                         rect.height - shoulder)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let top = rect.minY
        let floor = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        Self.addContinuousCorner(to: &path, from: CGPoint(x: rect.maxX, y: top),
                                 corner: CGPoint(x: right, y: top),
                                 end: CGPoint(x: right, y: top + shoulder))
        path.addLine(to: CGPoint(x: right, y: floor - bottom))
        Self.addContinuousCorner(to: &path, from: CGPoint(x: right, y: floor - bottom),
                                 corner: CGPoint(x: right, y: floor),
                                 end: CGPoint(x: right - bottom, y: floor))
        path.addLine(to: CGPoint(x: left + bottom, y: floor))
        Self.addContinuousCorner(to: &path, from: CGPoint(x: left + bottom, y: floor),
                                 corner: CGPoint(x: left, y: floor),
                                 end: CGPoint(x: left, y: floor - bottom))
        path.addLine(to: CGPoint(x: left, y: top + shoulder))
        Self.addContinuousCorner(to: &path, from: CGPoint(x: left, y: top + shoulder),
                                 corner: CGPoint(x: left, y: top),
                                 end: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }

    private static func addContinuousCorner(to path: inout Path, from start: CGPoint,
                                             corner: CGPoint, end: CGPoint) {
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let midpoint = CGPoint(x: 0.22 * start.x + 0.56 * corner.x + 0.22 * end.x,
                               y: 0.22 * start.y + 0.56 * corner.y + 0.22 * end.y)
        // Collinear controls give zero curvature at the straight-line joins;
        // the two halves have matching tangent and curvature at their midpoint.
        path.addCurve(to: midpoint, control1: mix(start, corner, 0.24),
                      control2: mix(start, corner, 0.56))
        path.addCurve(to: end, control1: mix(corner, end, 0.44),
                      control2: mix(corner, end, 0.76))
    }
}
