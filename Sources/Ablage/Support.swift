import CryptoKit
import Foundation

final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, queue: DispatchQueue, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

final class ContentCache {
    private struct Entry {
        var text: String
        var ocrPending: Bool
    }

    private var entries = [String: Entry]()
    private let lock = NSLock()

    func key(for f: FileFacts) -> String {
        "\(f.url.path)|\(f.modified.timeIntervalSince1970)|\(f.size)"
    }

    func text(for f: FileFacts, config: Config, allowOCR: Bool) -> String? {
        guard !f.isFolder, Extract.supports(f.ext) else { return nil }
        let key = key(for: f)
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached, !(cached.ocrPending && allowOCR) { return cached.text }
        guard let result = Extract.text(of: f.url, ext: f.ext, size: f.size, config: config, allowOCR: allowOCR) else { return nil }
        lock.lock()
        if entries.count > 3000 { entries.removeAll() }
        entries[key] = Entry(text: result.text, ocrPending: result.ocrPending)
        lock.unlock()
        return result.text
    }

    func ocrPending(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.ocrPending ?? false
    }
}

enum Tags {
    static func read(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func write(_ tags: [String], to url: URL) {
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }
}

enum Hashing {
    static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let sa = size(a), let sb = size(b), sa == sb else { return false }
        return digest(a) == digest(b)
    }

    private static func size(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func digest(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return Data(sha.finalize())
    }

    static func unique(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
