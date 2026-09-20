import XCTest
@testable import Ablage

final class ModelSettingsTests: XCTestCase {
    func testExternalModelsRequireOptInIncludingLANHosts() {
        for endpoint in ["https://example.com/v1", "http://studio.local/v1", "http://192.168.1.2/v1", "http://0.0.0.0/v1"] {
            var model = AIModel(provider: "openai", endpoint: endpoint)
            XCTAssertFalse(model.runsAutomatically, endpoint)
            model.automatic = true
            XCTAssertTrue(model.runsAutomatically)
        }
        var local = AIModel(provider: "openai", endpoint: "http://localhost:1234/v1")
        XCTAssertTrue(local.runsAutomatically)
        local.automatic = false
        XCTAssertFalse(local.runsAutomatically)
        XCTAssertFalse(ModelDraft().automatic)
        var network = ModelDraft(); network.name = "Home server"; network.model = "document-model"
        network.changeEndpoint("http://studio.local:1234/v1")
        XCTAssertTrue(network.problems(existing: []).isEmpty)
        XCTAssertFalse(network.automatic, "A network server still requires an explicit opt-in")
    }

    func testDraftPreservesAdvancedOptionsAndResetsConsentOnProviderChange() throws {
        var draft = ModelDraft(name: "remote", dictionary: ["provider": "openai", "endpoint": "https://example.com/v1", "model": "test", "automatic": true, "apiKey": "fixture-key", "effort": "low", "futureOption": 42])
        XCTAssertTrue(draft.automatic)
        XCTAssertEqual(draft.dictionary["futureOption"] as? Int, 42)
        draft.changeEndpoint("https://another.example/v1")
        XCTAssertFalse(draft.automatic)
        XCTAssertNil(draft.dictionary["apiKey"])
        XCTAssertTrue(draft.apiKeyFile.isEmpty)
        draft.automatic = true
        draft.changeProvider("anthropic")
        XCTAssertFalse(draft.automatic)
        XCTAssertEqual(draft.endpoint, "https://api.anthropic.com")
        XCTAssertFalse(draft.problems(existing: []).isEmpty, "A new provider requires its own model ID")
    }

    func testSettingsAndRuleModelRoundTrip() throws {
        var document = try ConfigDocument(data: Data(#"{"ai":{"maxChars":1234,"models":{}}}"#.utf8))
        var draft = ModelDraft(); draft.name = "remote"; draft.model = "chosen-model"; draft.automatic = true
        XCTAssertTrue(draft.problems(existing: []).isEmpty)
        document.models[draft.name] = draft.dictionary
        var rule = RuleDraft(); rule.name = "Receipts"; rule.matchModel = draft.name
        rule.modelDescription = "Receipts for travel expenses"; rule.actionModel = draft.name; rule.destination = "Filed"
        XCTAssertTrue(rule.problems.isEmpty)
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rule.json.utf8)) as? [String: Any])
        document.setRules([dictionary], in: nil)
        let decoded = try JSONDecoder().decode(Config.self, from: document.encoded())
        XCTAssertTrue(try XCTUnwrap(decoded.ai.models["remote"]).runsAutomatically)
        XCTAssertEqual(decoded.ai.maxChars, 1234)
        XCTAssertEqual(decoded.rules[0].match.ai?.description, rule.modelDescription)
        XCTAssertEqual(decoded.rules[0].action.ai, "remote")
        var edited = RuleDraft(dictionary: dictionary); edited.matchModel = ""; edited.actionModel = ""
        let removed = try JSONDecoder().decode(Rule.self, from: Data(edited.json.utf8))
        XCTAssertNil(removed.match.ai); XCTAssertNil(removed.action.ai)
    }
}
