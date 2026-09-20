import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import Ablage

/// Opt-in renders of the actual views, without screen capture or personal files.
final class VisualPreviewTests: XCTestCase {
    @MainActor
    func testRenderExactDuplicates() throws {
        guard let directory = ProcessInfo.processInfo.environment["ABLAGE_RENDER_DIR"] else { throw XCTSkip("Set ABLAGE_RENDER_DIR to render UI previews") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: directory)
        let fixture = root.appendingPathComponent("duplicate-fixtures")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let first = fixture.appendingPathComponent("September invoice.pdf")
        let data = try previewInvoice()
        for url in [first, fixture.appendingPathComponent("Invoice copy with a longer filename.pdf"), fixture.appendingPathComponent("Archive/Invoice.pdf")] { try data.write(to: url) }
        let model = ExactDuplicateModel(folders: [fixture])
        model.report = ExactDuplicateScanner.scan(folders: [fixture]); model.status = "3 files checked · 1 identical group · 2 extra copies"
        let group = try XCTUnwrap(model.report?.groups.first)
        let state = AppState(preview: Snapshot(inboxes: [], items: [], journal: [], aiModels: [], configError: nil, progress: nil, filedThisMonth: 0, examples: 0))
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try render(ExactDuplicateView(model: model, selected: group.id, keeping: first.path, startAutomatically: false).environmentObject(state)
                .frame(width: 1100, height: 780), width: 1100, to: root.appendingPathComponent("exact-duplicates-\(suffix).png"), dark: dark)
            try render(ExactDuplicateView(model: model, selected: group.id, startAutomatically: false).environmentObject(state)
                .frame(width: 980, height: 650), width: 980, to: root.appendingPathComponent("exact-duplicates-small-\(suffix).png"), dark: dark)
        }
    }

    @MainActor
    func testRenderPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["ABLAGE_RENDER_DIR"] else { throw XCTSkip("Set ABLAGE_RENDER_DIR to render UI previews") }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let inboxes = [InboxInfo(label: "Downloads", path: "/preview/Downloads", ruleNames: ["Invoices", "Screenshots"], enabled: true), InboxInfo(label: "Scans", path: "/preview/Scans", ruleNames: ["Invoices"], enabled: true)]
        let names = ["Invoice_2026_September.pdf", "Screenshot 2026-09-20 at 11.14.59.png", "Quarterly report — a particularly long document name.pdf", "Scanned letter.pdf", "Statement.pdf", "Boarding pass.pdf"]
        let move = FilePlan(state: .ready, rule: "Invoices", steps: [.init(kind: .move, value: Paths.home.appendingPathComponent("Documents/Invoices/2026/2026-09-20_Invoice.pdf").path), .init(kind: .rename, value: "2026-09-20_Invoice.pdf"), .init(kind: .tags, value: "Invoice, Business")])
        let screenshot = FilePlan(state: .ready, rule: "Screenshots", steps: [.init(kind: .move, value: Paths.home.appendingPathComponent("Pictures/Screenshots/2026/" + names[1]).path)])
        let plans: [FilePlan] = [move, screenshot, .noMatch, .needsOCR, .checking, .noMatch]
        let items = names.enumerated().map { index, name in InboxItem(id: "/preview/Downloads/" + name, inboxIndex: index < 4 ? 0 : 1, name: name, isFolder: false, size: Int64(124000 + index * 98322), ageDays: index, added: Date(), status: .unsorted, preview: plans[index]) }
        let entries = [JournalEntry(rule: "Invoices", kind: .moved, from: "/preview/Downloads/Invoice.pdf", to: "/preview/Documents/Invoices/Invoice.pdf"), JournalEntry(rule: "Installers", kind: .simulated, from: "/preview/Downloads/Installer with a long name.dmg", message: "would move to Trash")]
        let state = AppState(preview: Snapshot(inboxes: inboxes, items: items, journal: entries, aiModels: [], configError: nil, progress: nil, filedThisMonth: 42, examples: 12))
        let document = try ConfigDocument(data: Data(#"{"inboxes":[{"path":"~/Downloads","name":"Downloads"},{"path":"~/Documents/Scans","name":"Scans"}],"rules":[{"name":"Invoices","match":{"extensions":["pdf"]},"action":{"destination":"~/Documents/Invoices"}}]}"#.utf8))
        let fixture = url.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let pdf = fixture.appendingPathComponent("September invoice.pdf")
        try previewInvoice().write(to: pdf)
        var metadata = DocumentMetadata()
        metadata.title = "Studio subscription"; metadata.correspondent = "Atelier Wien"; metadata.documentDate = "2026-09-20"
        metadata.documentType = "Invoice"; metadata.invoiceNumber = "AW-2026-0920"; metadata.amount = "49.00"; metadata.currency = "EUR"; metadata.dueDate = "2026-10-04"
        metadata.fields = [DocumentField(name: "Project", value: "Studio")]
        let library = DocumentLibrary(url: fixture.appendingPathComponent("preview-" + UUID().uuidString + ".sqlite"))
        try library.saveMetadata(metadata, for: pdf.path); try library.index(pdf, config: Config())
        let first = try XCTUnwrap(library.document(at: pdf.path))
        let secondURL = fixture.appendingPathComponent("Invoice copy.pdf")
        try previewInvoice().write(to: secondURL)
        try library.index(secondURL, config: Config())
        let second = try XCTUnwrap(library.document(at: secondURL.path))
        let archive = ArchiveModel(library: library)
        archive.documents = [first, second]; archive.pairs = [.init(first: first, second: second, exact: true, similarity: 1)]
        archive.issues = [.init(document: first, kind: .changed)]
        let facts = try XCTUnwrap(FileFacts(url: pdf))
        let rule = try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"Invoices","action":{"destination":"~/Documents/Invoices/{year}","rename":"{date}_{correspondent}_{invoice_number}","tags":["Business"]}}"#.utf8))
        let packet = DocumentReviewPacket(facts: facts, text: first.text, metadata: metadata, rules: [rule], inbox: fixture, config: Config(), plan: FilePlan(state: .ready, rule: "Invoices", steps: []), digest: first.digest)
        let review = DocumentReviewModel(packet: packet, engine: state.engine)
        let split = ScanSplitModel(source: pdf); split.starts = [0, 2]
        var mail = MailAccount(); mail.name = "Receipts"; mail.host = "imap.example.com"; mail.username = "sam@example.com"; mail.folder = "Receipts"
        var configured = document
        configured.root["archiveFolders"] = ["~/Documents/Invoices", "~/Documents/Letters"]
        configured.root["keepOriginalsForever"] = true
        configured.root["mailAccounts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([mail]))
        configured.models = ["Studio model": ["provider": "openai", "endpoint": "https://api.example.com/v1", "model": "document-model", "automatic": false, "vision": true], "On this Mac": ["provider": "apple", "automatic": true]]
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try renderPanel(PanelView().environmentObject(state), width: 440, to: url.appendingPathComponent("panel-\(suffix).png"), dark: dark)
            try renderPanel(PanelView(showingActivity: true).environmentObject(state), width: 440, to: url.appendingPathComponent("activity-\(suffix).png"), dark: dark)
            try render(ReviewView().environmentObject(state).frame(width: 1000, height: 620), width: 1000, to: url.appendingPathComponent("review-\(suffix).png"), dark: dark)
            try render(ReviewView(selection: [items[0].id]).environmentObject(state).frame(width: 1000, height: 620), width: 1000, to: url.appendingPathComponent("review-plan-\(suffix).png"), dark: dark)
            try render(InboxRow(item: items[0], showingPlan: true).environmentObject(state).frame(width: 440).background(Palette.paper), width: 440, to: url.appendingPathComponent("file-plan-\(suffix).png"), dark: dark)
            try render(SettingsView(model: SettingsModel(document: document)).environmentObject(state).frame(width: 720, height: 690), width: 720, to: url.appendingPathComponent("settings-\(suffix).png"), dark: dark)
            for section in ["rules", "preferences"] { try render(SettingsView(model: SettingsModel(document: document), section: section).environmentObject(state).frame(width: 720, height: 690), width: 720, to: url.appendingPathComponent("\(section)-\(suffix).png"), dark: dark) }
            for section in ["archive", "email", "models"] { try render(SettingsView(model: SettingsModel(document: configured), section: section).environmentObject(state).frame(width: 720, height: 740), width: 720, to: url.appendingPathComponent("settings-\(section)-\(suffix).png"), dark: dark) }
            try render(DocumentReviewView(model: review, close: {}).environmentObject(state).frame(width: 1040, height: 780), width: 1040, to: url.appendingPathComponent("document-review-\(suffix).png"), dark: dark)
            try render(ArchiveView(model: archive, selected: first.id, filters: true).environmentObject(state).frame(width: 1120, height: 740), width: 1120, to: url.appendingPathComponent("archive-\(suffix).png"), dark: dark)
            try render(ArchiveView(model: archive, section: "duplicates", selectedPair: archive.pairs.first?.id).environmentObject(state).frame(width: 1120, height: 740), width: 1120, to: url.appendingPathComponent("duplicates-\(suffix).png"), dark: dark)
            try render(ArchiveView(model: archive, section: "integrity", selectedIssue: archive.issues.first?.id).environmentObject(state).frame(width: 1120, height: 740), width: 1120, to: url.appendingPathComponent("integrity-\(suffix).png"), dark: dark)
            try render(ScanSplitView(model: split).frame(width: 1000, height: 740), width: 1000, to: url.appendingPathComponent("split-\(suffix).png"), dark: dark)
            try render(HistoryView().environmentObject(state).frame(width: 740, height: 570), width: 740, to: url.appendingPathComponent("history-\(suffix).png"), dark: dark)
            var modelDraft = ModelDraft(); modelDraft.name = "Studio model"; modelDraft.model = "document-model"
            try render(ModelEditorView(draft: modelDraft, existing: [], onSave: { _ in }, onCancel: {}), width: 590, to: url.appendingPathComponent("model-editor-\(suffix).png"), dark: dark)
            var draft = RuleDraft(); draft.name = "Invoices"; draft.extensions = "pdf"; draft.destination = "~/Documents/Invoices/{year}"
            try render(RuleEditorView(draft: draft, excerpt: "", fileName: nil, onSave: { _ in }, onCancel: {}), width: 600, to: url.appendingPathComponent("rule-\(suffix).png"), dark: dark)
        }
    }
}

