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
    private var entries = [String: Extract.Result]()
    private var recognizing = Set<String>()
    private let lock = NSCondition()
    private let extract: (FileFacts, Config, Bool) -> Extract.Result?

    init(extract: @escaping (FileFacts, Config, Bool) -> Extract.Result? = { facts, config, allowOCR in
        Extract.text(of: facts.url, ext: facts.ext, size: facts.size, config: config, allowOCR: allowOCR)
    }) { self.extract = extract }

    func key(for f: FileFacts) -> String {
        "\(f.url.path)|\(f.modified.timeIntervalSince1970)|\(f.size)"
    }

    func key(for f: FileFacts, config: Config) -> String {
        key(for: f) + "|\(config.ocr)|\(config.ocrPages)|\(config.ocrMaxMB)"
    }

    func text(for f: FileFacts, config: Config, allowOCR: Bool) -> String? {
        guard !f.isFolder, Extract.supports(f.ext) else { return nil }
        let key = key(for: f, config: config)
        lock.lock()
        while allowOCR && recognizing.contains(key) { lock.wait() }
        if let cached = entries[key], !(cached.ocrPending && allowOCR) {
            lock.unlock(); return cached.text
        }
        if allowOCR { recognizing.insert(key) }
        lock.unlock()
        let result = extract(f, config, allowOCR)
        lock.lock()
        defer { if allowOCR { recognizing.remove(key) }; lock.broadcast(); lock.unlock() }
        if entries.count > 3000 { entries.removeAll() }
        guard let result else { return nil }
        // A fast preview finishing late must never overwrite completed recognition.
        if result.ocrPending, let completed = entries[key], !completed.ocrPending { return completed.text }
        entries[key] = result
        return result.text
    }

    func ocrPending(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.ocrPending ?? false
    }

    func failure(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return entries[key]?.failure
    }

    func retryFailure(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries[key]?.failure != nil { entries.removeValue(forKey: key) }
    }
}

enum Tags {
    static func read(_ url: URL) -> [String] {
        // URL caches resource values. Always ask a fresh URL after an edit or Undo.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    @discardableResult
    static func write(_ tags: [String], to url: URL) -> Bool {
        do {
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            return true
        } catch {
            Log.write("tags: \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

enum Hashing {
    static func identical(_ a: URL, _ b: URL) -> Bool {
        guard let sa = size(a), let sb = size(b), sa == sb else { return false }
        guard let first = digest(a), let second = digest(b) else { return false }
        return first == second
    }

    private static func size(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    static func digest(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        } catch { return nil }
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
