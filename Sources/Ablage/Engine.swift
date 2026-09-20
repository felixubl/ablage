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
    let preview: FilePlan?

    var url: URL { URL(fileURLWithPath: id) }
    var plan: FilePlan { status == .settling ? .arriving : (preview ?? .checking) }
    var hasSuggestion: Bool { plan.hasAction }

}

struct InboxInfo: Equatable {
    var label: String
    var path: String
    var ruleNames: [String]
    var enabled: Bool
    var reviewFirst = false
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
        let enabled: Bool
        let reviewFirst: Bool
        let excludedFolders: Set<String>
        var accessError: String?
        var watcher: FolderWatcher?
        var scanWork: DispatchWorkItem?
        var known = Set<String>()
        var pending = [String: PendingFile]()
        /// Arrivals during a pause. Sorted when the pause ends.
        var heldBack = Set<String>()

        init(_ config: InboxConfig, shared: [Rule], sortExistingDefault: Bool, sharedIgnore: [String] = []) {
            let base = URL(fileURLWithPath: Paths.expand(config.path), isDirectory: true).standardizedFileURL
            let all = (config.rules ?? []) + shared
            url = base
            label = config.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? base.lastPathComponent
            enabled = config.enabled ?? true
            reviewFirst = config.reviewFirst ?? false
            ignore = sharedIgnore + (config.ignore ?? [])
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
    private let recognitionQueue = DispatchQueue(label: "at.fubl.ablage.recognition", qos: .background)
    private let layerQueue = DispatchQueue(label: "at.fubl.ablage.textlayer", qos: .utility)
    private let archiveQueue = DispatchQueue(label: "at.fubl.ablage.archive.filings", qos: .utility)
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
    private var previewGeneration = 0
    private var previewRevisions = [String: Int]()
    private var previews = [String: FilePlan]()
    private var previewInFlight = Set<String>()
    private var recognitionPending = [String: FileFacts]()
    private var recognitionOrder: [String] = []
    private var recognitionActive: String?
    private var progress: Progress?
    private let cancelLock = NSLock()
    private var batchCancelled = false

    var onUpdate: ((Snapshot) -> Void)?

    /// Simulation is on until the user turns it off once, so a fresh install never moves anything unseen.
    var simulate: Bool {
        get { ProcessInfo.processInfo.environment["ABLAGE_SIMULATE"].map { $0 != "0" } ?? (defaults.object(forKey: Self.simulateKey) as? Bool ?? true) }
        set { defaults.set(newValue, forKey: Self.simulateKey) }
    }

    var paused: Bool {
        get { ProcessInfo.processInfo.environment["ABLAGE_PAUSED"].map { $0 == "1" } ?? defaults.bool(forKey: Self.pausedKey) }
        set {
            defaults.set(newValue, forKey: Self.pausedKey)
            if !newValue { queue.async { self.inboxes.forEach { self.scheduleScan($0, after: 0) }; self.startRecognition() } }
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
            if !self.config.keepOriginalsForever { Originals.purge(olderThanDays: self.config.originalsDays) }
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
            let candidate = try ConfigStore.load()
            let issues = ConfigStore.problems(in: candidate)
            guard issues.isEmpty else { throw ConfigError(message: issues.joined(separator: "\n")) }
            config = candidate
            configError = nil
            Log.write("config loaded: \(config.rules.count) shared rules, \(config.resolvedInboxes.count) inbox(es)")
        } catch {
            configError = "config.json: \(ConfigStore.describe(error))"
            Log.write("config error: \(error)")
        }
        classifier = Classifier(config: config.ai)
        MailIngestor.shared.configure(config.mailAccounts)
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
        previewGeneration += 1
        previews.removeAll()
        previewInFlight.removeAll()
        recognitionPending.removeAll()
        recognitionOrder.removeAll()
        attachInboxes()
        scheduleRescan()
        publish()
    }

    private func attachInboxes() {
        let previous = Dictionary(uniqueKeysWithValues: inboxes.map { ($0.url.path, $0) })
        for inbox in inboxes { inbox.scanWork?.cancel() }
        inboxes = config.resolvedInboxes.map { Inbox($0, shared: config.rules, sortExistingDefault: config.sortExistingOnRescan, sharedIgnore: config.ignore) }
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
            if let old = previous[inbox.url.path] {
                inbox.known = old.known
                inbox.pending = old.pending
                inbox.heldBack = old.heldBack
                scheduleScan(inbox, after: 0.1)
            } else {
                for url in list(inbox) { inbox.known.insert(url.path) }
            }
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
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: inbox.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            inbox.accessError = nil
        } catch {
            inbox.accessError = "Could not read \(inbox.label): \(error.localizedDescription)"
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

    /// An inbox for a file that lives elsewhere, so dropped files still get the shared rules.
    private func inboxOrTemporary(for path: String) -> Inbox {
        inbox(holding: path) ?? Inbox(
            InboxConfig(path: URL(fileURLWithPath: path).deletingLastPathComponent().path, ignore: nil, rules: nil, sortExistingOnRescan: nil),
            shared: config.rules, sortExistingDefault: false)
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
        if paused || !inbox.enabled {
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
        for inbox in inboxes where inbox.enabled && !inbox.reviewFirst {
            let mode: Mode = inbox.sortExistingOnRescan ? .all : .ageOnly
            for url in list(inbox) where inbox.known.contains(url.path) && inbox.pending[url.path] == nil {
                process(url: url, in: inbox, mode: mode)
            }
        }
        schedulePreviews()
        publish()
    }

    // MARK: Batch actions

    func cancelCurrentBatch() {
        cancelLock.lock()
        batchCancelled = true
        cancelLock.unlock()
    }

    private func isBatchCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return batchCancelled
    }

    func sortAll() {
        queue.async {
            let work = self.inboxes.flatMap { inbox in self.list(inbox).filter { inbox.known.contains($0.path) && inbox.pending[$0.path] == nil }.map { $0.path } }
            self.run(work, label: "sort") { path, inbox in self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all) }
        }
    }

    func sort(paths: [String]) {
        queue.async {
            self.run(paths, label: "sort") { path, inbox in self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all) }
        }
    }

