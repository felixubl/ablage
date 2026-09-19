import Foundation

/// Turns a document into the features the learner sees: stemmed words and word pairs from the
/// text, words from the file name, the extension and the download host. Stop words are dropped.
enum TextFeatures {
    static let stopwords: Set<String> = [
        // German
        "aber", "alle", "allem", "allen", "aller", "alles", "als", "also", "auch", "auf", "aus", "bei", "bin", "bis", "bist", "das",
        "dass", "dein", "deine", "dem", "den", "der", "des", "dich", "die", "dies", "diese", "diesem", "diesen", "dieser", "dieses",
        "dir", "doch", "dort", "durch", "ein", "eine", "einem", "einen", "einer", "eines", "einig", "einige", "einmal", "euch", "euer",
        "eure", "für", "fuer", "gegen", "habe", "haben", "hat", "hatte", "hatten", "hier", "hin", "hinter", "ich", "ihm", "ihn", "ihnen",
        "ihr", "ihre", "ihrem", "ihren", "ihrer", "ihres", "immer", "ins", "ist", "jede", "jedem", "jeden", "jeder", "jedes", "jene",
        "jetzt", "kann", "kein", "keine", "keinem", "keinen", "keiner", "können", "koennen", "man", "mehr", "mein", "meine", "meinem",
        "meinen", "meiner", "mich", "mir", "mit", "nach", "nicht", "nichts", "noch", "nun", "nur", "ober", "oder", "ohne", "sehr", "sein",
        "seine", "seinem", "seinen", "seiner", "sich", "sie", "sind", "soll", "sollen", "sondern", "sonst", "über", "ueber", "und", "uns",
        "unser", "unsere", "unter", "viel", "vom", "von", "vor", "war", "waren", "warst", "was", "weg", "weil", "weiter", "welche",
        "welchem", "welchen", "welcher", "welches", "wenn", "werde", "werden", "wie", "wieder", "will", "wir", "wird", "wirst", "woher",
        "wohin", "zum", "zur", "zwar", "zwischen", "sowie", "bzw", "etc", "usw", "ggf", "inkl", "zzgl",
        // English
        "about", "above", "after", "again", "against", "all", "and", "any", "are", "because", "been", "before", "being", "below",
        "between", "both", "but", "can", "did", "does", "doing", "down", "during", "each", "few", "for", "from", "further", "had",
        "has", "have", "having", "her", "here", "hers", "him", "his", "how", "into", "its", "itself", "just", "more", "most", "not",
        "now", "off", "once", "only", "other", "our", "ours", "out", "over", "own", "same", "she", "should", "some", "such", "than",
        "that", "the", "their", "theirs", "them", "then", "there", "these", "they", "this", "those", "through", "too", "under",
        "until", "very", "was", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would",
        "you", "your", "yours",
    ]

    /// Lowercased words with at least one letter and three characters, stop words removed.
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in token.count >= 3 && token.contains { $0.isLetter } && !stopwords.contains(token) }
    }

    /// Unstemmed words, for fuzzy matching.
    static func rawWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// Light suffix stripping for German and English. Enough to make Rechnung and Rechnungen one feature.
    static func stem(_ word: String) -> String {
        guard word.count >= 6, word.contains(where: \.isLetter), !word.contains(where: \.isNumber) else { return word }
        for suffix in ["ungen", "innen", "erinnen", "lichen", "ing", "ungs", "ung", "lich", "isch", "keit", "heit", "ern", "en", "er", "es", "ed", "st", "e", "n", "s"] {
            if word.hasSuffix(suffix), word.count - suffix.count >= 4 {
                return String(word.dropLast(suffix.count))
            }
        }
        return word
    }

    static func features(for facts: FileFacts, text: String?) -> [String: Int] {
        var out = [String: Int]()
        if !facts.ext.isEmpty { out["ext:" + facts.ext] = 2 }
        if !facts.host.isEmpty { out["host:" + facts.host] = 2 }
        for word in words(facts.stem) { out["fn:" + stem(word), default: 0] += 2 }
        let body = words(String((text ?? "").prefix(30_000))).map(stem)
        var counts = [String: Int]()
        for (i, word) in body.enumerated() {
            counts[word, default: 0] += 1
            if i + 1 < body.count { counts[word + " " + body[i + 1], default: 0] += 1 }
        }
        for (feature, count) in counts { out[feature, default: 0] += min(count, 3) }
        if out.count > 4000 {
            let kept = out.sorted { $0.value > $1.value }.prefix(4000)
            out = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        return out
    }
}

