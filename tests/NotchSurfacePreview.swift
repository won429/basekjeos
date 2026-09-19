import AppKit
import SwiftUI

@main
struct NotchSurfacePreview {
    static func main() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 560,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.setFillColor(NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.94, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 560))
        context.translateBy(x: 0, y: 560)
        context.scaleBy(x: 2, y: -2)
        context.setFillColor(NSColor.black.cgColor)
        for (rect, progress) in [(CGRect(x: 98, y: 20, width: 204, height: 30), CGFloat(0)),
                                  (CGRect(x: 20, y: 80, width: 360, height: 180), CGFloat(1))] {
            let shape = PlayerSurfaceShape(style: .notch, expansionProgress: progress,
                                           compactHeight: 30, expandedCornerRadius: 28)
            context.addPath(shape.path(in: rect).cgPath)
            context.fillPath()
        }
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
