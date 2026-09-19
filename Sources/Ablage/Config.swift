import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // ABLAGE_DIR moves config, journal and log into one folder. Used for testing.
    private static let override = ProcessInfo.processInfo.environment["ABLAGE_DIR"].map {
        URL(fileURLWithPath: expand($0), isDirectory: true)
    }

    static let configDirectory = override ?? home.appendingPathComponent(".config/ablage", isDirectory: true)
    static let configFile = configDirectory.appendingPathComponent("config.json")
    static let supportDirectory = override ?? home.appendingPathComponent("Library/Application Support/Ablage", isDirectory: true)
    static let journalFile = supportDirectory.appendingPathComponent("journal.json")
    static let learnedFile = supportDirectory.appendingPathComponent("learned.json")
    static let logFile = override?.appendingPathComponent("ablage.log") ?? home.appendingPathComponent("Library/Logs/Ablage.log")
    static let trash = home.appendingPathComponent(".Trash", isDirectory: true)

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

struct InboxConfig: Decodable {
    var path: String
    var ignore: [String]?
    var rules: [Rule]?
    var sortExistingOnRescan: Bool?
}

struct LearnConfig: Decodable {
    var enabled = true
    /// Positive examples a rule needs before the learner may pick it.
    var minExamples = 2
    /// Classifier posterior the winning rule needs when more than one rule is in the running.
    var minConfidence = 0.8
    /// Cosine similarity to the nearest example of that rule. Rejects documents unlike anything seen.
    var minSimilarity = 0.25
    /// Also learn from rule filings, not only from Apply rule.
    var fromRules = true
    /// Hours a rule filing must survive without an undo before it counts.
    var confirmAfterHours = 24.0

    private enum CodingKeys: String, CodingKey { case enabled, minExamples, minConfidence, minSimilarity, threshold, fromRules, confirmAfterHours }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        minExamples = try c.decodeIfPresent(Int.self, forKey: .minExamples) ?? minExamples
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? minConfidence
        minSimilarity = try c.decodeIfPresent(Double.self, forKey: .minSimilarity)
            ?? c.decodeIfPresent(Double.self, forKey: .threshold) ?? minSimilarity
        fromRules = try c.decodeIfPresent(Bool.self, forKey: .fromRules) ?? fromRules
        confirmAfterHours = try c.decodeIfPresent(Double.self, forKey: .confirmAfterHours) ?? confirmAfterHours
    }
}

struct Config: Decodable {
    var inbox = "~/Downloads"
    var inboxes: [InboxConfig]?
    var ignore: [String] = []
    var settleSeconds = 3.0
    var rescanMinutes = 30.0
    var sortExistingOnRescan = false
    var notifications = true
    var ocr = true
    var ocrPages = 2
    var ocrMaxMB = 25.0
    /// Give scanned PDFs an invisible text layer after filing, so Spotlight can search them.
    var searchablePDFs = true
    var textLayerMaxPages = 60
    var originalsDays = 30
    var ai = AIConfig()
    var learning = LearnConfig()
    var rules: [Rule] = []

    /// `inboxes` when given, otherwise the single `inbox`. Shared `rules` apply to every inbox after its own.
    var resolvedInboxes: [InboxConfig] {
        if let inboxes, !inboxes.isEmpty { return inboxes }
        return [InboxConfig(path: inbox, ignore: ignore, rules: nil, sortExistingOnRescan: sortExistingOnRescan)]
    }

    private enum CodingKeys: String, CodingKey {
        case inbox, inboxes, ignore, settleSeconds, rescanMinutes, sortExistingOnRescan, notifications, ocr, ocrPages, ocrMaxMB, searchablePDFs, textLayerMaxPages, originalsDays, ai, learning, rules
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inbox = try c.decodeIfPresent(String.self, forKey: .inbox) ?? inbox
        inboxes = try c.decodeIfPresent([InboxConfig].self, forKey: .inboxes)
        ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? ignore
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? settleSeconds
        rescanMinutes = try c.decodeIfPresent(Double.self, forKey: .rescanMinutes) ?? rescanMinutes
        sortExistingOnRescan = try c.decodeIfPresent(Bool.self, forKey: .sortExistingOnRescan) ?? sortExistingOnRescan
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        ocr = try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? ocr
        ocrPages = try c.decodeIfPresent(Int.self, forKey: .ocrPages) ?? ocrPages
        ocrMaxMB = try c.decodeIfPresent(Double.self, forKey: .ocrMaxMB) ?? ocrMaxMB
        searchablePDFs = try c.decodeIfPresent(Bool.self, forKey: .searchablePDFs) ?? searchablePDFs
        textLayerMaxPages = try c.decodeIfPresent(Int.self, forKey: .textLayerMaxPages) ?? textLayerMaxPages
        originalsDays = try c.decodeIfPresent(Int.self, forKey: .originalsDays) ?? originalsDays
        ai = try c.decodeIfPresent(AIConfig.self, forKey: .ai) ?? ai
        learning = try c.decodeIfPresent(LearnConfig.self, forKey: .learning) ?? learning
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? rules
    }
}

