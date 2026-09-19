import AppKit

// Renders the app icon: a tray symbol on a rounded blue square, exported as an iconset.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.50, blue: 0.96, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.78, alpha: 1))!
        .draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2 + size * 0.02)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(pixels).write(to: out.appendingPathComponent("icon_\(name).png"))
}
