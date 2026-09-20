import CryptoKit
import Darwin
import Foundation

/// A snapshot of one ordinary, local file. File identity keeps hard links out of the results.
struct DuplicateFile: Identifiable, Equatable, Codable {
    let path: String
    let size: Int64
    let modified: Date
    let identity: String
    let revision: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    static func read(_ url: URL) throws -> DuplicateFile {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ConfigError(message: "File unavailable: " + url.lastPathComponent) }
        return try snapshot(url, info)
    }

    fileprivate static func snapshot(_ url: URL, _ info: stat) throws -> DuplicateFile {
        guard info.st_mode & S_IFMT == S_IFREG else { throw ConfigError(message: "Not an ordinary file: " + url.lastPathComponent) }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw ConfigError(message: "Download this file in Finder before scanning: " + url.lastPathComponent) }
        return DuplicateFile(path: url.standardizedFileURL.path, size: info.st_size,
                             modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                             identity: "\(info.st_dev):\(info.st_ino)",
                             revision: "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
    }
}

struct ExactDuplicateGroup: Identifiable, Equatable, Codable {
    let digest: String
    let files: [DuplicateFile]
    var id: String { digest }
    var extraCount: Int { max(0, files.count - 1) }
    /// Logical content size, not a promise of space reclaimed on APFS or compressed volumes.
    var extraBytes: Int64 { (files.first?.size ?? 0) * Int64(extraCount) }
}

struct DuplicateScanReport: Codable {
    var groups: [ExactDuplicateGroup] = []
    var files = 0
    var compared = 0
    var cloudFiles = 0
    var linkedFiles = 0
    var issues: [String] = []
    var cancelled = false
    var extraCount: Int { groups.reduce(0) { $0 + $1.extraCount } }
    var extraBytes: Int64 { groups.reduce(0) { $0 + $1.extraBytes } }
}

enum ExactDuplicateScanner {
    static func scan(folders: [URL], recursive: Bool = true, cancellation: WorkCancellation = WorkCancellation(),
                     progress: (String) -> Void = { _ in }) -> DuplicateScanReport {
        var report = DuplicateScanReport()
        let fm = FileManager.default
        var identities = Set<String>()
        var visited = Set<String>()
        var buckets: [Int64: [DuplicateFile]] = [:]
        let protected = Paths.supportDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var lastProgress = Date.distantPast
        func update(_ text: String) {
            if Date().timeIntervalSince(lastProgress) > 0.15 { progress(text); lastProgress = Date() }
        }
        func issue(_ message: String) { if report.issues.count < 100 { report.issues.append(message) } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func consider(_ url: URL) {
            guard visited.insert(url.standardizedFileURL.path).inserted else { return }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.isAliasFile != true else { return }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw ConfigError(message: "Cannot read " + url.lastPathComponent) }
                if info.st_flags & UInt32(SF_DATALESS) != 0 || (values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded) {
                    report.cloudFiles += 1; return
                }
                let file = try DuplicateFile.snapshot(url, info)
                guard file.size > 0 else { return }
                guard identities.insert(file.identity).inserted else { report.linkedFiles += 1; return }
                report.files += 1
                buckets[file.size, default: []].append(file)
                update("Looking through folders · \(report.files.formatted()) files")
            } catch { issue(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        for root in folders {
            if cancellation.isCancelled { break }
            let folder = root.standardizedFileURL.resolvingSymlinksInPath()
            guard let properties = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  properties.isDirectory == true, properties.isPackage != true else {
                issue("Folder unavailable: " + Paths.abbreviate(root.path)); continue
            }
            if folder.path == protected || folder.path.hasPrefix(protected + "/") { continue }
            let options: FileManager.DirectoryEnumerationOptions = recursive
                ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: options, errorHandler: { url, error in
                issue(Paths.abbreviate(url.path) + ": " + error.localizedDescription); return !cancellation.isCancelled
            }) else { issue("Could not read folder: " + Paths.abbreviate(folder.path)); continue }
            for case let url as URL in enumerator {
                if cancellation.isCancelled { break }
                if url.path == protected || url.path.hasPrefix(protected + "/") { enumerator.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                consider(url)
            }
        }
        let candidates = buckets.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.flatMap { $0.value.sorted { $0.path < $1.path } }
        var matches: [String: [DuplicateFile]] = [:]
        for file in candidates {
            if cancellation.isCancelled { break }
            do {
                let hash = try digest(file, cancellation: cancellation)
                matches[hash, default: []].append(file)
                report.compared += 1
                update("Comparing contents · \(report.compared.formatted()) of \(candidates.count.formatted()) files")
            } catch is CancellationError { break }
            catch { issue(file.name + ": " + error.localizedDescription) }
        }
        // A file can change while later files are being hashed; don't publish an already-stale group.
        report.groups = matches.compactMap { digest, files in
            let current = files.filter { (try? DuplicateFile.read($0.url)) == $0 }
            return current.count > 1 ? ExactDuplicateGroup(digest: digest, files: current.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) : nil
        }.sorted { $0.extraBytes == $1.extraBytes ? $0.id < $1.id : $0.extraBytes > $1.extraBytes }
        report.cancelled = cancellation.isCancelled
        return report
    }

    /// Read in bounded chunks, refusing symlinks and files changed during comparison.
    static func digest(_ file: DuplicateFile, cancellation: WorkCancellation = WorkCancellation()) throws -> String {
        guard try DuplicateFile.read(file.url) == file else { throw ConfigError(message: "File changed. Scan again.") }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConfigError(message: "Could not read file contents.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, try DuplicateFile.snapshot(file.url, before) == file else { throw ConfigError(message: "File changed. Scan again.") }
        var hasher = SHA256()
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, try DuplicateFile.snapshot(file.url, after) == file,
              try DuplicateFile.read(file.url) == file else { throw ConfigError(message: "File changed during comparison. Scan again.") }
        return Data(hasher.finalize()).hex
    }
}

struct DuplicateRemoval {
    let keeper: DuplicateFile
    let copies: [DuplicateFile]
    let digest: String

    init(group: ExactDuplicateGroup, keeping path: String, removing paths: Set<String>) throws {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let paths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let keeper = group.files.first(where: { $0.path == path }), !paths.isEmpty, !paths.contains(path),
              paths.isSubset(of: Set(group.files.map(\.path))), !group.digest.isEmpty else {
            throw ConfigError(message: "Choose a copy to keep and at least one other copy to remove.")
        }
        self.keeper = keeper; copies = group.files.filter { paths.contains($0.path) }; digest = group.digest
        guard Set(([keeper] + copies).map(\.identity)).count == copies.count + 1 else {
            throw ConfigError(message: "These paths point to the same file. Scan again.")
        }
    }

    func validate() throws {
        for file in [keeper] + copies {
            guard try ExactDuplicateScanner.digest(file) == digest else { throw ConfigError(message: "A compared file changed. Scan again before removing copies.") }
        }
    }
}

struct DuplicateRemovalResult {
    var removedPaths: [String] = []
    var previewed = 0
    var error: String?
}
