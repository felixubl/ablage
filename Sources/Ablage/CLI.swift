import Foundation

/// `Ablage learn <rule> <file>`, `Ablage forget <rule> <file>`, `Ablage suggest <file>`, `Ablage examples`.
/// The same learning the panel does from Apply rule, usable from scripts and tests.
enum CLI {
    static let commands = ["learn", "forget", "suggest", "examples", "add-rule", "validate"]

    static func run(_ args: [String]) -> Int32 {
        let learner = Learner()
        learner.load()
        let config = (try? ConfigStore.load()) ?? Config()
        let cache = ContentCache()

        func facts(_ path: String) -> FileFacts? {
            let url = URL(fileURLWithPath: Paths.expand(path)).standardizedFileURL
            guard let f = FileFacts(url: url) else {
                print("no such file: \(path)")
                return nil
            }
            return f
        }

        switch args.first {
        case "learn", "forget":
            guard args.count >= 3 else {
                print("usage: Ablage \(args[0]) <rule> <file> [--negative]")
                return 2
            }
            guard let f = facts(args[2]) else { return 1 }
            if args[0] == "forget" {
                learner.forget(rule: args[1], source: f.url.path)
            } else {
                let text = cache.text(for: f, config: config, allowOCR: true)
                learner.learn(rule: args[1], facts: f, text: text, positive: !args.contains("--negative"))
            }
        case "suggest":
            guard args.count >= 2, let f = facts(args[1]) else {
                print("usage: Ablage suggest <file>")
                return 2
            }
            let text = cache.text(for: f, config: config, allowOCR: true)
            let names = Set(learner.examples.map(\.rule))
            if let s = learner.suggest(facts: f, text: text, among: names, config: config.learning) {
                print("\(s.rule)\t\(String(format: "%.2f", s.score))\tlike \(s.like)")
            } else {
                print("no suggestion")
            }
        case "examples":
            for e in learner.examples {
                print("\(e.positive ? "+" : "-")\t\(e.rule)\t\(e.name)\t\(e.tokens.count) tokens")
            }
        case "add-rule":
            guard args.count >= 2 else {
                print("usage: Ablage add-rule '<rule json>'")
                return 2
            }
            do {
                try ConfigStore.appendRule(args[1])
                print("added to \(Paths.abbreviate(Paths.configFile.path))")
            } catch {
                print("could not add rule: \(error.localizedDescription)")
                return 1
            }
        case "validate":
            do {
                let loaded = try ConfigStore.load()
                let problems = ConfigStore.problems(in: loaded)
                if problems.isEmpty {
                    print("ok: \(loaded.rules.count) shared rules, \(loaded.resolvedInboxes.count) inbox(es)")
                } else {
                    problems.forEach { print($0) }
                    return 1
                }
            } catch {
                print(ConfigStore.describe(error))
                return 1
            }
        default:
            print("usage: Ablage learn|forget <rule> <file> | suggest <file> | examples | add-rule '<json>' | validate")
            return 2
        }
        Log.flush()
        return 0
    }
}
