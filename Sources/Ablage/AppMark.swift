import AppKit

/// One vector master for the menu bar, in-app mark and app icon. Coordinates use a 24-point square.
enum AppMark {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 24, y: rect.height / 24)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private static var path: CGPath {
        let p = CGMutablePath()
        // An empty, open filing tray in perspective. No upright sheet or printer silhouette.
        p.move(to: CGPoint(x: 3, y: 14))
        p.addLine(to: CGPoint(x: 6.5, y: 6))
        p.addQuadCurve(to: CGPoint(x: 8, y: 5), control: CGPoint(x: 7, y: 5))
        p.addLine(to: CGPoint(x: 16, y: 5))
        p.addQuadCurve(to: CGPoint(x: 17.5, y: 6), control: CGPoint(x: 17, y: 5))
        p.addLine(to: CGPoint(x: 21, y: 14))
        p.addLine(to: CGPoint(x: 21, y: 18))
        p.addQuadCurve(to: CGPoint(x: 19, y: 20), control: CGPoint(x: 21, y: 20))
        p.addLine(to: CGPoint(x: 5, y: 20))
        p.addQuadCurve(to: CGPoint(x: 3, y: 18), control: CGPoint(x: 3, y: 20))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3, y: 14))
        p.addLine(to: CGPoint(x: 8, y: 14))
        p.addLine(to: CGPoint(x: 9.5, y: 17))
        p.addLine(to: CGPoint(x: 14.5, y: 17))
        p.addLine(to: CGPoint(x: 16, y: 14))
        p.addLine(to: CGPoint(x: 21, y: 14))
        return p
    }
}
