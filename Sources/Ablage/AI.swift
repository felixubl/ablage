import AppKit
import Foundation

struct AIModel: Decodable {
    var provider: String
    var endpoint: String?
    var model: String?
    var apiKey: String?
    var apiKeyFile: String?
    var effort: String?
    /// The model accepts images. Screenshots and scanned PDFs are then sent as pictures instead of OCR text.
    var vision: Bool?
    /// Remote models never run on their own unless this is set. Local ones always may.
    var automatic: Bool?

    var isLocal: Bool {
        if provider == "apple" { return true }
        guard provider == "openai", let host = endpoint.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) || host.hasSuffix(".local")
    }

    var runsAutomatically: Bool { isLocal || automatic == true }

    func resolvedKey() -> String? {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        if let apiKeyFile, let text = try? String(contentsOfFile: Paths.expand(apiKeyFile), encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        return nil
    }
}

struct AIConfig: Decodable {
    var models: [String: AIModel] = [:]
    var maxChars = 3000
    var timeoutSeconds = 90.0

    private enum CodingKeys: String, CodingKey { case models, maxChars, timeoutSeconds }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([String: AIModel].self, forKey: .models) ?? models
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? maxChars
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? timeoutSeconds
    }

    var modelNames: [String] { models.keys.sorted() }
}

struct Classification {
    /// 1-based index into the candidate rules, 0 when none fits.
    var category: Int
    var correspondent: String
    var title: String
    var date: Date?
    var model: String
}

struct PromptText {
    var instructions: String
    var user: String
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

final class Classifier {
    private let config: AIConfig

    init(config: AIConfig) { self.config = config }

    /// One call to one named model. The caller decides that this file may go to this model.
    func classify(facts: FileFacts, text: String?, candidates: [Rule], model name: String) -> Classification? {
        guard let model = config.models[name] else {
            Log.write("ai: model \"\(name)\" is not defined under ai.models")
            return nil
        }
        let textIsThin = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 40
        let wantsImage = model.vision == true && (Extract.imageExtensions.contains(facts.ext) || (facts.ext == "pdf" && textIsThin))
        let image = wantsImage ? Images.jpeg(for: facts.url, ext: facts.ext) : nil
        let prompt = Prompt.build(facts: facts, text: text, candidates: candidates, maxChars: config.maxChars, hasImage: image != nil)
        do {
            let raw = try run(model, prompt: prompt, image: image)
            guard var parsed = Parse.classification(raw) else {
                Log.write("ai [\(name)]: could not parse answer: \(raw.prefix(200))")
                return nil
            }
            parsed.model = name
            Log.write("ai [\(name)] \(facts.name): category \(parsed.category), \(parsed.correspondent) / \(parsed.title)")
            return parsed
        } catch {
            Log.write("ai [\(name)] failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func run(_ model: AIModel, prompt: PromptText, image: Data?) throws -> String {
        switch model.provider {
        case "apple": return try AppleModel.respond(prompt, timeout: config.timeoutSeconds)
        case "openai": return try openAI(model, prompt, image)
        case "anthropic": return try anthropic(model, prompt, image)
        default: throw AIError(message: "unknown provider \"\(model.provider)\"")
        }
    }

    // MARK: OpenAI-compatible (LM Studio, Ollama, OpenAI)

    private func openAI(_ m: AIModel, _ p: PromptText, _ image: Data?) throws -> String {
        guard let endpoint = m.endpoint, let url = URL(string: trimSlash(endpoint) + "/chat/completions") else {
            throw AIError(message: "endpoint missing")
        }
        var userContent: Any = p.user
        if let image {
            userContent = [
                ["type": "text", "text": p.user],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]],
            ]
        }
        let body: [String: Any] = [
            "model": m.model ?? "",
            "messages": [["role": "system", "content": p.instructions], ["role": "user", "content": userContent]],
            "temperature": 0,
            "max_tokens": 400,
            "response_format": ["type": "json_object"],
        ]
        var headers = ["Content-Type": "application/json"]
        if let key = m.resolvedKey() { headers["Authorization"] = "Bearer \(key)" }
        let json = try post(url, body, headers)
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIError(message: message)
        }
        guard let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
            throw AIError(message: "no choices in response")
        }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        throw AIError(message: "empty answer")
    }

    // MARK: Claude Messages API

    private func anthropic(_ m: AIModel, _ p: PromptText, _ image: Data?) throws -> String {
        guard let key = m.resolvedKey() else { throw AIError(message: "no API key, set apiKey or apiKeyFile") }
        guard let url = URL(string: trimSlash(m.endpoint ?? "https://api.anthropic.com") + "/v1/messages") else {
            throw AIError(message: "bad endpoint")
        }
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
        }
        content.append(["type": "text", "text": p.user])
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "integer"],
                "correspondent": ["type": "string"],
                "title": ["type": "string"],
                "date": ["type": "string"],
            ],
            "required": ["category", "correspondent", "title", "date"],
            "additionalProperties": false,
        ]
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
        let effort = m.effort ?? "low"
        if !effort.isEmpty { outputConfig["effort"] = effort }
        let body: [String: Any] = [
            "model": m.model ?? "claude-opus-5",
            "max_tokens": 1024,
            "system": p.instructions,
            "messages": [["role": "user", "content": content]],
            "output_config": outputConfig,
            "fallbacks": "default",
        ]
        let headers = [
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "server-side-fallback-2026-07-01",
        ]
        let json = try post(url, body, headers)
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw AIError(message: message)
        }
        if json["stop_reason"] as? String == "refusal" { throw AIError(message: "request was refused") }
        guard let blocks = json["content"] as? [[String: Any]] else { throw AIError(message: "no content in response") }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    private func post(_ url: URL, _ body: [String: Any], _ headers: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Box<Result<Data, Error>>(.failure(AIError(message: "no response")))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome.value = .failure(error)
                return
            }
            let data = data ?? Data()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let excerpt = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                outcome.value = .failure(AIError(message: "HTTP \(http.statusCode) \(excerpt)"))
                return
            }
            outcome.value = .success(data)
        }.resume()
        semaphore.wait()
        let data = try outcome.value.get()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "response is not a JSON object")
        }
        return json
    }

    private func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}

