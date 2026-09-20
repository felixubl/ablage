import Foundation

struct DocumentReviewPacket {
    var facts: FileFacts
    var text: String
    var metadata: DocumentMetadata
    var rules: [Rule]
    var inbox: URL
    var config: Config
    var plan: FilePlan
    var digest: String

    func draft(ruleIndex: Int? = nil) -> DocumentReviewDraft {
        var draft = DocumentReviewDraft(folder: facts.url.deletingLastPathComponent().path, filename: facts.name, tags: Tags.read(facts.url).joined(separator: ", "), metadata: metadata)
        let rule = ruleIndex.flatMap { rules.indices.contains($0) ? rules[$0] : nil } ?? rules.first { $0.name == plan.rule }
        if let rule {
            draft.ruleName = rule.name; draft.trash = rule.action.trash == true; draft.command = rule.action.run
            let file = FileContext(facts: facts, metadata: metadata) { text }
            let target = rule.targetURL(for: facts, context: rule.templateContext(for: file, enrichment: nil), inbox: inbox)
            draft.folder = target.deletingLastPathComponent().path
            draft.filename = target.lastPathComponent
            draft.tags = Array(Set(Tags.read(facts.url) + (rule.action.tags ?? []))).sorted().joined(separator: ", ")
        }
        return draft
    }
}

struct DocumentReviewDraft {
    var folder: String
    var filename: String
    var tags: String
    var metadata: DocumentMetadata
    var ruleName = "Reviewed"
    var trash = false
    var command: String?

    func validate() throws {
        try metadata.validate()
        guard !trash else { return }
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), name.rangeOfCharacter(from: .controlCharacters) == nil, !name.hasPrefix(".") else {
            throw ConfigError(message: "Enter a filename without slashes, colons or a leading dot.")
        }
        guard !Patterns.matches(#"\{[^}]+\}"#, name + folder) else { throw ConfigError(message: "Complete the fields in braces before approving this file.") }
        guard Paths.expand(folder).hasPrefix("/") else { throw ConfigError(message: "Choose a destination folder.") }
    }
}
