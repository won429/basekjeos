import AppKit

enum PlayerPresentationStyle: String, CaseIterable {
    case notch
    case dynamicIsland

    var title: String {
        switch self {
        case .notch: return "노치"
        case .dynamicIsland: return "다이나믹 아일랜드"
        }
    }

    var menuBarIcon: NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // Both styles share a display outline; the inset identifies the mode.
            let display = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 3.5, width: 17, height: 11),
                xRadius: 2, yRadius: 2
            )
            NSColor.black.setStroke()
            display.lineWidth = 1.4
            display.stroke()
            switch self {
            case .notch:
                let notch = NSBezierPath()
                notch.move(to: NSPoint(x: 6, y: 14.5))
                notch.line(to: NSPoint(x: 14, y: 14.5))
                notch.line(to: NSPoint(x: 14, y: 12.5))
                notch.curve(to: NSPoint(x: 12.5, y: 11),
                            controlPoint1: NSPoint(x: 14, y: 11.5),
                            controlPoint2: NSPoint(x: 13.5, y: 11))
                notch.line(to: NSPoint(x: 7.5, y: 11))
                notch.curve(to: NSPoint(x: 6, y: 12.5),
                            controlPoint1: NSPoint(x: 6.5, y: 11),
                            controlPoint2: NSPoint(x: 6, y: 11.5))
                notch.close()
                notch.fill()
            case .dynamicIsland:
                NSBezierPath(roundedRect: NSRect(x: 6, y: 10, width: 8, height: 2.4),
                             xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        image.isTemplate = true
        // Keep the product name in the accessibility label for menu bar
        // inspection and VoiceOver clients.
        image.accessibilityDescription = "Notch Music — \(title)"
        return image
    }
}
