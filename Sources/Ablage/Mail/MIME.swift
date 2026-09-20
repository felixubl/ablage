import Foundation

struct MailAttachment { var name: String; var data: Data }
enum MIME {
    static func attachments(_ data: Data, extensions: Set<String>) throws -> [MailAttachment] {
        var result: [MailAttachment] = []
        try parse(data, extensions: extensions, depth: 0, into: &result)
        return result
    }
    private static func parse(_ data: Data, extensions: Set<String>, depth: Int, into output: inout [MailAttachment]) throws {
        guard depth < 16, output.count < 200 else { throw ConfigError(message: "The email contains too many nested attachments.") }
        guard let message = String(data: data, encoding: .isoLatin1),
              let divider = message.range(of: "\r\n\r\n") ?? message.range(of: "\n\n") else { return }
        let headerText = String(message[..<divider.lowerBound]).replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let contentType = headers["content-type"] ?? "text/plain"
        let body = String(message[divider.upperBound...])
        let typeParameters = parameters(contentType)
        if contentType.lowercased().hasPrefix("multipart/"), let boundary = typeParameters["boundary"], !boundary.isEmpty {
            let pattern = #"(?:^|\r?\n)--"# + NSRegularExpression.escapedPattern(for: boundary) + #"(--)?[ \t]*(?:\r?\n|$)"#
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
            guard matches.count >= 2, matches.last?.range(at: 1).location != NSNotFound else { throw ConfigError(message: "The email has an incomplete multipart body. It will be retried.") }
            for index in 0..<max(0, matches.count - 1) {
                if matches[index].range(at: 1).location != NSNotFound { break }
                let start = matches[index].range.location + matches[index].range.length
                let end = matches[index + 1].range.location
                guard end >= start, let range = Range(NSRange(location: start, length: end - start), in: body), let part = String(body[range]).data(using: .isoLatin1) else { continue }
                try parse(part, extensions: extensions, depth: depth + 1, into: &output)
            }
            return
        }
        if contentType.lowercased().hasPrefix("message/rfc822") {
            let nested: Data?
            if headers["content-transfer-encoding"]?.lowercased() == "base64" { nested = Data(base64Encoded: body.filter { !$0.isWhitespace }) }
            else if headers["content-transfer-encoding"]?.lowercased() == "quoted-printable" { nested = try quotedPrintable(body) }
            else { nested = body.data(using: .isoLatin1) }
            guard let nested else { throw ConfigError(message: "A forwarded email has invalid transfer encoding.") }
            try parse(nested, extensions: extensions, depth: depth + 1, into: &output)
            return
        }
        let disposition = parameters(headers["content-disposition"] ?? "")
        guard let rawName = parameterName("filename", disposition) ?? parameterName("name", typeParameters) else { return }
        let name = safeName(decodeWords(rawName))
        guard !name.isEmpty, extensions.isEmpty || extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { return }
        let decoded: Data
        switch headers["content-transfer-encoding"]?.lowercased() {
        case "base64":
            let compact = body.filter { !$0.isWhitespace }
            guard let value = Data(base64Encoded: compact) else { throw ConfigError(message: "An attachment has invalid base64 data: " + name) }
            decoded = value
        case "quoted-printable": decoded = try quotedPrintable(body)
        default: decoded = body.data(using: .isoLatin1) ?? Data()
        }
        guard !decoded.isEmpty else { return }
        output.append(MailAttachment(name: name, data: decoded))
    }
    static func safeName(_ raw: String) -> String {
        let decoded = raw.data(using: .isoLatin1).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        let basename = decoded.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "attachment"
        let cleaned = basename.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        let url = URL(fileURLWithPath: cleaned)
        // Keep the extension when shortening a long attachment name.
        if !url.pathExtension.isEmpty, url.pathExtension.utf8.count <= 32 {
            return Template.filename(url.deletingPathExtension().lastPathComponent) + "." + Template.filename(url.pathExtension)
        }
        return Template.filename(cleaned)
    }
    private static func parameters(_ header: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|;)\s*([\w*.-]+)\s*=\s*("(?:\\.|[^"\\])*"|[^;]*)"#) else { return [:] }
        var values: [String: String] = [:]
        for match in regex.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            guard let key = Range(match.range(at: 1), in: header), let range = Range(match.range(at: 2), in: header) else { continue }
            let value = String(header[range]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            values[String(header[key]).lowercased()] = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return values
    }
    private static func parameterName(_ key: String, _ values: [String: String]) -> String? {
        var extended = values[key + "*"]
        if extended == nil, values[key + "*0*"] != nil || values[key + "*0"] != nil {
            var pieces: [String] = []; var index = 0
            while let value = values[key + "*\(index)*"] ?? values[key + "*\(index)"] { pieces.append(value); index += 1 }
            extended = pieces.joined()
        }
        if let extended {
            let parts = extended.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            let encoded = parts.count == 3 ? String(parts[2]) : extended
            let charset = parts.count == 3 ? String(parts[0]).lowercased() : "utf-8"
            let bytes = Array(encoded.data(using: .isoLatin1) ?? Data(encoded.utf8))
            var decoded = Data(); var index = 0
            while index < bytes.count {
                if bytes[index] == 37, index + 2 < bytes.count,
                   let byte = UInt8(String(decoding: bytes[index+1...index+2], as: UTF8.self), radix: 16) {
                    decoded.append(byte); index += 3
                } else { decoded.append(bytes[index]); index += 1 }
            }
            let encoding: String.Encoding = charset == "iso-8859-1" ? .isoLatin1 : (charset == "windows-1252" ? .windowsCP1252 : .utf8)
            return String(data: decoded, encoding: encoding) ?? values[key] ?? String(data: decoded, encoding: .isoLatin1)
        }
        return values[key]
    }
    static func quotedPrintable(_ text: String) throws -> Data {
        let bytes = Array(text.data(using: .isoLatin1) ?? Data()); var output: [UInt8] = []; var i = 0
        while i < bytes.count {
            if bytes[i] != 61 { output.append(bytes[i]); i += 1; continue }
            if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
            if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            guard i + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[i+1...i+2], as: UTF8.self), radix: 16) else { throw ConfigError(message: "An email attachment has invalid quoted-printable data.") }
            output.append(byte); i += 3
        }
        return Data(output)
    }
    static func decodeWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let full = Range(match.range, in: result), let body = Range(match.range(at: 3), in: text), let encoding = Range(match.range(at: 2), in: text), let charset = Range(match.range(at: 1), in: text) else { continue }
            let data = text[encoding].lowercased() == "b" ? Data(base64Encoded: String(text[body])) : try? quotedPrintable(String(text[body]).replacingOccurrences(of: "_", with: " "))
            if let data, let decoded = String(data: data, encoding: text[charset].lowercased() == "utf-8" ? .utf8 : .isoLatin1) { result.replaceSubrange(full, with: decoded) }
        }
        return result
    }
}
