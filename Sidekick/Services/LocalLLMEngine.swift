import Foundation
import LiteRTLM
import Observation

enum LocalLLMError: LocalizedError {
    case noModelSelected
    case modelMissing(String)
    case noUserMessage

    var errorDescription: String? {
        switch self {
        case .noModelSelected: "Pick or download a local model in Settings first."
        case .modelMissing(let name): "The model \(name) is no longer on this device. Download it again in Settings."
        case .noUserMessage: "Nothing to send."
        }
    }
}

/// Runs chat completions fully on-device with LiteRT-LM. No network is used once a model file is installed.
///
/// The engine (weights + compiled kernels) is expensive to create, so one instance is kept alive per model
/// path and reused across tasks; each request replays the task transcript into a fresh `Conversation`.
@MainActor
@Observable
final class LocalLLMEngine {
    static let shared = LocalLLMEngine()

    enum State: Equatable {
        case idle, loading(String), ready(String), failed(String)
    }

    private(set) var state: State = .idle
    private var engine: Engine?
    private var loadedPath: String?

    private init() {}

    /// Loads (or reuses) an engine for the given model file. Safe to call repeatedly.
    func engine(for model: InstalledLocalModel) async throws -> Engine {
        if let engine, loadedPath == model.url.path, await engine.isInitialized() { return engine }
        guard FileManager.default.fileExists(atPath: model.url.path) else {
            throw LocalLLMError.modelMissing(model.name)
        }
        engine = nil
        loadedPath = nil
        state = .loading(model.name)
        do {
            let config = try EngineConfig(
                modelPath: model.url.path,
                backend: Self.preferredBackend,
                visionBackend: model.catalogEntry?.supportsVision == false ? nil : Self.preferredBackend,
                maxNumTokens: 4096,
                cacheDir: LocalModelStore.cacheDirectory.path
            )
            let newEngine = Engine(engineConfig: config)
            try await newEngine.initialize()
            engine = newEngine
            loadedPath = model.url.path
            state = .ready(model.name)
            return newEngine
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func unload() {
        engine = nil
        loadedPath = nil
        state = .idle
    }

    /// Streams a reply for `messages` (system + history + trailing user turn) as `StreamEvent`s so the
    /// agent loop can treat it exactly like a remote provider. Tools are not offered to local models.
    func streamChat(model: InstalledLocalModel, messages: [LLMMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let engine = try await self.engine(for: model)
                    let (system, history, last) = try Self.split(messages)
                    let config = ConversationConfig(
                        systemMessage: system.map { Message($0, role: .system) },
                        initialMessages: history,
                        thinkingConfig: ThinkingConfig(enableThinking: false)
                    )
                    let conversation = try await engine.createConversation(with: config)
                    for try await chunk in conversation.sendMessageStream(last) {
                        if Task.isCancelled {
                            try? conversation.cancel()
                            throw CancellationError()
                        }
                        for content in chunk.contents {
                            if case .text(let text) = content, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                        }
                    }
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transcript conversion

    private static func split(_ messages: [LLMMessage]) throws -> (system: String?, history: [Message], last: Message) {
        var system: String?
        var converted: [Message] = []
        for message in messages {
            switch message.role {
            case "system":
                system = message.textContent
            case "user":
                if let m = userMessage(from: message) { converted.append(m) }
            case "assistant":
                var text = message.textContent ?? ""
                if let calls = message.toolCalls, !calls.isEmpty {
                    text += calls.map { "\n[used tool \($0.name)]" }.joined()
                }
                if !text.isEmpty { converted.append(Message(text, role: .model)) }
            case "tool":
                if let result = message.textContent, !result.isEmpty {
                    converted.append(Message("Tool result: \(result.prefix(4000))", role: .model))
                }
            default:
                break
            }
        }
        guard let last = converted.last, last.role == .user else { throw LocalLLMError.noUserMessage }
        converted.removeLast()
        return (system, converted, last)
    }

    private static func userMessage(from message: LLMMessage) -> Message? {
        var contents: [Content] = []
        for part in message.content ?? [] {
            switch part {
            case .text(let text):
                if !text.isEmpty { contents.append(.text(text)) }
            case .imageURL(let url):
                if let data = decodeDataURL(url) { contents.append(.imageData(data)) }
            }
        }
        if contents.isEmpty, let text = message.textContent, !text.isEmpty { contents.append(.text(text)) }
        guard !contents.isEmpty else { return nil }
        return Message(contents: contents, role: .user)
    }

    private static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    private static var preferredBackend: Backend {
        #if targetEnvironment(simulator)
        return .cpu()
        #else
        return .gpu
        #endif
    }
}
