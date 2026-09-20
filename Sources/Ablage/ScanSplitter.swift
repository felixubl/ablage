import AppKit
import CoreImage
import CoreText
import PDFKit
import Vision

struct SplitFailure: LocalizedError {
    var message: String
    var created: [URL] = []
    var errorDescription: String? { message }
}

enum ScanSplitter {
    static func groups(pageCount: Int, starts: Set<Int>, excluded: Set<Int>) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = []
        for page in 0..<max(0, pageCount) {
            if starts.contains(page), !current.isEmpty { groups.append(current); current = [] }
            if !excluded.contains(page) { current.append(page) }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    static func split(source: URL, expectedDigest: String, groups: [[Int]], folder: URL, prefix: String) throws -> [URL] {
        guard Hashing.digest(source)?.hex == expectedDigest else { throw ConfigError(message: "The scan changed. Reopen it before splitting.") }
        guard let document = PDFDocument(url: source), !document.isLocked else { throw ConfigError(message: "This PDF is unreadable or password protected.") }
        let pages = groups.flatMap { $0 }
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }), Set(pages).count == pages.count, pages.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            throw ConfigError(message: "Choose valid, non-overlapping page groups.")
        }
        let fm = FileManager.default
        let work = folder.appendingPathComponent(".ablage-split-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var staged: [URL] = []
        for (index, group) in groups.enumerated() {
            let result = PDFDocument()
            for number in group {
                guard let page = document.page(at: number)?.copy() as? PDFPage else { throw ConfigError(message: "Could not copy page \(number + 1).") }
                result.insert(page, at: result.pageCount)
            }
            let target = work.appendingPathComponent(Template.filename(prefix) + String(format: " — %02d.pdf", index + 1))
            guard result.write(to: target), PDFDocument(url: target)?.pageCount == group.count else { throw ConfigError(message: "Could not write one of the split documents.") }
            staged.append(target)
        }
        guard Hashing.digest(source)?.hex == expectedDigest else { throw ConfigError(message: "The original changed while preparing the split. No output files were delivered.") }
        var created: [URL] = []
        do {
            for staged in staged {
                var target = folder.appendingPathComponent(staged.lastPathComponent)
                if fm.fileExists(atPath: target.path) { target = Hashing.unique(target) }
                try fm.moveItem(at: staged, to: target)
                created.append(target)
            }
            return created
        } catch {
            throw SplitFailure(message: "\(created.count) documents were created before an error: \(error.localizedDescription). The original scan is unchanged.", created: created)
        }
    }

    static func separators(in source: URL, payload: String, cancellation: WorkCancellation) throws -> Set<Int> {
        guard !payload.isEmpty, let document = PDFDocument(url: source), !document.isLocked else { throw ConfigError(message: "Choose a readable PDF and separator text.") }
        var pages = Set<Int>()
        for index in 0..<document.pageCount {
            if cancellation.isCancelled { throw ConfigError(message: "Separator detection stopped.") }
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            if request.results?.contains(where: { $0.payloadStringValue == payload }) == true { pages.insert(index) }
        }
        return pages
    }

    static func separatorPDF(payload: String) throws -> Data {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw ConfigError(message: "QR generation is unavailable.") }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = filter.outputImage, let image = CIContext().createCGImage(qr, from: qr.extent) else { throw ConfigError(message: "Could not create the separator.") }
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConfigError(message: "Could not create the separator PDF.") }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 148, y: 270, width: 300, height: 300))
        func line(_ text: String, y: CGFloat, size: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: (595 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: y)
            CTLineDraw(line, context)
        }
        line("Ablage · New document", y: 640, size: 26)
        line("Place this sheet between documents before scanning.", y: 610, size: 14)
        line(payload, y: 225, size: 13)
        line("This separator sheet is omitted from the split copies.", y: 190, size: 12)
        context.endPDFPage(); context.closePDF()
        return output as Data
    }
}
