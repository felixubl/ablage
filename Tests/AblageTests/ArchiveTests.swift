import XCTest
@testable import Ablage

final class ArchiveTests: XCTestCase {
    private var folder: URL!
    private var library: DocumentLibrary!
    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/private/tmp/ablage-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = DocumentLibrary(url: folder.appendingPathComponent("index.sqlite"))
    }
    override func tearDownWithError() throws { library = nil; try FileManager.default.removeItem(at: folder) }
    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    func testFullTextFieldsFiltersAndSavedViewsPersist() throws {
        let url = try file("bill.txt", "Electricity consumption for September. Amount due forty euros.")
        var metadata = DocumentMetadata(); metadata.correspondent = "Stadtwerke"; metadata.invoiceNumber = "INV-2026-42"
        metadata.documentDate = "2026-09-01"; metadata.amount = "42.50"; metadata.currency = "EUR"
        metadata.fields = [DocumentField(name: "Project", value: "Renovation")]
        try library.saveMetadata(metadata, for: url.path)
        Tags.write(["Household"], to: url)
        try library.index(url, config: Config())
        XCTAssertEqual(try library.search(LibraryQuery(text: "electricity September")).count, 1)
        XCTAssertEqual(try library.search(LibraryQuery(text: "Renovation")).count, 1)
        XCTAssertEqual(try library.search(LibraryQuery(text: "INV-2026-42")).count, 1)
        XCTAssertEqual(try library.search(LibraryQuery(text: #"invoice" OR 1=1"#)).count, 0)
        var query = LibraryQuery(); query.correspondent = "stadt"; query.tag = "house"; query.fromDate = "2026-01-01"; query.toDate = "2026-12-31"
        query.field = "amount"; query.fieldValue = "42.50"
        XCTAssertEqual(try library.search(query).count, 1)
        query.toDate = "2025-12-31"; XCTAssertTrue(try library.search(query).isEmpty)
        let views = [SavedLibraryView(name: "Household", query: query)]
        try library.saveViews(views)
        let reopened = DocumentLibrary(url: folder.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(try reopened.savedViews(), views)
        XCTAssertEqual(try reopened.metadata(for: url.path), metadata)
    }
    func testIndexRefreshPreservesIntegrityBaselineAndOriginal() throws {
        let url = try file("original.txt", "the original")
        let preserved = try OriginalVault.keep(url, in: folder.appendingPathComponent("vault"))
        try library.index(url, config: Config(), original: preserved.path)
        try Data("intentional change".utf8).write(to: url)
        try library.index(url, config: Config())
        var document = try XCTUnwrap(library.document(at: url.path))
        XCTAssertNotEqual(document.digest, document.baseline)
        XCTAssertEqual(IntegrityChecker.check([document]).map(\.kind), [.changed])
        XCTAssertEqual(try String(contentsOf: preserved), "the original")
        try library.index(url, config: Config(), authorizedChange: true)
        document = try XCTUnwrap(library.document(at: url.path))
        XCTAssertTrue(IntegrityChecker.check([document]).isEmpty)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(IntegrityChecker.check([document]).map(\.kind), [.missing])
        try Data("corrupted original".utf8).write(to: preserved)
        XCTAssertEqual(IntegrityChecker.check([document]).map(\.kind), [.missing, .original])
    }
    func testAliasesDoNotBecomeDuplicateFilesAndMetadataSurvivesMoveTrashRestore() throws {
        let source = try file("receipt.txt", "some receipt")
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        try library.index(source, config: Config())
        try library.index(alias.appendingPathComponent(source.lastPathComponent), config: Config())
        XCTAssertEqual(try library.all().count, 1)
        var metadata = DocumentMetadata(); metadata.invoiceNumber = "42"
        try library.saveMetadata(metadata, for: source.path)
        let moved = folder.appendingPathComponent("filed.txt")
        try FileManager.default.moveItem(at: source, to: moved); try library.relocate(from: source.path, to: moved.path)
        XCTAssertEqual(try library.metadata(for: moved.path), metadata)
        XCTAssertNil(try library.metadata(for: source.path))
        let trashed = folder.appendingPathComponent("mock-trash.txt")
        try FileManager.default.moveItem(at: moved, to: trashed); try library.retire(moved.path, trash: trashed.path)
        XCTAssertTrue(try library.all().isEmpty)
        try FileManager.default.moveItem(at: trashed, to: source); try library.relocate(from: trashed.path, to: source.path)
        XCTAssertEqual(try library.all().count, 1)
        XCTAssertEqual(try library.metadata(for: source.path), metadata)
    }
    func testDuplicateComparisonSeparatesExactCopiesFromSimilarDocuments() throws {
        let text = (1...70).map { "service\($0) product\($0) quantity\($0)" }.joined(separator: " ")
        let first = try file("one.txt", text)
        let exact = try file("renamed.txt", text)
        let similar = try file("another-invoice.txt", text + " different invoice 2026 123 EUR 50")
        let unrelated = try file("other.txt", "a totally unrelated document")
        for url in [first, exact, similar, unrelated] { try library.index(url, config: Config()) }
        let pairs = DuplicateFinder.find(try library.all())
        XCTAssertEqual(pairs.filter(\.exact).count, 1)
        XCTAssertTrue(pairs.contains { !$0.exact && $0.similarity > 0.86 })
        XCTAssertFalse(pairs.contains { $0.first.name == "other.txt" || $0.second.name == "other.txt" })
    }
    func testMetadataValidationAndFieldTemplates() throws {
        var metadata = DocumentMetadata(); metadata.amount = "42.50"; metadata.currency = "EUR"; metadata.invoiceNumber = "INV-42"
        metadata.documentDate = "2026-09-20"; metadata.dueDate = "2026-10-20"; metadata.fields = [DocumentField(name: "Project", value: "House")]
        try metadata.validate()
        let source = try file("receipt.txt", "invoice")
        let rule = try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"Invoice","action":{"destination":"Invoices/{year}","rename":"{date}_{invoice_number}_{amount}_{currency}_{field.project}"}}"#.utf8))
        let context = FileContext(facts: try XCTUnwrap(FileFacts(url: source)), metadata: metadata) { nil }
        XCTAssertEqual(rule.targetURL(for: context.facts, context: rule.templateContext(for: context, enrichment: nil), inbox: folder).lastPathComponent, "2026-09-20_INV-42_42.50_EUR_House.txt")
        var template = rule.templateContext(for: context, enrichment: nil)
        template.fields["amount"] = "-42.50"
        template.fields["field.project"] = "../{amount}"
        XCTAssertEqual(Template.expand("{amount}_{field.project}", template), "-42.50_..-{amount}")
        template.correspondent = ".."
        XCTAssertEqual(Template.expand("Invoices/{correspondent}/{year}", template), "Invoices/_/2026")
        metadata.documentDate = "2026-02-30"; XCTAssertThrowsError(try metadata.validate())
        metadata.documentDate = ""; metadata.amount = "42.50 extra"; XCTAssertThrowsError(try metadata.validate())
        metadata.amount = ""; metadata.fields.append(DocumentField(name: "Project", value: "Duplicate")); XCTAssertThrowsError(try metadata.validate())
    }
    func testQueuedIndexDoesNotAcceptChangesAfterFiling() throws {
        let url = try file("filed.txt", "bytes approved when filed")
        let filedDigest = try XCTUnwrap(Hashing.digest(url)?.hex)
        try Data("edited after filing, before background indexing".utf8).write(to: url)
        try library.index(url, config: Config(), filedDigest: filedDigest)
        let document = try XCTUnwrap(library.document(at: url.path))
        XCTAssertEqual(document.baseline, filedDigest)
        XCTAssertEqual(IntegrityChecker.check([document]).map(\.kind), [.changed])
    }
}
