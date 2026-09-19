import AppKit
import Foundation

enum ItemStatus: Equatable {
    case settling, unsorted
}

struct InboxItem: Identifiable, Equatable {
    let id: String
    let inboxIndex: Int
    let name: String
    let isFolder: Bool
    let size: Int64
    let ageDays: Int
    let added: Date
    let status: ItemStatus
    /// What Sort now would do: a rule name, "learned:<rule>", "AI:<model>", "AI?:<model>" or "?" for files that need OCR.
    let preview: String?

    var url: URL { URL(fileURLWithPath: id) }
}

struct InboxInfo: Equatable {
    var label: String
    var path: String
    var ruleNames: [String]
}

struct Progress: Equatable {
    var done: Int
    var total: Int
}

struct Snapshot {
    var inboxes: [InboxInfo]
    var items: [InboxItem]
    var journal: [JournalEntry]
    var aiModels: [String]
    var configError: String?
    var progress: Progress?
    var filedThisMonth: Int
    var examples: Int
}

final class Engine {
    enum Mode {
        case new, ageOnly, all
    }

    private struct PendingFile {
        var size: Int64
        var modified: Date
        var since: Date
    }

    private final class Inbox {
        let url: URL
        let label: String
        let ignore: [String]
        let rules: [Rule]
        let sortExistingOnRescan: Bool
        let excludedFolders: Set<String>
        var watcher: FolderWatcher?
        var scanWork: DispatchWorkItem?
        var known = Set<String>()
        var pending = [String: PendingFile]()
        /// Arrivals during a pause. Sorted when the pause ends.
        var heldBack = Set<String>()

        init(_ config: InboxConfig, shared: [Rule], sortExistingDefault: Bool) {
            let base = URL(fileURLWithPath: Paths.expand(config.path), isDirectory: true).standardizedFileURL
            let all = (config.rules ?? []) + shared
            url = base
            label = Paths.abbreviate(base.path)
            ignore = config.ignore ?? []
            rules = all
            sortExistingOnRescan = config.sortExistingOnRescan ?? sortExistingDefault
            excludedFolders = Set(all.compactMap { rule -> String? in
                guard let destination = rule.action.destination else { return nil }
                let root = Template.destinationRoot(destination, inbox: base)
                return root.path.hasPrefix(base.path + "/") ? root.path : nil
            })
        }

        func holds(_ path: String) -> Bool {
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == url.path
        }
    }

    private static let partialSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload", ".aria2", ".!qb"]
    private static let simulateKey = "simulate"
    private static let pausedKey = "paused"

    private let queue = DispatchQueue(label: "at.fubl.ablage.engine", qos: .utility)
    private let previewQueue = DispatchQueue(label: "at.fubl.ablage.preview", qos: .background)
    private let fm = FileManager.default
    private let journal = Journal()
    private let learner = Learner()
    private let cache = ContentCache()
    private let defaults = UserDefaults.standard
    private var classifier = Classifier(config: AIConfig())

    private var config = Config()
    private var configError: String?
    private var loadedStamp: String?
    private var inboxes: [Inbox] = []
    private var configWatcher: FolderWatcher?
    private var configWork: DispatchWorkItem?
    private var publishWork: DispatchWorkItem?
    private var rescanTimer: DispatchSourceTimer?
    private var previews = [String: String]()
    private var previewInFlight = Set<String>()
    private var progress: Progress?

    var onUpdate: ((Snapshot) -> Void)?

    /// Simulation is on until the user turns it off once, so a fresh install never moves anything unseen.
    var simulate: Bool {
        get { defaults.object(forKey: Self.simulateKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.simulateKey) }
    }

    var paused: Bool {
        get { defaults.bool(forKey: Self.pausedKey) }
        set {
            defaults.set(newValue, forKey: Self.pausedKey)
            if !newValue { queue.async { self.inboxes.forEach { self.scheduleScan($0, after: 0) } } }
        }
    }

    // MARK: Lifecycle

    func start() {
        queue.async {
            self.journal.load()
            self.learner.load()
            self.loadConfig()
            self.watchConfig()
            self.attachInboxes()
            self.scheduleRescan()
            self.publish()
        }
    }

