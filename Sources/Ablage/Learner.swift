import Foundation

struct Example: Codable {
    var rule: String
    var source: String
    var name: String
    var tokens: [String]
    var positive: Bool
    var date: Date
}

struct Suggestion {
    var rule: String
    var score: Double
    var like: String
}

/// Learns from what the user files by hand, the way paperless-ngx's auto matching does.
/// A document is a set of tokens from its name, source and text. New files are compared
/// against stored examples by IDF-weighted cosine similarity. No model, nothing leaves the Mac.
final class Learner {
    private var storage: [Example] = []
    private let lock = NSLock()
    private let limit = 2000

    var examples: [Example] { lock.withLock { storage } }

    func load() {
        guard let data = try? Data(contentsOf: Paths.learnedFile) else { return }
        let loaded = (try? JSONDecoder().decode([Example].self, from: data)) ?? []
        lock.withLock { storage = loaded }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(examples) else { return }
        try? data.write(to: Paths.learnedFile, options: .atomic)
    }

    func learn(rule: String, facts: FileFacts, text: String?, positive: Bool) {
        let tokens = Array(Self.tokens(for: facts, text: text))
        guard !tokens.isEmpty else { return }
        lock.withLock {
            storage.removeAll { $0.rule == rule && $0.source == facts.url.path }
            storage.append(Example(rule: rule, source: facts.url.path, name: facts.name, tokens: tokens, positive: positive, date: Date()))
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
        }
        save()
        Log.write("learned: \(facts.name) \(positive ? "belongs to" : "does not belong to") \(rule)")
    }

    func forget(rule: String, source: String) {
        let changed = lock.withLock {
            let before = storage.count
            storage.removeAll { $0.rule == rule && $0.source == source }
            return storage.count != before
        }
        guard changed else { return }
        save()
        Log.write("forgot: \(Paths.abbreviate(source)) for \(rule)")
    }

    func suggest(facts: FileFacts, text: String?, among rules: Set<String>, config: LearnConfig) -> Suggestion? {
        let doc = Self.tokens(for: facts, text: text)
        guard !doc.isEmpty else { return nil }
        let examples = self.examples
        let pool = examples.filter { rules.contains($0.rule) }
        guard !pool.isEmpty else { return nil }

        var frequency = [String: Int]()
        for example in examples {
            for token in Set(example.tokens) { frequency[token, default: 0] += 1 }
        }
        let count = Double(examples.count)
        func idf(_ token: String) -> Double { log((count + 1) / (Double(frequency[token] ?? 0) + 1)) + 1 }
        let docWeights = Dictionary(uniqueKeysWithValues: doc.map { ($0, idf($0)) })
        let docNorm = sqrt(docWeights.values.reduce(0) { $0 + $1 * $1 })

        struct Tally {
            var score = 0.0
            var like = ""
            var positives = 0
            var negative = 0.0
        }
        var perRule = [String: Tally]()
        for example in pool {
            var dot = 0.0
            var norm = 0.0
            for token in example.tokens {
                let weight = idf(token)
                norm += weight * weight
                if let d = docWeights[token] { dot += d * weight }
            }
            let similarity = norm > 0 && docNorm > 0 ? dot / (sqrt(norm) * docNorm) : 0
            var tally = perRule[example.rule] ?? Tally()
            if example.positive {
                tally.positives += 1
                if similarity > tally.score {
                    tally.score = similarity
                    tally.like = example.name
                }
            } else {
                tally.negative = max(tally.negative, similarity)
            }
            perRule[example.rule] = tally
        }
        let ranked = perRule
            .filter { $0.value.positives >= config.minExamples && $0.value.score >= config.threshold && $0.value.score > $0.value.negative }
            .sorted { $0.value.score > $1.value.score }
        guard let top = ranked.first else { return nil }
        // Two rules scoring alike is a question for the user, not a guess.
        if ranked.count > 1, ranked[1].value.score > top.value.score - 0.05 { return nil }
        return Suggestion(rule: top.key, score: top.value.score, like: top.value.like)
    }

    static func tokens(for facts: FileFacts, text: String?) -> Set<String> {
        var out = Set<String>()
        if !facts.ext.isEmpty { out.insert("ext:" + facts.ext) }
        if !facts.host.isEmpty { out.insert("host:" + facts.host) }
        for source in [facts.stem, String((text ?? "").prefix(20_000))] {
            for token in tokenize(source) {
                out.insert(token)
                if out.count >= 1500 { return out }
            }
        }
        return out
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in token.count >= 3 && token.contains { $0.isLetter } }
    }
}
