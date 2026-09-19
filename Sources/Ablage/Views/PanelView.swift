import QuickLook
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var state: AppState
    @State private var filter = ""
    private let maxRows = 150

    private var visibleItems: [InboxItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return state.items }
        return state.items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            Divider()
            inbox
            Divider()
            activity
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 400)
        .quickLookPreview($state.quickLook)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ablage").font(.headline)
                    ForEach(state.inboxes, id: \.path) { info in
                        Button(info.label) { state.openInbox(info) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Simulate", isOn: $state.simulate)
                Toggle("Pause", isOn: $state.paused)
            }
            .toggleStyle(.switch).controlSize(.mini)
            if let error = state.configError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if state.simulate {
                Text("Simulation: rules only report what they would do. Turn it off once the activity list looks right.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let p = state.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text("Sorting \(p.done) of \(p.total)").font(.caption)
                }
            }
            Text(stats).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stats: String {
        var parts = ["\(state.filedThisMonth) filed this month"]
        if state.examples > 0 { parts.append("\(state.examples) learned examples") }
        return parts.joined(separator: " · ")
    }

    // MARK: Inbox

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(inboxTitle).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Review…") { state.openReview() }.controlSize(.small).disabled(state.unsortedCount == 0)
                Button("Sort now…") { state.confirmSortAll() }
                    .controlSize(.small).disabled(state.unsortedCount == 0 || state.progress != nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if state.items.count > 12 {
                TextField("Filter", text: $filter, prompt: Text("Filter by name"))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if state.items.isEmpty {
                Text("Inbox is empty. Drop files here to file them by the rules.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else if visibleItems.isEmpty {
                Text("Nothing matches the filter.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                let items = visibleItems
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.prefix(maxRows).enumerated()), id: \.element.id) { index, item in
                            if state.inboxes.count > 1, index == 0 || items[index - 1].inboxIndex != item.inboxIndex {
                                Text(state.inboxes[item.inboxIndex].label).font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                            }
                            InboxRow(item: item).environmentObject(state)
                        }
                        if items.count > maxRows {
                            Text("and \(items.count - maxRows) more").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            state.file(files)
            return true
        }
    }

    private var inboxTitle: String {
        var parts = ["Inbox"]
        if state.unsortedCount > 0 { parts.append("\(state.unsortedCount) unsorted") }
        if state.settlingCount > 0 { parts.append("\(state.settlingCount) arriving") }
        return parts.joined(separator: " · ")
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity").font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
            if state.journal.isEmpty {
                Text("Nothing sorted yet.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                ForEach(state.journal.prefix(8)) { entry in
                    ActivityRow(entry: entry).environmentObject(state)
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("New rule…") { state.newRule(from: nil) }
            Button("Rules…") { state.openConfig() }
            Button("Log") { state.openLog() }
            Toggle("Launch at login", isOn: $state.launchAtLogin).toggleStyle(.checkbox)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

struct InboxRow: View {
    @EnvironmentObject private var state: AppState
    let item: InboxItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isFolder ? "folder" : "doc")
                .foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(age).foregroundStyle(.secondary)
                    if !item.isFolder { Text(size).foregroundStyle(.secondary) }
                    if item.status == .settling {
                        Text("arriving").foregroundStyle(.orange)
                    } else if let preview = item.preview {
                        Text(previewLabel(preview)).foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.open(item) }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
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
        Button("Move to Trash") { state.trash(item) }
    }

    private func previewLabel(_ preview: String) -> String {
        if preview == "?" { return "→ needs OCR" }
        if preview.hasPrefix("learned:") { return "→ \(preview.dropFirst(8)) (learned)" }
        if preview.hasPrefix("AI?:") { return "→ \(preview.dropFirst(4)) on request" }
        if preview.hasPrefix("AI:") { return "→ asks \(preview.dropFirst(3))" }
        return "→ \(preview)"
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
        case .simulated: return "would \(entry.to == nil ? (entry.message ?? "act on") : "move") \(name)"
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
        if entry.kind != .simulated, let m = entry.message { parts.append(m) }
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
        case .error: return .red
        case .simulated, .skipped: return .secondary
        default: return .accentColor
        }
    }
}
