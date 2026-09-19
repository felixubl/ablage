import AppKit
import SwiftUI

enum Fonts {
    /// Cousine when it is installed, the system monospaced face otherwise.
    static func mono(_ size: CGFloat = 11) -> Font {
        NSFont(name: "Cousine", size: size) != nil ? .custom("Cousine", size: size) : .system(size: size, design: .monospaced)
    }
}
