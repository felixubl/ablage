import AppKit
import Combine
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.commands.contains(first) {
            exit(CLI.run(args))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let panel = MenuPanel()
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenus.install(appName: "Ablage")
        let state = AppState.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "ablage.icon"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Ablage")
        statusItem = item
        subscription = state.$paused.combineLatest(state.$items).sink { [weak self] paused, items in
            let button = self?.statusItem?.button
            button?.image = AppMark.image()
            button?.appearsDisabled = paused
            let count = items.filter { $0.status == .unsorted }.count
            button?.toolTip = paused ? "Ablage · Paused" : "Ablage · \(count) unsorted files"
        }
        NotificationCenter.default.addObserver(self, selector: #selector(closePanel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        state.start()
        if CommandLine.arguments.contains("--duplicates") { state.openDuplicates() }
    }

    @objc private func togglePanel() {
        if panel.isShown { panel.close() }
        else if let button = statusItem?.button { panel.show(PanelView().environmentObject(AppState.shared), from: button) }
    }

    @objc private func closePanel() { panel.close() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.openReview()
        return true
    }
}
