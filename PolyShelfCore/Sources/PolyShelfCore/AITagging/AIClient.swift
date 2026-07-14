import Foundation

/// AI endpoint configuration (FR-5.5). Base URL + model live in UserDefaults;
/// the key comes from the Keychain at call time and is never persisted here.
public struct AIEndpointConfig: Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var maxConcurrent: Int

    public init(baseURL: String, model: String, maxConcurrent: Int = 2) {
        self.baseURL = baseURL
        self.model = model
        self.maxConcurrent = maxConcurrent
    }

    public var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty
    }

    /// ".../v1" or bare host both accepted; normalized to the completions URL.
    public var chatCompletionsURL: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return URL(string: base + "/chat/completions")
    }
}

/// Strict-JSON contract the model must return (FR-5.6).
public struct AITagResult: Codable, Equatable, Sendable {
    public var tags: [String]
    public var description: String?
    public var suggestedDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case tags
        case description
        case suggestedDisplayName = "suggested_display_name"
    }
}

public enum AIClientError: Error, LocalizedError {
    case notConfigured
    case http(Int, String)
    case malformedResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "AI tagging isn’t configured. Set the base URL and model in Settings → AI Tagging."
        case .http(let code, let body): "Endpoint returned HTTP \(code): \(body)"
        case .malformedResponse(let detail): "Model reply wasn’t valid JSON after one retry: \(detail)"
        case .transport(let detail): "Network error: \(detail)"
        }
    }
}

/// OpenAI-compatible /v1/chat/completions client (works with OpenAI,
/// OpenRouter, Ollama, LM Studio, or any proxy). Single JSON response, no
/// streaming. The API key never appears in logs or error strings.
public struct AIClient: Sendable {
    public var config: AIEndpointConfig
    /// Injected for tests; nil → Keychain.
    private let apiKeyOverride: String?
    private let session: URLSession

    public init(config: AIEndpointConfig, apiKeyOverride: String? = nil, session: URLSession = .shared) {
        self.config = config
        self.apiKeyOverride = apiKeyOverride
        self.session = session
    }

    static let systemPrompt = """
    You are a 3D print model librarian. You will receive a rendered preview \
    image of a 3D model plus its filename and geometry stats. Reply with ONLY \
    a JSON object, no prose, no markdown fences, exactly this shape:
    {"tags": ["lowercase-tag", ...], "description": "one sentence", "suggested_display_name": "Readable Name"}
    Use 3-8 short lowercase tags describing what the object IS and notable \
    printing traits (e.g. articulated, vase, miniature, functional, decor).
    """

    // MARK: - Requests

    public func buildRequest(filename: String, stats: String, previewPNG: Data?, maxTokens: Int = 400) throws -> URLRequest {
        guard config.isConfigured, let url = config.chatCompletionsURL else {
            throw AIClientError.notConfigured
        }
        var userContent: [[String: Any]] = [
            ["type": "text", "text": "Filename: \(filename)\n\(stats)"]
        ]
        if let previewPNG {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(previewPNG.base64EncodedString())"],
            ])
        }
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKeyOverride ?? KeychainStore.loadAPIKey()
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Full tag call with one retry on malformed JSON (FR-5.6).
    public func generateTags(filename: String, stats: String, previewPNG: Data?) async throws -> AITagResult {
        let request = try buildRequest(filename: filename, stats: stats, previewPNG: previewPNG)
        do {
            return try await send(request)
        } catch AIClientError.malformedResponse {
            return try await send(request) // retry once, then propagate
        }
    }

    private func send(_ request: URLRequest) async throws -> AITagResult {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIClientError.transport(Self.scrubbed(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.transport("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw AIClientError.http(http.statusCode, Self.scrubbed(body))
        }
        let content = try Self.extractContent(data)
        return try Self.parseResult(content)
    }

    /// 1-token dry call for the settings "Test connection" button (FR-5.8).
    /// Returns nil on success, or the raw (key-scrubbed) error text.
    public func testConnection() async -> String? {
        do {
            guard config.isConfigured, let url = config.chatCompletionsURL else {
                throw AIClientError.notConfigured
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = apiKeyOverride ?? KeychainStore.loadAPIKey()
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]],
            ])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "No HTTP response" }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
                return "HTTP \(http.statusCode): \(Self.scrubbed(body))"
            }
            return nil
        } catch {
            return Self.scrubbed(error.localizedDescription)
        }
    }

    // MARK: - Response parsing (pure, unit-tested)

    static func extractContent(_ data: Data) throws -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AIClientError.malformedResponse("missing choices[0].message.content")
        }
        return content
    }

    /// Tolerates markdown fences and leading prose, then validates strictly.
    static func parseResult(_ content: String) throws -> AITagResult {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = text.range(of: "```") {
            text = String(text[fenceStart.upperBound...])
            if let newline = text.firstIndex(of: "\n") { text = String(text[newline...]) }
            if let fenceEnd = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceEnd.lowerBound])
            }
        }
        // Fall back to the outermost {...} span.
        if !text.hasPrefix("{"), let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              var result = try? JSONDecoder().decode(AITagResult.self, from: data) else {
            throw AIClientError.malformedResponse(String(text.prefix(200)))
        }
        result.tags = result.tags
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 }
        guard !result.tags.isEmpty else {
            throw AIClientError.malformedResponse("empty tags array")
        }
        return result
    }

    /// Removes any occurrence of the API key from outbound text (defense in
    /// depth for the "key never appears in logs" acceptance).
    static func scrubbed(_ text: String) -> String {
        guard let key = KeychainStore.loadAPIKey(), key.count >= 8 else { return text }
        return text.replacingOccurrences(of: key, with: "•••")
    }
}
