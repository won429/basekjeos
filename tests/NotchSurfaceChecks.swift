import SwiftUI

@main
struct NotchSurfaceChecks {
    static func main() {
        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            for size in [CGSize(width: 90, height: 30), CGSize(width: 204, height: 30),
                         CGSize(width: 272, height: 66), CGSize(width: 360, height: 180)] {
                let rect = CGRect(origin: CGPoint(x: 13, y: 7), size: size)
                let shape = PlayerSurfaceShape(style: .notch, expansionProgress: progress,
                                               compactHeight: 30, expandedCornerRadius: 28)
                let path = shape.path(in: rect)
                precondition(path.boundingRect == rect)
                precondition(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
                precondition(!path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 12)))
                // Compare actual curve geometry. Ray-based contains() can be
                // unstable at the exact y of a zero-curvature cubic endpoint.
                var cursor = CGPoint.zero
                var curves: [[CGPoint]] = []
                path.forEach { element in
                    switch element {
                    case .move(to: let p), .line(to: let p): cursor = p
                    case .curve(to: let p, control1: let a, control2: let b):
                        curves.append([cursor, a, b, p]); cursor = p
                    default: break
                    }
                }
                precondition(curves.count == 8)
                for i in curves.indices {
                    for j in 0..<4 {
                        let a = curves[i][j]
                        let b = curves[7 - i][3 - j]
                        // SwiftUI Path may quantize stored controls to Float.
                        precondition(abs(a.x + b.x - 2 * rect.midX) < 0.001,
                                     "Mirrored controls differ: \(a), \(b), \(rect)")
                        precondition(abs(a.y - b.y) < 0.001)
                    }
                }
                for i in stride(from: 0, to: 8, by: 2) {
                    let first = curves[i], second = curves[i + 1]
                    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
                        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                    }
                    precondition(abs(cross(first[0], first[1], first[2])) < 0.001)
                    precondition(abs(cross(second[3], second[2], second[1])) < 0.001)
                    precondition(abs(cross(first[2], first[3], second[1])) < 0.001)
                }
            }
        }
        let empty = PlayerSurfaceShape(style: .notch, expansionProgress: 0,
                                      compactHeight: 30, expandedCornerRadius: 28).path(in: .zero)
        precondition(empty.isEmpty)
        let rect = CGRect(x: 0, y: 0, width: 204, height: 30)
        let capsule = PlayerSurfaceShape(style: .dynamicIsland, expansionProgress: 0,
                                        compactHeight: 30, expandedCornerRadius: 28).path(in: rect)
        precondition(capsule.contains(CGPoint(x: 1, y: 15)))
        precondition(!capsule.contains(CGPoint(x: 1, y: 1)))
        print("Notch contour passed: compact/expanded/AirPods/idle sizes, transitions, symmetry, bounds, capsule unchanged")
    }
}
