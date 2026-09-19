import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// Gives a scanned PDF an invisible text layer, so Spotlight, Preview and Ablage's own rules
/// can read it. The page images are re-embedded untouched; only text is added on top.
enum SearchablePDF {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func hasTextLayer(_ url: URL) -> Bool {
        guard let doc = PDFDocument(url: url) else { return true }
        var text = ""
        for i in 0..<min(doc.pageCount, 3) {
            text += doc.page(at: i)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 { return true }
        }
        return false
    }

    static func pageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    /// Rewrites the file in place. Returns the number of pages that received text.
    @discardableResult
    static func addTextLayer(to url: URL, maxPages: Int) throws -> Int {
        guard let source = CGPDFDocument(url as CFURL), source.numberOfPages > 0 else { throw Failure(message: "not a readable PDF") }
        guard source.numberOfPages <= maxPages else { throw Failure(message: "\(source.numberOfPages) pages, limit is \(maxPages)") }
        guard let kitDocument = PDFDocument(url: url) else { throw Failure(message: "PDFKit could not open the file") }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ablage-\(UUID().uuidString).pdf")
        var firstBox = source.page(at: 1)?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(temporary as CFURL, mediaBox: &firstBox, nil) else { throw Failure(message: "could not create the output PDF") }
        var pagesWithText = 0

        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let rotated = page.rotationAngle % 180 != 0
            var displayBox = CGRect(x: 0, y: 0, width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
            context.beginPage(mediaBox: &displayBox)
            context.saveGState()
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: displayBox, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()

            if let kitPage = kitDocument.page(at: index - 1), let image = render(kitPage, target: displayBox.size) {
                let lines = recognise(image)
                if !lines.isEmpty {
                    draw(lines, in: displayBox, on: context)
                    pagesWithText += 1
                }
            }
            context.endPage()
        }
        context.closePDF()

        guard pagesWithText > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure(message: "no text recognised")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return pagesWithText
    }

    private static func render(_ page: PDFPage, target: CGSize) -> CGImage? {
        let scale: CGFloat = 2.5
        let image = page.thumbnail(of: CGSize(width: target.width * scale, height: target.height * scale), for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func recognise(_ image: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.write("text layer: recognition failed: \(error.localizedDescription)")
            return []
        }
        return request.results ?? []
    }

    /// Each recognised line becomes invisible text stretched over its bounding box, the way ocrmypdf does it.
    private static func draw(_ lines: [VNRecognizedTextObservation], in box: CGRect, on context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for observation in lines {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let rect = CGRect(
                x: box.minX + observation.boundingBox.minX * box.width,
                y: box.minY + observation.boundingBox.minY * box.height,
                width: observation.boundingBox.width * box.width,
                height: observation.boundingBox.height * box.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let fontSize = rect.height * 0.85
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: candidate.string, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            guard width > 0 else { continue }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rect.minX, y: rect.minY + descent)
            context.scaleBy(x: rect.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// Copies of files before Ablage changed their bytes, so Undo can put the original back.
enum Originals {
    static let directory = Paths.supportDirectory.appendingPathComponent("originals", isDirectory: true)

    static func keep(_ url: URL, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("\(id.uuidString).\(url.pathExtension)")
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: url, to: copy)
    }

    @discardableResult
    static func restore(for id: UUID, to url: URL) -> Bool {
        let copy = directory.appendingPathComponent("\(id.uuidString).\(url.pathExtension)")
        guard FileManager.default.fileExists(atPath: copy.path) else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: copy)
            return true
        } catch {
            Log.write("originals: could not restore \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    static func purge(olderThanDays days: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
