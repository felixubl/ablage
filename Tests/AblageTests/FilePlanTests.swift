import XCTest
@testable import Ablage

final class FilePlanTests: XCTestCase {
    private var inbox: URL!
    private var source: URL!
    private var file: FileContext!

    override func setUpWithError() throws {
        inbox = URL(fileURLWithPath: "/private/tmp/ablage-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        source = inbox.appendingPathComponent("Invoice_2026-09-20.PDF")
        try Data("original".utf8).write(to: source)
        file = FileContext(facts: try XCTUnwrap(FileFacts(url: source))) { "Invoice dated 2026-09-20" }
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: inbox) }

    private func rule(_ json: String) throws -> Rule { try JSONDecoder().decode(Rule.self, from: Data(json.utf8)) }
    private func plan(_ rule: Rule, config: Config = Config()) -> FilePlan {
        FilePlan.forRule(rule, file: file, inbox: inbox, config: config)
    }

    func testMoveRenameTagsAndHookAreExplicitAndReadOnly() throws {
        let rule = try rule(#"{"name":"Rechnungen","action":{"destination":"Filed/{year}","rename":"{date}_{correspondent}","dateFrom":"filename","correspondent":"Acme","tags":["Invoice"],"run":"touch should-not-exist"}}"#)
        let result = plan(rule)
        XCTAssertEqual(result.steps.map(\.kind), [.move, .rename, .tags, .run])
        XCTAssertEqual(result.steps[0].value, inbox.appendingPathComponent("Filed/2026/2026-09-20_Acme.PDF").path)
        XCTAssertEqual(result.steps[1].value, "2026-09-20_Acme.PDF")
        XCTAssertEqual(result.steps[2].value, "Invoice")
        XCTAssertEqual(result.rule, "Rechnungen")
        XCTAssertTrue(result.summary.hasPrefix("Move to "))
        XCTAssertTrue(result.hasAction)
        XCTAssertEqual(try String(contentsOf: source), "original")
        XCTAssertTrue(Tags.read(source).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [source.lastPathComponent])
    }

    func testTrashTakesPrecedenceOverMoveRenameAndTags() throws {
        let result = plan(try rule(#"{"name":"Old installers","action":{"trash":true,"destination":"Ignored","rename":"Ignored","tags":["Ignored"],"run":"echo filed"}}"#))
        XCTAssertEqual(result.steps.map(\.kind), [.trash, .run])
        XCTAssertEqual(result.summary, "Move to Trash")
        XCTAssertTrue(result.isDestructive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUnchangedAndExistingTagsAreNotPresentedAsActions() throws {
        let noAction = plan(try rule(#"{"name":"Keep"}"#))
        XCTAssertFalse(noAction.hasAction)
        XCTAssertEqual(noAction.steps.first?.kind, .keep)
        XCTAssertTrue(Tags.write(["Invoice"], to: source))
        let alreadyTagged = plan(try rule(#"{"name":"Tag","action":{"tags":["Invoice"],"run":"echo only after tagging"}}"#))
        XCTAssertFalse(alreadyTagged.hasAction)
        XCTAssertEqual(alreadyTagged.steps.map(\.kind), [.keep])
        let newTag = plan(try rule(#"{"name":"Tag","action":{"tags":["Invoice","Business"]}}"#))
        XCTAssertEqual(newTag.steps, [.init(kind: .tags, value: "Business")])
    }

    func testCollisionExplainsBothOutcomesWithoutTouchingEitherFile() throws {
        let target = inbox.appendingPathComponent("Filed/" + source.lastPathComponent)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: target)
        let result = plan(try rule(#"{"name":"File","action":{"destination":"Filed"}}"#))
        XCTAssertEqual(result.steps.first?.kind, .collision)
        XCTAssertTrue(result.fullDescription.contains("identical copy would go to Trash"))
        XCTAssertTrue(result.fullDescription.contains("Invoice_2026-09-20 2.PDF"))
        XCTAssertEqual(try String(contentsOf: source), "original")
        XCTAssertEqual(try String(contentsOf: target), "other")
    }

    func testUnresolvedModelFieldsStayVisible() throws {
        var config = Config()
        config.ai.models["local"] = AIModel(provider: "apple")
        let result = plan(try rule(#"{"name":"Invoices","action":{"destination":"Filed/{year}/{correspondent}","rename":"{date}_{title}","ai":"local"}}"#), config: config)
        XCTAssertEqual(result.steps[0].value, inbox.appendingPathComponent("Filed/{year}/{correspondent}/{date}_{title}.PDF").path)
        XCTAssertTrue(result.notes.joined().contains("not known yet"))
    }

    func testPendingOCRPreventsAnIncorrectFallbackPlan() throws {
        let scanned = FileContext(facts: file.facts) { "" }
        let rules = try [rule(#"{"name":"Invoice","match":{"content":["Invoice"]},"action":{"destination":"Invoices"}}"#), rule(#"{"name":"Fallback","action":{"trash":true}}"#)]
        let result = FilePlan.evaluate(rules: rules, file: scanned, inbox: inbox, config: Config(), ocrPending: { true }, learned: { nil })
        XCTAssertEqual(result.state, .needsOCR)
        XCTAssertTrue(result.steps.isEmpty)
        let resolved = FilePlan.evaluate(rules: rules, file: file, inbox: inbox, config: Config(), ocrPending: { false }, learned: { nil })
        XCTAssertEqual(resolved.rule, "Invoice")
    }

    func testTextFailureBlocksTheFallbackAndExplainsHowToRecover() throws {
        let scanned = FileContext(facts: file.facts) { "" }
        let rules = [try rule(#"{"name":"Invoices","match":{"content":["Invoice"]},"action":{"destination":"Filed"}}"#), try rule(#"{"name":"Fallback","action":{"trash":true}}"#)]
        let plan = FilePlan.evaluate(rules: rules, file: scanned, inbox: inbox, config: Config(), ocrPending: { false }, textFailure: { "This PDF is password protected." }, learned: { nil })
        XCTAssertEqual(plan.state, .textFailed)
        XCTAssertFalse(plan.hasAction)
        XCTAssertTrue(plan.fullDescription.contains("password protected"))
        XCTAssertTrue(plan.fullDescription.contains("retry"))
    }

    func testNoMatchAndManualModelAreExplicit() throws {
        let result = FilePlan.evaluate(rules: [], file: file, inbox: inbox, config: Config(), ocrPending: { false }, learned: { nil })
        XCTAssertEqual(result, .noMatch)
        XCTAssertFalse(result.summary.isEmpty)
        var config = Config()
        config.ai.models["remote"] = AIModel(provider: "openai", endpoint: "https://example.com")
        let rules = try [rule(#"{"name":"Invoices","match":{"ai":{"model":"remote","description":"An invoice"}},"action":{"destination":"Invoices"}}"#)]
        let manual = FilePlan.evaluate(rules: rules, file: file, inbox: inbox, config: config, ocrPending: { false }, learned: { nil })
        XCTAssertEqual(manual.state, .manualModel)
        XCTAssertFalse(manual.hasAction)
        config.ai.models["remote"]?.automatic = true
        let automatic = FilePlan.evaluate(rules: rules, file: file, inbox: inbox, config: config, ocrPending: { false }, learned: { nil })
        XCTAssertEqual(automatic.state, .model)
        XCTAssertTrue(automatic.hasAction)
        XCTAssertTrue(automatic.steps.isEmpty, "A preview cannot invent a model's decision")
    }

    func testDisabledRulesAndLearnedExplanations() throws {
        let rules = try [rule(#"{"name":"Disabled","enabled":false,"action":{"trash":true}}"#), rule(#"{"name":"Invoices","match":{"filename":["does-not-match"]},"action":{"destination":"Invoices"}}"#)]
        let suggestion = Suggestion(rule: "Invoices", confidence: 0.9, similarity: 0.8, like: "Previous invoice.pdf")
        let result = FilePlan.evaluate(rules: rules, file: file, inbox: inbox, config: Config(), ocrPending: { false }, learned: { suggestion })
        XCTAssertEqual(result.rule, "Invoices")
        XCTAssertEqual(result.steps.first?.kind, .move)
        XCTAssertTrue(result.explanation.contains("Previous invoice.pdf"))
        XCTAssertTrue(result.explanation.contains("80%"))
    }
}
