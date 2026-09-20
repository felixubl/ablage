import QuickLook
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var filter = ""
    @State private var inboxPath = ""
    @State private var showActivity = false
    @State private var dropTarget = false

    init(showingActivity: Bool = false) { _showActivity = State(initialValue: showingActivity) }

    private var visibleItems: [InboxItem] {
        state.items.filter { item in
            (inboxPath.isEmpty || state.inboxes[safe: item.inboxIndex]?.path == inboxPath) &&
            (filter.isEmpty || item.name.localizedCaseInsensitiveContains(filter) || item.plan.searchText.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(18)
            Divider()
            if let error = state.configError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Settings") { state.openSettings() }
                }.font(.caption).foregroundStyle(Palette.red).padding(12).background(Palette.red.opacity(0.06))
            }
            if state.simulate {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye")
                    Text("Preview mode. See what your rules would do before moving a single file.")
                }.font(.caption).foregroundStyle(Palette.blue).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10).background(Palette.blue.opacity(0.05))
            }
            if let progress = state.progress {
                HStack {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))) {
                        Text("Filing \(progress.done) of \(progress.total)").font(.caption)
                    }
                    Button("Stop") { state.engine.cancelCurrentBatch() }.controlSize(.small).help("Stop after the current file")
                }.padding(12)
            }
            HStack {
                Picker("Show", selection: $showActivity) {
                    Text("Inbox · \(state.unsortedCount)").tag(false)
                    Text("Activity").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                Button { showActivity ? state.openHistory() : state.openReview() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help(showActivity ? "Full activity history" : "Open review window")
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            if showActivity { activity } else { inbox }
            Divider()
            footer.padding(14)
        }
        .frame(width: 440)
        .background(Palette.paper).tint(Palette.blue)
        .quickLookPreview($state.quickLook)
        .onChange(of: state.inboxes) { _, folders in if !folders.contains(where: { $0.path == inboxPath }) { inboxPath = "" } }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) { BrandMark(); Text("Ablage").font(.system(size: 26, weight: .semibold, design: .serif)) }
                    Text(state.paused ? "Taking a breather. Arrivals will wait." : "A little order, automatically.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Inboxes & rules…") { state.openSettings() }.keyboardShortcut(",")
                    Button("Review files…") { state.openReview() }.keyboardShortcut("r")
                    Button("Activity history…") { state.openHistory() }
                    Button("Search archive…") { state.openArchive() }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Find duplicates…") { state.openDuplicates() }
                    Divider()
                    ForEach(state.inboxes, id: \.path) { info in Button("Open " + info.label) { state.openInbox(info) } }
                    Divider()
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                    Button("Open log") { state.openLog() }
                    Button("Quit Ablage") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape").font(.system(size: 16)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Settings and more")
            }
            HStack(spacing: 14) {
                Label(state.paused ? "Paused" : "Watching \(state.inboxes.filter(\.enabled).count) inbox\(state.inboxes.filter(\.enabled).count == 1 ? "" : "es")", systemImage: state.paused ? "pause.circle" : "circle.fill")
                    .font(.caption).foregroundStyle(state.paused ? .secondary : Palette.green)
                Spacer()
                Toggle("Preview", isOn: $state.simulate).help("Simulation: record planned actions without changing files")
                Toggle("Pause", isOn: $state.paused).help("Hold new arrivals until resumed")
            }.toggleStyle(.switch).controlSize(.mini)
        }
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file, action or rule", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search") }
                Button { state.engine.refreshPreviews() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh file plans · ⌘R").keyboardShortcut("r")
            }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 18)
            if state.inboxes.count > 1 {
                Picker("Inbox", selection: $inboxPath) {
                    Text("All inboxes").tag("")
                    ForEach(state.inboxes, id: \.path) { Text($0.label).tag($0.path) }
                }.controlSize(.small).padding(.horizontal, 18).padding(.top, 10)
            }
            if visibleItems.isEmpty {
                EmptyState(symbol: filter.isEmpty ? "tray" : "magnifyingglass", title: filter.isEmpty ? "All clear." : "No matching files", detail: filter.isEmpty ? "New arrivals appear here. You can also drop files in to run your rules." : "Try a different filename, action or rule.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleItems.prefix(60)) { item in InboxRow(item: item).environmentObject(state) }
                    }.padding(.vertical, 8)
                }.frame(height: min(310, CGFloat(visibleItems.count) * 84 + 16))
                if visibleItems.count > 60 {
                    Button("Review all \(visibleItems.count) files…") { state.openReview() }.buttonStyle(.plain).font(.caption).foregroundStyle(Palette.blue).padding(.bottom, 10)
                }
            }
            HStack {
                Text("\(state.filedThisMonth) recent filings this month").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review…") { state.openReview() }.controlSize(.small)
                Button(state.simulate ? "Preview rules…" : "Sort now…") { state.confirmSortAll() }
                    .controlSize(.small).disabled(state.unsortedCount == 0 || state.progress != nil)
            }.padding(.horizontal, 18).padding(.bottom, 14)
        }
        .background(dropTarget ? Palette.green.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            state.file(files)
            return true
        } isTargeted: { dropTarget = $0 }
    }

    private var activity: some View {
        VStack(spacing: 0) {
            if state.journal.isEmpty {
                EmptyState(symbol: "clock", title: "Your filing story starts here", detail: "Every action has a record. Moves, tags and Trash can be undone.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(state.journal.prefix(12)) { ActivityRow(entry: $0).environmentObject(state) }
                    }.padding(.vertical, 8)
                }.frame(maxHeight: 340)
                Button("View full history…") { state.openHistory() }.buttonStyle(.plain).foregroundStyle(Palette.blue).font(.callout).padding(12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { state.newRule(from: nil) } label: { Label("New rule", systemImage: "plus") }
            Spacer()
            Button("Archive…") { state.openArchive() }
            Button("Settings…") { state.openSettings() }
        }.controlSize(.small)
    }
}

