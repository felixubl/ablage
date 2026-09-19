import Foundation

struct FileFacts {
    let url: URL
    let name: String
    let stem: String
    let ext: String
    let extOriginal: String
    let isFolder: Bool
    let size: Int64
    let modified: Date
    let added: Date
    let sources: [String]

    var ageDays: Int { max(0, Int(Date().timeIntervalSince(added) / 86_400)) }
    var host: String { sources.compactMap { URL(string: $0)?.host }.first ?? "" }

    init?(url: URL) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        self.url = url
        name = url.lastPathComponent
        isFolder = (v.isDirectory ?? false) && !(v.isPackage ?? false)
        if isFolder {
            stem = name
            ext = ""
            extOriginal = ""
        } else {
            extOriginal = url.pathExtension
            ext = extOriginal.lowercased()
            stem = extOriginal.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        }
        size = Int64(v.fileSize ?? 0)
        modified = v.contentModificationDate ?? Date()
        added = v.addedToDirectoryDate ?? v.creationDate ?? modified
        sources = Extract.sources(of: url)
    }
}