    // Not URL.resourceValues: a long-lived URL caches those, and this queue has no run loop to flush the cache.
    private func configStamp() -> String? {
        guard let attributes = try? fm.attributesOfItem(atPath: Paths.configFile.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modified)|\(size)"
    }

    private func loadConfig() {
        loadedStamp = configStamp()
        do {
            try ConfigStore.ensureDefault()
            config = try ConfigStore.load()
            configError = nil
            Log.write("config loaded: \(config.rules.count) shared rules, \(config.resolvedInboxes.count) inbox(es)")
            let problems = ConfigStore.problems(in: config)
            if !problems.isEmpty {
                configError = problems.joined(separator: "\n")
                Log.write("config problems: \(problems.joined(separator: "; "))")
            }
        } catch {
            configError = "config.json: \(ConfigStore.describe(error))"
            Log.write("config error: \(error)")
        }
        classifier = Classifier(config: config.ai)
    }

    private func watchConfig() {
        try? fm.createDirectory(at: Paths.configDirectory, withIntermediateDirectories: true)
        configWatcher = FolderWatcher(url: Paths.configDirectory, queue: queue) { [weak self] in
            guard let self else { return }
            configWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadConfig() }
            configWork = work
            queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private func reloadConfig() {
        guard configStamp() != loadedStamp else { return }
        loadConfig()
        previews.removeAll()
        attachInboxes()
        scheduleRescan()
        publish()
    }

    private func attachInboxes() {
        for inbox in inboxes { inbox.scanWork?.cancel() }
        inboxes = config.resolvedInboxes.map { Inbox($0, shared: config.rules, sortExistingDefault: config.sortExistingOnRescan) }
        var missing: [String] = []
        for inbox in inboxes {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: inbox.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                missing.append(inbox.label)
                continue
            }
            inbox.watcher = FolderWatcher(url: inbox.url, queue: queue) { [weak self, weak inbox] in
                guard let self, let inbox else { return }
                self.scheduleScan(inbox, after: 1.0)
            }
            // Files already there are content, not arrivals. They wait for Sort now or an age rule.
            for url in list(inbox) { inbox.known.insert(url.path) }
        }
        if !missing.isEmpty, configError == nil { configError = "inbox folder not found: \(missing.joined(separator: ", "))" }
        schedulePreviews()
    }