@MainActor
private func previewInvoice() throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
    for page in 0..<4 {
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
        func line(_ text: String, y: CGFloat, size: CGFloat = 13, color: NSColor = .black) {
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
            context.textPosition = CGPoint(x: 54, y: y); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        line("ATELIER WIEN", y: 755, size: 27)
        line("A space for ideas.", y: 728, color: .darkGray)
        line(page == 0 ? "Invoice" : "Invoice · Details", y: 642, size: 24)
        line("AW-2026-0920", y: 610)
        line("20 September 2026", y: 578)
        context.setStrokeColor(NSColor.lightGray.cgColor); context.move(to: CGPoint(x: 54, y: 530)); context.addLine(to: CGPoint(x: 541, y: 530)); context.strokePath()
        line("Studio subscription · September", y: 489)
        line("Monthly access", y: 461, color: .darkGray)
        line("Total                                         EUR 49.00", y: 388, size: 18)
        line("Payment due: 4 October 2026", y: 348)
        line("Thank you for being part of the studio.", y: 252, color: .darkGray)
        line("Preview document · \(page + 1) / 4", y: 54, size: 10, color: .darkGray)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@MainActor
private func render<V: View>(_ view: V, width: CGFloat, to url: URL, dark: Bool) throws {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = hosting.fittingSize
    hosting.frame = CGRect(x: 0, y: 0, width: width, height: max(1, size.height))
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ConfigError(message: "Could not render view") }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ConfigError(message: "No render data") }
    try data.write(to: url)
    window.close()
    print("Rendered \(url.lastPathComponent): \(hosting.frame.size)")
}

@MainActor
private func renderPanel<V: View>(_ view: V, width: CGFloat, to url: URL, dark: Bool) throws {
    let naturalSize = NSHostingView(rootView: view).fittingSize
    let surface = MenuPanelSurface(content: view, naturalSize: naturalSize, maximumHeight: 800, onSizeChange: { _ in })
    try render(surface, width: width, to: url, dark: dark)
}
