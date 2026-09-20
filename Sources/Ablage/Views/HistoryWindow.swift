import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var category = "all"
    @State private var exportError: String?
    private var entries: [JournalEntry] {
        state.journal.filter { entry in
            (category == "all" || (category == "undo" && entry.canUndo) || (category == "errors" && entry.kind == .error) || (category == "preview" && entry.kind == .simulated)) &&
            (query.isEmpty || [entry.from, entry.to ?? "", entry.rule, entry.message ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text("Everything accounted for.").font(.system(size: 24, weight: .semibold, design: .serif)) }
                    Text("Your last 500 actions, with a way back.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export…") { export() }
            }.padding(22)
            HStack {
                TextField("Search files, folders or rules", text: $query).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $category) { Text("All actions").tag("all"); Text("Can undo").tag("undo"); Text("Errors").tag("errors"); Text("Previews").tag("preview") }.frame(width: 180)
            }.padding(.horizontal, 22).padding(.bottom, 16)
            Divider()
            if entries.isEmpty { EmptyState(symbol: "clock", title: "Nothing here yet", detail: "Actions matching this view will appear here."); Spacer() }
            else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                ActivityRow(entry: entry).environmentObject(state)
                                if entry.kind == .error, let message = entry.message {
                                    Text(message).font(.caption).foregroundStyle(Palette.red).textSelection(.enabled).padding(.horizontal, 12)
                                }
                            }.padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(16)
                }
            }
            Divider()
            HStack { Text("\(entries.count) actions").foregroundStyle(.secondary); Spacer(); Text("Undo keeps both files if the original name is taken.").foregroundStyle(.secondary) }.font(.caption).padding(14)
            if let error = exportError { Text(error).foregroundStyle(Palette.red).padding(12) }
        }.background(Palette.paper).tint(Palette.blue).frame(minWidth: 660, minHeight: 420)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Ablage-activity.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; try encoder.encode(entries).write(to: url, options: .atomic); exportError = nil }
        catch { exportError = error.localizedDescription }
    }
}

@MainActor
final class HistoryController {
    static let shared = HistoryController()
    private var window: NSWindow?
    func show(state: AppState) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView().environmentObject(state)))
        window.title = "Ablage · Activity"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 740, height: 570))
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
