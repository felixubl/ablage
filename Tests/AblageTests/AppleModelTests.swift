import XCTest
@testable import Ablage

#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppleModelTests: XCTestCase {
    func testClassificationSchemaAndContentWithoutCompilerMacros() throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let source = try GeneratedContent(json: #"{"category":2,"correspondent":"Atelier Wien","title":"Studio subscription","date":"2026-09-20"}"#)
            let value = try AppleClassification(source)
            XCTAssertEqual(value.category, 2)
            XCTAssertEqual(value.correspondent, "Atelier Wien")
            XCTAssertEqual(value.title, "Studio subscription")
            XCTAssertEqual(value.date, "2026-09-20")
            // GeneratedContent also carries identity metadata; compare the actual payload.
            let roundTrip = try JSONSerialization.jsonObject(with: Data(value.generatedContent.jsonString.utf8)) as? NSDictionary
            let original = try JSONSerialization.jsonObject(with: Data(source.jsonString.utf8)) as? NSDictionary
            XCTAssertEqual(try XCTUnwrap(roundTrip), try XCTUnwrap(original))

            let schema = try JSONEncoder().encode(AppleClassification.generationSchema)
            let decoded = try JSONDecoder().decode(GenerationSchema.self, from: schema)
            XCTAssertEqual(decoded.debugDescription, AppleClassification.generationSchema.debugDescription)
            let missing = try GeneratedContent(json: #"{"category":2}"#)
            XCTAssertThrowsError(try AppleClassification(missing))
            let wrongType = try GeneratedContent(json: #"{"category":"not a number","correspondent":"","title":"","date":""}"#)
            XCTAssertThrowsError(try AppleClassification(wrongType))
            return
        }
        #endif
        throw XCTSkip("Foundation Models schema checks require macOS 26 and its SDK")
    }
}
