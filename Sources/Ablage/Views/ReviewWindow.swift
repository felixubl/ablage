import AppKit
import SwiftUI

/// A table of everything waiting, with what would happen to each file, for filing in bulk.
struct ReviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = Set<String>()
    @State private var filter = ""

    private var rows: [InboxItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let unsorted = state.items.filter { $0.status == .unsorted }
        guard !needle.isEmpty else { return unsorted }
        return unsorted.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var selected: [InboxItem] { rows.filter { selection.contains($0.id) } }
    private var suggested: [InboxItem] { rows.filter(\.hasSuggestion) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter by name")).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(rows.count) waiting · \(suggested.count) with a suggestion · \(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Table(rows, selection: $selection) {
                TableColumn("File") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn("Inbox") { item in
                    Text(state.inboxes.indices.contains(item.inboxIndex) ? state.inboxes[item.inboxIndex].label : "").foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 140)
                TableColumn("Age") { item in Text(Self.age(item.ageDays)).foregroundStyle(.secondary) }.width(60)
                TableColumn("Size") { item in
                    Text(item.isFolder ? "" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Would") { item in Text(Self.label(item.preview)).foregroundStyle(item.hasSuggestion ? Color.accentColor : .secondary) }
                    .width(min: 120, ideal: 200)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = rows.filter { ids.contains($0.id) }
                if let first = items.first {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                    Button("Quick Look") { state.quickLook = first.url }
                    Menu("Apply rule") {
                        ForEach(state.rules(for: first), id: \.self) { name in
                            Button(name) { state.apply(ruleNamed: name, to: items) }
                        }
                    }
                    Divider()
                    Button("Move to Trash") { state.trash(items) }
                }
            } primaryAction: { ids in
                if let item = rows.first(where: { ids.contains($0.id) }) { state.quickLook = item.url }
            }
            Divider()
            HStack {
                if let p = state.progress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 160)
                    Text("\(p.done) of \(p.total)").font(.caption).foregroundStyle(.secondary)
                } else if state.simulate {
                    Text("Simulation is on: filing only reports what would happen.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select suggested") { selection = Set(suggested.map(\.id)) }.disabled(suggested.isEmpty)
                Menu("Apply rule to selection") {
                    if let first = selected.first {
                        ForEach(state.rules(for: first), id: \.self) { name in
                            Button(name) { state.apply(ruleNamed: name, to: selected) }
                        }
                    }
                }
                .disabled(selected.isEmpty).fixedSize()
                Button("Trash selection") { state.trash(selected) }.disabled(selected.isEmpty)
                Button("File selection") { state.sort(selected) }.disabled(selected.isEmpty || state.progress != nil).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 420)
        .quickLookPreview($state.quickLook)
        .onChange(of: state.items) { _, items in
            let ids = Set(items.map(\.id))
            selection = selection.intersection(ids)
        }
    }

    static func label(_ preview: String?) -> String {
        guard let preview else { return "" }
        if preview == "?" { return "needs OCR" }
        if preview.hasPrefix("learned:") { return "\(preview.dropFirst(8)) (learned)" }
        if preview.hasPrefix("AI?:") { return "\(preview.dropFirst(4)) on request" }
        if preview.hasPrefix("AI:") { return "asks \(preview.dropFirst(3))" }
        return preview
    }

    static func age(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "1 day"
        case ..<30: return "\(days) days"
        case ..<365: return "\(days / 30) mo"
        default: return "\(days / 365) y"
        }
    }
}

@MainActor
final class ReviewController {
    static let shared = ReviewController()
    private var window: NSWindow?

    func show(state: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: ReviewView().environmentObject(state))
        let window = NSWindow(contentViewController: controller)
        window.title = "Review inbox"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