struct Example: Codable {
    var id = UUID()
    var rule: String
    var source: String
    var name: String
    var features: [String: Int]
    var weight: Double
    var positive: Bool
    var date = Date()
    /// Filings by a rule count as training data only once this has passed without an undo.
    var confirmAfter: Date?
    var entryId: UUID?

    var isActive: Bool { confirmAfter.map { $0 <= Date() } ?? true }

    init(rule: String, source: String, name: String, features: [String: Int], weight: Double, positive: Bool, confirmAfter: Date?, entryId: UUID?) {
        self.rule = rule
        self.source = source
        self.name = name
        self.features = features
        self.weight = weight
        self.positive = positive
        self.confirmAfter = confirmAfter
        self.entryId = entryId
    }

    private enum CodingKeys: String, CodingKey { case id, rule, source, name, features, tokens, weight, positive, date, confirmAfter, entryId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rule = try c.decode(String.self, forKey: .rule)
        source = try c.decode(String.self, forKey: .source)
        name = try c.decode(String.self, forKey: .name)
        if let f = try c.decodeIfPresent([String: Int].self, forKey: .features) {
            features = f
        } else {
            // First-version examples stored a flat token list.
            let tokens = try c.decodeIfPresent([String].self, forKey: .tokens) ?? []
            features = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        }
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        positive = try c.decodeIfPresent(Bool.self, forKey: .positive) ?? true
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        confirmAfter = try c.decodeIfPresent(Date.self, forKey: .confirmAfter)
        entryId = try c.decodeIfPresent(UUID.self, forKey: .entryId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(rule, forKey: .rule)
        try c.encode(source, forKey: .source)
        try c.encode(name, forKey: .name)
        try c.encode(features, forKey: .features)
        try c.encode(weight, forKey: .weight)
        try c.encode(positive, forKey: .positive)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(confirmAfter, forKey: .confirmAfter)
        try c.encodeIfPresent(entryId, forKey: .entryId)
    }
}

struct Suggestion {
    var rule: String
    /// Posterior probability from the classifier, 1 when only one rule was in the running.
    var confidence: Double
    /// Cosine similarity to the nearest example of that rule.
    var similarity: Double
    var like: String
}

/// paperless-ngx's auto matching: a classifier trained on everything that was filed.
///
/// Multinomial naive Bayes over the features above decides between the rules that have enough
/// examples. A nearest-example similarity floor rejects documents that resemble nothing seen so
/// far, which a bare classifier cannot do, and counterexamples from undone filings veto a rule.
final class Learner {
    private var storage: [Example] = []
    private let lock = NSLock()
    private let limit = 5000
    private var version = 0
    private var cached: (version: Int, model: Model)?

    private struct ClassStats {
        var counts = [String: Double]()
        var total = 0.0
        var weight = 0.0
        var positives = 0
        var examples: [Example] = []
        var negatives: [Example] = []
    }

    private struct Model {
        var classes = [String: ClassStats]()
        var vocabulary = Set<String>()
        var documentFrequency = [String: Int]()
        var documents = 0
    }

    var examples: [Example] { lock.withLock { storage } }

