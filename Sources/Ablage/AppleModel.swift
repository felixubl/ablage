import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct AppleClassification {
    @Guide(description: "Number of the category that fits best, 0 when none fits")
    var category: Int
    @Guide(description: "Who issued the document: company, authority or person, kept short")
    var correspondent: String
    @Guide(description: "Subject of the document in 2 to 6 words")
    var title: String
    @Guide(description: "Document date as YYYY-MM-DD, empty when unknown")
    var date: String
}
#endif

/// Apple's on-device model. Free, private, no setup beyond Apple Intelligence being switched on.
enum AppleModel {
    static func respond(_ prompt: PromptText, timeout: TimeInterval) throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                throw AIError(message: "Apple Intelligence is not available: \(model.availability)")
            }
            let semaphore = DispatchSemaphore(value: 0)
            let outcome = Box<Result<String, Error>>(.failure(AIError(message: "timed out")))
            Task {
                defer { semaphore.signal() }
                do {
                    let session = LanguageModelSession(model: model, instructions: prompt.instructions)
                    let response = try await session.respond(to: prompt.user, generating: AppleClassification.self)
                    let c = response.content
                    let object: [String: Any] = ["category": c.category, "correspondent": c.correspondent, "title": c.title, "date": c.date]
                    let data = try JSONSerialization.data(withJSONObject: object)
                    outcome.value = .success(String(decoding: data, as: UTF8.self))
                } catch {
                    outcome.value = .failure(error)
                }
            }
            if semaphore.wait(timeout: .now() + timeout) == .timedOut { throw AIError(message: "timed out") }
            return try outcome.value.get()
        }
        #endif
        throw AIError(message: "the on-device model needs macOS 26")
    }
}
