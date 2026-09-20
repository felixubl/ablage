import AppKit
import PDFKit
import SwiftUI

@MainActor
final class PDFPreviewModel: ObservableObject {
    let document: PDFDocument?
    @Published var page = 0
    @Published var zoom = 0
    init(url: URL) { document = PDFDocument(url: url) }
}

struct PDFPreview: View {
    @StateObject private var model: PDFPreviewModel
    init(url: URL) { _model = StateObject(wrappedValue: PDFPreviewModel(url: url)) }
    var body: some View {
        if let document = model.document, !document.isLocked, document.pageCount > 0 {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { model.page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0).help("Previous page")
                    Text("Page \(model.page + 1) of \(document.pageCount)").font(.caption).monospacedDigit()
                    Button { model.page += 1 } label: { Image(systemName: "chevron.right") }.disabled(model.page + 1 >= document.pageCount).help("Next page")
                    Spacer()
                    Button { model.zoom -= 1 } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                    Button { model.zoom += 1 } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                }.buttonStyle(.borderless).padding(10).background(Palette.paper)
                PDFCanvas(document: document, page: model.page, zoom: model.zoom)
            }
        } else {
            EmptyState(symbol: "doc.badge.ellipsis", title: model.document?.isLocked == true ? "Password-protected PDF" : "Preview unavailable", detail: "Open this file in its default app to inspect it.")
        }
    }
}

struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let zoom: Int
    final class Coordinator { var page = -1; var zoom = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.autoScales = true; view.displayMode = .singlePage
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.page != page, let target = document.page(at: page) {
            view.go(to: target); context.coordinator.page = page
        }
        if zoom != context.coordinator.zoom {
            if zoom > context.coordinator.zoom { view.zoomIn(nil) } else { view.zoomOut(nil) }
            context.coordinator.zoom = zoom
        }
    }
}

struct DocumentPreview: View {
    let url: URL
    var text = ""
    var body: some View {
        Group {
            if url.pathExtension.lowercased() == "pdf" { PDFPreview(url: url).id(url) }
            else if let image = NSImage(contentsOf: url) { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1000) } }
            else if !text.isEmpty { ScrollView { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }
            else { EmptyState(symbol: "doc", title: url.lastPathComponent, detail: "Open this document in its default app to view it.") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
    }
}

struct MetadataEditor: View {
    @Binding var metadata: DocumentMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            entry("Title", text: $metadata.title)
            entry("Sender", text: $metadata.correspondent)
            entry("Document date", text: $metadata.documentDate, prompt: "YYYY-MM-DD")
            entry("Document type", text: $metadata.documentType, prompt: "Invoice, contract, letter…")
            DisclosureGroup("Invoice details") {
                VStack(alignment: .leading, spacing: 10) {
                    entry("Invoice number", text: $metadata.invoiceNumber)
                    HStack(alignment: .top) {
                        entry("Amount", text: $metadata.amount, prompt: "42.50")
                        entry("Currency", text: $metadata.currency, prompt: "EUR").frame(width: 85)
                    }
                    entry("Due date", text: $metadata.dueDate, prompt: "YYYY-MM-DD")
                }.padding(.top, 8)
            }
            DisclosureGroup("Additional fields") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($metadata.fields) { $field in
                        VStack(spacing: 6) {
                            HStack {
                                TextField("Field name", text: $field.name)
                                Picker("Type", selection: $field.kind) { ForEach(DocumentField.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().frame(width: 100)
                                Button { metadata.fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove field")
                            }
                            if field.kind == .boolean {
                                Picker("Value", selection: $field.value) { Text("Not set").tag(""); Text("Yes").tag("true"); Text("No").tag("false") }
                            } else { TextField(field.kind == .date ? "YYYY-MM-DD" : "Value", text: $field.value) }
                        }
                    }
                    Button { metadata.fields.append(DocumentField()) } label: { Label("Add field", systemImage: "plus") }
                }.padding(.top, 8)
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func entry(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt)).labelsHidden()
        }
    }
}

@MainActor
final class DocumentReviewModel: ObservableObject {
    @Published var packet: DocumentReviewPacket?
    @Published var draft = DocumentReviewDraft(folder: "", filename: "", tags: "", metadata: DocumentMetadata())
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = true
    @Published var completed = false
    @Published var ruleIndex = -1
    let path: String
    let engine: Engine

