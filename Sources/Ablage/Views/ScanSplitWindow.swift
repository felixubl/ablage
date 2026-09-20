import AppKit
import PDFKit
import SwiftUI

struct PDFPagePreview: NSViewRepresentable {
    var url: URL
    var page: Int
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = PDFDocument(url: url); view.autoScales = true; view.displayMode = .singlePage
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if let page = view.document?.page(at: page) { view.go(to: page) } }
}

@MainActor
final class ScanSplitModel: ObservableObject {
    let source: URL
    @Published var pageCount = 0
    @Published var selectedPage = 0
    @Published var starts: Set<Int> = [0]
    @Published var excluded = Set<Int>()
    @Published var prefix: String
    @Published var folder: URL
    @Published var busy = true
    @Published var detecting = false
    @Published var error: String?
    @Published var notice: String?
    @Published var created: [URL] = []
    @Published var payload = "ABLAGE:SPLIT"
    private var digest = ""
    private var cancellation = WorkCancellation()
    var groups: [[Int]] { ScanSplitter.groups(pageCount: pageCount, starts: starts, excluded: excluded) }
    init(source: URL) {
        self.source = source; prefix = source.deletingPathExtension().lastPathComponent; folder = source.deletingLastPathComponent()
        Task {
            do {
                let result = try await Task.detached { () -> (Int, String) in
                    guard let document = PDFDocument(url: source), !document.isLocked, let digest = Hashing.digest(source)?.hex else { throw ConfigError(message: "The PDF is unreadable or password protected.") }
                    return (document.pageCount, digest)
                }.value
                pageCount = result.0; digest = result.1
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func detect() {
        busy = true; detecting = true; error = nil; cancellation = WorkCancellation()
        let source = self.source, payload = self.payload, token = cancellation
        Task {
            do {
                let separators = try await Task.detached { try ScanSplitter.separators(in: source, payload: payload, cancellation: token) }.value
                excluded = separators; starts = Set(separators.map { $0 + 1 }).union([0])
                notice = "\(separators.count) separator sheets found. Review the page groups before creating PDFs."
            } catch { self.error = error.localizedDescription }
            busy = false; detecting = false
        }
    }
    func stop() { cancellation.cancel() }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
    func saveSeparator() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Ablage separator.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ScanSplitter.separatorPDF(payload: payload).write(to: url, options: .atomic); NSWorkspace.shared.open(url) }
        catch { self.error = error.localizedDescription }
    }
    func split() {
        busy = true; error = nil
        let source = self.source, digest = self.digest, groups = self.groups, folder = self.folder, prefix = self.prefix
        Task {
            do {
                created = try await Task.detached { try ScanSplitter.split(source: source, expectedDigest: digest, groups: groups, folder: folder, prefix: prefix) }.value
                notice = "\(created.count) documents created. The original scan is unchanged."
            } catch {
                if let failure = error as? SplitFailure { created = failure.created }
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ScanSplitView: View {
    @ObservedObject var model: ScanSplitModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One scan. Separate documents.").font(.system(size: 24, weight: .semibold, design: .serif))
                    Text(model.source.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(model.pageCount) pages · \(model.groups.count) documents").font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            HSplitView {
                PDFPagePreview(url: model.source, page: model.selectedPage).frame(minWidth: 400)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose where each document starts").font(.headline)
                    Text("Click a page to inspect it. Switch on New document at the first page of each group.").font(.caption).foregroundStyle(.secondary)
                    List(0..<model.pageCount, id: \.self) { page in
                        HStack {
                            Button("Page \(page + 1)") { model.selectedPage = page }.buttonStyle(.plain).foregroundStyle(model.selectedPage == page ? Palette.blue : .primary)
                            Spacer()
                            if model.excluded.contains(page) {
                                Text("Separator").font(.caption).foregroundStyle(.secondary)
                                Button("Include") { model.excluded.remove(page) }.controlSize(.small)
                            } else {
                                Toggle("New document", isOn: Binding(get: { model.starts.contains(page) }, set: { value in if value { model.starts.insert(page) } else { model.starts.remove(page) } }))
                                    .toggleStyle(.checkbox).disabled(page == 0)
                            }
                        }.padding(.vertical, 4)
                    }
                    DisclosureGroup("Barcode separators") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Separator text", text: $model.payload).textFieldStyle(.roundedBorder)
                            HStack { Button("Detect separators") { model.detect() }; Button("Save separator sheet…") { model.saveSeparator() } }
                            Text("Recognized separator sheets are omitted from the copies. The original keeps every page.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                    Button("Reset page groups") { model.starts = [0]; model.excluded = [] }
                }.padding(16).frame(minWidth: 330, idealWidth: 350, maxWidth: 400).disabled(model.busy || !model.created.isEmpty)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.error { Text(error).foregroundStyle(Palette.red).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).foregroundStyle(Palette.green) }
                HStack {
                    TextField("Output name", text: $model.prefix).textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                    Button { model.chooseFolder() } label: { Label(Paths.abbreviate(model.folder.path), systemImage: "folder") }.lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small); if model.detecting { Button("Stop") { model.stop() } } }
                    if !model.created.isEmpty { Button("Show documents") { NSWorkspace.shared.activateFileViewerSelecting(model.created) } }
                    Button("Create \(model.groups.count) PDFs") { model.split() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.groups.isEmpty || !model.created.isEmpty || model.prefix.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("The original is kept. New PDFs use free filenames. Files created in a watched inbox follow that inbox’s rules.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(minWidth: 880, minHeight: 580).background(Palette.paper).tint(Palette.blue)
    }
}

@MainActor
final class ScanSplitController: NSObject, NSWindowDelegate {
    static let shared = ScanSplitController()
    private var windows: [String: NSWindow] = [:]
    func show(url: URL) {
        if let window = windows[url.path], window.isVisible { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ScanSplitView(model: ScanSplitModel(source: url))))
        window.delegate = self
        window.title = "Ablage · Split scan"; window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1000, height: 740)); window.animationBehavior = .none; window.isReleasedWhenClosed = false
        windows[url.path] = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}
