import AppKit
import SwiftUI

/// A table of everything waiting, with what would happen to each file, for filing in bulk.
struct ReviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = Set<String>()
    @State private var filter = ""
    @State private var inboxPath = ""
    @State private var mode = "all"
    @State private var order = "newest"
    @FocusState private var searchFocused: Bool

    init(selection: Set<String> = []) { _selection = State(initialValue: selection) }

    private var rows: [InboxItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return state.items.filter { item in
            item.status == .unsorted &&
            (inboxPath.isEmpty || state.inboxes[safe: item.inboxIndex]?.path == inboxPath) &&
            (mode == "all" || (mode == "suggested" ? item.hasSuggestion : !item.hasSuggestion)) &&
            (needle.isEmpty || item.name.localizedCaseInsensitiveContains(needle) || item.plan.searchText.localizedCaseInsensitiveContains(needle))
        }.sorted { left, right in
            switch order {
            case "name": return left.name.localizedStandardCompare(right.name) == .orderedAscending
            case "largest": return left.size == right.size ? left.id < right.id : left.size > right.size
            case "oldest": return left.added == right.added ? left.id < right.id : left.added < right.added
            default: return left.added == right.added ? left.id < right.id : left.added > right.added
            }
        }
    }
    private var commonRules: [String] {
        guard let first = selected.first else { return [] }
        return state.rules(for: first).filter { name in selected.allSatisfy { state.rules(for: $0).contains(name) } }
    }

    private var selected: [InboxItem] { rows.filter { selection.contains($0.id) } }
    private var suggested: [InboxItem] { rows.filter(\.hasSuggestion) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Make room for what’s next.").font(.system(size: 24, weight: .semibold, design: .serif)) }
                    Text("Review the plan. Select a few files, or work through an entire inbox.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Find duplicates…") { state.openDuplicates() }
                Button("Archive…") { state.openArchive() }
                Button("Inboxes & rules…") { state.openSettings() }
            }.padding(20)
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Find a file, action or rule")).textFieldStyle(.roundedBorder).frame(maxWidth: 260).focused($searchFocused)
                Button { state.engine.refreshPreviews() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh file plans · ⌘R").keyboardShortcut("r")
                Spacer()
                Text("\(rows.count) waiting · \(suggested.count) with a suggestion · \(selected.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            HStack {
                Picker("Inbox", selection: $inboxPath) {
                    Text("All inboxes").tag("")
                    ForEach(state.inboxes, id: \.path) { Text($0.label).tag($0.path) }
                }
                Picker("Show", selection: $mode) { Text("All files").tag("all"); Text("Suggested").tag("suggested"); Text("Needs a rule").tag("unmatched") }
                Picker("Sort", selection: $order) { Text("Newest first").tag("newest"); Text("Oldest first").tag("oldest"); Text("Name").tag("name"); Text("Largest first").tag("largest") }
            }.padding(.horizontal, 12).padding(.bottom, 12)
            Table(rows, selection: $selection) {
                TableColumn("File") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 260, ideal: 400)
                TableColumn("Inbox") { item in
                    Text(state.inboxes.indices.contains(item.inboxIndex) ? state.inboxes[item.inboxIndex].label : "").foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110, max: 140)
                TableColumn("Age") { item in Text(Self.age(item.ageDays)).foregroundStyle(.secondary) }.width(60)
                TableColumn("Size") { item in
                    Text(item.isFolder ? "" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Planned action") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.plan.symbol).frame(width: 14)
                        Text(item.plan.summary).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(item.plan.color).help(item.plan.fullDescription)
                }.width(min: 220, ideal: 320)

            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = rows.filter { ids.contains($0.id) }
                if let first = items.first {
                    if items.count == 1, !first.isFolder { Button("Review & file…") { state.reviewDocument(first.id) } }
                    if items.count == 1, first.url.pathExtension.lowercased() == "pdf" { Button("Split scan…") { state.splitScan(first.url) } }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                    Button("Quick Look") { state.quickLook = first.url }
                    Menu("Apply rule") {
                        ForEach(state.rules(for: first).filter { name in items.allSatisfy { state.rules(for: $0).contains(name) } }, id: \.self) { name in
                            Button(name) { state.apply(ruleNamed: name, to: items) }
                        }
                    }
                    Divider()
                    Button(state.simulate ? "Preview move to Trash" : "Move to Trash", role: .destructive) { state.trash(items) }
                }
            } primaryAction: { ids in
                if let item = rows.first(where: { ids.contains($0.id) }) { state.quickLook = item.url }
            }
            .overlay {
                if rows.isEmpty { EmptyState(symbol: "tray", title: "Nothing waiting here", detail: "Try another inbox or clear your filters.").allowsHitTesting(false) }
            }
            if selected.count == 1, let item = selected.first {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !item.isFolder { Button("Review & file…") { state.reviewDocument(item.id) } }
                        FilePlanDetails(item: item, compact: true)
                    }.padding(16)
                }
                    .frame(maxWidth: .infinity).frame(height: 190).background(Palette.surface)
            } else {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Select a file to see its full destination, filename, tags and matching rule.")
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
            }
            Divider()
            HStack {
                if let p = state.progress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 160)
                    Text("\(p.done) of \(p.total)").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { state.engine.cancelCurrentBatch() }.help("Stop after the current file")
                } else if state.simulate {
                    Text("Simulation is on: filing only reports what would happen.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select suggested") { selection = Set(suggested.map(\.id)) }.disabled(suggested.isEmpty)
                Menu("Apply rule to selection") {
                    if !commonRules.isEmpty {
                        ForEach(commonRules, id: \.self) { name in
                            Button(name) { state.apply(ruleNamed: name, to: selected) }
                        }
                    }
                }
                .disabled(selected.isEmpty || commonRules.isEmpty || state.progress != nil).fixedSize()
                Button(state.simulate ? "Preview Trash" : "Trash") { state.trash(selected) }.disabled(selected.isEmpty || state.progress != nil)
                Button(state.simulate ? "Preview selection" : "File selection") { state.sort(selected) }.disabled(selected.isEmpty || state.progress != nil).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 850, minHeight: 480)
        .background(Palette.paper).tint(Palette.blue)
        .background {
            Group {
                Button("Select all") { selection = Set(rows.map(\.id)) }.keyboardShortcut("a")
                Button("Find") { searchFocused = true }.keyboardShortcut("f")
                Button("Quick Look") { if let first = selected.first { state.quickLook = first.url } }.keyboardShortcut(.space, modifiers: [])
            }.hidden()
        }
        .onChange(of: filter) { _, _ in selection.removeAll() }
        .onChange(of: inboxPath) { _, _ in selection.removeAll() }
        .onChange(of: mode) { _, _ in selection.removeAll() }
        .quickLookPreview($state.quickLook)
        .onChange(of: state.items) { _, items in
            let ids = Set(items.map(\.id))
            selection = selection.intersection(ids)
        }
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
        window.title = "Ablage · Review"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
