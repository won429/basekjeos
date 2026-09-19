import AppKit

enum ArtworkPalette {
    static var fallback: [NSColor] { [NSColor(srgbRed: 0.65, green: 0.65, blue: 0.65, alpha: 1)] }

    // Keep artwork/background colors intact; brighten only the meter's dark stops.
    static func waveformColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return fallback[0] }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance < 0.12 ? NSColor(srgbRed: 0.76, green: 0.76, blue: 0.78, alpha: 1) : color
    }

    private struct Bucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0

        var components: [Double] { [red, green, blue].map { $0 / Double(count) } }
        var color: NSColor {
            let rgb = components
            return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
    }

    static func colors(from image: NSImage) -> [NSColor] {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return fallback
        }
        // Convert embedded P3/gray/other profiles into explicit sRGB first.
        // Nearest-neighbor sampling avoids creating extra colors at hard edges.
        let columns = min(cgImage.width, 48)
        let rows = min(cgImage.height, 48)
        guard columns > 0, rows > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: columns, height: rows,
                  bitsPerComponent: 8, bytesPerRow: columns * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        var buckets: [Int: Bucket] = [:]
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = (row * columns + column) * 4
                let alpha = Double(pixels[offset + 3])
                guard alpha > 127 else { continue }
                let rgb = (0..<3).map { min(1, Double(pixels[offset + $0]) / alpha) }
                let bins = rgb.map { min(15, max(0, Int($0 * 16))) }
                let key = bins[0] * 256 + bins[1] * 16 + bins[2]
                var bucket = buckets[key, default: Bucket()]
                bucket.red += rgb[0]
                bucket.green += rgb[1]
                bucket.blue += rgb[2]
                bucket.count += 1
                buckets[key] = bucket
            }
        }
        let ranked = buckets.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }.map(\.value)
        guard !ranked.isEmpty else { return fallback }
        // Prefer visible colors over black borders when the cover contains them.
        // Entirely dark/gray covers retain their real tones, with no hue boost.
        let visible = ranked.filter { ($0.components.max() ?? 0) > 0.12 }
        let candidates = visible.isEmpty ? ranked : visible
        var selected: [Bucket] = []
        for candidate in candidates {
            let rgb = candidate.components
            let distinct = selected.allSatisfy { chosen in
                zip(rgb, chosen.components).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) } > 0.025
            }
            if distinct { selected.append(candidate) }
            if selected.count == 3 { break }
        }
        // Each stop is an average of pixels in the same RGB bucket. Never add a
        // complementary hue or raise saturation/brightness to fill the palette.
        return selected.map(\.color)
    }
}
