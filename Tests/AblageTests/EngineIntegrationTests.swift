import AppKit
import CoreText
import ImageIO
import XCTest
@testable import Ablage

final class EngineIntegrationTests: XCTestCase {
    func testMultipleInboxesPauseReloadSimulationAndUndo() throws {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("ablage-engine-" + UUID().uuidString)
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        setenv("ABLAGE_DIR", folder.path, 1)
        setenv("ABLAGE_SIMULATE", "0", 1)
        setenv("ABLAGE_PAUSED", "0", 1)
        defer { try? fm.removeItem(at: folder); unsetenv("ABLAGE_SIMULATE"); unsetenv("ABLAGE_PAUSED") }
        let configURL = folder.appendingPathComponent("config.json")
        var root: [String: Any] = [
            "settleSeconds": 0.5, "rescanMinutes": 0, "notifications": false,
            "ocr": false, "searchablePDFs": false, "learning": ["enabled": false], "ignore": ["*.keep"],
            "inboxes": [
                ["path": first.path, "name": "Downloads", "rules": [["name": "First", "match": ["extensions": ["txt"]], "action": ["destination": "Filed"]]]],
                ["path": second.path, "name": "Scans", "enabled": false, "rules": [["name": "Second", "match": ["extensions": ["txt"]], "action": ["destination": "Archive"]]]]
            ],
            "rules": [["name": "Tags", "match": ["extensions": ["md"]], "action": ["tags": ["Filed"]]]]
        ]
        let scanRule: [String: Any] = ["name": "Scanned invoices", "match": ["extensions": ["png", "pdf"], "content": ["invoice"]], "action": ["destination": "Invoices"]]
        let fallback: [String: Any] = ["name": "Scan fallback", "match": ["extensions": ["png", "pdf"]], "action": ["trash": true]]
        var initialInboxes = root["inboxes"] as! [[String: Any]]
        initialInboxes[1]["rules"] = [scanRule, fallback] + (initialInboxes[1]["rules"] as! [[String: Any]])
        root["inboxes"] = initialInboxes
        func save() throws { try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: configURL, options: .atomic) }
        try save()
        let existing = first.appendingPathComponent("existing.txt")
        try Data("old".utf8).write(to: existing)
        let scan = second.appendingPathComponent("scan.png")
        try writeScan(to: scan)
        let scanDigest = Hashing.digest(scan)
        let broken = second.appendingPathComponent("broken.pdf")
        try Data("not a valid PDF".utf8).write(to: broken)
        let snapshots = SnapshotRecorder()
        let engine = Engine()
        engine.onUpdate = { snapshots.set($0) }
        engine.start()
        try waitFor { snapshots.get()?.inboxes.count == 2 }
        XCTAssertTrue(fm.fileExists(atPath: existing.path), "Pre-existing files must wait for review")
        XCTAssertEqual(snapshots.get()?.inboxes.map(\.label), ["Downloads", "Scans"])
        try waitFor { snapshots.get()?.items.first(where: { $0.id == existing.path })?.preview != nil }
        let plan = try XCTUnwrap(snapshots.get()?.items.first(where: { $0.id == existing.path })?.preview)
        XCTAssertEqual(plan.rule, "First")
        XCTAssertEqual(plan.steps.map(\.kind), [.move])
        let plannedTarget = URL(fileURLWithPath: try XCTUnwrap(plan.steps.first?.value))
        XCTAssertEqual(plannedTarget.lastPathComponent, "existing.txt")
        XCTAssertEqual(plannedTarget.deletingLastPathComponent().lastPathComponent, "Filed")
        XCTAssertEqual(plannedTarget.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path, first.resolvingSymlinksInPath().path)
        XCTAssertTrue(fm.fileExists(atPath: existing.path), "Building a plan must leave the source untouched")

