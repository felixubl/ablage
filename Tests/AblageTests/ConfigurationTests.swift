import XCTest
@testable import Ablage

final class ConfigurationTests: XCTestCase {
    func testFirstRunStartsWithReviewAndNoServicesOrDestructiveRules() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        try ConfigStore.ensureDefault(at: url)
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        XCTAssertTrue(ConfigStore.problems(in: config).isEmpty)
        XCTAssertEqual(config.resolvedInboxes.map(\.path), ["~/Downloads"])
        XCTAssertTrue(config.resolvedInboxes.allSatisfy { $0.reviewFirst == true })
        XCTAssertFalse(config.sortExistingOnRescan)
        XCTAssertTrue(config.ai.models.isEmpty)
        XCTAssertTrue(config.mailAccounts.isEmpty)
        let rules = config.rules + config.resolvedInboxes.flatMap { $0.rules ?? [] }
        XCTAssertTrue(rules.filter(\.isEnabled).allSatisfy { $0.action.trash != true && $0.action.run == nil && $0.action.ai == nil && $0.match.ai == nil })
        let custom = Data(#"{"inbox":"~/Custom inbox","rules":[]}"#.utf8)
        try custom.write(to: url)
        try ConfigStore.ensureDefault(at: url)
        XCTAssertEqual(try Data(contentsOf: url), custom, "New defaults must preserve an existing setup")
    }

    func testPublishedExamplesAreValidAndStarterMatchesFirstRun() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let examples = root.appendingPathComponent("examples")
        for url in try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(Config.self, from: data)
            XCTAssertTrue(ConfigStore.problems(in: config).isEmpty, url.lastPathComponent)
            XCTAssertTrue(config.resolvedInboxes.allSatisfy { $0.reviewFirst == true }, "Examples must start with review: " + url.lastPathComponent)
        }
        let example = try JSONSerialization.jsonObject(with: Data(contentsOf: examples.appendingPathComponent("starter-config.json"))) as? NSDictionary
        let bundled = try JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8)) as? NSDictionary
        XCTAssertEqual(try XCTUnwrap(example), try XCTUnwrap(bundled))
    }

    func testMigratingSingleInboxPreservesGlobalAndUnknownSettings() throws {
        var document = try ConfigDocument(data: Data(#"{"inbox":"~/Downloads","ignore":["*.keep"],"custom":{"value":42},"rules":[]}"#.utf8))
        document.inboxes.append(["path": "~/Desktop", "name": "Screenshots", "enabled": false])
        let data = try document.encoded()
        let config = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(config.resolvedInboxes.count, 2)
        XCTAssertEqual(config.resolvedInboxes[0].path, "~/Downloads")
        XCTAssertEqual(config.resolvedInboxes[1].name, "Screenshots")
        XCTAssertEqual(config.resolvedInboxes[1].enabled, false)
        XCTAssertEqual(config.ignore, ["*.keep"])
        XCTAssertEqual((document.root["custom"] as? [String: Int])?["value"], 42)
        XCTAssertNil(document.root["inbox"])
    }

    func testLocalRulesAreIndependentOfSharedRules() throws {
        var document = try ConfigDocument(data: Data(#"{"inboxes":[{"path":"~/Downloads"},{"path":"~/Desktop"}],"rules":[{"name":"Shared"}]}"#.utf8))
        document.setRules([["name": "Local", "match": ["extensions": ["pdf"]]]], in: 1)
        XCTAssertEqual(document.rules(in: nil).first?["name"] as? String, "Shared")
        XCTAssertEqual(document.rules(in: 0).count, 0)
        XCTAssertEqual(document.rules(in: 1).first?["name"] as? String, "Local")
    }

    func testSaveCreatesBackupAndRejectsExternalChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        let original = Data(#"{"inbox":"~/Downloads","rules":[]}"#.utf8)
        try original.write(to: url)
        var document = try ConfigDocument(data: original)
        document.root["notifications"] = false
        try document.save(to: url)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("config.previous.json")), original)
        let external = Data(#"{"inbox":"~/Desktop","rules":[]}"#.utf8)
        try external.write(to: url)
        document.root["ocr"] = false
        XCTAssertThrowsError(try document.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testInvalidRulesAndDuplicateInboxesCannotBeSaved() throws {
        for json in [
            #"{"inboxes":[{"path":"~/Downloads"},{"path":"~/Downloads/../Downloads"}]}"#,
            #"{"rules":[{"name":"Broken","match":{"filenameRegex":"(["}}]}"#,
            #"{"settleSeconds":-1}"#,
            #"{"inbox":"relative/path"}"#
        ] {
            let document = try ConfigDocument(data: Data(json.utf8))
            XCTAssertThrowsError(try document.encoded(), json)
        }
    }

    func testRuleFormRoundTripsAdvancedFields() throws {
        let json = #"{"name":"Invoice","enabled":false,"match":{"extensions":["pdf"],"contentAll":["paid","invoice"],"minAgeDays":7,"ai":{"model":"local","description":"Invoices"}},"action":{"destination":"~/Invoices","dateFrom":"filename","run":"echo done","correspondent":"Test","ai":"local"},"custom":123}"#
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var draft = RuleDraft(dictionary: raw)
        draft.name = "Renamed"
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(draft.json.utf8)) as? [String: Any])
        XCTAssertEqual(saved["name"] as? String, "Renamed")
        XCTAssertEqual(saved["enabled"] as? Bool, false)
        XCTAssertEqual(saved["custom"] as? Int, 123)
        let action = try XCTUnwrap(saved["action"] as? [String: Any])
        XCTAssertEqual(action["run"] as? String, "echo done")
        XCTAssertEqual(action["dateFrom"] as? String, "filename")
        XCTAssertEqual(action["ai"] as? String, "local")
        let match = try XCTUnwrap(saved["match"] as? [String: Any])
        XCTAssertEqual(match["contentAll"] as? [String], ["paid", "invoice"])
        XCTAssertNotNil(match["ai"])
    }

    func testUndoRequiresActualTrashLocationAndSupportsTags() throws {
        XCTAssertFalse(JournalEntry(rule: "old", kind: .trashed, from: "/inbox/file.pdf").canUndo)
        XCTAssertTrue(JournalEntry(rule: "new", kind: .trashed, from: "/inbox/file.pdf", trashPath: "/trash/file 2.pdf").canUndo)
        XCTAssertTrue(JournalEntry(rule: "tags", kind: .tagged, from: "/inbox/file.pdf", previousTags: ["Existing"]).canUndo)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","date":0,"rule":"old","kind":"moved","from":"/a","to":"/b","previousTags":[],"undone":false}"#
        XCTAssertTrue(try JSONDecoder().decode(JournalEntry.self, from: Data(old.utf8)).canUndo)
    }

    func testFailedReadsAreNeverConsideredDuplicates() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(Hashing.identical(base, base.appendingPathExtension("missing")))
        try Data("one".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertTrue(Hashing.identical(base, base))
        let other = base.appendingPathExtension("other")
        try Data("two".utf8).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertFalse(Hashing.identical(base, other))
    }
}
