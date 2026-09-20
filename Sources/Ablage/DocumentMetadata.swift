import Foundation

struct DocumentField: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case text, number, date, boolean }
    var id = UUID()
    var name = ""
    var kind = Kind.text
    var value = ""
    var key: String { name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_") }
}

struct DocumentMetadata: Codable, Equatable {
    var title = ""
    var correspondent = ""
    var documentDate = ""
    var documentType = ""
    var invoiceNumber = ""
    var amount = ""
    var currency = ""
    var dueDate = ""
    var fields: [DocumentField] = []

    var values: [String: String] {
        var result = ["title": title, "correspondent": correspondent, "date": documentDate,
                      "type": documentType, "invoice_number": invoiceNumber, "amount": amount,
                      "currency": currency, "due_date": dueDate]
        for field in fields where !field.key.isEmpty { result["field." + field.key] = field.value }
        return result
    }
    var searchable: String { values.map { $0.key + " " + $0.value }.joined(separator: " ") }

    func validate() throws {
        for (name, value) in [("Document date", documentDate), ("Due date", dueDate)] where !value.isEmpty {
            guard Self.date(value) != nil else { throw ConfigError(message: "\(name) must be a valid date in YYYY-MM-DD format.") }
        }
        if !amount.isEmpty, !Self.isNumber(amount) { throw ConfigError(message: "Use a decimal amount, such as 42.50.") }
        if !currency.isEmpty, !Patterns.matches(#"^[A-Za-z]{3}$"#, currency) { throw ConfigError(message: "Use a three-letter currency, such as EUR.") }
        var keys = Set<String>()
        for field in fields {
            guard !field.key.isEmpty, keys.insert(field.key).inserted else { throw ConfigError(message: "Give each additional field a distinct name.") }
            guard !field.value.isEmpty else { continue }
            switch field.kind {
            case .number: if !Self.isNumber(field.value) { throw ConfigError(message: "\(field.name) must be a number.") }
            case .date: if Self.date(field.value) == nil { throw ConfigError(message: "\(field.name) must be a date in YYYY-MM-DD format.") }
            case .boolean: if !["true", "false"].contains(field.value) { throw ConfigError(message: "\(field.name) must be true or false.") }
            case .text: break
            }
        }
    }
    static func isNumber(_ value: String) -> Bool { Patterns.matches(#"^-?[0-9]+(?:\.[0-9]+)?$"#, value) }
    static func date(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: string), formatter.string(from: date) == string else { return nil }
        return date
    }
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func suggestions(name: String, text: String) -> Self {
        var value = Self()
        value.title = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        if let date = Extract.date(in: text) ?? Extract.date(in: name) { value.documentDate = dateString(date) }
        func capture(_ pattern: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return "" }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value.invoiceNumber = capture(#"(?:invoice\s*(?:number|no\.?|#)|rechnungs(?:nummer|nr\.?))\s*:?\s*([A-Z0-9][A-Z0-9/_.-]+)"#)
        if !value.invoiceNumber.isEmpty { value.documentType = "Invoice" }
        return value
    }
}

extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

enum FileIdentity {
    static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