    func load() {
        guard let data = try? Data(contentsOf: Paths.learnedFile) else { return }
        let loaded = (try? JSONDecoder().decode([Example].self, from: data)) ?? []
        lock.withLock {
            storage = loaded
            version += 1
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(examples) else { return }
        try? data.write(to: Paths.learnedFile, options: .atomic)
    }

    @discardableResult
    func learn(rule: String, facts: FileFacts, text: String?, weight: Double, positive: Bool, confirmAfter: Date?, entryId: UUID?) -> UUID? {
        let features = TextFeatures.features(for: facts, text: text)
        guard features.count >= 3 else { return nil }
        let example = Example(
            rule: rule, source: facts.url.path, name: facts.name, features: features, weight: weight, positive: positive,
            confirmAfter: confirmAfter, entryId: entryId)
        lock.withLock {
            storage.removeAll { $0.rule == rule && $0.source == facts.url.path && $0.positive == positive }
            storage.append(example)
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
            version += 1
        }
        save()
        let when = confirmAfter.map { " (counts from \(Self.short($0)))" } ?? ""
        Log.write("learned: \(facts.name) \(positive ? "belongs to" : "does not belong to") \(rule)\(when)")
        return example.id
    }

    func forget(entryId: UUID) {
        let removed = lock.withLock { () -> [Example] in
            let gone = storage.filter { $0.entryId == entryId }
            storage.removeAll { $0.entryId == entryId }
            if !gone.isEmpty { version += 1 }
            return gone
        }
        guard !removed.isEmpty else { return }
        save()
        for example in removed { Log.write("forgot: \(example.name) for \(example.rule)") }
    }

    func forget(rule: String, source: String) {
        let changed = lock.withLock {
            let before = storage.count
            storage.removeAll { $0.rule == rule && $0.source == source }
            if storage.count != before { version += 1 }
            return storage.count != before
        }
        guard changed else { return }
        save()
        Log.write("forgot: \(Paths.abbreviate(source)) for \(rule)")
    }

    func suggest(facts: FileFacts, text: String?, among rules: Set<String>, config: LearnConfig) -> Suggestion? {
        let doc = TextFeatures.features(for: facts, text: text)
        guard doc.count >= 3 else { return nil }
        let model = self.model()
        let candidates = model.classes.filter { rules.contains($0.key) && $0.value.positives >= config.minExamples }
        guard !candidates.isEmpty else { return nil }

        // Naive Bayes with Laplace smoothing, normalised over the candidate rules.
        let alpha = 0.5
        let vocabulary = Double(model.vocabulary.count)
        let totalWeight = candidates.values.reduce(0) { $0 + $1.weight }
        var logPosterior = [String: Double]()
        for (name, stats) in candidates {
            var score = log(stats.weight / totalWeight)
            let denominator = log(stats.total + alpha * vocabulary)
            for (feature, count) in doc {
                score += Double(count) * (log((stats.counts[feature] ?? 0) + alpha) - denominator)
            }
            logPosterior[name] = score
        }
        let peak = logPosterior.values.max() ?? 0
        let normaliser = logPosterior.values.reduce(0) { $0 + exp($1 - peak) }
        let posterior = logPosterior.mapValues { exp($0 - peak) / normaliser }

        // Nearest example, for the explanation and the similarity floor.
        let idf = { (feature: String) -> Double in log(Double(model.documents + 1) / Double((model.documentFrequency[feature] ?? 0) + 1)) + 1 }
        let docWeights = Dictionary(uniqueKeysWithValues: doc.keys.map { ($0, idf($0)) })
        let docNorm = sqrt(docWeights.values.reduce(0) { $0 + $1 * $1 })
        func similarity(_ example: Example) -> Double {
            var dot = 0.0
            var norm = 0.0
            for feature in example.features.keys {
                let w = idf(feature)
                norm += w * w
                if let d = docWeights[feature] { dot += d * w }
            }
            return norm > 0 && docNorm > 0 ? dot / (sqrt(norm) * docNorm) : 0
        }

        let ranked = candidates.keys.sorted { (posterior[$0] ?? 0) > (posterior[$1] ?? 0) }
        guard let best = ranked.first, let stats = candidates[best] else { return nil }
        let confidence = candidates.count == 1 ? 1 : (posterior[best] ?? 0)
        let runnerUp = ranked.dropFirst().first.flatMap { posterior[$0] } ?? 0
        guard confidence >= config.minConfidence, confidence - runnerUp >= 0.2 || candidates.count == 1 else { return nil }

        var nearest = 0.0
        var like = ""
        for example in stats.examples {
            let s = similarity(example)
            if s > nearest {
                nearest = s
                like = example.name
            }
        }
        let veto = stats.negatives.map(similarity).max() ?? 0
        guard nearest >= config.minSimilarity, nearest > veto else { return nil }
        return Suggestion(rule: best, confidence: confidence, similarity: nearest, like: like)
    }

    private func model() -> Model {
        let (examples, version) = lock.withLock { (storage, self.version) }
        if let cached, cached.version == version { return cached.model }
        var model = Model()
        for example in examples where example.isActive {
            var stats = model.classes[example.rule] ?? ClassStats()
            if example.positive {
                for (feature, count) in example.features {
                    let weighted = Double(count) * example.weight
                    stats.counts[feature, default: 0] += weighted
                    stats.total += weighted
                    model.vocabulary.insert(feature)
                }
                stats.weight += example.weight
                stats.positives += 1
                stats.examples.append(example)
                for feature in example.features.keys { model.documentFrequency[feature, default: 0] += 1 }
                model.documents += 1
            } else {
                stats.negatives.append(example)
            }
            model.classes[example.rule] = stats
        }
        cached = (version, model)
        return model
    }

    private static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: date)
    }
}
