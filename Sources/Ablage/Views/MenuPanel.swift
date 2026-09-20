import AppKit
import SwiftUI

/// A menu-bar surface that appears immediately and always grows down from its anchor.
final class MenuPanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var presentation = UUID()
    private var contentSize = NSSize.zero
    var onClose: (() -> Void)?
    var isShown: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
    }

    func show<Content: View>(_ content: Content, from button: NSStatusBarButton) {
        guard let anchorWindow = button.window, let screen = anchorWindow.screen else { return }
        anchor = button
        presentation = UUID()
        let current = presentation
        let naturalSize = NSHostingView(rootView: content).fittingSize
        let maximumHeight = max(1, min(anchorWindow.frame.minY, screen.visibleFrame.maxY) - screen.visibleFrame.minY - 8)
        let host = NSHostingView(rootView: MenuPanelSurface(content: content, naturalSize: naturalSize, maximumHeight: maximumHeight) { [weak self] size in
            // SwiftUI can lay out again after search or an asynchronous refresh. Keep the top fixed.
            DispatchQueue.main.async {
                guard let self, self.presentation == current, self.isShown else { return }
                self.resize(to: size)
            }
        })
        contentSize = host.fittingSize
        // Resizing belongs to this controller, so AppKit cannot move the anchor edge.
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(Self.frame(contentSize: contentSize, anchor: anchorWindow.frame, visibleFrame: screen.visibleFrame), display: false)
        host.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
    }

    func close() {
        guard isShown else { return }
        presentation = UUID()
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        panel.orderOut(nil)
        anchor?.highlight(false)
        removeMonitors()
        onClose?()
    }

    private func resize(to size: NSSize) {
        guard abs(size.height - contentSize.height) > 0.5 || abs(size.width - contentSize.width) > 0.5,
              let anchorWindow = anchor?.window, let screen = anchorWindow.screen else { return }
        contentSize = size
        panel.setFrame(Self.frame(contentSize: size, anchor: anchorWindow.frame, visibleFrame: screen.visibleFrame), display: true, animate: false)
    }

    /// AppKit screen coordinates are bottom-up. The upper edge never moves when the content changes.
    static func frame(contentSize: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width - 16)
        let top = min(anchor.minY, visibleFrame.maxY)
        let height = min(contentSize.height, max(1, top - visibleFrame.minY - 8))
        let x = min(max(anchor.midX - width / 2, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        return NSRect(x: x.rounded(), y: top - height, width: width, height: height)
    }

    private func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === panel || window.sheetParent === panel || window.parent === panel
    }

    private func installMonitors() {
        removeMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in self?.close() }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, !self.menuTracking else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === self.panel, self.panel.attachedSheet == nil {
                    self.close()
                    return nil
                }
            } else if !self.contains(event.window), event.window !== self.anchor?.window {
                self.close()
            }
            return event
        }) { monitors.append(monitor) }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.close()
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.close() })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false })
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown, !self.menuTracking, !self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return }
            // Let the status button's mouse-up toggle the panel, rather than close then reopen it.
            if let frame = self.anchor?.window?.frame, frame.contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons != 0 { return }
            self.close()
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers.removeAll()
        menuTracking = false
    }

    deinit { removeMonitors() }
}

struct MenuPanelSurface<Content: View>: View {
    let content: Content
    let naturalSize: CGSize
    let maximumHeight: CGFloat
    let onSizeChange: (CGSize) -> Void
    @State private var measuredHeight: CGFloat
    private let outline = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0)

    init(content: Content, naturalSize: CGSize, maximumHeight: CGFloat, onSizeChange: @escaping (CGSize) -> Void) {
        self.content = content
        self.naturalSize = naturalSize
        self.maximumHeight = maximumHeight
        self.onSizeChange = onSizeChange
        _measuredHeight = State(initialValue: naturalSize.height)
    }

    var body: some View {
        // Usually this does not scroll. On a short display, every control remains reachable.
        ScrollView(.vertical) {
            content.fixedSize(horizontal: true, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        measuredHeight = size.height
                        onSizeChange(CGSize(width: size.width, height: min(size.height, maximumHeight)))
                    }
                })
        }
        .scrollIndicators(measuredHeight > maximumHeight ? .automatic : .hidden)
        .frame(width: naturalSize.width, height: min(measuredHeight, maximumHeight))
        .background(Palette.paper)
        .clipShape(outline)
        .overlay(outline.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
        .transaction { $0.animation = nil }
    }
}
