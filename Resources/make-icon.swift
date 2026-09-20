import AppKit

// Run via `make icons`; AppMark.swift is the vector master shared with the app.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let tile = NSBezierPath(roundedRect: NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84), xRadius: size * 0.20, yRadius: size * 0.20)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = size * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor(srgbRed: 251 / 255, green: 251 / 255, blue: 249 / 255, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.07).setStroke()
    tile.lineWidth = max(0.5, size * 0.0015)
    tile.stroke()
    let context = graphics.cgContext
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    AppMark.draw(in: CGRect(x: size * 0.17, y: size * 0.17, width: size * 0.66, height: size * 0.66),
                 color: NSColor(srgbRed: 1 / 255, green: 122 / 255, blue: 78 / 255, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(pixels).write(to: out.appendingPathComponent("icon_\(name).png"))
}
