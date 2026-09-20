import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.commands.contains(first) {
            exit(CLI.run(args))
        }
        AblageApp.main()
    }
}

struct AblageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(state)
        } label: {
            MenuBarLabel(count: state.unsortedCount, paused: state.paused)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let count: Int
    let paused: Bool

    // Icon only: a full menu bar on a notched MacBook hides wide items behind the notch.
    var body: some View {
        Image(systemName: paused ? "pause.circle" : (count == 0 ? "tray" : "tray.full"))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }
}
