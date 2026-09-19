import Foundation

/// Minimal OpenAI-compatible chat-completions client with streaming and tool calling.
/// Works with OpenAI, OpenRouter, Vercel AI Gateway, Ollama, LM Studio, etc.

enum LLMError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add an API key and model in Settings first."
        case .http(let code, let body): "Provider returned HTTP \(code): \(body.prefix(300))"
        case .invalidResponse(let s): "Unexpected response: \(s.prefix(300))"
        }
    }
}

/// Content parts for multimodal user messages.
enum ContentPart: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .imageURL(let u):
            try c.encode("image_url", forKey: .type)
            try c.encode(["url": u], forKey: .imageURL)
        }
    }

    enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
}

struct ToolCall: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var arguments: String
}

struct LLMMessage: Encodable {
    var role: String
    var content: [ContentPart]?
    var textContent: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    static func system(_ text: String) -> LLMMessage { .init(role: "system", textContent: text) }
    static func user(_ parts: [ContentPart]) -> LLMMessage { .init(role: "user", content: parts) }
    static func assistant(_ text: String, toolCalls: [ToolCall]?) -> LLMMessage {
        .init(role: "assistant", textContent: text, toolCalls: (toolCalls?.isEmpty ?? true) ? nil : toolCalls)
    }
    static func tool(id: String, result: String) -> LLMMessage {
        .init(role: "tool", textContent: result, toolCallId: id)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let content {
            try c.encode(content, forKey: .content)
        } else if let textContent {
            try c.encode(textContent, forKey: .content)
        } else if role == "assistant" {
            try c.encodeNil(forKey: .content)
        }
        if let toolCalls {
            let encoded = toolCalls.map { tc in
                ToolCallWire(id: tc.id, type: "function", function: .init(name: tc.name, arguments: tc.arguments))
            }
            try c.encode(encoded, forKey: .toolCalls)
        }
        if let toolCallId { try c.encode(toolCallId, forKey: .toolCallId) }
    }

    enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallId = "tool_call_id"
    }

    struct ToolCallWire: Encodable {
        var id: String
        var type: String
        var function: Function
        struct Function: Encodable { var name: String; var arguments: String }
    }
}

struct ToolSpec: Encodable {
    var name: String
    var description: String
    var parameters: JSONValue

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("function", forKey: .type)
        try c.encode(Function(name: name, description: description, parameters: parameters), forKey: .function)
    }

    enum CodingKeys: String, CodingKey { case type, function }
    struct Function: Encodable { var name: String; var description: String; var parameters: JSONValue }
}

enum StreamEvent {
    case textDelta(String)
    case toolCallStarted(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, delta: String)
    case finished(reason: String?)
}

struct LLMClient {
    var settings: AppSettings = .shared

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }

    func makeRequest(path: String, body: Data, method: String = "POST") throws -> URLRequest {
        guard settings.isConfigured, let url = URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw LLMError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("Sidekick iOS", forHTTPHeaderField: "X-Title")
        req.httpBody = body
        return req
    }

    /// Streams a chat completion. Yields text deltas and tool call fragments.
    func streamChat(messages: [LLMMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var payload: [String: JSONValue] = [
                        "model": .string(settings.model),
                        "stream": .bool(true),
                        "messages": try JSONValue.encode(messages),
                    ]
                    if !tools.isEmpty {
                        payload["tools"] = try JSONValue.encode(tools)
                    }
                    let body = try JSONEncoder().encode(JSONValue.object(payload))
                    let request = try makeRequest(path: "/chat/completions", body: body)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.invalidResponse("no HTTP response")
                    }
                    if http.statusCode >= 400 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw LLMError.http(http.statusCode, text)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if data == "[DONE]" { break }
                        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { continue }
                        if let err = json["error"] {
                            throw LLMError.invalidResponse(err["message"]?.stringValue ?? err.description)
                        }
                        guard let choice = json["choices"]?.arrayValue?.first else { continue }
                        let delta = choice["delta"]
                        if let text = delta?["content"]?.stringValue, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if let calls = delta?["tool_calls"]?.arrayValue {
                            for call in calls {
                                let index = Int(call["index"]?.doubleValue ?? 0)
                                let fn = call["function"]
                                if let name = fn?["name"]?.stringValue, !name.isEmpty {
                                    continuation.yield(.toolCallStarted(index: index, id: call["id"]?.stringValue ?? "call_\(index)", name: name))
                                }
                                if let args = fn?["arguments"]?.stringValue, !args.isEmpty {
                                    continuation.yield(.toolCallArgumentsDelta(index: index, delta: args))
                                }
                            }
                        }
                        if let reason = choice["finish_reason"]?.stringValue {
                            continuation.yield(.finished(reason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Generic JSON POST used by image/video tools.
    func postJSON(path: String, body: JSONValue) async throws -> JSONValue {
        let request = try makeRequest(path: path, body: try JSONEncoder().encode(body))
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func getJSON(path: String) async throws -> JSONValue {
        var request = try makeRequest(path: path, body: Data(), method: "GET")
        request.httpBody = nil
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func getData(path: String) async throws -> Data {
        var request = try makeRequest(path: path, body: Data(), method: "GET")
        request.httpBody = nil
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return data
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
