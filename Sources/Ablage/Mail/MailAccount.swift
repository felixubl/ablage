import Foundation
import Security

struct MailAccount: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = "Email inbox"
    var host = ""
    var port = 993
    var username = ""
    var folder = "INBOX"
    var inbox = "~/Downloads"
    var enabled = false
    var intervalMinutes = 5
    var extensions = ["pdf"]
    var maxMessageMB = 30
    init() {}
    private enum CodingKeys: String, CodingKey { case id, name, host, port, username, folder, inbox, enabled, intervalMinutes, extensions, maxMessageMB }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        username = try c.decode(String.self, forKey: .username)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? folder
        inbox = try c.decodeIfPresent(String.self, forKey: .inbox) ?? inbox
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? intervalMinutes
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? extensions
        maxMessageMB = try c.decodeIfPresent(Int.self, forKey: .maxMessageMB) ?? maxMessageMB
    }
    var identity: String { "\(host.lowercased()):\(port)|\(username)|\(folder)" }
    var credentialKey: String { "\(id)|\(host.lowercased()):\(port)|\(username)" }
    var problem: String? {
        if UUID(uuidString: id) == nil { return "Email account identifiers must be UUIDs." }
        if host.isEmpty || host.contains(where: { $0.isWhitespace || "/@\\".contains($0) }) { return "Enter an IMAP hostname, such as imap.example.com." }
        if !(1...65535).contains(port) { return "IMAP port must be between 1 and 65535." }
        if username.isEmpty || folder.isEmpty { return "Email accounts need a username and mail folder." }
        if [username, folder].contains(where: { value in value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" } }) { return "Email fields cannot contain line breaks." }
        if !(1...1440).contains(intervalMinutes) || !(1...100).contains(maxMessageMB) { return "Choose 1–1440 minutes and a message limit of 1–100 MB." }
        return nil
    }
}

enum MailKeychain {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "at.fubl.ablage.imap", kSecAttrAccount as String: id]
    }
    static func save(_ password: String, account: String) throws {
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(account); entry.merge(value) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(entry as CFDictionary, nil)
            guard result == errSecSuccess else { throw error(result) }
        } else if status != errSecSuccess { throw error(status) }
    }
    static func read(_ account: String) throws -> String {
        var entry = query(account); entry[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(entry as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
    private static func error(_ status: OSStatus) -> ConfigError {
        ConfigError(message: status == errSecItemNotFound ? "Save an app password for this account first." : "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))
    }
}