    private func scheduleRescan() {
        rescanTimer?.cancel()
        rescanTimer = nil
        guard config.rescanMinutes > 0 else { return }
        let interval = config.rescanMinutes * 60
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.rescan() }
        timer.resume()
        rescanTimer = timer
    }

    // MARK: Listing

    private func list(_ inbox: Inbox) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? fm.contentsOfDirectory(at: inbox.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.filter { url in
            let name = url.lastPathComponent
            if Self.isPartial(name) { return false }
            if inbox.excludedFolders.contains(url.standardizedFileURL.path) { return false }
            if inbox.ignore.contains(where: { fnmatch($0, name, 0) == 0 }) { return false }
            return true
        }
    }

    private static func isPartial(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let lower = name.lowercased()
        return partialSuffixes.contains { lower.hasSuffix($0) }
    }

    private func inbox(holding path: String) -> Inbox? {
        inboxes.first { $0.holds(path) }
    }

    // MARK: Scanning

    private func scheduleScan(_ inbox: Inbox, after delay: TimeInterval) {
        inbox.scanWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak inbox] in
            guard let self, let inbox else { return }
            self.scan(inbox)
        }
        inbox.scanWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan(_ inbox: Inbox) {
        let now = Date()
        let urls = list(inbox)
        let current = Set(urls.map(\.path))
        inbox.known = inbox.known.intersection(current)
        inbox.pending = inbox.pending.filter { current.contains($0.key) }

        var settled: [URL] = []
        for url in urls where !inbox.known.contains(url.path) {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { continue }
            let size = Int64(v.fileSize ?? 0)
            let modified = v.contentModificationDate ?? now
            guard var entry = inbox.pending[url.path] else {
                inbox.pending[url.path] = PendingFile(size: size, modified: modified, since: now)
                continue
            }
            if entry.size != size || entry.modified != modified {
                entry.size = size
                entry.modified = modified
                entry.since = now
                inbox.pending[url.path] = entry
                continue
            }
            let quiet = now.timeIntervalSince(entry.since)
            let complete = (v.isDirectory ?? false) || size > 0 || quiet > 120
            if quiet >= config.settleSeconds, complete { settled.append(url) }
        }

        for url in settled {
            inbox.pending.removeValue(forKey: url.path)
            inbox.known.insert(url.path)
        }
        if paused {
            for url in settled { inbox.heldBack.insert(url.path) }
        } else {
            let resumed = inbox.heldBack.filter { current.contains($0) }
            inbox.heldBack.removeAll()
            for path in resumed.sorted() { process(url: URL(fileURLWithPath: path), in: inbox, mode: .new) }
            for url in settled { process(url: url, in: inbox, mode: .new) }
        }
        if !inbox.pending.isEmpty { scheduleScan(inbox, after: config.settleSeconds + 0.25) }
        schedulePreviews()
        publish()
    }

    private func rescan() {
        guard !paused else { return }
        for inbox in inboxes {
            let mode: Mode = inbox.sortExistingOnRescan ? .all : .ageOnly
            for url in list(inbox) where inbox.known.contains(url.path) && inbox.pending[url.path] == nil {
                process(url: url, in: inbox, mode: mode)
            }
        }
        schedulePreviews()
        publish()
    }

    func sortAll() {
        queue.async {
            let work = self.inboxes.flatMap { inbox in self.list(inbox).filter { inbox.pending[$0.path] == nil }.map { (inbox, $0) } }
            self.progress = Progress(done: 0, total: work.count)
            self.publish()
            for (i, (inbox, url)) in work.enumerated() {
                inbox.known.insert(url.path)
                self.process(url: url, in: inbox, mode: .all)
                self.progress = Progress(done: i + 1, total: work.count)
                if (i + 1) % 5 == 0 { self.publish() }
            }
            self.progress = nil
            self.schedulePreviews()
            self.publish()
        }
    }

    // MARK: Manual actions

    func apply(ruleIndex: Int, to path: String) {
        queue.async {
            guard let inbox = self.inbox(holding: path), inbox.rules.indices.contains(ruleIndex) else { return }
            inbox.known.insert(path)
            self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all, forced: inbox.rules[ruleIndex])
            self.schedulePreviews()
            self.publish()
        }
    }

    /// Used by the rule editor right after it appended a rule. Waits for the config reload first.
    func apply(ruleNamed name: String, to path: String) {
        queue.asyncAfter(deadline: .now() + 1.2) {
            self.reloadConfig()
            guard let inbox = self.inbox(holding: path), let rule = inbox.rules.first(where: { $0.name == name }) else {
                self.journal.add(JournalEntry(rule: name, kind: .error, from: path, message: "rule not found after saving, check config.json"))
                self.publish()
                return
            }
            inbox.known.insert(path)
            self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all, forced: rule)
            self.schedulePreviews()
            self.publish()
        }
    }

    /// Facts and a text excerpt for the rule editor. Completion runs on the main thread.
    func excerpt(path: String, completion: @escaping (FileFacts?, String) -> Void) {
        queue.async {
            let facts = FileFacts(url: URL(fileURLWithPath: path))
            var text = ""
            if let facts {
                let raw = self.contentProvider(for: facts)() ?? ""
                text = String(raw.prefix(1500)).replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            }
            DispatchQueue.main.async { completion(facts, text) }
        }
    }

    func ask(model: String, path: String) {
        queue.async {
            guard let inbox = self.inbox(holding: path), let facts = FileFacts(url: URL(fileURLWithPath: path)) else { return }
            let content = self.contentProvider(for: facts)
            inbox.known.insert(path)
            if self.aiCandidates(facts, rules: inbox.rules, content: content).isEmpty {
                self.journal.add(JournalEntry(rule: model, kind: .skipped, from: path, message: "no rule with an ai description applies here"))
            } else {
                _ = self.askModels(facts, in: inbox, content: content, only: model, manual: true)
            }
            self.schedulePreviews()
            self.publish()
        }
    }

    /// Files dropped onto the panel. They need not live in an inbox; the shared rules still apply.
    func file(paths: [String]) {
        queue.async {
            for path in paths {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                let inbox = self.inbox(holding: url.path) ?? Inbox(
                    InboxConfig(path: url.deletingLastPathComponent().path, ignore: nil, rules: nil, sortExistingOnRescan: nil),
                    shared: self.config.rules, sortExistingDefault: false)
                inbox.known.insert(url.path)
                if !self.process(url: url, in: inbox, mode: .all) {
                    self.journal.add(JournalEntry(rule: "drop", kind: .skipped, from: url.path, message: "no rule matched"))
                }
            }
            self.schedulePreviews()
            self.publish()
        }
    }

    func trash(path: String) {
        queue.async {
            do {
                try self.fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                self.journal.add(JournalEntry(rule: "manual", kind: .trashed, from: path, origin: "manual"))
            } catch {
                self.journal.add(JournalEntry(rule: "manual", kind: .error, from: path, message: error.localizedDescription))
            }
            self.publish()
        }
    }

    func undo(_ id: UUID) {
        queue.async {
            guard let entry = self.journal.entries.first(where: { $0.id == id }), entry.canUndo else { return }
            let original = URL(fileURLWithPath: entry.from)
            let source: URL?
            switch entry.kind {
            case .moved: source = entry.to.map { URL(fileURLWithPath: $0) }
            case .trashed, .duplicate: source = Paths.trash.appendingPathComponent(original.lastPathComponent)
            default: source = nil
            }
            guard let source, self.fm.fileExists(atPath: source.path) else {
                self.journal.add(JournalEntry(rule: "undo", kind: .error, from: entry.from, message: "file no longer there"))
                self.publish()
                return
            }
            var target = original
            if self.fm.fileExists(atPath: target.path) { target = Hashing.unique(target) }
            do {
                // Mark as known first so the scan triggered by the move does not sort it again.
                self.inbox(holding: target.path)?.known.insert(target.path)
                try self.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try self.fm.moveItem(at: source, to: target)
                if entry.kind == .moved { Tags.write(entry.previousTags, to: target) }
                self.journal.markUndone(id)
                Log.write("undo [\(entry.rule)] \(Paths.abbreviate(source.path)) -> \(Paths.abbreviate(target.path))")
                self.teachFromUndo(entry, restored: target)
            } catch {
                self.journal.add(JournalEntry(rule: "undo", kind: .error, from: entry.from, message: error.localizedDescription))
            }
            self.schedulePreviews()
            self.publish()
        }
    }

    /// Undoing a manual filing forgets the example; undoing a learned one records a counterexample.
    private func teachFromUndo(_ entry: JournalEntry, restored: URL) {
        guard config.learning.enabled else { return }
        switch entry.origin {
        case "manual":
            learner.forget(rule: entry.rule, source: entry.from)
        case "learned":
            guard let facts = FileFacts(url: restored) else { return }
            learner.learn(rule: entry.rule, facts: facts, text: contentProvider(for: facts)(), positive: false)
        default:
            break
        }
    }

    // MARK: Processing

    private func contentProvider(for facts: FileFacts) -> () -> String? {
        let config = self.config
        let cache = self.cache
        return { cache.text(for: facts, config: config, allowOCR: true) }
    }

    /// Plain rules first. Then what the user taught. Models only where a rule names one.
    @discardableResult
    private func process(url: URL, in inbox: Inbox, mode: Mode, forced: Rule? = nil) -> Bool {
        guard let facts = FileFacts(url: url) else { return false }
        let content = contentProvider(for: facts)
        let rules = inbox.rules

        if let forced {
            if config.learning.enabled, forced.action.trash != true, !forced.action.isNoop || forced.match.ai == nil {
                learner.learn(rule: forced.name, facts: facts, text: content(), positive: true)
            }
            perform(forced, facts, in: inbox, content: content, enrichment: enrichment(for: forced, facts, content: content, manual: true), origin: "manual", note: nil)
            return true
        }

        let plain = rules.first { rule in
            guard rule.isEnabled, rule.match.ai == nil else { return false }
            if mode == .ageOnly, rule.match.minAgeDays == nil { return false }
            return Matcher.matches(rule.match, facts, content: content)
        }
        if let plain {
            perform(plain, facts, in: inbox, content: content, enrichment: enrichment(for: plain, facts, content: content, manual: false), origin: "rule", note: nil)
            return true
        }
        guard mode != .ageOnly else { return false }

        if let suggestion = learnedSuggestion(facts, rules: rules, content: content),
           let rule = rules.first(where: { $0.name == suggestion.rule }) {
            let note = "like \(suggestion.like) (\(Int(suggestion.score * 100))%)"
            perform(rule, facts, in: inbox, content: content, enrichment: nil, origin: "learned", note: note)
            return true
        }
        return askModels(facts, in: inbox, content: content, only: nil, manual: false)
    }

    private func learnedSuggestion(_ facts: FileFacts, rules: [Rule], content: () -> String?) -> Suggestion? {
        guard config.learning.enabled else { return nil }
        let names = Set(rules.filter { $0.isEnabled && $0.match.ai == nil && $0.action.trash != true }.map(\.name))
        guard !names.isEmpty, learner.examples.contains(where: { names.contains($0.rule) }) else { return nil }
        return learner.suggest(facts: facts, text: content(), among: names, config: config.learning)
    }

    private func aiCandidates(_ facts: FileFacts, rules: [Rule], content: () -> String?) -> [Rule] {
        rules.filter { $0.isEnabled && $0.match.ai != nil && Matcher.matches($0.match, facts, content: content) }
    }

    /// Remote models wait for a manual request unless marked automatic.
    private func askModels(_ facts: FileFacts, in inbox: Inbox, content: () -> String?, only: String?, manual: Bool) -> Bool {
        let candidates = aiCandidates(facts, rules: inbox.rules, content: content)
        guard !candidates.isEmpty else { return false }
        var models: [String] = []
        if let only {
            models = [only]
        } else {
            for rule in candidates {
                if let name = rule.match.ai?.model, !models.contains(name) { models.append(name) }
            }
        }
        for name in models {
            guard let model = config.ai.models[name] else {
                Log.write("ai: model \"\(name)\" is not defined under ai.models")
                continue
            }
            guard manual || model.runsAutomatically else {
                Log.write("ai: \(name) is remote and not automatic, \(facts.name) waits for a manual request")
                continue
            }
            let pool = only == nil ? candidates.filter { $0.match.ai?.model == name } : candidates
            guard let result = classifier.classify(facts: facts, text: content(), candidates: pool, model: name) else {
                if manual { journal.add(JournalEntry(rule: name, kind: .skipped, from: facts.url.path, message: "no answer, see log")) }
                continue
            }
            if (1...pool.count).contains(result.category) {
                perform(pool[result.category - 1], facts, in: inbox, content: content, enrichment: result, origin: "model:\(name)", note: nil)
                return true
            }
            if manual { journal.add(JournalEntry(rule: name, kind: .skipped, from: facts.url.path, message: "no category fits")) }
        }
        return false
    }

    private func enrichment(for rule: Rule, _ facts: FileFacts, content: () -> String?, manual: Bool) -> Classification? {
        guard let name = rule.action.ai else { return nil }
        guard let model = config.ai.models[name] else {
            Log.write("ai: model \"\(name)\" is not defined under ai.models")
            return nil
        }
        guard manual || model.runsAutomatically else {
            Log.write("ai: \(name) is remote and not automatic, no enrichment for \(facts.name)")
            return nil
        }
        return classifier.classify(facts: facts, text: content(), candidates: [], model: name)
    }

    private func perform(_ rule: Rule, _ facts: FileFacts, in inbox: Inbox, content: () -> String?, enrichment: Classification?, origin: String, note: String?) {
        let action = rule.action
        var date = facts.modified
        if action.usesDate {
            switch action.dateFrom ?? (enrichment != nil ? "content" : "file") {
            case "content":
                date = enrichment?.date ?? content().flatMap(Extract.date) ?? Extract.date(in: facts.stem) ?? facts.modified
            case "filename":
                date = Extract.date(in: facts.stem) ?? facts.modified
            default:
                date = enrichment?.date ?? facts.modified
            }
        }
        let context = TemplateContext(
            date: date, name: facts.stem, ext: facts.ext, correspondent: action.correspondent ?? enrichment?.correspondent ?? "",
            title: enrichment?.title ?? "", rule: rule.name, host: facts.host)
        var notes: [String] = []
        if let note { notes.append(note) }
        if let e = enrichment {
            let fields = [e.correspondent, e.title].filter { !$0.isEmpty }.joined(separator: ", ")
            notes.append(fields.isEmpty ? "via \(e.model)" : "via \(e.model): \(fields)")
        }
        let message = notes.isEmpty ? nil : notes.joined(separator: " · ")
        let simulate = self.simulate

        if action.trash == true {
            if simulate {
                journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, message: "would move to Trash", origin: origin))
                return
            }
            do {
                try fm.trashItem(at: facts.url, resultingItemURL: nil)
                journal.add(JournalEntry(rule: rule.name, kind: .trashed, from: facts.url.path, message: message, origin: origin))
                notify(rule.name, "\(facts.name) → Trash", path: nil)
                if let command = action.run { runHook(command, rule: rule.name, from: facts.url.path, to: nil) }
            } catch {
                journal.add(JournalEntry(rule: rule.name, kind: .error, from: facts.url.path, message: error.localizedDescription))
            }
            return
        }
        if action.isNoop { return }
        if !action.movesOrTags, let command = action.run {
            if simulate {
                journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, message: "would run: \(command)", origin: origin))
            } else {
                runHook(command, rule: rule.name, from: facts.url.path, to: facts.url.path)
            }
            return
        }

        let folder = action.destination.map { Template.destination($0, context, inbox: inbox.url) } ?? facts.url.deletingLastPathComponent()
        let stem = action.rename.map { Template.filename(Template.expand($0, context)) } ?? facts.stem
        let filename = facts.extOriginal.isEmpty ? stem : "\(stem).\(facts.extOriginal)"
        var target = folder.appendingPathComponent(filename)
        let previousTags = Tags.read(facts.url)
        let newTags = (action.tags ?? []).filter { !previousTags.contains($0) }

        if target.path == facts.url.path {
            guard !newTags.isEmpty else { return }
            if simulate {
                journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, message: "would tag \(newTags.joined(separator: ", "))", origin: origin))
                return
            }
            Tags.write(previousTags + newTags, to: facts.url)
            journal.add(JournalEntry(rule: rule.name, kind: .tagged, from: facts.url.path, message: newTags.joined(separator: ", "), origin: origin, previousTags: previousTags))
            if let command = action.run { runHook(command, rule: rule.name, from: facts.url.path, to: facts.url.path) }
            return
        }
        if simulate {
            journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, to: target.path, message: message, origin: origin))
            return
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                if !facts.isFolder, Hashing.identical(facts.url, target) {
                    try fm.trashItem(at: facts.url, resultingItemURL: nil)
                    journal.add(JournalEntry(
                        rule: rule.name, kind: .duplicate, from: facts.url.path, to: target.path,
                        message: "identical file already there, copy moved to Trash", origin: origin))
                    notify(rule.name, "\(facts.name) is a duplicate, moved to Trash", path: target.path)
                    return
                }
                target = Hashing.unique(target)
            }
            try fm.moveItem(at: facts.url, to: target)
            if !newTags.isEmpty { Tags.write(previousTags + newTags, to: target) }
            journal.add(JournalEntry(rule: rule.name, kind: .moved, from: facts.url.path, to: target.path, message: message, origin: origin, previousTags: previousTags))
            notify(rule.name, "\(facts.name) → \(Paths.abbreviate(folder.path))", path: target.path)
            if let command = action.run { runHook(command, rule: rule.name, from: facts.url.path, to: target.path) }
        } catch {
            journal.add(JournalEntry(rule: rule.name, kind: .error, from: facts.url.path, to: target.path, message: error.localizedDescription))
        }
    }

    /// paperless-ngx's post-consume script: runs after filing, in the background, output to the log.
    private func runHook(_ command: String, rule: String, from: String, to: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["ABLAGE_FROM"] = from
        environment["ABLAGE_TO"] = to ?? ""
        environment["ABLAGE_RULE"] = rule
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            journal.add(JournalEntry(rule: rule, kind: .error, from: from, to: to, message: "could not run script: \(error.localizedDescription)"))
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("run [\(rule)] exit \(process.terminationStatus)\(output.isEmpty ? "" : ": " + output.prefix(500))")
            guard process.terminationStatus != 0, let self else { return }
            self.queue.async {
                self.journal.add(JournalEntry(rule: rule, kind: .error, from: from, to: to, message: "script exited with \(process.terminationStatus), see log"))
                self.publish()
            }
        }
    }

    private func notify(_ title: String, _ body: String, path: String?) {
        guard config.notifications else { return }
        Notifier.shared.post(title: title, body: body, path: path)
    }

    // MARK: Previews

    private func schedulePreviews() {
        let config = self.config
        let learner = self.learner
        for inbox in inboxes {
            let rules = inbox.rules.filter(\.isEnabled)
            for url in list(inbox) where inbox.known.contains(url.path) && inbox.pending[url.path] == nil {
                guard let facts = FileFacts(url: url) else { continue }
                let key = cache.key(for: facts)
                if previews[key] != nil || previewInFlight.contains(key) { continue }
                previewInFlight.insert(key)
                previewQueue.async { [weak self] in
                    guard let self else { return }
                    let content: () -> String? = { self.cache.text(for: facts, config: config, allowOCR: false) }
                    var name = rules.first { $0.match.ai == nil && Matcher.matches($0.match, facts, content: content) }?.name ?? ""
                    if name.isEmpty, config.learning.enabled {
                        let names = Set(rules.filter { $0.match.ai == nil && $0.action.trash != true }.map(\.name))
                        if let s = learner.suggest(facts: facts, text: content(), among: names, config: config.learning) { name = "learned:\(s.rule)" }
                    }
                    if name.isEmpty, let model = rules.first(where: { $0.match.ai != nil && Matcher.matches($0.match, facts, content: content) })?.match.ai?.model {
                        name = (config.ai.models[model]?.runsAutomatically ?? false) ? "AI:\(model)" : "AI?:\(model)"
                    }
                    if name.isEmpty, self.cache.ocrPending(key) { name = "?" }
                    self.queue.async {
                        self.previewInFlight.remove(key)
                        self.previews[key] = name
                        self.schedulePublish()
                    }
                }
            }
        }
    }

    // MARK: Publishing

    private func filedThisMonth() -> Int {
        let calendar = Calendar.current
        let now = Date()
        return journal.entries.filter {
            ($0.kind == .moved || $0.kind == .trashed) && !$0.undone && calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }.count
    }

    private func schedulePublish() {
        guard publishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.publishWork = nil
            self?.publish()
        }
        publishWork = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func publish() {
        var items: [InboxItem] = []
        for (index, inbox) in inboxes.enumerated() {
            var own: [InboxItem] = []
            for url in list(inbox) {
                guard let facts = FileFacts(url: url) else { continue }
                let preview = previews[cache.key(for: facts)].flatMap { $0.isEmpty ? nil : $0 }
                own.append(InboxItem(
                    id: url.path, inboxIndex: index, name: facts.name, isFolder: facts.isFolder, size: facts.size, ageDays: facts.ageDays,
                    added: facts.added, status: inbox.pending[url.path] != nil ? .settling : .unsorted, preview: preview))
            }
            own.sort { $0.added > $1.added }
            items += own
        }
        let snapshot = Snapshot(
            inboxes: inboxes.map { InboxInfo(label: $0.label, path: $0.url.path, ruleNames: $0.rules.map(\.name)) },
            items: items, journal: Array(journal.entries.prefix(50)), aiModels: config.ai.modelNames,
            configError: configError, progress: progress, filedThisMonth: filedThisMonth(), examples: learner.examples.count)
        onUpdate?(snapshot)
    }
}
