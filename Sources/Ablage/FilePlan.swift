import Foundation

/// A read-only explanation of the next rules run. Unknown decisions stay explicitly unknown.
struct FilePlan: Equatable {
    enum State: Equatable { case ready, checking, arriving, noMatch, needsOCR, readingText, textFailed, model, manualModel }
    enum Kind: Equatable { case move, rename, tags, trash, keep, run, collision }
    struct Step: Equatable {
        let kind: Kind
        let value: String

        var symbol: String {
            switch kind {
            case .move: return "folder"
            case .rename: return "pencil"
            case .tags: return "tag"
            case .trash: return "trash"
            case .keep: return "pause.circle"
            case .run: return "terminal"
            case .collision: return "doc.on.doc"
            }
        }
        var title: String {
            switch kind {
            case .move: return "Move to"
            case .rename: return "Rename to"
            case .tags: return "Add Finder tags"
            case .trash: return "Move to Trash"
            case .keep: return "Leave unchanged"
            case .run: return "Run after filing"
            case .collision: return "Check the existing file"
            }
        }
        var summary: String {
            switch kind {
            case .move: return "Move to " + Paths.abbreviate(URL(fileURLWithPath: value).deletingLastPathComponent().path)
            case .rename: return "Rename to " + value
            case .tags: return "Add tags: " + value
            case .trash: return "Move to Trash"
            case .keep: return "Leave unchanged"
            case .run: return "Run a command"
            case .collision: return "Check duplicate before filing"
            }
        }
    }

    var state: State
    var rule: String? = nil
    var steps: [Step] = []
    var explanation = ""
    var notes: [String] = []

    static let checking = FilePlan(state: .checking, explanation: "Reading the file and checking its rules. No files are changed by this preview.")
    static let arriving = FilePlan(state: .arriving, explanation: "Waiting for this download or copy to finish before checking its rules.")
    static let noMatch = FilePlan(state: .noMatch, explanation: "No enabled rule matches this file. It will stay in this inbox.")
    static let needsOCR = FilePlan(state: .needsOCR, explanation: "Queued for on-device text recognition. The plan updates automatically when the text is ready. Files stay unchanged. Recognition waits while Ablage is paused.")
    static let readingText = FilePlan(state: .readingText, explanation: "Reading this document on your Mac. Its plan will update automatically. No files are changed and no model is contacted.")
    static func textFailed(_ reason: String) -> FilePlan {
        FilePlan(state: .textFailed, explanation: reason, notes: ["A content rule could not be checked. The file stays here so a later rule cannot file it by mistake. You can retry or review the document yourself."])
    }

