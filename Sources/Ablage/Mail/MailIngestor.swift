import CryptoKit
import Foundation

struct MailDelivery: Codable {
    var staging: String
    var destination: String
    var digest: String
    var delivered = false
}
struct MailCheckpoint: Codable {
    var validity: UInt64 = 0
    var processed = Set<UInt64>()
    var deliveries: [String: MailDelivery] = [:]
    var retryAfter: [UInt64: Date] = [:]
}

/// The receipt is durable before delivery. Recovery cannot import an attachment twice
/// merely because the inbox watcher already moved it before the next checkpoint write.
enum MailDeliveryStore {
    static func deliver(_ key: String, attachment: MailAttachment, into inbox: URL, directory: URL,
                        state: inout MailCheckpoint, save: (MailCheckpoint) throws -> Void) throws -> Bool {
        let fm = FileManager.default
        if state.deliveries[key]?.delivered == true { return false }
        if state.deliveries[key] == nil {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(key)
            try attachment.data.write(to: staged, options: .atomic)
            let proposed = inbox.appendingPathComponent(attachment.name)
            let destination = fm.fileExists(atPath: proposed.path) ? Hashing.unique(proposed) : proposed
            state.deliveries[key] = MailDelivery(staging: staged.path, destination: destination.path, digest: SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined())
            try save(state)
        }
        guard var receipt = state.deliveries[key] else { return false }
        let staged = URL(fileURLWithPath: receipt.staging)
        if fm.fileExists(atPath: staged.path) {
            guard Hashing.digest(staged)?.hex == receipt.digest else { throw ConfigError(message: "A staged email attachment failed its checksum check.") }
            var destination = URL(fileURLWithPath: receipt.destination)
            if fm.fileExists(atPath: destination.path) {
                destination = Hashing.unique(destination)
                receipt.destination = destination.path; state.deliveries[key] = receipt; try save(state)
            }
            guard fm.fileExists(atPath: inbox.path) else { throw ConfigError(message: "The email destination folder is unavailable.") }
            try fm.moveItem(at: staged, to: destination)
        }
        // Absence of a prepared staging file means the delivery already completed.
        // Its destination may already have been moved by Ablage's ordinary rules.
        receipt.delivered = true; state.deliveries[key] = receipt; try save(state)
        return true
    }
}

extension Notification.Name { static let ablageMailStatus = Notification.Name("at.fubl.ablage.mail.status") }

final class MailIngestor {
    static let shared = MailIngestor()
    private let queue = DispatchQueue(label: "at.fubl.ablage.mail", qos: .utility)
    private let statusLock = NSLock()
    private var statuses: [String: String] = [:]
    private var accounts: [MailAccount] = []
    private var lastRun: [String: Date] = [:]
    private var timer: DispatchSourceTimer?

    func configure(_ accounts: [MailAccount]) {
        queue.async {
            self.accounts = accounts
            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5, repeating: 60)
                timer.setEventHandler { [weak self] in self?.poll() }
                timer.resume(); self.timer = timer
            }
        }
    }
    func status(_ id: String) -> String {
        statusLock.lock(); defer { statusLock.unlock() }; return statuses[id] ?? "Not fetched yet"
    }
    private func report(_ message: String, account: String) {
        statusLock.lock(); statuses[account] = message; statusLock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .ablageMailStatus, object: nil) }
    }
    private func poll() {
        for account in accounts where account.enabled {
            if Date().timeIntervalSince(lastRun[account.id] ?? .distantPast) >= Double(account.intervalMinutes * 60) { fetch(account) }
        }
    }
    func fetchNow(_ account: MailAccount) { queue.async { self.fetch(account, retryFailures: true) } }
    static func test(_ account: MailAccount, password: String) throws -> String {
        if let problem = account.problem { throw ConfigError(message: problem) }
        let client = try connect(account, password: password)
        _ = try client.examine(account.folder)
        return "Connected. The mail folder is readable."
    }
    private static func connect(_ account: MailAccount, password: String) throws -> IMAPClient {
        let transport = try TLSMailTransport(host: account.host, port: account.port)
        let client = try IMAPClient(transport: transport, maxBytes: account.maxMessageMB * 1_048_576)
        try client.login(username: account.username, password: password)
        return client
    }
    private func fetch(_ account: MailAccount, retryFailures: Bool = false) {
        lastRun[account.id] = Date(); report("Checking for attachments…", account: account.id)
        do {
            if let problem = account.problem { throw ConfigError(message: problem) }
            let password = try MailKeychain.read(account.credentialKey)
            var client = try Self.connect(account, password: password)
            let validity = try client.examine(account.folder)
            let identity = SHA256.hash(data: Data((account.id + account.identity).utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = Paths.supportDirectory.appendingPathComponent("mail", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stateURL = directory.appendingPathComponent(identity + ".json")
            var state = FileManager.default.fileExists(atPath: stateURL.path)
                ? try JSONDecoder().decode(MailCheckpoint.self, from: Data(contentsOf: stateURL)) : MailCheckpoint()
            if state.validity != validity { state.validity = validity; state.processed.removeAll(); state.retryAfter.removeAll() }
            if retryFailures { state.retryAfter.removeAll() }
            func save(_ value: MailCheckpoint) throws { try JSONEncoder().encode(value).write(to: stateURL, options: .atomic) }
            var count = 0; var errors: [String] = []
            let inbox = URL(fileURLWithPath: Paths.expand(account.inbox)).standardizedFileURL
            for uid in try client.uids().filter({ !state.processed.contains($0) && (state.retryAfter[$0] ?? .distantPast) <= Date() }).prefix(30) {
                do {
                    let bytes = try client.message(uid)
                    let attachments = try MIME.attachments(bytes, extensions: Set(account.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }))
                    for (index, attachment) in attachments.enumerated() {
                        let key = "\(identity)-\(validity)-\(uid)-\(index)"
                        if try MailDeliveryStore.deliver(key, attachment: attachment, into: inbox, directory: directory.appendingPathComponent("staging"), state: &state, save: save) { count += 1 }
                    }
                    state.processed.insert(uid); state.retryAfter.removeValue(forKey: uid)
                    let prefix = "\(identity)-\(validity)-\(uid)-"
                    state.deliveries = state.deliveries.filter { !$0.key.hasPrefix(prefix) }
                    try save(state)
                } catch {
                    errors.append("Message \(uid): " + error.localizedDescription)
                    state.retryAfter[uid] = Date().addingTimeInterval(3600)
                    try save(state)
                    // A rejected literal can leave the old connection mid-message. Start clean.
                    client = try Self.connect(account, password: password)
                    guard try client.examine(account.folder) == validity else { throw ConfigError(message: "The mailbox changed during import. Try again.") }
                }
            }
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            report(errors.isEmpty ? "\(stamp) · \(count) attachment\(count == 1 ? "" : "s") imported" : "\(count) imported. " + errors.prefix(3).joined(separator: " "), account: account.id)
        } catch { report(error.localizedDescription, account: account.id) }
    }
}
