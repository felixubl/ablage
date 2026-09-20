import Foundation

struct Rule: Decodable {
    var name: String
    var enabled: Bool?
    var match: Match
    var action: Action

    var isEnabled: Bool { enabled ?? true }
    init(name: String, match: Match = Match(), action: Action = Action()) {
        self.name = name; self.match = match; self.action = action
    }

    private enum CodingKeys: String, CodingKey { case name, enabled, match, action }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        match = try c.decodeIfPresent(Match.self, forKey: .match) ?? Match()
        action = try c.decodeIfPresent(Action.self, forKey: .action) ?? Action()
    }
}

struct Match: Decodable {
    var kind: String?
    var extensions: [String]?
    var filename: [String]?
    var filenameRegex: String?
    var source: [String]?
    var content: [String]?
    var contentAll: [String]?
    var contentRegex: String?
    var minAgeDays: Int?
    var minSizeMB: Double?
    var maxSizeMB: Double?
    /// Lets filename and content terms match with one or two wrong characters, for OCR errors.
    var fuzzy: Bool?
    /// Hands the decision to a named model once every other criterion matched and no plain rule did.
    var ai: AIMatch?

    var needsContent: Bool {
        !(content ?? []).isEmpty || !(contentAll ?? []).isEmpty || !(contentRegex ?? "").isEmpty
    }
}

struct AIMatch: Decodable {
    var model: String
    var description: String
}

struct Action: Decodable {
    var destination: String?
    var rename: String?
    var tags: [String]?
    var correspondent: String?
    var trash: Bool?
    var dateFrom: String?
    /// Name of a model that fills {correspondent}, {title} and the date for a rule that matched on its own.
    var ai: String?
    /// Shell command run after filing, with ABLAGE_FROM, ABLAGE_TO and ABLAGE_RULE in its environment.
    var run: String?

    var isNoop: Bool { destination == nil && rename == nil && (tags ?? []).isEmpty && trash != true && run == nil }
    var movesOrTags: Bool { destination != nil || rename != nil || !(tags ?? []).isEmpty }

    var usesDate: Bool {
        let text = (destination ?? "") + (rename ?? "")
        return ["{date}", "{year}", "{month}", "{day}"].contains { text.contains($0) }
    }
}

/// One file on its way through the rules: facts plus lazily loaded text and words.
final class FileContext {
    let facts: FileFacts
    let metadata: DocumentMetadata
    private let provider: () -> String?
    private var loaded = false
    private var text: String?
    private var wordCache: Set<String>?

    init(facts: FileFacts, metadata: DocumentMetadata = DocumentMetadata(), provider: @escaping () -> String?) {
        self.facts = facts
        self.metadata = metadata
        self.provider = provider
    }

    var content: String? {
        if !loaded {
            text = provider()
            loaded = true
        }
        return text
    }

    var words: Set<String> {
        if wordCache == nil { wordCache = TextFeatures.rawWords(facts.name + " " + (content ?? "")) }
        return wordCache ?? []
    }
}

enum Fuzzy {
    static func allowance(_ length: Int) -> Int {
        length >= 9 ? 2 : (length >= 5 ? 1 : 0)
    }

    /// Every word of the term has a word in the document within the edit-distance allowance.
    static func matches(_ term: String, in words: Set<String>) -> Bool {
        let parts = TextFeatures.rawWords(term)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            if words.contains(part) { return true }
            let budget = allowance(part.count)
            guard budget > 0 else { return false }
            return words.contains { abs($0.count - part.count) <= budget && distance(part, $0, limit: budget) <= budget }
        }
    }

    /// Levenshtein distance with an early exit once a row exceeds the limit.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

enum Matcher {
    static func matches(_ m: Match, _ file: FileContext) -> Bool {
        let f = file.facts
        let fuzzy = m.fuzzy == true
        switch m.kind ?? "file" {
        case "file": if f.isFolder { return false }
        case "folder": if !f.isFolder { return false }
        default: break
        }
        if let exts = m.extensions, !exts.isEmpty {
            let wanted = exts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            guard wanted.contains(f.ext) else { return false }
        }
        if let parts = m.filename, !parts.isEmpty {
            let nameWords = TextFeatures.rawWords(f.name)
            guard parts.contains(where: { f.name.localizedCaseInsensitiveContains($0) || (fuzzy && Fuzzy.matches($0, in: nameWords)) }) else { return false }
        }
        if let re = m.filenameRegex, !re.isEmpty {
            guard Patterns.matches(re, f.name) else { return false }
        }
        if let sources = m.source, !sources.isEmpty {
            guard f.sources.contains(where: { s in sources.contains { s.localizedCaseInsensitiveContains($0) } }) else { return false }
        }
        if let days = m.minAgeDays, f.ageDays < days { return false }
        if let mb = m.minSizeMB, Double(f.size) < mb * 1_048_576 { return false }
        if let mb = m.maxSizeMB, Double(f.size) > mb * 1_048_576 { return false }
        if m.needsContent {
            guard let text = file.content, !text.isEmpty else { return false }
            if let any = m.content, !any.isEmpty {
                guard any.contains(where: { text.localizedCaseInsensitiveContains($0) || (fuzzy && Fuzzy.matches($0, in: file.words)) }) else { return false }
            }
            if let all = m.contentAll, !all.isEmpty {
                guard all.allSatisfy({ text.localizedCaseInsensitiveContains($0) || (fuzzy && Fuzzy.matches($0, in: file.words)) }) else { return false }
            }
            if let re = m.contentRegex, !re.isEmpty {
                guard Patterns.matches(re, text) else { return false }
            }
        }
        return true
    }
}

enum Patterns {
    private static var cache = [String: NSRegularExpression]()
    private static let lock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache[pattern] = r
        return r
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = regex(pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
