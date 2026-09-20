import AppKit
import SwiftUI

@MainActor
final class ExactDuplicateModel: ObservableObject {
    @Published var folders: [URL]
    @Published var recursive: Bool
    @Published var report: DuplicateScanReport?
    @Published var busy = false
    @Published var scanning = false
    @Published var status = "Choose folders to compare. Scanning leaves every file in place."
    @Published var error: String?
    @Published var query = ""
    private var cancellation = WorkCancellation()

    init(folders: [URL]? = nil) {
        let configured = (try? ConfigStore.load()).map { config in
            config.resolvedInboxes.filter { $0.enabled ?? true }.map(\.path) + config.archiveFolders
        } ?? ["~/Downloads"]
        let saved = UserDefaults.standard.stringArray(forKey: "duplicateFolders")
        self.folders = folders ?? Array(Set(saved ?? configured)).sorted().map { URL(fileURLWithPath: Paths.expand($0)).standardizedFileURL }
        recursive = UserDefaults.standard.object(forKey: "duplicateIncludeSubfolders") as? Bool ?? true
    }
    var groups: [ExactDuplicateGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (report?.groups ?? []).filter { group in needle.isEmpty || group.files.contains { $0.path.localizedCaseInsensitiveContains(needle) } }
    }
    func chooseFolders() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "Add folders"; panel.message = "Compare file contents across these folders. Nothing is moved by a scan."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.map(\.standardizedFileURL) where !folders.contains(url) { folders.append(url) }
        changedFolders()
    }
    func removeFolder(_ url: URL) { folders.removeAll { $0 == url }; changedFolders() }
    func changedFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: "duplicateFolders")
        UserDefaults.standard.set(recursive, forKey: "duplicateIncludeSubfolders")
        report = nil; error = nil; status = "Folders changed. Scan to compare their contents."
    }
    func stop() { cancellation.cancel() }
    func scan() {
        guard !busy, !folders.isEmpty else { return }
        busy = true; scanning = true; report = nil; error = nil; status = "Looking through folders…"
        cancellation = WorkCancellation()
        let token = cancellation, roots = folders, recursive = recursive
        Task {
            let result = await Task.detached(priority: .utility) {
                ExactDuplicateScanner.scan(folders: roots, recursive: recursive, cancellation: token) { message in
                    Task { @MainActor [weak self] in if self?.scanning == true { self?.status = message } }
                }
            }.value
            report = result; busy = false; scanning = false
            status = "\(result.files.formatted()) files checked · \(result.groups.count.formatted()) identical groups · \(result.extraCount.formatted()) extra copies"
            if result.cancelled { status = "Scan stopped · partial results. " + status }
        }
    }
    func remove(_ request: DuplicateRemoval, state: AppState) {
        guard !busy else { return }
        busy = true; error = nil; status = "Rechecking the selected copies…"
        state.engine.trashDuplicates(request) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.error = result.error
                if !result.removedPaths.isEmpty, var updated = self.report {
                    let removed = Set(result.removedPaths)
                    updated.groups = updated.groups.compactMap { group in
                        let remaining = group.files.filter { !removed.contains($0.path) }
                        return remaining.count > 1 ? ExactDuplicateGroup(digest: group.digest, files: remaining) : nil
                    }
                    self.report = updated
                }
                self.status = result.previewed > 0 ? "Preview recorded for \(result.previewed) copies. No files moved."
                    : "\(result.removedPaths.count) copies moved to Trash. Undo is available in Activity."
                if result.error != nil { self.status = "Some files changed or could not be removed. Scan again before continuing." }
            }
        }
    }
}

struct ExactDuplicateView: View {
    @ObservedObject var model: ExactDuplicateModel
    @EnvironmentObject var state: AppState
    @State private var selected: String?
    @State private var keeper = ""
    @State private var removing = Set<String>()
    @State private var inspected: String?
    @State private var previewPresented = false
    @State private var showFolders = false
    @State private var showIssues = false
    var startAutomatically = true

