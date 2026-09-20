import CoreGraphics
import PDFKit
import XCTest
@testable import Ablage

final class ScanSplitterTests: XCTestCase {
    func testSplitPreservesOriginalPageOrderAndExistingFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ablage-split-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan.pdf")
        try Self.pdf(pages: 5).write(to: source)
        let hash = try XCTUnwrap(Hashing.digest(source)?.hex)
        let collision = root.appendingPathComponent("Result — 01.pdf")
        try Data("keep me".utf8).write(to: collision)
        let groups = ScanSplitter.groups(pageCount: 5, starts: [0,3], excluded: [2])
        XCTAssertEqual(groups, [[0,1],[3,4]])
        let created = try ScanSplitter.split(source: source, expectedDigest: hash, groups: groups, folder: root, prefix: "Result")
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(PDFDocument(url: created[0])?.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: created[1])?.page(at: 0)?.bounds(for: .mediaBox).width, 303)
        XCTAssertEqual(Hashing.digest(source)?.hex, hash)
        XCTAssertEqual(try String(contentsOf: collision), "keep me")
        XCTAssertThrowsError(try ScanSplitter.split(source: source, expectedDigest: "stale", groups: groups, folder: root, prefix: "Invalid"))
        XCTAssertThrowsError(try ScanSplitter.split(source: source, expectedDigest: hash, groups: [[0,1],[1,2]], folder: root, prefix: "Invalid"))
    }
    func testGeneratedSeparatorCanBeRecognized() throws {
        let source = URL(fileURLWithPath: "/private/tmp/ablage-qr-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try ScanSplitter.separatorPDF(payload: "ABLAGE:SPLIT").write(to: source)
        XCTAssertEqual(try ScanSplitter.separators(in: source, payload: "ABLAGE:SPLIT", cancellation: WorkCancellation()), [0])
    }
    static func pdf(pages: Int) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: output)!, mediaBox: &box, nil)!
        for index in 0..<pages {
            var rect = CGRect(x: 0, y: 0, width: 300 + index, height: 400)
            context.beginPage(mediaBox: &rect); context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 30, y: 30, width: 50, height: 50)); context.endPage()
        }
        context.closePDF(); return output as Data
    }
}
