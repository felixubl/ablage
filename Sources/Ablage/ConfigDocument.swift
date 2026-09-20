import Foundation

/// Round-trips unknown settings, and refuses to overwrite edits made outside the app.
struct ConfigDocument {
    var root: [String: Any]
    private var original: Data

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError(message: "The configuration must be a JSON object.")
        }
        _ = try JSONDecoder().decode(Config.self, from: data)
        self.root = root
        original = data
    }

    static func load() throws -> Self {
        try ConfigStore.ensureDefault()
        return try Self(data: Data(contentsOf: Paths.configFile))
    }

    var inboxes: [[String: Any]] {
        get {
            if let value = root["inboxes"] as? [[String: Any]], !value.isEmpty { return value }
            return [["path": root["inbox"] as? String ?? "~/Downloads"]]
        }
        set { root["inboxes"] = newValue; root.removeValue(forKey: "inbox") }
    }

    var models: [String: [String: Any]] {
        get { (root["ai"] as? [String: Any])?["models"] as? [String: [String: Any]] ?? [:] }
        set {
            var ai = root["ai"] as? [String: Any] ?? [:]
            ai["models"] = newValue
            root["ai"] = ai
        }
    }

    func rules(in scope: Int?) -> [[String: Any]] {
        (scope.map { inboxes[$0]["rules"] } ?? root["rules"]) as? [[String: Any]] ?? []
    }

    mutating func setRules(_ rules: [[String: Any]], in scope: Int?) {
        if let scope {
            var folders = inboxes
            folders[scope]["rules"] = rules
            inboxes = folders
        } else { root["rules"] = rules }
    }

    func encoded() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let config = try JSONDecoder().decode(Config.self, from: data)
        let problems = ConfigStore.problems(in: config)
        guard problems.isEmpty else { throw ConfigError(message: problems.joined(separator: "\n")) }
        return data
    }

    mutating func save(to url: URL = Paths.configFile) throws {
        let data = try encoded()
        let current = try Data(contentsOf: url)
        guard current == original else {
            throw ConfigError(message: "The configuration changed outside this window. Reload it before saving so those changes are preserved.")
        }
        try current.write(to: url.deletingPathExtension().appendingPathExtension("previous.json"), options: .atomic)
        try data.write(to: url, options: .atomic)
        original = data
    }
}
