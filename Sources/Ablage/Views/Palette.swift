import AppKit
import SwiftUI

/// The personal site's Preprint palette, including its accessible text and dark variants.
enum Palette {
    static let paper = color(0xFBFBF9, 0x141413)
    static let surface = color(0xFFFFFF, 0x1C1C1A)
    static let green = color(0x017A4E, 0x45E2A6)
    static let red = color(0xC8082F, 0xFF8B9D)
    static let blue = color(0x0052CC, 0x9DBFFF)

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct BrandMark: View {
    var body: some View {
        Image(nsImage: AppMark.image(size: 24))
            .foregroundStyle(Palette.green)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.green)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(24)
    }
}
