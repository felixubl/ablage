import Foundation

struct TemplateContext {
    var date: Date
    var name: String
    var ext: String
    var correspondent: String
    var title: String
    var rule: String
    var host: String
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

    static func expand(_ template: String, _ c: TemplateContext) -> String {
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
        var out = template
        for (token, value) in values {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }

    static func filename(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        if out.count > 180 { out = String(out.prefix(180)) }
        return out.isEmpty ? "unnamed" : out
    }

    static func destination(_ template: String, _ c: TemplateContext, inbox: URL) -> URL {
        resolve(expand(template, c), inbox: inbox)
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
