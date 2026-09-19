import AppKit

// Export a full-bleed texture into macOS icon geometry once, with real alpha.
// The supplied artwork must not contain another padded icon tile.
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
shape.addClip()
source.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