    init(path: String, engine: Engine) { self.path = path; self.engine = engine; reload() }
    #if DEBUG
    init(packet: DocumentReviewPacket, engine: Engine) {
        self.path = packet.facts.url.path; self.engine = engine; self.packet = packet
        draft = packet.draft(); ruleIndex = packet.rules.firstIndex { $0.name == packet.plan.rule } ?? -1; busy = false
    }
    #endif
    func reload() {
        busy = true; error = nil
        engine.reviewDocument(path: path) { result in
            self.busy = false
            switch result {
            case .success(let packet): self.packet = packet; self.draft = packet.draft(); self.ruleIndex = packet.rules.firstIndex { $0.name == packet.plan.rule } ?? -1
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func useRule() {
        guard var packet else { return }
        guard ruleIndex >= 0 else { draft.ruleName = "Reviewed"; draft.command = nil; return }
        packet.metadata = draft.metadata
        draft = packet.draft(ruleIndex: ruleIndex)
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose destination"; panel.directoryURL = URL(fileURLWithPath: Paths.expand(draft.folder))
        if panel.runModal() == .OK, let url = panel.url { draft.folder = Paths.abbreviate(url.path) }
    }
    func approve() {
        guard let packet else { return }
        busy = true; error = nil
        engine.approve(packet, draft: draft) { result in
            self.busy = false
            switch result {
            case .success(let message): self.notice = message; self.completed = true
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}

struct DocumentReviewView: View {
    @ObservedObject var model: DocumentReviewModel
    @EnvironmentObject var state: AppState
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review & file").font(.system(size: 24, weight: .semibold, design: .serif))
                    Text(URL(fileURLWithPath: model.path).lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: model.path)) }
                Button("Reload") { model.reload() }.disabled(model.busy || model.completed)
            }.padding(20)
            Divider()
            if let packet = model.packet {
                HSplitView {
                    DocumentPreview(url: packet.facts.url, text: packet.text).id(packet.digest).frame(minWidth: 380)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Document details").font(.headline)
                            Text("Suggested details are editable. Check them against the document before approving.").font(.caption).foregroundStyle(.secondary)
                            MetadataEditor(metadata: $model.draft.metadata)
                            Divider()
                            Text("Filing").font(.headline)
                            Picker("Rule", selection: $model.ruleIndex) {
                                Text("Manual filing").tag(-1)
                                ForEach(Array(packet.rules.enumerated()), id: \.offset) { index, rule in Text(rule.name).tag(index) }
                            }.onChange(of: model.ruleIndex) { _, _ in model.useRule() }
                            if model.ruleIndex >= 0 { Button("Update naming from these details") { model.useRule() }.font(.callout) }
                            Toggle("Move to Trash", isOn: $model.draft.trash).tint(Palette.red)
                            if !model.draft.trash {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Filename").font(.caption).foregroundStyle(.secondary)
                                    TextField("Filename", text: $model.draft.filename).textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Destination").font(.caption).foregroundStyle(.secondary)
                                    HStack { TextField("Destination folder", text: $model.draft.folder).textFieldStyle(.roundedBorder); Button { model.chooseFolder() } label: { Image(systemName: "folder") }.help("Choose destination") }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Finder tags to add").font(.caption).foregroundStyle(.secondary)
                                    TextField("Tags, separated by commas", text: $model.draft.tags).textFieldStyle(.roundedBorder)
                                }
                                Text("Existing files are never overwritten. If a name is taken, Ablage checks for an identical copy or chooses a free name.").font(.caption).foregroundStyle(.secondary)
                            }
                            if let command = model.draft.command {
                                Text("After filing, this rule runs:").font(.caption).foregroundStyle(.secondary)
                                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Button("Skip this command") { model.draft.command = nil }.font(.caption)
                            }
                        }.padding(20)
                    }.frame(minWidth: 320, idealWidth: 370, maxWidth: 440).disabled(model.busy || model.completed)
                }
            } else {
                VStack(spacing: 12) { if model.busy { ProgressView(); Text("Reading the document…").foregroundStyle(.secondary) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.error { Text(error).foregroundStyle(Palette.red).textSelection(.enabled) }
                if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Palette.green) }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.packet != nil {
                            Label(model.draft.trash ? "Move to Trash" : model.draft.filename, systemImage: model.draft.trash ? "trash" : "doc")
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(model.draft.trash ? Palette.red : .primary)
                            if !model.draft.trash {
                                Text(Paths.abbreviate(Paths.expand(model.draft.folder))).font(.caption).lineLimit(1).truncationMode(.middle).help(model.draft.folder)
                            }
                        }
                        Text(state.simulate ? "Preview mode · no file changes" : "Applies only to this document.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.completed ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button(state.simulate ? "Preview filing" : (model.draft.trash ? "Approve Trash" : "Approve & file")) { model.approve() }
                        .buttonStyle(.borderedProminent).tint(model.draft.trash ? Palette.red : Palette.blue)
                        .disabled(model.busy || model.packet == nil || model.completed).keyboardShortcut(.defaultAction)
                }
            }.padding(16)
        }.frame(minWidth: 850, minHeight: 580).background(Palette.paper).tint(Palette.blue)
    }
}

@MainActor
final class DocumentReviewController: NSObject, NSWindowDelegate {
    static let shared = DocumentReviewController()
    private var windows: [String: NSWindow] = [:]
    func show(path: String, state: AppState) {
        if let window = windows[path], window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = DocumentReviewModel(path: path, engine: state.engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Ablage · Review & file"; window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: DocumentReviewView(model: model, close: { [weak window] in window?.close() }).environmentObject(state))
        windows[path] = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}