enum Prompt {
    static func build(facts: FileFacts, text: String?, candidates: [Rule], maxChars: Int, hasImage: Bool) -> PromptText {
        let instructions = """
            You file documents for a personal archive. Look at the document and answer with one JSON object and nothing else: \
            {"category": <number>, "correspondent": "<who issued it, short>", "title": "<subject in 2 to 6 words>", "date": "<YYYY-MM-DD or empty>"}. \
            category is the number of the category that fits best, or 0 when none fits well. \
            Write correspondent and title in the document's own language. Do not invent a date.
            """
        var user = "Filename: \(facts.name)\n"
        if !facts.host.isEmpty { user += "Downloaded from: \(facts.host)\n" }
        user += "\nCategories:\n0. none of these\n"
        for (i, rule) in candidates.enumerated() { user += "\(i + 1). \(rule.name): \(rule.match.ai?.description ?? "")\n" }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "\nDocument text (excerpt):\n\(String(text.prefix(maxChars)))\n"
        } else if hasImage {
            user += "\nThe document is attached as an image.\n"
        } else {
            user += "\nNo text could be extracted. Judge by the filename.\n"
        }
        user += "\nAnswer with the JSON object only."
        return PromptText(instructions: instructions, user: user)
    }
}

enum Parse {
    static func classification(_ raw: String) -> Classification? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end { s = String(s[start...end]) }
        guard let data = s.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var category = 0
        if let number = object["category"] as? NSNumber {
            category = number.intValue
        } else if let string = object["category"] as? String, let number = Int(string.trimmingCharacters(in: .whitespaces)) {
            category = number
        }
        let correspondent = (object["correspondent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let date = (object["date"] as? String).flatMap { Extract.date(in: $0) }
        return Classification(category: category, correspondent: correspondent, title: title, date: date, model: "")
    }
}

enum Images {
    static func jpeg(for url: URL, ext: String, maxSide: CGFloat = 1024) -> Data? {
        let source: CGImage?
        if ext == "pdf" {
            source = Extract.firstPageImage(url)
        } else {
            source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cg = source else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, maxSide / max(width, height))
        let size = NSSize(width: max(1, width * scale), height: max(1, height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: cg, size: NSSize(width: width, height: height)).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