    func apply(ruleNamed name: String, paths: [String]) {
        queue.async {
            self.run(paths, label: "apply") { path, inbox in
                guard let rule = inbox.rules.first(where: { $0.name == name }) else {
                    self.journal.add(JournalEntry(rule: name, kind: .error, from: path, message: "no rule of that name applies to this inbox"))
                    return
                }
                self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all, forced: rule)
            }
        }
    }

    func trash(paths: [String], requiring digests: [String: String] = [:]) {
        queue.async {
            for path in paths {
                do {
                    guard digests.allSatisfy({ Hashing.digest(URL(fileURLWithPath: $0.key))?.hex == $0.value }) else {
                        throw ConfigError(message: "A compared document changed or disappeared. Refresh the archive and compare both copies again.")
                    }
                    if self.simulate {
                        self.journal.add(JournalEntry(rule: "manual", kind: .simulated, from: path, message: "would move to Trash", origin: "manual"))
                        continue
                    }
                    var trashed: NSURL?
                    try self.fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
                    if let target = trashed?.path { try? DocumentLibrary.shared.retire(path, trash: target) }
                    self.journal.add(JournalEntry(rule: "manual", kind: .trashed, from: path, trashPath: trashed?.path, origin: "manual"))
                } catch {
                    self.journal.add(JournalEntry(rule: "manual", kind: .error, from: path, message: error.localizedDescription))
                }
            }
            self.publish()
            DispatchQueue.main.async { NotificationCenter.default.post(name: .ablageArchiveChanged, object: nil) }
        }
    }

    /// An explicit duplicate review always retains a revalidated copy and records Undo information.
    func trashDuplicates(_ request: DuplicateRemoval, completion: @escaping (DuplicateRemovalResult) -> Void) {
        queue.async {
            var result = DuplicateRemovalResult()
            let preview = self.simulate
            do {
                try request.validate()
                for copy in request.copies {
                    // Recheck the retained copy before each removal, including after a previous copy moved.
                    guard try ExactDuplicateScanner.digest(request.keeper) == request.digest,
                          try ExactDuplicateScanner.digest(copy) == request.digest else {
                        throw ConfigError(message: "A compared file changed. Remaining copies were left in place; scan again.")
                    }
                    if preview {
                        self.journal.add(JournalEntry(rule: "Duplicate finder", kind: .simulated, from: copy.path,
                                                      message: "would move identical copy to Trash; keep " + Paths.abbreviate(request.keeper.path), origin: "manual"))
                        result.previewed += 1
                    } else {
                        var trashed: NSURL?
                        try self.fm.trashItem(at: copy.url, resultingItemURL: &trashed)
                        if let target = trashed?.path { try? DocumentLibrary.shared.retire(copy.path, trash: target) }
                        self.journal.add(JournalEntry(rule: "Duplicate finder", kind: .trashed, from: copy.path,
                                                      trashPath: trashed?.path, message: "Identical copy retained at " + Paths.abbreviate(request.keeper.path), origin: "manual"))
                        result.removedPaths.append(copy.path)
                    }
                }
            } catch {
                result.error = error.localizedDescription
                self.journal.add(JournalEntry(rule: "Duplicate finder", kind: .error, from: request.keeper.path, message: error.localizedDescription))
            }
            self.publish()
            let finished = result
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ablageArchiveChanged, object: nil)
                completion(finished)
            }
        }
    }

    /// Files dropped onto the panel. They need not live in an inbox; the shared rules still apply.
    func file(paths: [String]) {
        queue.async {
            self.run(paths, label: "drop") { path, inbox in
                if !self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all) {
                    self.journal.add(JournalEntry(rule: "drop", kind: .skipped, from: path, message: "no rule matched"))
                }
            }
        }
    }

    /// Runs a step over many files with progress in the panel. On the engine queue.
    private func run(_ paths: [String], label: String, step: (String, Inbox) -> Void) {
        cancelLock.lock()
        batchCancelled = false
        cancelLock.unlock()
        let standardized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        progress = Progress(done: 0, total: standardized.count)
        publish()
        for (i, path) in standardized.enumerated() {
            if isBatchCancelled() { Log.write("\(label): stopped after \(i) of \(standardized.count) files"); break }
            let inbox = inboxOrTemporary(for: path)
            inbox.known.insert(path)
            step(path, inbox)
            progress = Progress(done: i + 1, total: standardized.count)
            if (i + 1) % 5 == 0 { publish() }
        }
        progress = nil
        schedulePreviews()
        publish()
    }

    // MARK: Single-file actions

    func reviewDocument(path: String, completion: @escaping (Result<DocumentReviewPacket, Error>) -> Void) {
        queue.async {
            do {
                let url = URL(fileURLWithPath: path)
                guard let facts = FileFacts(url: url), !facts.isFolder, let digest = Hashing.digest(url)?.hex else { throw ConfigError(message: "This document is unavailable.") }
                let inbox = self.inboxOrTemporary(for: path)
                let file = self.context(for: facts)
                let text = file.content ?? ""
                let plan = FilePlan.evaluate(rules: inbox.rules, file: file, inbox: inbox.url, config: self.config, ocrPending: { false }, textFailure: { self.cache.failure(self.cache.key(for: facts, config: self.config)) }, learned: { self.learnedSuggestion(file, rules: inbox.rules) })
                self.refreshPreview(for: facts)
                var metadata = try DocumentLibrary.shared.metadata(for: path) ?? DocumentMetadata.suggestions(name: facts.name, text: text)
                if let rule = inbox.rules.first(where: { $0.name == plan.rule }) {
                    let context = rule.templateContext(for: file, enrichment: nil)
                    if metadata.correspondent.isEmpty { metadata.correspondent = context.correspondent }
                    if metadata.documentDate.isEmpty { metadata.documentDate = DocumentMetadata.dateString(context.date) }
                }
                guard Hashing.digest(url)?.hex == digest else { throw ConfigError(message: "The document changed while loading. Open review again.") }
                let packet = DocumentReviewPacket(facts: facts, text: text, metadata: metadata, rules: inbox.rules, inbox: inbox.url, config: self.config, plan: plan, digest: digest)
                DispatchQueue.main.async { completion(.success(packet)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func approve(_ packet: DocumentReviewPacket, draft: DocumentReviewDraft, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                try draft.validate()
                guard Hashing.digest(packet.facts.url)?.hex == packet.digest else { throw ConfigError(message: "This file changed since you opened it. Reload before approving.") }
                guard let facts = FileFacts(url: packet.facts.url) else { throw ConfigError(message: "The file is no longer available.") }
                let inbox = self.inboxOrTemporary(for: facts.url.path)
                inbox.known.insert(facts.url.path)
                var action = Action()
                action.trash = draft.trash
                action.run = draft.command
                if !draft.trash {
                    // The engine preserves the source extension. Review does not change file formats.
                    let name = URL(fileURLWithPath: draft.filename.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard name.pathExtension.lowercased() == facts.ext else { throw ConfigError(message: "Keep the .\(facts.extOriginal) extension; renaming cannot convert the document format.") }
                    action.destination = Paths.expand(draft.folder)
                    action.rename = facts.extOriginal.isEmpty ? name.lastPathComponent : name.deletingPathExtension().lastPathComponent
                    action.tags = RuleDraft.list(draft.tags)
                }
                let previous = self.journal.entries.first?.id
                let previousMetadata = try DocumentLibrary.shared.metadata(for: facts.url.path)
                let rule = Rule(name: draft.ruleName, action: action)
                let file = FileContext(facts: facts, metadata: draft.metadata) { packet.text }
                self.perform(rule, file, in: inbox, enrichment: nil, origin: "manual", note: "reviewed")
                let entry = self.journal.entries.first.flatMap { $0.id != previous ? $0 : nil }
                if entry?.kind == .error || entry?.kind == .skipped { throw ConfigError(message: entry?.message ?? "The file could not be filed.") }
                if !self.simulate, !draft.trash {
                    let path = entry?.kind == .moved ? (entry?.to ?? facts.url.path) : facts.url.path
                    if self.fm.fileExists(atPath: path) {
                        try DocumentLibrary.shared.saveMetadata(draft.metadata, for: path)
                        if let entry, entry.kind == .moved || entry.kind == .tagged {
                            self.journal.recordMetadataEdit(entry.id, previous: previousMetadata)
                        } else {
                            let edit = JournalEntry(rule: draft.ruleName, kind: .tagged, from: path, message: "document details updated", origin: "manual", previousTags: Tags.read(URL(fileURLWithPath: path)), metadataEdited: true, previousMetadata: previousMetadata)
                            self.journal.add(edit)
                        }
                        self.indexFiled(URL(fileURLWithPath: path))
                    }
                }
                self.refreshPreviews()
                self.publish()
                let message = self.simulate ? "Preview recorded. No files changed." : "Approved."
                DispatchQueue.main.async { completion(.success(message)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private func indexFiled(_ url: URL, original: String = "") {
        let config = self.config
        // Capture the filed bytes now; a queued text extraction must not silently accept a later edit.
        guard let filedDigest = Hashing.digest(url)?.hex else { return }
        archiveQueue.async {
            do {
                var preserved = original
                if preserved.isEmpty, config.keepOriginalsForever,
                   (try DocumentLibrary.shared.document(at: url.path)?.original ?? "").isEmpty {
                    preserved = try OriginalVault.keep(url).path
                }
                try DocumentLibrary.shared.index(url, config: config, original: preserved, filedDigest: filedDigest)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .ablageArchiveChanged, object: nil) }
            } catch { Log.write("archive: " + error.localizedDescription) }
        }
    }

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
            self.run([path], label: "apply") { path, inbox in
                guard let rule = inbox.rules.first(where: { $0.name == name }) else {
                    self.journal.add(JournalEntry(rule: name, kind: .error, from: path, message: "rule not found after saving, check config.json"))
                    return
                }
                self.process(url: URL(fileURLWithPath: path), in: inbox, mode: .all, forced: rule)
            }
        }
    }

    /// Facts and a text excerpt for the rule editor. Completion runs on the main thread.
    func excerpt(path: String, completion: @escaping (FileFacts?, String) -> Void) {
        queue.async {
            let facts = FileFacts(url: URL(fileURLWithPath: path))
            var text = ""
            if let facts {
                let raw = self.context(for: facts).content ?? ""
                self.refreshPreview(for: facts)
                text = String(raw.prefix(1500)).replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            }
            DispatchQueue.main.async { completion(facts, text) }
        }
    }

    func ask(model: String, path: String) {
        queue.async {
            guard let inbox = self.inbox(holding: path), let facts = FileFacts(url: URL(fileURLWithPath: path)) else { return }
            let file = self.context(for: facts)
            inbox.known.insert(path)
            if self.aiCandidates(file, rules: inbox.rules).isEmpty {
                self.journal.add(JournalEntry(rule: model, kind: .skipped, from: path, message: "no rule with an ai description applies here"))
            } else {
                _ = self.askModels(file, in: inbox, only: model, manual: true)
            }
            self.schedulePreviews()
            self.publish()
        }
    }

    func trash(path: String) { trash(paths: [path]) }

    func undo(_ id: UUID) {
        queue.async {
            guard let entry = self.journal.entries.first(where: { $0.id == id }), entry.canUndo else { return }
            let original = URL(fileURLWithPath: entry.from)
            let source: URL?
            switch entry.kind {
            case .moved: source = entry.to.map { URL(fileURLWithPath: $0) }
            case .trashed, .duplicate: source = entry.trashPath.map { URL(fileURLWithPath: $0) }
            case .tagged: source = original
            default: source = nil
            }
            guard let source, self.fm.fileExists(atPath: source.path) else {
                self.journal.add(JournalEntry(rule: "undo", kind: .error, from: entry.from, message: "file no longer there"))
                self.publish()
                return
            }
            if entry.kind == .tagged {
                guard Tags.write(entry.previousTags, to: original) else {
                    self.journal.add(JournalEntry(rule: "undo", kind: .error, from: entry.from, message: "Could not restore Finder tags"))
                    self.publish()
                    return
                }
                if entry.metadataEdited == true {
                    do {
                        if let metadata = entry.previousMetadata { try DocumentLibrary.shared.saveMetadata(metadata, for: original.path) }
                        else { try DocumentLibrary.shared.clearMetadata(for: original.path) }
                    } catch {
                        self.journal.add(JournalEntry(rule: "undo", kind: .error, from: original.path, message: "Tags restored, but document details could not be restored: " + error.localizedDescription))
                        self.publish(); return
                    }
                }
                self.indexFiled(original)
                self.journal.markUndone(id)
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
                try? DocumentLibrary.shared.relocate(from: source.path, to: target.path)
                if entry.kind == .moved {
                    Tags.write(entry.previousTags, to: target)
                    if Originals.restore(for: id, to: target) { Log.write("undo: original bytes restored for \(target.lastPathComponent)") }
                }
                if entry.metadataEdited == true {
                    do {
                        if let metadata = entry.previousMetadata { try DocumentLibrary.shared.saveMetadata(metadata, for: target.path) }
                        else { try DocumentLibrary.shared.clearMetadata(for: target.path) }
                    } catch {
                        self.journal.add(JournalEntry(rule: "undo", kind: .error, from: target.path, message: "File restored, but document details could not be restored: " + error.localizedDescription))
                    }
                }
                self.indexFiled(target)
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

    /// Undoing a filing takes back its example; undoing a learned one also records a counterexample.
    private func teachFromUndo(_ entry: JournalEntry, restored: URL) {
        guard config.learning.enabled else { return }
        learner.forget(entryId: entry.id)
        guard entry.origin == "learned", let facts = FileFacts(url: restored) else { return }
        learner.learn(rule: entry.rule, facts: facts, text: context(for: facts).content, weight: 1, positive: false, confirmAfter: nil, entryId: entry.id)
    }

    // MARK: Processing

    private func context(for facts: FileFacts) -> FileContext {
        let config = self.config
        let cache = self.cache
        let metadata = (try? DocumentLibrary.shared.metadata(for: facts.url.path)) ?? DocumentMetadata()
        return FileContext(facts: facts, metadata: metadata) { cache.text(for: facts, config: config, allowOCR: true) }
    }

    /// Plain rules first. Then what the user taught. Models only where a rule names one.
    @discardableResult
    private func process(url: URL, in inbox: Inbox, mode: Mode, forced: Rule? = nil) -> Bool {
        guard !inbox.reviewFirst || mode == .all || forced != nil else { return false }
        guard let facts = FileFacts(url: url) else { return false }
        // A run may resolve OCR without modifying the file. Retire its earlier plan,
        // including any read-only preview still in flight, before publishing again.
        previewRevisions[url.path, default: 0] += 1
        let file = context(for: facts)
        let rules = inbox.rules

        if let forced {
            perform(forced, file, in: inbox, enrichment: enrichment(for: forced, file, manual: true), origin: "manual", note: nil)
            return true
        }

        let plain = rules.first { rule in
            guard rule.isEnabled, rule.match.ai == nil else { return false }
            if mode == .ageOnly, rule.match.minAgeDays == nil { return false }
            return Matcher.matches(rule.match, file)
        }
        if let failure = cache.failure(cache.key(for: facts, config: config)) {
            journal.add(JournalEntry(rule: "Text recognition", kind: .skipped, from: url.path, message: failure))
            return true
        }
        if let plain {
            perform(plain, file, in: inbox, enrichment: enrichment(for: plain, file, manual: false), origin: "rule", note: nil)
            return true
        }
        guard mode != .ageOnly else { return false }

        let suggestion = learnedSuggestion(file, rules: rules)
        if let failure = cache.failure(cache.key(for: facts, config: config)) {
            journal.add(JournalEntry(rule: "Text recognition", kind: .skipped, from: url.path, message: failure))
            return true
        }
        if let suggestion, let rule = rules.first(where: { $0.name == suggestion.rule }) {
            var note = "like \(suggestion.like) (\(Int(suggestion.similarity * 100))%)"
            if suggestion.confidence < 1 { note += ", \(Int(suggestion.confidence * 100))% sure" }
            perform(rule, file, in: inbox, enrichment: nil, origin: "learned", note: note)
            return true
        }
        return askModels(file, in: inbox, only: nil, manual: false)
    }

    private func learnableRules(_ rules: [Rule]) -> Set<String> {
        Set(rules.filter { $0.isEnabled && $0.match.ai == nil && $0.action.trash != true && !$0.action.isNoop }.map(\.name))
    }

    private func learnedSuggestion(_ file: FileContext, rules: [Rule]) -> Suggestion? {
        guard config.learning.enabled else { return nil }
        let names = learnableRules(rules)
        guard !names.isEmpty, learner.examples.contains(where: { names.contains($0.rule) }) else { return nil }
        return learner.suggest(facts: file.facts, text: file.content, among: names, config: config.learning)
    }

    private func aiCandidates(_ file: FileContext, rules: [Rule]) -> [Rule] {
        rules.filter { $0.isEnabled && $0.match.ai != nil && Matcher.matches($0.match, file) }
    }

    /// Remote models wait for a manual request unless marked automatic.
    private func askModels(_ file: FileContext, in inbox: Inbox, only: String?, manual: Bool) -> Bool {
        let facts = file.facts
        let candidates = aiCandidates(file, rules: inbox.rules)
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
            let text = file.content
            guard manual || cache.failure(cache.key(for: facts, config: config)) == nil else { return false }
            guard let result = classifier.classify(facts: facts, text: text, candidates: pool, model: name) else {
                if manual { journal.add(JournalEntry(rule: name, kind: .skipped, from: facts.url.path, message: "no answer, see log")) }
                continue
            }
            if (1...pool.count).contains(result.category) {
                perform(pool[result.category - 1], file, in: inbox, enrichment: result, origin: "model:\(name)", note: nil)
                return true
            }
            if manual { journal.add(JournalEntry(rule: name, kind: .skipped, from: facts.url.path, message: "no category fits")) }
        }
        return false
    }

    private func enrichment(for rule: Rule, _ file: FileContext, manual: Bool) -> Classification? {
        guard let name = rule.action.ai else { return nil }
        guard let model = config.ai.models[name] else {
            Log.write("ai: model \"\(name)\" is not defined under ai.models")
            return nil
        }
        guard manual || model.runsAutomatically else {
            Log.write("ai: \(name) is remote and not automatic, no enrichment for \(file.facts.name)")
            return nil
        }
        let text = file.content
        guard manual || cache.failure(cache.key(for: file.facts, config: config)) == nil else { return nil }
        return classifier.classify(facts: file.facts, text: text, candidates: [], model: name)
    }

    private func perform(_ rule: Rule, _ file: FileContext, in inbox: Inbox, enrichment: Classification?, origin: String, note: String?) {
        let facts = file.facts
        let action = rule.action
        let context = rule.templateContext(for: file, enrichment: enrichment)
        if origin != "manual", let failure = cache.failure(cache.key(for: facts, config: config)) {
            journal.add(JournalEntry(rule: rule.name, kind: .skipped, from: facts.url.path, message: failure))
            return
        }
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
                var trashed: NSURL?
                try fm.trashItem(at: facts.url, resultingItemURL: &trashed)
                if let target = trashed?.path { try? DocumentLibrary.shared.retire(facts.url.path, trash: target) }
                journal.add(JournalEntry(rule: rule.name, kind: .trashed, from: facts.url.path, trashPath: trashed?.path, message: message, origin: origin))
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

        var target = rule.targetURL(for: facts, context: context, inbox: inbox.url)
        if Patterns.matches(#"\{(?:invoice_number|amount|currency|due_date|type|field\.[^{}]+)\}"#, target.path) {
            journal.add(JournalEntry(rule: rule.name, kind: .skipped, from: facts.url.path, message: "Document fields need completing in Review & file."))
            return
        }
        let folder = target.deletingLastPathComponent()
        let previousTags = Tags.read(facts.url)
        let newTags = (action.tags ?? []).filter { !previousTags.contains($0) }

        if FileIdentity.same(target, facts.url) {
            guard !newTags.isEmpty else { return }
            if simulate {
                journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, message: "would tag \(newTags.joined(separator: ", "))", origin: origin))
                return
            }
            guard Tags.write(previousTags + newTags, to: facts.url) else {
                journal.add(JournalEntry(rule: rule.name, kind: .error, from: facts.url.path, message: "Could not update Finder tags"))
                return
            }
            journal.add(JournalEntry(rule: rule.name, kind: .tagged, from: facts.url.path, message: newTags.joined(separator: ", "), origin: origin, previousTags: previousTags))
            indexFiled(facts.url)
            if let command = action.run { runHook(command, rule: rule.name, from: facts.url.path, to: facts.url.path) }
            return
        }
        if simulate {
            journal.add(JournalEntry(rule: rule.name, kind: .simulated, from: facts.url.path, to: target.path, message: message, origin: origin))
            return
        }
        // Features are read before the move, while the file is still where the facts say.
        let learnText = config.learning.enabled ? file.content : nil
        do {
            var original = try DocumentLibrary.shared.document(at: facts.url.path)?.original ?? ""
            if original.isEmpty, config.keepOriginalsForever, !facts.isFolder { original = try OriginalVault.keep(facts.url).path }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                if !facts.isFolder, Hashing.identical(facts.url, target) {
                    var trashed: NSURL?
                    try fm.trashItem(at: facts.url, resultingItemURL: &trashed)
                    if let target = trashed?.path { try? DocumentLibrary.shared.retire(facts.url.path, trash: target) }
                    journal.add(JournalEntry(
                        rule: rule.name, kind: .duplicate, from: facts.url.path, to: target.path, trashPath: trashed?.path,
                        message: "identical file already there, copy moved to Trash", origin: origin))
                    notify(rule.name, "\(facts.name) is a duplicate, moved to Trash", path: target.path)
                    return
                }
                target = Hashing.unique(target)
            }
            try fm.moveItem(at: facts.url, to: target)
            try? DocumentLibrary.shared.relocate(from: facts.url.path, to: target.path)
            if !newTags.isEmpty { Tags.write(previousTags + newTags, to: target) }
            let entry = JournalEntry(rule: rule.name, kind: .moved, from: facts.url.path, to: target.path, message: message, origin: origin, previousTags: previousTags)
            journal.add(entry)
            indexFiled(target, original: original)
            remember(rule, facts, text: learnText, origin: origin, entryId: entry.id)
            notify(rule.name, "\(facts.name) → \(Paths.abbreviate(folder.path))", path: target.path)
            if let command = action.run { runHook(command, rule: rule.name, from: facts.url.path, to: target.path) }
            scheduleTextLayer(for: target, entryId: entry.id, rule: rule.name)
        } catch {
            journal.add(JournalEntry(rule: rule.name, kind: .error, from: facts.url.path, to: target.path, message: error.localizedDescription))
        }
    }

    /// Every filing is training data. Hand filings count at once and weigh more; rule filings count
    /// after the confirmation period, so an undo can still take them back.
    private func remember(_ rule: Rule, _ facts: FileFacts, text: String?, origin: String, entryId: UUID) {
        guard config.learning.enabled, rule.action.trash != true, rule.match.ai == nil else { return }
        let manual = origin == "manual"
        guard manual || config.learning.fromRules else { return }
        let confirmAfter = manual ? nil : Date().addingTimeInterval(config.learning.confirmAfterHours * 3600)
        let weight = manual ? 3.0 : (origin == "rule" ? 1.0 : 0.5)
        learner.learn(rule: rule.name, facts: facts, text: text, weight: weight, positive: true, confirmAfter: confirmAfter, entryId: entryId)
    }

    /// Scans get a text layer after filing, in the background. The original bytes are kept for Undo.
    private func scheduleTextLayer(for url: URL, entryId: UUID, rule: String) {
        guard config.searchablePDFs, url.pathExtension.lowercased() == "pdf" else { return }
        let maxPages = config.textLayerMaxPages
        let maxBytes = Int64(config.ocrMaxMB * 1_048_576)
        layerQueue.async { [weak self] in
            guard let self else { return }
            guard let size = (try? self.fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.int64Value <= maxBytes else { return }
            guard !SearchablePDF.hasTextLayer(url) else { return }
            let work = self.fm.temporaryDirectory.appendingPathComponent("ablage-ocr-" + UUID().uuidString, isDirectory: true)
            let staged = work.appendingPathComponent(url.lastPathComponent)
            do {
                // OCR works on a private copy. Undo and later filings can proceed independently.
                try self.fm.createDirectory(at: work, withIntermediateDirectories: true)
                try self.fm.copyItem(at: url, to: staged)
                guard let originalHash = Hashing.digest(staged) else { throw ConfigError(message: "Could not read PDF for OCR") }
                let pages = try SearchablePDF.addTextLayer(to: staged, maxPages: maxPages)
                self.queue.async {
                    defer { try? self.fm.removeItem(at: work) }
                    // Never recreate an undone file or overwrite a document edited during OCR.
                    guard self.journal.entries.contains(where: { $0.id == entryId && !$0.undone }),
                          Hashing.digest(url) == originalHash else {
                        Log.write("text layer: skipped changed or undone file \(url.lastPathComponent)")
                        return
                    }
                    do {
                        let tags = Tags.read(url)
                        try Originals.keep(url, for: entryId)
                        _ = try self.fm.replaceItemAt(url, withItemAt: staged)
                        Tags.write(tags, to: url)
                        self.indexFiled(url)
                        self.journal.add(JournalEntry(rule: rule, kind: .textLayer, from: url.path, to: url.path, message: "searchable now, \(pages) page\(pages == 1 ? "" : "s") of text", origin: "rule"))
                        self.publish()
                    } catch { Log.write("text layer: \(url.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch {
                try? self.fm.removeItem(at: work)
                Log.write("text layer: \(url.lastPathComponent): \(error.localizedDescription)")
            }
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

    func refreshPreviews() {
        queue.async {
            self.previewGeneration += 1
            self.previews.removeAll()
            self.previewInFlight.removeAll()
            self.schedulePreviews()
            self.publish()
        }
    }

    private func previewKey(for facts: FileFacts) -> String {
        cache.key(for: facts, config: config) + "|\(facts.ageDays)|\(previewRevisions[facts.url.path, default: 0])|" + Tags.read(facts.url).sorted().joined(separator: "\u{1f}")
    }

    private func schedulePreviews() {
        var liveKeys = Set<String>()
        var livePaths = Set<String>()
        for inbox in inboxes {
            for url in list(inbox) where inbox.known.contains(url.path) && inbox.pending[url.path] == nil {
                guard let facts = FileFacts(url: url) else { continue }
                liveKeys.insert(previewKey(for: facts))
                livePaths.insert(url.path)
                schedulePreview(for: facts, in: inbox)
            }
        }
        previews = previews.filter { liveKeys.contains($0.key) }
        previewRevisions = previewRevisions.filter { livePaths.contains($0.key) }
        recognitionPending = recognitionPending.filter { livePaths.contains($0.value.url.path) }
        recognitionOrder.removeAll { recognitionPending[$0] == nil }
    }

    private func schedulePreview(for facts: FileFacts, in inbox: Inbox) {
        let key = previewKey(for: facts)
        guard previews[key] == nil, !previewInFlight.contains(key) else { return }
        let config = self.config
        let generation = previewGeneration
        let rules = inbox.rules.filter(\.isEnabled)
        let learnable = learnableRules(rules)
        let contentKey = cache.key(for: facts, config: config)
        previewInFlight.insert(key)
        previewQueue.async { [weak self] in
            guard let self else { return }
            let metadata = (try? DocumentLibrary.shared.metadata(for: facts.url.path)) ?? DocumentMetadata()
            let file = FileContext(facts: facts, metadata: metadata) { self.cache.text(for: facts, config: config, allowOCR: false) }
            let plan = FilePlan.evaluate(rules: rules, file: file, inbox: inbox.url, config: config,
                ocrPending: { self.cache.ocrPending(contentKey) },
                textFailure: { self.cache.failure(contentKey) },
                learned: {
                    guard config.learning.enabled, !learnable.isEmpty else { return nil }
                    return self.learner.suggest(facts: facts, text: file.content, among: learnable, config: config.learning)
                })
            self.queue.async {
                guard self.previewGeneration == generation else { return }
                self.previewInFlight.remove(key)
                guard let current = FileFacts(url: facts.url), self.previewKey(for: current) == key else { return }
                self.previews[key] = plan.state == .needsOCR && self.recognitionActive == contentKey ? .readingText : plan
                if self.cache.ocrPending(contentKey) { self.enqueueRecognition(facts) }
                self.schedulePublish()
            }
        }
    }

    private func refreshPreview(for facts: FileFacts) {
        guard let inbox = inboxes.first(where: { $0.holds(facts.url.path) }), inbox.pending[facts.url.path] == nil else { return }
        previews.removeValue(forKey: previewKey(for: facts))
        previewRevisions[facts.url.path, default: 0] += 1
        schedulePreview(for: facts, in: inbox)
        schedulePublish()
    }

    /// Only extraction happens here: no file mutations, rule actions or model requests.
    private func enqueueRecognition(_ facts: FileFacts, first: Bool = false) {
        let key = cache.key(for: facts, config: config)
        guard recognitionActive != key else { return }
        if first { recognitionOrder.removeAll { $0 == key } }
        if recognitionPending[key] == nil || first {
            recognitionPending[key] = facts
            if first { recognitionOrder.insert(key, at: 0) } else { recognitionOrder.append(key) }
        }
        startRecognition()
    }

    private func startRecognition() {
        guard !paused, recognitionActive == nil else { return }
        while !recognitionOrder.isEmpty {
            let key = recognitionOrder.removeFirst()
            guard let facts = recognitionPending.removeValue(forKey: key),
                  let current = FileFacts(url: facts.url), cache.key(for: current, config: config) == key,
                  inboxes.contains(where: { $0.holds(facts.url.path) && $0.known.contains(facts.url.path) && $0.pending[facts.url.path] == nil }),
                  cache.ocrPending(key) else { continue }
            let config = self.config
            recognitionActive = key
            let planKey = previewKey(for: facts)
            if previews[planKey]?.state == .needsOCR { previews[planKey] = .readingText }
            schedulePublish()
            recognitionQueue.async { [weak self] in
                guard let self else { return }
                _ = self.cache.text(for: facts, config: config, allowOCR: true)
                self.queue.async {
                    self.recognitionActive = nil
                    if let current = FileFacts(url: facts.url), self.cache.key(for: current, config: self.config) == key {
                        self.refreshPreview(for: current)
                    }
                    self.startRecognition()
                }
            }
            return
        }
    }

    func readTextNext(path: String) {
        queue.async {
            guard let facts = FileFacts(url: URL(fileURLWithPath: path)) else { return }
            let key = self.cache.key(for: facts, config: self.config)
            self.cache.retryFailure(key)
            if self.cache.ocrPending(key) { self.enqueueRecognition(facts, first: true) }
            self.refreshPreview(for: facts)
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
                let preview = previews[previewKey(for: facts)]
                own.append(InboxItem(
                    id: url.path, inboxIndex: index, name: facts.name, isFolder: facts.isFolder, size: facts.size, ageDays: facts.ageDays,
                    added: facts.added, status: (inbox.pending[url.path] != nil || !inbox.known.contains(url.path)) ? .settling : .unsorted, preview: preview))
            }
            own.sort { $0.added > $1.added }
            items += own
        }
        let issues = ([configError] + inboxes.map(\.accessError)).compactMap { $0 }
        let snapshot = Snapshot(
            inboxes: inboxes.map { InboxInfo(label: $0.label, path: $0.url.path, ruleNames: $0.rules.map(\.name), enabled: $0.enabled, reviewFirst: $0.reviewFirst) },
            items: items, journal: journal.entries, aiModels: config.ai.modelNames,
            configError: issues.isEmpty ? nil : issues.joined(separator: "\n"), progress: progress, filedThisMonth: filedThisMonth(), examples: learner.examples.count)
        onUpdate?(snapshot)
    }
}
