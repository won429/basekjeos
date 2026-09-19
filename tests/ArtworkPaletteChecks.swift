import AppKit

@main
struct ArtworkPaletteChecks {
    static func main() {
        let gray = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        let muted = NSColor(srgbRed: 0.60, green: 0.50, blue: 0.45, alpha: 1)
        let dark = NSColor(srgbRed: 0.04, green: 0.03, blue: 0.02, alpha: 1)
        for source in [gray, muted, dark, NSColor.black] {
            let palette = ArtworkPalette.colors(from: fixture { _, _ in source })
            precondition(palette.count == 1)
            precondition(distance(palette[0], source) < 0.015, "Do not invent hue, saturation or brightness")
        }
        for source in [dark, NSColor.black, NSColor(srgbRed: 0.08, green: 0.1, blue: 0.24, alpha: 1)] {
            let visible = ArtworkPalette.waveformColor(source).usingColorSpace(.sRGB)!
            precondition(visible.redComponent > 0.7 && visible.greenComponent > 0.7 && visible.blueComponent > 0.7,
                         "Dark meter colors must become light gray")
        }
        precondition(ArtworkPalette.waveformColor(muted) == muted, "Keep readable album colors unchanged")
        let colors = [NSColor(srgbRed: 0.8, green: 0.15, blue: 0.1, alpha: 1),
                      NSColor(srgbRed: 0.1, green: 0.7, blue: 0.25, alpha: 1),
                      NSColor(srgbRed: 0.12, green: 0.2, blue: 0.8, alpha: 1)]
        let palette = ArtworkPalette.colors(from: fixture { x, _ in colors[x / 16] })
        precondition(palette.count == 3)
        for color in palette {
            precondition(colors.contains { distance($0, color) < 0.015 }, "Every stop comes from the cover")
        }
        let transparentPink = NSColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 0)
        let transparency = ArtworkPalette.colors(from: fixture { x, _ in x < 24 ? transparentPink : gray })
        precondition(transparency.count == 1 && distance(transparency[0], gray) < 0.015)
        let empty = ArtworkPalette.colors(from: fixture { _, _ in .clear })
        precondition(empty.count == 1 && distance(empty[0], ArtworkPalette.fallback[0]) < 0.015)
        print("PASS: grayscale, muted/dark/black covers, three cover colors, transparency, neutral fallback")
    }

    static func fixture(_ pixel: (Int, Int) -> NSColor) -> NSImage {
        var pixels = [UInt8]()
        for y in 0..<48 { for x in 0..<48 {
            let c = pixel(x, y).usingColorSpace(.sRGB)!
            pixels += [c.redComponent * c.alphaComponent, c.greenComponent * c.alphaComponent,
                       c.blueComponent * c.alphaComponent, c.alphaComponent].map { UInt8(($0 * 255).rounded()) }
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 48 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cgImage, size: NSSize(width: 48, height: 48))
    }

    static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.usingColorSpace(.sRGB)!, b = rhs.usingColorSpace(.sRGB)!
        return max(abs(a.redComponent - b.redComponent),
                   max(abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)))
    }
}
