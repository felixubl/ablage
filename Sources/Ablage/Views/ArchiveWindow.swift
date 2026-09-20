import AppKit
import SwiftUI

extension Notification.Name { static let ablageArchiveChanged = Notification.Name("at.fubl.ablage.archive.changed") }

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var query = LibraryQuery()
    @Published var documents: [LibraryDocument] = []
    @Published var views: [SavedLibraryView] = []
    @Published var pairs: [DuplicatePair] = []
    @Published var issues: [IntegrityIssue] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var customFields: [String] = []
    @Published var canStop = false
    private var cancellation = WorkCancellation()
    private var searchGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    let library: DocumentLibrary
    init(library: DocumentLibrary = .shared) { self.library = library; search(); loadViews() }

    func search(debounce: Bool = false) {
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        let query = self.query, library = self.library
        searchTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled else { return }
                let documents = try await Task.detached(priority: .userInitiated) { try library.search(query) }.value
                guard self.searchGeneration == generation, !Task.isCancelled else { return }
                self.documents = documents
                self.customFields = Array(Set(customFields + documents.flatMap { $0.metadata.fields.map(\.key) })).sorted()
            } catch is CancellationError {} catch { if self.searchGeneration == generation { self.error = error.localizedDescription } }
        }
    }
    func loadViews() { do { views = try library.savedViews() } catch { self.error = error.localizedDescription } }
    func saveView(name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { views.append(SavedLibraryView(name: name, query: query)); try library.saveViews(views) } catch { self.error = error.localizedDescription }
    }
    func deleteView(_ id: UUID) { do { views.removeAll { $0.id == id }; try library.saveViews(views) } catch { self.error = error.localizedDescription } }
    func stop() { cancellation.cancel() }

    func refresh(readScans: Bool = false) {
        guard !busy else { return }
        busy = true; canStop = true; error = nil; status = readScans ? "Indexing documents, including on-device text recognition…" : "Indexing document contents…"
        cancellation = WorkCancellation(); let token = cancellation, library = self.library
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try ArchiveIndexer.refresh(library: library, config: ConfigStore.load(), readScans: readScans, cancellation: token)
                }.value
                status = "\(report.indexed) documents indexed" + (report.cancelled ? " · stopped" : "")
                if !report.errors.isEmpty { error = report.errors.prefix(5).joined(separator: "\n") }
                search()
            } catch { self.error = error.localizedDescription }
            busy = false; canStop = false
        }
    }
    func findDuplicates() {
        guard !busy else { return }
        busy = true; canStop = true; error = nil; status = "Comparing checksums and document text…"
        cancellation = WorkCancellation(); let token = cancellation, library = self.library
        Task {
            do {
                pairs = try await Task.detached(priority: .utility) { DuplicateFinder.find(try library.all().filter { FileManager.default.fileExists(atPath: $0.path) }, cancellation: token) }.value
                status = "\(pairs.count) possible duplicate pairs" + (token.isCancelled ? " · stopped" : "")
            } catch { self.error = error.localizedDescription }
            busy = false; canStop = false
        }
    }
    func checkIntegrity() {
        guard !busy else { return }
        busy = true; canStop = true; error = nil; status = "Checking files and preserved originals…"
        cancellation = WorkCancellation(); let token = cancellation, library = self.library
        Task {
            do {
                let result = try await Task.detached(priority: .utility) { () -> (Int, [IntegrityIssue]) in
                    let documents = try library.all(); return (documents.count, IntegrityChecker.check(documents, cancellation: token))
                }.value
                issues = result.1
                status = token.isCancelled ? "Check stopped · results are incomplete" : "\(result.0) documents checked · \(issues.count) to review"
            } catch { self.error = error.localizedDescription }
            busy = false; canStop = false
        }
    }
    func acceptChange(_ document: LibraryDocument) {
        let alert = NSAlert(); alert.messageText = "Accept this file’s current contents?"
        alert.informativeText = "Use this after an intentional edit to \(document.name). Future checks will compare against its current contents."
        alert.addButton(withTitle: "Accept current contents"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; let library = self.library
        Task {
            do { try await Task.detached { try library.index(document.url, config: ConfigStore.load(), authorizedChange: true) }.value }
            catch { self.error = error.localizedDescription }
            busy = false; checkIntegrity()
        }
    }
    func exportOriginal(_ document: LibraryDocument) {
        let source = URL(fileURLWithPath: document.original)
        let panel = NSSavePanel(); panel.nameFieldStringValue = document.name; panel.prompt = "Save original copy"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        busy = true
        Task {
            do {
                try await Task.detached {
                    guard Hashing.digest(source)?.hex == source.deletingPathExtension().lastPathComponent else { throw ConfigError(message: "The preserved original is unavailable or changed.") }
                    let temporary = target.deletingLastPathComponent().appendingPathComponent(".ablage-export-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: target) }
                }.value
                status = "Original saved to " + Paths.abbreviate(target.path)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ArchiveView: View {
    @ObservedObject var model: ArchiveModel
    @EnvironmentObject var state: AppState
    @State private var section = "documents"
    @State private var selected: String?
    @State private var selectedPair: String?
    @State private var selectedIssue: String?
    @State private var viewName = ""
    @State private var savingView = false
    @State private var filters = false
    @FocusState private var searchFocused: Bool
    init(model: ArchiveModel, section: String = "documents", selected: String? = nil, selectedPair: String? = nil, selectedIssue: String? = nil, filters: Bool = false) {
        self.model = model; _section = State(initialValue: section); _selected = State(initialValue: selected)
        _selectedPair = State(initialValue: selectedPair); _selectedIssue = State(initialValue: selectedIssue); _filters = State(initialValue: filters)
    }
    private var document: LibraryDocument? { model.documents.first { $0.id == selected } }
    private var pair: DuplicatePair? { model.pairs.first { $0.id == selectedPair } }
    private var issue: IntegrityIssue? { model.issues.first { $0.id == selectedIssue } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find it again.").font(.system(size: 24, weight: .semibold, design: .serif))
                    Text("Your documents, in their own folders.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Archive section", selection: $section) {
                    Text("Documents").tag("documents"); Text("Duplicates").tag("duplicates"); Text("Integrity").tag("integrity")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 310)
                Menu {
                    Button("Refresh index") { model.refresh() }
                    Button("Read scans and refresh…") { model.refresh(readScans: true) }
                    Button("Choose archive folders…") { state.openSettings(section: "archive") }
                } label: { Image(systemName: "arrow.clockwise") }.fixedSize().disabled(model.busy).help("Index and archive folders")
            }.padding(20)
            Divider()
            if section == "documents" { documents }
            else if section == "duplicates" { duplicates }
            else { integrity }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.error { Text(error).font(.callout).foregroundStyle(Palette.red).textSelection(.enabled).lineLimit(4) }
                HStack {
                    if model.busy { ProgressView().controlSize(.small); if model.canStop { Button("Stop") { model.stop() } } }
                    Text(model.status.isEmpty ? "Refresh the index after changing files outside Ablage." : model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if section == "documents" { Text("\(model.documents.count) documents").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(12)
        }.frame(minWidth: 930, minHeight: 600).background(Palette.paper).tint(Palette.blue)
        .background {
            Button("Find in archive") { section = "documents"; searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .alert("Save this search", isPresented: $savingView) {
            TextField("Name", text: $viewName)
            Button("Save") { model.saveView(name: viewName); viewName = "" }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The search and filters are saved together. Results update as your archive grows.") }
        .onChange(of: model.query) { _, _ in model.search(debounce: true) }
        .onReceive(NotificationCenter.default.publisher(for: .ablageArchiveChanged)) { _ in model.search() }
    }

    private var documents: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search names, document contents and fields", text: $model.query.text).textFieldStyle(.roundedBorder).focused($searchFocused)
                Button { filters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                Menu("Saved views") {
                    ForEach(model.views) { view in Button(view.name) { model.query = view.query } }
                    Divider()
                    Button("Save current search…") { savingView = true }
                    if !model.views.isEmpty {
                        Menu("Delete saved view") { ForEach(model.views) { view in Button(view.name, role: .destructive) { model.deleteView(view.id) } } }
                    }
                }.fixedSize()
            }.padding(12)
            if filters {
                VStack(spacing: 10) {
                    HStack { TextField("Sender", text: $model.query.correspondent); TextField("Document type", text: $model.query.type); TextField("Finder tag", text: $model.query.tag) }
                    HStack { TextField("Folder path (optional)", text: $model.query.folder); TextField("From YYYY-MM-DD", text: $model.query.fromDate); TextField("To YYYY-MM-DD", text: $model.query.toDate) }
                    HStack {
                        Picker("Field", selection: $model.query.field) {
                            Text("Any field").tag("")
                            Text("Invoice number").tag("invoice_number"); Text("Amount").tag("amount"); Text("Currency").tag("currency"); Text("Due date").tag("due_date")
                            ForEach(Array(Set(model.customFields + (model.query.field.hasPrefix("field.") ? [String(model.query.field.dropFirst(6))] : []))).sorted(), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag("field." + $0) }
                        }
                        TextField("Contains", text: $model.query.fieldValue).disabled(model.query.field.isEmpty)
                        Button("Clear filters") { let text = model.query.text; model.query = LibraryQuery(); model.query.text = text }
                    }
                }.textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 12)
            }
            HSplitView {
                List(model.documents, selection: $selected) { document in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text([document.date, document.metadata.correspondent, document.metadata.documentType].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text(Paths.abbreviate(document.url.deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !model.query.text.isEmpty { Text(document.text.prefix(180)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }.padding(.vertical, 5).tag(document.id)
                }.frame(minWidth: 270, idealWidth: 330, maxWidth: 430)
                if let document {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Review & edit…") { state.reviewDocument(document.path) }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                            Spacer()
                            Menu {
                                Button("Open") { NSWorkspace.shared.open(document.url) }
                                if document.url.pathExtension.lowercased() == "pdf" { Button("Split scan…") { state.splitScan(document.url) } }
                                if !document.original.isEmpty { Button("Save original copy…") { model.exportOriginal(document) } }
                            } label: { Image(systemName: "ellipsis.circle") }.fixedSize()
                        }.padding(12)
                        DocumentPreview(url: document.url, text: document.text).id(document.digest)
                    }
                } else { EmptyState(symbol: "doc.text.magnifyingglass", title: model.documents.isEmpty ? "Your archive starts here" : "Choose a document", detail: model.documents.isEmpty ? "Filed documents appear automatically. Add existing folders in Settings → Archive, then refresh the index." : "Search inside documents, review their details or open them in Finder.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }

    private var duplicates: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Identical bytes are exact copies. Similar text may describe different documents—compare both.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Scan folders for identical files…") { state.openDuplicates() }
                Button("Compare archive documents") { model.findDuplicates() }.disabled(model.busy)
            }.padding(12)
            HSplitView {
                List(model.pairs, selection: $selectedPair) { pair in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(pair.exact ? "Exact copies" : "Similar text · \(Int(pair.similarity * 100))%", systemImage: pair.exact ? "doc.on.doc" : "text.magnifyingglass").foregroundStyle(pair.exact ? Palette.blue : .secondary)
                        Text(pair.first.name).lineLimit(1); Text(pair.second.name).lineLimit(1).foregroundStyle(.secondary)
                    }.font(.callout).padding(.vertical, 5).tag(pair.id)
                }.frame(minWidth: 230, idealWidth: 260, maxWidth: 330)
                if let pair {
                    HStack(spacing: 1) { duplicateDocument(pair.first, keeping: pair.second); duplicateDocument(pair.second, keeping: pair.first) }
                } else { EmptyState(symbol: "doc.on.doc", title: "Keep the copy you want", detail: "Refresh the archive index, then find duplicates across your documents. Nothing is removed automatically.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }
    private func duplicateDocument(_ document: LibraryDocument, keeping other: LibraryDocument) -> some View {
        VStack(spacing: 8) {
            Text(document.name).font(.headline).lineLimit(2).padding(.top, 12)
            Text(Paths.abbreviate(document.path)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).padding(.horizontal, 10)
            DocumentPreview(url: document.url, text: document.text).id(document.digest)
            HStack {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                Button(state.simulate ? "Preview Trash" : "Trash this copy", role: .destructive) {
                    let alert = NSAlert(); alert.messageText = state.simulate ? "Preview moving this copy to Trash?" : "Move this copy to Trash?"
                    alert.informativeText = Paths.abbreviate(document.path) + "\nThe other document stays in place. You can undo from Activity."
                    alert.addButton(withTitle: state.simulate ? "Preview" : "Move to Trash"); alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        state.engine.trash(paths: [document.path], requiring: [document.path: document.digest, other.path: other.digest])
                        model.status = state.simulate ? "Trash preview recorded in Activity." : "Trash requested. Check Activity for the result or Undo, then find duplicates again."
                    }
                }
            }.padding(.bottom, 12)
        }.frame(maxWidth: .infinity)
    }

    private var integrity: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Checks against the contents recorded when each file was first indexed or filed by Ablage.").font(.callout).foregroundStyle(.secondary)
                Spacer(); Button("Check files") { model.checkIntegrity() }.disabled(model.busy)
            }.padding(12)
            HSplitView {
                List(model.issues, selection: $selectedIssue) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(issue.kind.rawValue, systemImage: "exclamationmark.circle").foregroundStyle(Palette.red)
                        Text(issue.document.name).lineLimit(2)
                    }.font(.callout).padding(.vertical, 5).tag(issue.id)
                }.frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
                if let issue {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(issue.kind.rawValue).font(.headline)
                        Text(Paths.abbreviate(issue.document.path)).textSelection(.enabled)
                        Text("A change can be an intentional edit, a move, or an unavailable drive. Check the document before accepting a new baseline.").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if issue.kind == .changed { Button("Accept current contents…") { model.acceptChange(issue.document) }.disabled(model.busy) }
                            if !issue.document.original.isEmpty { Button("Save original copy…") { model.exportOriginal(issue.document) }.disabled(model.busy) }
                        }
                        DocumentPreview(url: issue.document.url, text: issue.document.text)
                    }.padding(16)
                } else { EmptyState(symbol: "checkmark.shield", title: "Confidence in your archive", detail: "Check for missing files, unreadable files and changed contents. Preserved originals can be saved as a separate copy.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }
}

@MainActor
final class ArchiveController {
    static let shared = ArchiveController()
    private var window: NSWindow?
    private var model: ArchiveModel?
    func show(state: AppState) {
        if let window { model?.search(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let model = ArchiveModel(); self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: ArchiveView(model: model).environmentObject(state)))
        window.title = "Ablage · Archive"; window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1120, height: 740)); window.animationBehavior = .none; window.isReleasedWhenClosed = false
        self.window = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}