struct InboxRow: View {
    @EnvironmentObject private var state: AppState
    let item: InboxItem
    @State private var hovered = false
    @State private var showingPlan = false

    init(item: InboxItem, showingPlan: Bool = false) {
        self.item = item
        _showingPlan = State(initialValue: showingPlan)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.id)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(age).foregroundStyle(.secondary)
                    if state.inboxes.count > 1 { Text(state.inboxes[safe: item.inboxIndex]?.label ?? "").foregroundStyle(.secondary) }
                    if !item.isFolder { Text(size).foregroundStyle(.secondary) }
                }
                .font(.caption).lineLimit(1)
                Button { showingPlan.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: item.plan.symbol).frame(width: 13)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.plan.summary).lineLimit(2).multilineTextAlignment(.leading)
                            if !item.plan.additionalActions.isEmpty {
                                Text("Also: " + item.plan.additionalActions).font(.caption2)
                            }
                        }
                        Image(systemName: showingPlan ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.font(.caption).foregroundStyle(item.plan.color).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(showingPlan ? "Hide the full plan" : "Show the full plan")
                .accessibilityLabel("\(showingPlan ? "Hide" : "Show") full plan for \(item.name): \(item.plan.summary)")
                if showingPlan {
                    Divider().padding(.vertical, 6)
                    FilePlanDetails(item: item, showsFilename: false).padding(.bottom, 6)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.open(item) }
        .contextMenu { actions }
        .help(item.id)
    }

    @ViewBuilder private var actions: some View {
        if !item.isFolder { Button("Review & file…") { state.reviewDocument(item.id) } }
        if item.url.pathExtension.lowercased() == "pdf" { Button("Split scan…") { state.splitScan(item.url) } }
        Button(showingPlan ? "Hide planned action" : "Show planned action") { showingPlan.toggle() }
        Button("New rule from this file…") { state.newRule(from: item) }
        Button("Quick Look") { state.quickLook = item.url }
        Button("Reveal in Finder") { state.reveal(item) }
        Menu("Apply rule") {
            ForEach(Array(state.rules(for: item).enumerated()), id: \.offset) { index, name in
                Button(name) { state.apply(ruleIndex: index, to: item) }
            }
        }
        if !state.aiModels.isEmpty {
            Menu("Ask model") {
                ForEach(state.aiModels, id: \.self) { name in
                    Button(name) { state.ask(model: name, item) }
                }
            }
        }
        Divider()
        Button(state.simulate ? "Preview move to Trash" : "Move to Trash", role: .destructive) { state.trash(item) }
    }

    private var age: String {
        switch item.ageDays {
        case 0: return "today"
        case 1: return "1 day"
        case ..<30: return "\(item.ageDays) days"
        case ..<365: return "\(item.ageDays / 30) mo"
        default: return "\(item.ageDays / 365) y"
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }
}

struct ActivityRow: View {
    @EnvironmentObject private var state: AppState
    let entry: JournalEntry

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return f
    }()

    private var stamp: String {
        Calendar.current.isDateInToday(entry.date) ? Self.time.string(from: entry.date) : Self.dayAndTime.string(from: entry.date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(stamp).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if entry.canUndo {
                Button("Undo") { state.undo(entry) }.controlSize(.small)
            } else if entry.undone {
                Text("undone").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .opacity(entry.undone ? 0.5 : 1)
        .contentShape(Rectangle())
        .contextMenu { Button("Reveal in Finder") { state.reveal(entry) } }
    }

    private var name: String { URL(fileURLWithPath: entry.from).lastPathComponent }

    private var title: String {
        switch entry.kind {
        case .simulated: return name
        case .error: return "failed: \(name)"
        case .skipped: return "no match: \(name)"
        case .tagged: return "tagged \(name)"
        case .textLayer: return "text layer: \(name)"
        case .duplicate: return "duplicate: \(name)"
        case .trashed: return "trashed \(name)"
        case .moved: return name
        }
    }

    private var detail: String {
        var parts = [entry.rule]
        if let origin = entry.origin, origin != "rule" { parts.append(origin) }
        if let to = entry.to { parts.append("→ " + Paths.abbreviate(URL(fileURLWithPath: to).deletingLastPathComponent().path)) }
        if entry.kind == .simulated { parts.append(entry.to == nil ? (entry.message ?? "Preview") : "Would move") }
        else if let m = entry.message { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch entry.kind {
        case .moved: return "arrow.right.doc.on.clipboard"
        case .trashed, .duplicate: return "trash"
        case .tagged: return "tag"
        case .textLayer: return "doc.text.magnifyingglass"
        case .simulated: return "eye"
        case .skipped: return "questionmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .error: return Palette.red
        case .simulated, .skipped: return .secondary
        default: return Palette.green
        }
    }
}