        // Enabling OCR invalidates the earlier no-OCR cache. Pausing holds the queue.
        setenv("ABLAGE_PAUSED", "1", 1)
        root["ocr"] = true
        try save()
        try waitFor { snapshots.get()?.items.first(where: { $0.id == scan.path })?.plan.state == .needsOCR }
        setenv("ABLAGE_PAUSED", "0", 1)
        engine.refreshPreviews()
        try waitFor { snapshots.get()?.items.first(where: { $0.id == scan.path })?.plan.rule == "Scanned invoices" }
        XCTAssertEqual(Hashing.digest(scan), scanDigest, "Background OCR must not rewrite, file or trash a scan")
        XCTAssertFalse(snapshots.get()?.journal.contains { $0.from == scan.path } ?? true)
        try waitFor { snapshots.get()?.items.first(where: { $0.id == broken.path })?.plan.state == .textFailed }
        engine.sort(paths: [broken.path])
        try waitFor { snapshots.get()?.journal.contains { FileIdentity.same(URL(fileURLWithPath: $0.from), broken) && $0.kind == .skipped } == true }
        XCTAssertTrue(fm.fileExists(atPath: broken.path), "Failed extraction must block a destructive fallback")

        let arrival = first.appendingPathComponent("new.txt")
        try Data("first arrival".utf8).write(to: arrival)
        let filed = first.appendingPathComponent("Filed/new.txt")
        try waitFor { fm.fileExists(atPath: filed.path) }
        let waiting = second.appendingPathComponent("waiting.txt")
        try Data("second arrival".utf8).write(to: waiting)
        try waitFor { snapshots.get()?.items.contains(where: { $0.id == waiting.path && $0.status == .unsorted }) == true }
        XCTAssertTrue(fm.fileExists(atPath: waiting.path))
        var inboxes = root["inboxes"] as! [[String: Any]]
        inboxes[1]["enabled"] = true
        root["inboxes"] = inboxes
        try save()
        try waitFor { fm.fileExists(atPath: second.appendingPathComponent("Archive/waiting.txt").path) }

