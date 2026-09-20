import Foundation

final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct IndexReport { var indexed = 0; var errors: [String] = []; var cancelled = false }
enum ArchiveIndexer {
    static func refresh(library: DocumentLibrary, config: Config, readScans: Bool = false,
                        cancellation: WorkCancellation, progress: (Int) -> Void = { _ in }) throws -> IndexReport {
        let fm = FileManager.default
        var report = IndexReport()
        var paths = Set(try library.all().map(\.path))
        let protected = Paths.supportDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for root in config.archiveFolders {
            let folder = URL(fileURLWithPath: Paths.expand(root)).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                report.errors.append("Folder unavailable: " + root); continue
            }
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                report.errors.append(url.lastPathComponent + ": " + error.localizedDescription); return true
            }) else { continue }
            for case let url as URL in enumerator {
                if cancellation.isCancelled { report.cancelled = true; return report }
                if url.resolvingSymlinksInPath().path.hasPrefix(protected) { enumerator.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true, Extract.supports(url.pathExtension.lowercased()) else { continue }
                paths.insert(url.path)
            }
        }
        for path in paths.sorted() {
            if cancellation.isCancelled { report.cancelled = true; break }
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { try library.markMissing(path); continue }
            do {
                var original = ""
                if config.keepOriginalsForever, (try library.document(at: path))?.original.isEmpty != false {
                    original = try OriginalVault.keep(url).path
                }
                try library.index(url, config: config, original: original, readScans: readScans)
                report.indexed += 1; progress(report.indexed)
            } catch { report.errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        return report
    }
}

struct DuplicatePair: Identifiable, Equatable {
    let first: LibraryDocument
    let second: LibraryDocument
    let exact: Bool
    let similarity: Double
    var id: String { first.path + "\n" + second.path }
}

enum DuplicateFinder {
    /// Exact matches are checksum based. Similar text is a suggestion, never a deletion decision.
    static func find(_ documents: [LibraryDocument], cancellation: WorkCancellation = WorkCancellation()) -> [DuplicatePair] {
        let docs = documents.filter { !$0.missing }.sorted { $0.path < $1.path }
        var result: [DuplicatePair] = []
        var hashes: [String: Int] = [:]
        var inverted: [UInt64: [Int]] = [:]
        var features: [Set<UInt64>] = []
        for (index, document) in docs.enumerated() {
            if cancellation.isCancelled { break }
            if !document.digest.isEmpty, let prior = hashes[document.digest] {
                result.append(DuplicatePair(first: docs[prior], second: document, exact: true, similarity: 1))
            } else if !document.digest.isEmpty { hashes[document.digest] = index }
            let words = document.text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4000).map(String.init)
            var grams = Set<UInt64>()
            if words.count >= 12 {
                for i in 0..<(words.count - 2) { grams.insert(hash(words[i...i+2].joined(separator: " "))) }
            }
            features.append(grams)
            guard grams.count >= 10 else { continue }
            var candidates: [Int: Int] = [:]
            for gram in grams {
                // Common boilerplate must not turn a large archive into a quadratic comparison.
                if let posting = inverted[gram], posting.count < 200 {
                    for prior in posting { candidates[prior, default: 0] += 1 }
                }
            }
            for prior in candidates.sorted(by: { $0.value > $1.value }).prefix(40).map(\.key) {
                guard docs[prior].digest != document.digest else { continue }
                let similarity = 2.0 * Double(grams.intersection(features[prior]).count) / Double(grams.count + features[prior].count)
                if similarity >= 0.86 { result.append(DuplicatePair(first: docs[prior], second: document, exact: false, similarity: similarity)) }
            }
            for gram in grams where (inverted[gram]?.count ?? 0) < 200 { inverted[gram, default: []].append(index) }
        }
        return result.sorted { $0.exact != $1.exact ? $0.exact : $0.similarity > $1.similarity }
    }
    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

struct IntegrityIssue: Identifiable {
    enum Kind: String { case missing = "File unavailable", changed = "Contents changed", unreadable = "Cannot read file", original = "Original unavailable or changed" }
    var document: LibraryDocument
    var kind: Kind
    var id: String { document.path + kind.rawValue }
}
enum IntegrityChecker {
    static func check(_ documents: [LibraryDocument], cancellation: WorkCancellation = WorkCancellation()) -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []
        for document in documents {
            if cancellation.isCancelled { break }
            if !FileManager.default.fileExists(atPath: document.path) { issues.append(.init(document: document, kind: .missing)) }
            else if let current = Hashing.digest(document.url)?.hex {
                if current != document.baseline { issues.append(.init(document: document, kind: .changed)) }
            } else { issues.append(.init(document: document, kind: .unreadable)) }
            if !document.original.isEmpty {
                let original = URL(fileURLWithPath: document.original)
                let expected = original.deletingPathExtension().lastPathComponent
                if Hashing.digest(original)?.hex != expected { issues.append(.init(document: document, kind: .original)) }
            }
        }
        return issues
    }
}
