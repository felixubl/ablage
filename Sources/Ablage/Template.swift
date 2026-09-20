import Foundation

struct TemplateContext {
    var date: Date
    var name: String
    var ext: String
    var correspondent: String
    var title: String
    var rule: String
    var host: String
    var fields: [String: String] = [:]
}

enum Template {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let date = formatter("yyyy-MM-dd")
    private static let year = formatter("yyyy")
    private static let month = formatter("MM")
    private static let day = formatter("dd")

    static func expand(_ template: String, _ c: TemplateContext, preserving unresolved: Set<String> = []) -> String {
        let values: [(String, String)] = [
            ("{date}", date.string(from: c.date)),
            ("{year}", year.string(from: c.date)),
            ("{month}", month.string(from: c.date)),
            ("{day}", day.string(from: c.date)),
            ("{name}", c.name),
            ("{ext}", c.ext),
            ("{correspondent}", c.correspondent),
            ("{title}", c.title),
            ("{rule}", c.rule),
            ("{host}", c.host),
        ]
        var replacements = Dictionary(uniqueKeysWithValues: values)
        for (key, value) in c.fields where !value.isEmpty && !["date", "title", "correspondent"].contains(key) {
            replacements["{" + key + "}"] = value
        }
        // Replace tokens once. Document text cannot inject further placeholders or path segments.
        let pattern = try! NSRegularExpression(pattern: #"\{[^}]+\}"#)
        var out = template
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let token = String(out[range])
            if !unresolved.contains(token), let value = replacements[token] {
                out.replaceSubrange(range, with: component(value))
            }
        }
        return out
    }

    private static func component(_ value: String) -> String {
        var value = value.components(separatedBy: .controlCharacters).joined()
        for separator in ["/", "\\", ":"] { value = value.replacingOccurrences(of: separator, with: "-") }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "." || value == ".." ? "_" : value
    }

    static func filename(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        while out.utf8.count > 180 { out.removeLast() }
        return out.isEmpty ? "unnamed" : out
    }

    static func destination(_ template: String, _ c: TemplateContext, inbox: URL, preserving unresolved: Set<String> = []) -> URL {
        resolve(expand(template, c, preserving: unresolved), inbox: inbox)
    }

    /// The fixed part of a destination template, before the first placeholder.
    static func destinationRoot(_ template: String, inbox: URL) -> URL {
        let fixed = template.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? template
        return resolve(fixed, inbox: inbox)
    }

    private static func resolve(_ path: String, inbox: URL) -> URL {
        if path.hasPrefix("~") || path.hasPrefix("/") {
            return URL(fileURLWithPath: Paths.expand(path), isDirectory: true).standardizedFileURL
        }
        return inbox.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}


extension Rule {
    /// Shared by the read-only plan and execution, so dates and filenames agree.
    func templateContext(for file: FileContext, enrichment: Classification?) -> TemplateContext {
        let facts = file.facts
        var date = facts.modified
        if action.usesDate {
            switch action.dateFrom ?? (enrichment != nil ? "content" : "file") {
            case "content": date = enrichment?.date ?? file.content.flatMap(Extract.date) ?? Extract.date(in: facts.stem) ?? facts.modified
            case "filename": date = Extract.date(in: facts.stem) ?? facts.modified
            default: date = enrichment?.date ?? facts.modified
            }
        }
        if let corrected = DocumentMetadata.date(file.metadata.documentDate) { date = corrected }
        return TemplateContext(date: date, name: facts.stem, ext: facts.ext,
                               correspondent: file.metadata.correspondent.isEmpty ? (action.correspondent ?? enrichment?.correspondent ?? "") : file.metadata.correspondent,
                               title: file.metadata.title.isEmpty ? (enrichment?.title ?? "") : file.metadata.title, rule: name, host: facts.host, fields: file.metadata.values)
    }

    func targetURL(for facts: FileFacts, context: TemplateContext, inbox: URL, preserving unresolved: Set<String> = []) -> URL {
        let folder = action.destination.map { Template.destination($0, context, inbox: inbox, preserving: unresolved) } ?? facts.url.deletingLastPathComponent()
        let stem = action.rename.map { Template.filename(Template.expand($0, context, preserving: unresolved)) } ?? facts.stem
        let filename = facts.extOriginal.isEmpty ? stem : "\(stem).\(facts.extOriginal)"
        return folder.appendingPathComponent(filename)
    }
}