        inboxes[1]["reviewFirst"] = true
        root["inboxes"] = inboxes
        try save()
        try waitFor { snapshots.get()?.inboxes.last?.reviewFirst == true }
        let reviewSource = second.appendingPathComponent("review-me.txt")
        try Data("Invoice number: INV-42\nDocument to review.".utf8).write(to: reviewSource)
        try waitFor { snapshots.get()?.items.first(where: { $0.id == reviewSource.path })?.preview != nil }
        XCTAssertTrue(fm.fileExists(atPath: reviewSource.path), "Review-first arrivals must never file automatically")
        let loaded = expectation(description: "Editable review loads")
        var packet: DocumentReviewPacket?
        engine.reviewDocument(path: reviewSource.path) { result in
            if case .success(let value) = result { packet = value }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        let review = try XCTUnwrap(packet)
        var draft = review.draft()
        draft.filename = "approved.txt"
        draft.metadata.invoiceNumber = "INV-42"
        draft.metadata.amount = "42.50"
        let approved = expectation(description: "Edited document approved")
        var approvalError: Error?
        engine.approve(review, draft: draft) { result in
            if case .failure(let error) = result { approvalError = error }
            approved.fulfill()
        }
        wait(for: [approved], timeout: 5)
        XCTAssertNil(approvalError)
        let approvedURL = second.appendingPathComponent("Archive/approved.txt")
        XCTAssertTrue(fm.fileExists(atPath: approvedURL.path))
        XCTAssertEqual(try DocumentLibrary.shared.metadata(for: approvedURL.path)?.amount, "42.50")
        let approvedEntry = try XCTUnwrap(snapshots.get()?.journal.first { $0.from == reviewSource.path && $0.kind == .moved })
        engine.undo(approvedEntry.id)
        try waitFor { snapshots.get()?.journal.first { $0.id == approvedEntry.id }?.undone == true }
        XCTAssertTrue(fm.fileExists(atPath: reviewSource.path))
        XCTAssertNil(try DocumentLibrary.shared.metadata(for: reviewSource.path), "Undo restores the previous metadata as well as the file")

        let stale = expectation(description: "Stale review is rejected")
        try Data("changed since review".utf8).write(to: reviewSource)
        engine.approve(review, draft: draft) { result in
            if case .success = result { XCTFail("A changed document must not be filed using a stale review") }
            stale.fulfill()
        }
        wait(for: [stale], timeout: 5)
        XCTAssertEqual(try String(contentsOf: reviewSource), "changed since review")
        engine.trash(paths: [reviewSource.path], requiring: [reviewSource.path: review.digest, approvedURL.path: review.digest])
        try waitFor { snapshots.get()?.journal.contains { $0.from == reviewSource.path && $0.kind == .error && ($0.message?.contains("compare both copies") ?? false) } == true }
        XCTAssertTrue(fm.fileExists(atPath: reviewSource.path), "Stale duplicate comparisons must never trash the remaining file")

        root["rules"] = [["name": "Invalid", "match": ["filenameRegex": "(["]]]
        try save()
        try waitFor { snapshots.get()?.configError?.contains("invalid filenameRegex") == true }
        let survives = first.appendingPathComponent("last-good.txt")
        try Data("last valid config".utf8).write(to: survives)
        try waitFor { fm.fileExists(atPath: first.appendingPathComponent("Filed/last-good.txt").path) }

        setenv("ABLAGE_SIMULATE", "1", 1)
        engine.trash(path: existing.path)
        try waitFor { snapshots.get()?.journal.contains(where: { $0.from == existing.path && $0.kind == .simulated }) == true }
        XCTAssertTrue(fm.fileExists(atPath: existing.path), "Simulation must never trash a file")
        setenv("ABLAGE_SIMULATE", "0", 1)
        let entry = try XCTUnwrap(snapshots.get()?.journal.first { $0.from == arrival.path && $0.kind == .moved })
        // A collision on restore keeps both files.
        try Data("replacement".utf8).write(to: arrival)
        engine.undo(entry.id)
        try waitFor { snapshots.get()?.journal.first(where: { $0.id == entry.id })?.undone == true }
        XCTAssertEqual(try String(contentsOf: arrival), "replacement")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("new 2.txt")), "first arrival")

        let tagged = first.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: tagged)
        Tags.write(["Original"], to: tagged)
        try waitFor { snapshots.get()?.journal.contains(where: { $0.from == tagged.path && $0.kind == .tagged }) == true }
        XCTAssertEqual(Set(Tags.read(tagged)), ["Original", "Filed"])
        let tagEntry = try XCTUnwrap(snapshots.get()?.journal.first { $0.from == tagged.path && $0.kind == .tagged })
        engine.undo(tagEntry.id)
        try waitFor { snapshots.get()?.journal.first(where: { $0.id == tagEntry.id })?.undone == true }
        XCTAssertEqual(Tags.read(tagged), ["Original"])

        let stopped = expectation(description: "Batch stops without filing remaining files")
        var began = false
        engine.onUpdate = { [weak engine] snapshot in
            if snapshot.progress?.done == 0 { began = true; engine?.cancelCurrentBatch() }
            else if began && snapshot.progress == nil { began = false; stopped.fulfill() }
        }
        engine.sort(paths: [existing.path])
        wait(for: [stopped], timeout: 5)
        XCTAssertTrue(fm.fileExists(atPath: existing.path))
        XCTAssertFalse(fm.fileExists(atPath: first.appendingPathComponent("Filed/existing.txt").path))
    }

    private func writeScan(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
        let font = CTFontCreateWithName("Helvetica" as CFString, 52, nil)
        for (index, value) in ["INVOICE", "September 2026", "Studio subscription", "Total EUR 49.00"].enumerated() {
            let line = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 70, y: 560 - index * 100)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.03)
        }
        XCTFail("Timed out waiting for the engine", file: file, line: line)
        throw ConfigError(message: "Engine expectation timed out")
    }
}

private final class SnapshotRecorder {
    private let lock = NSLock()
    private var snapshot: Snapshot?
    func set(_ snapshot: Snapshot) { lock.lock(); self.snapshot = snapshot; lock.unlock() }
    func get() -> Snapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
}
