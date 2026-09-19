import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "at.fubl.ablage.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static var writes = 0

    static func flush() { queue.sync {} }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = Paths.logFile
            writes += 1
            if writes % 200 == 0 { rotate(url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    /// Keeps the log under a few hundred kilobytes once it passes two megabytes.
    private static func rotate(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 2_000_000,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(400_000)
        guard let newline = tail.firstIndex(of: 0x0A) else { return }
        try? tail[tail.index(after: newline)...].write(to: url)
    }
}
