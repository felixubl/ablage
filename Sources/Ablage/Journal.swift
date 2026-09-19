import Foundation

enum EntryKind: String, Codable {
    case moved, trashed, duplicate, tagged, simulated, skipped, error
}

struct JournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var rule: String
    var kind: EntryKind
    var from: String
    var to: String?
    var message: String?
    /// rule | manual | learned | model. Undo uses it to teach or forget.
    var origin: String?
    var previousTags: [String] = []
    var undone = false

    var canUndo: Bool { !undone && (kind == .moved || kind == .trashed || kind == .duplicate) }
}

final class Journal {
    private(set) var entries: [JournalEntry] = []
    private let limit = 500

    func load() {
        guard let data = try? Data(contentsOf: Paths.journalFile) else { return }
        entries = (try? JSONDecoder().decode([JournalEntry].self, from: data)) ?? []
    }

    func add(_ entry: JournalEntry) {
        // Rescans in simulation would otherwise report the same file every time.
        if entry.kind == .simulated, entries.contains(where: {
            $0.kind == .simulated && $0.rule == entry.rule && $0.from == entry.from && $0.to == entry.to && $0.message == entry.message
        }) { return }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
        Log.write(describe(entry))
    }

    func markUndone(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].undone = true
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Paths.journalFile, options: .atomic)
    }

    private func describe(_ e: JournalEntry) -> String {
        var parts = ["\(e.kind.rawValue)", "[\(e.rule)]", Paths.abbreviate(e.from)]
        if let to = e.to { parts += ["->", Paths.abbreviate(to)] }
        if let m = e.message { parts.append("(\(m))") }
        return parts.joined(separator: " ")
    }
}
