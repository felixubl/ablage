import Foundation
import SQLite3

struct LibraryQuery: Codable, Equatable {
    var text = ""
    var folder = ""
    var tag = ""
    var type = ""
    var correspondent = ""
    var fromDate = ""
    var toDate = ""
    var field = ""
    var fieldValue = ""
}
struct SavedLibraryView: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: LibraryQuery
}
struct LibraryDocument: Identifiable, Equatable {
    var path: String
    var name: String
    var text: String
    var tags: [String]
    var metadata: DocumentMetadata
    var digest: String
    var baseline: String
    var original: String
    var modified: Date
    var missing: Bool
    var retired = false
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var date: String { metadata.documentDate.isEmpty ? DocumentMetadata.dateString(modified) : metadata.documentDate }
}

/// Local search, metadata and integrity records. Files remain in their ordinary Finder folders.
final class DocumentLibrary {
    static let shared = DocumentLibrary(url: Paths.supportDirectory.appendingPathComponent("archive.sqlite"))
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var failure: String?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw ConfigError(message: "Could not open the document index.")
            }
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS documents(path TEXT PRIMARY KEY, name TEXT NOT NULL, text TEXT NOT NULL, tags TEXT NOT NULL, metadata TEXT NOT NULL, digest TEXT NOT NULL, baseline TEXT NOT NULL, original TEXT NOT NULL, modified REAL NOT NULL, missing INTEGER NOT NULL DEFAULT 0, retired INTEGER NOT NULL DEFAULT 0)")
            // Migration from early index builds, without discarding the integrity baselines.
            try? execute("ALTER TABLE documents ADD COLUMN retired INTEGER NOT NULL DEFAULT 0")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(path UNINDEXED, name, text, fields, tokenize='unicode61 remove_diacritics 2')")
            try execute("CREATE TABLE IF NOT EXISTS metadata(path TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        } catch { failure = error.localizedDescription }
    }
    deinit { sqlite3_close(db) }

    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        if let failure { throw ConfigError(message: failure) }
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConfigError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Document index unavailable")
        }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        return statement
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw ConfigError(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().path }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    func metadata(for path: String) throws -> DocumentMetadata? {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT value FROM metadata WHERE path=?", [Self.canonical(path)]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(DocumentMetadata.self, from: Data(string(s, 0).utf8))
    }
    func saveMetadata(_ value: DocumentMetadata, for path: String) throws {
        let path = Self.canonical(path)
        try value.validate()
        lock.lock(); defer { lock.unlock() }
        try execute("INSERT OR REPLACE INTO metadata VALUES (?, ?)", [path, try json(value)])
        if var document = try document(at: path) { document.metadata = value; try store(document) }
    }
    func clearMetadata(for path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let path = Self.canonical(path)
        try execute("DELETE FROM metadata WHERE path=?", [path])
        if var document = try document(at: path) { document.metadata = DocumentMetadata(); try store(document) }
    }
    func document(at path: String) throws -> LibraryDocument? { try read("SELECT * FROM documents WHERE path=?", [Self.canonical(path)]).first }
    func all() throws -> [LibraryDocument] { try read("SELECT * FROM documents WHERE retired=0 ORDER BY modified DESC") }
    private func read(_ sql: String, _ values: [String] = []) throws -> [LibraryDocument] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        var documents: [LibraryDocument] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            documents.append(LibraryDocument(path: string(s, 0), name: string(s, 1), text: string(s, 2),
                tags: try JSONDecoder().decode([String].self, from: Data(string(s, 3).utf8)),
                metadata: try JSONDecoder().decode(DocumentMetadata.self, from: Data(string(s, 4).utf8)),
                digest: string(s, 5), baseline: string(s, 6), original: string(s, 7),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)), missing: sqlite3_column_int(s, 9) != 0, retired: sqlite3_column_int(s, 10) != 0))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw ConfigError(message: String(cString: sqlite3_errmsg(db))) }
        return documents
    }
    func search(_ query: LibraryQuery) throws -> [LibraryDocument] {
        let words = query.text.split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        let docs = try words.isEmpty ? all() : read("SELECT d.* FROM documents d JOIN search s ON d.path=s.path WHERE search MATCH ? AND d.retired=0 ORDER BY rank", [words.joined(separator: " AND ")])
        let folder = Self.canonical(Paths.expand(query.folder))
        return docs.filter { d in
            !d.missing && (query.folder.isEmpty || d.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")) &&
            (query.tag.isEmpty || d.tags.contains { $0.localizedCaseInsensitiveContains(query.tag) }) &&
            (query.type.isEmpty || d.metadata.documentType.localizedCaseInsensitiveContains(query.type)) &&
            (query.correspondent.isEmpty || d.metadata.correspondent.localizedCaseInsensitiveContains(query.correspondent)) &&
            (query.fromDate.isEmpty || d.date >= query.fromDate) && (query.toDate.isEmpty || d.date <= query.toDate) &&
            (query.field.isEmpty || (!(d.metadata.values[query.field] ?? "").isEmpty && (d.metadata.values[query.field] ?? "").localizedCaseInsensitiveContains(query.fieldValue)))
        }
    }
    func store(_ document: LibraryDocument) throws {
        var document = document
        document.path = Self.canonical(document.path)
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT OR REPLACE INTO documents VALUES (?,?,?,?,?,?,?,?,?,?,?)", [document.path, document.name, document.text, try json(document.tags), try json(document.metadata), document.digest, document.baseline, document.original, String(document.modified.timeIntervalSince1970), document.missing ? "1" : "0", document.retired ? "1" : "0"])
            try execute("DELETE FROM search WHERE path=?", [document.path])
            try execute("INSERT INTO search VALUES (?,?,?,?)", [document.path, document.name, document.text, document.tags.joined(separator: " ") + " " + document.metadata.searchable])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func index(_ url: URL, config: Config, original: String = "", authorizedChange: Bool = false, readScans: Bool = false, filedDigest: String? = nil) throws {
        let url = URL(fileURLWithPath: Self.canonical(url.path))
        guard let facts = FileFacts(url: url), !facts.isFolder else { return }
        guard let hash = Hashing.digest(url)?.hex else { throw ConfigError(message: "Cannot read \(url.lastPathComponent)") }
        let previous = try document(at: url.path)
        let text: String
        if previous?.digest == hash, !readScans { text = previous?.text ?? "" }
        else { text = Extract.text(of: url, ext: facts.ext, size: facts.size, config: config, allowOCR: readScans)?.text ?? "" }
        guard Hashing.digest(url)?.hex == hash else { throw ConfigError(message: "\(url.lastPathComponent) changed while indexing. Refresh to try again.") }
        lock.lock(); defer { lock.unlock() }
        let latest = try document(at: url.path)
        let metadata = try self.metadata(for: url.path) ?? latest?.metadata ?? DocumentMetadata()
        try store(LibraryDocument(path: url.path, name: facts.name, text: text, tags: Tags.read(url), metadata: metadata, digest: hash,
            baseline: filedDigest ?? (authorizedChange ? hash : (latest?.baseline ?? hash)), original: original.isEmpty ? (latest?.original ?? "") : original,
            modified: facts.modified, missing: false))
    }
    func relocate(from: String, to: String) throws {
        let from = Self.canonical(from), to = Self.canonical(to)
        guard from != to else { return }
        lock.lock(); defer { lock.unlock() }
        if let metadata = try metadata(for: from) { try saveMetadata(metadata, for: to) }
        if var document = try document(at: from) {
            document.path = to; document.name = URL(fileURLWithPath: to).lastPathComponent; document.missing = false; document.retired = false
            try store(document)
            try execute("DELETE FROM documents WHERE path=?", [from]); try execute("DELETE FROM search WHERE path=?", [from])
        }
        if from != to { try execute("DELETE FROM metadata WHERE path=?", [from]) }
    }
    func markMissing(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }; try execute("UPDATE documents SET missing=1 WHERE path=?", [Self.canonical(path)])
    }
    func retire(_ path: String, trash: String) throws {
        lock.lock(); defer { lock.unlock() }
        try relocate(from: path, to: trash)
        try execute("UPDATE documents SET retired=1, missing=1 WHERE path=?", [Self.canonical(trash)])
    }
    func savedViews() throws -> [SavedLibraryView] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT value FROM settings WHERE key='views'"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return [] }
        return try JSONDecoder().decode([SavedLibraryView].self, from: Data(string(s, 0).utf8))
    }
    func saveViews(_ views: [SavedLibraryView]) throws {
        lock.lock(); defer { lock.unlock() }; try execute("INSERT OR REPLACE INTO settings VALUES ('views', ?)", [try json(views)])
    }
}

enum OriginalVault {
    static var directory: URL { Paths.supportDirectory.appendingPathComponent("preserved-originals") }
    static func keep(_ url: URL, in directory: URL = OriginalVault.directory) throws -> URL {
        guard let digest = Hashing.digest(url)?.hex else { throw ConfigError(message: "Cannot preserve the original of \(url.lastPathComponent)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(digest + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
        if FileManager.default.fileExists(atPath: target.path) {
            guard Hashing.digest(target)?.hex == digest else { throw ConfigError(message: "The preserved original failed its checksum check.") }
            return target
        }
        let staging = directory.appendingPathComponent("." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: url, to: staging)
        guard Hashing.digest(staging)?.hex == digest, Hashing.digest(url)?.hex == digest else { throw ConfigError(message: "The file changed while preserving its original.") }
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            // Another indexing worker may have preserved the same contents in the meantime.
            guard Hashing.digest(target)?.hex == digest else { throw error }
        }
        return target
    }
}
