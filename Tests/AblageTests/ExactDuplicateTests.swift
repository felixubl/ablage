import XCTest
@testable import Ablage

final class ExactDuplicateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ablage-exact-" + UUID().uuidString).standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }
    @discardableResult
    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func testGroupsIdenticalBytesAcrossNamesExtensionsAndFoldersWithoutAnIndex() throws {
        try file("cv.pdf", "same file bytes")
        try file("renamed.bin", "same file bytes")
        try file("nested/cv-1.pdf", "same file bytes")
        try file("cv-updated.pdf", "same file byteS") // Same size, different contents.
        try file("other.zip", "unrelated and different size")
        let report = ExactDuplicateScanner.scan(folders: [root])
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.files, 5)
        XCTAssertEqual(report.compared, 4)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.files.count, 3)
        XCTAssertEqual(report.extraCount, 2)
        XCTAssertEqual(report.extraBytes, 30)
        XCTAssertEqual(report.groups.first?.digest, Hashing.digest(root.appendingPathComponent("cv.pdf"))?.hex)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("nested/cv-1.pdf").path))
        let shallow = ExactDuplicateScanner.scan(folders: [root], recursive: false)
        XCTAssertEqual(shallow.groups.first?.files.count, 2)
    }
    func testOverlappingRootsLinksHiddenFilesPackagesAndEmptyFilesDoNotInflateResults() throws {
        let first = try file("a.dat", "same")
        try file("nested/b.dat", "same")
        try file(".hidden.dat", "same")
        try file("empty.txt", "")
        try file("another-empty.txt", "")
        try file("Ignored.app/Contents/payload.dat", "same")
        try fm.linkItem(at: first, to: root.appendingPathComponent("hard-link.dat"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("file-link.dat"), withDestinationURL: first)
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let report = ExactDuplicateScanner.scan(folders: [root, root.appendingPathComponent("nested"), root])
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.files.count, 2)
        XCTAssertEqual(report.linkedFiles, 1)
        XCTAssertEqual(report.files, 2)
    }
    func testCancellationAndUnavailableRootsAreReportedWithoutFalseCleanResults() throws {
        try file("one", "identical"); try file("two", "identical")
        let token = WorkCancellation(); token.cancel()
        let cancelled = ExactDuplicateScanner.scan(folders: [root], cancellation: token)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.groups.isEmpty)
        let unavailable = ExactDuplicateScanner.scan(folders: [root.appendingPathComponent("missing")])
        XCTAssertEqual(unavailable.issues.count, 1)
        XCTAssertTrue(unavailable.groups.isEmpty)
    }
    func testRemovalMustKeepADistinctUnchangedFileAndRejectsReplacedPaths() throws {
        let first = try file("one", "identical"); let second = try file("two", "identical")
        let group = try XCTUnwrap(ExactDuplicateScanner.scan(folders: [root]).groups.first)
        XCTAssertThrowsError(try DuplicateRemoval(group: group, keeping: first.path, removing: [first.path, second.path]))
        XCTAssertThrowsError(try DuplicateRemoval(group: group, keeping: first.path, removing: [root.appendingPathComponent("unknown").path]))
        let request = try DuplicateRemoval(group: group, keeping: first.path, removing: [second.path])
        XCTAssertNoThrow(try request.validate())
        try Data("different".utf8).write(to: first)
        XCTAssertThrowsError(try request.validate())
        try Data("identical".utf8).write(to: first)
        let newGroup = try XCTUnwrap(ExactDuplicateScanner.scan(folders: [root]).groups.first)
        let newRequest = try DuplicateRemoval(group: newGroup, keeping: first.path, removing: [second.path])
        try fm.removeItem(at: second)
        try fm.createSymbolicLink(at: second, withDestinationURL: first)
        XCTAssertThrowsError(try newRequest.validate())
        XCTAssertEqual(try String(contentsOf: first), "identical")
    }
    func testDigestStopsDuringLargeFileAndRejectsEditsAfterScan() throws {
        let url = try file("payload", String(repeating: "a", count: 2_000_000))
        let snapshot = try DuplicateFile.read(url)
        let token = WorkCancellation(); token.cancel()
        XCTAssertThrowsError(try ExactDuplicateScanner.digest(snapshot, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        try Data("replacement".utf8).write(to: url)
        XCTAssertThrowsError(try ExactDuplicateScanner.digest(snapshot))
    }

    func testEnginePreviewTrashSeveralCopiesUndoAndChangedKeeper() throws {
        let oldDirectory = ProcessInfo.processInfo.environment["ABLAGE_DIR"]
        let oldSimulation = ProcessInfo.processInfo.environment["ABLAGE_SIMULATE"]
        setenv("ABLAGE_DIR", root.appendingPathComponent("support").path, 1)
        setenv("ABLAGE_SIMULATE", "1", 1)
        defer {
            if let oldDirectory { setenv("ABLAGE_DIR", oldDirectory, 1) } else { unsetenv("ABLAGE_DIR") }
            if let oldSimulation { setenv("ABLAGE_SIMULATE", oldSimulation, 1) } else { unsetenv("ABLAGE_SIMULATE") }
        }
        let keeper = try file("contents/keep.bin", "identical data")
        let other = try file("contents/extra.bin", "identical data")
        let third = try file("contents/third.bin", "identical data")
        let group = try XCTUnwrap(ExactDuplicateScanner.scan(folders: [root.appendingPathComponent("contents")]).groups.first)
        let request = try DuplicateRemoval(group: group, keeping: keeper.path, removing: [other.path, third.path])
        let engine = Engine(), recorder = DuplicateJournalRecorder()
        engine.onUpdate = { recorder.set($0.journal) }
        let preview = expectation(description: "Preview leaves all copies")
        engine.trashDuplicates(request) { result in
            XCTAssertNil(result.error); XCTAssertEqual(result.previewed, 2); XCTAssertTrue(result.removedPaths.isEmpty)
            preview.fulfill()
        }
        wait(for: [preview], timeout: 5)
        XCTAssertTrue(fm.fileExists(atPath: other.path)); XCTAssertTrue(fm.fileExists(atPath: third.path))
        setenv("ABLAGE_SIMULATE", "0", 1)
        let removal = expectation(description: "Both extra copies go to Trash")
        engine.trashDuplicates(request) { result in
            XCTAssertNil(result.error); XCTAssertEqual(Set(result.removedPaths), Set(request.copies.map(\.path))); removal.fulfill()
        }
        wait(for: [removal], timeout: 5)
        XCTAssertTrue(fm.fileExists(atPath: keeper.path))
        XCTAssertFalse(fm.fileExists(atPath: other.path)); XCTAssertFalse(fm.fileExists(atPath: third.path))
        let entries = recorder.get().filter { $0.rule == "Duplicate finder" && $0.kind == .trashed }
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            engine.undo(entry.id)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, recorder.get().first(where: { $0.id == entry.id })?.undone != true { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertEqual(recorder.get().first(where: { $0.id == entry.id })?.undone, true)
        }
        XCTAssertEqual(try Data(contentsOf: other), try Data(contentsOf: keeper))
        XCTAssertEqual(try Data(contentsOf: third), try Data(contentsOf: keeper))
        let fresh = try XCTUnwrap(ExactDuplicateScanner.scan(folders: [root.appendingPathComponent("contents")]).groups.first)
        let staleRequest = try DuplicateRemoval(group: fresh, keeping: keeper.path, removing: [other.path, third.path])
        try Data("keep this edit".utf8).write(to: keeper)
        let rejected = expectation(description: "Changed keeper protects remaining copies")
        engine.trashDuplicates(staleRequest) { result in
            XCTAssertNotNil(result.error); XCTAssertTrue(result.removedPaths.isEmpty); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(fm.fileExists(atPath: other.path)); XCTAssertTrue(fm.fileExists(atPath: third.path))
    }
}

private final class DuplicateJournalRecorder {
    private let lock = NSLock()
    private var entries: [JournalEntry] = []
    func set(_ entries: [JournalEntry]) { lock.lock(); self.entries = entries; lock.unlock() }
    func get() -> [JournalEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}
