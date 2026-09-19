import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = Engine()

    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var journal: [JournalEntry] = []
    @Published private(set) var inboxes: [InboxInfo] = []
    @Published private(set) var aiModels: [String] = []
    @Published private(set) var configError: String?
    @Published private(set) var progress: Progress?
    @Published private(set) var filedThisMonth = 0
    @Published private(set) var examples = 0
    @Published var quickLook: URL?
    @Published var simulate: Bool { didSet { engine.simulate = simulate } }
    @Published var paused: Bool { didSet { engine.paused = paused } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            do {
                try LaunchAtLogin.set(launchAtLogin)
            } catch {
                Log.write("launch at login: \(error.localizedDescription)")
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    var unsortedCount: Int { items.filter { $0.status == .unsorted }.count }
    var settlingCount: Int { items.count - unsortedCount }

    private init() {
        simulate = engine.simulate
        paused = engine.paused
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func start() {
        engine.onUpdate = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        engine.start()
        Notifier.shared.requestAuthorization()
    }

    private func apply(_ s: Snapshot) {
        items = s.items
        journal = s.journal
        inboxes = s.inboxes
        aiModels = s.aiModels
        configError = s.configError
        progress = s.progress
        filedThisMonth = s.filedThisMonth
        examples = s.examples
    }

    func confirmSortAll() {
        let count = unsortedCount
        guard count > 0 else { return }
        let alert = NSAlert()
        let place = inboxes.count == 1 ? inboxes[0].label : "\(inboxes.count) inboxes"
        alert.messageText = "Sort \(count) items in \(place)?"
        alert.informativeText = simulate
            ? "Simulation is on. Nothing moves. The activity list shows what each rule would do."
            : "Every enabled rule runs on every item. Each move can be undone from the activity list."
        alert.addButton(withTitle: simulate ? "Simulate" : "Sort")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.sortAll()
    }

    func apply(ruleIndex: Int, to item: InboxItem) { engine.apply(ruleIndex: ruleIndex, to: item.id) }
    func apply(ruleNamed name: String, to items: [InboxItem]) { engine.apply(ruleNamed: name, paths: items.map(\.id)) }
    func sort(_ items: [InboxItem]) { engine.sort(paths: items.map(\.id)) }
    func trash(_ items: [InboxItem]) { engine.trash(paths: items.map(\.id)) }
    func openReview() { ReviewController.shared.show(state: self) }
    func ask(model: String, _ item: InboxItem) { engine.ask(model: model, path: item.id) }
    func trash(_ item: InboxItem) { engine.trash(path: item.id) }
    func undo(_ entry: JournalEntry) { engine.undo(entry.id) }
    func reveal(_ item: InboxItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func open(_ item: InboxItem) { NSWorkspace.shared.open(item.url) }
    func file(_ urls: [URL]) { engine.file(paths: urls.map(\.path)) }

    func reveal(_ entry: JournalEntry) {
        let candidates = [entry.undone ? entry.from : (entry.to ?? entry.from), entry.from]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func newRule(from item: InboxItem?) {
        guard let item else {
            present(RuleDraft(), excerpt: "", item: nil)
            return
        }
        engine.excerpt(path: item.id) { [weak self] facts, text in
            var draft = RuleDraft()
            draft.extensions = facts?.ext ?? ""
            draft.source = facts?.host ?? ""
            self?.present(draft, excerpt: text, item: item)
        }
    }

    private func present(_ draft: RuleDraft, excerpt: String, item: InboxItem?) {
        RuleEditorController.shared.show(draft: draft, excerpt: excerpt, fileName: item?.name) { [weak self] draft in
            do {
                try ConfigStore.appendRule(draft.json)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not save the rule"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
            if draft.applyNow, let item { self?.engine.apply(ruleNamed: draft.name.trimmingCharacters(in: .whitespaces), to: item.id) }
        }
    }
    func openConfig() { NSWorkspace.shared.open(Paths.configFile) }
    func openInbox(_ info: InboxInfo) { NSWorkspace.shared.open(URL(fileURLWithPath: info.path, isDirectory: true)) }
    func rules(for item: InboxItem) -> [String] { inboxes.indices.contains(item.inboxIndex) ? inboxes[item.inboxIndex].ruleNames : [] }

    func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.logFile.path) { Log.write("log opened") }
        NSWorkspace.shared.open(Paths.logFile)
    }
}