    var summary: String {
        if let first = steps.first { return first.summary }
        switch state {
        case .checking: return "Checking rules…"
        case .arriving: return "Waiting for download to finish"
        case .noMatch: return "Keep here · no matching rule"
        case .needsOCR: return "Waiting to read text"
        case .readingText: return "Reading text…"
        case .textFailed: return "Could not read document text"
        case .model: return "Ask a model to choose a rule"
        case .manualModel: return "Keep here · model request needed"
        case .ready: return "Leave unchanged"
        }
    }
    var symbol: String {
        if let first = steps.first { return first.symbol }
        switch state {
        case .checking, .arriving: return "clock"
        case .needsOCR, .readingText: return "doc.text.magnifyingglass"
        case .textFailed: return "exclamationmark.triangle"
        case .model, .manualModel: return "sparkles"
        default: return "minus.circle"
        }
    }
    var isDestructive: Bool { steps.contains { $0.kind == .trash || $0.kind == .collision } }
    var hasAction: Bool { state == .model || steps.contains { $0.kind != .keep } }
    var additionalActions: String {
        steps.dropFirst().map { step in
            switch step.kind {
            case .rename: return "rename"
            case .tags: return "add tags"
            case .run: return "run command"
            default: return step.summary
            }
        }.joined(separator: " · ")
    }
    var searchText: String { ([summary, rule ?? "", explanation] + steps.map(\.value) + notes).joined(separator: " ") }
    var fullDescription: String {
        var lines = [summary, explanation]
        if let rule { lines.append("Rule: " + rule) }
        lines += steps.map { $0.title + ": " + $0.value }
        lines += notes
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func evaluate(rules: [Rule], file: FileContext, inbox: URL, config: Config,
                         ocrPending: () -> Bool, textFailure: () -> String? = { nil }, learned: () -> Suggestion?) -> FilePlan {
        let enabled = rules.filter(\.isEnabled)
        for rule in enabled where rule.match.ai == nil {
            let matches = Matcher.matches(rule.match, file)
            if let failure = textFailure() { return .textFailed(failure) }
            if matches {
                let plan = forRule(rule, file: file, inbox: inbox, config: config, ocrPending: ocrPending)
                if let failure = textFailure() { return .textFailed(failure) }
                return plan
            }
            // An earlier content rule may win after OCR. Do not present a later fallback as certain.
            if rule.match.needsContent, ocrPending() {
                var metadata = rule.match
                metadata.content = nil; metadata.contentAll = nil; metadata.contentRegex = nil
                if Matcher.matches(metadata, file) { return .needsOCR }
            }
        }
        let suggestion = learned()
        if let failure = textFailure() { return .textFailed(failure) }
        if let suggestion, let rule = enabled.first(where: { $0.name == suggestion.rule }) {
            if ocrPending() { return .needsOCR }
            var plan = forRule(rule, file: file, inbox: inbox, config: config, learned: true, ocrPending: ocrPending)
            plan.explanation = "Learned from “\(suggestion.like)” (\(Int(suggestion.similarity * 100))% similarity)."
            return plan
        }
        let candidates = enabled.filter { $0.match.ai != nil && Matcher.matches($0.match, file) }
        if let failure = textFailure() { return .textFailed(failure) }
        if !candidates.isEmpty {
            let automatic = candidates.filter { config.ai.models[$0.match.ai!.model]?.runsAutomatically == true }
            let pool = automatic.isEmpty ? candidates : automatic
            let models = Array(Set(pool.compactMap { $0.match.ai?.model })).sorted().joined(separator: ", ")
            return FilePlan(state: automatic.isEmpty ? .manualModel : .model,
                            explanation: automatic.isEmpty
                                ? "The file stays here until you choose Ask model → \(models). The model may choose a rule or leave it unmatched."
                                : "\(models) will choose among the rules below, or leave this file unmatched. No model has been contacted for this preview.",
                            notes: ["Possible rules: " + pool.map(\.name).joined(separator: ", ")])
        }
        return ocrPending() ? .needsOCR : .noMatch
    }

    static func forRule(_ rule: Rule, file: FileContext, inbox: URL, config: Config,
                        learned: Bool = false, ocrPending: () -> Bool = { false }) -> FilePlan {
        let action = rule.action
        let facts = file.facts
        var plan = FilePlan(state: .ready, rule: rule.name)
        func add(_ kind: Kind, _ value: String = "") { plan.steps.append(Step(kind: kind, value: value)) }
        if action.trash == true {
            add(.trash, "The file goes to the macOS Trash. You can undo this from Activity.")
            if let command = action.run { add(.run, command) }
            return plan
        }
        if action.isNoop { add(.keep, "This rule deliberately keeps the file in place."); return plan }
        if !action.movesOrTags, let command = action.run { add(.run, command); return plan }

        let context = rule.templateContext(for: file, enrichment: nil)
        var unresolved = Set<String>()
        if !learned, let name = action.ai, config.ai.models[name]?.runsAutomatically == true {
            if file.metadata.title.isEmpty { unresolved.insert("{title}") }
            if action.correspondent == nil, file.metadata.correspondent.isEmpty { unresolved.insert("{correspondent}") }
            if action.dateFrom != "filename", file.metadata.documentDate.isEmpty { unresolved.formUnion(["{date}", "{year}", "{month}", "{day}"]) }
            if !unresolved.isEmpty { plan.notes.append("\(name) fills document details when the rule runs. Fields in braces are not known yet.") }
        }
        if action.usesDate, action.dateFrom == "content", file.metadata.documentDate.isEmpty, ocrPending() {
            unresolved.formUnion(["{date}", "{year}", "{month}", "{day}"])
            plan.notes.append("The document date is not known until text recognition runs.")
        }
        let target = rule.targetURL(for: facts, context: context, inbox: inbox, preserving: unresolved)
        if Patterns.matches(#"\{(?:invoice_number|amount|currency|due_date|type|field\.[^{}]+)\}"#, target.path) {
            plan.notes.append("Complete the document fields in Review & file before this rule can file the document.")
        }
        let existingTags = Tags.read(facts.url)
        let tags = (action.tags ?? []).filter { !existingTags.contains($0) }
        if FileIdentity.same(target, facts.url) {
            if tags.isEmpty { add(.keep, "The file is already in the requested place and has the requested tags.") }
            else {
                add(.tags, tags.joined(separator: ", "))
                if let command = action.run { add(.run, command) }
            }
            return plan
        }
        if unresolved.isEmpty, FileManager.default.fileExists(atPath: target.path) {
            add(.collision, Paths.abbreviate(target.path))
            let uniqueName = Hashing.unique(target).lastPathComponent
            plan.notes.append(facts.isFolder
                ? "The folder will be filed as “\(uniqueName)”. Existing folders are never overwritten."
                : "An identical copy would go to Trash. Otherwise it will be filed as “\(uniqueName)”. Existing files are never overwritten.")
            if !tags.isEmpty { plan.notes.append("If moved, add tags: " + tags.joined(separator: ", ")) }
            if let command = action.run { plan.notes.append("If moved, run: " + command) }
            return plan
        }
        if target.deletingLastPathComponent().path != facts.url.deletingLastPathComponent().path { add(.move, target.path) }
        if target.lastPathComponent != facts.name { add(.rename, target.lastPathComponent) }
        if !tags.isEmpty { add(.tags, tags.joined(separator: ", ")) }
        if let command = action.run { add(.run, command) }
        if config.searchablePDFs, facts.ext == "pdf" { plan.notes.append("After moving, a scanned PDF may receive a searchable text layer. Undo restores the original.") }
        return plan
    }
}
