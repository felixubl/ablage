import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

enum Extract {
    static let maxChars = 60_000
    static let textExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "json", "xml", "html", "htm", "tex", "r", "py", "log", "yaml", "yml", "toml", "ini", "sh",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
    static let officeMembers: [String: [String]] = [
        "docx": ["word/document.xml"],
        "xlsx": ["xl/sharedStrings.xml"],
        "pptx": ["ppt/slides/slide*.xml"],
    ]

    struct Result {
        var text: String
        /// True when the file has no text layer and OCR was needed but not allowed in this pass.
        var ocrPending: Bool
        var failure: String? = nil
    }

    static func supports(_ ext: String) -> Bool {
        ext == "pdf" || textExtensions.contains(ext) || imageExtensions.contains(ext) || officeMembers[ext] != nil
    }

    static func text(of url: URL, ext: String, size: Int64, config: Config, allowOCR: Bool) -> Result? {
        let ocrAllowed = config.ocr && Double(size) <= config.ocrMaxMB * 1_048_576
        if ext == "pdf" {
            return pdf(url, pages: config.ocrPages, ocrAllowed: ocrAllowed, allowOCR: allowOCR)
        }
        if textExtensions.contains(ext) {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Result(text: clip(s), ocrPending: false)
        }
        if imageExtensions.contains(ext) {
            guard ocrAllowed else { return Result(text: "", ocrPending: false) }
            // Valid tracking pixels and tiny icons contain no readable document text.
            // Vision rejects these dimensions; treat them as empty instead of unreadable.
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int,
               width <= 2 || height <= 2 { return Result(text: "", ocrPending: false) }
            guard allowOCR else { return Result(text: "", ocrPending: true) }
            let handler = VNImageRequestHandler(url: url, options: [:])
            do { return Result(text: clip(try ocr(handler)), ocrPending: false) }
            catch { return Result(text: "", ocrPending: false, failure: error.localizedDescription) }
        }
        if let members = officeMembers[ext] {
            return Result(text: clip(unzipText(url, members: members)), ocrPending: false)
        }
        return nil
    }

    private static func pdf(_ url: URL, pages: Int, ocrAllowed: Bool, allowOCR: Bool) -> Result? {
        guard let doc = PDFDocument(url: url) else { return Result(text: "", ocrPending: false, failure: "This PDF could not be opened.") }
        guard !doc.isLocked else { return Result(text: "", ocrPending: false, failure: "This PDF is password protected.") }
        var text = ""
        for i in 0..<min(doc.pageCount, 40) {
            if let s = doc.page(at: i)?.string { text += s + "\n" }
            if text.count > maxChars { break }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
            return Result(text: clip(text), ocrPending: false)
        }
        guard ocrAllowed else { return Result(text: text, ocrPending: false) }
        guard allowOCR else { return Result(text: text, ocrPending: true) }
        var recognized = ""
        do {
            for i in 0..<min(doc.pageCount, max(1, pages)) {
                guard let page = doc.page(at: i), let image = render(page) else { throw ConfigError(message: "Could not read page \(i + 1) for text recognition.") }
                recognized += try ocr(VNImageRequestHandler(cgImage: image, options: [:])) + "\n"
            }
        } catch { return Result(text: text, ocrPending: false, failure: error.localizedDescription) }
        return Result(text: clip(recognized), ocrPending: false)
    }

    static func firstPageImage(_ url: URL) -> CGImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        return render(page)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func ocr(_ handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func unzipText(_ url: URL, members: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + members
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8) else { return "" }
        let stripped = xml.replacingOccurrences(of: "</w:p>|</a:p>|</si>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    private static func clip(_ s: String) -> String {
        s.count > maxChars ? String(s.prefix(maxChars)) : s
    }

    static func sources(of url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read == length else { return [] }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String] ?? []
    }

    private static let months: [String: Int] = [
        "jänner": 1, "januar": 1, "jan": 1, "january": 1,
        "februar": 2, "feber": 2, "feb": 2, "february": 2,
        "märz": 3, "mär": 3, "mar": 3, "march": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "jun": 6, "june": 6,
        "juli": 7, "jul": 7, "july": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "oktober": 10, "okt": 10, "oct": 10, "october": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "dez": 12, "dec": 12, "december": 12,
    ]

    private static let monthPattern = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    /// The first plausible date in reading order, the way paperless picks a document's created date.
    static func date(in text: String) -> Date? {
        let sample = String(text.prefix(20_000))
        let range = NSRange(sample.startIndex..., in: sample)
        var found: [(location: Int, year: Int, month: Int, day: Int)] = []

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
            Range(m.range(at: i), in: sample).map { String(sample[$0]) } ?? ""
        }
        func scan(_ pattern: String, _ build: (NSTextCheckingResult) -> (Int, Int, Int)?) {
            guard let re = Patterns.regex(pattern) else { return }
            for m in re.matches(in: sample, range: range) {
                if let (y, mo, d) = build(m) { found.append((m.range.location, y, mo, d)) }
            }
        }

        scan(#"\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b"#) { m in
            (Int(group(m, 3)) ?? 0, Int(group(m, 2)) ?? 0, Int(group(m, 1)) ?? 0)
        }
        scan(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) { m in
            (Int(group(m, 1)) ?? 0, Int(group(m, 2)) ?? 0, Int(group(m, 3)) ?? 0)
        }
        scan(#"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)"#) { m in
            (Int(group(m, 1)) ?? 0, Int(group(m, 2)) ?? 0, Int(group(m, 3)) ?? 0)
        }
        scan(#"\b(\d{1,2})\.?\s*("# + monthPattern + #")\.?\s+(\d{4})\b"#) { m in
            guard let month = months[group(m, 2).lowercased()] else { return nil }
            return (Int(group(m, 3)) ?? 0, month, Int(group(m, 1)) ?? 0)
        }
        scan(#"\b("# + monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#) { m in
            guard let month = months[group(m, 1).lowercased()] else { return nil }
            return (Int(group(m, 3)) ?? 0, month, Int(group(m, 2)) ?? 0)
        }
        scan(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#) { m in
            (Int(group(m, 3)) ?? 0, Int(group(m, 2)) ?? 0, Int(group(m, 1)) ?? 0)
        }

        let calendar = Calendar(identifier: .gregorian)
        let thisYear = calendar.component(.year, from: Date())
        for hit in found.sorted(by: { $0.location < $1.location }) {
            guard (1990...thisYear + 1).contains(hit.year), (1...12).contains(hit.month), (1...31).contains(hit.day) else { continue }
            var components = DateComponents()
            components.year = hit.year
            components.month = hit.month
            components.day = hit.day
            components.hour = 12
            guard let date = calendar.date(from: components), calendar.component(.day, from: date) == hit.day else { continue }
            return date
        }
        return nil
    }
}