enum ConfigStore {
    static func ensureDefault() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Paths.configFile.path) else { return }
        try fm.createDirectory(at: Paths.configDirectory, withIntermediateDirectories: true)
        try DefaultConfig.json.write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }

    static func load() throws -> Config {
        let data = try Data(contentsOf: Paths.configFile)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "top level" : p
        }
        switch e {
        case .dataCorrupted(let c): return "invalid JSON: \(c.debugDescription)"
        case .keyNotFound(let k, let c): return "missing \"\(k.stringValue)\" at \(path(c))"
        case .typeMismatch(_, let c): return "wrong type at \(path(c)): \(c.debugDescription)"
        case .valueNotFound(_, let c): return "missing value at \(path(c))"
        @unknown default: return "\(e)"
        }
    }
}

struct ConfigError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension ConfigStore {
    /// Inserts a rule at the end of the top-level "rules" array. Everything else in the file stays as written.
    static func appendRule(_ ruleJSON: String) throws {
        var text = try String(contentsOf: Paths.configFile, encoding: .utf8)
        guard let (open, close) = topLevelArray(named: "rules", in: text) else {
            throw ConfigError(message: "config.json has no top-level \"rules\" array")
        }
        let inner = text[text.index(after: open)..<close]
        let isEmpty = inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let indented = ruleJSON.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        var cut = close
        while cut > text.index(after: open), text[text.index(before: cut)].isWhitespace { cut = text.index(before: cut) }
        text.replaceSubrange(cut..<close, with: (isEmpty ? "\n" : ",\n") + indented + "\n  ")
        try text.write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }

    /// Indices of the brackets of a top-level array value, found by walking the JSON text.
    static func topLevelArray(named key: String, in text: String) -> (open: String.Index, close: String.Index)? {
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        var lastString: String?
        var expectingValue = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped {
                    escaped = false
                    current.append(ch)
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                    if depth == 1 { lastString = current }
                } else {
                    current.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                    current = ""
                case ":":
                    expectingValue = depth == 1 && lastString == key
                case "{":
                    depth += 1
                    expectingValue = false
                case "}":
                    depth -= 1
                case "[":
                    if depth == 1, expectingValue {
                        var level = 0
                        var j = i
                        var quoted = false
                        var slash = false
                        while j < text.endIndex {
                            let c = text[j]
                            if quoted {
                                if slash { slash = false } else if c == "\\" { slash = true } else if c == "\"" { quoted = false }
                            } else if c == "\"" {
                                quoted = true
                            } else if c == "[" {
                                level += 1
                            } else if c == "]" {
                                level -= 1
                                if level == 0 { return (i, j) }
                            }
                            j = text.index(after: j)
                        }
                        return nil
                    }
                    depth += 1
                    expectingValue = false
                case "]":
                    depth -= 1
                default:
                    if !ch.isWhitespace { expectingValue = false }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Mistakes that would otherwise fail silently: bad regexes, rules naming models that do not exist.
    static func problems(in config: Config) -> [String] {
        var out: [String] = []
        let rules = config.rules + config.resolvedInboxes.flatMap { $0.rules ?? [] }
        for rule in rules {
            for (label, pattern) in [("filenameRegex", rule.match.filenameRegex), ("contentRegex", rule.match.contentRegex)] {
                guard let pattern, !pattern.isEmpty else { continue }
                if (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) == nil {
                    out.append("rule \"\(rule.name)\": invalid \(label)")
                }
            }
            if let model = rule.match.ai?.model, config.ai.models[model] == nil {
                out.append("rule \"\(rule.name)\": model \"\(model)\" is not defined under ai.models")
            }
            if let model = rule.action.ai, config.ai.models[model] == nil {
                out.append("rule \"\(rule.name)\": model \"\(model)\" is not defined under ai.models")
            }
        }
        return out
    }
}
