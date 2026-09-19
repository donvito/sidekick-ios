import Foundation
import Security
import Observation

enum ProviderPreset: String, CaseIterable, Identifiable {
    case openai, openrouter, vercel, ollama, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .vercel: "Vercel AI Gateway"
        case .ollama: "Ollama (local)"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .vercel: "https://ai-gateway.vercel.sh/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: "gpt-4.1-mini"
        case .openrouter: "openai/gpt-4.1-mini"
        case .vercel: "openai/gpt-4.1-mini"
        case .ollama: "qwen3"
        case .custom: ""
        }
    }

    var supportsMedia: Bool { self == .openai || self == .custom }
    var requiresAPIKey: Bool { self != .ollama && self != .custom }
    var needsBaseURL: Bool { self == .ollama || self == .custom }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var preset: ProviderPreset {
        didSet {
            defaults.set(preset.rawValue, forKey: "preset")
            if preset != .custom {
                baseURL = preset.baseURL
                if model.isEmpty || oldValue != preset { model = preset.defaultModel }
            }
        }
    }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    var imageModel: String { didSet { defaults.set(imageModel, forKey: "imageModel") } }
    var videoModel: String { didSet { defaults.set(videoModel, forKey: "videoModel") } }
    var askBeforeActing: Bool { didSet { defaults.set(askBeforeActing, forKey: "askBeforeActing") } }
    var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    var userAbout: String { didSet { defaults.set(userAbout, forKey: "userAbout") } }
    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }

    var apiKey: String {
        didSet { Keychain.set(apiKey, for: "apiKey") }
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty && (!apiKey.isEmpty || !preset.requiresAPIKey)
    }

    private init() {
        let presetRaw = defaults.string(forKey: "preset") ?? ProviderPreset.openai.rawValue
        let p = ProviderPreset(rawValue: presetRaw) ?? .openai
        preset = p
        baseURL = defaults.string(forKey: "baseURL") ?? p.baseURL
        model = defaults.string(forKey: "model") ?? p.defaultModel
        imageModel = defaults.string(forKey: "imageModel") ?? "gpt-image-1"
        videoModel = defaults.string(forKey: "videoModel") ?? "sora-2"
        askBeforeActing = defaults.object(forKey: "askBeforeActing") as? Bool ?? true
        userName = defaults.string(forKey: "userName") ?? ""
        userAbout = defaults.string(forKey: "userAbout") ?? ""
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        apiKey = Keychain.get("apiKey") ?? ""
    }
}

enum Keychain {
    private static let service = "com.donvito.sidekick"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