    init(model: ExactDuplicateModel, selected: String? = nil, keeping: String? = nil, startAutomatically: Bool = true) {
        let keeping = keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.model = model; _selected = State(initialValue: selected); self.startAutomatically = startAutomatically
        _keeper = State(initialValue: keeping ?? "")
        let paths = model.report?.groups.first { $0.id == selected }?.files.map(\.path) ?? []
        _removing = State(initialValue: keeping.map { Set(paths).subtracting([$0]) } ?? [])
        _inspected = State(initialValue: keeping)
    }
    private var group: ExactDuplicateGroup? { model.groups.first { $0.id == selected } }
    private var file: DuplicateFile? { group?.files.first { $0.path == inspected } ?? group?.files.first }
    private var bytes: String { ByteCountFormatter.string(fromByteCount: model.report?.extraBytes ?? 0, countStyle: .file) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find the extra copies.").font(.system(size: 24, weight: .semibold, design: .serif))
                    Text("Identical contents, even with different names. You choose what stays.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Preview", isOn: $state.simulate).toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                    .help("Record a simulation in Activity without moving files")
                Button(model.report == nil ? "Scan folders" : "Scan again") { resetSelection(); model.scan() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.folders.isEmpty).keyboardShortcut("r")
            }.padding(22)
            Divider()
            HStack(spacing: 12) {
                Label(model.folders.count == 1 ? Paths.abbreviate(model.folders[0].path) : "\(model.folders.count) folders", systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(model.folders.map { Paths.abbreviate($0.path) }.joined(separator: "\n"))
                Button(showFolders ? "Done" : "Choose folders…") { showFolders.toggle() }.disabled(model.busy)
                Spacer()
                Toggle("Include subfolders", isOn: $model.recursive).disabled(model.busy).onChange(of: model.recursive) { _, _ in model.changedFolders(); resetSelection() }
            }.font(.callout).padding(.horizontal, 22).padding(.vertical, 12)
            if showFolders || model.folders.isEmpty { folderPicker }
            if state.simulate {
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(Palette.blue)
                    Text("Preview is on. Removing copies records a simulation; files stay in place.").font(.callout)
                    Spacer()
                }.padding(.horizontal, 22).padding(.vertical, 10).background(Palette.blue.opacity(0.06))
            }
            HStack(spacing: 12) {
                TextField("Find a filename or folder", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 310)
                Spacer()
                if let report = model.report {
                    Text("\(report.extraCount.formatted()) extra copies · \(bytes) of contents").font(.callout).foregroundStyle(.secondary)
                        .help("Logical file sizes. Space actually freed can differ for APFS clones, compressed files and backups.")
                }
            }.padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            HSplitView {
                groupList.frame(minWidth: 235, idealWidth: 285, maxWidth: 370)
                if let group { detail(group) }
                else {
                    EmptyState(symbol: model.busy ? "doc.text.magnifyingglass" : "doc.on.doc", title: emptyTitle,
                               detail: model.busy ? "Comparing file contents on your Mac. You can stop at any time." : emptyDetail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }.frame(minWidth: 980, minHeight: 650).background(Palette.paper).tint(Palette.blue)
        .onChange(of: selected) { _, _ in keeper = ""; removing = []; inspected = nil }
        .onChange(of: model.query) { _, _ in if group == nil { resetSelection() } }
        .sheet(isPresented: $previewPresented) {
            if let file {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.name).font(.headline).lineLimit(2)
                            Text(Paths.abbreviate(file.url.deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(file.url) }
                        Button("Done") { previewPresented = false }.keyboardShortcut(.cancelAction)
                    }.padding(18)
                    Divider()
                    DocumentPreview(url: file.url, text: "").id(file.path + file.revision)
                }.frame(width: 740, height: 650).background(Palette.paper)
            }
        }
        .task { if startAutomatically, model.report == nil { model.scan() } }
    }

    private var emptyTitle: String {
        if model.busy { return "Finding identical files" }
        if model.report == nil { return "Choose where to look" }
        if !model.query.isEmpty && model.groups.isEmpty { return "No groups match your search" }
        if model.report?.cancelled == true { return "Scan stopped" }
        if model.groups.isEmpty { return "No identical files found" }
        return "Choose a group to compare"
    }
    private var emptyDetail: String {
        if model.report == nil { return "Add your Downloads, Desktop or another folder. No archive index or text recognition is needed." }
        if !model.query.isEmpty && model.groups.isEmpty { return "Try another filename or folder, or clear the search." }
        if model.report?.cancelled == true { return "Results are incomplete. Scan again to finish comparing your folders." }
        if model.groups.isEmpty { return "No identical copies were found among the files that could be checked. Scan details are shown below." }
        return "Each group contains the same bytes. Choose a copy to keep, then review the others before moving them to Trash."
    }
    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.folders, id: \.path) { folder in
                        HStack {
                            Text(Paths.abbreviate(folder.path)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeFolder(folder); resetSelection() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Remove folder \(folder.lastPathComponent)")
                        }
                    }
                }
            }.frame(height: CGFloat(min(4, model.folders.count)) * 28)
            HStack {
                Button { model.chooseFolders(); resetSelection() } label: { Label("Add folders…", systemImage: "plus") }
                Text("Hidden files, apps, aliases and files stored only in the cloud are skipped.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 22).padding(.bottom, 14).disabled(model.busy)
    }
    private var groupList: some View {
        List(model.groups, selection: $selected) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.files.first?.name ?? "Identical files").fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                Label("\(group.files.count) copies · \(ByteCountFormatter.string(fromByteCount: group.files.first?.size ?? 0, countStyle: .file)) each", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(group.extraCount) extra · \(ByteCountFormatter.string(fromByteCount: group.extraBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(Palette.blue)
            }.padding(.vertical, 7).tag(group.id)
        }.listStyle(.sidebar)
    }
    private func detail(_ group: ExactDuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Identical contents", systemImage: "checkmark.seal").font(.headline).foregroundStyle(Palette.green)
                Spacer()
                Text("\(group.files.count) copies").font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 18)
            Text("Choose a copy to keep. Names, dates and Finder tags can differ.").font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(group.files) { copy in copyRow(copy, group: group) }
                }.padding(.horizontal, 18).padding(.bottom, 14)
            }.frame(maxHeight: .infinity)
            Divider()
            if let file {
                HStack {
                    Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Preview…") { previewPresented = true }
                    Button("Open") { NSWorkspace.shared.open(file.url) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 12) {
                Text(keeper.isEmpty ? "Select the copy you want to keep." : "\(removing.count) selected · at least one copy stays")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(state.simulate ? "Review Trash preview…" : "Review removal…") { confirmRemoval(group) }
                    .disabled(keeper.isEmpty || removing.isEmpty || model.busy)
            }.padding(16)
        }.frame(maxWidth: .infinity).background(Palette.surface)
    }
    private func copyRow(_ copy: DuplicateFile, group: ExactDuplicateGroup) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: keeper == copy.path ? "checkmark.circle.fill" : "doc")
                .font(.system(size: 22)).foregroundStyle(keeper == copy.path ? Palette.green : .secondary).accessibilityHidden(true)
            Button { inspected = copy.path; previewPresented = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.name).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                    Text(Paths.abbreviate(copy.url.deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    Text("Modified " + copy.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(copy.path).accessibilityLabel("Preview \(copy.path)")
            VStack(alignment: .trailing, spacing: 8) {
                if keeper == copy.path { Label("Keeping", systemImage: "checkmark").font(.callout).foregroundStyle(Palette.green) }
                else {
                    Button("Keep this copy") { keeper = copy.path; removing = Set(group.files.map(\.path)).subtracting([copy.path]); inspected = copy.path }
                        .controlSize(.small).disabled(model.busy)
                    if !keeper.isEmpty {
                        Toggle("Remove", isOn: Binding(get: { removing.contains(copy.path) }, set: { if $0 { removing.insert(copy.path) } else { removing.remove(copy.path) } }))
                            .font(.caption).disabled(model.busy).accessibilityLabel("Remove \(copy.path)")
                    }
                }
            }
        }.padding(12).background(keeper == copy.path ? Palette.green.opacity(0.06) : Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(keeper == copy.path ? Palette.green.opacity(0.35) : Color.secondary.opacity(0.12)))
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error { Text(error).font(.callout).foregroundStyle(Palette.red).textSelection(.enabled) }
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.scanning { Button("Stop scan") { model.stop() }.controlSize(.small) }
                if let report = model.report, !report.issues.isEmpty || report.cloudFiles > 0 || report.linkedFiles > 0 {
                    Button("Scan details") { showIssues.toggle() }.controlSize(.small).popover(isPresented: $showIssues) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Scan details").font(.headline)
                                Text("\(report.cloudFiles) cloud-only files skipped · \(report.linkedFiles) repeated hard links skipped")
                                ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in Text(issue).textSelection(.enabled) }
                                if report.issues.count == 100 { Text("Showing the first 100 issues.") }
                            }.font(.callout).padding(18)
                        }.frame(width: 420, height: 280)
                    }
                }
                Button("Activity & Undo") { state.openHistory() }.controlSize(.small)
            }
        }.padding(12)
    }
    private func resetSelection() { selected = nil; keeper = ""; removing = []; inspected = nil }
    private func confirmRemoval(_ group: ExactDuplicateGroup) {
        do {
            let request = try DuplicateRemoval(group: group, keeping: keeper, removing: removing)
            let alert = NSAlert()
            alert.messageText = state.simulate ? "Preview moving \(request.copies.count) extra copies to Trash?" : "Move \(request.copies.count) extra copies to Trash?"
            alert.informativeText = state.simulate ? "No files will move. The preview appears in Activity." : "Contents are checked again first. You can undo from Activity."
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
            text.string = "KEEP\n" + Paths.abbreviate(keeper) + "\n\n" + (state.simulate ? "PREVIEW TRASH\n" : "MOVE TO TRASH\n")
                + request.copies.map { Paths.abbreviate($0.path) }.joined(separator: "\n\n")
            text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 12)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: state.simulate ? "Record preview" : "Move to Trash"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.remove(request, state: state); keeper = ""; removing = []
        } catch { model.error = error.localizedDescription }
    }
}

@MainActor
final class ExactDuplicateController {
    static let shared = ExactDuplicateController()
    private var window: NSWindow?
    func show(state: AppState) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let model = ExactDuplicateModel()
        let window = NSWindow(contentViewController: NSHostingController(rootView: ExactDuplicateView(model: model).environmentObject(state)))
        window.title = "Ablage · Find duplicates"; window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1100, height: 780)); window.animationBehavior = .none; window.isReleasedWhenClosed = false
        self.window = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
}
