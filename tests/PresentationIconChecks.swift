import AppKit

@main
struct PresentationIconChecks {
    static func main() throws {
        let notch = PlayerPresentationStyle.notch.menuBarIcon
        let island = PlayerPresentationStyle.dynamicIsland.menuBarIcon
        for image in [notch, island] {
            precondition(image.isTemplate)
            precondition(image.size == NSSize(width: 20, height: 18))
            precondition(image.accessibilityDescription?.contains("Notch Music") == true)
        }
        precondition(notch.tiffRepresentation != island.tiffRepresentation)
        if let path = CommandLine.arguments.dropFirst().first {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 180,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 400, height: 180).fill()
            notch.draw(in: NSRect(x: 10, y: 9, width: 180, height: 162))
            island.draw(in: NSRect(x: 210, y: 9, width: 180, height: 162))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        print("Presentation icons passed: distinct shapes, template rendering, size and accessibility")
    }
}
